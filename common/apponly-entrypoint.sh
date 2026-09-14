#!/bin/bash
set -u
log() { echo "[apponly-entrypoint] $*"; }

TRACELIB_PORT="${TRACELIB_PORT:-80}"
UPSTREAM_ENTRYPOINT="${UPSTREAM_ENTRYPOINT:-docker-entrypoint.sh}"

chmod 777 /coverage 2>/dev/null || log "warn: chmod 777 /coverage failed"
chmod 777 /dev/shm  2>/dev/null || log "warn: chmod 777 /dev/shm failed"
umask 000

[ "$#" -eq 0 ] && { log "no CMD given; nothing to run"; exit 1; }

if command -v "$UPSTREAM_ENTRYPOINT" >/dev/null 2>&1; then
    "$UPSTREAM_ENTRYPOINT" "$@" &
else
    log "no upstream entrypoint '$UPSTREAM_ENTRYPOINT' on PATH, execing CMD directly"
    "$@" &
fi
APP_PID=$!

cleanup() { kill "$APP_PID" 2>/dev/null || true; }
trap cleanup EXIT TERM INT
trap 'kill -USR1 "$APP_PID" 2>/dev/null || true' USR1

log "waiting for server to listen on :$TRACELIB_PORT"
while :; do
    if ss -lnt "sport = :$TRACELIB_PORT" 2>/dev/null | grep -q LISTEN; then
        log "server is listening on :$TRACELIB_PORT"; break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "app process exited before binding :$TRACELIB_PORT — giving up"
        wait "$APP_PID" 2>/dev/null || true; exit 1
    fi
    sleep 1
done

READY_MARKER="${APP_INIT_READY_MARKER:-/tmp/tracelib-app-ready}"
rm -f "$READY_MARKER" 2>/dev/null || true

if [ -x /app-init.sh ]; then
    log "running app-specific init: /app-init.sh"
    set -o pipefail
    if /app-init.sh 2>&1 | sed 's/^/[app-init] /'; then
        : > "$READY_MARKER"
    else
        log "/app-init.sh returned nonzero (continuing); NOT writing $READY_MARKER"
    fi
    set +o pipefail
else
    : > "$READY_MARKER"
fi

log "app ready — no tracer attached here; the eBPF sidecar attaches externally"
while kill -0 "$APP_PID" 2>/dev/null; do
    wait "$APP_PID" 2>/dev/null || true
done
