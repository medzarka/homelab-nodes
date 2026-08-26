#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Deeper Optimized Worker Initializer
# ==============================================================================
# Automates the entire bootstrap lifecycle for a High-Performance Worker Node:
# 1. OS & Architecture Detection (Debian/Ubuntu/Oracle Linux on ARM64/AMD64)
# 2. 7-Day Host Log Retention Configuration (systemd-journald)
# 3. Weekly Automated Package Updates & Scheduled Reboot (systemd-timer)
# 4. Firewalld Lockdown (Worker: Port 22 SSH only + Trusted tailscale0)
# 5. Advanced Storage & Disk I/O Performance Hardening:
#    * Udev block layer queue tuning (none scheduler, 128KB read-ahead)
#    * Kernel storage anti-freeze sysctl (64MB dirty cap, vfs_cache_pressure=50)
#    * ZFS trickle-write rate limiter (if ZFS is present)
#    * Ephemeral high-speed RAM-disk (/mnt/ramdisk)
# 6. Production Docker CE Installation with "iptables": false Hardening
# 7. Tailscale VPN Mesh + Arcane Agent Deployment
# 8. Docker Swarm Worker Cluster Join (over Tailscale Mesh)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/01-detect-os.sh"

ensure_root

echo "===================================================================="
echo "    🚀 HOMELAB WORKER INITIALIZER (DEEP STORAGE & I/O OPTIMIZED)   "
echo "===================================================================="
print_system_info

# ------------------------------------------------------------------------------
# 1. Load or Prompt Configuration Parameters
# ------------------------------------------------------------------------------
WORKER_DIR="${SCRIPT_DIR}/worker"
ENV_FILE="${WORKER_DIR}/.env"

if [ -f "${ENV_FILE}" ]; then
  echo "Loading existing configuration from ${ENV_FILE}..."
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# Fallback interactive inputs if not predefined
if [ -t 0 ] && [ ! -f "${ENV_FILE}" ]; then
  read -r -p "Enter Node / Tailscale Hostname [default: $(hostname)]: " INPUT_NAME
  TS_HOSTNAME="${INPUT_NAME:-$(hostname)}"

  read -r -p "Enter Tailscale Auth Key (optional, press ENTER to authenticate via URL): " TS_AUTHKEY

  read -r -p "Enter Master Node Tailscale IP [e.g. 100.x.y.z]: " MASTER_TAILSCALE_IP

  read -r -p "Enter Arcane Agent Token (from Arcane UI -> Add Node): " ARCANE_AGENT_TOKEN

  read -r -p "Enter Docker Swarm Worker Join Token (optional, press ENTER to skip): " SWARM_WORKER_TOKEN

  read -r -p "Enter Weekly Maintenance Day (e.g. Sun, Mon) [default: Sun]: " INPUT_DAY
  UPDATE_DAY="${INPUT_DAY:-Sun}"

  read -r -p "Enter Weekly Maintenance Time (HH:MM) [default: 04:00]: " INPUT_TIME
  UPDATE_TIME="${INPUT_TIME:-04:00}"
else
  TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
  TS_AUTHKEY="${TS_AUTHKEY:-}"
  MASTER_TAILSCALE_IP="${MASTER_TAILSCALE_IP:-}"
  ARCANE_AGENT_TOKEN="${ARCANE_AGENT_TOKEN:-}"
  SWARM_WORKER_TOKEN="${SWARM_WORKER_TOKEN:-}"
  UPDATE_DAY="${UPDATE_DAY:-Sun}"
  UPDATE_TIME="${UPDATE_TIME:-04:00}"
fi

# Write/Update worker .env
cat << EOF > "${ENV_FILE}"
NODE_NAME=${TS_HOSTNAME}
TS_HOSTNAME=${TS_HOSTNAME}
TS_AUTHKEY=${TS_AUTHKEY}
TS_EXTRA_ARGS=--reset
MASTER_TAILSCALE_IP=${MASTER_TAILSCALE_IP}
ARCANE_SERVER_URL=http://${MASTER_TAILSCALE_IP}:3552
ARCANE_AGENT_TOKEN=${ARCANE_AGENT_TOKEN}
ARCANE_AGENT_NAME=${TS_HOSTNAME}
SWARM_WORKER_TOKEN=${SWARM_WORKER_TOKEN}
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
# 4. Install & Harden Firewalld (Worker: Port 22 SSH only + trusted tailscale0)
# ------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/common/05-configure-firewalld.sh" "worker"

# ------------------------------------------------------------------------------
# 5. Apply Deep Storage & Disk I/O Optimizations (Udev, Sysctl, ZFS, RAM-Disk)
# ------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/common/06-storage-optimizations.sh"

# ------------------------------------------------------------------------------
# 6. Install & Harden Docker CE ("iptables": false)
# ------------------------------------------------------------------------------
bash "${SCRIPT_DIR}/common/04-install-docker.sh"

# Ensure local shared bridge network exists on worker
SHARED_NETWORK="${SHARED_NETWORK:-shared_net}"
if ! docker network ls --format '{{.Name}}' | grep -q "^${SHARED_NETWORK}$"; then
  echo "Creating shared bridge network '${SHARED_NETWORK}'..."
  docker network create "${SHARED_NETWORK}" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 7. Deploy Worker Compose Stack (Tailscale + Arcane Agent)
# ------------------------------------------------------------------------------
echo "===> [Worker Stack] Launching Tailscale & Arcane Agent..."
cd "${WORKER_DIR}"
docker compose up -d --remove-orphans

# Check for Tailscale Authentication
echo "Waiting for Tailscale interface initialization..."
sleep 5

WORKER_TS_IP=""
for i in {1..12}; do
  WORKER_TS_IP="$(docker exec tailscale tailscale ip -4 2>/dev/null || true)"
  if [ -n "${WORKER_TS_IP}" ]; then
    break
  fi
  echo "Checking Tailscale status ($i/12)..."
  sleep 3
done

if [ -z "${WORKER_TS_IP}" ]; then
  echo ""
  echo "⚠️ Tailscale is running but requires interactive login."
  echo "👉 Run: docker exec -it tailscale tailscale up"
  echo "Follow the displayed URL to authenticate this Worker node to your Tailscale network."
  echo ""
  read -r -p "Press [ENTER] once Tailscale authentication is complete to continue..."
  WORKER_TS_IP="$(docker exec tailscale tailscale ip -4 2>/dev/null || echo '127.0.0.1')"
fi

# ------------------------------------------------------------------------------
# 8. Join Docker Swarm Cluster (Binding to Tailscale Mesh IP)
# ------------------------------------------------------------------------------
echo "===> [Docker Swarm] Checking Swarm Cluster Status..."
SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo 'inactive')"

if [ "$SWARM_STATE" = "inactive" ] && [ -n "${SWARM_WORKER_TOKEN}" ] && [ -n "${MASTER_TAILSCALE_IP}" ]; then
  echo "Joining Docker Swarm cluster at ${MASTER_TAILSCALE_IP}:2377..."
  if [ -n "$WORKER_TS_IP" ] && [ "$WORKER_TS_IP" != "127.0.0.1" ]; then
    docker swarm join \
      --token "${SWARM_WORKER_TOKEN}" \
      --advertise-addr "${WORKER_TS_IP}" \
      --data-path-addr "${WORKER_TS_IP}" \
      "${MASTER_TAILSCALE_IP}:2377" || true
  else
    docker swarm join \
      --token "${SWARM_WORKER_TOKEN}" \
      "${MASTER_TAILSCALE_IP}:2377" || true
  fi
elif [ "$SWARM_STATE" = "active" ]; then
  echo "Docker Swarm is already active on this node."
else
  echo "Swarm token not provided. You can join the Swarm later with:"
  echo "  sudo docker swarm join --token <TOKEN> --advertise-addr ${WORKER_TS_IP} --data-path-addr ${WORKER_TS_IP} ${MASTER_TAILSCALE_IP:-<MASTER_TS_IP>}:2377"
fi

# ------------------------------------------------------------------------------
# 9. Completion Summary & Auditing
# ------------------------------------------------------------------------------
echo ""
echo "===================================================================="
echo "🎉 DEEPLY OPTIMIZED WORKER NODE SETUP COMPLETED SUCCESSFULLY!"
echo "===================================================================="
echo " 🌐 Tailscale Mesh IP:     ${WORKER_TS_IP}"
echo " 🤖 Arcane Agent:          Connected to http://${MASTER_TAILSCALE_IP:-<MASTER_IP>}:3552"
echo " 💾 RAM-Disk (/mnt/ramdisk): Active ($(df -h /mnt/ramdisk | tail -1 | awk '{print $2, "allocated"}'))"
echo ""
echo " 🛡️ Firewall Security:"
echo "   • Public Ports: 22 (SSH ONLY - all web/internal ports blocked)"
echo "   • Tailscale Mesh: 100% Trusted for inter-node communication"
echo ""
echo " ⚡ Applied I/O Optimizations:"
echo "   • Block Queue: scheduler=none, read_ahead=128KB, rq_affinity=2"
echo "   • Kernel Storage: vm.dirty_bytes=64MB, vm.vfs_cache_pressure=50"
echo "   • RAM-Disk: /mnt/ramdisk mounted for ephemeral workloads"
echo ""
echo " 🔍 To audit this host configuration at any time, run:"
echo "    sudo ./audit-node.sh --role worker --deep"
echo "===================================================================="
