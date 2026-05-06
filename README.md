# MigrationVM — Automated VM Migration & State Recovery for Proxmox VE

A suite of daemons for Proxmox VE clusters that automate **live migration** of virtual machines based on real-time resource monitoring and provide **automatic memory state recovery** after HA failover events.

Built for a 3-node Proxmox cluster (Emilia, RAM, REM), this project ensures optimal resource distribution, minimal downtime, and near-zero state loss during hardware failures.

---

## Features

### 🔄 Live Migrator — Signal-Driven Migration Daemon (Bash)
- **Signal-driven architecture**: reacts to signals from RAM, vCPU, and GPU monitoring agents via file-based IPC (`inotifywait`)
- **Smart node selection**: selects target nodes by comparing usage percentages *and* absolute capacity
- **Supported signals**: `MIGRATE_VM`, `LIGHTEN_NODE`, `GPU_REQUEST`, `CONSOLIDATE_VM`
- **Automatic VM placement**: detects newly created VMs and migrates them to an appropriate node if the local node is full
- **Maintenance mode**: evacuate all VMs from a node before maintenance with optimal distribution
- **Cluster harmonization**: moves smaller VMs to free up space for consolidation when no single node has enough room
- **Anti-ping-pong protection**: per-VM cooldown (5 min default) prevents migration loops
- **Priority queue**: concurrent signals are sorted by urgency (`critical` > `high` > `medium` > `low`)
- **Debian packaging**: `.deb` package for easy deployment
- **CLI tool** (`migrator-ctl.sh`): status, manual migration, signal simulation, VM creation, history

### 🛡️ VMState Guardian — Memory State Snapshot & Recovery Daemon (C)
- **Periodic memory snapshots**: captures full VM state (RAM, CPU registers, virtual devices) at configurable intervals
- **Two capture modes**:
  - **QMP pre-copy** (recommended): ~10–500 ms pause
  - **QM savevm** (fallback): ~2–16 s pause depending on RAM size
- **Automatic HA failover detection**: detects when a VM has been restarted on a different node by Proxmox HA
- **Automatic state restoration**: stops the cold-booted VM and restores the last saved memory state
- **Anti-loop protection**: cooldown timer + max retry counter to prevent infinite restore loops
- **Shared storage support**: snapshots stored on Ceph (or any shared filesystem) for cross-node access

---

## Prerequisites

| Requirement | Version / Details |
|---|---|
| **Proxmox VE** | 7.x or 8.x (provides `qm`, `pvesh`, `ha-manager`) |
| **Cluster** | At least 2 nodes (3 recommended for quorum) |
| **Shared storage** | Ceph RBD (recommended), NFS, or iSCSI |
| **Root access** | On all cluster nodes |

### Live Migrator dependencies
```bash
apt install -y inotify-tools python3
```

### VMState Guardian build dependencies
```bash
apt install -y build-essential
```

---

## Installation & Setup

### Live Migrator

**1. Copy the project to each Proxmox node:**

```bash
scp -r /path/to/MigrationVM/live-migrator root@<NODE_IP>:/tmp/live-migrator
```

**2. Run the installer on each node:**

```bash
ssh root@<NODE_IP>
chmod +x /tmp/live-migrator/scripts/install.sh
/tmp/live-migrator/scripts/install.sh
```

**3. Enable and start:**

```bash
systemctl enable --now live-migrator
```

**Automated install across all nodes:**

```bash
for node in rem ram emilia; do
    echo "=== Installing on $node ==="
    scp -r live-migrator root@${node}:/tmp/live-migrator
    ssh root@${node} "chmod +x /tmp/live-migrator/scripts/install.sh && \
        /tmp/live-migrator/scripts/install.sh && \
        systemctl enable --now live-migrator"
done
```

### VMState Guardian

**1. Copy and compile on each node:**

```bash
scp -r /path/to/MigrationVM/vmstate-guardian root@<NODE_IP>:/opt/vmstate-guardian
ssh root@<NODE_IP>
cd /opt/vmstate-guardian
make clean && make
```

**2. Install and configure:**

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

**3. Edit configuration** (`/etc/vmstate-guardian/vmstate-guardian.conf`):

```ini
[general]
vmid = 101           # Your VM ID
mode = qmp           # qmp (recommended) or qm

[snapshot]
snapshot_interval = 60

[paths]
vmstate_path = /mnt/pve/cephfs/vmstate/101   # MUST be on shared storage
```

**4. Enable and start:**

```bash
systemctl enable --now vmstate-guardian
```

---

## How to Use

### Live Migrator CLI (`migrator-ctl.sh`)

```bash
migrator-ctl.sh status                  # Daemon status
migrator-ctl.sh nodes                   # Cluster node status
migrator-ctl.sh history                 # Migration history
migrator-ctl.sh migrate 101 rem         # Manual migration
migrator-ctl.sh maintenance             # Evacuate this node
migrator-ctl.sh create 200 2048 test-vm # Create a test VM
```

**Signal simulation (for testing):**

```bash
migrator-ctl.sh signal MIGRATE_VM --vmid 101 --urgency high
migrator-ctl.sh signal LIGHTEN_NODE --resource ram --urgency critical
migrator-ctl.sh signal GPU_REQUEST --vmid 101 --gpu-usage emilia:45,rem:82,ram:none
migrator-ctl.sh signal CONSOLIDATE_VM --vmid 108 --min-ram 8192 --nodes emilia,rem
```

### VMState Guardian

```bash
# Logs
journalctl -u vmstate-guardian -f

# Verify snapshots (QMP mode)
ls -la /mnt/pve/cephfs/vmstate/101/latest.state

# Verify snapshots (QM mode)
qm listsnapshot 101 | grep vsg-
```

### Diagnostics

```bash
live-migrator.sh --check        # Quick health check
live-migrator.sh -f             # Run in foreground (debug)
journalctl -fu live-migrator    # Live migrator logs
```

---

## System Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Proxmox VE Cluster                             │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐      │
│  │     EMILIA        │  │       RAM        │  │       REM        │      │
│  │                   │  │                  │  │                  │      │
│  │  ┌─────────────┐ │  │  ┌────────────┐  │  │  ┌────────────┐ │      │
│  │  │live-migrator│ │  │  │live-migrator│  │  │  │live-migrator│ │      │
│  │  │  (daemon)   │ │  │  │  (daemon)  │  │  │  │  (daemon)  │ │      │
│  │  └──────┬──────┘ │  │  └─────┬──────┘  │  │  └─────┬──────┘ │      │
│  │         │        │  │        │         │  │        │        │      │
│  │  ┌──────┴──────┐ │  │  ┌─────┴──────┐  │  │  ┌─────┴──────┐ │      │
│  │  │  vmstate-   │ │  │  │  vmstate-  │  │  │  │  vmstate-  │ │      │
│  │  │  guardian   │ │  │  │  guardian  │  │  │  │  guardian  │ │      │
│  │  └─────────────┘ │  │  └────────────┘  │  │  └────────────┘ │      │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘      │
│           │                     │                     │                 │
│  ┌────────┴─────────────────────┴─────────────────────┴──────────┐     │
│  │                Ceph RBD (Shared Storage)                       │     │
│  │        VM disks  ·  vmstate snapshots  ·  signal files         │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │                   External Monitoring Agents                   │     │
│  │  Agent RAM  ──┐                                               │     │
│  │  Agent vCPU ──┼── .sig files ──▶ live-migrator ──▶ qm migrate │     │
│  │  Agent GPU  ──┘                                               │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │                       Proxmox HA Manager                       │     │
│  │     Detects node failure → restarts VM on surviving node       │     │
│  │     vmstate-guardian detects failover → restores memory state   │     │
│  └────────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────────┘
```

### Signal Flow (Live Migrator)

```
Monitoring Agent          Live Migrator Daemon              Proxmox
     │                          │                            │
     │  write .tmp → rename .sig│                            │
     │─────────────────────────▶│                            │
     │                          │ inotifywait detects .sig   │
     │                          │ Parse signal               │
     │                          │ Evaluate cluster state     │
     │                          │ Select best target node    │
     │                          │───── qm migrate ──────────▶│
     │                          │◀──── result ──────────────│
     │◀── .resp ───────────────│                            │
```

### Failover Flow (VMState Guardian)

```
Normal Operation          Node Failure              Recovery
     │                       │                        │
  [snapshot]              [crash!]                    │
  every Ns ──▶ Ceph      HA detects               vmstate-guardian
     │                   (~60s)                    detects failover
     │                       │                        │
     │                   VM restarted              stops cold VM
     │                   on new node               loads latest.state
     │                       │                    resumes VM
     │                       │                        │
     │                       │                   ≤ N seconds of
     │                       │                   state loss
```

---

## Project Structure

```
MigrationVM/
├── README.md                          # This file
├── live-migrator/
│   ├── daemon/
│   │   ├── live-migrator.sh           # Main daemon (signal-driven)
│   │   ├── migrator-ctl.sh            # Admin CLI
│   │   ├── conf/live-migrator.conf    # Configuration
│   │   ├── systemd/                   # systemd service unit
│   │   └── README.md                  # Daemon documentation
│   ├── scripts/
│   │   ├── install.sh                 # Installation script
│   │   ├── build-deb.sh              # Debian package builder
│   │   └── analyze_migrations.py     # Log analysis & graphs
│   ├── debian-pkg/                    # Debian packaging files
│   ├── ALGORITHMES.md                 # Detailed algorithm documentation
│   ├── INTER_TEAM_API.md             # Inter-agent signal API specification
│   ├── FAQ.md                         # Frequently asked questions
│   ├── SCENARIOS_TESTS.md            # Test scenarios
│   ├── GUIDE_TESTS_ALGORITHMES.md    # Algorithm testing guide
│   └── PROJET_MIGRATION.md          # Project overview & responsibilities
└── vmstate-guardian/
    ├── src/                           # C source code
    │   ├── main.c
    │   ├── config.{c,h}
    │   ├── ha_monitor.{c,h}
    │   ├── snapshot_mgr.{c,h}
    │   ├── restore_engine.{c,h}
    │   ├── qmp.{c,h}
    │   ├── proxmox_cmd.{c,h}
    │   └── logger.{c,h}
    ├── conf/vmstate-guardian.conf     # Configuration
    ├── systemd/                       # systemd service unit
    ├── scripts/install.sh             # Installation script
    ├── docs/                          # Module documentation
    ├── Makefile                       # Build system
    ├── vmstate-guardian               # Compiled binary
    └── README.md                      # Full documentation
```

---

## License

This project is developed as part of an academic project for Proxmox VE cluster management.
