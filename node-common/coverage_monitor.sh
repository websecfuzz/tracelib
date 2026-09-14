#!/bin/sh
set -u

INTERVAL="${INTERVAL:-60}"
SERVICE="${SERVICE:-nodebb}"
BITMAPS="${BITMAPS:-/dev/shm}"
APP_DIR="${APP_DIR:-/opt/nodebb}"

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "coverage_monitor: neither 'docker compose' nor 'docker-compose' found" >&2
    exit 1
fi

trap 'echo; echo "[coverage_monitor] stopped"; exit 0' INT TERM

echo "[coverage_monitor] polling every ${INTERVAL}s; service=${SERVICE} app_dir=${APP_DIR}"
while true; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== [$ts] coverage snapshot ==="
    $DC exec -T -w "$APP_DIR" -e NODE_V8_COVERAGE=/coverage/v8 "$SERVICE" \
        c8 report \
            --reporter=text-summary \
            --temp-directory /coverage/v8 \
        || echo "  (container not ready, or no coverage data yet)"

    n=$(find "$BITMAPS" -maxdepth 1 -type f -name 'wf-*' 2>/dev/null | wc -l)
    echo "  tracelib bitmaps on disk (wf-*): $n"

    sleep "$INTERVAL"
done
