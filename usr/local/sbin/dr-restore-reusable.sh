#!/bin/bash

set -u

VM_NAME="${1:-}"

CONFIG_DIR="/usr/local/etc/dr"

if [ -z "${VM_NAME:-}" ]; then
    echo "ERROR: VM name belum diberikan."
    echo ""
    echo "Usage:"
    echo "  $0 <VM_NAME>"
    echo ""
    echo "Example:"
    echo "  $0 ONEMDORAYA"
    exit 1
fi

CONFIG_FILE="${CONFIG_DIR}/${VM_NAME}.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config tidak ditemukan:"
    echo "       ${CONFIG_FILE}"
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# ==================================================
# Validate configuration
# ==================================================

: "${VM_NAME:?ERROR: VM_NAME belum didefinisikan}"
: "${PROD_VMID:?ERROR: PROD_VMID belum didefinisikan}"
: "${DR_SLOT_A:?ERROR: DR_SLOT_A belum didefinisikan}"
: "${DR_SLOT_B:?ERROR: DR_SLOT_B belum didefinisikan}"
: "${CURRENT_DR_VMID:?ERROR: CURRENT_DR_VMID belum didefinisikan}"
: "${BACKUP_ROOT:?ERROR: BACKUP_ROOT belum didefinisikan}"
: "${DR_IP:?ERROR: DR_IP belum didefinisikan}"
: "${DR_STORAGE:?ERROR: DR_STORAGE belum didefinisikan}"
: "${SHUTDOWN_TIMEOUT:?ERROR: SHUTDOWN_TIMEOUT belum didefinisikan}"
: "${NETWORK_TIMEOUT:?ERROR: NETWORK_TIMEOUT belum didefinisikan}"
: "${SERVICE_TIMEOUT:?ERROR: SERVICE_TIMEOUT belum didefinisikan}"
: "${NETWORK_RETRY_INTERVAL:?ERROR: NETWORK_RETRY_INTERVAL belum didefinisikan}"
: "${SERVICE_RETRY_INTERVAL:?ERROR: SERVICE_RETRY_INTERVAL belum didefinisikan}"

# ==================================================
# Determine target slot
# ==================================================

if [ "$DR_SLOT_A" = "$DR_SLOT_B" ]; then
    echo "ERROR: DR_SLOT_A dan DR_SLOT_B tidak boleh sama."
    exit 1
fi

if [ "$CURRENT_DR_VMID" = "$DR_SLOT_A" ]; then
    TARGET_DR_VMID="$DR_SLOT_B"
elif [ "$CURRENT_DR_VMID" = "$DR_SLOT_B" ]; then
    TARGET_DR_VMID="$DR_SLOT_A"
else
    echo "ERROR: CURRENT_DR_VMID bukan salah satu DR slot."
    exit 1
fi

# ==================================================
# Concurrency Lock
# ==================================================

LOCK_FILE="/var/run/dr-restore-${VM_NAME}.lock"

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "ERROR: DR restore untuk ${VM_NAME} sedang berjalan."
    echo "       Lock file: ${LOCK_FILE}"
    exit 1
fi

# ==================================================
# Logging
# ==================================================

LOG_FILE="/var/log/dr-restore-${VM_NAME}.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "=================================================="
echo " DR RESTORE ENGINE"
echo "=================================================="
echo " VM Name          : ${VM_NAME}"
echo " Production VMID  : ${PROD_VMID}"
echo " Current DR VMID  : ${CURRENT_DR_VMID}"
echo " Target DR VMID   : ${TARGET_DR_VMID}"
echo " Backup Root      : ${BACKUP_ROOT}"
echo " DR IP            : ${DR_IP}"
echo " DR Storage       : ${DR_STORAGE}"
echo " Config           : ${CONFIG_FILE}"
echo " Log              : ${LOG_FILE}"
echo "=================================================="

# ==================================================
# Safety checks
# ==================================================

echo ""
echo "[1/10] Performing safety checks..."

# Check production VM
if qm status "$PROD_VMID" >/dev/null 2>&1; then
    PROD_STATUS=$(qm status "$PROD_VMID" | awk '{print $2}')

    echo "ERROR: Production VM ${PROD_VMID} ditemukan di node DR."
    echo "       Status: ${PROD_STATUS}"
    echo "       Restore dibatalkan demi keamanan."
    exit 1
else
    echo "      Production VM ${PROD_VMID}: not present on DR"
fi

# Check current DR VM
if ! qm status "$CURRENT_DR_VMID" >/dev/null 2>&1; then
    echo "ERROR: CURRENT DR VM ${CURRENT_DR_VMID} tidak ditemukan."
    exit 1
fi

CURRENT_STATUS=$(qm status "$CURRENT_DR_VMID" | awk '{print $2}')

case "$CURRENT_STATUS" in
    running)
        echo "      Current DR VM ${CURRENT_DR_VMID}: running"
        ;;
    stopped)
        echo "      Current DR VM ${CURRENT_DR_VMID}: stopped"
        ;;
    *)
        echo "ERROR: Status CURRENT DR VM ${CURRENT_DR_VMID} tidak dikenal: ${CURRENT_STATUS}"
        exit 1
        ;;
esac

echo "      Current DR VM ${CURRENT_DR_VMID}: ${CURRENT_STATUS}"

# Target must not exist
if qm status "$TARGET_DR_VMID" >/dev/null 2>&1; then
    echo "ERROR: TARGET DR VM ${TARGET_DR_VMID} sudah ada."
    echo ""
    echo "       Script tidak akan menimpa VM tersebut."
    echo "       Periksa VM target sebelum melanjutkan."
    exit 1
fi

echo "      Target DR VM ${TARGET_DR_VMID}: available"

# Backup root
if [ ! -d "$BACKUP_ROOT" ]; then
    echo "ERROR: Backup root tidak ditemukan:"
    echo "       ${BACKUP_ROOT}"
    exit 1
fi

echo "      Backup root: OK"

# DR storage
if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$DR_STORAGE"; then
    echo "ERROR: Storage '${DR_STORAGE}' tidak ditemukan."
    exit 1
fi

echo "      DR storage: OK"

# ==================================================
# Find latest backup
# ==================================================

echo ""
echo "[2/10] Finding latest backup..."

LATEST_BACKUP=$(
    find "$BACKUP_ROOT" \
        -type f \
        -name 'vzdump-qemu-*.vma.zst' \
        -printf '%T@ %p\n' \
        2>/dev/null \
        | sort -nr \
        | head -n 1 \
        | cut -d' ' -f2-
)

if [ -z "$LATEST_BACKUP" ]; then
    echo "ERROR: Tidak ditemukan backup:"
    echo "       ${BACKUP_ROOT}"
    exit 1
fi

echo "      Latest backup:"
echo "      ${LATEST_BACKUP}"

if [ ! -f "$LATEST_BACKUP" ]; then
    echo "ERROR: File backup tidak dapat diakses."
    exit 1
fi

echo "      Backup file: OK"

# ==================================================
# Stop current VM
# ==================================================

echo ""
echo "[3/10] Stopping CURRENT DR VM ${CURRENT_DR_VMID}..."

CURRENT_STATUS=$(qm status "$CURRENT_DR_VMID" | awk '{print $2}')

if [ "$CURRENT_STATUS" = "running" ]; then

    echo "      Sending graceful shutdown..."

    qm shutdown "$CURRENT_DR_VMID" || true

    ELAPSED=0

    while [ "$ELAPSED" -lt "$SHUTDOWN_TIMEOUT" ]; do

        STATUS=$(qm status "$CURRENT_DR_VMID" | awk '{print $2}')

        if [ "$STATUS" = "stopped" ]; then
            echo "      VM ${CURRENT_DR_VMID} stopped."
            break
        fi

        echo "      Waiting... ${ELAPSED}/${SHUTDOWN_TIMEOUT} seconds"

        sleep 5
        ELAPSED=$((ELAPSED + 5))

    done

    STATUS=$(qm status "$CURRENT_DR_VMID" | awk '{print $2}')

    if [ "$STATUS" != "stopped" ]; then
        echo ""
        echo "ERROR: CURRENT VM ${CURRENT_DR_VMID} gagal shutdown."
        echo ""
        echo "      CURRENT VM tidak akan dihancurkan."
        echo "      Restore dibatalkan."
        exit 1
    fi

else

    echo "      VM sudah stopped."

fi

# ==================================================
# Restore backup
# ==================================================

echo ""
echo "[4/10] Restoring backup to VMID ${TARGET_DR_VMID}..."

if ! qmrestore \
    "$LATEST_BACKUP" \
    "$TARGET_DR_VMID" \
    --storage "$DR_STORAGE" \
    --unique 0; then

    echo ""
    echo "ERROR: qmrestore gagal."
    echo ""

    if qm status "$TARGET_DR_VMID" >/dev/null 2>&1; then
        echo "      Cleaning partial target VM..."

        qm destroy "$TARGET_DR_VMID" --purge 1 || true
    fi

    echo ""
    echo "      Starting CURRENT VM ${CURRENT_DR_VMID}..."

    bash -c 'exec 200>&-; exec qm start "$1"' _ "$CURRENT_DR_VMID" || true

    exit 1
fi

echo ""
echo "      Restore completed successfully."

# ==================================================
# Prepare target VM
# ==================================================

echo ""
echo "[5/10] Preparing TARGET DR VM ${TARGET_DR_VMID}..."

if ! /usr/local/sbin/dr-prepare-vm.sh \
    "$CONFIG_FILE" \
    "$TARGET_DR_VMID"; then

    echo ""
    echo "ERROR: DR preparation failed."

    echo ""
    echo "      Starting rollback..."

    /usr/local/sbin/dr-rollback.sh \
        "$CURRENT_DR_VMID" \
        "$TARGET_DR_VMID" || true

    exit 1
fi

# ==================================================
# Start target VM
# ==================================================

echo ""
echo "[6/10] Starting TARGET DR VM ${TARGET_DR_VMID}..."

if ! bash -c 'exec 200>&-; exec qm start "$1"' _ "$TARGET_DR_VMID"; then

    echo ""
    echo "ERROR: TARGET VM gagal start."

    echo ""
    echo "      Starting rollback..."

    /usr/local/sbin/dr-rollback.sh \
        "$CURRENT_DR_VMID" \
        "$TARGET_DR_VMID" || true

    exit 1
fi

echo "      VM ${TARGET_DR_VMID} started."

# ==================================================
# Wait for network
# ==================================================

echo ""
echo "[7/10] Waiting for network..."

ELAPSED=0

while [ "$ELAPSED" -lt "$NETWORK_TIMEOUT" ]; do

    if ping -c 1 -W 2 "$DR_IP" >/dev/null 2>&1; then
        echo "      Network ready after ${ELAPSED} seconds."
        break
    fi

    echo "      Waiting for network... ${ELAPSED}/${NETWORK_TIMEOUT} seconds"

    sleep "$NETWORK_RETRY_INTERVAL"
    ELAPSED=$((ELAPSED + NETWORK_RETRY_INTERVAL))

done

if ! ping -c 1 -W 2 "$DR_IP" >/dev/null 2>&1; then

    echo ""
    echo "ERROR: Network tidak ready."

    echo ""
    echo "      Starting rollback..."

    /usr/local/sbin/dr-rollback.sh \
        "$CURRENT_DR_VMID" \
        "$TARGET_DR_VMID" || true

    exit 1
fi

# ==================================================
# Wait for services
# ==================================================

echo ""
echo "[8/10] Waiting for services..."

ELAPSED=0
SSH_READY=0
HTTP_READY=0

while [ "$ELAPSED" -lt "$SERVICE_TIMEOUT" ]; do

    if timeout 5 bash -c "</dev/tcp/${DR_IP}/${SSH_PORT}" \
        >/dev/null 2>&1; then
        SSH_READY=1
    fi

    if curl \
        --silent \
        --show-error \
        --fail \
        --connect-timeout 5 \
        --max-time 10 \
        "http://${DR_IP}:${HTTP_PORT}/" \
        >/dev/null 2>&1; then
        HTTP_READY=1
    fi

    if [ "$SSH_READY" -eq 1 ] && [ "$HTTP_READY" -eq 1 ]; then
        echo "      SSH ready."
        echo "      HTTP ready."
        break
    fi

    echo "      SSH=${SSH_READY} HTTP=${HTTP_READY} (${ELAPSED}/${SERVICE_TIMEOUT})"

    sleep "$SERVICE_RETRY_INTERVAL"
    ELAPSED=$((ELAPSED + SERVICE_RETRY_INTERVAL))

done

if [ "$SSH_READY" -ne 1 ] || [ "$HTTP_READY" -ne 1 ]; then

    echo ""
    echo "ERROR: Services tidak ready."

    echo ""
    echo "      Starting rollback..."

    /usr/local/sbin/dr-rollback.sh \
        "$CURRENT_DR_VMID" \
        "$TARGET_DR_VMID" || true

    exit 1
fi

# ==================================================
# Final health check
# ==================================================

echo ""
echo "[9/10] Running final health check..."

if ! /usr/local/sbin/dr-health-check.sh \
    "$CONFIG_FILE"; then

    echo ""
    echo "ERROR: Final health check FAILED."

    echo ""
    echo "      Starting rollback..."

    /usr/local/sbin/dr-rollback.sh \
        "$CURRENT_DR_VMID" \
        "$TARGET_DR_VMID" || true

    exit 1
fi

# ==================================================
# Promote target
# ==================================================

echo ""
echo "[10/10] Promoting TARGET VM ${TARGET_DR_VMID}..."

echo "      Updating CURRENT_DR_VMID..."

sed -i \
    "s/^CURRENT_DR_VMID=.*/CURRENT_DR_VMID=\"${TARGET_DR_VMID}\"/" \
    "$CONFIG_FILE"

echo "      CURRENT_DR_VMID=${TARGET_DR_VMID}"

# ==================================================
# Remove old current VM
# ==================================================

echo ""
echo "      Removing previous CURRENT VM ${CURRENT_DR_VMID}..."

if qm status "$CURRENT_DR_VMID" >/dev/null 2>&1; then

    OLD_STATUS=$(qm status "$CURRENT_DR_VMID" | awk '{print $2}')

    if [ "$OLD_STATUS" = "stopped" ]; then

        if qm destroy "$CURRENT_DR_VMID" --purge 1; then
            echo "      Old VM ${CURRENT_DR_VMID} removed."
        else
            echo "      WARNING: Old VM ${CURRENT_DR_VMID} gagal dihapus."
            echo "      Target VM ${TARGET_DR_VMID} tetap dipertahankan."
        fi

    else

        echo "      WARNING: Old VM ${CURRENT_DR_VMID} bukan stopped."
        echo "      Tidak dihapus demi keamanan."

    fi

else

    echo "      Old VM ${CURRENT_DR_VMID} sudah tidak ada."

fi

# ==================================================
# Final status
# ==================================================

echo ""
echo "=================================================="
echo " DR RESTORE SUCCESS"
echo "=================================================="
echo " VM Name          : ${VM_NAME}"
echo " Production VMID  : ${PROD_VMID}"
echo " Previous DR VMID : ${CURRENT_DR_VMID}"
echo " Current DR VMID  : ${TARGET_DR_VMID}"
echo " DR IP            : ${DR_IP}"
echo " Backup           : ${LATEST_BACKUP}"
echo "=================================================="
echo ""
echo " DR VM ${TARGET_DR_VMID} is now CURRENT."
echo ""
