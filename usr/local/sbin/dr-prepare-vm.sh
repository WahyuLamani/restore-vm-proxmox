#!/bin/bash

set -e

CONFIG_FILE="$1"
VMID="$2"

if [ -z "${CONFIG_FILE:-}" ] || [ -z "${VMID:-}" ]; then
    echo "ERROR: Parameter belum lengkap."
    echo ""
    echo "Usage:"
    echo "  $0 <config-file> <VMID>"
    echo ""
    echo "Example:"
    echo "  $0 /usr/local/etc/dr/ONEMDORAYA.conf 118"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config tidak ditemukan:"
    echo "       $CONFIG_FILE"
    exit 1
fi

if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: VMID harus berupa angka."
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# Validate required configuration
: "${VM_NAME:?ERROR: VM_NAME belum didefinisikan}"
: "${DR_BRIDGE:?ERROR: DR_BRIDGE belum didefinisikan}"
: "${DR_CORES:?ERROR: DR_CORES belum didefinisikan}"
: "${DR_MEMORY:?ERROR: DR_MEMORY belum didefinisikan}"
: "${DR_NET_MODEL:?ERROR: DR_NET_MODEL belum didefinisikan}"

echo "=================================================="
echo " Preparing DR VM"
echo "=================================================="
echo " VM Name   : ${VM_NAME}"
echo " VMID      : ${VMID}"
echo " Bridge    : ${DR_BRIDGE}"
echo " Net Model : ${DR_NET_MODEL}"
echo " CPU       : ${DR_CORES} cores"
echo " Memory    : ${DR_MEMORY} MB"
echo "=================================================="

echo ""
echo "[1/6] Checking VM..."

if ! qm status "$VMID" >/dev/null 2>&1; then
    echo "ERROR: VM ${VMID} tidak ditemukan."
    exit 1
fi

echo "      VM ${VMID} ditemukan."

echo ""
echo "[2/6] Checking VM status..."

STATUS=$(qm status "$VMID" | awk '{print $2}')

if [ "$STATUS" = "running" ]; then
    echo "ERROR: VM ${VMID} sedang running."
    echo "       Stop VM terlebih dahulu sebelum preparation."
    exit 1
fi

echo "      VM sudah stopped."

echo ""
echo "[3/6] Configuring CPU and memory..."

qm set "$VMID" \
    --cores "$DR_CORES" \
    --memory "$DR_MEMORY"

echo "      CPU    : ${DR_CORES} cores"
echo "      Memory : ${DR_MEMORY} MB"

echo ""
echo "[4/6] Configuring DR network..."

CURRENT_NET=$(qm config "$VMID" | awk -F': ' '/^net0:/ {print $2}')

if [ -z "$CURRENT_NET" ]; then
    echo "ERROR: net0 tidak ditemukan pada VM ${VMID}."
    exit 1
fi

CURRENT_MAC=$(echo "$CURRENT_NET" | sed -n 's/^[^=]*=\([^,]*\).*/\1/p')

if [ -z "$CURRENT_MAC" ]; then
    echo "ERROR: MAC address net0 tidak dapat dibaca."
    echo "       net0: ${CURRENT_NET}"
    exit 1
fi

echo "      MAC       : ${CURRENT_MAC}"
echo "      Model     : ${DR_NET_MODEL}"
echo "      Bridge    : ${DR_BRIDGE}"

qm set "$VMID" \
    --net0 "${DR_NET_MODEL}=${CURRENT_MAC},bridge=${DR_BRIDGE},firewall=1"

echo ""
echo "[5/6] Configuring onboot..."

qm set "$VMID" --onboot 0

echo "      onboot: 0"

echo ""
echo "[6/6] Verifying VM configuration..."

echo ""
qm config "$VMID" | grep -E '^(cores|memory|net0|onboot):'
echo ""

echo "=================================================="
echo " DR VM ${VMID} berhasil dipersiapkan."
echo " VM masih dalam keadaan STOPPED."
echo "=================================================="
echo ""
