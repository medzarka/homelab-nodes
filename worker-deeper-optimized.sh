#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Worker Deeper Optimized Wrapper
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/setup-worker-deeper-optimized.sh" "$@"
