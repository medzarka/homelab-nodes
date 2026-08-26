#!/usr/bin/env bash
# ==============================================================================
# Homelab Node Framework — Advanced Storage & Disk I/O Performance Tuner
# ==============================================================================
# Implements persistent hardware, kernel, ZFS, and RAM-disk optimizations:
# 1. Block layer queue tuning (none scheduler, 128KB read-ahead, rq_affinity=2)
# 2. Kernel storage anti-freeze sysctl (dirty_bytes cap, vfs_cache_pressure=50, swappiness=1)
# 3. ZFS trickle-write rate limiter (if ZFS kernel module / pool present)
# 4. Ephemeral RAM-disk (/mnt/ramdisk) configuration in /etc/fstab
# Based on production benchmarks from homelab-srv/README.md
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/01-detect-os.sh"

ensure_root

echo "===> [Storage Optimization] Applying Deep Disk & I/O Performance Hardening..."

# ------------------------------------------------------------------------------
# 1. Block Layer Queue & I/O Scheduler Tuning (Persistent via Udev)
# ------------------------------------------------------------------------------
echo "Configuring block device queue parameters via Udev..."
UDEV_RULE_FILE="/etc/udev/rules.d/60-homelab-ioscheduler.rules"

cat << 'EOF' > "${UDEV_RULE_FILE}"
# Homelab high-throughput block queue rules (SATA, NVMe, VirtIO)
ACTION=="add|change", KERNEL=="sd[a-z]|nvme[0-9]n[0-9]|vd[a-z]", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="64", ATTR{queue/read_ahead_kb}="128", ATTR{queue/rq_affinity}="2"
EOF

# Reload and apply udev rules immediately
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --type=devices --action=change 2>/dev/null || true

# Apply immediately to all existing block devices
for disk_path in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
  if [ -d "$disk_path" ]; then
    disk_name="$(basename "$disk_path")"
    echo "  -> Tuning /dev/${disk_name}..."
    [ -f "${disk_path}/queue/scheduler" ] && echo "none" > "${disk_path}/queue/scheduler" 2>/dev/null || true
    [ -f "${disk_path}/queue/read_ahead_kb" ] && echo "128" > "${disk_path}/queue/read_ahead_kb" 2>/dev/null || true
    [ -f "${disk_path}/queue/rq_affinity" ] && echo "2" > "${disk_path}/queue/rq_affinity" 2>/dev/null || true
    [ -f "${disk_path}/queue/nr_requests" ] && echo "64" > "${disk_path}/queue/nr_requests" 2>/dev/null || true
  fi
done

# ------------------------------------------------------------------------------
# 2. Kernel Storage Anti-Freeze & VFS Cache Parameters (Sysctl)
# ------------------------------------------------------------------------------
echo "Configuring kernel storage anti-freeze parameters..."
SYSCTL_FILE="/etc/sysctl.d/99-storage-anti-freeze.conf"

cat << 'EOF' > "${SYSCTL_FILE}"
# Retain directory dentries and inode metadata in RAM (prevents I/O stalls)
vm.vfs_cache_pressure = 50

# Cap global dirty page buffers to 64MB / 32MB to protect controller cache & flash
vm.dirty_background_bytes = 33554432
vm.dirty_bytes = 67108864
vm.dirty_writeback_centisecs = 200
vm.dirty_expire_centisecs = 500

# Minimize swapping of active container memory
vm.swappiness = 1
EOF

# Apply sysctl settings
sysctl -p "${SYSCTL_FILE}" >/dev/null

# ------------------------------------------------------------------------------
# 3. ZFS Kernel Module "Trickle-Write" Tuning (If ZFS is present)
# ------------------------------------------------------------------------------
if command -v zfs &>/dev/null || [ -d /sys/module/zfs ]; then
  echo "ZFS detected. Configuring ZFS trickle-write rate limiter..."
  
  ZFS_MOD_FILE="/etc/modprobe.d/zfs.conf"
  cat << 'EOF' > "${ZFS_MOD_FILE}"
# --- ZFS Trickle-Write Rate Limiter (64MB / 5s) ---
options zfs zfs_dirty_data_max=67108864
options zfs zfs_txg_timeout=5
options zfs zfs_vdev_async_write_max_active=2
options zfs zfs_vdev_sync_write_max_active=2
options zfs zfs_prefetch_disable=1
EOF

  # Update initramfs if tool exists
  if command -v update-initramfs &>/dev/null; then
    echo "Updating initramfs for ZFS persistence..."
    update-initramfs -u -k all 2>/dev/null || true
  elif command -v dracut &>/dev/null; then
    echo "Updating dracut for ZFS persistence..."
    dracut -f 2>/dev/null || true
  fi

  # Apply dataset optimizations to active pools if available
  if zpool list -H -o name &>/dev/null; then
    for pool in $(zpool list -H -o name 2>/dev/null); do
      echo "Optimizing ZFS pool '${pool}' dataset properties..."
      zfs set compression=lz4 "${pool}" 2>/dev/null || true
      zfs set atime=off "${pool}" 2>/dev/null || true
      zfs set relatime=off "${pool}" 2>/dev/null || true
      zfs set xattr=sa "${pool}" 2>/dev/null || true
      zfs set primarycache=all "${pool}" 2>/dev/null || true
    done
  fi
fi

# ------------------------------------------------------------------------------
# 4. Ephemeral RAM-Disk Setup (/mnt/ramdisk)
# ------------------------------------------------------------------------------
echo "Configuring high-speed ephemeral RAM-disk (/mnt/ramdisk)..."
TOTAL_RAM_KB="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

# Determine appropriate RAM-disk size
if [ "$TOTAL_RAM_GB" -ge 48 ]; then
  RAMDISK_SIZE="24G"
elif [ "$TOTAL_RAM_GB" -ge 24 ]; then
  RAMDISK_SIZE="12G"
elif [ "$TOTAL_RAM_GB" -ge 12 ]; then
  RAMDISK_SIZE="6G"
else
  RAMDISK_SIZE="2G"
fi

mkdir -p /mnt/ramdisk

# Ensure /etc/fstab entry exists
if ! grep -q "[[:space:]]/mnt/ramdisk[[:space:]]" /etc/fstab; then
  echo "Adding /mnt/ramdisk (size=${RAMDISK_SIZE}) to /etc/fstab..."
  echo "tmpfs  /mnt/ramdisk  tmpfs  rw,nosuid,nodev,noatime,size=${RAMDISK_SIZE},mode=1777  0  0" >> /etc/fstab
fi

# Mount ramdisk if not mounted
if ! mountpoint -q /mnt/ramdisk; then
  mount /mnt/ramdisk 2>/dev/null || mount -a
fi

chmod 1777 /mnt/ramdisk

echo "✅ [Storage Optimization] Applied successfully!"
echo "   • RAM-Disk: $(df -h /mnt/ramdisk | tail -1 | awk '{print $2, "total,", $4, "available"}')"
echo "   • Sysctl:   vfs_cache_pressure=$(sysctl -n vm.vfs_cache_pressure), dirty_bytes=$(sysctl -n vm.dirty_bytes)"
