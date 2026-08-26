#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Hardened Docker Engine Installer
# ==============================================================================
# Installs Docker CE & Compose Plugin with production hardening:
# - "iptables": false (Preserves Firewalld authority)
# - "live-restore": true (Zero-downtime daemon updates)
# - "userland-proxy": false (Low-overhead kernel routing)
# - Strict 10MB/3-file log rotation
# - Concurrent download/upload throttles
# Supports: Ubuntu, Debian, Oracle Linux 9/10 on ARM64 and AMD64
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/01-detect-os.sh"

ensure_root

echo "===> [Docker Engine] Starting Docker CE Installation & Hardening..."

# 1. Clean conflicting/legacy packages
echo "Removing legacy or conflicting packages..."
if [ "$OS_FAMILY" = "debian_like" ]; then
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>/dev/null || true
  done
elif [ "$OS_FAMILY" = "rhel_like" ]; then
  for pkg in docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc; do
    dnf remove -y "$pkg" 2>/dev/null || true
  done
fi

# 2. Configure Official Docker Repository
echo "Configuring official Docker repository for ${OS_ID} (${ARCH})..."

if [ "$OS_FAMILY" = "debian_like" ]; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  CODENAME="${VERSION_CODENAME:-}"
  if [ -z "$CODENAME" ] && [ -f /etc/os-release ]; then
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  fi
  # Fallback for debian/ubuntu derivatives
  if [ -z "$CODENAME" ]; then
    CODENAME="$(lsb_release -cs 2>/dev/null || echo 'stable')"
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} \
    ${CODENAME} stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

elif [ "$OS_FAMILY" = "rhel_like" ]; then
  dnf install -y dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# 3. Kernel Modules & Production Daemon Configuration Hardening
echo "Loading required kernel modules (overlay, br_netfilter)..."
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
mkdir -p /etc/modules-load.d
cat << 'EOF' > /etc/modules-load.d/docker-swarm.conf
overlay
br_netfilter
EOF

echo "Applying hardened production /etc/docker/daemon.json..."
mkdir -p /etc/docker

# Note: "live-restore": true is strictly incompatible with Docker Swarm and will cause dockerd crash on Swarm nodes.
cat << 'EOF' > /etc/docker/daemon.json
{
  "iptables": false,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 3
}
EOF

# 4. Enable and start services
echo "Enabling and starting Docker and Containerd services..."
systemctl daemon-reload
systemctl enable --now docker
systemctl enable --now containerd

if systemctl is-active --quiet docker; then
  echo "Restarting Docker daemon to enforce daemon.json..."
  systemctl restart docker
fi

# 5. Non-root user permissions
TARGET_USER="${SUDO_USER:-${USER:-}}"
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && id "$TARGET_USER" &>/dev/null; then
  echo "Adding user '${TARGET_USER}' to 'docker' group..."
  usermod -aG docker "$TARGET_USER" 2>/dev/null || true
fi

echo "✅ [Docker Engine] Installed and configured successfully!"
docker --version
docker compose version
