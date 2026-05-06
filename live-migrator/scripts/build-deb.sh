#!/bin/bash
# ============================================================================
# build-deb.sh — Construit le paquet Debian (.deb) de live-migrator v2
#
# Usage : ./scripts/build-deb.sh
# Résultat : live-migrator_2.0.0_all.deb (dans le dossier racine)
# ============================================================================

set -e

# scripts/ est au même niveau que daemon/ et debian-pkg/
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/daemon"
PKG_DIR="$ROOT_DIR/debian-pkg"
VERSION="2.0.0"

if [ ! -f "$DAEMON_DIR/live-migrator.sh" ]; then
    echo "ERROR: $DAEMON_DIR/live-migrator.sh introuvable"
    exit 1
fi

echo "=== Construction du paquet live-migrator_${VERSION}_all.deb ==="

# 1. Préparer l'arborescence du paquet
echo "[1/4] Copie des fichiers depuis daemon/..."

mkdir -p "$PKG_DIR/usr/local/sbin"
mkdir -p "$PKG_DIR/etc/live-migrator"
mkdir -p "$PKG_DIR/etc/systemd/system"
mkdir -p "$PKG_DIR/var/lib/live-migrator/signals/processed"
mkdir -p "$PKG_DIR/var/lib/live-migrator/signals/responses"
mkdir -p "$PKG_DIR/var/lib/live-migrator/vm_cooldowns"
mkdir -p "$PKG_DIR/var/lib/live-migrator/pending_consolidations"

cp "$DAEMON_DIR/live-migrator.sh" "$PKG_DIR/usr/local/sbin/"
cp "$DAEMON_DIR/migrator-ctl.sh" "$PKG_DIR/usr/local/sbin/"
chmod 755 "$PKG_DIR/usr/local/sbin/live-migrator.sh"
chmod 755 "$PKG_DIR/usr/local/sbin/migrator-ctl.sh"

cp "$DAEMON_DIR/conf/live-migrator.conf" "$PKG_DIR/etc/live-migrator/"
chmod 644 "$PKG_DIR/etc/live-migrator/live-migrator.conf"

cp "$DAEMON_DIR/systemd/live-migrator.service" "$PKG_DIR/etc/systemd/system/"
chmod 644 "$PKG_DIR/etc/systemd/system/live-migrator.service"

# 2. Permissions sur les scripts DEBIAN
echo "[2/4] Permissions..."
chmod 755 "$PKG_DIR/DEBIAN/postinst"
chmod 755 "$PKG_DIR/DEBIAN/prerm"

# 3. Construire le .deb
echo "[3/4] Construction du paquet..."
dpkg-deb --build "$PKG_DIR" "$ROOT_DIR/live-migrator_${VERSION}_all.deb"

# 4. Vérifier
echo "[4/4] Vérification..."
dpkg-deb --info "$ROOT_DIR/live-migrator_${VERSION}_all.deb"

echo ""
echo "=== Paquet créé : live-migrator_${VERSION}_all.deb ==="
echo ""
echo "Installation sur un noeud Proxmox :"
echo "  scp live-migrator_${VERSION}_all.deb root@<IP_NOEUD>:/tmp/"
echo "  ssh root@<IP_NOEUD> dpkg -i /tmp/live-migrator_${VERSION}_all.deb"
