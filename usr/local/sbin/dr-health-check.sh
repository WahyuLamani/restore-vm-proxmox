#!/bin/bash

set -u

CONFIG_FILE="$1"

if [ -z "${CONFIG_FILE:-}" ]; then
    echo "ERROR: Config belum diberikan."
    echo ""
    echo "Usage:"
    echo "  $0 <config-file>"
    echo ""
    echo "Example:"
    echo "  $0 /usr/local/etc/dr/ONEMDORAYA.conf"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config tidak ditemukan:"
    echo "       $CONFIG_FILE"
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# Validate required configuration
: "${VM_NAME:?ERROR: VM_NAME belum didefinisikan}"
: "${DR_IP:?ERROR: DR_IP belum didefinisikan}"
: "${SSH_PORT:?ERROR: SSH_PORT belum didefinisikan}"
: "${HTTP_PORT:?ERROR: HTTP_PORT belum didefinisikan}"

echo "=================================================="
echo " DR VM HEALTH CHECK"
echo "=================================================="
echo " VM Name    : ${VM_NAME}"
echo " Target IP  : ${DR_IP}"
echo " SSH Port   : ${SSH_PORT}"
echo " HTTP Port  : ${HTTP_PORT}"
echo "=================================================="

FAILED=0

echo ""
echo "[1/3] Checking ICMP..."

if ping -c 3 -W 2 "$DR_IP" >/dev/null 2>&1; then
    echo "      PASS: Ping berhasil."
else
    echo "      FAIL: Ping gagal."
    FAILED=1
fi

echo ""
echo "[2/3] Checking SSH port ${SSH_PORT}..."

if timeout 5 bash -c "</dev/tcp/${DR_IP}/${SSH_PORT}" \
    >/dev/null 2>&1; then
    echo "      PASS: SSH port ${SSH_PORT} terbuka."
else
    echo "      FAIL: SSH port ${SSH_PORT} tidak dapat diakses."
    FAILED=1
fi

echo ""
echo "[3/3] Checking HTTP port ${HTTP_PORT}..."

if curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 5 \
    --max-time 10 \
    "http://${DR_IP}:${HTTP_PORT}/" \
    >/dev/null 2>&1; then

    echo "      PASS: HTTP service merespons."
else
    echo "      FAIL: HTTP service tidak merespons."
    FAILED=1
fi

echo ""
echo "=================================================="

if [ "$FAILED" -eq 0 ]; then

    echo " HEALTH CHECK: SUCCESS"
    echo " ${VM_NAME} (${DR_IP}) HEALTHY."

    echo "=================================================="
    exit 0

else

    echo " HEALTH CHECK: FAILED"
    echo " ${VM_NAME} (${DR_IP}) tidak sehat."

    echo "=================================================="
    exit 1

fi
