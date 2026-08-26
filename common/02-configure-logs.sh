#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Host Logging System 7-Day Retention Configurator
# ==============================================================================
# Configures systemd-journald and logrotate to strictly retain max 7 days of logs.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/01-detect-os.sh"

ensure_root

echo "===> [Log Configuration] Configuring 7-day Host Log Retention..."

# 1. Configure systemd-journald
JOURNALD_CONF_DIR="/etc/systemd/journald.conf.d"
JOURNALD_CONF_FILE="${JOURNALD_CONF_DIR}/00-homelab-retention.conf"

mkdir -p "${JOURNALD_CONF_DIR}"

echo "Writing persistent retention settings to ${JOURNALD_CONF_FILE}..."
cat << 'EOF' > "${JOURNALD_CONF_FILE}"
[Journal]
# Ensure persistent storage on disk
Storage=persistent
# Retain journal entries for at most 7 days
MaxRetentionSec=7day
# Rotate journal files at least once every 24 hours
MaxFileSec=1day
# Cap total journal disk footprint to 500MB
SystemMaxUse=500M
# Cap individual journal file size to 50MB
SystemMaxFileSize=50M
# Rate limit burst logs to prevent I/O saturation
RateLimitIntervalSec=30s
RateLimitBurst=10000
EOF

# 2. Restart systemd-journald to apply changes
if systemctl is-active --quiet systemd-journald 2>/dev/null; then
  echo "Restarting systemd-journald..."
  systemctl restart systemd-journald
fi

# 3. Vacuum existing logs immediately
echo "Vacuuming logs older than 7 days..."
if command -v journalctl &>/dev/null; then
  journalctl --vacuum-time=7d 2>/dev/null || true
  journalctl --vacuum-size=500M 2>/dev/null || true
fi

# 4. Configure Logrotate baseline if logrotate is installed
if [ -d /etc/logrotate.d ]; then
  echo "Configuring logrotate default max retention..."
  cat << 'EOF' > /etc/logrotate.d/00-homelab-retention
# Global homelab 7-day max retention safety net
/var/log/messages /var/log/syslog /var/log/auth.log /var/log/secure /var/log/daemon.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        systemctl reload-or-try-restart rsyslog 2>/dev/null || true
    endscript
}
EOF
fi

echo "✅ [Log Configuration] Host log retention set to max 7 days (500MB cap)."
if command -v journalctl &>/dev/null; then
  CURRENT_JOURNAL_SIZE="$(journalctl --disk-usage 2>/dev/null || echo 'N/A')"
  echo "   Current Journal Disk Usage: ${CURRENT_JOURNAL_SIZE}"
fi
