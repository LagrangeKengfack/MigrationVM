# Live Migrator v2 — Daemon de migration pour Proxmox VE

Orchestrateur signal-driven qui réagit aux signaux des agents RAM, vCPU et GPU pour migrer les VMs dans le cluster Proxmox.

---

## Contenu de ce dossier

```
daemon/
├── live-migrator.sh          # Daemon principal (signal-driven)
├── migrator-ctl.sh           # CLI admin (status, migrate, signal, create)
├── conf/
│   └── live-migrator.conf    # Configuration avec section [orchestrator]
├── systemd/
│   └── live-migrator.service # Service systemd
└── README.md                 # Ce fichier
```

> Les scripts d'installation et le paquet .deb sont dans les dossiers `scripts/` et `debian-pkg/` à la racine du projet.

---

## ⚠️ Mise à jour depuis la v1 (ancien daemon)

Si l'ancien `live-migrator` est déjà installé sur les nœuds du cluster :

### Étape 1 — Désinstaller l'ancien (sur CHAQUE nœud)

```bash
ssh root@<noeud>

# 1. Arrêter et désactiver
systemctl stop live-migrator
systemctl disable live-migrator

# 2. Supprimer les fichiers
rm -f /usr/local/sbin/live-migrator.sh
rm -f /usr/local/sbin/migrator-ctl.sh
rm -f /etc/systemd/system/live-migrator.service
systemctl daemon-reload

# 3. (Optionnel) Supprimer les données et la config
rm -rf /var/lib/live-migrator    # ⚠️ efface l'historique
rm -rf /etc/live-migrator

# Si installé via .deb :
dpkg --purge live-migrator
```

### Étape 2 — Installer la v2

Voir la section [Installation](#installation) ci-dessous.

---

## Installation complète — Étape par étape

> **Contexte** : le projet `live-migrator/` est sur votre machine locale.
> Vous allez le copier sur chaque nœud Proxmox puis l'installer.
> Répétez toute la procédure **sur chaque nœud** (REM, RAM, EMILIA).

---

### Étape 1 — Installer les prérequis (sur chaque nœud)

Ouvrez l'interface web Proxmox : `https://<IP_NOEUD>:8006`

1. Dans le panneau de gauche, cliquez sur le nœud (ex: `rem`)
2. Cliquez sur **Shell** (ouvre un terminal dans le navigateur)
3. Exécutez :

```bash
apt update && apt install -y inotify-tools python3
```

4. Vérifiez que tout est OK :

```bash
qm --version && pvesh --version && inotifywait --help | head -1
```

---

### Étape 2 — Copier le projet sur le nœud

**Depuis le terminal de votre machine locale** (pas le shell Proxmox) :

```bash
# Remplacez <IP_NOEUD> par l'IP du nœud Proxmox
# Exemple : 192.168.1.10

scp -r /home/lagrange/MigrationVM/live-migrator root@<IP_NOEUD>:/tmp/live-migrator
```

> **Astuce** : si vous avez configuré vos noms d'hôte dans `/etc/hosts`, vous pouvez utiliser directement `root@rem`, `root@ram`, `root@emilia`.

Répétez pour chaque nœud :

```bash
scp -r /home/lagrange/MigrationVM/live-migrator root@rem:/tmp/live-migrator
scp -r /home/lagrange/MigrationVM/live-migrator root@ram:/tmp/live-migrator
scp -r /home/lagrange/MigrationVM/live-migrator root@emilia:/tmp/live-migrator
```

---

### Étape 3 — Lancer l'installation (sur chaque nœud)

Retournez dans la **Shell Proxmox** du nœud (ou via SSH) :

```bash
# Rendre le script exécutable
chmod +x /tmp/live-migrator/scripts/install.sh

# Lancer l'installation
/tmp/live-migrator/scripts/install.sh
```

Le script va :
- ✅ Vérifier les dépendances (qm, pvesh, python3, inotifywait)
- ✅ Arrêter l'ancien daemon s'il tournait
- ✅ Copier `live-migrator.sh` et `migrator-ctl.sh` dans `/usr/local/sbin/`
- ✅ Copier la config dans `/etc/live-migrator/`
- ✅ Créer les répertoires de signaux dans `/var/lib/live-migrator/`
- ✅ Installer le service systemd

---

### Étape 4 — Activer et démarrer le daemon

Toujours dans le Shell du nœud :

```bash
# Activer au démarrage + lancer maintenant
systemctl enable --now live-migrator

# Vérifier que ça tourne
systemctl status live-migrator
```

---

### Étape 5 — Vérifier que tout fonctionne

```bash
# Vérification rapide des métriques
live-migrator.sh --check

# Voir les logs en temps réel
journalctl -fu live-migrator

# État via le CLI
migrator-ctl.sh status
```

---

### Résumé : les 4 commandes essentielles par nœud

```bash
# 1. Depuis votre machine locale :
scp -r /home/lagrange/MigrationVM/live-migrator root@<IP_NOEUD>:/tmp/live-migrator

# 2-4. Sur le nœud (Shell Proxmox ou SSH) :
chmod +x /tmp/live-migrator/scripts/install.sh
/tmp/live-migrator/scripts/install.sh
systemctl enable --now live-migrator
```

---

### (Optionnel) Installation automatisée des 3 nœuds d'un coup

Si vous préférez tout faire depuis votre machine locale en une seule commande :

```bash
for node in rem ram emilia; do
    echo "=== Installation sur $node ==="
    scp -r /home/lagrange/MigrationVM/live-migrator root@${node}:/tmp/live-migrator
    ssh root@${node} "chmod +x /tmp/live-migrator/scripts/install.sh && \
        /tmp/live-migrator/scripts/install.sh && \
        systemctl enable --now live-migrator"
    echo ""
done
```

> Nécessite un accès SSH sans mot de passe (`ssh-copy-id root@rem` etc.) ou vous devrez entrer le mot de passe pour chaque nœud.

---

## Configuration

Fichier : `/etc/live-migrator/live-migrator.conf`

```ini
[thresholds]
temp_threshold = 80         # °C
cpu_threshold = 90          # %
ram_threshold = 90          # %
hysteresis = 5              # %
cooldown = 300              # secondes (par VM, anti-ping-pong)

[migration]
migration_type = secure     # secure | insecure
enable_xbzrle = 0           # compression réseau (1 = activer)

[orchestrator]                          # ← NOUVEAU en v2
signal_dir = /var/lib/live-migrator/signals
enable_auto_placement = 1
margin_pct = 10

[paths]
log_file = /var/log/live-migrator.log
state_dir = /var/lib/live-migrator
```

> **Si vous mettez à jour depuis la v1 :** ajoutez la section `[orchestrator]` dans votre config existante, ou comparez avec `live-migrator.conf.new` créé par le script d'install.

---

## Utilisation

### Commandes CLI

```bash
migrator-ctl.sh status                          # état du daemon
migrator-ctl.sh nodes                           # état des nœuds
migrator-ctl.sh history                         # historique
migrator-ctl.sh migrate 101 rem                 # migration manuelle
migrator-ctl.sh maintenance                     # vider ce nœud
migrator-ctl.sh create 200 2048 test-vm         # créer une VM test
```

### Simulation de signaux (test)

```bash
migrator-ctl.sh signal MIGRATE_VM --vmid 101 --urgency high
migrator-ctl.sh signal LIGHTEN_NODE --resource ram --urgency critical
migrator-ctl.sh signal GPU_REQUEST --vmid 101 --gpu-usage emilia:45,rem:82,ram:none
migrator-ctl.sh signal CONSOLIDATE_VM --vmid 108 --min-ram 8192 --nodes emilia,rem
```

### Diagnostic

```bash
live-migrator.sh --check                        # vérification sans daemon
journalctl -fu live-migrator                    # logs en temps réel
live-migrator.sh -f                             # mode foreground (debug)
```

---

## Dépannage

| Problème | Solution |
|----------|---------|
| `inotifywait not found` | `apt install inotify-tools` |
| Le daemon ne réagit pas aux signaux | Vérifier le rename `.tmp` → `.sig` |
| `ALL_NODES_EQUALLY_LOADED` | Les nœuds ont une charge similaire, c'est normal |
| `COOLDOWN_ACTIVE` | Attendre 5 min (configurable via `cooldown`) |
| Consolidation en `PENDING` | Le daemon surveille, elle se fera quand un nœud se libère |
