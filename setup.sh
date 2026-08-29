#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Unified Multi-Node Cluster Orchestrator (setup.sh)
# ==============================================================================
# Main entry point for initializing any node in the Homelab Sovereign Cluster.
# Dynamically detects the NODE_ROLE (MASTER or WORKER) from .env or interactive
# prompt, bootstraps system hardening, installs Docker, configures Tailscale mesh,
# and deploys the appropriate Docker Compose stack (Arcane Manager or Agent).
# ==============================================================================

set -euo pipefail

# Terminal formatting constants
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/01-detect-os.sh"

ensure_root

echo "===================================================================="
echo "          🌐 HOMELAB SOVEREIGN CLUSTER NODE BOOTSTRAPPER            "
echo "===================================================================="
print_system_info

# ------------------------------------------------------------------------------
# 1. Load Environment Configuration
# ------------------------------------------------------------------------------
ROOT_ENV="${SCRIPT_DIR}/.env"
WORKER_JOIN_ENV="${SCRIPT_DIR}/worker-join.env"

if [ -f "${ROOT_ENV}" ]; then
  echo "Loading configuration from ${ROOT_ENV}..."
  # shellcheck disable=SC1090
  source "${ROOT_ENV}"
elif [ -f "${WORKER_JOIN_ENV}" ]; then
  echo "Loading master-generated configuration from ${WORKER_JOIN_ENV}..."
  # shellcheck disable=SC1090
  source "${WORKER_JOIN_ENV}"
fi

# ------------------------------------------------------------------------------
# 2. Determine and Normalize NODE_ROLE
# ------------------------------------------------------------------------------
ROLE="${NODE_ROLE:-}"

if [ -z "${ROLE}" ]; then
  if [ -t 0 ]; then
    echo ""
    echo -e "${BOLD}Please select the role for this node:${NC}"
    echo "  1) MASTER                 - Primary Cloud VPS / Swarm Leader / Arcane Cockpit Manager"
    echo "  2) WORKER                 - Standard Compute / Edge Node / Arcane Agent"
    echo "  3) WORKER_DEEPER_OPTIMIZED- High-I/O Compute Node with deep disk/RAM-disk optimizations"
    echo ""
    read -r -p "Enter choice [1-3, default: 1]: " ROLE_CHOICE
    case "${ROLE_CHOICE:-1}" in
      1|master|MASTER)
        ROLE="MASTER"
        ;;
      2|worker|WORKER)
        ROLE="WORKER"
        ;;
      3|deeper|optimized|WORKER_DEEPER_OPTIMIZED)
        ROLE="WORKER_DEEPER_OPTIMIZED"
        ;;
      *)
        echo "⚠️ Invalid choice. Defaulting to MASTER."
        ROLE="MASTER"
        ;;
    esac
  else
    echo "ℹ️ No NODE_ROLE specified in non-interactive mode. Defaulting to MASTER."
    ROLE="MASTER"
  fi
fi

# Normalize role string (uppercase, convert hyphens to underscores)
ROLE_NORMALIZED="$(echo "${ROLE}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

echo ""
echo -e ">>> Target Node Role: ${BOLD}${ROLE_NORMALIZED}${NC}"
echo "--------------------------------------------------------------------"

# ------------------------------------------------------------------------------
# 3. Dispatch to Target Node Setup Script
# ------------------------------------------------------------------------------
case "${ROLE_NORMALIZED}" in
  MASTER)
    echo "===> [Role: MASTER] Initiating Master Leader & Arcane Manager setup..."
    bash "${SCRIPT_DIR}/setup-master.sh"
    ;;
  WORKER)
    echo "===> [Role: WORKER] Initiating Worker Node & Arcane Agent setup..."
    bash "${SCRIPT_DIR}/setup-worker.sh"
    ;;
  WORKER_DEEPER_OPTIMIZED|WORKER_OPTIMIZED|DEEPER)
    echo "===> [Role: WORKER_DEEPER_OPTIMIZED] Initiating High-I/O Optimized Worker setup..."
    bash "${SCRIPT_DIR}/setup-worker-deeper-optimized.sh"
    ;;
  *)
    echo -e "\033[0;31m[ERROR]\033[0m Unknown NODE_ROLE '${ROLE_NORMALIZED}'!"
    echo "Supported roles: MASTER, WORKER, WORKER_DEEPER_OPTIMIZED"
    exit 1
    ;;
esac

# ------------------------------------------------------------------------------
# 4. Post-Setup Health & Security Audit Recommendation
# ------------------------------------------------------------------------------
echo ""
echo "===================================================================="
echo "          🎉 NODE SETUP & CONTAINER DEPLOYMENT COMPLETE!             "
echo "===================================================================="
echo "To verify and audit your node configuration, firewall, and services, run:"
echo "👉  sudo bash ${SCRIPT_DIR}/audit-node.sh"
echo "===================================================================="
