# Module snapshot_mgr

Gestion du cycle de snapshot périodique avec rotation (un seul snapshot conservé).

## Fichiers
- `snapshot_mgr.h` — Interface
- `snapshot_mgr.c` — Implémentation des deux modes

## Modes de fonctionnement

### Mode QMP (pre-copy)
1. Crée le répertoire `vmstate_path` si nécessaire
2. Connecte au socket QMP
3. Déclenche `migrate exec:cat > <path>/new.state`
4. Attend la fin du transfert pre-copy (VM tourne pendant le gros du transfert)
5. Renomme atomiquement `new.state` → `latest.state`
6. Écrit un fichier `timestamp` avec l'heure du snapshot

### Mode QM (savevm)
1. Recherche le dernier snapshot `vsg-*` existant
2. Crée un nouveau snapshot `vsg-<timestamp>` avec `--vmstate 1`
3. Supprime l'ancien snapshot

## Nommage
- Mode QMP : fichier `latest.state` dans `vmstate_path`
- Mode QM : snapshots internes nommés `vsg-<unix_timestamp>` (ex: `vsg-1713362400`)

## Rotation
Un seul snapshot est conservé. En mode QMP, le renommage atomique garantit qu'il y a toujours un état valide pendant l'écriture du nouveau.
