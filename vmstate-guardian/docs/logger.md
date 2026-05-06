# Module logger

Double journalisation vers syslog (intégration systemd/journald) et fichier texte.

## Fichiers
- `logger.h` — Interface avec 4 niveaux de log
- `logger.c` — Implémentation syslog + fichier avec horodatage

## Niveaux
| Niveau | Syslog | Usage |
|--------|--------|-------|
| `VSG_LOG_DEBUG` | LOG_DEBUG | Détails techniques (cycle par cycle) |
| `VSG_LOG_INFO` | LOG_INFO | Opérations normales (snapshot créé, etc.) |
| `VSG_LOG_WARN` | LOG_WARNING | Événements anormaux (failover détecté) |
| `VSG_LOG_ERROR` | LOG_ERR | Erreurs (snapshot échoué, restore impossible) |

## Format de sortie
```
[2026-04-17 14:30:00] [INFO] Snapshot vsg-1713362400 created
```
