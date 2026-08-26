#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Hardened Firewalld Configurator
# ==============================================================================
# Configures Firewalld with:
# - Complete reset and backup of previous configurations
# - Public zone:
#     * Master: SSH (22), HTTP (80), HTTPS (443) ONLY
#     * Worker: SSH (22) ONLY
# - Trusted zone: tailscale0 interface (Full unrestricted mesh trust)
# - NAT Masquerading: Active for container outbound internet traffic
# - Docker Zone Safety: Prevents ZONE_CONFLICT on docker0 / docker_gwbridge
# Variables:
#   $1 or NODE_ROLE : "master" or "worker" [Default: worker]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/01-detect-os.sh"

ensure_root

NODE_ROLE="${1:-${NODE_ROLE:-worker}}"

echo "===> [Firewalld Hardening] Configuring Firewalld for Node Role: ${NODE_ROLE^^}..."

# 1. Install Firewalld if missing
if ! command -v firewall-cmd &>/dev/null; then
  echo "Installing Firewalld via ${PKG_MGR}..."
  if [ "$OS_FAMILY" = "debian_like" ]; then
    apt-get update && apt-get install -y firewalld
  elif [ "$OS_FAMILY" = "rhel_like" ]; then
    dnf install -y firewalld
  fi
fi

systemctl enable --now firewalld

# 2. Backup existing configuration
if [ -d /etc/firewalld ]; then
  BACKUP_PATH="/etc/firewalld.bak.$(date +%F_%H%M%S)"
  echo "Backing up existing firewalld configuration to ${BACKUP_PATH}..."
  cp -r /etc/firewalld "${BACKUP_PATH}"
fi

# 3. Clean and harden the public zone
echo "Hardening 'public' zone rules..."

# Remove insecure or unnecessary default services and ports
for svc in cockpit dhcpv6-client vnc-server telnet samba; do
  firewall-cmd --permanent --zone=public --remove-service="${svc}" 2>/dev/null || true
done

for port in 41641/udp 1194/udp 51820/udp 8080/tcp 9090/tcp 3552/tcp 7007/tcp 45876/tcp; do
  firewall-cmd --permanent --zone=public --remove-port="${port}" 2>/dev/null || true
done

# Always permit SSH on public zone
firewall-cmd --permanent --zone=public --add-service=ssh

# Configure Master vs Worker public ports
if [ "$NODE_ROLE" = "master" ]; then
  echo "Permitting HTTP (80) and HTTPS (443) on Master public zone..."
  firewall-cmd --permanent --zone=public --add-service=http
  firewall-cmd --permanent --zone=public --add-service=https
else
  echo "Enforcing SSH-only on Worker public zone (blocking external HTTP/HTTPS)..."
  firewall-cmd --permanent --zone=public --remove-service=http 2>/dev/null || true
  firewall-cmd --permanent --zone=public --remove-service=https 2>/dev/null || true
fi

# Enable masquerading for container outbound NAT routing and Tailscale exit node
echo "Enabling NAT masquerade on public zone..."
firewall-cmd --permanent --zone=public --add-masquerade

# Enable Linux Kernel IP Packet Forwarding (Required for Tailscale Exit Node & Subnet Routing)
echo "Configuring Kernel IP packet forwarding in /etc/sysctl.d/99-tailscale-forwarding.conf..."
cat << 'EOF' > /etc/sysctl.d/99-tailscale-forwarding.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale-forwarding.conf 2>/dev/null || sysctl --system >/dev/null 2>&1 || true

# 4. Configure trusted zone for Tailscale mesh
echo "Configuring 'trusted' zone for Tailscale mesh..."
firewall-cmd --permanent --zone=drop --remove-interface=tailscale0 2>/dev/null || true
firewall-cmd --permanent --zone=public --remove-interface=tailscale0 2>/dev/null || true
firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
# Trust all incoming traffic from Tailscale CGNAT subnet (IPv4 & IPv6)
firewall-cmd --permanent --zone=trusted --add-source=100.64.0.0/10
firewall-cmd --permanent --zone=trusted --add-source=fd7a:115c:a1e0::/48

# Ensure docker bridges are NOT in trusted to avoid ZONE_CONFLICT with docker daemon
firewall-cmd --permanent --zone=trusted --remove-interface=docker0 2>/dev/null || true
firewall-cmd --permanent --zone=trusted --remove-interface=docker_gwbridge 2>/dev/null || true

# 5. Reload Firewalld configuration
echo "Reloading Firewalld to apply changes..."
firewall-cmd --reload

echo "✅ [Firewalld Hardening] Completed successfully for ${NODE_ROLE^^} node."
echo "--------------------------------------------------------"
echo " Active Firewalld Zones:"
firewall-cmd --get-active-zones
echo " Public Zone Rules:"
firewall-cmd --zone=public --list-all
echo " Trusted Zone Rules:"
firewall-cmd --zone=trusted --list-all
echo "--------------------------------------------------------"
