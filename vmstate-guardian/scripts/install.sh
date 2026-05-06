#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "=== VMState Guardian Installer ==="
echo "Source directory: $SCRIPT_DIR"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Check dependencies
echo "[1/7] Checking dependencies..."
for cmd in gcc make qm pvesh ha-manager; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "  WARNING: '$cmd' not found"
    else
        echo "  OK: $cmd"
    fi
done

# Compile
echo "[2/7] Compiling..."
cd "$SCRIPT_DIR"
make clean
make
echo "  Binary: $SCRIPT_DIR/vmstate-guardian"

# Install binary
echo "[3/7] Installing binary..."
install -m 755 vmstate-guardian /usr/local/sbin/
echo "  Installed: /usr/local/sbin/vmstate-guardian"

# Install config
echo "[4/7] Installing configuration..."
install -d /etc/vmstate-guardian
if [ ! -f /etc/vmstate-guardian/vmstate-guardian.conf ]; then
    install -m 644 conf/vmstate-guardian.conf /etc/vmstate-guardian/
    echo "  Installed: /etc/vmstate-guardian/vmstate-guardian.conf"
else
    echo "  Config exists, skipping (backup: vmstate-guardian.conf.new)"
    install -m 644 conf/vmstate-guardian.conf /etc/vmstate-guardian/vmstate-guardian.conf.new
fi

# Create directories
echo "[5/7] Creating directories..."
install -d /var/lib/vmstate-guardian
install -d /var/lib/vmstate-guardian/vmstate
echo "  Created: /var/lib/vmstate-guardian"

# Install systemd unit
echo "[6/7] Installing systemd service..."
install -m 644 systemd/vmstate-guardian.service /etc/systemd/system/
systemctl daemon-reload
echo "  Installed: /etc/systemd/system/vmstate-guardian.service"

# Summary
echo "[7/7] Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Edit /etc/vmstate-guardian/vmstate-guardian.conf"
echo "     - Set 'vmid' to your VM ID"
echo "     - Set 'vmstate_path' to a shared storage path"
echo "     - Choose mode: 'qmp' or 'qm'"
echo "  2. Enable and start the service:"
echo "     systemctl enable vmstate-guardian"
echo "     systemctl start vmstate-guardian"
echo "  3. Check status:"
echo "     systemctl status vmstate-guardian"
echo "     journalctl -u vmstate-guardian -f"
echo "     tail -f /var/log/vmstate-guardian.log"
