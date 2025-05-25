#!/bin/bash
#
# /tmp Maintenance Script
# Version: 2.4
# Author: Eren Kesdi
# Description: Checks/repairs /tmp filesystem with service awareness
# Last Updated: 25-05-2025

set -euo pipefail

# === 1. Initialization ===
SCRIPT_VERSION="2.4"
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
SECONDS=0

# === 2. Permission and Dependency Checks ===
[ "$(id -u)" -ne 0 ] && { echo "Root privileges required!" >&2; exit 1; }

required_commands=(lsof fsck fuser mountpoint timeout tee blockdev)
for cmd in "${required_commands[@]}"; do
    command -v "$cmd" >/dev/null || { echo "$cmd not found. Please install it." >&2; exit 1; }
done

# === 3. Signal Handling ===
trap 'script_interrupted' INT TERM

script_interrupted() {
    echo "[TRAP] Script interrupted. Attempting cleanup..."
    cleanup_and_exit 2
}

# === 4. Logging Setup ===
LOG_DIR="/var/log/tmp_maintenance"
mkdir -p "$LOG_DIR" || { echo "Cannot create log directory!" >&2; exit 1; }
LOG_FILE="$LOG_DIR/tmp_maintenance_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1

echo "==== Starting /tmp maintenance v$SCRIPT_VERSION (commit: $GIT_HASH) ===="
echo "Process ID: $$"
echo "Log file: $LOG_FILE"
echo "Start time: $(date)"

# === 5. User Confirmation ===
echo "WARNING: This script will stop services using /tmp temporarily."
echo "Ensure you have proper backups before proceeding!"
read -p "Continue? (y/N) " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

# === 6. Service Management ===
SERVICES=(nginx apache2 php-fpm mysql redis postgresql mongod docker \
          cassandra elasticsearch rabbitmq-server)

declare -A SERVICE_STATUS

# === Functions ===

cleanup_and_exit() {
    local exit_code=${1:-0}
    echo "[CLEANUP] Restarting necessary services..."
    
    for svc in "${SERVICES[@]}"; do
        if [ "${SERVICE_STATUS[$svc]:-}" = "active" ]; then
            echo "[RESTARTING] $svc..."
            if ! timeout 30s systemctl start "$svc"; then
                echo "[WARNING] Failed to restart $svc normally. Attempting recovery..."
                systemctl reset-failed "$svc"
                systemctl start "$svc" || \
                    echo "[ERROR] Recovery failed for $svc. Manual intervention needed."
            fi
        fi
    done
    
    echo "[RESOURCES] Final memory usage: $(free -h | awk '/Mem:/{print $3"/"$2}')"
    echo "[TIME] Script ran for $((SECONDS/60))m $((SECONDS%60))s"
    echo "[EXIT] Script completed with code $exit_code at $(date)"
    exit "$exit_code"
}

# === 7. Service Status Check ===
echo "[STATUS] Checking service states..."
for svc in "${SERVICES[@]}"; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        if systemctl is-active --quiet "$svc"; then
            SERVICE_STATUS["$svc"]="active"
            echo "[STATUS] $svc: ACTIVE (enabled)"
        else
            SERVICE_STATUS["$svc"]="inactive"
            echo "[STATUS] $svc: INACTIVE (enabled)"
        fi
    else
        SERVICE_STATUS["$svc"]="disabled"
        echo "[STATUS] $svc: DISABLED"
    fi
done

# === 8. Service Stopping ===
echo "[ACTION] Stopping services in reverse dependency order..."
for ((i=${#SERVICES[@]}-1; i>=0; i--)); do
    svc="${SERVICES[$i]}"
    if [ "${SERVICE_STATUS[$svc]}" = "active" ]; then
        echo "[STOPPING] $svc..."
        if ! timeout 30s systemctl stop "$svc"; then
            echo "[WARNING] Graceful stop failed. Force stopping $svc..."
            systemctl kill -s SIGKILL "$svc" || \
                echo "[ERROR] Could not stop $svc. Continuing anyway."
        fi
    fi
done

# === 9. /tmp Filesystem Analysis ===
TMP_DEVICE=$(findmnt -n -o SOURCE /tmp)
TMP_FSTYPE=$(findmnt -n -o FSTYPE /tmp)
TMP_OPTIONS=$(findmnt -n -o OPTIONS /tmp)

if [ -z "$TMP_DEVICE" ]; then
    echo "[INFO] /tmp is not a separate mount point. Skipping fsck."
    cleanup_and_exit 0
fi

echo "[INFO] /tmp mounted from: $TMP_DEVICE"
echo "[INFO] Filesystem type: $TMP_FSTYPE"
echo "[INFO] Mount options: $TMP_OPTIONS"

# Check filesystem size
FS_SIZE=$(blockdev --getsize64 "$TMP_DEVICE" 2>/dev/null || echo "unknown")
echo "[INFO] Filesystem size: $([ "$FS_SIZE" != "unknown" ] && numfmt --to=iec "$FS_SIZE" || echo "$FS_SIZE")"

if [[ "$TMP_FSTYPE" == "tmpfs" ]]; then
    echo "[INFO] tmpfs detected. Skipping fsck."
    cleanup_and_exit 0
fi

# === 10. Unmount Procedure ===
echo "[ACTION] Unmounting /tmp..."
if ! umount /tmp; then
    echo "[WARNING] Normal unmount failed. Checking for open files..."
    lsof +D /tmp || true
    
    echo "[ACTION] Terminating processes using /tmp..."
    while IFS= read -r pid; do
        [ -d "/proc/$pid" ] && kill -TERM "$pid" && sleep 1
    done < <(lsof -t /tmp 2>/dev/null)
    
    sleep 3
    echo "[FORCE] Final unmount attempt..."
    umount -f /tmp || {
        echo "[CRITICAL] Cannot unmount /tmp. System may need reboot."
        cleanup_and_exit 1
    }
fi

# === 11. Filesystem Check ===
echo "[ACTION] Checking filesystem..."
FS_OPTS="-f -y -C -T"
[[ "$TMP_FSTYPE" == "ext4" ]] && FS_OPTS="$FS_OPTS -E threaded"

fsck $FS_OPTS "$TMP_DEVICE"
FSCK_RC=$?

case $FSCK_RC in
    0) echo "[FSCK] Filesystem is clean" ;;
    1) echo "[FSCK] Errors were corrected" ;;
    2) echo "[FSCK] System should be rebooted" ;;
    *) echo "[FSCK] Critical error (code $FSCK_RC)"; cleanup_and_exit 1 ;;
esac

# === 12. Remounting ===
echo "[ACTION] Preparing to remount /tmp..."
MNT_OPTS="defaults"

# Filesystem-specific options
case "$TMP_FSTYPE" in
    ext4) MNT_OPTS="$MNT_OPTS,data=writeback,barrier=0" ;;
    xfs)  MNT_OPTS="$MNT_OPTS,nobarrier" ;;
esac

# Preserve original options
[[ "$TMP_DEVICE" == /dev/loop* ]] && MNT_OPTS="$MNT_OPTS,loop"
[[ "$TMP_OPTIONS" == *noexec* ]] && MNT_OPTS="$MNT_OPTS,noexec"
[[ "$TMP_OPTIONS" == *nosuid* ]] && MNT_OPTS="$MNT_OPTS,nosuid"
[[ "$TMP_OPTIONS" == *nodev* ]]  && MNT_OPTS="$MNT_OPTS,nodev"

echo "[INFO] Using mount options: $MNT_OPTS"

mount -o "$MNT_OPTS" -t "$TMP_FSTYPE" "$TMP_DEVICE" /tmp || {
    echo "[FALLBACK] Primary mount failed. Attempting tmpfs fallback..."
    mount -t tmpfs -o size=1G,nr_inodes=10k,mode=1777 tmpfs /tmp || {
        echo "[CRITICAL] Cannot mount /tmp. System may be unstable."
        cleanup_and_exit 1
    }
    echo "[WARNING] /tmp is now using tmpfs. Original filesystem not mounted."
}

# === 13. Security Hardening ===
echo "[SECURITY] Applying /tmp permissions..."
chmod 1777 /tmp
find /tmp -xdev -type d ! -perm 1777 -exec chmod 1777 {} + 2>/dev/null
find /tmp -xdev -type f ! -perm 644 -exec chmod 644 {} + 2>/dev/null

# === 14. Service Restoration ===
echo "[ACTION] Restarting services..."
FAILED_SERVICES=0

for svc in "${SERVICES[@]}"; do
    if [ "${SERVICE_STATUS[$svc]}" = "active" ]; then
        echo "[STARTING] $svc..."
        
        if ! timeout 45s systemctl start "$svc"; then
            echo "[WARNING] Normal start failed. Attempting recovery..."
            systemctl reset-failed "$svc"
            systemctl start "$svc" || {
                echo "[ERROR] Failed to start $svc"
                [[ $svc =~ ^(nginx|apache|mysql|redis)$ ]] && ((FAILED_SERVICES++))
            }
        fi
        
        sleep 2
        if systemctl is-active --quiet "$svc"; then
            echo "[STATUS] $svc started successfully"
        else
            echo "[WARNING] $svc is not active after start attempt"
        fi
    fi
done

# === 15. Final Checks ===
echo "[VERIFICATION] Checking system status..."
mountpoint -q /tmp || { echo "[ERROR] /tmp not mounted!"; cleanup_and_exit 1; }

# Critical services check
CRITICAL_SERVICES=(nginx apache2 mysql redis)
for svc in "${CRITICAL_SERVICES[@]}"; do
    if [ "${SERVICE_STATUS[$svc]:-}" = "active" ] && \
       ! systemctl is-active --quiet "$svc"; then
        echo "[CRITICAL] $svc failed to start!"
        ((FAILED_SERVICES++))
    fi
done

# === 16. Cleanup and Exit ===
echo "[HOUSEKEEPING] Removing old logs..."
find "$LOG_DIR" -name "tmp_maintenance_*.log" -mtime +30 -delete

if [ "$FAILED_SERVICES" -eq 0 ]; then
    echo "==== Maintenance completed successfully ===="
    echo "[SUMMARY] All operations completed"
    echo "[NOTE] Check full log at: $LOG_FILE"
    cleanup_and_exit 0
else
    echo "==== Maintenance completed with ERRORS ====" >&2
    echo "[ERROR] $FAILED_SERVICES critical services failed to start" >&2
    echo "[ACTION REQUIRED] Check system status:" >&2
    echo "  1. systemctl --failed" >&2
    echo "  2. journalctl -xe" >&2
    echo "  3. Log file: $LOG_FILE" >&2
    cleanup_and_exit 1
fi
