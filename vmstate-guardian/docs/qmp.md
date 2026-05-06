# Module qmp

Communication directe avec QEMU via le protocole QMP (QEMU Monitor Protocol) sur socket Unix.

## Fichiers
- `qmp.h` — Interface de connexion et commandes QMP
- `qmp.c` — Implémentation socket Unix + JSON

## Principe

Le QMP est un protocole JSON sur socket Unix. Chaque VM QEMU expose un socket à :
```
/var/run/qemu-server/<vmid>.qmp
```

## Protocole de connexion
1. Connexion au socket Unix
2. Réception du greeting JSON
3. Envoi de `{"execute":"qmp_capabilities"}` pour activer le mode commande
4. Envoi/réception de commandes JSON

## Fonctions principales

### `qmp_migrate_to_file()`
Déclenche une migration pre-copy vers un fichier :
1. Envoie `{"execute":"migrate","arguments":{"uri":"exec:cat > /path/to/file"}}`
2. Interroge `query-migrate` toutes les secondes
3. Statuts possibles : `setup` → `active` → `completed` (ou `failed`)
4. Quand `completed` : envoie `cont` pour reprendre la VM
5. L'avantage : la VM ne se fige que ~10-500ms à la fin du transfert

### `qmp_cont()` / `qmp_stop()`
Envoie les commandes de reprise/arrêt de la VM.

## Notes techniques
- Le parsing JSON est simplifié (recherche de sous-chaînes) car les réponses QMP ont une structure prévisible
- Timeout configurable via `migration_timeout` dans le fichier de configuration
- En cas d'échec, la VM est automatiquement reprise (`cont`)
