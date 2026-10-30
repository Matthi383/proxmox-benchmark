#!/usr/bin/env bash

# ==========================================================
# Proxmox Benchmark
# Version: 1.1
#
# Tests:
#   - System information
#   - Network: DNS, ping and iperf2 (optional)
#   - pveperf
#   - 4K Random Mixed QD32 (70/30)
#   - Sequential Write QD16
#   - Sequential Read QD16
#   - 4K Random Write QD1
#   - 4K Random Read QD1
#   - FSYNC
#
# Usage:
#   ./proxmox-benchmark.sh [OPTIONS] NAME=PATH [NAME=PATH ...]
#
# Example:
#   ./proxmox-benchmark.sh \
#     --network-host 192.168.2.251 \
#     --network-port 4711 \
#     --dns-host fritz.box \
#     core=/mnt/pve/core forge=/mnt/pve/forge
#
# Use --no-network to skip network tests.
# ==========================================================

set -Eeuo pipefail

VERSION="1.1"

# Generic benchmark defaults; override them with command-line options.
RUNTIME=60
TEST_SIZE="2G"
FSYNC_SIZE="256M"
LOG_DIR="/root/ssd-benchmark-results"

# Network settings are deliberately not tied to a specific home network.
NETWORK_ENABLED=1
NETWORK_HOST=""
NETWORK_PORT=""
DNS_HOST=""
PING_COUNT=20
IPERF_DURATION=30
IPERF_INTERVAL=5
IPERF_PARALLEL=4

STORAGE_ARGS=()

usage() {
    cat <<EOF
Proxmox Benchmark v$VERSION

Usage:
  $0 [OPTIONS] NAME=PATH [NAME=PATH ...]

Storage arguments:
  NAME=PATH                 Storage label and directory to benchmark.
                            Example: core=/mnt/pve/core

Options:
  --network-host HOST       iperf2 server IP or hostname (required unless --no-network)
  --network-port PORT       iperf2 server TCP port (required unless --no-network)
  --dns-host HOST           Optional hostname for IPv4 DNS lookup, e.g. fritz.box
  --no-network              Skip DNS, ping and iperf2 tests

  --ping-count N            Number of ping packets (default: $PING_COUNT)
  --iperf-duration SEC      Duration of each iperf2 test (default: $IPERF_DURATION)
  --iperf-interval SEC      iperf2 reporting interval (default: $IPERF_INTERVAL)
  --iperf-parallel N        Number of parallel iperf2 streams (default: $IPERF_PARALLEL)

  --runtime SEC             Duration of each fio test (default: $RUNTIME)
  --test-size SIZE          fio test-file size (default: $TEST_SIZE)
  --fsync-size SIZE         fio FSYNC test size (default: $FSYNC_SIZE)
  --log-dir PATH            Directory for benchmark logs (default: $LOG_DIR)

  -h, --help                Show this help

Example:
  $0 --network-host 192.168.2.251 --network-port 4711 \\
     --dns-host fritz.box core=/mnt/pve/core forge=/mnt/pve/forge

  $0 --no-network --runtime 45 data=/mnt/pve/data
EOF
}

die() {
    echo "FEHLER: $*" >&2
    exit 1
}

# ----------------------------------------------------------
# Parse command-line arguments
# ----------------------------------------------------------

while (($#)); do
    case "$1" in
        --network-host)
            (($# >= 2)) || die "--network-host benötigt einen Wert."
            NETWORK_HOST="$2"; shift 2 ;;
        --network-port)
            (($# >= 2)) || die "--network-port benötigt einen Wert."
            NETWORK_PORT="$2"; shift 2 ;;
        --dns-host)
            (($# >= 2)) || die "--dns-host benötigt einen Wert."
            DNS_HOST="$2"; shift 2 ;;
        --no-network)
            NETWORK_ENABLED=0; shift ;;
        --ping-count)
            (($# >= 2)) || die "--ping-count benötigt einen Wert."
            PING_COUNT="$2"; shift 2 ;;
        --iperf-duration)
            (($# >= 2)) || die "--iperf-duration benötigt einen Wert."
            IPERF_DURATION="$2"; shift 2 ;;
        --iperf-interval)
            (($# >= 2)) || die "--iperf-interval benötigt einen Wert."
            IPERF_INTERVAL="$2"; shift 2 ;;
        --iperf-parallel)
            (($# >= 2)) || die "--iperf-parallel benötigt einen Wert."
            IPERF_PARALLEL="$2"; shift 2 ;;
        --runtime)
            (($# >= 2)) || die "--runtime benötigt einen Wert."
            RUNTIME="$2"; shift 2 ;;
        --test-size)
            (($# >= 2)) || die "--test-size benötigt einen Wert."
            TEST_SIZE="$2"; shift 2 ;;
        --fsync-size)
            (($# >= 2)) || die "--fsync-size benötigt einen Wert."
            FSYNC_SIZE="$2"; shift 2 ;;
        --log-dir)
            (($# >= 2)) || die "--log-dir benötigt einen Wert."
            LOG_DIR="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        --*)
            die "Unbekannte Option: $1 (siehe --help)" ;;
        *=*)
            STORAGE_ARGS+=("$1"); shift ;;
        *)
            die "Ungültiges Argument: $1 (erwartet wird NAME=PATH oder eine Option)" ;;
    esac
done

# ----------------------------------------------------------
# Validate arguments
# ----------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."

((${#STORAGE_ARGS[@]} > 0)) || {
    usage
    exit 1
}

if (( NETWORK_ENABLED )); then
    [[ -n "$NETWORK_HOST" ]] || die "Bitte --network-host angeben oder --no-network verwenden."
    [[ -n "$NETWORK_PORT" ]] || die "Bitte --network-port angeben oder --no-network verwenden."
    [[ "$NETWORK_PORT" =~ ^[0-9]+$ ]] || die "--network-port muss numerisch sein."
    (( NETWORK_PORT >= 1 && NETWORK_PORT <= 65535 )) || die "--network-port muss zwischen 1 und 65535 liegen."
fi

for VALUE_NAME in PING_COUNT IPERF_DURATION IPERF_INTERVAL IPERF_PARALLEL RUNTIME; do
    VALUE="${!VALUE_NAME}"
    [[ "$VALUE" =~ ^[0-9]+$ ]] || die "$VALUE_NAME muss eine positive Ganzzahl sein."
    (( VALUE > 0 )) || die "$VALUE_NAME muss größer als 0 sein."
done

command -v fio >/dev/null 2>&1 || die "fio ist nicht installiert. Installation: apt install fio"
command -v pveperf >/dev/null 2>&1 || die "pveperf wurde nicht gefunden."

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/benchmark-$TIMESTAMP.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "=========================================================="
echo " PROXMOX BENCHMARK v$VERSION"
echo "=========================================================="
echo "Datum:       $(date)"
echo "Host:        $(hostname)"
echo "Kernel:      $(uname -r)"
echo "fio:         $(fio --version)"
echo "fio runtime: ${RUNTIME}s"
echo "fio size:    $TEST_SIZE"
echo "FSYNC size:  $FSYNC_SIZE"
echo "Log:         $LOG_FILE"
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
lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket' || true

echo
echo "--- Memory ---"
free -h

echo
echo "--- Disks ---"
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS

# ----------------------------------------------------------
# Network benchmark
# ----------------------------------------------------------

if (( NETWORK_ENABLED )); then
    echo
    echo "=========================================================="
    echo " NETWORK BENCHMARK"
    echo "=========================================================="
    echo "Server: $NETWORK_HOST:$NETWORK_PORT"

    if [[ -n "$DNS_HOST" ]]; then
        echo
        echo ">>> DNS-Auflösung (IPv4): $DNS_HOST"
        if ! time getent ahostsv4 "$DNS_HOST"; then
            echo "DNS-Auflösung fehlgeschlagen – Netzwerkbenchmark wird fortgesetzt."
        fi
    fi

    echo
    echo ">>> Ping-Test ($PING_COUNT Pakete)"
    ping -c "$PING_COUNT" "$NETWORK_HOST" || echo "Ping-Test fehlgeschlagen."

    if command -v iperf >/dev/null 2>&1; then
        echo
        echo ">>> iperf2 Single-Stream (${IPERF_DURATION}s)"
        iperf -c "$NETWORK_HOST" -p "$NETWORK_PORT" \
            -t "$IPERF_DURATION" -i "$IPERF_INTERVAL" \
            || echo "Single-Stream-Test fehlgeschlagen."

        echo
        echo ">>> iperf2 Multi-Stream ($IPERF_PARALLEL Streams, ${IPERF_DURATION}s)"
        iperf -c "$NETWORK_HOST" -p "$NETWORK_PORT" \
            -t "$IPERF_DURATION" -i "$IPERF_INTERVAL" -P "$IPERF_PARALLEL" \
            || echo "Multi-Stream-Test fehlgeschlagen."
    else
        echo "iperf2 nicht installiert – iperf-Tests werden übersprungen."
    fi

    echo
    echo ">>> Netzwerkbenchmark abgeschlossen"
else
    echo
    echo "Netzwerkbenchmark durch --no-network deaktiviert."
fi

# ----------------------------------------------------------
# PVE performance - root
# ----------------------------------------------------------

echo
echo "=========================================================="
echo " PVE PERFORMANCE - ROOT"
echo "=========================================================="

pveperf /

# ----------------------------------------------------------
# Storage preparation
# ----------------------------------------------------------

declare -a STORAGE_NAMES=()
declare -a STORAGE_PATHS=()

for ARG in "${STORAGE_ARGS[@]}"; do
    NAME="${ARG%%=*}"
    PATH_STORAGE="${ARG#*=}"

    [[ -n "$NAME" && -n "$PATH_STORAGE" ]] || die "Name oder Pfad fehlt: $ARG"
    [[ -d "$PATH_STORAGE" ]] || die "Verzeichnis existiert nicht: $PATH_STORAGE"
    [[ -w "$PATH_STORAGE" ]] || die "Verzeichnis nicht beschreibbar: $PATH_STORAGE"

    AVAILABLE=$(df -BG --output=avail "$PATH_STORAGE" | tail -1 | tr -dc '0-9')
    (( AVAILABLE >= 4 )) || {
        echo "FEHLER: Zu wenig freier Speicher auf $PATH_STORAGE"
        echo "Mindestens 4 GB freier Speicher erforderlich."
        exit 1
    }

    STORAGE_NAMES+=("$NAME")
    STORAGE_PATHS+=("$PATH_STORAGE")
done

# ----------------------------------------------------------
# PVE performance per storage
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
        "$NAME-randrw-qd32" "$TEST_FILE" \
        --size="$TEST_SIZE" --rw=randrw --rwmixread=70 \
        --bs=4k --ioengine=libaio --iodepth=32 --direct=1

    # 2. Sequential Write QD16
    run_fio \
        "$NAME-seqwrite-qd16" "$TEST_FILE" \
        --size="$TEST_SIZE" --rw=write --bs=1M \
        --ioengine=libaio --iodepth=16 --direct=1

    # 3. Sequential Read QD16
    run_fio \
        "$NAME-seqread-qd16" "$TEST_FILE" \
        --size="$TEST_SIZE" --rw=read --bs=1M \
        --ioengine=libaio --iodepth=16 --direct=1

    # 4. 4K Random Write QD1
    run_fio \
        "$NAME-randwrite-qd1" "$TEST_FILE" \
        --size="$TEST_SIZE" --rw=randwrite --bs=4k \
        --ioengine=libaio --iodepth=1 --direct=1

    # 5. 4K Random Read QD1
    run_fio \
        "$NAME-randread-qd1" "$TEST_FILE" \
        --size="$TEST_SIZE" --rw=randread --bs=4k \
        --ioengine=libaio --iodepth=1 --direct=1

    # 6. FSYNC
    run_fio \
        "$NAME-fsync" "$TEST_FILE" \
        --size="$FSYNC_SIZE" --rw=write --bs=4k \
        --ioengine=psync --fdatasync=1 --direct=0

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
