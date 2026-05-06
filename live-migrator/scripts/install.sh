#!/bin/bash
set -e

echo "=== Live Migrator v2 — Installation ==="

# Vérifier root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Ce script doit être exécuté en root"
    exit 1
fi

# scripts/ est au même niveau que daemon/ → root = scripts/..
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/daemon"

if [ ! -f "$DAEMON_DIR/live-migrator.sh" ]; then
    echo "ERROR: $DAEMON_DIR/live-migrator.sh introuvable"
    echo "  Assurez-vous que le dossier daemon/ est présent."
    exit 1
fi

# 1. Vérifier les dépendances
echo "[1/6] Vérification des dépendances..."
MISSING=0
for cmd in qm pvesh python3 bash inotifywait; do
    if command -v "$cmd" &>/dev/null; then
        echo "  ✅ $cmd"
    else
        echo "  ❌ $cmd MANQUANT"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Installer les dépendances manquantes :"
    echo "  apt install inotify-tools python3"
    echo ""
    read -p "Continuer quand même ? (o/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Oo]$ ]] && exit 1
fi

# 2. Arrêter l'ancien daemon s'il tourne
echo "[2/6] Arrêt de l'ancien daemon..."
if systemctl is-active --quiet live-migrator 2>/dev/null; then
    systemctl stop live-migrator
    echo "  Ancien daemon arrêté"
else
    echo "  Aucun daemon en cours"
fi

# 3. Installer les scripts
echo "[3/6] Installation des scripts..."
install -m 755 "$DAEMON_DIR/live-migrator.sh" /usr/local/sbin/
install -m 755 "$DAEMON_DIR/migrator-ctl.sh" /usr/local/sbin/
echo "  Installé: /usr/local/sbin/live-migrator.sh"
echo "  Installé: /usr/local/sbin/migrator-ctl.sh"

# 4. Configuration
echo "[4/6] Installation de la configuration..."
install -d /etc/live-migrator
if [ ! -f /etc/live-migrator/live-migrator.conf ]; then
    install -m 644 "$DAEMON_DIR/conf/live-migrator.conf" /etc/live-migrator/
    echo "  Installé: /etc/live-migrator/live-migrator.conf"
else
    install -m 644 "$DAEMON_DIR/conf/live-migrator.conf" /etc/live-migrator/live-migrator.conf.new
    echo "  ⚠️  Config existante conservée"
    echo "  Nouvelle config copiée dans live-migrator.conf.new"
    echo "  → Comparez et ajoutez les nouvelles options (section [orchestrator])"
fi

# 5. Répertoires
echo "[5/6] Création des répertoires..."
install -d /var/lib/live-migrator
install -d /var/lib/live-migrator/signals
install -d /var/lib/live-migrator/signals/processed
install -d /var/lib/live-migrator/signals/responses
install -d /var/lib/live-migrator/vm_cooldowns
install -d /var/lib/live-migrator/pending_consolidations
echo "  Créé: /var/lib/live-migrator/signals/"
echo "  Créé: /var/lib/live-migrator/signals/responses/"
echo "  Créé: /var/lib/live-migrator/vm_cooldowns/"

# 6. Systemd
echo "[6/6] Installation du service systemd..."
install -m 644 "$DAEMON_DIR/systemd/live-migrator.service" /etc/systemd/system/
systemctl daemon-reload
echo "  Installé: /etc/systemd/system/live-migrator.service"

echo ""
echo "=== Installation terminée ==="
echo ""
echo "Prochaines étapes :"
echo "  1. Vérifier /etc/live-migrator/live-migrator.conf"
echo "     - Section [orchestrator] : signal_dir, enable_auto_placement, margin_pct"
echo "  2. Activer et démarrer :"
echo "     systemctl enable live-migrator"
echo "     systemctl start live-migrator"
echo "  3. Vérifier :"
echo "     migrator-ctl.sh status"
echo "     journalctl -u live-migrator -f"
