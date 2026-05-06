# Scénarios de test — Live Migrator v2

Ce document contient tous les scénarios de test, classés en 3 catégories :

1. **Immédiats** — Testables maintenant sans aucune dépendance
2. **Simulés** — Testables en simulant les données des autres agents
3. **Intégration** — Nécessitent les agents des autres groupes

La couverture vise **≥ 80%** des fonctionnalités décrites dans `PROJET_MIGRATION.md`.

---

## Catégorie 1 — Tests immédiats (sans dépendance)

### T01 : Démarrage et arrêt du daemon

**Objectif :** Vérifier que le daemon démarre, écoute les signaux et s'arrête proprement.

```bash
# Démarrer
sudo systemctl start live-migrator

# Vérifier qu'il tourne
systemctl status live-migrator
# Résultat attendu : active (running)

# Vérifier les logs
journalctl -u live-migrator --no-pager -n 10
# Résultat attendu : "Live-migrator started, watching signals..."

# Arrêter
sudo systemctl stop live-migrator
systemctl status live-migrator
# Résultat attendu : inactive (dead)
```

---

### T02 : Migration manuelle via migrator-ctl

**Objectif :** Confirmer que la migration fonctionne de bout en bout.

```bash
# 1. Vérifier les VMs disponibles
qm list

# 2. Vérifier les nœuds
migrator-ctl.sh nodes

# 3. Migrer manuellement
migrator-ctl.sh migrate <vmid> <noeud_cible>

# 4. Vérifier
qm list
migrator-ctl.sh history

# Résultat attendu : VM déplacée, entrée dans l'historique
```

---

### T03 : Mode maintenance — distribution optimale

**Objectif :** Vider un nœud en répartissant les VMs intelligemment.

```bash
# Pré-requis : avoir ≥ 2 VMs running sur le nœud

# 1. Exécuter le mode maintenance
migrator-ctl.sh maintenance

# Résultat attendu :
# [1/N] Migrating VM xxx → noeud_a ... OK
# [2/N] Migrating VM yyy → noeud_b ... OK  ← nœud DIFFÉRENT si possible
# Node is ready for maintenance

# 2. Vérifier que le nœud est vide
qm list
# Résultat attendu : aucune VM running
```

**Points de vérification :**
- Les VMs ne vont PAS toutes sur le même nœud (sauf si un seul est dispo)
- Le nœud cible est recalculé APRÈS chaque migration

---

### T04 : Mode maintenance — cible forcée

**Objectif :** Forcer toutes les VMs vers un seul nœud.

```bash
migrator-ctl.sh maintenance ram

# Résultat attendu : TOUTES les VMs sur "ram"
qm list
```

---

### T05 : Migration pre-copy standard

**Objectif :** Mesurer le downtime d'une migration standard.

```bash
# 1. Depuis une autre machine, ping la VM
ping -i 0.1 <vm_ip> | tee /tmp/ping_precopy.txt &

# 2. Migrer
migrator-ctl.sh migrate <vmid> <cible>

# 3. Arrêter le ping
kill %1

# 4. Analyser
grep -c "timeout\|unreachable" /tmp/ping_precopy.txt
# Résultat attendu : 0-3 paquets perdus (< 300ms downtime)
```

---

### T06 : Migration avec compression XBZRLE

**Objectif :** Comparer la durée avec et sans XBZRLE.

```bash
# 1. Activer XBZRLE
sed -i 's/enable_xbzrle = 0/enable_xbzrle = 1/' /etc/live-migrator/live-migrator.conf

# 2. Ping + migration
ping -i 0.1 <vm_ip> | tee /tmp/ping_xbzrle.txt &
migrator-ctl.sh migrate <vmid> <cible>
kill %1

# 3. Comparer les durées dans les logs
migrator-ctl.sh history

# 4. Vérifier que la config XBZRLE a été nettoyée après
grep -c migrate_compression /etc/pve/qemu-server/<vmid>.conf
# Résultat attendu : 0

# 5. Remettre XBZRLE à 0
sed -i 's/enable_xbzrle = 1/enable_xbzrle = 0/' /etc/live-migrator/live-migrator.conf
```

---

### T07 : Vérification des métriques cluster

**Objectif :** Confirmer la lecture correcte des métriques.

```bash
migrator-ctl.sh status
migrator-ctl.sh nodes

# Vérifier manuellement :
free -h           # RAM locale
nproc             # CPU locaux
pvesh get /cluster/resources --type node --output-format json | python3 -m json.tool

# Résultat attendu : les valeurs de migrator-ctl correspondent à la réalité
```

---

### T08 : Historique des migrations

**Objectif :** Vérifier que l'historique se remplit et est consultable.

```bash
# Après avoir fait quelques migrations (T02, T03) :
migrator-ctl.sh history

# Résultat attendu : liste des migrations avec vmid, source, target, durée, statut
cat /var/lib/live-migrator/migration_history.log
```

---

## Catégorie 2 — Tests avec données simulées

Ces tests simulent les signaux des autres agents en créant manuellement des fichiers `.sig`.

### T09 : Signal MIGRATE_VM (simulation agent RAM)

**Objectif :** Vérifier le traitement d'un signal de migration.

```bash
# 1. S'assurer que le daemon tourne
systemctl status live-migrator

# 2. Simuler un signal de l'agent RAM
TIMESTAMP=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_migrate_vm.tmp << EOF
type=MIGRATE_VM
vmid=<vmid_running>
source_agent=ram-agent
reason=test_signal
urgency=high
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_migrate_vm.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_migrate_vm.sig

# 3. Vérifier la réaction (quelques secondes)
sleep 5
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP}.resp

# Résultat attendu :
#   status=SUCCESS
#   action=MIGRATED
#   target_node=<nœud_le_moins_chargé>

# 4. Vérifier que le signal a été déplacé
ls /var/lib/live-migrator/signals/processed/
```

---

### T10 : Signal LIGHTEN_NODE (simulation agent RAM)

**Objectif :** Vérifier que le daemon choisit la bonne VM à migrer.

```bash
# Pré-requis : ≥ 2 VMs de tailles différentes sur ce nœud

TIMESTAMP=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.tmp << EOF
type=LIGHTEN_NODE
source_agent=ram-agent
reason=test_lighten
urgency=high
resource=ram
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.sig

sleep 10
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP}.resp

# Résultat attendu : la VM la plus gourmande en RAM a été migrée
# Vérifier avec qm list
```

---

### T11 : Signal LIGHTEN_NODE (simulation agent vCPU)

**Objectif :** Vérifier que resource=cpu choisit la VM la plus gourmande en CPU.

```bash
TIMESTAMP=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.tmp << EOF
type=LIGHTEN_NODE
source_agent=vcpu-agent
reason=test_lighten_cpu
urgency=high
resource=cpu
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.sig

sleep 10
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP}.resp

# Résultat attendu : la VM avec le plus de vCPU a été migrée
```

---

### T12 : Signal GPU_REQUEST (simulation agent GPU)

**Objectif :** Vérifier la migration vers un nœud avec GPU.

```bash
# D'abord, identifier quel nœud a un GPU :
# ssh root@<chaque_noeud> lspci | grep -iE 'VGA|3D' | grep -iv integrated

TIMESTAMP=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_gpu_request.tmp << EOF
type=GPU_REQUEST
vmid=<vmid_running>
source_agent=gpu-agent
reason=test_gpu
urgency=high
gpu_nodes_usage=emilia:45,rem:82,ram:none
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_gpu_request.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_gpu_request.sig

sleep 10
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP}.resp

# Résultat attendu : VM migrée vers "emilia" (GPU le moins sollicité à 45%)
```

**Note :** Adaptez les valeurs `gpu_nodes_usage` à votre cluster réel. Si aucun nœud n'a de GPU, le test doit retourner `REFUSED/NO_SUITABLE_NODE`.

---

### T13 : Signal CONSOLIDATE_VM (simulation agent RAM)

**Objectif :** Vérifier la logique de consolidation.

```bash
# Pré-requis : une VM running sur ce nœud

TIMESTAMP=$(date +%s)
VM_RAM_MB=2048  # Adapter selon la VM
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_consolidate_vm.tmp << EOF
type=CONSOLIDATE_VM
vmid=<vmid_running>
source_agent=ram-agent
reason=test_consolidate
urgency=medium
min_ram_mb=${VM_RAM_MB}
min_vcpu=2
nodes_involved=emilia,rem
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_consolidate_vm.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_consolidate_vm.sig

sleep 10
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP}.resp

# Si un nœud a assez de RAM :
#   status=SUCCESS, action=CONSOLIDATED
# Si aucun nœud :
#   status=REFUSED, action=CONSOLIDATION_IMPOSSIBLE
```

---

### T14 : Cooldown par VM (anti-ping-pong)

**Objectif :** Vérifier qu'une VM récemment migrée ne peut pas être re-migrée.

```bash
# 1. Envoyer un premier signal MIGRATE_VM
TIMESTAMP1=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP1}_migrate_vm.tmp << EOF
type=MIGRATE_VM
vmid=<vmid>
source_agent=ram-agent
reason=test_cooldown_1
urgency=high
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP1}_migrate_vm.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP1}_migrate_vm.sig

sleep 10

# 2. Vérifier que la migration a eu lieu
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP1}.resp
# Résultat attendu : status=SUCCESS

# 3. Envoyer immédiatement un 2ème signal pour la MÊME VM
TIMESTAMP2=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP2}_migrate_vm.tmp << EOF
type=MIGRATE_VM
vmid=<vmid>
source_agent=ram-agent
reason=test_cooldown_2
urgency=high
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP2}_migrate_vm.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP2}_migrate_vm.sig

sleep 5

# 4. Vérifier le refus
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP2}.resp
# Résultat attendu : status=REFUSED, action=COOLDOWN_ACTIVE
```

---

### T15 : Signal pour VM inexistante

**Objectif :** Vérifier la gestion d'erreur.

```bash
TIMESTAMP=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_migrate_vm.tmp << EOF
type=MIGRATE_VM
vmid=9999
source_agent=ram-agent
reason=test_invalid
urgency=high
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_migrate_vm.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_migrate_vm.sig

sleep 5
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP}.resp
# Résultat attendu : status=REFUSED, action=VM_NOT_FOUND
```

---

### T16 : LIGHTEN_NODE quand tous les nœuds sont proches en charge

**Objectif :** Vérifier que le daemon refuse de migrer inutilement.

```bash
# Ce test fonctionne quand tous les nœuds ont une charge similaire (±10%)
# Vérifier d'abord :
migrator-ctl.sh nodes
# Si les charges sont proches, le test est valide

TIMESTAMP=$(date +%s)
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.tmp << EOF
type=LIGHTEN_NODE
source_agent=ram-agent
reason=test_equal_load
urgency=medium
resource=ram
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_lighten_node.sig

sleep 5
cat /var/lib/live-migrator/signals/responses/response_${TIMESTAMP}.resp
# Résultat attendu : status=REFUSED, action=ALL_NODES_EQUALLY_LOADED
```

---

### T17 : Priorité des signaux (urgency)

**Objectif :** Vérifier que les signaux critical sont traités avant les medium.

```bash
# 1. Arrêter le daemon pour accumuler les signaux
sudo systemctl stop live-migrator

# 2. Créer 2 signaux : un medium d'abord, un critical ensuite
TS1=$(date +%s)
sleep 1
TS2=$(date +%s)

# Signal medium (créé en premier)
cat > /var/lib/live-migrator/signals/signal_${TS1}_lighten_node.tmp << EOF
type=LIGHTEN_NODE
source_agent=ram-agent
reason=test_priority_medium
urgency=medium
resource=ram
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TS1}_lighten_node.tmp \
   /var/lib/live-migrator/signals/signal_${TS1}_lighten_node.sig

# Signal critical (créé en second)
cat > /var/lib/live-migrator/signals/signal_${TS2}_migrate_vm.tmp << EOF
type=MIGRATE_VM
vmid=<vmid>
source_agent=ram-agent
reason=test_priority_critical
urgency=critical
timestamp=$(date -Iseconds)
EOF
mv /var/lib/live-migrator/signals/signal_${TS2}_migrate_vm.tmp \
   /var/lib/live-migrator/signals/signal_${TS2}_migrate_vm.sig

# 3. Redémarrer le daemon
sudo systemctl start live-migrator
sleep 15

# 4. Vérifier l'ordre de traitement dans les logs
journalctl -u live-migrator --no-pager -n 20
# Résultat attendu : le signal critical a été traité AVANT le medium
```

---

### T18 : Placement automatique d'une nouvelle VM

**Objectif :** Vérifier que le watcher inotifywait détecte une nouvelle VM.

```bash
# 1. S'assurer que le daemon tourne
systemctl status live-migrator

# 2. Créer une VM (elle sera éteinte)
qm create <nouveau_vmid> --memory 2048 --name test-placement

# 3. Observer les logs dans les 5 secondes
journalctl -u live-migrator --no-pager -n 10

# Si le nœud a assez de RAM :
#   "VM <vmid> reste ici, assez de ressources"
# Si le nœud n'a PAS assez :
#   "VM <vmid> placée sur <cible>"

# 4. Nettoyer
qm destroy <nouveau_vmid>
```

---

### T19 : Signal avec fichier mal formé

**Objectif :** Vérifier la robustesse du parsing.

```bash
TIMESTAMP=$(date +%s)

# Fichier sans champ type
cat > /var/lib/live-migrator/signals/signal_${TIMESTAMP}_bad.tmp << EOF
vmid=101
source_agent=test
EOF
mv /var/lib/live-migrator/signals/signal_${TIMESTAMP}_bad.tmp \
   /var/lib/live-migrator/signals/signal_${TIMESTAMP}_bad.sig

sleep 5
# Résultat attendu : le daemon log une erreur et déplace le fichier
# sans crash
journalctl -u live-migrator --no-pager -n 5
ls /var/lib/live-migrator/signals/processed/
```

---

## Catégorie 3 — Tests d'intégration (nécessitent les autres agents)

### T20 : Signal réel de l'agent RAM

**Dépendance :** Agent RAM opérationnel.

**Procédure :**
1. Simuler une surcharge RAM sur un nœud (lancer des VMs gourmandes)
2. L'agent RAM détecte la surcharge et envoie un signal
3. Vérifier que le daemon migre la bonne VM
4. Vérifier la réponse dans `/var/lib/live-migrator/signals/responses/`

---

### T21 : Signal réel de l'agent vCPU

**Dépendance :** Agent vCPU opérationnel.

**Procédure :**
1. Générer de la contention CPU (stress test dans une VM)
2. L'agent vCPU envoie un signal LIGHTEN_NODE
3. Vérifier la migration

---

### T22 : Signal réel de l'agent GPU

**Dépendance :** Agent GPU opérationnel.

**Procédure :**
1. Démarrer une VM qui a besoin du GPU sur un nœud sans GPU
2. L'agent GPU envoie un GPU_REQUEST avec les pourcentages d'utilisation
3. Le daemon migre vers le nœud avec le GPU le moins sollicité

---

### T23 : Consolidation réelle après partage de RAM

**Dépendance :** Agent RAM avec mécanisme de partage actif.

**Procédure :**
1. L'agent RAM disperse la RAM d'une VM sur 2 nœuds
2. L'agent RAM envoie un signal CONSOLIDATE_VM
3. Le daemon surveille et consolide quand un nœud peut tout héberger
4. Si harmonisation nécessaire : vérifie que des petites VMs sont déplacées d'abord

---

### T24 : Chaîne complète de bout en bout

**Dépendance :** Tous les agents.

**Procédure :**
1. Cluster sous charge normale
2. Augmenter la charge RAM sur un nœud
3. Agent RAM détecte → envoie signal → daemon migre
4. Vérifier : signal reçu → VM migrée → réponse envoyée → historique mis à jour
5. Vérifier le cooldown : renvoyer un signal pour la même VM → refus

---

## Récapitulatif de couverture

| Fonctionnalité | Tests | Couverture |
|---|---|---|
| Migration manuelle | T02, T05, T06 | ✅ |
| Migration sur signal MIGRATE_VM | T09, T14, T15 | ✅ |
| Migration sur signal LIGHTEN_NODE (RAM) | T10, T16 | ✅ |
| Migration sur signal LIGHTEN_NODE (CPU) | T11 | ✅ |
| Migration sur signal GPU_REQUEST | T12 | ✅ |
| Consolidation CONSOLIDATE_VM | T13, T23 | ✅ |
| Placement auto nouvelles VMs | T18 | ✅ |
| Mode maintenance (auto) | T03 | ✅ |
| Mode maintenance (forcé) | T04 | ✅ |
| Cooldown anti-ping-pong | T14 | ✅ |
| Priorité urgency | T17 | ✅ |
| Pre-copy | T05 | ✅ |
| XBZRLE | T06 | ✅ |
| Gestion erreurs (VM inexistante) | T15 | ✅ |
| Gestion erreurs (signal mal formé) | T19 | ✅ |
| Gestion erreurs (nœuds égaux) | T16 | ✅ |
| Démarrage/arrêt daemon | T01 | ✅ |
| Métriques cluster | T07 | ✅ |
| Historique | T08 | ✅ |
| Réponses aux agents | T09-T16 | ✅ |
| Harmonisation cluster | T13, T23 | ✅ |
| **Total : 21/24 fonctionnalités** | | **87.5%** |

Les 3 fonctionnalités restantes (T20-T22 : signaux réels des agents) nécessitent les autres groupes.
