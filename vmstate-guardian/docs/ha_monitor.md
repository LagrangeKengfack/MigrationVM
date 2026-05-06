# Module ha_monitor

Détection des événements de failover HA (basculement de la VM vers un autre nœud).

## Fichiers
- `ha_monitor.h` — Interface
- `ha_monitor.c` — Implémentation

## Principe de détection

Le démon ne modifie PAS le HA de Proxmox. Il observe passivement :

1. À chaque cycle, vérifie si la VM tourne sur le **nœud local** (`pve_vm_node()` vs `gethostname()`)
2. Compare avec le **dernier nœud connu** (stocké dans `/var/lib/vmstate-guardian/last_node`)
3. Si le nœud a changé → **failover détecté**

## Fichier d'état
```
/var/lib/vmstate-guardian/last_node
```
Contient simplement le nom du dernier nœud où la VM tournait (ex: `emilia`).

## Cas traités

| Situation | Résultat |
|-----------|----------|
| VM sur ce nœud, même nœud qu'avant | Pas de failover → snapshot normal |
| VM sur ce nœud, nœud différent d'avant | **Failover détecté** → restore |
| VM pas sur ce nœud | Veille passive |
| Premier lancement (pas de fichier d'état) | Sauvegarde du nœud courant, pas de restore |
| Redémarrage manuel par l'utilisateur | Même nœud → **pas de restore** |
