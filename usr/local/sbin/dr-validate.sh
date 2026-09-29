#!/bin/bash

set -u

VM_NAME="$1"

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

source "$CONFIG_FILE"

echo "=================================================="
echo " DR SAFETY VALIDATION"
echo "=================================================="
echo " VM Name          : ${VM_NAME}"
echo " Config           : ${CONFIG_FILE}"
echo "=================================================="

FAILED=0

echo ""
echo "[1/10] Checking configuration..."

REQUIRED_VARS=(
    VM_NAME
    PROD_VMID
    DR_SLOT_A
    DR_SLOT_B
    CURRENT_DR_VMID
    BACKUP_ROOT
    DR_IP
    DR_BRIDGE
    DR_STORAGE
)

for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR:-}" ]; then
        echo "      FAIL: ${VAR} belum didefinisikan."
        FAILED=1
    else
        echo "      PASS: ${VAR}=${!VAR}"
    fi
done

echo ""
echo "[2/10] Checking DR slots..."

if [ "$DR_SLOT_A" = "$DR_SLOT_B" ]; then
    echo "      FAIL: DR_SLOT_A dan DR_SLOT_B sama."
    FAILED=1
else
    echo "      PASS: Slot A dan B berbeda."
fi

if [ "$CURRENT_DR_VMID" = "$DR_SLOT_A" ] || \
   [ "$CURRENT_DR_VMID" = "$DR_SLOT_B" ]; then
    echo "      PASS: CURRENT_DR_VMID valid."
else
    echo "      FAIL: CURRENT_DR_VMID bukan salah satu slot."
    FAILED=1
fi

if [ "$CURRENT_DR_VMID" = "$DR_SLOT_A" ]; then
    TARGET_DR_VMID="$DR_SLOT_B"
else
    TARGET_DR_VMID="$DR_SLOT_A"
fi

echo "      CURRENT : ${CURRENT_DR_VMID}"
echo "      TARGET  : ${TARGET_DR_VMID}"

echo ""
echo "[3/10] Checking CURRENT VM..."

if qm status "$CURRENT_DR_VMID" >/dev/null 2>&1; then

    CURRENT_STATUS=$(qm status "$CURRENT_DR_VMID" | awk '{print $2}')

    echo "      PASS: VM ${CURRENT_DR_VMID} ditemukan."
    echo "      Status: ${CURRENT_STATUS}"

else

    echo "      FAIL: VM ${CURRENT_DR_VMID} tidak ditemukan."
    FAILED=1

fi

echo ""
echo "[4/10] Checking TARGET VM..."

if qm status "$TARGET_DR_VMID" >/dev/null 2>&1; then

    TARGET_STATUS=$(qm status "$TARGET_DR_VMID" | awk '{print $2}')

    echo "      FAIL: VM target ${TARGET_DR_VMID} sudah ada."
    echo "      Status: ${TARGET_STATUS}"

    FAILED=1

else

    echo "      PASS: VM target ${TARGET_DR_VMID} belum ada."

fi

echo ""
echo "[5/10] Checking production VMID..."

if [ "$PROD_VMID" = "$CURRENT_DR_VMID" ] || \
   [ "$PROD_VMID" = "$TARGET_DR_VMID" ]; then

    echo "      FAIL: PROD_VMID sama dengan DR slot."
    FAILED=1

else

    echo "      PASS: Production VMID berbeda dari DR slot."

fi

if qm status "$PROD_VMID" >/dev/null 2>&1; then

    echo "      WARNING: VM ${PROD_VMID} juga ditemukan pada node DR."

else

    echo "      PASS: Production VM ${PROD_VMID} tidak ada pada node DR."

fi

echo ""
echo "[6/10] Checking backup root..."

if [ -d "$BACKUP_ROOT" ]; then
    echo "      PASS: ${BACKUP_ROOT}"
else
    echo "      FAIL: Backup root tidak ditemukan."
    FAILED=1
fi

echo ""
echo "[7/10] Finding latest backup..."

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

if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then

    echo "      PASS: Backup ditemukan."
    echo "      ${LATEST_BACKUP}"

else

    echo "      FAIL: Backup tidak ditemukan."
    FAILED=1

fi

echo ""
echo "[8/10] Checking DR storage..."

if pvesm status | awk 'NR>1 {print $1}' | grep -qx "$DR_STORAGE"; then

    echo "      PASS: Storage ${DR_STORAGE} tersedia."

else

    echo "      FAIL: Storage ${DR_STORAGE} tidak ditemukan."
    FAILED=1

fi

echo ""
echo "[9/10] Checking helper scripts..."

HELPERS=(
    "/usr/local/sbin/dr-prepare-vm.sh"
    "/usr/local/sbin/dr-health-check.sh"
    "/usr/local/sbin/dr-rollback.sh"
)

for HELPER in "${HELPERS[@]}"; do

    if [ -x "$HELPER" ]; then
        echo "      PASS: ${HELPER}"
    else
        echo "      FAIL: ${HELPER}"
        FAILED=1
    fi

done

echo ""
echo "[10/10] Checking CURRENT VM health..."

if [ "$CURRENT_STATUS" = "running" ]; then

    if /usr/local/sbin/dr-health-check.sh "$CONFIG_FILE"; then
        echo "      PASS: CURRENT VM sehat."
    else
        echo "      FAIL: CURRENT VM health check gagal."
        FAILED=1
    fi

else

    echo "      WARNING: CURRENT VM tidak running."
    echo "      Status: ${CURRENT_STATUS}"

fi

echo ""
echo "=================================================="

if [ "$FAILED" -eq 0 ]; then

    echo " SAFETY VALIDATION: PASSED"
    echo ""
    echo " Ready for DR restore:"
    echo " CURRENT : ${CURRENT_DR_VMID}"
    echo " TARGET  : ${TARGET_DR_VMID}"
    echo "=================================================="

    exit 0

else

    echo " SAFETY VALIDATION: FAILED"
    echo ""
    echo " DR restore TIDAK BOLEH dijalankan."
    echo "=================================================="

    exit 1

fi
