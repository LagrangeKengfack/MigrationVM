# VMState Guardian

**Migration à froid avec reprise du dernier état mémoire — Proxmox VE**

Démon C externe qui se place au-dessus du HA Proxmox pour capturer périodiquement l'état mémoire des VM et le restaurer automatiquement après un redémarrage HA sur un autre nœud.

---

## Table des matières

1. [Mise en contexte](#1-mise-en-contexte)
2. [Architecture globale](#2-architecture-globale)
3. [Activation du HA dans le cluster Proxmox](#3-activation-du-ha-dans-le-cluster-proxmox)
4. [Snapshot mémoire — description technique](#4-snapshot-mémoire--description-technique)
5. [Reprise automatique après redémarrage HA](#5-reprise-automatique-après-redémarrage-ha)
6. [Procédure d'installation complète](#6-procédure-dinstallation-complète)
7. [Procédure de test réelle sur le cluster](#7-procédure-de-test-réelle-sur-le-cluster)
8. [Dépannage / Troubleshooting](#8-dépannage--troubleshooting)
9. [Références](#9-références)

---

## 1. Mise en contexte

### Problème

Dans un cluster Proxmox, quand un nœud physique tombe en panne, le **HA (Haute Disponibilité)** de Proxmox redémarre automatiquement les VM sur un autre nœud. Mais ce redémarrage est une **reprise à froid** : la VM repart depuis zéro, perdant tout l'état en mémoire (RAM, registres CPU, connexions réseau, etc.).

### Objectif

Minimiser la perte d'état en capturant périodiquement **l'état mémoire complet** de la VM et en le restaurant automatiquement après un redémarrage HA. L'utilisateur perd au maximum l'état des dernières secondes (l'intervalle entre deux captures).

### Rôle des composants

| Composant | Rôle |
|-----------|------|
| **HA Proxmox** | Détecte la panne d'un nœud, redémarre la VM sur un autre nœud (reprise à froid) |
| **VMState Guardian** | Capture périodiquement l'état mémoire, détecte le redémarrage HA, restaure le dernier état |

### Hypothèses

- Cluster Proxmox de 3 nœuds : **Emilia**, **RAM**, **REM** (fonctionne aussi avec 2+ nœuds)
- Disques VM sur **stockage partagé** (Ceph RBD recommandé)
- Le code interne du HA Proxmox n'est **pas** modifié
- Le démon est déployé sur **chaque nœud** du cluster
- Root access sur tous les nœuds

### Limites

- **Interruption visible** : même avec la restauration, l'utilisateur subira une coupure (temps de détection HA + temps de restauration)
- **Connexions TCP perdues** : les connexions réseau actives (SSH, HTTP, base de données) seront brisées car les machines distantes auront fermé leur côté
- **Saut d'horloge** : la VM restaurée croit être à l'heure du snapshot, NTP corrigera mais les applications peuvent voir une incohérence temporaire
- **Pas de GPU** : la migration de l'état GPU n'est pas couverte

---

## 2. Architecture globale

### Schéma du système

```
┌──────────────────────────────────────────────────────────────────┐
│                        Cluster Proxmox                           │
│                                                                  │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐       │
│  │   EMILIA    │     │     RAM     │     │     REM     │       │
│  │             │     │             │     │             │       │
│  │  vmstate-   │     │  vmstate-   │     │  vmstate-   │       │
│  │  guardian   │     │  guardian   │     │  guardian   │       │
│  │  (démon)    │     │  (démon)    │     │  (démon)    │       │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘       │
│         │                   │                   │               │
│         └───────────────────┼───────────────────┘               │
│                             │                                    │
│                    ┌────────▼─────────┐                         │
│                    │   Ceph (Shared)  │                         │
│                    │   - VM disks     │                         │
│                    │   - vmstate      │                         │
│                    │     files        │                         │
│                    └──────────────────┘                         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    HA Proxmox                             │   │
│  │  Surveille les nœuds, redémarre les VM si panne détectée │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### Flux normal (snapshot périodique)

```
Boucle toutes les N secondes :
  1. Vérifier si la VM tourne sur CE nœud
     → Non : dormir et recommencer
     → Oui : continuer
  2. Capturer l'état mémoire (mode QMP pre-copy ou qm snapshot)
  3. Supprimer l'ancien état / renommer atomiquement
  4. Journaliser
```

### Flux de panne (failover HA + restauration)

```
  1. Le nœud source tombe en panne
  2. HA Proxmox détecte la panne (~30-60s)
  3. HA redémarre la VM sur un autre nœud (démarrage à froid)
  4. Le démon sur le nouveau nœud détecte :
     "La VM tourne ICI mais le dernier nœud connu était DIFFÉRENT"
  5. → Arrête la VM fraîchement démarrée
  6. → Charge le dernier état mémoire sauvegardé
  7. → Redémarre la VM avec l'état restauré
  8. → Met à jour le nœud connu
  9. → Reprend les snapshots périodiques
```

### Rôle de chaque nœud

Chaque nœud exécute le même démon. Le démon est **actif** (snapshot) uniquement sur le nœud où la VM tourne. Sur les autres nœuds, il est en **veille** (vérification toutes les 5 secondes).

### Deux modes de fonctionnement

| | Mode QMP pre-copy (recommandé) | Mode QM savevm (fallback) |
|---|---|---|
| **Commande** | QMP `migrate exec:...` | `qm snapshot --vmstate 1` |
| **Pause VM** | ~10-500 ms | ~2-16 s (selon taille RAM) |
| **Restore** | `-incoming` + QMP `cont` | `qm rollback` + `qm start` |
| **Complexité** | Élevée | Simple |

Le **mode QMP** est recommandé car il minimise la pause de la VM pendant la capture.

---

## 3. Activation du HA dans le cluster Proxmox

### 3.1 Prérequis

- Cluster Proxmox fonctionnel avec au moins 2 nœuds (3 recommandé pour le quorum)
- Stockage partagé configuré (Ceph, NFS, iSCSI, etc.)
- Réseau Corosync fonctionnel entre les nœuds
- VM créée sur le stockage partagé

### 3.2 Vérifier que le cluster est sain

```bash
# Statut du cluster
pvecm status

# Résultat attendu : tous les nœuds listés avec "established"
# Vérifier le quorum
pvecm expected 1  # Ne PAS exécuter, juste vérifier le nombre de votes
```

```bash
# Vérifier que tous les nœuds se voient
pvecm nodes

# Résultat attendu : 3 nœuds listés (emilia, ram, rem)
```

```bash
# Vérifier le stockage partagé
pvesm status

# Le stockage doit apparaître comme "active" sur tous les nœuds
```

### 3.3 Vérifier/activer le HA Manager

```bash
# Le service HA est intégré à Proxmox et démarre automatiquement
systemctl status pve-ha-lrm
systemctl status pve-ha-crm

# S'assurer qu'ils sont actifs
systemctl enable pve-ha-lrm
systemctl enable pve-ha-crm
```

### 3.4 Créer un groupe HA

Le groupe HA définit quels nœuds peuvent héberger la VM.

```bash
# Créer le groupe "grp-migration" avec les 3 nœuds
ha-manager groupadd grp-migration --nodes emilia,ram,rem

# Vérifier
ha-manager groupconfig grp-migration
```

Options du groupe :
```bash
# Restreindre à certains nœuds uniquement
ha-manager groupadd grp-migration --nodes emilia,ram,rem --restricted 1

# Définir un nœud prioritaire
ha-manager groupadd grp-migration --nodes emilia:2,ram:1,rem:1
# emilia a la priorité 2 (plus haute), ram et rem ont la priorité 1
```

### 3.5 Ajouter une VM au HA

```bash
# Ajouter la VM 101 au groupe HA
ha-manager add vm:101 --group grp-migration

# Vérifier
ha-manager config
```

Options supplémentaires :
```bash
# Définir le nombre max de redémarrages
ha-manager add vm:101 --group grp-migration --max_restart 3

# Définir le nombre max de relocalisations
ha-manager add vm:101 --group grp-migration --max_relocate 3
```

### 3.6 Politique de redémarrage

```bash
# Changer l'état demandé (started = redémarrer automatiquement si arrêtée)
ha-manager set vm:101 --state started

# Autres états possibles :
# started   = VM doit tourner, HA la redémarre si elle s'arrête
# stopped   = VM doit être arrêtée
# ignored   = HA ignore cette VM
# disabled  = HA désactivé pour cette VM
```

### 3.7 Vérification que le HA est opérationnel

```bash
# Statut global du HA
ha-manager status

# Résultat attendu :
# quorum OK, master emilia
# vm:101 started emilia
```

```bash
# Statut détaillé
cat /etc/pve/ha/resources.cfg
cat /etc/pve/ha/groups.cfg
```

### 3.8 Commandes de diagnostic

```bash
# Voir les logs HA
journalctl -u pve-ha-crm -f
journalctl -u pve-ha-lrm -f

# Voir le journal HA spécifique
tail -f /var/log/pve/ha-manager/current

# Vérifier le quorum
pvecm expected
corosync-quorumtool -s

# Surveiller en temps réel
watch -n 1 'ha-manager status'
```

### 3.9 Test rapide du HA

```bash
# Sur le nœud où la VM tourne, simuler une panne avec fence
# ATTENTION : cela va arrêter le nœud !
# Méthode douce : arrêter le service cluster
systemctl stop pve-cluster

# Méthode réelle : reboot
reboot

# Observer depuis un AUTRE nœud :
watch -n 1 'ha-manager status'
# La VM devrait migrer vers un autre nœud après ~60 secondes
```

### 3.10 Problèmes fréquents

| Problème | Cause | Solution |
|----------|-------|----------|
| "no quorum" | Moins de la moitié +1 des nœuds disponibles | Vérifier réseau corosync, remettre les nœuds en ligne |
| VM ne redémarre pas | max_restart atteint | `ha-manager set vm:101 --state started` |
| HA disabled | Service pas démarré | `systemctl start pve-ha-crm pve-ha-lrm` |
| "fence failed" | Pas de mécanisme de fencing | Configurer le fencing (IPMI, etc.) |
| VM bloquée en "migrate" | Migration interrompue | `ha-manager set vm:101 --state started` |

---

## 4. Snapshot mémoire — description technique

### 4.1 Principe

Un **snapshot avec état mémoire** capture :
- L'état complet de la RAM de la VM
- L'état des registres CPU (vCPU)
- L'état des périphériques virtuels (réseau, disque, etc.)
- Un point-dans-le-temps du disque (négligeable sur Ceph grâce au copy-on-write)

### 4.2 Deux mécanismes de capture

#### Mode QM (`qm snapshot --vmstate 1`)
- Utilise `savevm` de QEMU en interne
- **Pause la VM pendant TOUTE la durée** de l'écriture de la RAM sur disque
- Durée ≈ taille_RAM / vitesse_écriture_stockage

| RAM | SSD (~500 MB/s) | NVMe (~2 GB/s) |
|-----|-----------------|-----------------|
| 2 Go | ~4 s | ~1 s |
| 4 Go | ~8 s | ~2 s |
| 8 Go | ~16 s | ~4 s |

#### Mode QMP pre-copy (`migrate exec:...`)
- Utilise le mécanisme de **migration avec pre-copy** de QEMU
- La VM **continue de tourner** pendant le transfert de la majeure partie de la RAM
- Seule la phase finale (dernières pages sales) nécessite une pause
- **Pause réelle : ~10-500 ms** pour une charge de travail typique

Phases du pre-copy :
```
Phase 1 : VM TOURNE → copie de toute la RAM vers le fichier
Phase 2 : VM TOURNE → re-copie des pages modifiées (dirty pages)
Phase 3 : VM PAUSE  → copie des dernières pages sales (~10-500 ms)
Phase 4 : VM REPREND → commande "cont" envoyée via QMP
```

### 4.3 Algorithme du cycle de snapshot

```
BOUCLE toutes les snapshot_interval secondes :
  SI mode == QMP :
    1. Connecter au socket QMP : /var/run/qemu-server/<vmid>.qmp
    2. Envoyer : {"execute":"migrate","arguments":{"uri":"exec:cat > <path>/new.state"}}
    3. Interroger query-migrate toutes les secondes
    4. Quand status == "completed" : envoyer "cont"
    5. Renommer atomiquement new.state → latest.state
    6. Écrire fichier timestamp
  
  SI mode == QM :
    1. Exécuter : qm snapshot <vmid> vsg-<timestamp> --vmstate 1
    2. Supprimer l'ancien snapshot vsg-* si existant
```

### 4.4 Stratégie de rotation

**Un seul snapshot est conservé à tout moment.**

- **Mode QMP** : écriture dans `new.state` puis renommage atomique vers `latest.state`. Si le démon plante pendant l'écriture, l'ancien `latest.state` reste intact.
- **Mode QM** : le nouveau snapshot est créé avant la suppression de l'ancien. En cas d'échec de la création, l'ancien reste disponible.

### 4.5 Structure des fichiers

**Mode QMP :**
```
/var/lib/vmstate-guardian/vmstate/   (doit être sur stockage partagé)
├── latest.state     # État mémoire le plus récent
├── new.state        # Écriture en cours (temporaire)
└── timestamp        # Unix timestamp du dernier snapshot
```

**Mode QM :**
Les snapshots sont internes au fichier qcow2/RBD, nommés `vsg-<unix_timestamp>`.

### 4.6 Nommage

- Préfixe `vsg-` pour identifier les snapshots du démon
- Suffixe : timestamp Unix (ex: `vsg-1713362400`)
- Permet de distinguer les snapshots du démon des snapshots manuels de l'utilisateur

### 4.7 Persistance et synchronisation inter-nœuds

- **Les fichiers d'état** (`latest.state`, snapshots internes qcow2) sont sur le **stockage partagé** (Ceph)
- **Aucune synchronisation manuelle** nécessaire : le stockage partagé rend les fichiers accessibles depuis tout nœud
- **Le fichier `last_node`** (dans `state_dir`) est sur stockage **local** — c'est intentionnel : chaque nœud maintient sa propre vision du dernier nœud connu

### 4.8 Risques de corruption / incohérence

| Risque | Probabilité | Mitigation |
|--------|-------------|------------|
| Panne pendant l'écriture du snapshot | Faible | Renommage atomique (QMP) / ancien snapshot conservé (QM) |
| État mémoire incohérent avec le disque | Très faible | Le snapshot capture un instant cohérent (VM pausée brièvement) |
| Fichier d'état tronqué | Faible | Vérification de la taille avant restauration |
| QMP socket inaccessible | Moyen | Retry + fallback vers sleep |

### 4.9 Impact sur les performances

- **CPU** : ~5-15% pendant le pre-copy (transfert mémoire en arrière-plan)
- **I/O** : écriture de `taille_RAM` octets à chaque cycle
- **Réseau** : aucun impact (tout est local / stockage)
- **VM** : pause de ~10-500ms en mode QMP, ~2-16s en mode QM

### 4.10 Conditions de validité

Pour qu'un snapshot soit valide à la restauration :
1. Le fichier doit être complet (pas tronqué)
2. La configuration VM doit être identique (même nombre de vCPU, même taille RAM, mêmes devices)
3. Le disque doit être dans un état compatible (sur stockage partagé, c'est automatique)
4. La version de QEMU doit être compatible (même cluster Proxmox = OK)

---

## 5. Reprise automatique après redémarrage HA

### 5.1 Comment détecter un redémarrage HA

Le démon compare **le nœud actuel de la VM** avec **le dernier nœud connu** :

```
nœud_courant = hostname de ce serveur
nœud_vm = pvesh get /cluster/resources → nœud de la VM
dernier_nœud = contenu de /var/lib/vmstate-guardian/last_node

SI nœud_vm == nœud_courant ET dernier_nœud != nœud_courant :
    → FAILOVER DÉTECTÉ
```

### 5.2 Comment savoir sur quel nœud la VM a redémarré

La commande `pvesh get /cluster/resources --type vm` retourne un JSON contenant le `node` de chaque VM. Le démon extrait le nœud correspondant au VMID configuré.

### 5.3 Comment retrouver le dernier snapshot

- **Mode QMP** : vérifier l'existence et la taille de `<vmstate_path>/latest.state`
- **Mode QM** : parser la sortie de `qm listsnapshot <vmid>` pour trouver le dernier `vsg-*` par timestamp

### 5.4 Déclenchement de la restauration

1. Arrêter la VM démarrée par HA : `qm stop <vmid>`
2. Attendre l'arrêt complet (5 secondes)
3. **Mode QMP** :
   - Injecter `args: -incoming "exec:cat <state_file>"` dans la config VM
   - Démarrer : `qm start <vmid>` (QEMU charge l'état depuis le fichier)
   - Envoyer `cont` via QMP pour reprendre la VM
   - Retirer les `args` de la config
4. **Mode QM** :
   - Rollback : `qm rollback <vmid> <snap_name>`
   - Démarrer : `qm start <vmid>`

### 5.5 Protection contre les boucles infinies

| Mécanisme | Fichier | Description |
|-----------|---------|-------------|
| **Lock temporel** | `restore.lock` | Si le dernier restore date de moins de `restore_cooldown` secondes → bloqué |
| **Compteur** | `restore_count` | Après `max_restore_attempts` tentatives consécutives → bloqué |
| **Reset** | — | Le compteur est remis à 0 après un restore réussi |

Si le compteur est atteint, le démon log une erreur et l'administrateur doit intervenir manuellement.

### 5.6 Protection contre un snapshot invalide

Avant de tenter la restauration :
- Vérifier que le fichier d'état existe
- Vérifier que sa taille est > 0
- Vérifier que la VM est bien arrêtée après le `qm stop`
- Après restauration, vérifier que le statut de la VM est `running`

### 5.7 Journalisation

Chaque étape est journalisée dans :
- **Syslog** (accessible via `journalctl -u vmstate-guardian`)
- **Fichier dédié** (`/var/log/vmstate-guardian.log`)

Exemple de log :
```
[2026-04-17 14:30:05] [WARN] FAILOVER DETECTED: VM 101 moved from emilia to ram
[2026-04-17 14:30:05] [INFO] Stopping VM 101 for state restore
[2026-04-17 14:30:10] [INFO] Setting VM args: -incoming "exec:cat /ceph/vmstate/101/latest.state"
[2026-04-17 14:30:10] [INFO] Starting VM 101 with incoming state
[2026-04-17 14:30:25] [INFO] Sending 'cont' to resume VM
[2026-04-17 14:30:28] [INFO] VM 101 is running with restored state
[2026-04-17 14:30:28] [INFO] Restore completed successfully
```

### 5.8 Vérification du succès

Après restauration, le démon vérifie :
1. `qm status <vmid>` retourne `running`
2. Si oui → sauvegarde du nouveau nœud dans `last_node`, reset du compteur
3. Si non → incrémente le compteur d'échec, log une erreur

---

## 6. Procédure d'installation complète

### 6.1 Dépendances système

Le démon nécessite uniquement :
- **gcc** (compilateur C)
- **make** (système de build)
- **Proxmox VE** (pour `qm`, `pvesh`, `ha-manager`)

```bash
# Sur chaque nœud Proxmox (Debian-based)
apt update
apt install -y build-essential
```

### 6.2 Récupérer les sources

```bash
# Copier le répertoire vmstate-guardian sur chaque nœud
# Par exemple via scp :
scp -r vmstate-guardian/ root@emilia:/opt/
scp -r vmstate-guardian/ root@ram:/opt/
scp -r vmstate-guardian/ root@rem:/opt/
```

### 6.3 Compilation

```bash
cd /opt/vmstate-guardian
make clean
make
```

Résultat : binaire `vmstate-guardian` dans le répertoire courant.

### 6.4 Installation automatique

```bash
chmod +x scripts/install.sh
sudo ./scripts/install.sh
```

### 6.5 Installation manuelle

```bash
# Installer le binaire
sudo install -m 755 vmstate-guardian /usr/local/sbin/

# Créer le répertoire de configuration
sudo mkdir -p /etc/vmstate-guardian
sudo cp conf/vmstate-guardian.conf /etc/vmstate-guardian/

# Créer les répertoires de données
sudo mkdir -p /var/lib/vmstate-guardian/vmstate

# Installer le service systemd
sudo cp systemd/vmstate-guardian.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### 6.6 Configuration

Éditer `/etc/vmstate-guardian/vmstate-guardian.conf` :

```ini
[general]
# IMPORTANT : mettre l'ID de votre VM
vmid = 101

# Mode : "qmp" (recommandé) ou "qm"
mode = qmp

[snapshot]
# Intervalle entre snapshots en secondes
snapshot_interval = 60

[paths]
# IMPORTANT : ce chemin DOIT être sur le stockage partagé (Ceph)
# Exemple avec un montage Ceph :
vmstate_path = /mnt/pve/cephfs/vmstate/101
```

**Points critiques :**
- `vmstate_path` **DOIT** être sur le stockage partagé pour que la restauration fonctionne sur un autre nœud
- Le `vmid` doit correspondre à la VM configurée en HA
- Le mode `qmp` est recommandé pour minimiser la pause de la VM

### 6.7 Activation

```bash
# Faire sur CHAQUE nœud du cluster
sudo systemctl enable vmstate-guardian
sudo systemctl start vmstate-guardian
```

### 6.8 Vérification

```bash
# Statut du service
sudo systemctl status vmstate-guardian

# Logs en temps réel
sudo journalctl -u vmstate-guardian -f

# Fichier de log
sudo tail -f /var/log/vmstate-guardian.log

# Vérifier que les snapshots sont créés
# Mode QM :
qm listsnapshot 101

# Mode QMP :
ls -la /mnt/pve/cephfs/vmstate/101/
```

---

## 7. Procédure de test réelle sur le cluster

### Test 1 : Fonctionnement normal du snapshot

**Objectif :** vérifier que le démon crée des snapshots périodiques.

**Préconditions :**
- VM 101 en état `running` sur un nœud (ex: Emilia)
- Démon installé et démarré sur tous les nœuds

**Commandes :**
```bash
# Sur Emilia, démarrer en mode foreground pour observer
sudo /usr/local/sbin/vmstate-guardian -f -c /etc/vmstate-guardian/vmstate-guardian.conf

# Attendre 2 intervalles (ex: 2 minutes si interval=60)
# Observer les logs
```

**Résultat attendu :**
- Un message "Snapshot cycle completed" toutes les 60 secondes
- Mode QMP : fichier `latest.state` créé dans `vmstate_path`
- Mode QM : snapshot `vsg-*` visible via `qm listsnapshot 101`

**Vérification :**
```bash
# Mode QMP
ls -la /mnt/pve/cephfs/vmstate/101/latest.state
cat /mnt/pve/cephfs/vmstate/101/timestamp

# Mode QM
qm listsnapshot 101 | grep vsg-
```

---

### Test 2 : Rotation des snapshots

**Objectif :** vérifier qu'un seul snapshot est conservé.

**Préconditions :** test 1 réussi.

**Commandes :**
```bash
# Attendre 3 cycles de snapshot
# Mode QM :
qm listsnapshot 101 | grep -c vsg-
# Doit retourner 1

# Mode QMP :
ls -la /mnt/pve/cephfs/vmstate/101/
# Doit contenir : latest.state, timestamp (pas de fichiers accumulés)
```

**Résultat attendu :** un seul snapshot/fichier à tout moment.

---

### Test 3 : Arrêt contrôlé d'un nœud (test HA)

**Objectif :** vérifier que HA redémarre la VM et que le démon restaure l'état.

**Préconditions :**
- VM 101 tourne sur Emilia
- HA activé pour VM 101
- Démon actif sur tous les nœuds
- Au moins un snapshot existe

**Commandes :**
```bash
# Sur EMILIA (nœud source) - arrêter proprement
sudo reboot

# Sur RAM ou REM - observer
watch -n 1 'ha-manager status'
# Attendre que VM 101 apparaisse sur un autre nœud

# Vérifier les logs du démon sur le nouveau nœud
journalctl -u vmstate-guardian -n 50
```

**Résultat attendu :**
- HA redémarre VM 101 sur RAM ou REM (~60s)
- Le démon détecte le failover
- Le démon arrête la VM, restaure l'état, et la redémarre

**Vérification :**
```bash
# Vérifier les logs
grep "FAILOVER DETECTED" /var/log/vmstate-guardian.log
grep "Restore completed" /var/log/vmstate-guardian.log

# Vérifier que la VM tourne
qm status 101
```

---

### Test 4 : Panne simulée (hard crash)

**Objectif :** simuler une panne brutale (pas un arrêt propre).

**Préconditions :** test 3 réussi.

**Commandes :**
```bash
# Sur le nœud source - couper brutalement
# Option 1 : via IPMI/iLO/iDRAC
ipmitool power off

# Option 2 : via sysrq (crash immédiat)
echo b > /proc/sysrq-trigger

# Option 3 : couper l'alimentation physiquement
```

**Résultat attendu :** identique au test 3, mais le délai de détection HA peut être plus long (~2 minutes).

---

### Test 5 : Absence de snapshot

**Objectif :** vérifier le comportement quand aucun snapshot n'existe.

**Préconditions :**
- Supprimer tous les snapshots/fichiers d'état
- Provoquer un failover

**Commandes :**
```bash
# Supprimer les snapshots
# Mode QMP :
rm -f /mnt/pve/cephfs/vmstate/101/latest.state

# Mode QM :
qm listsnapshot 101  # noter les noms vsg-*
qm delsnapshot 101 vsg-XXXXXXXXXX

# Provoquer un failover (reboot du nœud source)
```

**Résultat attendu :**
- Le démon détecte le failover
- La restauration échoue avec "No valid state file" ou "No vsg-* snapshot found"
- La VM reste dans son état de démarrage à froid (HA l'a déjà démarrée)

**Vérification :**
```bash
grep "No valid state" /var/log/vmstate-guardian.log
qm status 101  # doit être running (démarrage froid HA)
```

---

### Test 6 : Snapshot corrompu

**Objectif :** vérifier le comportement avec un fichier d'état invalide.

**Commandes :**
```bash
# Mode QMP : remplacer le fichier d'état par un fichier vide
echo "" > /mnt/pve/cephfs/vmstate/101/latest.state

# Provoquer un failover
```

**Résultat attendu :**
- Le démon détecte que le fichier est vide (taille 0)
- Refuse la restauration
- La VM reste en démarrage froid

---

### Test 7 : Anti-boucle de restauration

**Objectif :** vérifier que le démon ne restaure pas en boucle infinie.

**Commandes :**
```bash
# Simuler des échecs répétés :
# 1. Provoquer un failover
# 2. Observer les logs : le démon tente 3 fois (max_restore_attempts)
# 3. Après 3 échecs, il s'arrête et log une erreur

# Vérifier
cat /var/lib/vmstate-guardian/restore_count
grep "Max restore attempts" /var/log/vmstate-guardian.log
```

**Résultat attendu :**
- Après 3 tentatives, le démon affiche "Max restore attempts reached. Manual intervention required."
- La VM tourne en état froid

**Reset :**
```bash
# Après intervention manuelle, remettre le compteur à 0
rm /var/lib/vmstate-guardian/restore_count
rm /var/lib/vmstate-guardian/restore.lock
```

---

### Test 8 : Test de charge / performance

**Objectif :** mesurer l'impact du démon sur les performances de la VM.

**Commandes :**
```bash
# Dans la VM : lancer un benchmark pendant que le démon fait des snapshots
# Exemples :
sysbench cpu run
sysbench memory run
dd if=/dev/zero of=/tmp/test bs=1M count=1000

# Sur l'hôte : observer pendant un snapshot
iostat -x 1
vmstat 1
```

**Résultat attendu :**
- Mode QMP : pause de ~10-500ms (quasi imperceptible)
- Mode QM : pause de quelques secondes (visible)
- I/O élevé pendant le transfert de la RAM

---

## 8. Dépannage / Troubleshooting

### Le démon ne démarre pas

| Symptôme | Cause | Solution |
|----------|-------|----------|
| "cannot load config" | Fichier de config absent | Créer `/etc/vmstate-guardian/vmstate-guardian.conf` |
| "Cannot init logging" | Permissions insuffisantes | `chmod 755 /var/log/` |
| Service inactif | Pas activé | `systemctl enable --now vmstate-guardian` |

### Le snapshot échoue

| Symptôme | Cause | Solution |
|----------|-------|----------|
| "Cannot connect to QMP socket" | VM pas en cours d'exécution | Vérifier `qm status <vmid>` |
| "Cannot connect to QMP socket" | Socket occupé par Proxmox | Réessayer (le démon réessaiera au cycle suivant) |
| "migration timeout" | RAM trop grande / stockage trop lent | Augmenter `migration_timeout` |
| "Failed to create snapshot" | Quota de stockage dépassé | Vérifier l'espace disque |

### Le failover n'est pas détecté

| Symptôme | Cause | Solution |
|----------|-------|----------|
| Pas de "FAILOVER DETECTED" | VM pas en HA | `ha-manager add vm:101 --group grp-migration` |
| Pas de "FAILOVER DETECTED" | `last_node` déjà correct | Vérifier `cat /var/lib/vmstate-guardian/last_node` |
| Pas de "FAILOVER DETECTED" | Démon pas démarré sur le nouveau nœud | `systemctl status vmstate-guardian` sur tous les nœuds |

### La restauration échoue

| Symptôme | Cause | Solution |
|----------|-------|----------|
| "No valid state file" | Fichier absent / vide | Vérifier le chemin `vmstate_path` et le stockage partagé |
| "Failed to stop VM" | VM déjà arrêtée ou lockée | `qm unlock <vmid>` puis réessayer |
| "Failed to start VM with incoming args" | Arguments invalides | Vérifier le chemin du fichier d'état |
| "Max restore attempts reached" | Boucle d'échecs | Corriger la cause, puis `rm /var/lib/vmstate-guardian/restore_count` |

### Commandes de diagnostic

```bash
# Statut complet
systemctl status vmstate-guardian
journalctl -u vmstate-guardian --no-pager -n 100

# État interne du démon
cat /var/lib/vmstate-guardian/last_node
cat /var/lib/vmstate-guardian/restore_count
cat /var/lib/vmstate-guardian/restore.lock

# État de la VM
qm status 101
qm config 101
qm listsnapshot 101

# État du HA
ha-manager status
pvecm status

# État du stockage
ls -la /mnt/pve/cephfs/vmstate/101/
pvesm status
```

---

## 9. Références

### Documentation Proxmox
- [Proxmox VE Administration Guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.html)
- [Proxmox HA Manager](https://pve.proxmox.com/wiki/High_Availability)
- [Proxmox Cluster Manager](https://pve.proxmox.com/wiki/Cluster_Manager)

### Commandes Proxmox
- [qm (QEMU/KVM VM manager)](https://pve.proxmox.com/pve-docs/qm.1.html)
- [pvesh (Proxmox API shell)](https://pve.proxmox.com/pve-docs/pvesh.1.html)
- [ha-manager](https://pve.proxmox.com/pve-docs/ha-manager.1.html)

### QEMU / KVM
- [QEMU Documentation](https://www.qemu.org/docs/master/)
- [QMP Protocol](https://www.qemu.org/docs/master/interop/qmp-intro.html)
- [QEMU Migration](https://www.qemu.org/docs/master/devel/migration.html)
- [KVM API](https://www.kernel.org/doc/html/latest/virt/kvm/api.html)

### Ceph
- [Ceph Documentation](https://docs.ceph.com/)
- [Proxmox Ceph](https://pve.proxmox.com/wiki/Deploy_Hyper-Converged_Ceph_Cluster)

### Systemd
- [systemd.service](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [systemd.unit](https://www.freedesktop.org/software/systemd/man/systemd.unit.html)

### Linux
- [syslog(3)](https://man7.org/linux/man-pages/man3/syslog.3.html)
- [unix(7) — sockets Unix](https://man7.org/linux/man-pages/man7/unix.7.html)
- [Corosync](https://corosync.github.io/corosync/)
