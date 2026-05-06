# Live Migrator — Guide de déploiement, Tests formels et Algorithmes

Ce document complète le README principal avec :
1. **Paquet Debian** — Installation en une commande sur tout cluster Proxmox
2. **Scénarios de test formels** — Pour rapport avec 15+ VMs
3. **Outil d'analyse Python** — Courbes et statistiques depuis les logs
4. **Algorithmes** — Pseudocode de tous les algorithmes pour le rapport

---

## Table des matières

1. [Paquet Debian (.deb)](#1-paquet-debian-deb)
2. [Scénarios de test formels](#2-scénarios-de-test-formels)
3. [Outil d'analyse des logs](#3-outil-danalyse-des-logs)
4. [Algorithmes du système](#4-algorithmes-du-système)

---

## 1. Paquet Debian (.deb)

### Qu'est-ce que c'est ?

Au lieu de copier des fichiers et taper des commandes, on crée un **paquet `.deb`** (comme les logiciels qu'on installe avec `apt`). Une seule commande suffit pour installer le live-migrator sur n'importe quel nœud Proxmox.

> **Note :** Ce n'est PAS une recompilation de l'ISO Proxmox. C'est un paquet additionnel qui s'installe par-dessus Proxmox existant, comme n'importe quel logiciel Debian.

### Structure du paquet

```
debian-pkg/
├── DEBIAN/
│   ├── control         ← Métadonnées du paquet (nom, version, dépendances)
│   ├── postinst        ← Script post-installation (active le service)
│   ├── prerm           ← Script pré-suppression (arrête le service)
│   └── conffiles       ← Liste des fichiers de config (préservés lors des mises à jour)
├── usr/local/sbin/
│   ├── live-migrator.sh
│   └── migrator-ctl.sh
├── etc/
│   ├── live-migrator/
│   │   └── live-migrator.conf
│   └── systemd/system/
│       └── live-migrator.service
└── var/lib/live-migrator/
```

### Comment construire le paquet

```bash
# Sur ta machine (laptop ou un nœud Proxmox)
cd /chemin/vers/live-migrator
chmod +x scripts/build-deb.sh
./scripts/build-deb.sh

# Résultat : live-migrator_1.0.0_all.deb
```

### Comment installer sur un nouveau cluster

```bash
# 1. Copier le .deb vers chaque nœud
scp live-migrator_1.0.0_all.deb root@<IP_NOEUD_1>:/tmp/
scp live-migrator_1.0.0_all.deb root@<IP_NOEUD_2>:/tmp/
scp live-migrator_1.0.0_all.deb root@<IP_NOEUD_3>:/tmp/

# 2. Sur chaque nœud, une seule commande :
dpkg -i /tmp/live-migrator_1.0.0_all.deb

# C'est tout ! Le service est installé, activé et démarré.
# Optionnel : ajuster la config
nano /etc/live-migrator/live-migrator.conf
systemctl restart live-migrator
```

### Désinstallation

```bash
dpkg -r live-migrator      # Supprimer (garde la config)
dpkg --purge live-migrator  # Supprimer tout (y compris la config)
```

### Mise à jour

```bash
# Reconstruire le .deb avec la nouvelle version
# Changer la version dans debian-pkg/DEBIAN/control
dpkg -i /tmp/live-migrator_1.1.0_all.deb
# La config existante est préservée automatiquement
```

---

## 2. Scénarios de test formels

### Prérequis généraux

- Cluster Proxmox avec 3 nœuds (REM, RAM, EMILIA)
- `live-migrator` installé et actif sur chaque nœud
- Au moins 15 VMs réparties sur les nœuds (utiliser des VMs légères si nécessaire)
- `stress` installé sur chaque nœud : `apt install stress -y`
- Stockage partagé fonctionnel

### Créer des VMs de test rapidement

Si tu n'as pas 15 VMs, tu peux en créer facilement :

```bash
# Sur un nœud Proxmox — créer des VMs minimales (512 Mo RAM chacune)
for i in $(seq 200 214); do
  qm create $i --name "test-vm-$i" --memory 512 --cores 1 --net0 virtio,bridge=vmbr0
  # Si tu as un template/ISO :
  # qm clone <template_id> $i --name "test-vm-$i"
  qm start $i
done
```

---

### Test 1 : Vérification des métriques (sans migration)

| | |
|---|---|
| **Objectif** | Confirmer que l'outil lit correctement les métriques sur les 3 nœuds |
| **VMs impliquées** | Aucune (lecture seule) |
| **Commande** | `live-migrator.sh --check` sur chaque nœud |

```bash
# Sur chaque nœud
live-migrator.sh --check
```

**Résultat attendu :** Température, CPU, RAM, nombre de VMs locales, et nœud cible affichés correctement. Comparer avec `top`, `free -h`, `sensors`.

**Mesures à noter :** Température, % CPU, % RAM, nombre de VMs, nœud cible choisi.

---

### Test 2 : Migration manuelle d'une seule VM

| | |
|---|---|
| **Objectif** | Valider que `migrator-ctl.sh migrate` fonctionne |
| **VMs impliquées** | 1 VM |
| **Commande** | `migrator-ctl.sh migrate <vmid> <target>` |

```bash
# 1. Noter l'emplacement initial
pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | \
  python3 -c "import sys,json; [print(f'VM {v[\"vmid\"]}: {v[\"node\"]}') for v in json.load(sys.stdin) if v.get('type')=='qemu' and v.get('status')=='running']"

# 2. Migrer
migrator-ctl.sh migrate <vmid> <target>

# 3. Vérifier
migrator-ctl.sh history
```

**Mesures :** Durée, statut (OK/FAILED).

---

### Test 3 : Migration avec XBZRLE activé vs désactivé

| | |
|---|---|
| **Objectif** | Comparer les durées de migration avec et sans compression |
| **VMs impliquées** | 2 VMs identiques (même RAM, même charge) |

```bash
# Test A : sans XBZRLE
sed -i 's/enable_xbzrle = 1/enable_xbzrle = 0/' /etc/live-migrator/live-migrator.conf
migrator-ctl.sh migrate <vm1> <target>
# → noter la durée

# Test B : avec XBZRLE
sed -i 's/enable_xbzrle = 0/enable_xbzrle = 1/' /etc/live-migrator/live-migrator.conf
migrator-ctl.sh migrate <vm2> <target>
# → noter la durée

# Vérifier que XBZRLE est nettoyé après
grep migrate_compression /etc/pve/qemu-server/<vm2>.conf
# Résultat attendu : rien (nettoyé)
```

**Mesures :** Durée avec XBZRLE, durée sans XBZRLE, différence en %.

---

### Test 4 : Migration secure vs insecure

| | |
|---|---|
| **Objectif** | Mesurer le gain de vitesse du mode insecure |
| **VMs impliquées** | 2 VMs identiques |

```bash
# Test A : secure (SSH)
sed -i 's/migration_type = insecure/migration_type = secure/' /etc/live-migrator/live-migrator.conf
migrator-ctl.sh migrate <vm1> <target>

# Test B : insecure (TCP)
sed -i 's/migration_type = secure/migration_type = insecure/' /etc/live-migrator/live-migrator.conf
migrator-ctl.sh migrate <vm2> <target>
```

**Mesures :** Durée secure, durée insecure, ratio.

---

### Test 5 : Mode maintenance — vider un nœud (toutes VMs)

| | |
|---|---|
| **Objectif** | Vérifier que toutes les VMs running sont migrées |
| **VMs impliquées** | Toutes les VMs du nœud (5+ pour un bon test) |

```bash
# 1. Lister les VMs locales
qm list

# 2. Vider le nœud
migrator-ctl.sh maintenance

# 3. Vérifier
qm list   # Aucune VM running
migrator-ctl.sh history
```

**Mesures :** Nombre de VMs migrées, durée totale, nombre d'échecs, nœuds cibles choisis.

---

### Test 6 : Mode maintenance avec cible forcée

| | |
|---|---|
| **Objectif** | Forcer toutes les VMs vers un nœud spécifique |
| **VMs impliquées** | Toutes les VMs du nœud |

```bash
migrator-ctl.sh maintenance rem
```

**Mesures :** Toutes les VMs sont bien sur le nœud cible forcé.

---

### Test 7 : Déclenchement automatique par surcharge CPU

| | |
|---|---|
| **Objectif** | Le daemon détecte la surcharge CPU et migre automatiquement |
| **VMs impliquées** | Au moins 2 VMs sur le nœud stressé |

```bash
# 1. Config de test
sed -i 's/cpu_threshold = 90/cpu_threshold = 30/' /etc/live-migrator/live-migrator.conf
sed -i 's/hysteresis = 5/hysteresis = 0/' /etc/live-migrator/live-migrator.conf
sed -i 's/cooldown = 300/cooldown = 30/' /etc/live-migrator/live-migrator.conf
systemctl restart live-migrator

# 2. Stresser le CPU
stress --cpu $(nproc) --timeout 180 &

# 3. Observer
tail -f /var/log/live-migrator.log

# 4. Attendre la migration automatique

# 5. Nettoyer
kill %1
# Remettre les seuils normaux
sed -i 's/cpu_threshold = 30/cpu_threshold = 90/' /etc/live-migrator/live-migrator.conf
sed -i 's/hysteresis = 0/hysteresis = 5/' /etc/live-migrator/live-migrator.conf
sed -i 's/cooldown = 30/cooldown = 300/' /etc/live-migrator/live-migrator.conf
systemctl restart live-migrator
```

**Mesures :** Temps de détection (entre début stress et alerte), VM choisie, nœud cible, durée de migration.

---

### Test 8 : Déclenchement automatique par surcharge RAM

| | |
|---|---|
| **Objectif** | Le daemon détecte la surcharge RAM et migre automatiquement |
| **VMs impliquées** | Au moins 2 VMs sur le nœud stressé |

```bash
# 1. Config de test
sed -i 's/ram_threshold = 90/ram_threshold = 40/' /etc/live-migrator/live-migrator.conf
sed -i 's/cooldown = 300/cooldown = 30/' /etc/live-migrator/live-migrator.conf
systemctl restart live-migrator

# 2. Consommer de la RAM
stress --vm 4 --vm-bytes 2G --timeout 180 &

# 3. Observer
tail -f /var/log/live-migrator.log

# 4. Nettoyer après le test
kill %1
sed -i 's/ram_threshold = 40/ram_threshold = 90/' /etc/live-migrator/live-migrator.conf
sed -i 's/cooldown = 30/cooldown = 300/' /etc/live-migrator/live-migrator.conf
systemctl restart live-migrator
```

**Mesures :** Temps de détection, VM choisie (la plus gourmande en RAM), durée.

---

### Test 9 : Vérification du cooldown (anti-rafale)

| | |
|---|---|
| **Objectif** | Vérifier qu'une seule migration se déclenche par période de cooldown |
| **VMs impliquées** | 3+ VMs sur le nœud stressé |

```bash
# 1. Cooldown de 60s, seuil bas
sed -i 's/cpu_threshold = 90/cpu_threshold = 20/' /etc/live-migrator/live-migrator.conf
sed -i 's/cooldown = 300/cooldown = 60/' /etc/live-migrator/live-migrator.conf
systemctl restart live-migrator

# 2. Stresser longtemps
stress --cpu $(nproc) --timeout 300 &

# 3. Observer — on devrait voir :
# - 1ère détection → migration
# - "Cooldown active: Xs remaining" pendant 60s
# - 2ème migration après 60s
tail -f /var/log/live-migrator.log

# 4. Nettoyer
kill %1
# Remettre les seuils normaux
```

**Mesures :** Nombre de migrations, intervalle entre chaque migration (doit être ≥ cooldown).

---

### Test 10 : Mesure du downtime (ping)

| | |
|---|---|
| **Objectif** | Mesurer le temps d'interruption réel pour l'utilisateur |
| **VMs impliquées** | 1 VM avec réseau configuré |

```bash
# 1. Depuis ton laptop ou une autre machine, ping la VM toutes les 100ms
ping -i 0.1 <vm_ip> | while read line; do echo "$(date '+%H:%M:%S.%N') $line"; done | tee /tmp/ping_migration.txt &

# 2. Depuis un nœud Proxmox, migrer la VM
qm migrate <vmid> <target> --online

# 3. Arrêter le ping
kill %1

# 4. Analyser
echo "=== Paquets perdus ==="
grep -c "timeout\|no answer\|Unreachable" /tmp/ping_migration.txt || echo "0 paquets perdus"

echo "=== Latence avant migration ==="
head -20 /tmp/ping_migration.txt | grep "time="

echo "=== Latence après migration ==="
tail -20 /tmp/ping_migration.txt | grep "time="
```

**Mesures :** Nombre de paquets perdus, durée du downtime (paquets perdus × 100ms), latence avant/après.

---

### Test 11 : Migration de VMs avec différentes tailles de RAM

| | |
|---|---|
| **Objectif** | Mesurer l'impact de la taille de la RAM sur la durée |
| **VMs impliquées** | 5 VMs de tailles différentes |

| VM | RAM | Type de charge |
|----|-----|----------------|
| VM-A | 512 Mo | Idle |
| VM-B | 1 Go | Idle |
| VM-C | 2 Go | Charge légère |
| VM-D | 4 Go | Charge moyenne |
| VM-E | 8 Go | Charge moyenne |

```bash
# Migrer chacune et noter la durée
for vmid in <A> <B> <C> <D> <E>; do
  echo "--- VM $vmid ---"
  migrator-ctl.sh migrate $vmid <target>
  sleep 10  # pause entre chaque
done

migrator-ctl.sh history
```

**Mesures :** Durée pour chaque taille de RAM → tracer la courbe durée = f(RAM).

---

### Test 12 : Migrations séquentielles de 15 VMs (stress test)

| | |
|---|---|
| **Objectif** | Tester la robustesse avec un grand nombre de migrations |
| **VMs impliquées** | 15 VMs |

```bash
# Mode maintenance pour migrer toutes les VMs
migrator-ctl.sh maintenance

# Résultat attendu : 15/15 migrées, 0 failed
migrator-ctl.sh history
```

**Mesures :** Durée totale, durée de chaque migration, taux de succès, répartition sur les nœuds cibles.

---

### Test 13 : Sélection intelligente de la VM (plus grosse consommatrice)

| | |
|---|---|
| **Objectif** | Vérifier que c'est bien la VM la plus gourmande qui est migrée |
| **VMs impliquées** | 3 VMs avec des consommations CPU différentes |

```bash
# 1. Dans VM-grande : générer de la charge CPU
# Dans VM-petite : laisser idle

# 2. Déclencher une migration auto (baisser le seuil)

# 3. Vérifier dans les logs quelle VM a été choisie
grep "MIGRATION TRIGGERED" /var/log/live-migrator.log | tail -1
```

**Mesures :** VM choisie, sa consommation CPU vs les autres.

---

### Test 14 : Reprise après échec de migration

| | |
|---|---|
| **Objectif** | Vérifier que l'outil gère proprement un échec |
| **VMs impliquées** | 1 VM avec configuration invalide |

```bash
# Simuler un échec : migrer vers un nœud inexistant
migrator-ctl.sh migrate <vmid> noeud_inexistant

# Vérifier : la VM est toujours sur le nœud d'origine
qm status <vmid>
migrator-ctl.sh history  # doit montrer FAILED
```

**Mesures :** Message d'erreur, VM toujours fonctionnelle, entrée dans l'historique.

---

### Test 15 : Fonctionnement continu du daemon (24h)

| | |
|---|---|
| **Objectif** | Vérifier la stabilité du daemon sur une longue période |
| **VMs impliquées** | Toutes |

```bash
# 1. Vérifier que le daemon tourne
migrator-ctl.sh status

# 2. Attendre 24h

# 3. Revérifier
migrator-ctl.sh status
journalctl -u live-migrator --no-pager -n 50
# Le daemon doit toujours tourner sans erreur
```

**Mesures :** Uptime du daemon, mémoire utilisée par le processus, nombre de vérifications effectuées.

---

### Tableau récapitulatif des tests

| # | Test | VMs | Type | Mesure principale |
|---|------|-----|------|-------------------|
| 1 | Lecture métriques | 0 | Fonctionnel | Exactitude des valeurs |
| 2 | Migration manuelle | 1 | Fonctionnel | Durée, succès |
| 3 | XBZRLE on/off | 2 | Performance | Comparaison durées |
| 4 | Secure vs insecure | 2 | Performance | Ratio de vitesse |
| 5 | Maintenance auto | 5+ | Fonctionnel | Toutes migrées |
| 6 | Maintenance forcée | 5+ | Fonctionnel | Cible correcte |
| 7 | Auto-trigger CPU | 2+ | Automatique | Temps de détection |
| 8 | Auto-trigger RAM | 2+ | Automatique | VM la plus gourmande |
| 9 | Cooldown | 3+ | Anti-rafale | Intervalle respecté |
| 10 | Downtime (ping) | 1 | Performance | ms de coupure |
| 11 | Tailles de RAM | 5 | Performance | Durée = f(RAM) |
| 12 | Stress 15 VMs | 15 | Robustesse | Taux de succès |
| 13 | Sélection VM | 3 | Intelligence | Bonne VM choisie |
| 14 | Reprise après échec | 1 | Résilience | VM intacte |
| 15 | Stabilité 24h | Toutes | Stabilité | Uptime daemon |

---

## 3. Outil d'analyse des logs

### Installation

```bash
# matplotlib est nécessaire pour les graphiques
pip3 install matplotlib
# ou
apt install python3-matplotlib -y
```

### Utilisation

```bash
# Copier les logs depuis le cluster vers ton laptop
scp root@<IP_NOEUD>:/var/lib/live-migrator/migration_history.log ./
scp root@<IP_NOEUD>:/var/log/live-migrator.log ./

# Lancer l'analyse (les 2 fichiers ensemble pour un rapport complet)
python3 scripts/analyze_migrations.py migration_history.log live-migrator.log

# Ou avec un dossier de sortie personnalisé
python3 scripts/analyze_migrations.py migration_history.log --output-dir ./rapport
```

### Graphiques générés

| Fichier | Description | Utile pour |
|---------|-------------|------------|
| `migration_durations.png` | Barre : durée de chaque migration, colorée par raison | Comparer les performances |
| `migration_success_rate.png` | Camembert : % réussies vs échouées | Vue globale fiabilité |
| `migration_timeline.png` | Scatter : quand chaque migration a eu lieu | Voir les pics d'activité |
| `migration_by_reason.png` | Barre : nombre par raison (CPU, RAM, temp, maintenance) | Identifier les causes principales |
| `migration_by_target.png` | Barre : combien de VMs chaque nœud a reçu | Vérifier la distribution |
| `metrics_over_time.png` | Lignes : CPU/RAM/temp avec seuils | Voir l'évolution des métriques |
| `rapport_migrations.txt` | Texte : statistiques complètes | Insérer dans le rapport |

### Format du rapport textuel

```
===========================================================
   RAPPORT D'ANALYSE DES MIGRATIONS
===========================================================

Période : 2026-04-18 16:34:45 → 2026-04-18 18:20:30
Total migrations : 23
  Réussies : 21 (91.3%)
  Échouées : 2 (8.7%)

--- Durées (migrations réussies) ---
  Minimum  : 12s
  Maximum  : 95s
  Moyenne  : 38.4s
  Médiane  : 32s
  Total    : 807s (13.4 min)

--- Répartition par raison ---
  maintenance                    : 10 (43.5%)
  cpu(...)                       :  6 (26.1%)
  temperature(...)               :  4 (17.4%)
  manual                         :  3 (13.0%)
  ...
```

---

## 4. Algorithmes du système

### 4.1 Algorithme principal — Boucle de surveillance

```
ALGORITHME : SurveillanceContinue

ENTRÉES :
  seuil_temp, seuil_cpu, seuil_ram   : seuils de déclenchement
  hystérésis                          : marge anti-yo-yo (%)
  intervalle                          : période de vérification (s)
  cooldown                            : temps min entre 2 migrations (s)

DÉBUT
  TANT QUE daemon_actif :
    temp ← LireTemperatureCPU()
    cpu  ← LireChargeCPU()
    ram  ← LireUtilisationRAM()

    alerte ← FAUX
    raison ← ""

    // Check prioritaire : Température
    SI temp > seuil_temp ALORS
      alerte ← VRAI
      raison ← "temperature"

    // Check 2 : CPU (avec hystérésis)
    SINON SI cpu > (seuil_cpu + hystérésis) ALORS
      alerte ← VRAI
      raison ← "cpu"

    // Check 3 : RAM
    SINON SI ram > seuil_ram ALORS
      alerte ← VRAI
      raison ← "ram"

    FIN SI

    SI alerte ET PAS CooldownActif() ET CompterVMsLocales() > 0 ALORS
      vm     ← ChoisirVMàMigrer(raison)
      cible  ← ChoisirMeilleurNoeud()

      SI vm ≠ ∅ ET cible ≠ ∅ ALORS
        MigrerVM(vm, cible, raison)
        DémarrerCooldown()
      FIN SI
    FIN SI

    Attendre(intervalle)
  FIN TANT QUE
FIN
```

### 4.2 Algorithme de sélection de la VM à migrer

```
ALGORITHME : ChoisirVMàMigrer(raison)

ENTRÉE  : raison (temperature | cpu | ram)
SORTIE  : vmid de la VM à migrer

DÉBUT
  vms ← ListeVMsLocalesEnCours()
  meilleure_vm ← ∅
  meilleur_score ← -1

  POUR CHAQUE vm DANS vms :
    SI raison = "temperature" OU raison = "cpu" ALORS
      score ← ConsommationCPU(vm)    // via API Proxmox
    SINON SI raison = "ram" ALORS
      score ← ConsommationRAM(vm)    // via API Proxmox
    FIN SI

    SI score > meilleur_score ALORS
      meilleur_score ← score
      meilleure_vm ← vm
    FIN SI
  FIN POUR

  RETOURNER meilleure_vm
FIN
```

**Complexité :** O(n) où n = nombre de VMs locales.

**Justification :** On migre la VM qui consomme le plus de la ressource en surcharge. C'est celle qui libérera le plus de capacité en une seule migration, minimisant le nombre total de migrations nécessaires.

### 4.3 Algorithme de sélection du nœud cible

```
ALGORITHME : ChoisirMeilleurNoeud()

SORTIE : nom du nœud cible

DÉBUT
  noeud_local ← NomHôte()
  meilleur_noeud ← ∅
  meilleure_ram_libre ← 0

  noeuds ← RécupérerNoeudsCluster()     // via API Proxmox

  POUR CHAQUE noeud DANS noeuds :
    SI noeud = noeud_local ALORS
      CONTINUER                          // on ne migre pas vers soi-même

    SI noeud.statut ≠ "online" ALORS
      CONTINUER                          // ignorer les nœuds hors ligne

    ram_libre ← noeud.ram_totale - noeud.ram_utilisée

    SI ram_libre > meilleure_ram_libre ALORS
      meilleure_ram_libre ← ram_libre
      meilleur_noeud ← noeud
    FIN SI
  FIN POUR

  RETOURNER meilleur_noeud
FIN
```

**Complexité :** O(k) où k = nombre de nœuds dans le cluster.

**Critère de sélection :** RAM libre (= RAM totale − RAM utilisée). Le nœud avec le plus de RAM libre est le plus capable d'accueillir une nouvelle VM. Ce critère est préféré au CPU car la RAM est la ressource la plus contraignante pour une migration (la VM ne peut pas démarrer si le nœud n'a pas assez de RAM).

### 4.4 Algorithme du mécanisme d'hystérésis

```
ALGORITHME : MécanismeHystérésis

Objectif : empêcher les migrations en yo-yo

PARAMÈTRES :
  seuil = 90%
  hystérésis = 5%

RÈGLE DE DÉCLENCHEMENT :
  Migration si valeur > seuil + hystérésis (95%)

RÈGLE DE NORMALISATION :
  Situation considérée « normale » si valeur < seuil (90%)

ZONE MORTE :
  Entre 90% et 95% → AUCUNE ACTION

DIAGRAMME D'ÉTAT :

  ┌──────────┐   valeur > 95%    ┌──────────────┐
  │  NORMAL  │ ──────────────── │  EN ALERTE   │
  │          │                   │  (migrer)    │
  │          │   valeur < 90%    │              │
  │          │ ◄──────────────── │              │
  └──────────┘                   └──────────────┘
        ▲                              │
        │     Entre 90% et 95%         │
        │     → pas de changement      │
        └──────────────────────────────┘
```

### 4.5 Algorithme du cooldown (anti-rafale)

```
ALGORITHME : CooldownActif()

SORTIE : VRAI si on ne peut pas migrer, FAUX sinon

DÉBUT
  SI fichier_timestamp_dernière_migration EXISTE ALORS
    dernier_ts ← LireFichier(fichier_timestamp)
    maintenant ← TempsActuel()
    écoulé ← maintenant - dernier_ts

    SI écoulé < cooldown ALORS
      RETOURNER VRAI       // cooldown actif, on attend
    FIN SI
  FIN SI

  RETOURNER FAUX             // pas de cooldown, on peut migrer
FIN
```

### 4.6 Algorithme de configuration XBZRLE

```
ALGORITHME : ConfigurerXBZRLE(vmid)

DÉBUT
  SI enable_xbzrle = 1 ALORS
    conf ← "/etc/pve/qemu-server/<vmid>.conf"

    // Ajouter les paramètres de compression AVANT la migration
    AjouterLigne(conf, "migrate_compression: xbzrle")
    AjouterLigne(conf, "migrate_compression_cache: 1638400")

    // Proxmox lira ces paramètres automatiquement
  FIN SI
FIN

ALGORITHME : NettoyerXBZRLE(vmid)

DÉBUT
  conf ← "/etc/pve/qemu-server/<vmid>.conf"
  SupprimerLignesCommençantPar(conf, "migrate_compression")
  // Nettoyage APRÈS la migration (succès ou échec)
FIN
```

### 4.7 Algorithme du mode maintenance

```
ALGORITHME : ModeMaintenance(cible_forcée)

ENTRÉE  : cible_forcée (optionnel, nom du nœud)
SORTIE  : nombre de VMs migrées avec succès

DÉBUT
  vms ← ListeVMsLocalesEnCours()
  total ← |vms|
  succès ← 0

  POUR i DE 1 À total :
    vm ← vms[i]

    SI cible_forcée ≠ ∅ ALORS
      cible ← cible_forcée
    SINON
      cible ← ChoisirMeilleurNoeud()     // Recalculé à chaque itération
    FIN SI

    SI cible = ∅ ALORS
      Logger("Pas de nœud disponible pour VM " + vm)
      CONTINUER
    FIN SI

    Afficher("[" + i + "/" + total + "] Migration VM " + vm + " → " + cible)

    SI MigrerVM(vm, cible, "maintenance") = SUCCÈS ALORS
      succès ← succès + 1
    FIN SI
  FIN POUR

  Afficher("Migrées : " + succès + "/" + total)
  RETOURNER succès
FIN
```

**Point important :** `ChoisirMeilleurNoeud()` est appelé **avant chaque migration**, pas une seule fois au début. Cela permet de distribuer les VMs sur plusieurs nœuds (le nœud ayant reçu la VM précédente a maintenant moins de RAM libre).

### 4.8 Algorithme du pre-copy (exécuté par Proxmox/QEMU)

```
ALGORITHME : PreCopyMigration (natif QEMU, pas dans notre code)

DÉBUT
  // Phase 1 : Copie initiale
  VM continue de tourner
  Copier TOUTE la RAM vers le nœud cible

  // Phase 2 : Itérations de convergence
  RÉPÉTER
    dirty_pages ← pages modifiées depuis la dernière copie
    Copier dirty_pages vers le nœud cible
  JUSQU'À |dirty_pages| < seuil_convergence
         OU nombre_d_itérations > max_itérations

  // Phase 3 : Pause et transfert final
  PAUSE la VM (micro-freeze de 10-500ms)
  Copier les dernières dirty pages
  Copier les registres CPU + état des périphériques

  // Phase 4 : Reprise
  REPRENDRE la VM sur le nœud cible
  Libérer les ressources sur le nœud source
FIN
```

Ce n'est PAS notre code — c'est ce que fait QEMU en interne quand on appelle `qm migrate --online`. Notre outil décide simplement **quand** et **vers où** déclencher cette commande.
