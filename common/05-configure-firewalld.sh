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

ARCANE_BOOTSTRAP_PORT="${ARCANE_BOOTSTRAP_PORT:-8005}"

# Configure Master vs Worker public ports
if [ "$NODE_ROLE" = "master" ]; then
  echo "Permitting HTTP (80), HTTPS (443), and Arcane Bootstrap Proxy (${ARCANE_BOOTSTRAP_PORT}) on Master public zone..."
  firewall-cmd --permanent --zone=public --add-service=http
  firewall-cmd --permanent --zone=public --add-service=https
  firewall-cmd --permanent --zone=public --add-port="${ARCANE_BOOTSTRAP_PORT}/tcp"
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

# 5. Harden Docker Forwarding Policy (Prevent public port exposure)
echo "Hardening Docker forwarding policy..."
firewall-cmd --permanent --policy docker-forwarding --remove-ingress-zone ANY 2>/dev/null || true
firewall-cmd --permanent --policy docker-forwarding --add-ingress-zone public 2>/dev/null || true
firewall-cmd --permanent --policy docker-forwarding --set-target REJECT 2>/dev/null || true

if [ "$NODE_ROLE" = "master" ]; then
  echo "Permitting HTTP/HTTPS and Bootstrap Proxy forwarding to Docker on Master node..."
  firewall-cmd --permanent --policy docker-forwarding --add-port=80/tcp 2>/dev/null || true
  firewall-cmd --permanent --policy docker-forwarding --add-port=443/tcp 2>/dev/null || true
  firewall-cmd --permanent --policy docker-forwarding --add-port="${ARCANE_BOOTSTRAP_PORT}/tcp" 2>/dev/null || true
fi

# 5.1 Deploy Docker Firewalld Hardening Systemd Service
# This fixes the Docker vs Firewalld race condition: Docker bypasses nftables policies by injecting 
# iptables FORWARD rules. If we use firewalld direct rules to secure DOCKER-USER, `firewall-cmd --reload` 
# crashes because it flushes iptables, destroying the chain before loading the rules. 
# This systemd service dynamically repopulates the chain safely on Docker restart or Firewalld reload.
if [ "${DOCKER_IPTABLES_HARDENING:-true}" = "true" ]; then
  echo "Deploying robust Docker Firewalld Hardening systemd service..."
  
  # Master nodes allow HTTP/HTTPS (80,443) and Arcane Bootstrap Proxy for ingress. Workers only allow internal traffic.
  if [ "$NODE_ROLE" = "master" ]; then
    DOCKER_USER_RULES="iptables -A DOCKER-USER -p tcp -m multiport --dports 80,443,${ARCANE_BOOTSTRAP_PORT} -j RETURN;"
  else
    DOCKER_USER_RULES=""
  fi

  cat << EOF > /etc/systemd/system/docker-firewalld-hardening.service
[Unit]
Description=Docker Firewalld Hardening (DOCKER-USER rules)
After=docker.service firewalld.service
BindsTo=docker.service
ReloadPropagatedFrom=firewalld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/bash -c "iptables -F DOCKER-USER 2>/dev/null || true; iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN; iptables -A DOCKER-USER -i lo -j RETURN; iptables -A DOCKER-USER -i tailscale0 -j RETURN; iptables -A DOCKER-USER -i docker0 -j RETURN; iptables -A DOCKER-USER -i docker_gwbridge -j RETURN; iptables -A DOCKER-USER -i br-+ -j RETURN; ${DOCKER_USER_RULES} iptables -A DOCKER-USER -j REJECT --reject-with icmp-port-unreachable"
ExecReload=/usr/bin/bash -c "iptables -F DOCKER-USER 2>/dev/null || true; iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN; iptables -A DOCKER-USER -i lo -j RETURN; iptables -A DOCKER-USER -i tailscale0 -j RETURN; iptables -A DOCKER-USER -i docker0 -j RETURN; iptables -A DOCKER-USER -i docker_gwbridge -j RETURN; iptables -A DOCKER-USER -i br-+ -j RETURN; ${DOCKER_USER_RULES} iptables -A DOCKER-USER -j REJECT --reject-with icmp-port-unreachable"

[Install]
WantedBy=multi-user.target docker.service
EOF

  systemctl daemon-reload
  systemctl enable --now docker-firewalld-hardening.service
else
  echo "DOCKER_IPTABLES_HARDENING is disabled. Skipping Docker iptables hardening."
fi

# 6. Reload Firewalld configuration
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
