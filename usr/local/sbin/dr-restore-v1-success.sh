#!/bin/bash

set -u

# ==========================================================
# DR Restore Orchestrator
#
# Usage:
#   dr-restore.sh <OLD_VMID> <NEW_VMID> <BACKUP_ROOT> <DR_IP>
#
# Example:
#   dr-restore.sh 107 117 /mnt/omv-backup/Regional 192.168.71.233
#
# Flow:
#   1. Validate old/new VM
#   2. Find latest backup
#   3. Stop old VM gracefully
#   4. Wait until old VM is really stopped
#   5. Restore new VM
#   6. Prepare new VM
#   7. Start new VM
#   8. Wait for network
#   9. Wait for SSH + HTTP
#  10. Final health check
#  11. SUCCESS / ROLLBACK
#
# Exit code:
#   0 = SUCCESS
#   1 = FAILED
# ==========================================================

OLD_VMID="${1:-}"
NEW_VMID="${2:-}"
BACKUP_ROOT="${3:-}"
DR_IP="${4:-}"

DR_STORAGE="local-lvm"

SHUTDOWN_TIMEOUT=300
NETWORK_TIMEOUT=300
SERVICE_TIMEOUT=300

NETWORK_RETRY_INTERVAL=5
SERVICE_RETRY_INTERVAL=10

PREPARE_SCRIPT="/usr/local/sbin/dr-prepare-vm.sh"
HEALTH_SCRIPT="/usr/local/sbin/dr-health-check.sh"
ROLLBACK_SCRIPT="/usr/local/sbin/dr-rollback.sh"

# ==========================================================
# Error handler
# ==========================================================

error_exit() {

    echo ""
    echo "=================================================="
    echo " DR RESTORE FAILED"
    echo "=================================================="
    echo "$1"
    echo "=================================================="

    exit 1
}

# ==========================================================
# Graceful VM shutdown
# ==========================================================

stop_vm_gracefully() {

    local VMID="$1"
    local TIMEOUT="$2"

    echo ""
    echo "Requesting graceful shutdown VM ${VMID}..."

    # qm shutdown may return timeout/error even when
    # the guest is actually shutting down.
    qm shutdown "$VMID" || true

    local ELAPSED=0

    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do

        STATUS=$(qm status "$VMID" | awk '{print $2}')

        if [ "$STATUS" = "stopped" ]; then
            echo "VM ${VMID} berhasil stopped."
            return 0
        fi

        echo "VM ${VMID} masih ${STATUS}... (${ELAPSED}/${TIMEOUT}s)"

        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done

    echo "ERROR: VM ${VMID} belum stopped setelah ${TIMEOUT} detik."

    return 1
}

# ==========================================================
# Wait for network / ping
# ==========================================================

wait_for_network() {

    local IP="$1"
    local TIMEOUT="$2"
    local INTERVAL="$3"

    local ELAPSED=0

    echo ""
    echo "Waiting for ${IP} network..."

    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do

        if ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then

            echo "Network ${IP} READY."
            echo "Network ready after ${ELAPSED} seconds."

            return 0
        fi

        echo "Network belum ready... (${ELAPSED}/${TIMEOUT}s)"

        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo "ERROR: Network ${IP} belum ready setelah ${TIMEOUT} detik."

    return 1
}

# ==========================================================
# Wait for services
# ==========================================================

wait_for_services() {

    local IP="$1"
    local TIMEOUT="$2"
    local INTERVAL="$3"

    local ELAPSED=0

    echo ""
    echo "Waiting for VM services..."
    echo "Target:"
    echo "  SSH  : ${IP}:22"
    echo "  HTTP : ${IP}:80"

    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do

        SSH_READY=0
        HTTP_READY=0

        if timeout 5 bash -c "</dev/tcp/${IP}/22" \
            >/dev/null 2>&1; then
            SSH_READY=1
        fi

        if curl \
            --silent \
            --show-error \
            --fail \
            --connect-timeout 5 \
            --max-time 10 \
            "http://${IP}/" \
            >/dev/null 2>&1; then
            HTTP_READY=1
        fi

        if [ "$SSH_READY" -eq 1 ] && [ "$HTTP_READY" -eq 1 ]; then

            echo "SSH service READY."
            echo "HTTP service READY."
            echo "All required services ready after ${ELAPSED} seconds."

            return 0
        fi

        if [ "$SSH_READY" -eq 1 ]; then
            SSH_STATUS="READY"
        else
            SSH_STATUS="NOT READY"
        fi

        if [ "$HTTP_READY" -eq 1 ]; then
            HTTP_STATUS="READY"
        else
            HTTP_STATUS="NOT READY"
        fi

        echo "Services: SSH=${SSH_STATUS}, HTTP=${HTTP_STATUS} (${ELAPSED}/${TIMEOUT}s)"

        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo ""
    echo "ERROR: Required services belum ready setelah ${TIMEOUT} detik."

    return 1
}

# ==========================================================
# Rollback helper
# ==========================================================

perform_rollback() {

    echo ""
    echo "=================================================="
    echo " INITIATING ROLLBACK"
    echo "=================================================="

    if [ ! -x "$ROLLBACK_SCRIPT" ]; then
        echo "ERROR: Rollback script tidak ditemukan:"
        echo "$ROLLBACK_SCRIPT"
        return 1
    fi

    if "$ROLLBACK_SCRIPT" "$OLD_VMID" "$NEW_VMID"; then

        echo ""
        echo "Rollback berhasil."
        return 0

    else

        echo ""
        echo "CRITICAL: Rollback gagal."
        return 1
    fi
}

# ==========================================================
# Parameter validation
# ==========================================================

if [ -z "$OLD_VMID" ] || \
   [ -z "$NEW_VMID" ] || \
   [ -z "$BACKUP_ROOT" ] || \
   [ -z "$DR_IP" ]; then

    echo "ERROR: Parameter belum lengkap."
    echo ""
    echo "Usage:"
    echo "  $0 <OLD_VMID> <NEW_VMID> <BACKUP_ROOT> <DR_IP>"
    echo ""
    echo "Example:"
    echo "  $0 107 117 /mnt/omv-backup/Regional 192.168.71.233"

    exit 1
fi

if ! [[ "$OLD_VMID" =~ ^[0-9]+$ ]] || \
   ! [[ "$NEW_VMID" =~ ^[0-9]+$ ]]; then

    error_exit "VMID harus berupa angka."
fi

if [ "$OLD_VMID" = "$NEW_VMID" ]; then
    error_exit "OLD_VMID dan NEW_VMID tidak boleh sama."
fi

# ==========================================================
# Header
# ==========================================================

echo "=================================================="
echo " DR RESTORE ORCHESTRATOR"
echo "=================================================="
echo " Old VM            : ${OLD_VMID}"
echo " New VM            : ${NEW_VMID}"
echo " Backup Root       : ${BACKUP_ROOT}"
echo " DR IP             : ${DR_IP}"
echo " Storage           : ${DR_STORAGE}"
echo " Shutdown Timeout  : ${SHUTDOWN_TIMEOUT}s"
echo " Network Timeout   : ${NETWORK_TIMEOUT}s"
echo " Service Timeout   : ${SERVICE_TIMEOUT}s"
echo "=================================================="

# ==========================================================
# Step 1 - Check old VM
# ==========================================================

echo ""
echo "[1/10] Checking old VM..."

if ! qm status "$OLD_VMID" >/dev/null 2>&1; then
    error_exit "Old VM ${OLD_VMID} tidak ditemukan."
fi

echo "       Old VM ${OLD_VMID} ditemukan."

# ==========================================================
# Step 2 - Check new VM
# ==========================================================

echo ""
echo "[2/10] Checking new VM..."

if qm status "$NEW_VMID" >/dev/null 2>&1; then
    error_exit "New VM ${NEW_VMID} sudah ada. Abort untuk mencegah overwrite."
fi

echo "       New VM ${NEW_VMID} belum ada."

# ==========================================================
# Step 3 - Find latest backup
# ==========================================================

echo ""
echo "[3/10] Finding latest backup..."

if [ ! -d "$BACKUP_ROOT" ]; then
    error_exit "Backup directory tidak ditemukan: ${BACKUP_ROOT}"
fi

BACKUP_FILE=$(find "$BACKUP_ROOT" \
    -type f \
    -name 'vzdump-qemu-*.vma.zst' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-)

if [ -z "$BACKUP_FILE" ]; then
    error_exit "Tidak ditemukan backup vzdump-qemu-*.vma.zst."
fi

echo "       Latest backup:"
echo "       ${BACKUP_FILE}"

# ==========================================================
# Step 4 - Stop old VM
# ==========================================================

echo ""
echo "[4/10] Stopping old VM ${OLD_VMID}..."

OLD_STATUS=$(qm status "$OLD_VMID" | awk '{print $2}')

if [ "$OLD_STATUS" = "running" ]; then

    if ! stop_vm_gracefully "$OLD_VMID" "$SHUTDOWN_TIMEOUT"; then

        echo ""
        echo "Old VM gagal shutdown."
        echo "Restore dibatalkan."
        echo "VM lama tetap dipertahankan."

        error_exit "Old VM ${OLD_VMID} gagal berhenti."
    fi

else

    echo "       Old VM sudah ${OLD_STATUS}."
fi

# ==========================================================
# Step 5 - Restore new VM
# ==========================================================

echo ""
echo "[5/10] Restoring new VM ${NEW_VMID}..."

if ! qmrestore \
    "$BACKUP_FILE" \
    "$NEW_VMID" \
    --storage "$DR_STORAGE"; then

    echo ""
    echo "Restore gagal."

    # Cleanup partial VM if it exists
    if qm status "$NEW_VMID" >/dev/null 2>&1; then

        echo "Membersihkan VM ${NEW_VMID} hasil restore partial..."

        qm stop "$NEW_VMID" >/dev/null 2>&1 || true

        qm destroy "$NEW_VMID" --purge 1 || true
    fi

    echo "Menjalankan rollback..."

    if ! perform_rollback; then
        error_exit "Restore gagal DAN rollback gagal."
    fi

    error_exit "Restore VM ${NEW_VMID} gagal."
fi

echo "       Restore berhasil."

# ==========================================================
# Step 6 - Prepare new VM
# ==========================================================

echo ""
echo "[6/10] Preparing new VM ${NEW_VMID}..."

if ! "$PREPARE_SCRIPT" "$NEW_VMID"; then

    echo ""
    echo "Preparation gagal."
    echo "Menjalankan rollback..."

    if ! perform_rollback; then
        error_exit "Preparation gagal DAN rollback gagal."
    fi

    error_exit "Preparation VM ${NEW_VMID} gagal."
fi

# ==========================================================
# Step 7 - Start new VM
# ==========================================================

echo ""
echo "[7/10] Starting new VM ${NEW_VMID}..."

if ! qm start "$NEW_VMID"; then

    echo ""
    echo "Start VM gagal."
    echo "Menjalankan rollback..."

    if ! perform_rollback; then
        error_exit "Start VM gagal DAN rollback gagal."
    fi

    error_exit "VM ${NEW_VMID} gagal start."
fi

echo "       VM ${NEW_VMID} started."

# ==========================================================
# Step 8 - Wait for network
# ==========================================================

echo ""
echo "[8/10] Waiting for network..."

if ! wait_for_network \
    "$DR_IP" \
    "$NETWORK_TIMEOUT" \
    "$NETWORK_RETRY_INTERVAL"; then

    echo ""
    echo "Network check FAILED."
    echo "Menjalankan rollback..."

    if ! perform_rollback; then
        error_exit "Network check gagal DAN rollback gagal."
    fi

    error_exit "VM ${NEW_VMID} gagal melewati network readiness."
fi

# ==========================================================
# Step 9 - Wait for services
# ==========================================================

echo ""
echo "[9/10] Waiting for services..."

if ! wait_for_services \
    "$DR_IP" \
    "$SERVICE_TIMEOUT" \
    "$SERVICE_RETRY_INTERVAL"; then

    echo ""
    echo "Service readiness FAILED."
    echo "Menjalankan rollback..."

    if ! perform_rollback; then
        error_exit "Service check gagal DAN rollback gagal."
    fi

    error_exit "VM ${NEW_VMID} gagal melewati service readiness."
fi

# ==========================================================
# Step 10 - Final health check
# ==========================================================

echo ""
echo "[10/10] Running final health check..."

if ! "$HEALTH_SCRIPT" "$DR_IP"; then

    echo ""
    echo "Final health check FAILED."
    echo "Menjalankan rollback..."

    if ! perform_rollback; then
        error_exit "Final health check gagal DAN rollback gagal."
    fi

    error_exit "VM ${NEW_VMID} tidak sehat."
fi

# ==========================================================
# SUCCESS
# ==========================================================

echo ""
echo "=================================================="
echo " DR RESTORE SUCCESS"
echo "=================================================="
echo " Old VM : ${OLD_VMID}"
echo " New VM : ${NEW_VMID}"
echo " IP     : ${DR_IP}"
echo ""
echo " Network : READY"
echo " SSH     : READY"
echo " HTTP    : READY"
echo " Health  : SUCCESS"
echo ""
echo " IMPORTANT:"
echo " Old VM ${OLD_VMID} TIDAK dihapus."
echo " New VM ${NEW_VMID} sekarang HEALTHY."
echo "=================================================="

exit 0
