#!/bin/bash

set -e

CURRENT_VMID="$1"
TARGET_VMID="$2"

if [ -z "${CURRENT_VMID:-}" ] || [ -z "${TARGET_VMID:-}" ]; then
    echo "ERROR: Parameter belum lengkap."
    echo ""
    echo "Usage:"
    echo "  $0 <CURRENT_VMID> <TARGET_VMID>"
    echo ""
    echo "Example:"
    echo "  $0 117 118"
    exit 1
fi

if ! [[ "$CURRENT_VMID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: CURRENT_VMID harus berupa angka."
    exit 1
fi

if ! [[ "$TARGET_VMID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: TARGET_VMID harus berupa angka."
    exit 1
fi

if [ "$CURRENT_VMID" = "$TARGET_VMID" ]; then
    echo "ERROR: CURRENT_VMID dan TARGET_VMID tidak boleh sama."
    exit 1
fi

echo "=================================================="
echo " DR ROLLBACK"
echo "=================================================="
echo " Current VM : ${CURRENT_VMID}"
echo " Failed VM  : ${TARGET_VMID}"
echo "=================================================="

echo ""
echo "[1/4] Checking current VM..."

if ! qm status "$CURRENT_VMID" >/dev/null 2>&1; then
    echo "ERROR: CURRENT VM ${CURRENT_VMID} tidak ditemukan."
    exit 1
fi

CURRENT_STATUS=$(qm status "$CURRENT_VMID" | awk '{print $2}')

echo "      VM ${CURRENT_VMID} status: ${CURRENT_STATUS}"

echo ""
echo "[2/4] Stopping failed target VM..."

if qm status "$TARGET_VMID" >/dev/null 2>&1; then

    TARGET_STATUS=$(qm status "$TARGET_VMID" | awk '{print $2}')

    echo "      VM ${TARGET_VMID} status: ${TARGET_STATUS}"

    if [ "$TARGET_STATUS" = "running" ]; then
        echo "      Attempting graceful shutdown..."

        qm shutdown "$TARGET_VMID" || true

        TIMEOUT=120
        ELAPSED=0

        while [ "$ELAPSED" -lt "$TIMEOUT" ]; do

            STATUS=$(qm status "$TARGET_VMID" | awk '{print $2}')

            if [ "$STATUS" = "stopped" ]; then
                echo "      VM ${TARGET_VMID} berhasil stopped."
                break
            fi

            sleep 5
            ELAPSED=$((ELAPSED + 5))

        done

        STATUS=$(qm status "$TARGET_VMID" | awk '{print $2}')

        if [ "$STATUS" != "stopped" ]; then
            echo "      Graceful shutdown gagal."
            echo "      Melakukan hard stop..."

            qm stop "$TARGET_VMID"
        fi
    fi

else

    echo "      Target VM ${TARGET_VMID} tidak ditemukan."
    echo "      Tidak ada VM yang perlu dihentikan."

fi

echo ""
echo "[3/4] Destroying failed target VM..."

if qm status "$TARGET_VMID" >/dev/null 2>&1; then

    qm destroy "$TARGET_VMID" --purge 1

    echo "      VM ${TARGET_VMID} berhasil dihapus."

else

    echo "      VM ${TARGET_VMID} sudah tidak ada."

fi

echo ""
echo "[4/4] Starting current VM..."

CURRENT_STATUS=$(qm status "$CURRENT_VMID" | awk '{print $2}')

if [ "$CURRENT_STATUS" = "running" ]; then

    echo "      VM ${CURRENT_VMID} sudah running."

else

    qm start "$CURRENT_VMID"

    echo "      VM ${CURRENT_VMID} berhasil di-start."

fi

echo ""
echo "=================================================="
echo " DR ROLLBACK COMPLETED"
echo "=================================================="
echo " Current VM : ${CURRENT_VMID}"
echo " Failed VM  : ${TARGET_VMID}"
echo "=================================================="
echo ""
