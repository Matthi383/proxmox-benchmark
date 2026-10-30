#!/usr/bin/env bash

# ==========================================================
# Proxmox Benchmark
# Version: 1.0
#
# Tests:
#   - pveperf
#   - 4K Random Mixed QD32 (70/30)
#   - Sequential Write QD16
#   - Sequential Read QD16
#   - 4K Random Write QD1
#   - 4K Random Read QD1
#   - FSYNC
#
# Usage:
#   ./proxmox-benchmark.sh NAME=PATH [NAME=PATH ...]
#
# Example:
#   ./proxmox-benchmark.sh core=/mnt/pve/core forge=/mnt/pve/forge
# ==========================================================

set -Eeuo pipefail

VERSION="1.0"
RUNTIME=60
TEST_SIZE="2G"
FSYNC_SIZE="256M"
BLOCK_SIZE="4k"
LOG_DIR="/root/ssd-benchmark-results"

# ----------------------------------------------------------
# Checks
# ----------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "FEHLER: Bitte als root ausführen."
    exit 1
fi

if ! command -v fio >/dev/null 2>&1; then
    echo "FEHLER: fio ist nicht installiert."
    echo "Installation: apt install fio"
    exit 1
fi

if ! command -v pveperf >/dev/null 2>&1; then
    echo "FEHLER: pveperf wurde nicht gefunden."
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Verwendung:"
    echo "$0 NAME=PFAD [NAME=PFAD ...]"
    echo
    echo "Beispiel:"
    echo "$0 core=/mnt/pve/core forge=/mnt/pve/forge"
    exit 1
fi

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/benchmark-$TIMESTAMP.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "=========================================================="
echo " PROXMOX BENCHMARK v$VERSION"
echo "=========================================================="
echo "Datum: $(date)"
echo "Host:  $(hostname)"
echo "Kernel: $(uname -r)"
echo "fio:   $(fio --version)"
echo "Log:   $LOG_FILE"
echo

# ----------------------------------------------------------
# System information
# ----------------------------------------------------------

echo "=========================================================="
echo " SYSTEM INFORMATION"
echo "=========================================================="

pveversion -v || true

echo
echo "--- CPU ---"
lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket'

echo
echo "--- Memory ---"
free -h

echo
echo "--- Disks ---"
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS

# ============================================================
# NETWORK BENCHMARK
# ============================================================

echo
echo "============================================================"
echo " NETWORK BENCHMARK"
echo "============================================================"

NETWORK_HOST="192.168.2.251"
NETWORK_PORT="4711"

echo
echo ">>> DNS-Auflösung (IPv4)"
if time getent ahostsv4 fritz.box; then
    echo "DNS-Auflösung erfolgreich."
else
    echo "DNS-Auflösung fehlgeschlagen."
fi

echo
echo ">>> Ping-Test (20 Pakete)"
ping -c 20 "$NETWORK_HOST" || echo "Ping-Test fehlgeschlagen"

if command -v iperf >/dev/null 2>&1; then

    echo
    echo ">>> iperf2 Single-Stream (30 Sekunden)"
    iperf -c "$NETWORK_HOST" -p "$NETWORK_PORT" -t 30 -i 5 \
        || echo "Single-Stream-Test fehlgeschlagen"

    echo
    echo ">>> iperf2 Multi-Stream (4 Streams, 30 Sekunden)"
    iperf -c "$NETWORK_HOST" -p "$NETWORK_PORT" -t 30 -i 5 -P 4 \
        || echo "Multi-Stream-Test fehlgeschlagen"

else
    echo
    echo "iperf2 nicht installiert – Netzwerkbenchmark übersprungen."
fi

echo
echo ">>> Netzwerkbenchmark abgeschlossen"
echo

echo

# ----------------------------------------------------------
# PVE Performance
# ----------------------------------------------------------

echo "=========================================================="
echo " PVE PERFORMANCE - ROOT"
echo "=========================================================="

pveperf /

# ----------------------------------------------------------
# Storage preparation
# ----------------------------------------------------------

declare -a STORAGE_NAMES=()
declare -a STORAGE_PATHS=()

for ARG in "$@"; do

    if [[ "$ARG" != *=* ]]; then
        echo "FEHLER: Ungültiges Argument: $ARG"
        exit 1
    fi

    NAME="${ARG%%=*}"
    PATH_STORAGE="${ARG#*=}"

    if [[ -z "$NAME" || -z "$PATH_STORAGE" ]]; then
        echo "FEHLER: Name oder Pfad fehlt: $ARG"
        exit 1
    fi

    if [[ ! -d "$PATH_STORAGE" ]]; then
        echo "FEHLER: Verzeichnis existiert nicht: $PATH_STORAGE"
        exit 1
    fi

    if [[ ! -w "$PATH_STORAGE" ]]; then
        echo "FEHLER: Verzeichnis nicht beschreibbar: $PATH_STORAGE"
        exit 1
    fi

    AVAILABLE=$(df -BG --output=avail "$PATH_STORAGE" | tail -1 | tr -dc '0-9')

    if (( AVAILABLE < 4 )); then
        echo "FEHLER: Zu wenig freier Speicher auf $PATH_STORAGE"
        echo "Mindestens 4 GB freier Speicher erforderlich."
        exit 1
    fi

    STORAGE_NAMES+=("$NAME")
    STORAGE_PATHS+=("$PATH_STORAGE")

done

# ----------------------------------------------------------
# PVE Performance per storage
# ----------------------------------------------------------

for INDEX in "${!STORAGE_NAMES[@]}"; do

    NAME="${STORAGE_NAMES[$INDEX]}"
    PATH_STORAGE="${STORAGE_PATHS[$INDEX]}"

    echo
    echo "=========================================================="
    echo " PVE PERFORMANCE - $NAME"
    echo "=========================================================="

    pveperf "$PATH_STORAGE"

done

# ----------------------------------------------------------
# Benchmark function
# ----------------------------------------------------------

run_fio() {

    local NAME="$1"
    local FILE="$2"
    shift 2

    echo
    echo "----------------------------------------------------------"
    echo " TEST: $NAME"
    echo "----------------------------------------------------------"

    fio \
        --name="$NAME" \
        --filename="$FILE" \
        "$@" \
        --runtime="$RUNTIME" \
        --time_based \
        --group_reporting

}

# ----------------------------------------------------------
# Run benchmarks
# ----------------------------------------------------------

for INDEX in "${!STORAGE_NAMES[@]}"; do

    NAME="${STORAGE_NAMES[$INDEX]}"
    PATH_STORAGE="${STORAGE_PATHS[$INDEX]}"

    TEST_FILE="$PATH_STORAGE/.fio-benchmark-$TIMESTAMP.tmp"

    echo
    echo
    echo "##########################################################"
    echo " STORAGE: $NAME"
    echo " PATH:    $PATH_STORAGE"
    echo "##########################################################"

    echo
    echo "--- Storage information ---"
    df -h "$PATH_STORAGE"

    echo
    echo "--- Starting benchmarks ---"

    # 1. 4K Random Mixed QD32
    run_fio \
        "$NAME-randrw-qd32" \
        "$TEST_FILE" \
        --size="$TEST_SIZE" \
        --rw=randrw \
        --rwmixread=70 \
        --bs="$BLOCK_SIZE" \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1

    # 2. Sequential Write QD16
    run_fio \
        "$NAME-seqwrite-qd16" \
        "$TEST_FILE" \
        --size="$TEST_SIZE" \
        --rw=write \
        --bs=1M \
        --ioengine=libaio \
        --iodepth=16 \
        --direct=1

    # 3. Sequential Read QD16
    run_fio \
        "$NAME-seqread-qd16" \
        "$TEST_FILE" \
        --size="$TEST_SIZE" \
        --rw=read \
        --bs=1M \
        --ioengine=libaio \
        --iodepth=16 \
        --direct=1

    # 4. 4K Random Write QD1
    run_fio \
        "$NAME-randwrite-qd1" \
        "$TEST_FILE" \
        --size="$TEST_SIZE" \
        --rw=randwrite \
        --bs="$BLOCK_SIZE" \
        --ioengine=libaio \
        --iodepth=1 \
        --direct=1

    # 5. 4K Random Read QD1
    run_fio \
        "$NAME-randread-qd1" \
        "$TEST_FILE" \
        --size="$TEST_SIZE" \
        --rw=randread \
        --bs="$BLOCK_SIZE" \
        --ioengine=libaio \
        --iodepth=1 \
        --direct=1

    # 6. FSYNC
    run_fio \
        "$NAME-fsync" \
        "$TEST_FILE" \
        --size="$FSYNC_SIZE" \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --ioengine=psync \
        --fdatasync=1 \
        --direct=0

    # Cleanup
    echo
    echo "--- Removing benchmark file ---"

    rm -f -- "$TEST_FILE"

    echo "Storage $NAME completed."

done

# ----------------------------------------------------------
# Finish
# ----------------------------------------------------------

echo
echo "=========================================================="
echo " BENCHMARK COMPLETED"
echo "=========================================================="

echo "Host: $(hostname)"
echo "Finished: $(date)"
echo
echo "Results saved to:"
echo "$LOG_FILE"
echo
echo "=========================================================="
