# Agent de Migration — Résumé des responsabilités

Résume de l'ensemble des tâches de l'agent de migration.

---

## Rôle

L'agent de migration est l'**orchestrateur central** de déplacement des VMs dans le cluster Proxmox. Il ne surveille pas lui-même les métriques (c'est le rôle des agents RAM, vCPU, GPU) mais **réagit à leurs signaux** et **prend les décisions de placement** en évaluant l'état global du cluster.

---

## Tâches de l'agent

### 1. Migration sur signal des autres agents

| Signal reçu | Source | Action |
|---|---|---|
| `MIGRATE_VM` | Agent RAM ou vCPU | Migrer une VM spécifique vers le nœud le moins chargé |
| `LIGHTEN_NODE` | Agent RAM ou vCPU | Choisir la VM la plus gourmande en ressource et la migrer |
| `GPU_REQUEST` | Agent GPU | Migrer une VM vers un nœud avec GPU disponible et le moins sollicité |
| `CONSOLIDATE_VM` | Agent RAM | Surveiller le cluster et regrouper une VM à RAM dispersée dès qu'un nœud peut tout héberger |

Pour chaque signal :
- Évaluer le **pourcentage d'utilisation** de chaque nœud (pas seulement les valeurs absolues, car les nœuds n'ont pas les mêmes capacités)
- Ne migrer **que si** un nœud cible est significativement moins chargé (marge de 10%)
- Vérifier que le nœud cible a assez de **capacité absolue** (Go de RAM libre) pour la VM
- Pour `GPU_REQUEST` : utiliser les pourcentages d'utilisation GPU fournis par l'agent GPU pour choisir le nœud avec le GPU le moins sollicité
- Exécuter `qm migrate --online` (pre-copy natif Proxmox, avec option XBZRLE)
- Envoyer une **réponse** à l'agent source (succès/échec/refus)

### 2. Placement automatique des nouvelles VMs

Quand une VM est créée (via l'interface web ou le terminal) sur un nœud qui n'a pas assez de ressources :
- Détection immédiate via `inotifywait` sur `/etc/pve/qemu-server/`
- Évaluation des ressources requises vs disponibles
- Migration à froid (instantanée) vers un nœud capable d'accueillir la VM
- Si aucun nœud ne peut → la VM reste sur place, l'erreur Proxmox standard s'affiche au démarrage

### 3. Consolidation des VMs à RAM dispersée

Quand l'équipe RAM partage la RAM d'une VM sur plusieurs nœuds (ex: 4 Go sur EMILIA + 4 Go sur REM), la VM est lente. L'agent RAM envoie un signal `CONSOLIDATE_VM` avec les informations nécessaires (RAM totale, nœuds impliqués). Notre daemon :
- Enregistre la VM comme "à consolider"
- Surveille l'état du **cluster** (pas de la VM) en continu
- Dès qu'un nœud peut héberger **toute** la VM → exécute la migration
- Si nécessaire, **harmonise le cluster** : déplace d'abord des petites VMs pour libérer assez d'espace sur un nœud (voir algorithme d'harmonisation)
- Répond à l'agent RAM avec le résultat (`CONSOLIDATED` ou `CONSOLIDATION_IMPOSSIBLE`)

### 4. Mode maintenance

Commande manuelle pour vider un nœud de toutes ses VMs avant maintenance :
- Chaque VM est migrée vers le nœud **le moins chargé au moment de sa migration** (recalculé à chaque VM)
- Distribution optimale : les VMs ne vont pas toutes sur le même nœud
- Option : forcer un nœud cible pour toutes les VMs

### 5. Migration manuelle

Commande pour l'administrateur : `migrator-ctl.sh migrate <vmid> <node>`

### 6. Gestion des VMs éteintes (surallocation surveillée)

Les VMs éteintes ne consomment pas de RAM. L'agent **ne réserve pas** la RAM pour les VMs éteintes (ce qui permet de maximiser l'utilisation des ressources). Quand un utilisateur redémarre sa VM et que le nœud est plein :
- L'agent RAM/vCPU envoie un signal `LIGHTEN_NODE`
- L'agent de migration migre une **autre** VM pour faire de la place
- La VM de l'utilisateur n'est pas touchée

---

## Protections implémentées

| Protection | Mécanisme | Objectif |
|---|---|---|
| **Anti-ping-pong** | Cooldown de 5 min par VM | Empêcher qu'une VM soit migrée en boucle |
| **Anti-migration inutile** | Marge de 10% entre nœuds | Ne migrer que si c'est réellement bénéfique |
| **Anti-rafale** | File d'attente + tri par urgence | Gérer les pics de signaux |
| **Re-vérification** | État recalculé avant chaque migration | Ne pas migrer si la situation a changé |
| **Signaux contradictoires** | Premier arrivé, premier servi + cooldown | Éviter les conflits entre agents |

---

## Choix techniques

| Choix | Justification |
|---|---|
| **Pre-copy natif** (pas post-copy) | Supporté par Proxmox, sûr en cas de panne du nœud source |
| **XBZRLE** (optionnel) | Compression mémoire pour réseaux lents |
| **inotifywait** (pas polling) | Réaction instantanée aux signaux, 0 CPU en attente |
| **Pourcentages d'abord** | Comparaison équitable entre nœuds de capacités différentes |
| **Fichiers .sig** (pas socket/API) | Simple, debuggable, compatible avec tout langage |
| **Utilisation GPU fournie par l'agent** | Pas besoin de `nvidia-smi` local, l'agent GPU fournit les % d'utilisation par nœud |

---

## Communication avec les autres agents

| Agent | Signaux reçus | Réponse envoyée |
|---|---|---|
| Agent RAM | `MIGRATE_VM`, `LIGHTEN_NODE`, `CONSOLIDATE_VM` | Succès/échec/refus dans fichier `.resp` |
| Agent vCPU | `MIGRATE_VM`, `LIGHTEN_NODE` | Idem |
| Agent GPU | `GPU_REQUEST` (fournit `gpu_nodes_usage`) | Idem |

Le protocole de communication est documenté en détail dans `INTER_TEAM_API.md`.

---

## Outils fournis

| Outil | Rôle |
|---|---|
| `live-migrator.sh` | Daemon systemd (tourne sur chaque nœud) |
| `migrator-ctl.sh` | CLI admin : status, migrate, maintenance, history, create, signal (test) |
| `analyze_migrations.py` | Analyse des logs + génération de graphiques pour le rapport |
| `build-deb.sh` | Construction du paquet Debian pour déploiement facile |

---

## Scénarios de test

### Testables immédiatement (sans les autres agents)

| # | Test |
|---|------|
| 1 | Création de VM avec placement automatique (CLI + interface web) |
| 2 | Migration manuelle via `migrator-ctl.sh` |
| 3 | Mode maintenance avec distribution optimale |
| 4 | Simulation de signaux via `migrator-ctl.sh signal` |
| 5 | Migration pre-copy vs XBZRLE |
| 6 | Vérification du cooldown (anti-ping-pong) |
| 7 | Mesure du downtime (test ping) |

### Nécessitent les autres agents

| # | Test | Dépendance |
|---|------|------------|
| 8 | Signal réel `MIGRATE_VM` / `LIGHTEN_NODE` | Agent RAM ou vCPU |
| 9 | Signal réel `GPU_REQUEST` | Agent GPU |
| 10 | Consolidation après partage de ressources | Agent RAM avec partage actif |
| 11 | Chaîne complète : surcharge → signal → migration → réponse | Tous les agents |
