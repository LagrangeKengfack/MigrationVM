#!/bin/bash
# ============================================================================
# live-migrator.sh — Orchestrateur de migration v2 pour Proxmox VE
#
# Architecture signal-driven : réagit aux signaux des agents RAM, vCPU, GPU
# via inotifywait sur le répertoire de signaux. Gère aussi le placement
# automatique des nouvelles VMs et la consolidation des VMs à RAM dispersée.
#
# Usage :
#   live-migrator.sh [-c config] [-f] [-h]
#   -c : chemin vers le fichier de configuration
#   -f : mode foreground (pas de daemonisation)
#   -h : aide
# ============================================================================

set -euo pipefail

# ---- Defaults ----
CONF_FILE="/etc/live-migrator/live-migrator.conf"
LOG_FILE="/var/log/live-migrator.log"
STATE_DIR="/var/lib/live-migrator"
SIGNAL_DIR="/var/lib/live-migrator/signals"
PID_FILE="/var/run/live-migrator.pid"
FOREGROUND=0

# Seuils par défaut
TEMP_THRESHOLD=80           # °C — migrer si CPU > 80°C
CPU_THRESHOLD=90            # % — migrer si load > 90% (relatif au nb de cores)
RAM_THRESHOLD=90            # % — migrer si RAM utilisée > 90%
CHECK_INTERVAL=15           # secondes entre chaque vérification (mode legacy)
COOLDOWN=300                # secondes minimum entre deux migrations d'une même VM
MIGRATION_TYPE="secure"     # secure ou insecure
ENABLE_XBZRLE=0             # 1 pour activer la compression XBZRLE
MAX_PARALLEL=1              # nombre de migrations simultanées
HYSTERESIS=5                # % — ne pas re-déclencher si seuil - hysteresis
ENABLE_AUTO_PLACEMENT=1     # 1 pour activer le placement automatique des nouvelles VMs
MARGIN_PCT=10               # marge min en % entre source et cible pour autoriser migration

# ---- Logging ----
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    logger -t live-migrator -p "daemon.${level,,}" "$msg" 2>/dev/null || true
    if [ "$FOREGROUND" -eq 1 ]; then
        echo "[$ts] [$level] $msg"
    fi
}

# ---- Configuration ----
load_config() {
    if [ -f "$CONF_FILE" ]; then
        log INFO "Loading config from $CONF_FILE"
        while IFS='=' read -r key value; do
            # Ignorer commentaires et lignes vides
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ "$key" =~ ^[[:space:]]*\[ ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/#.*//')
            case "$key" in
                temp_threshold)         TEMP_THRESHOLD="$value" ;;
                cpu_threshold)          CPU_THRESHOLD="$value" ;;
                ram_threshold)          RAM_THRESHOLD="$value" ;;
                check_interval)         CHECK_INTERVAL="$value" ;;
                cooldown)               COOLDOWN="$value" ;;
                migration_type)         MIGRATION_TYPE="$value" ;;
                enable_xbzrle)          ENABLE_XBZRLE="$value" ;;
                max_parallel)           MAX_PARALLEL="$value" ;;
                log_file)               LOG_FILE="$value" ;;
                state_dir)              STATE_DIR="$value" ;;
                hysteresis)             HYSTERESIS="$value" ;;
                signal_dir)             SIGNAL_DIR="$value" ;;
                enable_auto_placement)  ENABLE_AUTO_PLACEMENT="$value" ;;
                margin_pct)             MARGIN_PCT="$value" ;;
            esac
        done < "$CONF_FILE"
    else
        log WARN "Config file $CONF_FILE not found, using defaults"
    fi
}

dump_config() {
    log INFO "Configuration:"
    log INFO "  temp_threshold=$TEMP_THRESHOLD°C"
    log INFO "  cpu_threshold=$CPU_THRESHOLD%"
    log INFO "  ram_threshold=$RAM_THRESHOLD%"
    log INFO "  cooldown=${COOLDOWN}s"
    log INFO "  migration_type=$MIGRATION_TYPE"
    log INFO "  enable_xbzrle=$ENABLE_XBZRLE"
    log INFO "  signal_dir=$SIGNAL_DIR"
    log INFO "  auto_placement=$ENABLE_AUTO_PLACEMENT"
    log INFO "  margin_pct=$MARGIN_PCT%"
}

# ---- Métriques système ----

# Retourne la température CPU max en °C
get_cpu_temp() {
    local max_temp=0
    if [ -d /sys/class/thermal ]; then
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            if [ -f "$zone" ]; then
                local temp
                temp=$(cat "$zone" 2>/dev/null || echo 0)
                if [ "$temp" -gt 1000 ]; then
                    temp=$((temp / 1000))
                fi
                if [ "$temp" -gt "$max_temp" ]; then
                    max_temp=$temp
                fi
            fi
        done
    fi
    if [ "$max_temp" -eq 0 ] && command -v sensors &>/dev/null; then
        max_temp=$(sensors 2>/dev/null | grep -oP '\+\K[0-9]+(?=\.[0-9]*°C)' | sort -rn | head -1 || echo 0)
    fi
    echo "$max_temp"
}

# Retourne l'utilisation CPU en % (basée sur le load average 1min vs nombre de cores)
get_cpu_usage() {
    local load_1m
    load_1m=$(awk '{print $1}' /proc/loadavg)
    local ncpus
    ncpus=$(nproc)
    echo "$load_1m $ncpus" | awk '{printf "%d", ($1 / $2) * 100}'
}

# Retourne l'utilisation RAM en %
get_ram_usage() {
    awk '/MemTotal/{total=$2} /MemAvailable/{avail=$2} END{printf "%d", ((total-avail)/total)*100}' /proc/meminfo
}

# ---- Gestion du cluster ----

# Liste les VMs en cours d'exécution sur le nœud local
get_local_running_vms() {
    qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'
}

# Retourne le nombre de VMs locales
count_local_vms() {
    get_local_running_vms | wc -l
}

# Récupère les métriques de tous les nœuds du cluster via pvesh API
# Retourne un tableau JSON avec node, status, cpu, maxcpu, mem, maxmem
get_cluster_nodes() {
    pvesh get /cluster/resources --type node --output-format json 2>/dev/null || echo "[]"
}

# Retourne les infos RAM d'une VM : memory en Mo (configurée)
get_vm_ram_mb() {
    local vmid="$1"
    local conf="/etc/pve/qemu-server/${vmid}.conf"
    if [ -f "$conf" ]; then
        grep -oP 'memory:\s*\K[0-9]+' "$conf" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Retourne le nombre total de vCPU d'une VM (cores × sockets)
get_vm_vcpu() {
    local vmid="$1"
    local conf="/etc/pve/qemu-server/${vmid}.conf"
    local cores=1
    local sockets=1
    if [ -f "$conf" ]; then
        cores=$(grep -oP 'cores:\s*\K[0-9]+' "$conf" 2>/dev/null || echo 1)
        sockets=$(grep -oP 'sockets:\s*\K[0-9]+' "$conf" 2>/dev/null || echo 1)
    fi
    echo $((cores * sockets))
}

# ===========================================================================
# ---- SÉLECTION DU MEILLEUR NŒUD (v2 — pourcentage d'abord, capacité ensuite)
# ===========================================================================

select_best_target_v2() {
    local vmid="${1:-}"          # ID VM (optionnel pour LIGHTEN_NODE)
    local resource="${2:-ram}"   # "ram" ou "cpu"

    local local_node
    local_node=$(hostname)

    local cluster_json
    cluster_json=$(get_cluster_nodes)

    # Utiliser python3 pour parser les données du cluster et sélectionner le meilleur nœud
    local vm_ram_mb=0
    if [ -n "$vmid" ]; then
        vm_ram_mb=$(get_vm_ram_mb "$vmid")
    fi

    python3 -c "
import sys, json

cluster = json.loads('''$cluster_json''')
local_node = '$local_node'
resource = '$resource'
margin = $MARGIN_PCT
vm_ram_bytes = $vm_ram_mb * 1024 * 1024  # Mo → octets

# Collecter les métriques
nodes = {}
for n in cluster:
    name = n.get('node', '')
    status = n.get('status', '')
    if not name or status != 'online':
        continue
    nodes[name] = {
        'ram_pct': (n.get('mem', 0) / n.get('maxmem', 1)) * 100 if n.get('maxmem', 0) > 0 else 100,
        'cpu_pct': n.get('cpu', 0) * 100,
        'ram_libre': n.get('maxmem', 0) - n.get('mem', 0),
    }

if local_node not in nodes:
    sys.exit(0)

local_pct = nodes[local_node]['ram_pct'] if resource == 'ram' else nodes[local_node]['cpu_pct']

# Candidats : nœuds significativement moins chargés (marge de margin%)
candidates = []
for name, m in nodes.items():
    if name == local_node:
        continue
    node_pct = m['ram_pct'] if resource == 'ram' else m['cpu_pct']
    if node_pct < (local_pct - margin):
        candidates.append((name, m))

if not candidates:
    sys.exit(0)

# Trier par % croissant
key = 'cpu_pct' if resource == 'cpu' else 'ram_pct'
candidates.sort(key=lambda x: x[1][key])

# Vérifier la capacité absolue si VM spécifiée
if vm_ram_bytes > 0:
    for name, m in candidates:
        if m['ram_libre'] >= vm_ram_bytes:
            print(name)
            sys.exit(0)
    # Aucun candidat n'a assez de RAM absolue
    sys.exit(0)
else:
    print(candidates[0][0])
" 2>/dev/null || echo ""
}

# ===========================================================================
# ---- SÉLECTION DU MEILLEUR NŒUD GPU
# ===========================================================================

select_best_gpu_node() {
    local vmid="$1"
    local gpu_nodes_usage="$2"   # format: "emilia:45,rem:82,ram:none"

    local vm_ram_bytes
    vm_ram_bytes=$(( $(get_vm_ram_mb "$vmid") * 1024 * 1024 ))

    local local_node
    local_node=$(hostname)

    local cluster_json
    cluster_json=$(get_cluster_nodes)

    python3 -c "
import sys, json

gpu_usage_str = '$gpu_nodes_usage'
local_node = '$local_node'
vm_ram_bytes = $vm_ram_bytes

cluster = json.loads('''$cluster_json''')

# Construire les métriques RAM par nœud
ram_libre = {}
for n in cluster:
    name = n.get('node', '')
    if name and n.get('status') == 'online':
        ram_libre[name] = n.get('maxmem', 0) - n.get('mem', 0)

# Parser gpu_nodes_usage
gpu_nodes = []
for entry in gpu_usage_str.split(','):
    parts = entry.strip().split(':')
    if len(parts) != 2:
        continue
    node, pct = parts[0].strip(), parts[1].strip()
    if pct == 'none':
        continue  # Pas de GPU
    try:
        gpu_nodes.append((node, int(pct)))
    except ValueError:
        continue

if not gpu_nodes:
    sys.exit(0)

# Trier par utilisation GPU croissante (le moins sollicité d'abord)
gpu_nodes.sort(key=lambda x: x[1])

# Choisir le premier qui a assez de RAM et n'est pas le nœud local
for node, pct in gpu_nodes:
    if node == local_node:
        continue
    free = ram_libre.get(node, 0)
    if free >= vm_ram_bytes:
        print(node)
        sys.exit(0)

# Fallback : accepter même le nœud local si c'est le seul avec GPU
for node, pct in gpu_nodes:
    free = ram_libre.get(node, 0)
    if free >= vm_ram_bytes:
        print(node)
        sys.exit(0)
" 2>/dev/null || echo ""
}

# ===========================================================================
# ---- SÉLECTION DE LA VM À MIGRER (pour LIGHTEN_NODE)
# ===========================================================================

select_vm_to_migrate() {
    local resource="${1:-ram}"  # "ram" ou "cpu"
    local local_node
    local_node=$(hostname)

    local vms
    vms=$(get_local_running_vms)
    [ -z "$vms" ] && return

    local best_vmid=""
    local best_metric=-1

    for vmid in $vms; do
        # Vérifier cooldown par VM
        if ! check_vm_cooldown "$vmid"; then
            continue
        fi

        local metric=0
        if [ "$resource" = "cpu" ]; then
            metric=$(get_vm_vcpu "$vmid")
        else
            metric=$(get_vm_ram_mb "$vmid")
        fi

        if [ "$metric" -gt "$best_metric" ]; then
            best_metric=$metric
            best_vmid=$vmid
        fi
    done

    echo "$best_vmid"
}

# ===========================================================================
# ---- COOLDOWN PAR VM (anti-ping-pong)
# ===========================================================================

check_vm_cooldown() {
    local vmid="$1"
    local cooldown_file="$STATE_DIR/vm_cooldowns/$vmid"
    if [ -f "$cooldown_file" ]; then
        local last_ts
        last_ts=$(cat "$cooldown_file" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local elapsed=$((now - last_ts))
        if [ "$elapsed" -lt "$COOLDOWN" ]; then
            local remaining=$((COOLDOWN - elapsed))
            log DEBUG "Cooldown actif pour VM $vmid: ${remaining}s restantes"
            return 1
        fi
    fi
    return 0
}

set_vm_cooldown() {
    local vmid="$1"
    mkdir -p "$STATE_DIR/vm_cooldowns"
    date +%s > "$STATE_DIR/vm_cooldowns/$vmid"
}

# Compat: ancien cooldown global
check_cooldown() {
    local lock_file="$STATE_DIR/last_migration"
    if [ -f "$lock_file" ]; then
        local last_ts
        last_ts=$(cat "$lock_file" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local elapsed=$((now - last_ts))
        if [ "$elapsed" -lt "$COOLDOWN" ]; then
            return 1
        fi
    fi
    return 0
}

set_cooldown() {
    date +%s > "$STATE_DIR/last_migration"
}

# ===========================================================================
# ---- XBZRLE ----
# ===========================================================================

setup_xbzrle() {
    local vmid="$1"
    if [ "$ENABLE_XBZRLE" -eq 1 ]; then
        local conf="/etc/pve/qemu-server/${vmid}.conf"
        if [ -f "$conf" ] && ! grep -q "migrate_compression" "$conf"; then
            log INFO "Enabling XBZRLE compression for VM $vmid"
            echo "migrate_compression: xbzrle" >> "$conf"
            echo "migrate_compression_cache: 1638400" >> "$conf"
        fi
    fi
}

cleanup_xbzrle() {
    local vmid="$1"
    local conf="/etc/pve/qemu-server/${vmid}.conf"
    if [ -f "$conf" ]; then
        sed -i '/^migrate_compression/d' "$conf" 2>/dev/null || true
    fi
}

# ===========================================================================
# ---- MIGRATION ----
# ===========================================================================

migrate_vm() {
    local vmid="$1"
    local target="$2"
    local reason="${3:-signal}"

    log INFO "=== MIGRATION TRIGGERED ==="
    log INFO "  VM: $vmid → $target"
    log INFO "  Reason: $reason"
    log INFO "  Type: $MIGRATION_TYPE"

    setup_xbzrle "$vmid"

    local start_ts
    start_ts=$(date +%s)

    local migrate_cmd="qm migrate $vmid $target --online"
    if [ "$MIGRATION_TYPE" = "insecure" ]; then
        migrate_cmd="$migrate_cmd --migration_type insecure"
    fi

    log INFO "Executing: $migrate_cmd"
    local output
    if output=$($migrate_cmd 2>&1); then
        local end_ts
        end_ts=$(date +%s)
        local duration=$((end_ts - start_ts))
        log INFO "Migration SUCCESS: VM $vmid → $target (${duration}s)"
        set_vm_cooldown "$vmid"
        set_cooldown
        cleanup_xbzrle "$vmid"

        echo "$(date '+%Y-%m-%d %H:%M:%S') | VM=$vmid | $(hostname)→$target | ${reason} | ${duration}s | OK" \
            >> "$STATE_DIR/migration_history.log"
        return 0
    else
        log ERROR "Migration FAILED: VM $vmid → $target: $output"
        cleanup_xbzrle "$vmid"

        echo "$(date '+%Y-%m-%d %H:%M:%S') | VM=$vmid | $(hostname)→$target | ${reason} | FAILED" \
            >> "$STATE_DIR/migration_history.log"
        return 1
    fi
}

# ===========================================================================
# ---- HARMONISATION DU CLUSTER (pour consolidation)
# ===========================================================================

# Tente de libérer assez de RAM sur un nœud en déplaçant des petites VMs
# Retourne le nœud cible si réussi, vide sinon
harmonize_and_consolidate() {
    local vmid="$1"
    local min_ram_mb="$2"

    local cluster_json
    cluster_json=$(get_cluster_nodes)

    local local_node
    local_node=$(hostname)

    # Étape 1 : vérifier si un nœud a directement assez de place
    local direct_target
    direct_target=$(python3 -c "
import sys, json
cluster = json.loads('''$cluster_json''')
need = $min_ram_mb * 1024 * 1024
best = None
best_free = 0
for n in cluster:
    name = n.get('node','')
    if not name or n.get('status') != 'online':
        continue
    free = n.get('maxmem',0) - n.get('mem',0)
    if free >= need and free > best_free:
        best = name
        best_free = free
if best:
    print(best)
" 2>/dev/null || echo "")

    if [ -n "$direct_target" ]; then
        echo "$direct_target"
        return 0
    fi

    # Étape 2 : harmonisation — déplacer des petites VMs pour libérer assez de place
    log INFO "Harmonisation nécessaire pour VM $vmid (${min_ram_mb} Mo)"

    # Pour chaque nœud (trié par ram_libre décroissante), tenter l'harmonisation
    local nodes_by_free
    nodes_by_free=$(python3 -c "
import sys, json
cluster = json.loads('''$cluster_json''')
nodes = []
for n in cluster:
    name = n.get('node','')
    if name and n.get('status') == 'online':
        free = n.get('maxmem',0) - n.get('mem',0)
        nodes.append((name, free))
nodes.sort(key=lambda x: -x[1])
for name, free in nodes:
    print(f'{name} {free}')
" 2>/dev/null || echo "")

    while IFS=' ' read -r target_node free_bytes; do
        [ -z "$target_node" ] && continue
        local need_bytes=$((min_ram_mb * 1024 * 1024))
        local deficit=$((need_bytes - free_bytes))

        if [ "$deficit" -le 0 ]; then
            echo "$target_node"
            return 0
        fi

        # Trouver des VMs déplaçables sur target_node
        local vms_on_target
        vms_on_target=$(ssh -o ConnectTimeout=3 "root@${target_node}" \
            "qm list 2>/dev/null | awk 'NR>1 && \$3==\"running\" {print \$1}'" 2>/dev/null || echo "")

        [ -z "$vms_on_target" ] && continue

        local freed=0
        local moves_plan=()

        for vm in $vms_on_target; do
            [ "$vm" = "$vmid" ] && continue  # Ne pas déplacer la VM qu'on consolide

            local vm_ram
            vm_ram=$(ssh -o ConnectTimeout=3 "root@${target_node}" \
                "grep -oP 'memory:\s*\K[0-9]+' /etc/pve/qemu-server/${vm}.conf 2>/dev/null || echo 0" 2>/dev/null || echo 0)

            local vm_ram_bytes=$((vm_ram * 1024 * 1024))
            if [ "$vm_ram_bytes" -le "$deficit" ] && [ "$vm_ram_bytes" -gt 0 ]; then
                # Vérifier qu'on peut la placer ailleurs
                local alt_dest
                alt_dest=$(select_best_target_v2 "$vm" "ram")
                if [ -n "$alt_dest" ] && [ "$alt_dest" != "$target_node" ]; then
                    moves_plan+=("$vm:$alt_dest:$vm_ram")
                    freed=$((freed + vm_ram_bytes))
                    if [ "$freed" -ge "$deficit" ]; then
                        break
                    fi
                fi
            fi
        done

        if [ "$freed" -ge "$deficit" ]; then
            # Exécuter les migrations préparatoires
            log INFO "Harmonisation: déplacement de ${#moves_plan[@]} VM(s) depuis $target_node"
            for move in "${moves_plan[@]}"; do
                IFS=':' read -r mv_vmid mv_dest mv_ram <<< "$move"
                log INFO "  Harmonisation: VM $mv_vmid (${mv_ram}Mo) → $mv_dest"
                if ! ssh -o ConnectTimeout=3 "root@${target_node}" \
                    "qm migrate $mv_vmid $mv_dest --online" 2>/dev/null; then
                    log WARN "  Harmonisation: échec migration VM $mv_vmid"
                fi
            done
            echo "$target_node"
            return 0
        fi
    done <<< "$nodes_by_free"

    echo ""
    return 1
}

# ===========================================================================
# ---- RÉPONSES AUX AGENTS ----
# ===========================================================================

write_response() {
    local signal_file="$1"
    local status="$2"     # SUCCESS, FAILED, REFUSED
    local action="$3"     # MIGRATED, CONSOLIDATED, MIGRATION_FAILED, NO_SUITABLE_NODE, etc.
    local target_node="${4:-}"
    local extra="${5:-}"

    local sig_basename
    sig_basename=$(basename "$signal_file" .sig)
    local timestamp
    timestamp=$(echo "$sig_basename" | grep -oP 'signal_\K[0-9]+' || echo "$(date +%s)")

    local resp_file="$SIGNAL_DIR/responses/response_${timestamp}.resp"
    mkdir -p "$SIGNAL_DIR/responses"

    {
        echo "status=$status"
        echo "action=$action"
        echo "timestamp=$(date -Iseconds)"
        [ -n "$target_node" ] && echo "target_node=$target_node"
        [ -n "$extra" ] && echo "$extra"
    } > "${resp_file}.tmp"

    mv "${resp_file}.tmp" "$resp_file"
    log INFO "Response written: $resp_file ($status/$action)"
}

# ===========================================================================
# ---- TRAITEMENT DES SIGNAUX ----
# ===========================================================================

# Parse un fichier .sig en variables associatives
parse_signal() {
    local sig_file="$1"
    # Retourne les valeurs sur stdout au format KEY=VALUE
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "${key}=${value}"
    done < "$sig_file"
}

process_signal() {
    local sig_file="$1"

    log INFO "Processing signal: $sig_file"

    # Parser le signal
    local sig_type="" sig_vmid="" sig_resource="" sig_urgency="" sig_source=""
    local sig_gpu_nodes_usage="" sig_min_ram_mb="" sig_min_vcpu="" sig_nodes_involved=""

    while IFS='=' read -r key value; do
        case "$key" in
            type)               sig_type="$value" ;;
            vmid)               sig_vmid="$value" ;;
            resource)           sig_resource="$value" ;;
            urgency)            sig_urgency="$value" ;;
            source_agent)       sig_source="$value" ;;
            gpu_nodes_usage)    sig_gpu_nodes_usage="$value" ;;
            min_ram_mb)         sig_min_ram_mb="$value" ;;
            min_vcpu)           sig_min_vcpu="$value" ;;
            nodes_involved)     sig_nodes_involved="$value" ;;
        esac
    done < <(parse_signal "$sig_file")

    if [ -z "$sig_type" ]; then
        log ERROR "Signal sans type: $sig_file"
        write_response "$sig_file" "REFUSED" "INVALID_SIGNAL"
        mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
        return
    fi

    log INFO "Signal: type=$sig_type vmid=$sig_vmid source=$sig_source urgency=$sig_urgency"

    case "$sig_type" in

        MIGRATE_VM)
            # Migrer une VM spécifique
            if [ -z "$sig_vmid" ]; then
                write_response "$sig_file" "REFUSED" "VM_NOT_FOUND"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            # Vérifier que la VM existe et tourne
            if ! qm status "$sig_vmid" 2>/dev/null | grep -q "running"; then
                write_response "$sig_file" "REFUSED" "VM_NOT_FOUND"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            # Vérifier le cooldown
            if ! check_vm_cooldown "$sig_vmid"; then
                write_response "$sig_file" "REFUSED" "COOLDOWN_ACTIVE"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            # Sélectionner le meilleur nœud
            local target
            target=$(select_best_target_v2 "$sig_vmid" "ram")
            if [ -z "$target" ]; then
                write_response "$sig_file" "REFUSED" "NO_SUITABLE_NODE"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            # Migrer
            if migrate_vm "$sig_vmid" "$target" "signal:MIGRATE_VM:$sig_source"; then
                write_response "$sig_file" "SUCCESS" "MIGRATED" "$target"
            else
                write_response "$sig_file" "FAILED" "MIGRATION_FAILED"
            fi
            ;;

        LIGHTEN_NODE)
            # Choisir la VM la plus gourmande et la migrer
            local resource="${sig_resource:-ram}"
            local vmid
            vmid=$(select_vm_to_migrate "$resource")

            if [ -z "$vmid" ]; then
                write_response "$sig_file" "REFUSED" "VM_NOT_FOUND"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            local target
            target=$(select_best_target_v2 "$vmid" "$resource")
            if [ -z "$target" ]; then
                write_response "$sig_file" "REFUSED" "ALL_NODES_EQUALLY_LOADED"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            if migrate_vm "$vmid" "$target" "signal:LIGHTEN_NODE:$resource:$sig_source"; then
                write_response "$sig_file" "SUCCESS" "MIGRATED" "$target" "vmid=$vmid"
            else
                write_response "$sig_file" "FAILED" "MIGRATION_FAILED" "" "vmid=$vmid"
            fi
            ;;

        GPU_REQUEST)
            if [ -z "$sig_vmid" ] || [ -z "$sig_gpu_nodes_usage" ]; then
                write_response "$sig_file" "REFUSED" "INVALID_SIGNAL"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            if ! qm status "$sig_vmid" 2>/dev/null | grep -q "running"; then
                write_response "$sig_file" "REFUSED" "VM_NOT_FOUND"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            if ! check_vm_cooldown "$sig_vmid"; then
                write_response "$sig_file" "REFUSED" "COOLDOWN_ACTIVE"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            local target
            target=$(select_best_gpu_node "$sig_vmid" "$sig_gpu_nodes_usage")
            if [ -z "$target" ]; then
                write_response "$sig_file" "REFUSED" "NO_SUITABLE_NODE"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            if migrate_vm "$sig_vmid" "$target" "signal:GPU_REQUEST:$sig_source"; then
                write_response "$sig_file" "SUCCESS" "MIGRATED" "$target"
            else
                write_response "$sig_file" "FAILED" "MIGRATION_FAILED"
            fi
            ;;

        CONSOLIDATE_VM)
            if [ -z "$sig_vmid" ] || [ -z "$sig_min_ram_mb" ]; then
                write_response "$sig_file" "REFUSED" "INVALID_SIGNAL"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            # Vérifier si la consolidation est physiquement possible
            # (la VM ne doit pas nécessiter plus que la RAM totale de tout nœud)
            local physically_possible
            physically_possible=$(python3 -c "
import sys, json
cluster = json.loads('''$(get_cluster_nodes)''')
need = $sig_min_ram_mb * 1024 * 1024
for n in cluster:
    if n.get('status') == 'online' and n.get('maxmem', 0) >= need:
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null || echo "no")

            if [ "$physically_possible" = "no" ]; then
                log WARN "CONSOLIDATE_VM: VM $sig_vmid (${sig_min_ram_mb}Mo) impossible, aucun nœud assez gros"
                write_response "$sig_file" "REFUSED" "CONSOLIDATION_IMPOSSIBLE"
                mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
                return
            fi

            # Tenter la consolidation (avec harmonisation si nécessaire)
            local target
            target=$(harmonize_and_consolidate "$sig_vmid" "$sig_min_ram_mb")

            if [ -n "$target" ]; then
                # Migrer la VM vers le nœud qui a maintenant assez de place
                if migrate_vm "$sig_vmid" "$target" "signal:CONSOLIDATE_VM:$sig_source"; then
                    write_response "$sig_file" "SUCCESS" "CONSOLIDATED" "$target"
                else
                    write_response "$sig_file" "FAILED" "MIGRATION_FAILED"
                fi
            else
                # Pas de place maintenant, enregistrer en attente
                log INFO "CONSOLIDATE_VM: VM $sig_vmid en attente de place"
                mkdir -p "$STATE_DIR/pending_consolidations"
                cp "$sig_file" "$STATE_DIR/pending_consolidations/"
                write_response "$sig_file" "PENDING" "WAITING_FOR_CAPACITY"
            fi
            ;;

        *)
            log WARN "Signal type inconnu: $sig_type"
            write_response "$sig_file" "REFUSED" "INVALID_SIGNAL"
            ;;
    esac

    # Déplacer le signal vers processed/
    mv "$sig_file" "$SIGNAL_DIR/processed/" 2>/dev/null || true
}

# Traite tous les signaux en attente, triés par urgence
process_pending_signals() {
    local sig_files
    sig_files=$(ls "$SIGNAL_DIR"/*.sig 2>/dev/null || true)
    [ -z "$sig_files" ] && return

    local count
    count=$(echo "$sig_files" | wc -w)
    if [ "$count" -gt 10 ]; then
        log WARN "ALERTE: $count signaux en attente (>10)"
    fi

    # Trier par urgence (critical > high > medium > low)
    local sorted_files
    sorted_files=$(for f in $sig_files; do
        local urg
        urg=$(grep -oP 'urgency=\K\S+' "$f" 2>/dev/null || echo "low")
        local prio
        case "$urg" in
            critical) prio=0 ;;
            high)     prio=1 ;;
            medium)   prio=2 ;;
            low)      prio=3 ;;
            *)        prio=4 ;;
        esac
        echo "$prio $f"
    done | sort -n | awk '{print $2}')

    for sig_file in $sorted_files; do
        [ -f "$sig_file" ] || continue  # Peut avoir été déplacé entre-temps
        process_signal "$sig_file"
    done
}

# Vérifie les consolidations en attente
check_pending_consolidations() {
    local pending_dir="$STATE_DIR/pending_consolidations"
    [ -d "$pending_dir" ] || return

    for pf in "$pending_dir"/*.sig 2>/dev/null; do
        [ -f "$pf" ] || continue

        local vmid min_ram_mb
        vmid=$(grep -oP 'vmid=\K\S+' "$pf" 2>/dev/null || echo "")
        min_ram_mb=$(grep -oP 'min_ram_mb=\K\S+' "$pf" 2>/dev/null || echo "0")

        [ -z "$vmid" ] && continue

        local target
        target=$(harmonize_and_consolidate "$vmid" "$min_ram_mb")
        if [ -n "$target" ]; then
            local source_agent
            source_agent=$(grep -oP 'source_agent=\K\S+' "$pf" 2>/dev/null || echo "unknown")

            if migrate_vm "$vmid" "$target" "consolidation:$source_agent"; then
                log INFO "Consolidation réussie: VM $vmid → $target"
                # Écrire la réponse
                write_response "$pf" "SUCCESS" "CONSOLIDATED" "$target"
            fi
            rm -f "$pf"
        fi
    done
}

# ===========================================================================
# ---- PLACEMENT AUTOMATIQUE DES NOUVELLES VMS ----
# ===========================================================================

handle_new_vm() {
    local conf_file="$1"

    # Extraire le VMID du nom de fichier
    local vmid
    vmid=$(basename "$conf_file" .conf)

    # Vérifier que c'est un ID numérique
    [[ "$vmid" =~ ^[0-9]+$ ]] || return

    # Attendre 2 secondes que Proxmox finisse d'écrire le .conf
    sleep 2

    local vm_ram_mb
    vm_ram_mb=$(get_vm_ram_mb "$vmid")

    if [ "$vm_ram_mb" -eq 0 ]; then
        log DEBUG "VM $vmid: impossible de lire la RAM configurée"
        return
    fi

    # Comparer avec la RAM libre locale
    local ram_libre_locale
    ram_libre_locale=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)

    if [ "$ram_libre_locale" -ge "$vm_ram_mb" ]; then
        log INFO "Placement auto: VM $vmid reste ici (${ram_libre_locale}Mo libre >= ${vm_ram_mb}Mo requis)"
        return
    fi

    log WARN "Placement auto: VM $vmid nécessite ${vm_ram_mb}Mo mais seulement ${ram_libre_locale}Mo libre"

    local target
    target=$(select_best_target_v2 "$vmid" "ram")
    if [ -n "$target" ]; then
        log INFO "Placement auto: VM $vmid → $target"
        qm migrate "$vmid" "$target" 2>&1 || \
            log ERROR "Placement auto: échec migration VM $vmid → $target"
    else
        log WARN "Placement auto: aucun nœud ne peut accueillir VM $vmid (${vm_ram_mb}Mo)"
    fi
}

# ===========================================================================
# ---- MODE MAINTENANCE ----
# ===========================================================================

maintenance_mode() {
    local target="${1:-}"
    log INFO "===== MAINTENANCE MODE ACTIVATED ====="

    local vms
    vms=$(get_local_running_vms)
    local total
    total=$(echo "$vms" | grep -c '[0-9]' || echo 0)

    if [ "$total" -eq 0 ]; then
        log INFO "No running VMs on this node. Ready for maintenance."
        echo "No running VMs on this node."
        return 0
    fi

    log INFO "Found $total running VMs to migrate"
    echo "Found $total running VMs to migrate"

    local success=0
    local failed=0
    local count=0

    for vmid in $vms; do
        count=$((count + 1))

        local dest="$target"
        if [ -z "$dest" ]; then
            dest=$(select_best_target_v2 "$vmid" "ram")
        fi

        if [ -z "$dest" ]; then
            log ERROR "[$count/$total] VM $vmid: No target node available"
            echo "[$count/$total] VM $vmid: FAILED (no target node)"
            failed=$((failed + 1))
            continue
        fi

        echo "[$count/$total] Migrating VM $vmid → $dest ..."

        if migrate_vm "$vmid" "$dest" "maintenance"; then
            success=$((success + 1))
            echo "[$count/$total] VM $vmid → $dest : OK"
        else
            failed=$((failed + 1))
            echo "[$count/$total] VM $vmid → $dest : FAILED"
        fi
    done

    log INFO "Maintenance complete: $success/$total migrated, $failed failed"
    echo ""
    echo "===== MAINTENANCE COMPLETE ====="
    echo "  Migrated: $success/$total"
    echo "  Failed:   $failed"

    if [ "$failed" -eq 0 ]; then
        echo "  Status:   Node is ready for maintenance"
        return 0
    else
        echo "  Status:   Some VMs failed to migrate"
        return 1
    fi
}

# ===========================================================================
# ---- BOUCLE PRINCIPALE (inotifywait) ----
# ===========================================================================

# Boucle de surveillance des signaux
watch_signals() {
    log INFO "Watching signals in $SIGNAL_DIR"

    # Traiter les signaux déjà présents au démarrage
    process_pending_signals

    # Écouter les nouveaux fichiers .sig
    inotifywait -m -e moved_to --format '%f' "$SIGNAL_DIR" 2>/dev/null | while read -r filename; do
        [ "$RUNNING" -eq 0 ] && break
        if [[ "$filename" == *.sig ]]; then
            local sig_file="$SIGNAL_DIR/$filename"
            if [ -f "$sig_file" ]; then
                process_signal "$sig_file"
            fi
        fi
    done
}

# Boucle de surveillance des nouvelles VMs
watch_new_vms() {
    if [ "$ENABLE_AUTO_PLACEMENT" -ne 1 ]; then
        return
    fi

    local vm_conf_dir="/etc/pve/qemu-server"
    if [ ! -d "$vm_conf_dir" ]; then
        log WARN "VM config dir $vm_conf_dir not found, auto-placement disabled"
        return
    fi

    log INFO "Watching new VMs in $vm_conf_dir"

    inotifywait -m -e create -e moved_to --format '%f' "$vm_conf_dir" 2>/dev/null | while read -r filename; do
        [ "$RUNNING" -eq 0 ] && break
        if [[ "$filename" == *.conf ]]; then
            handle_new_vm "$vm_conf_dir/$filename" &
        fi
    done
}

# Boucle périodique pour les consolidations en attente
watch_consolidations() {
    while [ "$RUNNING" -eq 1 ]; do
        sleep 60
        check_pending_consolidations
    done
}

# ===========================================================================
# ---- SIGNAL HANDLING ----
# ===========================================================================
RUNNING=1
cleanup() {
    RUNNING=0
    log INFO "=== live-migrator stopping ==="
    # Tuer les sous-processus
    kill 0 2>/dev/null || true
    rm -f "$PID_FILE"
}
trap cleanup SIGTERM SIGINT

# ===========================================================================
# ---- MAIN ----
# ===========================================================================
usage() {
    echo "Usage: $0 [options]"
    echo "  -c PATH    Config file (default: $CONF_FILE)"
    echo "  -f         Run in foreground"
    echo "  -h         Show help"
    echo "  --check    Run one check cycle and exit (diagnostic)"
    echo ""
    echo "Note: Use migrator-ctl.sh for maintenance and manual operations."
}

main() {
    local check_only=0

    while [ $# -gt 0 ]; do
        case "$1" in
            -c) CONF_FILE="$2"; shift 2 ;;
            -f) FOREGROUND=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --check) check_only=1; FOREGROUND=1; shift ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Créer les répertoires
    mkdir -p "$STATE_DIR"
    mkdir -p "$SIGNAL_DIR/processed"
    mkdir -p "$SIGNAL_DIR/responses"
    mkdir -p "$STATE_DIR/vm_cooldowns"
    mkdir -p "$STATE_DIR/pending_consolidations"
    mkdir -p "$(dirname "$LOG_FILE")"

    # Charger la configuration
    load_config

    log INFO "=== live-migrator v2 starting ==="
    dump_config

    # Mode check-only : diagnostic
    if [ "$check_only" -eq 1 ]; then
        echo "=== System Metrics ==="
        echo "  Temperature: $(get_cpu_temp)°C (threshold: ${TEMP_THRESHOLD}°C)"
        echo "  CPU Usage:   $(get_cpu_usage)% (threshold: ${CPU_THRESHOLD}%)"
        echo "  RAM Usage:   $(get_ram_usage)% (threshold: ${RAM_THRESHOLD}%)"
        echo "  Local VMs:   $(count_local_vms)"
        echo ""
        echo "=== Best Target Node (v2) ==="
        local target
        target=$(select_best_target_v2 "" "ram")
        echo "  Target: ${target:-none available}"
        echo ""
        echo "=== Signal Directory ==="
        echo "  Path: $SIGNAL_DIR"
        echo "  Pending signals: $(ls "$SIGNAL_DIR"/*.sig 2>/dev/null | wc -l || echo 0)"
        echo "  Pending consolidations: $(ls "$STATE_DIR/pending_consolidations"/*.sig 2>/dev/null | wc -l || echo 0)"
        exit 0
    fi

    # Vérifier inotifywait
    if ! command -v inotifywait &>/dev/null; then
        log ERROR "inotifywait not found. Install: apt install inotify-tools"
        echo "ERROR: inotifywait not found. Install: apt install inotify-tools" >&2
        exit 1
    fi

    # Écrire le PID
    echo $$ > "$PID_FILE"
    log INFO "Daemon running (PID $$)"

    # Lancer les 3 boucles en parallèle
    watch_signals &
    local signals_pid=$!

    watch_new_vms &
    local vms_pid=$!

    watch_consolidations &
    local consolidations_pid=$!

    log INFO "Signal watcher PID: $signals_pid"
    log INFO "VM watcher PID: $vms_pid"
    log INFO "Consolidation watcher PID: $consolidations_pid"

    # Attendre qu'un processus se termine (ou SIGTERM)
    wait
}

# Permettre le sourcing pour les tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
