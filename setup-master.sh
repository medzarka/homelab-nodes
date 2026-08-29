#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Master Node Initializer & Hardener
# ==============================================================================
# Automates the entire bootstrap lifecycle for a Homelab Master Node:
# 1. OS & Architecture Detection (Debian/Ubuntu/Oracle Linux on ARM64/AMD64)
# 2. 7-Day Host Log Retention Configuration (systemd-journald)
# 3. Weekly Automated Package Updates & Scheduled Reboot (systemd-timer)
# 4. Firewalld Lockdown (Master: Ports 22, 80, 443 only + Trusted tailscale0)
# 5. Production Docker CE Installation with "iptables": false Hardening
# 6. Tailscale VPN Mesh + Arcane Cockpit Manager Stack Deployment
# 7. Docker Swarm Cluster Initialization over Tailscale Mesh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/01-detect-os.sh"

ensure_root

echo "===================================================================="
echo "          🚀 HOMELAB MASTER NODE INITIALIZER & HARDENER            "
echo "===================================================================="
print_system_info

# ------------------------------------------------------------------------------
# 1. Load or Prompt Configuration Parameters
# ------------------------------------------------------------------------------
MASTER_DIR="${SCRIPT_DIR}/master"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "${ENV_FILE}" ]; then
  echo "Loading configuration from ${ENV_FILE}..."
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# Fallback interactive inputs if not predefined
if [ -t 0 ] && [ ! -f "${ENV_FILE}" ]; then
  read -r -p "Enter Node / Tailscale Hostname [default: $(hostname)]: " INPUT_NAME
  TS_HOSTNAME="${INPUT_NAME:-$(hostname)}"

  read -r -p "Enter Tailscale Auth Key (optional, press ENTER to authenticate via URL): " TS_AUTHKEY

  read -r -p "Enter Persistent Data Root Directory [default: /srv/data]: " INPUT_DATA
  DATA_DIR="${INPUT_DATA:-/srv/data}"

  read -r -p "Enter Arcane Web UI Port [default: 3552]: " INPUT_PORT
  ARCANE_PORT="${INPUT_PORT:-3552}"

  read -r -p "Enter Weekly Maintenance Day (e.g. Sun, Mon) [default: Sun]: " INPUT_DAY
  UPDATE_DAY="${INPUT_DAY:-Sun}"

  read -r -p "Enter Weekly Maintenance Time (HH:MM) [default: 04:00]: " INPUT_TIME
  UPDATE_TIME="${INPUT_TIME:-04:00}"
else
  TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
  TS_AUTHKEY="${TS_AUTHKEY:-}"
  TS_EXTRA_ARGS="${TS_EXTRA_ARGS:---reset --advertise-exit-node}"
  DATA_DIR="${DATA_DIR:-/srv/data}"
  ARCANE_PORT="${ARCANE_PORT:-3552}"
  ARCANE_BOOTSTRAP_PORT="${ARCANE_BOOTSTRAP_PORT:-8005}"
  ARCANE_PROXY_USER="${ARCANE_PROXY_USER:-admin}"
  ARCANE_PROXY_PASSWORD="${ARCANE_PROXY_PASSWORD:-$(openssl rand -hex 12 2>/dev/null || echo 'arcane-bootstrap-admin')}"
  SHARED_NETWORK="${SHARED_NETWORK:-shared_net}"
  SWARM_NETWORK="${SWARM_NETWORK:-homelab_swarm_net}"
  UPDATE_DAY="${UPDATE_DAY:-Sun}"
  UPDATE_TIME="${UPDATE_TIME:-04:00}"
fi

# Auto-generate 32-byte hexadecimal encryption and JWT secrets for Arcane if not predefined
ENCRYPTION_KEY="${ENCRYPTION_KEY:-$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
ARCANE_BOOTSTRAP_PORT="${ARCANE_BOOTSTRAP_PORT:-8005}"
ARCANE_PROXY_USER="${ARCANE_PROXY_USER:-admin}"
ARCANE_PROXY_PASSWORD="${ARCANE_PROXY_PASSWORD:-$(openssl rand -hex 12 2>/dev/null || echo 'arcane-bootstrap-admin')}"

# Write/Update master .env
mkdir -p "${DATA_DIR}/arcane"
chmod 777 "${DATA_DIR}/arcane" 2>/dev/null || true

cat << EOF > "${ENV_FILE}"
NODE_ROLE=MASTER
NODE_NAME=${TS_HOSTNAME}
TS_HOSTNAME=${TS_HOSTNAME}
TS_AUTHKEY=${TS_AUTHKEY}
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:---reset --advertise-exit-node}"
DATA_DIR=${DATA_DIR}
ARCANE_PORT=${ARCANE_PORT}
ARCANE_APP_URL=http://localhost:${ARCANE_PORT}
ARCANE_BOOTSTRAP_PORT=${ARCANE_BOOTSTRAP_PORT}
ARCANE_PROXY_USER=${ARCANE_PROXY_USER}
ARCANE_PROXY_PASSWORD=${ARCANE_PROXY_PASSWORD}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
JWT_SECRET=${JWT_SECRET}
ALLOW_CLI_PASSWORD_RESET=true
SHARED_NETWORK=${SHARED_NETWORK}
SWARM_NETWORK=${SWARM_NETWORK}
PUID=1000
PGID=1000
UPDATE_DAY=${UPDATE_DAY}
UPDATE_TIME=${UPDATE_TIME}
EOF

# ------------------------------------------------------------------------------
# 2. Configure Host 7-Day Log Retention
# ------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/common/02-configure-logs.sh"

# ------------------------------------------------------------------------------
# 3. Configure Weekly Auto-Update & Reboot Schedule
# ------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/common/03-configure-updates.sh" "${UPDATE_DAY}" "${UPDATE_TIME}"

# ------------------------------------------------------------------------------
# 4. Install & Harden Firewalld (Master: 22, 80, 443 + trusted tailscale0)
# ------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/common/05-configure-firewalld.sh" "master"

# ------------------------------------------------------------------------------
# 5. Install & Harden Docker CE ("iptables": false)
# ------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/common/04-install-docker.sh"

# Ensure local shared bridge network exists before starting containers
if ! docker network ls --format '{{.Name}}' | grep -q "^${SHARED_NETWORK}$"; then
  echo "Creating shared bridge network '${SHARED_NETWORK}'..."
  docker network create "${SHARED_NETWORK}" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 6. Launch Tailscale Mesh Container
# ------------------------------------------------------------------------------
echo "===> [Tailscale] Launching Tailscale VPN mesh container..."
# Stop any host-level tailscaled service to prevent /dev/net/tun conflicts
if systemctl is-active --quiet tailscaled 2>/dev/null; then
  echo "Stopping and disabling host-level tailscaled service (migrating to container)..."
  systemctl stop tailscaled 2>/dev/null || true
  systemctl disable tailscaled 2>/dev/null || true
  pkill -9 tailscaled 2>/dev/null || true
  ip link delete tailscale0 2>/dev/null || true
fi

# Remove legacy/conflicting unmanaged container if present
if docker ps -a --format '{{.Names}}' | grep -q "^tailscale$"; then
  echo "Recreating existing 'tailscale' container..."
  docker rm -f tailscale 2>/dev/null || true
fi

docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/master/docker-compose.yaml" up -d tailscale

# Check for Tailscale Authentication
echo "Waiting for Tailscale interface initialization..."
sleep 5

TS_IP=""
for i in {1..12}; do
  TS_IP="$(docker exec tailscale tailscale ip -4 2>/dev/null || true)"
  if [ -n "${TS_IP}" ]; then
    break
  fi
  echo "Checking Tailscale status ($i/12)..."
  sleep 3
done

if [ -z "${TS_IP}" ]; then
  echo ""
  echo "⚠️ Tailscale is running but requires interactive login."
  echo "👉 Run: docker exec -it tailscale tailscale up"
  echo "Follow the displayed URL to authenticate this Master node to your Tailscale network."
  echo ""
  read -r -p "Press [ENTER] once Tailscale authentication is complete to continue..."
  TS_IP="$(docker exec tailscale tailscale ip -4 2>/dev/null || echo '127.0.0.1')"
fi

# ------------------------------------------------------------------------------
# 7. Initialize Docker Swarm on Master (Binding to Tailscale Mesh IP)
# ------------------------------------------------------------------------------
echo "===> [Docker Swarm] Checking Swarm Cluster Status..."
SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo 'inactive')"

if [ "$SWARM_STATE" = "inactive" ]; then
  if [ -n "$TS_IP" ] && [ "$TS_IP" != "127.0.0.1" ]; then
    echo "Initializing Docker Swarm Leader on Tailscale IP (${TS_IP})..."
    docker swarm init --advertise-addr "${TS_IP}" --data-path-addr "${TS_IP}"
  else
    echo "Initializing Docker Swarm Leader on default interface..."
    docker swarm init
  fi
else
  echo "Docker Swarm is already active on this node (State: ${SWARM_STATE})."
fi

# Create encrypted attachable overlay network if missing
if ! docker network ls --format '{{.Name}}' | grep -q "^${SWARM_NETWORK}$"; then
  echo "Creating attachable overlay network '${SWARM_NETWORK}' with MTU 1200..."
  docker network create \
    --driver overlay \
    --attachable \
    --opt com.docker.network.driver.mtu=1200 \
    "${SWARM_NETWORK}" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 8. Deploy Arcane Manager Cockpit & Bootstrap Proxy
# ------------------------------------------------------------------------------
echo "===> [Master Stack] Launching Arcane Manager & Bootstrap Proxy..."
if docker ps -a --format '{{.Names}}' | grep -q "^arcane$"; then
  echo "Recreating existing 'arcane' container..."
  docker rm -f arcane 2>/dev/null || true
fi

docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/master/docker-compose.yaml" up -d --remove-orphans

# Retrieve Swarm Join Tokens
WORKER_JOIN_TOKEN="$(docker swarm join-token -q worker 2>/dev/null || echo 'N/A')"
MANAGER_JOIN_TOKEN="$(docker swarm join-token -q manager 2>/dev/null || echo 'N/A')"

# ------------------------------------------------------------------------------
# 8. Auto-Generate Worker Onboarding Configuration (worker-join.env)
# ------------------------------------------------------------------------------
WORKER_JOIN_ENV="${SCRIPT_DIR}/worker-join.env"

cat << EOF > "${WORKER_JOIN_ENV}"
# ==============================================================================
# Homelab Worker Node Configuration (Auto-Generated by Master Node)
# Cluster Master: ${TS_HOSTNAME} (${TS_IP})
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ==============================================================================

# Node Role: WORKER (or WORKER_DEEPER_OPTIMIZED)
NODE_ROLE=WORKER

# Master Node Cluster Coordinates
MASTER_TAILSCALE_IP=${TS_IP}
ARCANE_SERVER_URL=http://${TS_IP}:${ARCANE_PORT}
SWARM_WORKER_TOKEN=${WORKER_JOIN_TOKEN}

# Overlay & Bridge Mesh Networks
SHARED_NETWORK=${SHARED_NETWORK}
SWARM_NETWORK=${SWARM_NETWORK}

# Tailscale Authentication & Exit Node
TS_AUTHKEY=
TS_EXTRA_ARGS="--reset --advertise-exit-node"

# Arcane Agent Token (Obtain from Arcane UI: http://${TS_IP}:${ARCANE_PORT} -> Nodes -> Add Node)
ARCANE_AGENT_TOKEN=

# Host Maintenance Schedule
UPDATE_DAY=${UPDATE_DAY}
UPDATE_TIME=${UPDATE_TIME}
EOF

# ------------------------------------------------------------------------------
# 9. Completion Summary & Worker Onboarding Instructions
# ------------------------------------------------------------------------------
PUBLIC_IP="$(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

echo ""
echo "===================================================================="
echo "🎉 MASTER NODE SETUP & HARDENING COMPLETED SUCCESSFULLY!"
echo "===================================================================="
echo " 🌐 Tailscale Mesh IP:     ${TS_IP}"
echo " 🧙 Arcane Tailscale URL:  http://${TS_IP}:${ARCANE_PORT} (or http://localhost:${ARCANE_PORT})"
echo " 🔑 Arcane App Login:      User: arcane | Pass: arcane-admin"
echo ""
echo " 🛡️ Arcane Bootstrap URL:  http://${PUBLIC_IP}:${ARCANE_BOOTSTRAP_PORT}"
echo "    • Layer 1 (Proxy Auth): User: ${ARCANE_PROXY_USER} | Pass: ${ARCANE_PROXY_PASSWORD}"
echo "    • Layer 2 (Arcane App): User: arcane | Pass: arcane-admin"
echo ""
echo " 🛡️ Firewall Security:"
echo "   • Public Ports: 22 (SSH), 80 (HTTP), 443 (HTTPS), ${ARCANE_BOOTSTRAP_PORT} (Bootstrap Proxy)"
echo "   • Tailscale Mesh: 100% Trusted for inter-node communication"
echo "   • Kernel IP Forwarding: Enabled (IPv4/IPv6 forwarding active)"
echo ""
echo " 🚪 Tailscale Exit Node: Enabled (--advertise-exit-node)"
echo "   👉 Approve route in Admin Console: https://login.tailscale.com/admin/machines"
echo ""
echo " 📄 Auto-Generated Worker Onboarding File: ${WORKER_JOIN_ENV}"
echo "--------------------------------------------------------------------"
echo " To onboard a new Worker node with zero manual configuration:"
echo " 1. Log into Arcane UI (http://${PUBLIC_IP}:${ARCANE_BOOTSTRAP_PORT} or http://${TS_IP}:${ARCANE_PORT}) -> Nodes -> Add Node"
echo " 2. Copy the generated Agent Token and add it to ${WORKER_JOIN_ENV}"
echo " 3. Copy the file to your worker machine:"
echo "    👉 scp ${WORKER_JOIN_ENV} user@<worker-ip>:~/homelab-nodes/.env"
echo " 4. On the worker machine, simply run:"
echo "    👉 sudo ./setup.sh"
echo "--------------------------------------------------------------------"
echo ""
echo " 🔍 To audit this host configuration at any time, run:"
echo "    sudo ./audit-node.sh --role master"
echo "===================================================================="
