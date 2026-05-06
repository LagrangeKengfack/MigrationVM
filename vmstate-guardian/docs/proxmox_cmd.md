# Module proxmox_cmd

Wrapper C autour des commandes CLI Proxmox (`qm`, `pvesh`, `ha-manager`).

## Fichiers
- `proxmox_cmd.h` — Interface des commandes
- `proxmox_cmd.c` — Exécution via `popen()` et parsing de la sortie

## Fonctions

| Fonction | Commande sous-jacente | Description |
|----------|----------------------|-------------|
| `pve_vm_status()` | `qm status <vmid>` | État de la VM (running/stopped) |
| `pve_vm_node()` | `pvesh get /cluster/resources` | Nœud hébergeant la VM |
| `pve_vm_start()` | `qm start <vmid>` | Démarrer la VM |
| `pve_vm_stop()` | `qm stop <vmid>` | Arrêter la VM (immédiat) |
| `pve_vm_shutdown()` | `qm shutdown <vmid>` | Arrêt propre (30s timeout) |
| `pve_snapshot_create()` | `qm snapshot` | Créer un snapshot |
| `pve_snapshot_delete()` | `qm delsnapshot` | Supprimer un snapshot |
| `pve_snapshot_rollback()` | `qm rollback` | Restaurer un snapshot |
| `pve_snapshot_list()` | `qm listsnapshot` | Lister les snapshots |
| `pve_ha_status()` | `ha-manager status` | État du HA |
| `pve_vm_set_args()` | `qm set --args` | Injecter des arguments QEMU |
| `pve_vm_delete_args()` | `qm set --delete args` | Supprimer les arguments QEMU |
| `pve_local_node()` | `gethostname()` | Nom du nœud local |

## Notes
- Toutes les commandes sont exécutées via `popen()` (simple, pas de dépendance libcurl)
- Le parsing JSON de `pvesh` est minimal (recherche de sous-chaînes)
- Les erreurs sont journalisées via le module `logger`
