#!/bin/sh
set -u

INTERVAL="${INTERVAL:-60}"
SERVICE="${SERVICE:-wordpress}"
BITMAPS="${BITMAPS:-./bitmaps}"

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "coverage_monitor: neither 'docker compose' nor 'docker-compose' found" >&2
    exit 1
fi

trap 'echo; echo "[coverage_monitor] stopped"; exit 0' INT TERM

echo "[coverage_monitor] polling every ${INTERVAL}s; service=${SERVICE} bitmaps=${BITMAPS}"
while true; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== [$ts] coverage snapshot ==="
    $DC exec -T "$SERVICE" php /tracelib-support/coverage_report.php \
        || echo "  (container not ready, or no coverage data)"
    if [ -d "$BITMAPS" ]; then
        n=$(find "$BITMAPS" -maxdepth 1 -type f -name 'req-*' 2>/dev/null | wc -l)
        echo "  tracelib bitmaps on disk: $n"
    fi
    sleep "$INTERVAL"
done
