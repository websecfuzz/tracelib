#!/bin/bash

set -u

SHM_DIR="${SHM_DIR:-/dev/shm}"
AGE_MINUTES="${AGE_MINUTES:-5}"
INTERVAL="${INTERVAL:-30}"

trap 'exit 0' INT TERM

while true; do
    if [ -d "$SHM_DIR" ]; then
        find "$SHM_DIR" -mindepth 1 -maxdepth 1 -type f -mmin "+$AGE_MINUTES" -delete 2>/dev/null || true
    fi
    sleep "$INTERVAL"
done
