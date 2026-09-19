#!/bin/bash
#
# truenas-sata-sas-spindown-timer.sh v1.0.0
#
# SAS + SATA Disk Spin-down Timer (TrueNAS safe)
# Monitors disk power state WITHOUT unnecessarily waking SAS drives.
# Uses kernel I/O counters (/sys/block/<disk>/stat) to detect real activity
# (does NOT spin up disks) and only spins down after TIMEOUT seconds without I/O.
#
# Usage:
#   ./truenas-sata-sas-spindown-timer.sh [-h] [-m] [-i <disk>] [-t <timeout>] [-p <poll>] [-o] [-c]
#
# Options:
#   -t TIMEOUT   : Idle time in seconds before spin-down (default: 3600)
#   -p POLL_TIME : Poll interval in seconds (default: 600)
#   -m           : Manual mode (only monitor disks given via -i; can be repeated)
#   -i <disk>    : Disk to monitor (e.g. sda, sdg). Repeatable.
#   -o           : One-shot mode (run one poll cycle and exit)
#   -c           : Check mode (prints status each poll; still performs spin-down!)
#   -h           : Help
#

# -----------------------
# Prevent multiple instances
# -----------------------
command -v flock >/dev/null 2>&1 || {
  echo "flock not found (util-linux). Exiting."
  exit 1
}

LOCKFILE="/var/run/truenas-sata-sas-spindown-timer.lock"
exec 9>"$LOCKFILE" || exit 1
flock -n 9 || {
  echo "Another instance is already running. Exiting."
  exit 0
}

TIMEOUT=3600
POLL_TIME=600
MANUAL_MODE=false
ONE_SHOT=false
CHECK_MODE=false
DISKS=()

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

usage() {
    grep '^#' "$0" | sed 's/^#//'
}

while getopts "hmot:p:i:c" opt; do
    case $opt in
        h) usage; exit 0 ;;
        m) MANUAL_MODE=true ;;
        o) ONE_SHOT=true ;;
        t) TIMEOUT=$OPTARG ;;
        p) POLL_TIME=$OPTARG ;;
        i) DISKS+=("$OPTARG") ;;
        c) CHECK_MODE=true ;;
        *) usage; exit 1 ;;
    esac
done

# -----------------------
# Auto detect disks
# -----------------------
if [ "$MANUAL_MODE" = false ]; then
    mapfile -t DISKS < <(ls /sys/block | grep '^sd')
fi

if [ ${#DISKS[@]} -eq 0 ]; then
    log "No disks detected. Exiting."
    exit 1
fi

log "Monitoring disks: ${DISKS[*]}"
log "Idle timeout: $TIMEOUT seconds, Poll interval: $POLL_TIME seconds"
[ "$CHECK_MODE" = true ] && log "Check mode enabled - will output status each poll interval (spin-down still active)"

disk_path() {
    echo "/dev/$1"
}

# -----------------------
# Disk power state check (SAS-safe; should not spin up)
# Returns: STANDBY or ACTIVE
# -----------------------
disk_state() {
    local disk="$1"
    local output

    output=$(sudo smartctl -i --nocheck standby "$(disk_path "$disk")" 2>&1)
    if echo "$output" | grep -q "STANDBY"; then
        echo "STANDBY"
    else
        echo "ACTIVE"
    fi
}

# -----------------------
# Disk I/O counter (does NOT spin up)
# Uses /sys/block/<disk>/stat: field1=reads completed, field5=writes completed
# Returns a monotonically increasing integer (reads+writes), or empty on error.
# -----------------------
disk_io() {
    awk '{print $1+$5}' "/sys/block/$1/stat" 2>/dev/null
}

declare -A LAST_ACTIVE
declare -A PREV_IO

# -----------------------
# Initialize timers and previous I/O
# -----------------------
now_init=$(date +%s)
for d in "${DISKS[@]}"; do
    LAST_ACTIVE[$d]=$now_init
    PREV_IO[$d]=$(disk_io "$d")
done

# -----------------------
# Main loop
# -----------------------
while true; do
    now=$(date +%s)

    for d in "${DISKS[@]}"; do
        state=$(disk_state "$d")

        # Detect real activity via kernel I/O counters
        current_io=$(disk_io "$d")
        if [[ -n "$current_io" && "$current_io" != "${PREV_IO[$d]}" ]]; then
            # I/O happened since last poll -> reset idle timer
            LAST_ACTIVE[$d]=$now
            PREV_IO[$d]=$current_io
        fi

        idle_time=$(( now - LAST_ACTIVE[$d] ))

        # Spin down if timeout reached and disk not already in standby
        if [[ "$state" != "STANDBY" && $idle_time -ge $TIMEOUT ]]; then
            log "Disk $d idle for $idle_time s - spinning down"
            sudo smartctl -s standby,now "$(disk_path "$d")"
            # Reset timer after issuing spindown
            LAST_ACTIVE[$d]=$now
            # Refresh I/O baseline (still does not spin up)
            PREV_IO[$d]=$(disk_io "$d")
            state="STANDBY"
        fi

        # Status output per poll if enabled
        if [ "$CHECK_MODE" = true ]; then
            log "Disk $d status: $state (idle $idle_time s, io=${current_io:-?})"
        fi
    done

    [ "$ONE_SHOT" = true ] && break
    sleep "$POLL_TIME"
done
