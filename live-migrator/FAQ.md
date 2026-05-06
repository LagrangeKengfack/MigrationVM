# FAQ — Live Migrator : Réponses détaillées

Ce document répond à toutes les questions fréquentes sur le fonctionnement, les concepts et les choix de conception du live-migrator.

---

## Table des matières

1. [Qu'est-ce que le yo-yo de migration ?](#1-quest-ce-que-le-yo-yo-de-migration-)
2. [Tunnel SSH et mode insecure — comment ça marche ?](#2-tunnel-ssh-et-mode-insecure--comment-ça-marche-)
3. [Pourquoi XBZRLE est inutile sur réseau rapide ? + Comparaison pre-copy vs post-copy](#3-pourquoi-xbzrle-est-inutile-sur-réseau-rapide--comparaison-complète-pre-copy-vs-post-copy)
4. [Pre-copy par défaut et XBZRLE optionnel](#4-pre-copy-par-défaut-et-xbzrle-optionnel)
5. [Le service doit-il être réactivé après chaque redémarrage ?](#5-le-service-doit-il-être-réactivé-après-chaque-redémarrage-)
6. [Les modes de lancement de live-migrator.sh](#6-les-modes-de-lancement-de-live-migratorsh)
7. [Migration vers plusieurs nœuds — comment ça décide ?](#7-migration-vers-plusieurs-nœuds--comment-ça-décide-)
8. [Quelle VM migrer quand le seuil est dépassé ?](#8-quelle-vm-migrer-quand-le-seuil-est-dépassé-)
9. [GPU passthrough et live migration](#9-gpu-passthrough-et-live-migration)
10. [Automatiser le basculement pre-copy ↔ post-copy](#10-automatiser-le-basculement-pre-copy--post-copy)
11. [Verrouillage (lock) de la VM pendant la migration](#11-verrouillage-lock-de-la-vm-pendant-la-migration)
12. [Dashboard de métriques basique](#12-dashboard-de-métriques-basique)
13. [Fallback si aucun nœud ne peut accueillir la plus grosse VM](#13-fallback-si-aucun-nœud-ne-peut-accueillir-la-plus-grosse-vm)
14. [Installation sur le vrai cluster (REM, RAM, EMILIA)](#14-installation-sur-le-vrai-cluster-rem-ram-emilia)
15. [Ne pas éditer le README existant](#15-ne-pas-éditer-le-readme-existant)

---

## 1. Qu'est-ce que le yo-yo de migration ?

### Le problème

Imagine ce scénario :

```
15:00:00 — CPU du nœud REM = 91% → seuil 90% dépassé → VM 101 migrée vers RAM
15:00:45 — Migration terminée. REM descend à 60%.
15:01:00 — Mais RAM monte à 92% (car elle a reçu VM 101) → seuil dépassé → VM 101 migrée... vers REM !
15:01:45 — REM remonte à 91% → migration de nouveau...
```

**La VM 101 fait des allers-retours entre REM et RAM en boucle**, comme un yo-yo. C'est désastreux car :

- Chaque migration consomme du réseau et du CPU
- Chaque migration cause un micro-downtime (~100-500 ms)
- Le cluster est constamment perturbé sans jamais se stabiliser

### Comment on l'empêche

Notre outil utilise **2 mécanismes anti-yo-yo** :

| Mécanisme | Comment ça marche | Paramètre |
|-----------|-------------------|-----------|
| **Hystérésis** | La migration se déclenche à `seuil + hystérésis` (ex: 95%), mais la situation est considérée "normale" dès que ça redescend sous `seuil` (90%). Ça crée une "zone morte" de 5% où rien ne se passe. | `hysteresis = 5` |
| **Cooldown** | Après une migration, on interdit toute nouvelle migration automatique pendant X secondes (défaut : 5 minutes). Même si un seuil est re-dépassé. | `cooldown = 300` |

### Exemple avec hystérésis

```
Seuil CPU = 90%    Hystérésis = 5%

   100% ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ──
    95% ─── ─── ─── ─── ─── DÉCLENCHEMENT ─── ─── ──   ← On migre ICI (95%)
    90% ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ──   ← Seuil
    85% ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ──
    80% ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ──

Entre 90% et 95% = ZONE MORTE → on ne fait rien
En-dessous de 90% = situation normale, le compteur est réinitialisé
```

Sans l'hystérésis, si le CPU oscille entre 89% et 91%, il y aurait une migration toutes les 15 secondes !

---

## 2. Tunnel SSH et mode insecure — comment ça marche ?

Pendant une migration à chaud, Proxmox doit transférer la RAM de la VM (potentiellement des Go de données) d'un nœud à l'autre. Il y a **deux façons** de faire ce transfert :

### Mode `secure` (tunnel SSH) — le défaut

```
┌─────────────────┐                          ┌─────────────────┐
│   Nœud source   │                          │   Nœud cible    │
│   (REM)         │                          │   (RAM)         │
│                 │       TUNNEL SSH          │                 │
│  QEMU ──────────┼─── chiffré (AES-256) ───┼──────── QEMU    │
│                 │                          │                 │
│  RAM de la VM ──┤  → données chiffrées →   ├── RAM reçue     │
│                 │                          │                 │
└─────────────────┘                          └─────────────────┘
```

**Comment ça fonctionne :**

1. Proxmox ouvre une connexion SSH du nœud source vers le nœud cible
2. À travers cette connexion SSH, il crée un **tunnel** : un "tube" chiffré dans lequel passent les données
3. QEMU sur le nœud source envoie les pages RAM à travers ce tunnel
4. Toutes les données (RAM, état CPU, etc.) sont **chiffrées en transit** avec le chiffrement SSH (AES-256 typiquement)

**Analogie :** C'est comme envoyer un colis dans un coffre-fort verrouillé. Même si quelqu'un intercepte le colis sur le réseau, il ne peut pas lire le contenu.

**Avantage :** Sécurisé — personne sur le réseau ne peut voir les données des VMs en transit.

**Inconvénient :** Le chiffrement/déchiffrement consomme du CPU et ralentit le transfert (~30-50% plus lent qu'en clair).

### Mode `insecure` (TCP direct)

```
┌─────────────────┐                          ┌─────────────────┐
│   Nœud source   │                          │   Nœud cible    │
│   (REM)         │                          │   (RAM)         │
│                 │       TCP DIRECT          │                 │
│  QEMU ──────────┼─── données en clair  ───┼──────── QEMU    │
│                 │   (port ~4000-4999)      │                 │
│  RAM de la VM ──┤  → transfert rapide →    ├── RAM reçue     │
│                 │                          │                 │
└─────────────────┘                          └─────────────────┘
```

**Comment ça fonctionne :**

1. QEMU sur le nœud cible ouvre un port TCP (dans la plage 4000-4999 typiquement)
2. QEMU sur le nœud source se connecte directement à ce port
3. Les données de la RAM sont envoyées **en clair** (pas de chiffrement) via ce port TCP
4. C'est un transfert réseau brut, comme un simple copie de fichier

**Le terme "insecure" :** Les données de la RAM de la VM (qui peuvent contenir des mots de passe, des données sensibles, etc.) transitent **en clair** sur le réseau. Toute personne ayant accès au réseau peut potentiellement les intercepter.

**Pourquoi on l'utilise quand même :**

- Dans un cluster Proxmox, le réseau entre les nœuds est généralement un **réseau privé dédié** (VLAN ou réseau physique séparé)
- Personne d'extérieur n'y a accès
- Le gain de vitesse est significatif (~×2 plus rapide)
- En production, c'est la recommandation courante pour les clusters Proxmox internes

### Comparaison

| Aspect | `secure` (SSH) | `insecure` (TCP) |
|--------|----------------|-----------------|
| Chiffrement | ✅ AES-256 | ❌ Aucun |
| Vitesse | ~500 MiB/s | ~1000 MiB/s (×2) |
| Usage CPU | Élevé (chiffrement) | Faible |
| Sécurité réseau | Données protégées | Données en clair |
| Réseau requis | N'importe lequel | Réseau privé/dédié recommandé |
| **Recommandation** | Réseau partagé/public | **Réseau dédié cluster (notre cas)** |

---

## 3. Pourquoi XBZRLE est inutile sur réseau rapide ? + Comparaison complète pre-copy vs post-copy

### Pourquoi XBZRLE est inutile sur réseau 10 Gbps

XBZRLE compresse les pages mémoire modifiées avant de les envoyer sur le réseau. Voici le calcul :

```
Scénario : VM avec 8 Go de RAM, taux de dirty pages = 200 Mo/s

SANS compression (réseau 10 Gbps = ~1200 Mo/s de débit réel) :
  → Le réseau peut évacuer 1200 Mo/s
  → Les dirty pages arrivent à 200 Mo/s
  → Le réseau absorbe FACILEMENT toute la charge → convergence rapide
  → La compression ajouterait du CPU pour RIEN

AVEC compression :
  → On compresse 200 Mo/s de données → ça donne ~80 Mo/s à transférer
  → On gagne 120 Mo/s sur le réseau ... mais le réseau avait déjà 1000 Mo/s de marge !
  → Le CPU est gaspillé à compresser pour un gain réseau inutile

SANS compression (réseau 1 Gbps = ~120 Mo/s de débit réel) :
  → Les dirty pages arrivent à 200 Mo/s
  → Le réseau ne peut évacuer que 120 Mo/s
  → 200 > 120 → LE RÉSEAU EST LE GOULOT → migration NE CONVERGE PAS
  → La compression réduit 200 Mo/s → ~80 Mo/s < 120 Mo/s → ÇA CONVERGE !
```

**Conclusion :** La compression n'est utile que quand le réseau est le facteur limitant. Sur 10 Gbps, le réseau n'est jamais le facteur limitant, sauf pour des VMs avec un taux d'écriture extrême (ce qui est rare).

### Comparaison COMPLÈTE : pre-copy vs post-copy

| Critère | Pre-copy (notre choix) | Post-copy |
|---------|----------------------|-----------|
| **Comment ça marche** | Copie TOUTE la RAM avant de basculer la VM. Re-copie les pages modifiées. Quand il n'y a presque plus de modifications → pause courte → bascule. | Bascule la VM IMMÉDIATEMENT. Les pages RAM manquantes sont récupérées à la demande (page fault réseau). |
| **Downtime** | 10 ms à 1 seconde (selon la RAM et le réseau) | ~5 ms (quasi-instantané) |
| **Durée totale** | Plus longue (doit converger) | Plus courte (bascule rapide) |
| **Danger de panne source** | ✅ Aucun : toute la RAM est déjà copiée quand on bascule | ❌ CRITIQUE : si le nœud source tombe APRÈS la bascule, les pages non encore récupérées sont PERDUES → crash de la VM |
| **Convergence** | ❌ Peut ne pas converger si le taux d'écriture > débit réseau | ✅ Pas de problème de convergence |
| **Performance après migration** | ✅ Immédiatement normale | ❌ Dégradée : chaque accès mémoire à une page pas encore transférée = page fault réseau = latence |
| **Réseau après migration** | ✅ Aucun trafic lié à la migration | ❌ Trafic continu pour récupérer les pages manquantes |
| **Support Proxmox** | ✅ Natif (`qm migrate --online`) | ❌ Non supporté — il faudrait manipuler QEMU/QMP directement |
| **Maintenance du nœud source** | ✅ Le nœud source est libéré → on peut l'éteindre | ❌ Le nœud source DOIT rester allumé pour servir les pages manquantes |
| **Complexité** | ✅ Simple (commande Proxmox native) | ❌ Très complexe (QMP, gestion d'erreurs, monitoring) |
| **VMs petites (< 4 Go RAM)** | ✅ Parfait : converge en quelques secondes | Overkill (pas besoin) |
| **VMs moyennes (4-16 Go)** | ✅ Bien : converge en 10-60 secondes | Intéressant si downtime critique |
| **VMs très grosses (64 Go+)** | ⚠️ Peut ne pas converger si écriture intensive | ✅ Idéal pour ce cas |
| **Notre cas d'usage** | ✅ **Adapté** : VMs moyennes, réseau correct, maintenance = on veut libérer le nœud | ❌ **Dangereux** : nos triggers sont des situations pré-panne (surchauffe, surcharge) → le nœud source risque de tomber PENDANT que post-copy attend encore des pages |

### Pourquoi le post-copy est DANGEREUX dans notre cas

Notre outil migre quand :
- Température CPU trop élevée → risque de **thermal shutdown** (le nœud s'éteint sans prévenir)
- CPU surchargé → risque de **freeze complet**
- RAM saturée → risque de **OOM killer** qui tue des processus

Dans ces 3 cas, **le nœud source est en danger**. Si on utilise le post-copy :

```
1. Température = 85°C → on bascule VM 101 en post-copy vers RAM
2. VM 101 tourne sur RAM mais 40% de sa mémoire est encore sur REM
3. REM atteint 95°C → THERMAL SHUTDOWN → REM s'éteint brusquement
4. VM 101 sur RAM essaie d'accéder à une page sur REM → REM est DOWN
5. → VM 101 CRASH ! Données corrompues, perte de travail
```

Avec le pre-copy :

```
1. Température = 85°C → on copie toute la RAM de VM 101 vers RAM
2. Copie terminée → petite pause → VM 101 bascule sur RAM
3. TOUTE la RAM est déjà sur RAM → REM peut tomber, on s'en fiche
4. VM 101 continue de fonctionner normalement
```

---

## 4. Pre-copy par défaut et XBZRLE optionnel

**Oui, tu as bien compris.**

L'implémentation utilise la **méthode pre-copy native de Proxmox** (`qm migrate --online`) par défaut. C'est le comportement standard, sans aucune modification.

Pour activer la compression XBZRLE, il faut modifier le fichier de configuration :

```ini
# /etc/live-migrator/live-migrator.conf
enable_xbzrle = 1
```

Ce qui se passe techniquement quand `enable_xbzrle = 1` :

1. Avant la migration, l'outil ajoute ces lignes dans `/etc/pve/qemu-server/<vmid>.conf` :
   ```
   migrate_compression: xbzrle
   migrate_compression_cache: 1638400
   ```
2. La migration `qm migrate --online` utilise alors la compression
3. Après la migration (succès ou échec), l'outil **supprime** ces lignes du fichier de config de la VM

C'est transparent : tu actives l'option une seule fois dans le fichier de config, et l'outil gère le reste automatiquement pour chaque migration.

---

## 5. Le service doit-il être réactivé après chaque redémarrage ?

**Non.** La commande `systemctl enable live-migrator` ne doit être exécutée qu'**une seule fois**. Elle crée un lien symbolique qui dit à systemd de démarrer automatiquement le service à chaque boot.

```bash
# UNE SEULE FOIS (lors de l'installation) :
systemctl enable live-migrator    # → se lance automatiquement au boot
systemctl start live-migrator     # → le lancer maintenant

# Après un redémarrage de la machine :
# Le service se lance TOUT SEUL, rien à faire
```

Le mot-clé c'est `enable` vs `start` :

| Commande | Effet | Quand l'utiliser |
|----------|-------|-----------------|
| `systemctl enable` | Configure le service pour démarrer **automatiquement au boot** | Une seule fois, à l'installation |
| `systemctl start` | Démarre le service **maintenant** | Une seule fois à l'installation, ou après un `stop` manuel |
| `systemctl disable` | Empêche le démarrage automatique au boot | Si tu veux arrêter définitivement |
| `systemctl stop` | Arrête le service **maintenant** (mais il redémarrera au prochain boot si `enable`) | Pour un arrêt temporaire |

Remarque : si le service crashe en cours de route, la directive `Restart=on-failure` dans le fichier systemd le redémarrera automatiquement après 30 secondes.

---

## 6. Les modes de lancement de live-migrator.sh

```bash
live-migrator.sh [-c config] [-f] [-h]
```

### `-c config` — Chemin vers le fichier de configuration

Par défaut, l'outil cherche sa config dans `/etc/live-migrator/live-migrator.conf`. L'option `-c` permet de spécifier un autre fichier.

**Quand c'est utile :**
- Pour tester avec une config différente sans modifier la config de production
- Si tu as plusieurs configs (une pour tests, une pour prod)

```bash
# Utiliser une config de test avec des seuils bas
live-migrator.sh -c /tmp/test-config.conf
```

### `-f` — Mode foreground (pas de daemonisation)

Normalement, le service systemd lance `live-migrator.sh` en arrière-plan (daemon). Avec `-f`, le script affiche **tout dans le terminal** au lieu de seulement écrire dans le fichier de log.

**Quand c'est utile :**
- Pour débugger : tu vois les messages en direct dans ton terminal
- Pour comprendre ce que fait le service

```bash
# Lancer en mode visible pour voir les vérifications en direct
live-migrator.sh -f
# → Tu vois les logs défiler dans ton terminal
# → Ctrl+C pour arrêter
```

### `-h` — Aide

Affiche le message d'aide avec toutes les options disponibles.

### `--check` — Mode diagnostic (non listé dans l'usage de base)

Lance **une seule** vérification (pas de boucle) et affiche les résultats :

```bash
live-migrator.sh --check
# === System Metrics ===
#   Temperature: 42°C (threshold: 80°C)
#   CPU Usage:   15% (threshold: 90%)
#   RAM Usage:   34% (threshold: 90%)
#   Local VMs:   2
#
# === Best Target Node ===
#   Target: ram
```

**C'est le mode le plus utile pour tester** sans risquer de déclencher de migration.

### Résumé

En pratique, tu n'auras jamais besoin de ces options. Le service systemd lance automatiquement `live-migrator.sh -c /etc/live-migrator/live-migrator.conf`. Les options `-f` et `--check` sont pour le debug/test.

---

## 7. Migration vers plusieurs nœuds — comment ça décide ?

### Migration automatique (daemon)

En mode automatique (quand un seuil est dépassé), l'outil migre **UNE SEULE VM à la fois** (la plus grosse consommatrice, voir question 8). Il ne migre pas vers plusieurs nœuds en une seule fois.

**Comment le nœud cible est choisi :**

```
Pour chaque nœud du cluster (sauf le nœud local) :
  1. Vérifier qu'il est en ligne (via pvesh)
  2. Récupérer la RAM libre de ce nœud
  → Choisir celui qui a LE PLUS DE RAM LIBRE
```

C'est l'algorithme de la fonction `select_best_target()` dans le code. C'est un choix simple et efficace : le nœud avec le plus de RAM libre est le plus capable d'accueillir une VM supplémentaire.

**Il n'y a pas de configuration par VM pour dire "cette VM va sur ce nœud".** C'est automatique et basé sur la RAM libre.

### Mode maintenance

En mode maintenance (`migrator-ctl.sh maintenance`), **toutes les VMs** sont migrées. Pour chaque VM, le nœud cible est recalculé :

```
VM 101 (8 Go) → select_best_target() → RAM a 20 Go libre → VM 101 → RAM
VM 102 (4 Go) → select_best_target() → REM a 15 Go libre, RAM n'a plus que 12 Go → VM 102 → REM
VM 103 (2 Go) → select_best_target() → RAM a 12 Go libre, REM a 11 Go → VM 103 → RAM
```

Le calcul est refait **avant chaque migration**, donc il tient compte des VMs déjà migrées.

### Forcer un nœud cible

Si tu veux forcer toutes les VMs vers un nœud spécifique :

```bash
migrator-ctl.sh maintenance ram    # Tout va vers "ram"
```

Ou pour une VM spécifique :

```bash
migrator-ctl.sh migrate 101 rem    # VM 101 → rem
```

---

## 8. Quelle VM migrer quand le seuil est dépassé ?

Quand un seuil est dépassé, l'outil doit choisir **laquelle** des VMs locales migrer. La logique est dans la fonction `select_vm_to_migrate()` :

### Règle : on migre la VM qui consomme le plus de la ressource en surcharge

| Ressource en surcharge | VM migrée |
|----------------------|-----------|
| **Température CPU** ou **charge CPU** | La VM qui utilise le **plus de CPU** |
| **RAM** | La VM qui utilise le **plus de RAM** |

### Comment ça marche concrètement

```
Exemple : seuil RAM = 90%, RAM hôte = 92%

Nœud REM a 3 VMs :
  VM 101 = 6 Go de RAM utilisée  ← MIGRÉE EN PREMIER (plus grosse)
  VM 102 = 3 Go de RAM utilisée
  VM 103 = 1 Go de RAM utilisée

→ L'outil migre VM 101 (6 Go) car c'est elle qui libérera le plus de RAM
→ Après migration, la RAM de REM baisse de ~6 Go
→ Si c'est suffisant pour repasser sous 90% → fini
→ Sinon, après le cooldown (5 min), une nouvelle vérification
   → Si RAM encore > 90% → migre VM 102 (3 Go)
```

### Et si la VM la plus grosse ne passe pas sur le nœud cible ?

Actuellement, l'outil **ne vérifie pas** que le nœud cible a assez de RAM pour la VM. C'est Proxmox qui refusera la migration avec l'erreur "not enough memory". Dans ce cas :

- La migration échoue et est loggée comme `FAILED`
- L'outil ne réessaie pas immédiatement (cooldown)
- L'admin peut intervenir manuellement

> **Note :** C'est une amélioration possible (voir question 13).

---

## 9. GPU passthrough et live migration

### Live migration avec GPU passthrough : ça ne marche PAS

**Réponse courte : NON, la live migration ne fonctionne pas avec le GPU en passthrough.**

**Pourquoi :**

Le GPU passthrough (PCI passthrough / VFIO) consiste à donner à la VM un accès **direct et exclusif** au GPU physique. La VM contrôle directement le matériel GPU.

Pendant une live migration, il faut copier l'**état complet** de la VM vers un autre nœud. Or :
- L'état interne du GPU (mémoire VRAM, registres, contextes de calcul) ne peut **pas** être sérialisé et transféré
- Le GPU du nœud cible est un matériel physique **différent**, potentiellement un modèle différent
- Il n'existe pas de standard pour "migrer" un état GPU d'un matériel à un autre
- QEMU/KVM ne supportent tout simplement pas la migration des périphériques PCI passthrough

**Ce qui se passe si tu essaies :**

```bash
qm migrate 101 ram --online
# Erreur : "can't migrate VM with PCI passthrough devices"
```

Proxmox bloquera la migration **avant même de commencer**. Ça ne causera pas de crash, mais la migration sera refusée. Ça vaut autant pour le bouton dans l'interface web que pour la commande en terminal.

### Et le HA (High Availability) avec GPU passthrough ?

**Le HA peut redémarrer la VM sur un autre nœud, MAIS :**

1. **Le GPU ne sera PAS en passthrough sur le nouveau nœud** sauf si :
   - Le nouveau nœud a exactement le même modèle de GPU
   - Le GPU est configuré dans le BIOS/IOMMU du nouveau nœud
   - La config de la VM référence un GPU disponible sur le nouveau nœud

2. **En pratique :** Si le nœud REM avec un GPU en passthrough tombe, le HA essaiera de redémarrer la VM sur RAM ou EMILIA. Mais si ces nœuds n'ont pas de GPU compatible ou configuré pour le passthrough, la VM **ne pourra pas démarrer** avec la config GPU. Le HA échouera.

3. **Cas où ça pourrait marcher :**
   - Si TOUS les nœuds ont le même GPU et la même config IOMMU
   - La VM utilise une configuration GPU "agnostique" (via un pool de GPU identiques)
   - C'est très rare en pratique

### Impact sur notre outil

Notre outil appelle `qm migrate --online`. Si la VM a un GPU passthrough, Proxmox refusera la migration. L'outil loggera une erreur `FAILED` et passera à autre chose (grâce au cooldown). **Aucun crash.**

---

## 10. Automatiser le basculement pre-copy ↔ post-copy

### La demande

Tu souhaites que l'outil bascule **automatiquement** entre pre-copy et post-copy en fonction de la taille de la RAM de la VM (ex: > 10 Go → post-copy).

### Pourquoi ce n'est PAS faisable actuellement

| Blocage | Explication |
|---------|-------------|
| ❌ Proxmox ne supporte pas le post-copy | `qm migrate --online` fait TOUJOURS du pre-copy. Il n'y a pas d'option `--postcopy`. |
| ❌ Implémenter le post-copy nécessite QMP | Il faudrait parler directement au processus QEMU via le socket QMP, en contournant complètement Proxmox. |
| ❌ Risque de corruption | Le post-copy est dangereux si le nœud source est instable (voir question 3). |
| ❌ Complexité disproportionnée | Implémenter un gestionnaire QMP complet en Bash est irréaliste (il faudrait du Python, avec gestion d'erreurs, timeouts, monitoring...). |

### Ce qu'on peut faire à la place

**Amélioration réaliste :** Au lieu de basculer entre pre-copy et post-copy, on peut améliorer le pre-copy pour les grosses VMs :

| Amélioration | Comment | Effet |
|-------------|---------|-------|
| **XBZRLE auto** | Si VM > X Go de RAM → activer automatiquement XBZRLE | Meilleure convergence |
| **Downtime adaptatif** | Si VM > X Go → augmenter `migrate_downtime` (de 100ms à 500ms) | Convergence plus rapide au prix de quelques ms de pause supplémentaire |
| **Bande passante** | Si VM > X Go → ne pas limiter la bande passante (`migrate_speed: 0`) | Transfert le plus rapide possible |

Ces améliorations restent dans le cadre de Proxmox natif et sont sûres.

### Pour plus tard (vraie production)

Si un jour tu as réellement des VMs de 64 Go+ avec des taux d'écriture extrêmes et que le pre-copy ne converge pas, la solution serait :

1. Écrire un module Python séparé qui communique avec QEMU via QMP
2. Implémenter la séquence post-copy QMP (`migrate -d`, `migrate_start_postcopy`)
3. Ajouter un monitoring en temps réel de la migration
4. Gérer les erreurs et le fallback vers pre-copy

C'est un projet en soi, pas un ajout rapide au script Bash actuel.

---

## 11. Verrouillage (lock) de la VM pendant la migration

### Qu'est-ce que le lock ?

Quand Proxmox lance une migration, il pose un **verrou (lock)** sur la VM dans la base de données du cluster (`/etc/pve`). Ce verrou empêche les **opérations administratives** sur la VM, PAS son utilisation.

### Ce que le lock empêche (opérations admin)

- Supprimer la VM
- Changer sa configuration (ajouter un disque, modifier la RAM...)
- Prendre un snapshot
- Lancer une **autre** migration en parallèle
- Arrêter/redémarrer la VM via l'interface

### Ce que le lock N'empêche PAS (utilisation normale)

- **L'utilisateur continue d'utiliser sa machine normalement** ✅
- Les applications continuent de tourner ✅
- Le réseau continue de fonctionner ✅
- Les fichiers sont accessibles ✅
- Les connexions SSH/RDP restent actives ✅

### Le seul moment d'interruption

Le seul moment où l'utilisateur peut percevoir quelque chose, c'est la **micropause finale** (phase 3 du pre-copy) :

```
Phase 1-2 : VM tourne normalement → l'utilisateur ne remarque RIEN
Phase 3   : PAUSE de la VM (~10-500ms) → micro-freeze imperceptible
Phase 4   : VM reprend sur le nouveau nœud → tout est normal
```

En pratique, sur un bon réseau, cette pause est de **10 à 200 ms**. L'utilisateur ne le remarque même pas (un clic de souris prend ~100ms).

---

## 12. Dashboard de métriques basique — qu'est-ce que ça veut dire ?

Dans le tableau "Ce que Proxmox NE sait PAS faire nativement", la ligne :

> | Dashboard de métriques pour décision | ❌ Basique |

Cela signifie que l'interface web de Proxmox offre des graphiques de métriques (CPU, RAM, réseau) pour chaque nœud et chaque VM, **mais** :

| Ce que Proxmox a | Ce qui manque |
|------------------|---------------|
| Graphiques CPU/RAM par VM | ❌ Pas de vue "quel nœud est en surcharge et quelle VM migrer" |
| Graphiques par nœud | ❌ Pas de comparaison côte-à-côte des nœuds |
| Historique de métriques | ❌ Pas de corrélation métriques → migration |
| Alertes basiques (mail) | ❌ Pas de recommandation automatique de migration |

**"Basique"** = Proxmox te donne les chiffres, mais ne t'aide pas à prendre la décision. C'est à toi de regarder 3 écrans, comparer, et décider. Notre outil automatise cette décision.

---

## 13. Fallback si aucun nœud ne peut accueillir la plus grosse VM

### Le problème

```
Nœud REM en surcharge RAM :
  VM 101 = 12 Go (plus grosse)
  VM 102 = 4 Go
  VM 103 = 2 Go

Nœuds cibles :
  RAM : 8 Go libres → NE PEUT PAS accueillir VM 101 (12 Go)
  EMILIA : 6 Go libres → NE PEUT PAS accueillir VM 101 (12 Go)
```

### Comportement actuel

Actuellement, l'outil sélectionne la plus grosse VM (101) et tente la migration. Proxmox refuse avec "not enough memory". La migration est loggée comme `FAILED`, et le cooldown s'active.

**C'est effectivement un cas non géré.** L'outil ne fait PAS de fallback vers la deuxième VM.

### Amélioration prévue

L'amélioration idéale serait de modifier `select_vm_to_migrate()` pour implémenter un **fallback** :

```
1. Lister les VMs triées par consommation (décroissant)
2. Pour chaque VM (de la plus grosse à la plus petite) :
   a. Vérifier si le meilleur nœud cible a assez de RAM libre
   b. Si oui → migrer cette VM → FIN
   c. Si non → passer à la VM suivante
3. Si aucune VM ne peut être migrée → logger l'erreur
```

**Pour l'instant, en attendant cette amélioration :** si le cas se présente, l'admin peut migrer manuellement une petite VM :

```bash
migrator-ctl.sh migrate 103 ram    # Migrer la petite VM 103 (2 Go) manuellement
```

---

## 14. Installation sur le vrai cluster (REM, RAM, EMILIA)

### Les dépendances

Les dépendances (`qm`, `pvesh`, `python3`, `bash`) sont **déjà installées** sur chaque nœud Proxmox. Tu n'as rien à installer manuellement. Le script `install.sh` les vérifie juste par sécurité, mais ne les installe pas.

### Comment transférer et installer sur le cluster

Tu es connecté au cluster via ton navigateur web (interface Proxmox). Voici comment installer le live-migrator :

#### Méthode 1 : Via SSH depuis ton laptop (RECOMMANDÉE)

```bash
# 1. Depuis ton laptop, copier le dossier vers le nœud REM
scp -r /chemin/vers/live-migrator root@<IP_REM>:/opt/live-migrator

# 2. Se connecter en SSH au nœud REM
ssh root@<IP_REM>

# 3. Installer sur REM
cd /opt/live-migrator
chmod +x scripts/install.sh
./scripts/install.sh
systemctl enable live-migrator
systemctl start live-migrator

# 4. Copier et installer sur RAM
scp -r /opt/live-migrator root@ram:/opt/live-migrator
ssh root@ram "cd /opt/live-migrator && ./scripts/install.sh && systemctl enable live-migrator && systemctl start live-migrator"

# 5. Copier et installer sur EMILIA
scp -r /opt/live-migrator root@emilia:/opt/live-migrator
ssh root@emilia "cd /opt/live-migrator && ./scripts/install.sh && systemctl enable live-migrator && systemctl start live-migrator"
```

#### Méthode 2 : Via le Shell de l'interface Proxmox

L'interface web Proxmox a un **shell intégré** (cliquer sur le nœud → Shell). Tu peux y coller des commandes.

```bash
# 1. Sur le nœud REM, via le shell web :
# Créer le répertoire
mkdir -p /opt/live-migrator

# 2. Option A : Télécharger depuis un dépôt Git (si disponible)
cd /opt && git clone <URL_DU_REPO> live-migrator

# 2. Option B : Copier les fichiers manuellement (coller dans le shell)
# Tu peux créer chaque fichier avec cat << 'EOF' > fichier ... EOF
# Mais c'est fastidieux — la méthode SSH est bien plus simple
```

#### Méthode 3 : Clé USB (si pas d'accès SSH direct)

```bash
# 1. Copier le dossier sur une clé USB
# 2. Brancher la clé sur le serveur
# 3. Monter la clé et copier
mount /dev/sdb1 /mnt
cp -r /mnt/live-migrator /opt/
umount /mnt
# 4. Installer normalement
cd /opt/live-migrator && ./scripts/install.sh
```

### Résumé de l'installation sur les 3 nœuds

| Étape | Commande | Sur quel nœud |
|-------|----------|---------------|
| Copier les sources | `scp -r` | Depuis ton laptop → chaque nœud |
| Installer | `./scripts/install.sh` | Sur chaque nœud |
| Activer le service | `systemctl enable --now live-migrator` | Sur chaque nœud |
| Vérifier | `migrator-ctl.sh status` | Sur chaque nœud |

L'installation totale prend ~5 minutes pour les 3 nœuds.

---

## 15. Ne pas éditer le README existant

✅ Confirmé. Ce document FAQ est un fichier séparé (`FAQ.md`). Le fichier `README.md` existant n'a pas été modifié.
