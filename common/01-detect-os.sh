#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — OS & Architecture Detection Module
# ==============================================================================
# Supports: Ubuntu, Debian, Oracle Linux 9/10, RHEL, Rocky, AlmaLinux
# Architectures: x86_64 (amd64), aarch64 (arm64)
# ==============================================================================

set -euo pipefail

# Ensure running with superuser privileges
ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "❌ Error: This script must be executed as root (or via sudo)." >&2
    exit 1
  fi
}

# Detect and normalize OS and architecture
detect_system() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_NAME="${NAME:-Linux}"
  else
    echo "❌ Error: Cannot detect operating system (/etc/os-release missing)." >&2
    exit 1
  fi

  # Determine family
  if [[ "$OS_ID" =~ ^(ubuntu|debian|raspbian)$ ]] || [[ "$OS_ID_LIKE" =~ (ubuntu|debian) ]]; then
    OS_FAMILY="debian_like"
    PKG_MGR="apt-get"
  elif [[ "$OS_ID" =~ ^(ol|rhel|centos|rocky|almalinux|fedora)$ ]] || [[ "$OS_ID_LIKE" =~ (rhel|centos|fedora) ]]; then
    OS_FAMILY="rhel_like"
    PKG_MGR="dnf"
  else
    echo "⚠️ Warning: Unknown OS ID '$OS_ID'. Defaulting to best-effort detection." >&2
    if command -v dnf &>/dev/null; then
      OS_FAMILY="rhel_like"
      PKG_MGR="dnf"
    elif command -v apt-get &>/dev/null; then
      OS_FAMILY="debian_like"
      PKG_MGR="apt-get"
    else
      echo "❌ Error: Unsupported package manager. Neither apt-get nor dnf found." >&2
      exit 1
    fi
  fi

  # Detect CPU Architecture
  RAW_ARCH="$(uname -m)"
  case "$RAW_ARCH" in
    x86_64|amd64)
      ARCH="amd64"
      RPM_ARCH="x86_64"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      RPM_ARCH="aarch64"
      ;;
    armv7l|armhf)
      ARCH="armhf"
      RPM_ARCH="armhfp"
      ;;
    *)
      ARCH="$RAW_ARCH"
      RPM_ARCH="$RAW_ARCH"
      ;;
  esac

  export OS_ID OS_ID_LIKE OS_VERSION_ID OS_NAME OS_FAMILY PKG_MGR ARCH RPM_ARCH
}

# Helper print summary
print_system_info() {
  detect_system
  echo "--------------------------------------------------------"
  echo " 🖥️ System Summary:"
  echo "   • OS Name:      ${OS_NAME} (${OS_ID} ${OS_VERSION_ID})"
  echo "   • Family:       ${OS_FAMILY}"
  echo "   • Architecture: ${ARCH} (${RAW_ARCH})"
  echo "   • Package Mgr:  ${PKG_MGR}"
  echo "--------------------------------------------------------"
}

# Run detection when sourced or executed
detect_system
