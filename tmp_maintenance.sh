#!/bin/bash
#
# /tmp Maintenance Script
# Version: 2.3
# Author: Eren Kesdi
# Description: Checks/repairs /tmp filesystem with service awareness
# Last Updated: 25-05-2025

set -euo pipefail

# === 1. Yetki ve bağımlılık kontrolü ===
[ "$(id -u)" -ne 0 ] && { echo "Root privileges required!" >&2; exit 1; }
for cmd in lsof fsck fuser mountpoint timeout tee; do
    command -v "$cmd" >/dev/null || { echo "$cmd not found. Please install it." >&2; exit 1; }
done

# === 2. Kesme sinyalleri yakalama ===
trap 'echo "[TRAP] Script interrupted. Attempting cleanup..."; cleanup_and_exit 2' INT TERM

# === 3. Log dosyası ===
LOG_DIR="/var/log/tmp_maintenance"
mkdir -p "$LOG_DIR" || { echo "Cannot create log directory!" >&2; exit 1; }
LOG_FILE="$LOG_DIR/tmp_maintenance_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1

# === 4. Kullanıcı onayı ===
echo "WARNING: This script will stop services using /tmp temporarily."
echo "Ensure you have proper backups before proceeding!"
read -p "Continue? (y/N) " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 1

echo "==== Starting /tmp maintenance ===="
echo "Process ID: $$"
echo "Log file: $LOG_FILE"

# === 5. Servis listesi ===
SERVICES=(nginx apache2 php-fpm mysql redis postgresql mongod docker \
          cassandra elasticsearch rabbitmq-server)

declare -A SERVICE_STATUS

# === Fonksiyonlar ===

cleanup_and_exit() {
    local code=${1:-0}
    echo "[CLEANUP] Restarting necessary services before exiting..."
    for svc in "${SERVICES[@]}"; do
        if [ "${SERVICE_STATUS[$svc]:-}" = "active" ]; then
            systemctl start "$svc" || echo "[RECOVERY] Failed to restart $svc during cleanup."
        fi
    done
    echo "[EXIT] Script exited with code $code"
    exit "$code"
}

# === 6. Servis durumlarını kaydet ===
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

# === 7. Servisleri durdur ===
echo "[STEP] Stopping services..."
for ((i=${#SERVICES[@]}-1; i>=0; i--)); do
    svc="${SERVICES[$i]}"
    if [ "${SERVICE_STATUS[$svc]}" = "active" ]; then
        echo "[STOPPING] $svc..."
        if ! timeout 30s systemctl stop "$svc"; then
            echo "[WARNING] Graceful stop failed. Sending SIGKILL to $svc"
            systemctl kill -s SIGKILL "$svc"
        fi
    fi
done

# === 8. /tmp mount kontrolü ===
TMP_DEVICE=$(findmnt -n -o SOURCE /tmp)
TMP_FSTYPE=$(findmnt -n -o FSTYPE /tmp)
TMP_OPTIONS=$(findmnt -n -o OPTIONS /tmp)

if [ -z "$TMP_DEVICE" ]; then
    echo "[INFO] /tmp is not a separate mount point. Skipping fsck."
    cleanup_and_exit 0
fi

echo "[INFO] /tmp mounted from $TMP_DEVICE as $TMP_FSTYPE with options: $TMP_OPTIONS"

if [[ "$TMP_FSTYPE" == "tmpfs" ]]; then
    echo "[INFO] tmpfs detected. Skipping fsck."
    cleanup_and_exit 0
fi

# === 9. Unmount işlemi ===
echo "[STEP] Attempting to unmount /tmp..."
if ! umount /tmp; then
    echo "[WARNING] Normal unmount failed. Checking for open files..."
    lsof +D /tmp || true
    echo "[INFO] Attempting to terminate processes using /tmp..."
    fuser -km /tmp || pkill -f /tmp
    sleep 5
    echo "[FORCE] Final unmount attempt..."
    umount -f /tmp || {
        echo "[ERROR] Cannot unmount /tmp. Reboot might be required."
        cleanup_and_exit 1
    }
fi

# === 10. Dosya sistemi kontrolü ===
echo "[STEP] Running fsck on $TMP_DEVICE..."
fsck -f -y -C -T "$TMP_DEVICE"
FSCK_RC=$?

case $FSCK_RC in
    0) echo "[FSCK] Clean filesystem" ;;
    1) echo "[FSCK] Errors corrected" ;;
    2) echo "[FSCK] Reboot recommended" ;;
    4|8|16) echo "[FSCK] Critical error ($FSCK_RC). Aborting..." >&2; cleanup_and_exit 1 ;;
    *) echo "[FSCK] Unknown return code $FSCK_RC. Aborting..." >&2; cleanup_and_exit 1 ;;
esac

# === 11. Mount işlemi ===
echo "[STEP] Remounting /tmp..."
MNT_OPTS="defaults"

[[ "$TMP_FSTYPE" == "ext4" ]] && MNT_OPTS="$MNT_OPTS,data=writeback,barrier=0"
[[ "$TMP_FSTYPE" == "xfs" ]]  && MNT_OPTS="$MNT_OPTS,nobarrier"

[[ "$TMP_DEVICE" == /dev/loop* ]] && MNT_OPTS="$MNT_OPTS,loop"
[[ "$TMP_OPTIONS" == *noexec* ]] && MNT_OPTS="$MNT_OPTS,noexec"
[[ "$TMP_OPTIONS" == *nosuid* ]] && MNT_OPTS="$MNT_OPTS,nosuid"
[[ "$TMP_OPTIONS" == *nodev* ]]  && MNT_OPTS="$MNT_OPTS,nodev"

mount -o "$MNT_OPTS" -t "$TMP_FSTYPE" "$TMP_DEVICE" /tmp || {
    echo "[FALLBACK] Mount failed. Trying tmpfs fallback..."
    mount -t tmpfs -o size=1G,nr_inodes=10k,mode=1777 tmpfs /tmp || {
        echo "[CRITICAL] Cannot mount /tmp. System may be unstable." >&2
        cleanup_and_exit 1
    }
}

mountpoint -q /tmp && echo "[SUCCESS] /tmp is mounted" || { echo "[ERROR] Mount verification failed!" >&2; cleanup_and_exit 1; }

# === 12. Servisleri başlat ===
echo "[STEP] Restarting services..."
for svc in "${SERVICES[@]}"; do
    if [ "${SERVICE_STATUS[$svc]}" = "active" ]; then
        echo "[STARTING] $svc..."
        timeout 45s systemctl start "$svc" || {
            echo "[WARNING] Restart failed for $svc. Retrying after reset-failed..."
            systemctl reset-failed "$svc"
            systemctl start "$svc" || echo "[ERROR] Failed to start $svc"
        }
        sleep 2
        systemctl is-active --quiet "$svc" && echo "[STATUS] $svc is running" || echo "[WARNING] $svc failed to reach active state"
    fi
done

# === 13. Kritik servis kontrolü ===
echo "[CHECK] Verifying critical services..."
FAILED=0
for svc in nginx apache2 mysql redis; do
    if [ "${SERVICE_STATUS[$svc]}" = "active" ] && ! systemctl is-active --quiet "$svc"; then
        echo "[CRITICAL] $svc is not running!" >&2
        ((FAILED++))
    fi
done

# === 14. Log temizliği ===
find "$LOG_DIR" -name "tmp_maintenance_*.log" -mtime +30 -delete

# === 15. Özet ===
if [ "$FAILED" -eq 0 ]; then
    echo "==== Maintenance completed successfully ===="
    echo "[LOG] $LOG_FILE"
    exit 0
else
    echo "==== Maintenance completed with ERRORS ====" >&2
    echo "[FAILURES] $FAILED critical services failed to restart." >&2
    echo "Check: systemctl --failed, journalctl -xe" >&2
    echo "Log: $LOG_FILE" >&2
    exit 1
fi
