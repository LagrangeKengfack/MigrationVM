# API de Communication — Live Migrator

Ce document explique comment vos agents doivent communiquer avec le daemon `live-migrator` pour déclencher des migrations de VMs.

**Chaque groupe trouvera sa section dédiée plus bas.** La partie commune concerne tout le monde.

---

## Partie commune

### Objectif

Le daemon `live-migrator` est l'**orchestrateur de migration** du cluster. Il reçoit des signaux de vos agents, évalue l'état du cluster, et exécute la migration au meilleur endroit. **C'est lui qui décide du nœud cible** — vos agents n'ont qu'à dire *quoi* migrer et *pourquoi*.

### Où écrire les signaux

```
/var/lib/live-migrator/signals/
```

Ce répertoire existe sur **chaque nœud**. Écrivez le signal **sur le nœud concerné**.

### Format du fichier signal

**Nom :** `signal_<timestamp_unix>_<type>.sig`

**Contenu :** Format clé=valeur, une paire par ligne. Voir la section de votre groupe pour le format exact.

> **Écriture atomique obligatoire :** Écrivez d'abord dans un fichier `.tmp`, puis renommez-le en `.sig`. Cela empêche le daemon de lire un fichier partiellement écrit.

### Champs communs à tous les signaux

| Champ | Obligatoire | Description |
|-------|:-----------:|-------------|
| `type` | ✅ | Type de signal (voir section de votre groupe) |
| `source_agent` | ✅ | Nom de votre agent (ex: `ram-agent`) |
| `reason` | ✅ | Raison du signal, texte libre |
| `urgency` | ✅ | `low`, `medium`, `high`, `critical` (voir guide ci-dessous) |
| `timestamp` | ✅ | Horodatage ISO 8601 |

Le champ `urgency` détermine **l'ordre de traitement** quand plusieurs signaux arrivent en même temps. Un signal `critical` sera traité avant un signal `low`.

**Guide pour choisir l'urgency :**

| Niveau | Quand l'utiliser | Exemples |
|--------|-----------------|----------|
| `critical` | Risque immédiat pour le service, noeud en danger | Utilisation > 95%, température critique, risque de crash |
| `high` | Dégradation significative des performances | Utilisation > 85%, contention CPU/GPU élevée |
| `medium` | Situation notable mais pas urgente | Utilisation > 75%, optimisation souhaitée |
| `low` | Amélioration optionnelle, aucun impact immédiat | Rééquilibrage préventif, consolidation de confort |

Chaque agent décide de l'urgency selon ses propres seuils et métriques. Ce guide est une recommandation pour assurer la cohérence entre les agents.

### Où lire les réponses

```
/var/lib/live-migrator/signals/responses/response_<timestamp_original>.resp
```

Le `<timestamp_original>` correspond au timestamp de votre signal, ce qui permet de matcher signal → réponse.

### Format de la réponse

```ini
original_signal=signal_1745312345_migrate_vm.sig
status=SUCCESS
action=MIGRATED
vmid=103
source_node=emilia
target_node=rem
duration_seconds=45
timestamp=2026-04-22T09:30:52
message=VM 103 migrated from emilia to rem in 45s
```

### Statuts de réponse possibles

| `status` | `action` | Signification |
|----------|----------|---------------|
| `SUCCESS` | `MIGRATED` | Migration réussie |
| `SUCCESS` | `CONSOLIDATED` | Consolidation réussie (VM regroupée sur un seul nœud) |
| `FAILED` | `MIGRATION_FAILED` | La commande de migration a échoué |
| `REFUSED` | `NO_SUITABLE_NODE` | Aucun nœud ne peut accueillir la VM |
| `REFUSED` | `ALL_NODES_EQUALLY_LOADED` | Migration inutile, les nœuds sont proches en charge |
| `REFUSED` | `VM_NOT_FOUND` | La VM n'existe pas ou n'est pas en cours d'exécution |
| `REFUSED` | `COOLDOWN_ACTIVE` | Cette VM a été migrée récemment (protection anti-ping-pong, 5 min) |
| `REFUSED` | `CONSOLIDATION_IMPOSSIBLE` | Aucun nœud ne peut héberger la totalité de la VM |

### Types de signaux — Vue d'ensemble

| Signal | Qui l'envoie | Signification |
|--------|-------------|---------------|
| `MIGRATE_VM` | Agent RAM, Agent vCPU | Migrer une VM spécifique hors de ce nœud |
| `LIGHTEN_NODE` | Agent RAM, Agent vCPU | Ce nœud est surchargé, alléger en migrant une VM |
| `CONSOLIDATE_VM` | Agent RAM | Une VM a sa RAM dispersée sur plusieurs nœuds, la regrouper quand possible |
| `GPU_REQUEST` | Agent GPU | Cette VM a besoin du GPU, la déplacer vers un nœud avec GPU |

---

## Section 1 — Agent RAM

### Signaux que vous pouvez envoyer

#### `MIGRATE_VM` — Migrer une VM spécifique

Utilisez ce signal quand vous avez identifié une VM précise qui doit quitter son nœud (ex: elle consomme trop de RAM).

```ini
type=MIGRATE_VM
vmid=103
source_agent=ram-agent
reason=vm_103_ram_peak_12gb
urgency=high
timestamp=2026-04-22T09:30:00
```

| Champ | Obligatoire | Description |
|-------|:-----------:|-------------|
| `vmid` | ✅ | ID de la VM à migrer |

**Ce que fait notre daemon :** Trouve le nœud le moins chargé en pourcentage d'utilisation RAM qui a assez de RAM libre en absolu pour accueillir cette VM, puis exécute la migration.

---

#### `LIGHTEN_NODE` — Alléger un nœud surchargé

Utilisez ce signal quand le nœud est globalement surchargé en RAM mais que vous ne savez pas (ou ne souhaitez pas choisir) quelle VM migrer.

```ini
type=LIGHTEN_NODE
source_agent=ram-agent
reason=ram_usage_87_percent
urgency=high
resource=ram
timestamp=2026-04-22T09:31:00
```

| Champ | Obligatoire | Description |
|-------|:-----------:|-------------|
| `resource` | ✅ | Toujours `ram` pour l'agent RAM. Permet au daemon de choisir la VM la plus gourmande **en RAM** |

**Ce que fait notre daemon :**
1. Compare la charge de **tous** les nœuds du cluster
2. **Ne migre que si** d'autres nœuds sont significativement moins chargés (marge de 10%)
3. Choisit la VM consommant le plus de **RAM** sur ce nœud
4. La migre vers le nœud le moins chargé

Si tous les nœuds sont proches en charge → réponse `REFUSED / ALL_NODES_EQUALLY_LOADED`.

---

#### `CONSOLIDATE_VM` — Regrouper les ressources dispersées d'une VM

Utilisez ce signal quand votre mécanisme de partage a réparti la RAM d'une VM sur plusieurs nœuds. Le daemon surveillera et, dès qu'un nœud pourra héberger toute la VM, il la regroupera.

```ini
type=CONSOLIDATE_VM
vmid=108
source_agent=ram-agent
reason=vm_ram_split_4gb_emilia_4gb_rem
urgency=medium
min_ram_mb=8192
min_vcpu=4
nodes_involved=emilia,rem
timestamp=2026-04-22T09:32:00
```

| Champ | Obligatoire | Description |
|-------|:-----------:|-------------|
| `vmid` | ✅ | ID de la VM dont les ressources sont dispersées |
| `min_ram_mb` | ✅ | RAM totale de la VM en Mo (nécessaire pour déterminer quel nœud peut tout héberger) |
| `min_vcpu` | ✅ | Nombre de vCPU total de la VM |
| `nodes_involved` | ✅ | Liste des nœuds sur lesquels les ressources sont actuellement réparties (séparés par des virgules) |

**Ce que fait notre daemon :**
1. Enregistre la VM comme "à consolider"
2. Surveille l'état du cluster en continu
3. Dès qu'un nœud a assez de RAM libre (≥ `min_ram_mb`) et assez de vCPU, et que sa charge est raisonnable → exécute la migration. Si nécessaire, harmonise le cluster en déplaçant d'abord des petites VMs pour libérer l'espace.
4. Répond `CONSOLIDATED` avec le nœud cible
5. Répond `CONSOLIDATION_IMPOSSIBLE` **uniquement** si la VM nécessite plus de RAM que la capacité totale de n'importe quel nœud du cluster (cas physiquement impossible). Tant que c'est théoriquement possible, le daemon continue de surveiller et d'attendre une opportunité.

---

## Section 2 — Agent vCPU

### Signaux que vous pouvez envoyer

#### `MIGRATE_VM` — Migrer une VM spécifique

Utilisez ce signal quand une VM précise cause de la contention CPU.

```ini
type=MIGRATE_VM
vmid=101
source_agent=vcpu-agent
reason=vm_101_cpu_intensive
urgency=medium
timestamp=2026-04-22T09:30:00
```

| Champ | Obligatoire | Description |
|-------|:-----------:|-------------|
| `vmid` | ✅ | ID de la VM à migrer |

---

#### `LIGHTEN_NODE` — Alléger un nœud surchargé en CPU

Utilisez ce signal quand le nœud a une contention CPU globale.

```ini
type=LIGHTEN_NODE
source_agent=vcpu-agent
reason=cpu_contention_92_percent
urgency=high
resource=cpu
timestamp=2026-04-22T09:31:00
```

| Champ | Obligatoire | Description |
|-------|:-----------:|-------------|
| `resource` | ✅ | Toujours `cpu` pour l'agent vCPU. Permet au daemon de choisir la VM la plus gourmande **en CPU** |

**Même logique que pour l'agent RAM**, mais le daemon sélectionne la VM la plus consommatrice de **CPU** au lieu de RAM.

---

## Section 3 — Agent GPU

### Signal que vous pouvez envoyer

#### `GPU_REQUEST` — Une VM a besoin du GPU

Utilisez ce signal quand une VM doit accéder au GPU (via votre mécanisme de partage) mais se trouve sur un nœud sans GPU ou dont le GPU est trop sollicité.

```ini
type=GPU_REQUEST
vmid=105
source_agent=gpu-agent
reason=vm_needs_gpu_for_rendering
urgency=high
gpu_nodes_usage=emilia:45,rem:82,ram:none
timestamp=2026-04-22T09:30:00
```

| Champ | Obligatoire | Description |
|-------|:-----------:|-------------|
| `vmid` | ✅ | ID de la VM qui a besoin du GPU |
| `gpu_nodes_usage` | ✅ | Pourcentage d'utilisation GPU de chaque nœud, au format `noeud:pourcentage` séparés par des virgules. Utilisez `none` pour les nœuds sans GPU. |

**Ce que fait notre daemon :**
1. Parse `gpu_nodes_usage` pour identifier les nœuds avec GPU et leur charge
2. Choisit le nœud dont le **GPU est le moins sollicité** et qui peut accueillir la VM (assez de RAM/CPU libres)
3. Exécute la migration
4. Répond avec le nœud cible

---

## Remarques

### 1. Signaux contradictoires simultanés

Si l'agent RAM demande de migrer la VM 101 hors d'EMILIA et que l'agent vCPU demande aussi de migrer la VM 101 au même moment : le premier signal reçu est traité, le second recevra la réponse `COOLDOWN_ACTIVE` (la VM vient d'être migrée).

### 2. Protection contre les rafales

Si plus de 10 signaux non traités s'accumulent, le daemon traite les signaux par ordre d'`urgency` (`critical` d'abord). Les signaux `low` peuvent être retardés.

### 3. VM éteinte qui redémarre

Si une VM éteinte est démarrée par un utilisateur et que le nœud manque de ressources : envoyez un signal `LIGHTEN_NODE`. Le daemon migrera une **autre** VM pour faire de la place. La VM qui vient de démarrer ne sera pas migrée (protection cooldown).

### 4. Migration impossible

Si aucun nœud du cluster n'a assez de ressources pour accueillir la VM, le daemon répond `REFUSED / NO_SUITABLE_NODE`. Votre agent doit gérer ce cas (continuer le partage de ressources ou alerter l'administrateur).

### 5. Nœud qui rejoint ou quitte le cluster

Le daemon actualise la liste des nœuds à chaque signal via l'API Proxmox. Un nouveau nœud sera automatiquement pris en compte. Un nœud hors ligne sera exclu.

### 6. Libération de la RAM après migration

Proxmox libère **automatiquement** la RAM de la VM sur le nœud source après une migration réussie. Le processus QEMU du nœud source est terminé et toutes ses ressources (RAM, CPU, réseau) sont libérées. Aucune action supplémentaire n'est nécessaire de votre part ni de la nôtre.
