#!/bin/bash
# ============================================================================
# migrator-ctl.sh — Outil de contrôle CLI pour live-migrator
#
# Permet de déclencher manuellement des migrations, activer le mode
# maintenance, et consulter l'état du système.
#
# Usage :
#   migrator-ctl.sh <commande> [options]
#
# Commandes :
#   status              — Affiche les métriques du nœud et l'état du daemon
#   maintenance [node]  — Migre toutes les VMs vers d'autres nœuds
#   migrate <vmid> <node> — Migre une VM spécifique
#   history             — Historique des migrations
#   nodes               — État de tous les nœuds du cluster
# ============================================================================

set -euo pipefail

CONF_FILE="/etc/live-migrator/live-migrator.conf"
STATE_DIR="/var/lib/live-migrator"
PID_FILE="/var/run/live-migrator.pid"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATOR="$SCRIPT_DIR/live-migrator.sh"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Fonctions utilitaires ----

is_daemon_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

bar_graph() {
    local percent=$1
    local max=$2
    local width=30
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    local color="$GREEN"
    if [ "$percent" -gt "$max" ]; then
        color="$RED"
    elif [ "$percent" -gt $((max - 10)) ]; then
        color="$YELLOW"
    fi
    printf "${color}"
    printf '%0.s█' $(seq 1 $filled) 2>/dev/null || true
    printf "${NC}"
    printf '%0.s░' $(seq 1 $empty) 2>/dev/null || true
    printf " %d%%" "$percent"
}

# ---- Commandes ----

cmd_status() {
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}     LIVE-MIGRATOR — STATUS            ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    # Daemon status
    echo -ne "  Daemon:      "
    if is_daemon_running; then
        local pid
        pid=$(cat "$PID_FILE")
        echo -e "${GREEN}● Running${NC} (PID $pid)"
    else
        echo -e "${RED}● Stopped${NC}"
    fi
    echo ""

    # Node info
    local hostname
    hostname=$(hostname)
    echo -e "  ${BOLD}Node:${NC}        $hostname"
    echo ""

    # Source les fonctions du daemon pour les métriques
    source "$MIGRATOR"

    # Temperature
    local temp
    temp=$(get_cpu_temp)
    echo -ne "  Temperature: "
    if [ "$temp" -gt 80 ]; then
        echo -e "${RED}${temp}°C${NC}  ⚠ CRITICAL"
    elif [ "$temp" -gt 70 ]; then
        echo -e "${YELLOW}${temp}°C${NC}"
    else
        echo -e "${GREEN}${temp}°C${NC}"
    fi

    # CPU
    local cpu
    cpu=$(get_cpu_usage)
    echo -ne "  CPU Load:    "
    bar_graph "$cpu" 90
    echo ""

    # RAM
    local ram
    ram=$(get_ram_usage)
    echo -ne "  RAM Usage:   "
    bar_graph "$ram" 90
    echo ""

    # VMs
    echo ""
    local vms
    vms=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}' || true)
    local vm_count
    vm_count=$(echo "$vms" | grep -c '[0-9]' 2>/dev/null || echo 0)
    echo -e "  ${BOLD}Local VMs:${NC}   $vm_count running"
    if [ "$vm_count" -gt 0 ]; then
        for vmid in $vms; do
            local name
            name=$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/{print $2}' || echo "unknown")
            echo "    • VM $vmid ($name)"
        done
    fi

    # Cooldown
    echo ""
    if [ -f "$STATE_DIR/last_migration" ]; then
        local last_ts
        last_ts=$(cat "$STATE_DIR/last_migration")
        local now
        now=$(date +%s)
        local elapsed=$((now - last_ts))
        local last_date
        last_date=$(date -d "@$last_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        echo -e "  ${BOLD}Last migration:${NC} $last_date (${elapsed}s ago)"
    else
        echo -e "  ${BOLD}Last migration:${NC} never"
    fi

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
}

cmd_maintenance() {
    local target="${1:-}"

    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}     MAINTENANCE MODE                  ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    if [ -n "$target" ]; then
        echo -e "  Target node: ${BLUE}$target${NC}"
    else
        echo -e "  Target node: ${BLUE}auto-select (least loaded)${NC}"
    fi
    echo ""

    # Sourcer les fonctions du daemon
    source "$MIGRATOR"
    FOREGROUND=1
    load_config

    # Confirmer
    local vm_count
    vm_count=$(count_local_vms)
    echo -e "  VMs to migrate: ${BOLD}$vm_count${NC}"
    echo ""

    if [ "$vm_count" -eq 0 ]; then
        echo -e "  ${GREEN}Node is already empty. Ready for maintenance.${NC}"
        return 0
    fi

    echo -ne "  Proceed? [y/N] "
    read -r confirm
    if [[ ! "$confirm" =~ ^[yYoO] ]]; then
        echo "  Cancelled."
        return 1
    fi

    echo ""
    maintenance_mode "$target"
}

cmd_migrate() {
    local vmid="$1"
    local target="$2"

    echo -e "Migrating VM ${BOLD}$vmid${NC} → ${BOLD}$target${NC} (online)..."

    # Sourcer les fonctions
    source "$MIGRATOR"
    FOREGROUND=1
    load_config

    migrate_vm "$vmid" "$target" "manual"
}

cmd_history() {
    local history_file="$STATE_DIR/migration_history.log"

    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}     MIGRATION HISTORY                 ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    if [ ! -f "$history_file" ]; then
        echo "  No migrations recorded yet."
        return
    fi

    echo -e "  ${BOLD}Date                 | VM    | Target  | Reason         | Duration | Status${NC}"
    echo "  -------------------+-------+---------+----------------+----------+-------"
    tail -20 "$history_file" | while IFS='|' read -r date vm target reason duration status; do
        echo "  $date|$vm|$target|$reason|$duration|$status"
    done
    echo ""
    local total
    total=$(wc -l < "$history_file")
    echo "  Total migrations: $total"
}

cmd_nodes() {
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}     CLUSTER NODES STATUS              ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    local local_node
    local_node=$(hostname)

    # Récupérer les nœuds
    local nodes
    nodes=$(pvesh get /cluster/resources --type node --output-format json 2>/dev/null)

    echo "$nodes" | python3 -c "
import sys, json

nodes = json.load(sys.stdin)
for n in sorted(nodes, key=lambda x: x.get('node', '')):
    node = n.get('node', '?')
    status = n.get('status', '?')
    cpu = n.get('cpu', 0) * 100
    maxcpu = n.get('maxcpu', 0)
    mem = n.get('mem', 0)
    maxmem = n.get('maxmem', 0)

    mem_pct = (mem / maxmem * 100) if maxmem > 0 else 0
    mem_gb = mem / (1024**3)
    maxmem_gb = maxmem / (1024**3)

    status_icon = '●' if status == 'online' else '○'
    status_color = '\033[0;32m' if status == 'online' else '\033[0;31m'

    marker = ' ◄ (local)' if node == '$local_node' else ''
    print(f'  {status_color}{status_icon}\033[0m {node}{marker}')
    print(f'      CPU: {cpu:.0f}% ({maxcpu} cores)')
    print(f'      RAM: {mem_pct:.0f}% ({mem_gb:.1f}/{maxmem_gb:.1f} GB)')
    print()
" 2>/dev/null || echo "  Error: cannot retrieve node information"

    echo -e "${BOLD}═══════════════════════════════════════${NC}"
}

# ---- Simulation de signaux (test) ----

cmd_signal() {
    local sig_type="$1"
    local sig_dir="/var/lib/live-migrator/signals"

    if [ -z "$sig_type" ]; then
        echo -e "${RED}Usage:${NC} $0 signal <type> [options]"
        echo ""
        echo "Types:"
        echo "  MIGRATE_VM     --vmid <id>"
        echo "  LIGHTEN_NODE   --resource <ram|cpu>"
        echo "  GPU_REQUEST    --vmid <id> --gpu-usage <node:pct,...>"
        echo "  CONSOLIDATE_VM --vmid <id> --min-ram <mb> --nodes <n1,n2>"
        echo ""
        echo "Options communes:"
        echo "  --urgency <low|medium|high|critical>  (default: high)"
        echo "  --reason <text>                        (default: test_signal)"
        return 1
    fi

    shift
    local vmid="" resource="ram" urgency="high" reason="test_signal"
    local gpu_usage="" min_ram="" min_vcpu="2" nodes_involved=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --vmid)       vmid="$2"; shift 2 ;;
            --resource)   resource="$2"; shift 2 ;;
            --urgency)    urgency="$2"; shift 2 ;;
            --reason)     reason="$2"; shift 2 ;;
            --gpu-usage)  gpu_usage="$2"; shift 2 ;;
            --min-ram)    min_ram="$2"; shift 2 ;;
            --min-vcpu)   min_vcpu="$2"; shift 2 ;;
            --nodes)      nodes_involved="$2"; shift 2 ;;
            *)            echo "Unknown option: $1"; return 1 ;;
        esac
    done

    local timestamp
    timestamp=$(date +%s)
    local sig_file="$sig_dir/signal_${timestamp}_$(echo "$sig_type" | tr '[:upper:]' '[:lower:]').tmp"

    mkdir -p "$sig_dir"

    {
        echo "type=$sig_type"
        [ -n "$vmid" ] && echo "vmid=$vmid"
        echo "source_agent=migrator-ctl-test"
        echo "reason=$reason"
        echo "urgency=$urgency"
        [ "$sig_type" = "LIGHTEN_NODE" ] && echo "resource=$resource"
        [ -n "$gpu_usage" ] && echo "gpu_nodes_usage=$gpu_usage"
        [ -n "$min_ram" ] && echo "min_ram_mb=$min_ram"
        [ -n "$min_vcpu" ] && echo "min_vcpu=$min_vcpu"
        [ -n "$nodes_involved" ] && echo "nodes_involved=$nodes_involved"
        echo "timestamp=$(date -Iseconds)"
    } > "$sig_file"

    # Atomique : rename .tmp → .sig
    local final_file="${sig_file%.tmp}.sig"
    mv "$sig_file" "$final_file"

    echo -e "${GREEN}Signal sent:${NC} $final_file"
    echo -e "  Type:    $sig_type"
    [ -n "$vmid" ] && echo -e "  VMID:    $vmid"
    echo -e "  Urgency: $urgency"
    echo ""
    echo -e "${YELLOW}Waiting for response...${NC}"
    echo -e "Check: cat $sig_dir/responses/response_${timestamp}.resp"
}

# ---- Création de VM (test placement) ----

cmd_create() {
    local vmid="$1"
    local memory="${2:-2048}"
    local name="${3:-test-vm}"

    if [ -z "$vmid" ]; then
        echo -e "${RED}Usage:${NC} $0 create <vmid> [memory_mb] [name]"
        return 1
    fi

    echo -e "Creating VM $vmid (${memory}Mo, name=$name)..."
    qm create "$vmid" --memory "$memory" --name "$name" 2>&1
    echo -e "${GREEN}VM $vmid created.${NC} Check logs for auto-placement decision."
}

# ---- Main ----

usage() {
    echo -e "${BOLD}Usage:${NC} $0 <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  status                 Show node metrics and daemon status"
    echo "  maintenance [node]     Migrate all VMs off this node"
    echo "  migrate <vmid> <node>  Migrate a specific VM"
    echo "  history                Show migration history"
    echo "  nodes                  Show cluster nodes status"
    echo "  signal <type> [opts]   Send a test signal to the daemon"
    echo "  create <vmid> [mem]    Create a test VM (triggers auto-placement)"
    echo ""
    echo -e "${BOLD}Signal types:${NC}"
    echo "  MIGRATE_VM     --vmid <id>"
    echo "  LIGHTEN_NODE   --resource <ram|cpu>"
    echo "  GPU_REQUEST    --vmid <id> --gpu-usage <node:pct,...>"
    echo "  CONSOLIDATE_VM --vmid <id> --min-ram <mb> --nodes <n1,n2>"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 status"
    echo "  $0 maintenance              # auto-select best targets"
    echo "  $0 maintenance ram           # force all VMs to 'ram'"
    echo "  $0 migrate 101 rem"
    echo "  $0 signal MIGRATE_VM --vmid 101 --urgency critical"
    echo "  $0 signal LIGHTEN_NODE --resource ram"
    echo "  $0 signal GPU_REQUEST --vmid 101 --gpu-usage emilia:45,rem:82,ram:none"
    echo "  $0 signal CONSOLIDATE_VM --vmid 108 --min-ram 8192 --nodes emilia,rem"
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

case "$1" in
    status)       cmd_status ;;
    maintenance)  cmd_maintenance "${2:-}" ;;
    migrate)
        if [ $# -lt 3 ]; then
            echo "Usage: $0 migrate <vmid> <target_node>"
            exit 1
        fi
        cmd_migrate "$2" "$3"
        ;;
    history)      cmd_history ;;
    nodes)        cmd_nodes ;;
    signal)       shift; cmd_signal "$@" ;;
    create)
        if [ $# -lt 2 ]; then
            echo "Usage: $0 create <vmid> [memory_mb] [name]"
            exit 1
        fi
        cmd_create "$2" "${3:-2048}" "${4:-test-vm}"
        ;;
    -h|--help)    usage ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
