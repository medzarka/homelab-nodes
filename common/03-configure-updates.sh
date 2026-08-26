#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Weekly Automatic OS Updates & Reboot Configurator
# ==============================================================================
# Sets up a native systemd service + timer for weekly upgrades & reboot.
# Variables:
#   $1 or UPDATE_DAY  : Day of week (e.g., Sun, Mon, Tue) [Default: Sun]
#   $2 or UPDATE_TIME : Time in HH:MM format [Default: 04:00]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/01-detect-os.sh"

ensure_root

TARGET_DAY="${1:-${UPDATE_DAY:-Sun}}"
TARGET_TIME="${2:-${UPDATE_TIME:-04:00}}"

echo "===> [Auto-Update] Configuring Weekly Maintenance Schedule..."
echo "   • Schedule Day:  ${TARGET_DAY}"
echo "   • Schedule Time: ${TARGET_TIME}"

# 1. Create Maintenance Execution Script
MAINTENANCE_SCRIPT="/usr/local/sbin/homelab-auto-update.sh"

cat << 'EOF' > "${MAINTENANCE_SCRIPT}"
#!/usr/bin/env bash
# ==============================================================================
# Homelab Weekly Maintenance Runner
# Upgrades all packages, cleans caches, and triggers host reboot.
# ==============================================================================

set -euo pipefail
exec > >(logger -t homelab-auto-update -s) 2>&1

echo ">>> [$(date -Iseconds)] Starting scheduled weekly OS update..."

if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_ID_LIKE="${ID_LIKE:-}"
fi

if [[ "$OS_ID" =~ ^(ubuntu|debian|raspbian)$ ]] || [[ "$OS_ID_LIKE" =~ (ubuntu|debian) ]]; then
  echo ">>> Updating Debian/Ubuntu packages via apt-get..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
  apt-get autoremove -y --purge
  apt-get clean
elif [[ "$OS_ID" =~ ^(ol|rhel|centos|rocky|almalinux|fedora)$ ]] || [[ "$OS_ID_LIKE" =~ (rhel|centos|fedora) ]]; then
  echo ">>> Updating RHEL/Oracle Linux packages via dnf..."
  dnf upgrade -y --refresh
  dnf autoremove -y
  dnf clean all
else
  echo ">>> Unknown OS, attempting generic dnf / apt update..."
  if command -v dnf &>/dev/null; then
    dnf upgrade -y
  elif command -v apt-get &>/dev/null; then
    apt-get update && apt-get upgrade -y
  fi
fi

echo ">>> Package updates complete. Scheduling reboot in 1 minute..."
sync
/usr/bin/systemctl reboot
EOF

chmod +x "${MAINTENANCE_SCRIPT}"

# 2. Create Systemd Service
SERVICE_FILE="/etc/systemd/system/homelab-auto-update.service"
cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab Weekly System Package Update and Reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${MAINTENANCE_SCRIPT}
StandardOutput=journal+console
StandardError=journal+console
EOF

# 3. Create Systemd Timer
TIMER_FILE="/etc/systemd/system/homelab-auto-update.timer"
cat << EOF > "${TIMER_FILE}"
[Unit]
Description=Timer for Homelab Weekly System Package Update and Reboot

[Timer]
OnCalendar=${TARGET_DAY} *-*-* ${TARGET_TIME}:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

# 4. Reload and Enable Timer
systemctl daemon-reload
systemctl enable --now homelab-auto-update.timer

echo "✅ [Auto-Update] Weekly update and reboot timer successfully scheduled."
systemctl list-timers homelab-auto-update.timer --no-pager
