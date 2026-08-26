#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Comprehensive Host Audit & Compliance Check
# ==============================================================================
# Verifies full compliance with homelab security & operational standards:
# 1. Host OS & Architecture
# 2. Firewalld Lockdown & Zone Configuration (Master vs Worker)
# 3. Docker Engine Hardening ("iptables": false, live-restore, logs)
# 4. Docker Swarm Status & Mesh Network
# 5. Host Log Retention (7-day max in journald)
# 6. Automated Weekly Maintenance Timer
# 7. Container Stack Health (Tailscale & Arcane Manager/Agent)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

PASSED_CHECKS=0
WARNING_CHECKS=0
FAILED_CHECKS=0

pass() {
  echo -e "  [ ${GREEN}PASS${NC} ] $1"
  ((PASSED_CHECKS++))
}

warn() {
  echo -e "  [ ${YELLOW}WARN${NC} ] $1"
  ((WARNING_CHECKS++))
}

fail() {
  echo -e "  [ ${RED}FAIL${NC} ] $1"
  ((FAILED_CHECKS++))
}

info() {
  echo -e "  [ ${BLUE}INFO${NC} ] $1"
}

# Determine Role
NODE_ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role|-r)
      NODE_ROLE="$2"
      shift 2
      ;;
    master|worker)
      NODE_ROLE="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$NODE_ROLE" ]; then
  # Auto-detect from docker containers or prompt
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "arcane$"; then
    NODE_ROLE="master"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "arcane-agent"; then
    NODE_ROLE="worker"
  else
    NODE_ROLE="worker"
  fi
fi

echo ""
echo -e "${BOLD}${CYAN}====================================================================${NC}"
echo -e "${BOLD}${CYAN}         🔍 HOMELAB NODE SECURITY & COMPLIANCE AUDIT                ${NC}"
echo -e "${BOLD}${CYAN}====================================================================${NC}"
echo -e " Auditing Target Role: ${BOLD}${NODE_ROLE^^}${NC}"
echo " Timestamp:            $(date -Iseconds)"
echo " Hostname:             $(hostname)"
echo ""

# ------------------------------------------------------------------------------
# 1. Host OS & Architecture
# ------------------------------------------------------------------------------
echo -e "${BOLD}1. 🖥️ Operating System & Architecture${NC}"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  pass "Operating System: ${NAME:-Linux} ${VERSION_ID:-} (Kernel: $(uname -r))"
  pass "CPU Architecture: $(uname -m)"
else
  fail "/etc/os-release not found."
fi
echo ""

# ------------------------------------------------------------------------------
# 2. Firewalld Configuration & Zone Hardening
# ------------------------------------------------------------------------------
echo -e "${BOLD}2. 🛡️ Firewalld Firewall Hardening${NC}"
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
  pass "Firewalld service is active and running."

  # Check Public Zone
  PUB_SERVICES="$(firewall-cmd --zone=public --list-services 2>/dev/null || echo '')"
  PUB_MASQ="$(firewall-cmd --zone=public --query-masquerade 2>/dev/null && echo 'yes' || echo 'no')"

  if [[ "$PUB_SERVICES" =~ "ssh" ]]; then
    pass "Public zone permits SSH service."
  else
    fail "Public zone is missing SSH service!"
  fi

  if [ "$PUB_MASQ" = "yes" ]; then
    pass "Public zone NAT masquerading is ENABLED (Outbound container routing active)."
  else
    fail "Public zone NAT masquerading is DISABLED! Containers cannot route traffic outbound."
  fi

  if [ "$NODE_ROLE" = "master" ]; then
    if [[ "$PUB_SERVICES" =~ "http" ]] && [[ "$PUB_SERVICES" =~ "https" ]]; then
      pass "Master public zone permits HTTP (80) and HTTPS (443)."
    else
      warn "Master public zone is missing HTTP/HTTPS service (expected for web ingress)."
    fi
  else
    if [[ "$PUB_SERVICES" =~ "http" ]] || [[ "$PUB_SERVICES" =~ "https" ]]; then
      warn "Worker node has public HTTP/HTTPS open. (Recommended: SSH-only on workers)."
    else
      pass "Worker public zone is strictly locked down (SSH only, no public HTTP/HTTPS)."
    fi
  fi

  # Check Trusted Zone & Tailscale Interface
  ACTIVE_ZONES="$(firewall-cmd --get-active-zones 2>/dev/null || echo '')"
  TRUSTED_IFACES="$(firewall-cmd --zone=trusted --list-interfaces 2>/dev/null || echo '')"

  if [[ "$TRUSTED_IFACES" =~ "tailscale0" ]]; then
    pass "Interface 'tailscale0' is assigned to the 'trusted' zone (Inter-node mesh open)."
  else
    warn "Interface 'tailscale0' is not in trusted zone. (May occur if Tailscale container is not yet started)."
  fi

  # Check for ZONE_CONFLICT hazards
  if [[ "$TRUSTED_IFACES" =~ "docker0" ]] || [[ "$TRUSTED_IFACES" =~ "docker_gwbridge" ]]; then
    fail "ZONE CONFLICT DETECTED: docker0/docker_gwbridge found in 'trusted' zone! Remove with: firewall-cmd --permanent --zone=trusted --remove-interface=docker0"
  else
    pass "Docker bridges (docker0, docker_gwbridge) are isolated from trusted zone (No zone conflicts)."
  fi

else
  fail "Firewalld is not installed or not running!"
fi
echo ""

# ------------------------------------------------------------------------------
# 3. Docker Engine Configuration & Hardening
# ------------------------------------------------------------------------------
echo -e "${BOLD}3. 🐳 Docker Engine & Daemon Hardening${NC}"
if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
  DOCKER_VER="$(docker --version 2>/dev/null || echo 'Unknown')"
  pass "Docker Engine is active: ${DOCKER_VER}"

  DAEMON_JSON="/etc/docker/daemon.json"
  if [ -f "$DAEMON_JSON" ]; then
    pass "Configuration file ${DAEMON_JSON} exists."

    # Check iptables: false
    if grep -q '"iptables"[[:space:]]*:[[:space:]]*false' "$DAEMON_JSON"; then
      pass "Docker 'iptables: false' is configured (Firewall bypass prevented)."
    else
      fail "Docker 'iptables: false' is MISSING in ${DAEMON_JSON}! Docker may expose published ports directly."
    fi

    # Check live-restore
    if grep -q '"live-restore"[[:space:]]*:[[:space:]]*true' "$DAEMON_JSON"; then
      pass "Docker 'live-restore: true' is configured (Zero-downtime container uptime)."
    else
      warn "Docker 'live-restore: true' is not set."
    fi

    # Check logging driver and limits
    if grep -q '"max-size"' "$DAEMON_JSON" && grep -q '"max-file"' "$DAEMON_JSON"; then
      pass "Docker container log rotation limits are configured."
    else
      warn "Docker log rotation limits ('max-size'/'max-file') not detected in daemon.json."
    fi

  else
    fail "Missing ${DAEMON_JSON} configuration file!"
  fi
else
  fail "Docker Engine is not installed or not running!"
fi
echo ""

# ------------------------------------------------------------------------------
# 4. Docker Swarm Cluster Status
# ------------------------------------------------------------------------------
echo -e "${BOLD}4. 🐝 Docker Swarm Cluster & Overlay Mesh${NC}"
if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
  SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo 'inactive')"
  
  if [ "$SWARM_STATE" = "active" ]; then
    IS_MANAGER="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo 'false')"
    if [ "$IS_MANAGER" = "true" ]; then
      pass "Docker Swarm is ACTIVE (Role: Manager/Leader)."
      NODE_COUNT="$(docker node ls -q 2>/dev/null | wc -l | tr -d ' ' || echo '1')"
      info "Total Swarm Nodes connected: ${NODE_COUNT}"
    else
      pass "Docker Swarm is ACTIVE (Role: Worker Node)."
    fi

    # Check Swarm Overlay Network
    SWARM_NET="${SWARM_NETWORK:-homelab_swarm_net}"
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${SWARM_NET}$"; then
      pass "Attachable overlay network '${SWARM_NET}' is active and ready."
    else
      info "Overlay network '${SWARM_NET}' not found on this node yet (created when stacks attach)."
    fi

    # Check Local Shared Bridge Network
    SHARED_NET="${SHARED_NETWORK:-shared_net}"
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${SHARED_NET}$"; then
      pass "Shared bridge network '${SHARED_NET}' is active."
    else
      warn "Shared bridge network '${SHARED_NET}' not found. Run 'docker network create ${SHARED_NET}'."
    fi
  else
    warn "Docker Swarm is INACTIVE on this node."
  fi
fi
echo ""

# ------------------------------------------------------------------------------
# 5. Host Log Retention (7-Day Limit)
# ------------------------------------------------------------------------------
echo -e "${BOLD}5. 📜 Host Logging System (7-Day Retention)${NC}"
RETENTION_CONF="/etc/systemd/journald.conf.d/00-homelab-retention.conf"
if [ -f "$RETENTION_CONF" ]; then
  if grep -q "MaxRetentionSec=7day" "$RETENTION_CONF"; then
    pass "Journald 7-day retention policy is active (${RETENTION_CONF})."
  else
    warn "Journald retention configuration exists but MaxRetentionSec is not set to 7day."
  fi
else
  # Check main journald.conf
  if grep -q "^[[:space:]]*MaxRetentionSec=7day" /etc/systemd/journald.conf 2>/dev/null; then
    pass "Journald 7-day retention policy is active in /etc/systemd/journald.conf."
  else
    fail "7-day journald retention policy not configured!"
  fi
fi

if command -v journalctl &>/dev/null; then
  JOURNAL_USAGE="$(journalctl --disk-usage 2>/dev/null || echo 'N/A')"
  info "Current Journal Disk Footprint: ${JOURNAL_USAGE}"
fi
echo ""

# ------------------------------------------------------------------------------
# 6. Automated Weekly Updates & Scheduled Reboot
# ------------------------------------------------------------------------------
echo -e "${BOLD}6. ⏰ Automated Weekly Maintenance Timer${NC}"
if systemctl is-active --quiet homelab-auto-update.timer 2>/dev/null; then
  pass "Systemd timer 'homelab-auto-update.timer' is ENABLED and ACTIVE."
  NEXT_TRIGGER="$(systemctl list-timers homelab-auto-update.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3, $4}' || echo 'Unknown')"
  info "Next scheduled update & reboot: ${NEXT_TRIGGER}"
else
  fail "Maintenance timer 'homelab-auto-update.timer' is NOT active!"
fi
echo ""

# ------------------------------------------------------------------------------
# 7. Container Stack Health (Tailscale & Arcane)
# ------------------------------------------------------------------------------
echo -e "${BOLD}7. 📦 Containerized Services (Tailscale & Arcane)${NC}"
if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
  # Check Tailscale
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"; then
    TS_IP="$(docker exec tailscale tailscale ip -4 2>/dev/null || echo '')"
    if [ -n "$TS_IP" ]; then
      pass "Tailscale container is running (Mesh IP: ${TS_IP})."
    else
      warn "Tailscale container is running but Mesh IP not acquired (interactive login required)."
    fi
  else
    fail "Tailscale container is NOT running!"
  fi

  # Check Arcane
  if [ "$NODE_ROLE" = "master" ]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^arcane$"; then
      pass "Arcane Manager container is running."
    else
      fail "Arcane Manager container is NOT running!"
    fi
  else
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^arcane-agent$"; then
      pass "Arcane Agent container is running."
    else
      fail "Arcane Agent container is NOT running!"
    fi
  fi
fi
echo ""

# ------------------------------------------------------------------------------
# 8. Storage & Disk I/O Optimizations (Optional / Deep Optimized Nodes)
# ------------------------------------------------------------------------------
echo -e "${BOLD}8. ⚡ Storage & Disk I/O Optimizations${NC}"
DEEP_STORAGE_CONFIGURED=false

# Check Udev rules
if [ -f "/etc/udev/rules.d/60-homelab-ioscheduler.rules" ] || [ -f "/etc/udev/rules.d/60-ioscheduler.rules" ]; then
  pass "Block I/O queue udev rules configured."
  DEEP_STORAGE_CONFIGURED=true
else
  info "Block I/O queue udev rules not installed (standard for non-compute nodes)."
fi

# Check Sysctl Storage parameters
if [ -f "/etc/sysctl.d/99-storage-anti-freeze.conf" ]; then
  DIRTY_BYTES="$(sysctl -n vm.dirty_bytes 2>/dev/null || echo '0')"
  VFS_PRESS="$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo '100')"
  if [ "$DIRTY_BYTES" = "67108864" ] && [ "$VFS_PRESS" = "50" ]; then
    pass "Storage anti-freeze sysctl parameters active (dirty_bytes=64MB, vfs_cache_pressure=50)."
    DEEP_STORAGE_CONFIGURED=true
  else
    warn "Storage anti-freeze sysctl file present but values differ (dirty_bytes=${DIRTY_BYTES}, vfs_cache_pressure=${VFS_PRESS})."
  fi
else
  info "Storage anti-freeze sysctl not configured (default OS parameters active)."
fi

# Check Ephemeral RAM-Disk
if mountpoint -q /mnt/ramdisk 2>/dev/null; then
  RAMDISK_USAGE="$(df -h /mnt/ramdisk | tail -1 | awk '{print $2, "total,", $4, "available"}')"
  pass "Ephemeral RAM-Disk mounted at /mnt/ramdisk (${RAMDISK_USAGE})."
  DEEP_STORAGE_CONFIGURED=true
else
  info "Ephemeral RAM-Disk (/mnt/ramdisk) is not mounted."
fi

# Check ZFS rate limiter if ZFS present
if [ -d /sys/module/zfs ]; then
  if [ -f "/etc/modprobe.d/zfs.conf" ]; then
    pass "ZFS kernel module trickle-write rate limiter configured."
  else
    warn "ZFS kernel module loaded without trickle-write rate limiter (/etc/modprobe.d/zfs.conf)."
  fi
fi
echo ""

# ------------------------------------------------------------------------------
# Audit Summary
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}====================================================================${NC}"
echo -e "${BOLD}                     AUDIT RESULTS SUMMARY                         ${NC}"
echo -e "${BOLD}${CYAN}====================================================================${NC}"
echo -e "  Passed Checks:   ${GREEN}${PASSED_CHECKS}${NC}"
echo -e "  Warnings:        ${YELLOW}${WARNING_CHECKS}${NC}"
echo -e "  Failed Checks:   ${RED}${FAILED_CHECKS}${NC}"
echo ""

if [ "$FAILED_CHECKS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}🎉 COMPLIANCE AUDIT PASSED! This node satisfies all Homelab standards.${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}❌ AUDIT FAILED with ${FAILED_CHECKS} error(s). Please review the items marked [ FAIL ] above.${NC}"
  exit 1
fi
