# Module restore_engine

Restauration automatique de l'état mémoire de la VM après un failover HA.

## Fichiers
- `restore_engine.h` — Interface
- `restore_engine.c` — Implémentation

## Processus de restauration

### Mode QMP
1. Vérifier que le fichier `latest.state` existe et n'est pas vide
2. Arrêter la VM démarrée par HA (`qm stop`)
3. Injecter `-incoming "exec:cat <state_file>"` dans la config VM
4. Démarrer la VM (`qm start`) — QEMU charge l'état depuis le fichier
5. Envoyer `cont` via QMP pour repriser la VM
6. Retirer l'argument `args` de la config VM
7. Vérifier que la VM est en état `running`

### Mode QM
1. Trouver le dernier snapshot `vsg-*`
2. Arrêter la VM (`qm stop`)
3. Rollback au snapshot (`qm rollback`)
4. Démarrer la VM (`qm start`) — reprend depuis l'état du snapshot

## Protections anti-boucle

| Mécanisme | Fichier | Description |
|-----------|---------|-------------|
| Lock temporel | `restore.lock` | Interdit un restore si le dernier date de moins de `restore_cooldown` secondes |
| Compteur de tentatives | `restore_count` | Compte les restaurations consécutives, bloque après `max_restore_attempts` |
| Reset automatique | — | Le compteur est remis à 0 après un restore réussi |

## Scénario de boucle évitée
1. HA redémarre VM → restore tenté → échec
2. HA redémarre VM → restore tenté → échec (2e tentative)
3. HA redémarre VM → restore tenté → échec (3e tentative)
4. HA redémarre VM → **bloqué** par max_restore_attempts → message d'erreur → intervention manuelle nécessaire
