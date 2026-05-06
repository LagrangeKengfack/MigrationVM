# Algorithmes — Live Migrator v2

Ce document détaille tous les algorithmes utilisés par le daemon `live-migrator`.

---

## 1. Sélection du meilleur nœud cible

Utilisé par : `MIGRATE_VM`, `LIGHTEN_NODE`, `CONSOLIDATE_VM`, `PLACE_VM`

```
ENTRÉES :
  vmid      : ID de la VM à migrer (peut être ∅ pour LIGHTEN_NODE)
  resource  : "ram" ou "cpu" (pour savoir quel critère prioriser)

SORTIE : nom du nœud cible, ou ∅

DÉBUT
  noeud_local ← NomHôte()

  // 1. Collecter les métriques du cluster via pvesh API
  POUR CHAQUE noeud DANS pvesh(/cluster/resources?type=node) :
    SI noeud.statut ≠ "online" OU noeud = noeud_local → IGNORER
    noeuds[noeud] = {
      cpu_pct   = (cpu_utilisé / cpu_total) × 100
      ram_pct   = (ram_utilisée / ram_totale) × 100
      ram_libre = ram_totale - ram_utilisée   // en octets
    }

  // 2. Exclure les nœuds aussi chargés que le nœud local
  charge_locale ← noeuds[noeud_local].ram_pct
  candidats ← noeuds OÙ ram_pct < (charge_locale - 10%)

  SI candidats est vide → RETOURNER ∅

  // 3. Trier par pourcentage d'utilisation croissant
  SI resource = "cpu" ALORS
    Trier candidats par cpu_pct croissant
  SINON
    Trier candidats par ram_pct croissant

  // 4. Vérifier la capacité absolue
  SI vmid ≠ ∅ ALORS
    ram_vm ← LireConfigVM(vmid).memory × 1024 × 1024  // Mo → octets
    POUR CHAQUE candidat (du moins chargé au plus chargé) :
      SI candidat.ram_libre ≥ ram_vm ALORS
        RETOURNER candidat
  SINON
    RETOURNER candidats[0]

  RETOURNER ∅
FIN
```

**Pourquoi 2 étapes (% puis absolu) :**

| Nœud | Total | Utilisé | % | Libre |
|------|-------|---------|---|-------|
| REM | 64 Go | 50 Go | 78% | 14 Go |
| RAM | 32 Go | 16 Go | 50% | 16 Go |
| EMILIA | 32 Go | 28 Go | 87% | 4 Go |

VM à migrer = 8 Go. En triant par %, RAM (50%) est le moins chargé et a 16 Go libre ≥ 8 Go → choisi. Sans les %, on pourrait choisir un nœud à 87% avec 4 Go libres.

---

## 2. Sélection de la VM à migrer (pour LIGHTEN_NODE)

```
ENTRÉES :
  resource : "ram" ou "cpu"

SORTIE : vmid de la VM à migrer

DÉBUT
  vms ← liste des VMs running sur le nœud local (qm list)

  SI resource = "ram" ALORS
    // Trier par consommation RAM décroissante
    POUR CHAQUE vm :
      vm.usage = LireConfigVM(vm.id).memory  // RAM configurée
    Trier vms par usage décroissant
  SINON  // cpu
    // Trier par nombre de vCPU décroissant
    POUR CHAQUE vm :
      vm.usage = LireConfigVM(vm.id).cores × LireConfigVM(vm.id).sockets
    Trier vms par usage décroissant

  // Exclure les VMs en cooldown
  POUR CHAQUE vm (de la plus gourmande à la moins) :
    SI PasEnCooldown(vm.id) ALORS
      RETOURNER vm.id

  RETOURNER ∅  // Toutes en cooldown
FIN
```

---

## 3. Sélection du meilleur nœud GPU

Utilisé par : `GPU_REQUEST`

```
ENTRÉES :
  vmid            : ID de la VM à migrer
  gpu_nodes_usage : chaîne "emilia:45,rem:82,ram:none"

SORTIE : nom du nœud cible

DÉBUT
  // 1. Parser les données GPU de l'agent
  gpu_data ← {}
  POUR CHAQUE entrée DANS gpu_nodes_usage.split(",") :
    noeud, pct = entrée.split(":")
    SI pct = "none" → IGNORER (pas de GPU)
    gpu_data[noeud] = pct (entier)

  SI gpu_data est vide → RETOURNER ∅  // Aucun nœud avec GPU

  // 2. Trier par utilisation GPU croissante
  candidats ← Trier gpu_data par pct croissant

  // 3. Vérifier que le nœud peut accueillir la VM (RAM)
  ram_vm ← LireConfigVM(vmid).memory
  POUR CHAQUE candidat (du GPU le moins sollicité au plus) :
    ram_libre ← RamLibre(candidat.noeud)
    SI ram_libre ≥ ram_vm ET candidat.noeud ≠ noeud_local ALORS
      RETOURNER candidat.noeud

  RETOURNER ∅
FIN
```

---

## 4. Harmonisation du cluster (pour consolidation)

Utilisé par : `CONSOLIDATE_VM` quand aucun nœud n'a directement assez de place.

**Principe :** Si une VM de 5 Go doit être consolidée mais chaque nœud n'a que 2 Go de libre, on déplace des petites VMs pour "libérer" assez de place sur un nœud.

```
ENTRÉES :
  vmid          : ID de la VM à consolider
  min_ram_mb    : RAM totale requise (ex: 5120 Mo = 5 Go)
  nodes_involved : nœuds où la RAM est actuellement dispersée

SORTIE : noeud_cible OU ∅

DÉBUT
  // 1. Vérification directe : un nœud peut-il accueillir sans rien bouger ?
  POUR CHAQUE noeud (trié par ram_libre déc.) :
    SI noeud.ram_libre ≥ min_ram_mb ALORS
      RETOURNER noeud  // Cas simple, pas d'harmonisation nécessaire

  // 2. Pas de place directe → tenter l'harmonisation
  // Pour chaque nœud candidat, calculer combien de RAM il faut libérer
  POUR CHAQUE noeud_cible (trié par ram_libre déc.) :
    deficit = min_ram_mb - noeud_cible.ram_libre

    SI deficit ≤ 0 → RETOURNER noeud_cible  // Ne devrait pas arriver ici

    // 3. Trouver des VMs "déplaçables" sur noeud_cible
    //    pour libérer au moins 'deficit' Mo
    vms_sur_cible ← VMs running sur noeud_cible, triées par RAM croissante
    vms_a_deplacer ← []
    ram_liberee ← 0

    POUR CHAQUE vm DANS vms_sur_cible :
      SI vm.id = vmid → IGNORER (ne pas déplacer la VM qu'on consolide)
      SI vm.ram ≤ deficit ET PasEnCooldown(vm.id) ALORS
        // Vérifier qu'on peut placer cette VM ailleurs
        autre_noeud ← ChoisirMeilleurNoeud(vm.id, "ram")
        SI autre_noeud ≠ ∅ ALORS
          vms_a_deplacer ← vms_a_deplacer + [vm, autre_noeud]
          ram_liberee ← ram_liberee + vm.ram
          SI ram_liberee ≥ deficit → SORTIR DE LA BOUCLE

    SI ram_liberee ≥ deficit ALORS
      // 4. Exécuter les migrations préparatoires
      POUR CHAQUE (vm, dest) DANS vms_a_deplacer :
        Migrer(vm.id, dest)

      // 5. Maintenant noeud_cible a assez de place
      RETOURNER noeud_cible

  RETOURNER ∅  // Impossible même avec harmonisation
FIN
```

**Exemple concret :**

```
État initial :
  REM    : 64 Go total, 62 Go utilisés, 2 Go libres
  RAM    : 32 Go total, 30 Go utilisés, 2 Go libres
  EMILIA : 32 Go total, 29 Go utilisés, 3 Go libres

VM 108 : 5 Go dispersés (3 Go sur REM + 2 Go sur EMILIA)
→ Aucun nœud n'a 5 Go libres

Harmonisation sur EMILIA (3 Go libres, le plus) :
  Déficit = 5 Go - 3 Go = 2 Go à libérer
  VM 112 (2 Go) est sur EMILIA → déplaçable vers RAM ? Non (2 Go libres pile)
  VM 115 (1 Go) est sur EMILIA → déplaçable vers REM ? Oui (2 Go libres)
  VM 116 (1 Go) est sur EMILIA → déplaçable vers RAM ? Oui (2 Go libres)
  RAM libérée = 1 + 1 = 2 Go ≥ déficit

  → Migrer VM 115 → REM, VM 116 → RAM
  → EMILIA a maintenant 5 Go libres
  → Consolider VM 108 sur EMILIA
```

---

## 5. Placement des nouvelles VMs

```
DÉCLENCHEUR : inotifywait détecte un nouveau fichier .conf
              dans /etc/pve/qemu-server/

DÉBUT
  Attendre 2 secondes  // Laisser Proxmox finir d'écrire le .conf

  vmid ← extraire du nom de fichier (<vmid>.conf)
  ram_vm ← LireConfigVM(vmid).memory
  ram_libre_locale ← RamLibre(noeud_local)

  SI ram_libre_locale ≥ ram_vm ALORS
    Logger("VM $vmid reste ici, assez de ressources")
    SORTIR

  // Pas assez de place localement
  cible ← ChoisirMeilleurNoeud(vmid, "ram")
  SI cible ≠ ∅ ALORS
    qm migrate $vmid $cible  // Migration à froid (VM éteinte)
    Logger("VM $vmid placée sur $cible")
  SINON
    Logger("WARN: aucun nœud ne peut accueillir VM $vmid")
FIN
```

---

## 6. Mode maintenance (vidage de nœud)

```
ENTRÉES :
  noeud_cible_forcé : ∅ ou nom d'un nœud (si l'admin force un choix)

DÉBUT
  vms ← VMs running sur le nœud local
  total ← |vms|
  succès ← 0

  POUR i, vm DANS vms :
    SI noeud_cible_forcé ≠ ∅ ALORS
      cible ← noeud_cible_forcé
    SINON
      // RE-CALCULER à chaque VM (la charge change après chaque migration)
      cible ← ChoisirMeilleurNoeud(vm.id, "ram")

    SI cible = ∅ ALORS
      Logger("ERREUR: pas de nœud pour VM $vm.id")
      CONTINUER

    Afficher("[$(i+1)/$total] Migration VM $vm.id → $cible ...")
    résultat ← qm migrate $vm.id $cible --online
    SI résultat = OK ALORS
      succès++
      Afficher("OK")
    SINON
      Afficher("ÉCHEC")

  Afficher("Migrated: $succès/$total")
  SI succès = total → Afficher("Node is ready for maintenance")
FIN
```

---

## 7. Cooldown par VM (anti-ping-pong)

```
FICHIER : /var/lib/live-migrator/vm_cooldowns/<vmid>
CONTENU : timestamp de la dernière migration

FONCTION PasEnCooldown(vmid) :
  fichier ← /var/lib/live-migrator/vm_cooldowns/$vmid
  SI fichier n'existe pas → RETOURNER VRAI

  dernier_ts ← lire fichier
  maintenant ← date +%s
  écoulé ← maintenant - dernier_ts

  SI écoulé ≥ COOLDOWN (300s par défaut) ALORS
    RETOURNER VRAI
  SINON
    Logger("Cooldown actif pour VM $vmid : $(COOLDOWN - écoulé)s restantes")
    RETOURNER FAUX

FONCTION EnregistrerMigration(vmid) :
  date +%s > /var/lib/live-migrator/vm_cooldowns/$vmid
```

---

## 8. Traitement des signaux (dispatch)

```
ENTRÉE : chemin du fichier .sig

DÉBUT
  // Parser le fichier clé=valeur
  signal ← {}
  POUR CHAQUE ligne DANS fichier :
    clé, valeur ← ligne.split("=")
    signal[clé] ← valeur

  // Dispatcher selon le type
  SELON signal.type :
    "MIGRATE_VM" :
      SI signal.vmid est vide → réponse REFUSED/VM_NOT_FOUND
      SI PasRunning(signal.vmid) → réponse REFUSED/VM_NOT_FOUND
      SI PasEnCooldown(signal.vmid) = FAUX → réponse REFUSED/COOLDOWN_ACTIVE
      cible ← ChoisirMeilleurNoeud(signal.vmid, "ram")
      SI cible = ∅ → réponse REFUSED/NO_SUITABLE_NODE
      Migrer(signal.vmid, cible) → réponse SUCCESS/MIGRATED ou FAILED

    "LIGHTEN_NODE" :
      vmid ← ChoisirVMàMigrer(signal.resource)
      SI vmid = ∅ → réponse REFUSED/VM_NOT_FOUND
      cible ← ChoisirMeilleurNoeud(vmid, signal.resource)
      SI cible = ∅ → réponse REFUSED/NO_SUITABLE_NODE ou ALL_NODES_EQUALLY_LOADED
      Migrer(vmid, cible)

    "GPU_REQUEST" :
      cible ← ChoisirMeilleurNoeudGPU(signal.vmid, signal.gpu_nodes_usage)
      SI cible = ∅ → réponse REFUSED/NO_SUITABLE_NODE
      Migrer(signal.vmid, cible)

    "CONSOLIDATE_VM" :
      cible ← Harmoniser(signal.vmid, signal.min_ram_mb, signal.min_vcpu, signal.nodes_involved)
      SI cible ≠ ∅ → Migrer(signal.vmid, cible) → réponse SUCCESS/CONSOLIDATED
      SINON → réponse REFUSED/CONSOLIDATION_IMPOSSIBLE

  // Déplacer le signal vers processed/
  Déplacer fichier → /var/lib/live-migrator/signals/processed/
FIN
```

---

## 9. File d'attente et priorité

```
Quand plusieurs signaux arrivent simultanément :

  1. Lire tous les fichiers .sig du répertoire
  2. Parser tous les signaux
  3. Trier par urgency :
     critical > high > medium > low
  4. À urgence égale : premier arrivé (timestamp) en premier
  5. Traiter un par un (pas de migration parallèle)
  6. Si file > 10 signaux → Logger alerte admin
```
