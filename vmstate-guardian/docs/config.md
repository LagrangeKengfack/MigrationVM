# Module config

Parsing du fichier de configuration INI (`/etc/vmstate-guardian/vmstate-guardian.conf`).

## Fichiers
- `config.h` — Structures et constantes
- `config.c` — Parsing clé=valeur avec gestion des commentaires (#) et sections ([])

## Paramètres supportés

| Clé | Type | Défaut | Description |
|-----|------|--------|-------------|
| `vmid` | int | 101 | ID de la VM à protéger |
| `mode` | string | qmp | `qmp` (pre-copy) ou `qm` (savevm) |
| `snapshot_interval` | int | 60 | Secondes entre deux snapshots |
| `monitor_interval` | int | 5 | Secondes entre deux vérifications HA |
| `max_restore_attempts` | int | 3 | Max tentatives de restauration consécutives |
| `restore_cooldown` | int | 120 | Délai minimum entre deux restaurations |
| `migration_timeout` | int | 300 | Timeout pour la migration QMP |
| `state_dir` | path | /var/lib/vmstate-guardian | Répertoire d'état du démon |
| `log_file` | path | /var/log/vmstate-guardian.log | Fichier de log |
| `vmstate_path` | path | .../vmstate | Répertoire des fichiers d'état VM |
| `qmp_socket` | path | auto | Socket QMP QEMU |
| `foreground` | bool | false | Mode premier plan |
