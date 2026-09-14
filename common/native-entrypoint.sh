#!/bin/bash

set -u

log() { echo "[native-entrypoint] $*"; }

TRACELIB_PORT="${TRACELIB_PORT:-8081}"
UPSTREAM_ENTRYPOINT="${UPSTREAM_ENTRYPOINT:-docker-entrypoint.sh}"

if [ "$#" -eq 0 ]; then
    log "no CMD given; nothing to run"
    exit 1
fi

if command -v "$UPSTREAM_ENTRYPOINT" >/dev/null 2>&1; then
    "$UPSTREAM_ENTRYPOINT" "$@" &
else
    log "no upstream entrypoint '$UPSTREAM_ENTRYPOINT' on PATH, execing CMD directly"
    "$@" &
fi
APP_PID=$!

cleanup() { kill "$APP_PID" 2>/dev/null || true; }
trap cleanup EXIT TERM INT

log "waiting for server to listen on :$TRACELIB_PORT"
while :; do
    if ss -lnt "sport = :$TRACELIB_PORT" 2>/dev/null | grep -q LISTEN; then
        log "server is listening on :$TRACELIB_PORT"
        break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "app process exited before binding :$TRACELIB_PORT — giving up"
        wait "$APP_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

if [ -x /app-init.sh ]; then
    log "running app-specific init: /app-init.sh"
    /app-init.sh 2>&1 | sed 's/^/[app-init] /' || log "/app-init.sh returned nonzero (continuing)"
fi

wait "$APP_PID"
