#!/bin/bash

set -u

log() { echo "[tracelib-ebpf-entrypoint] $*"; }

TRACELIB_PORT="${TRACELIB_PORT:-80}"
TRACELIB_HEADER="${TRACELIB_HEADER:-X-REQUEST-ID}"
UPSTREAM_ENTRYPOINT="${UPSTREAM_ENTRYPOINT:-docker-entrypoint.sh}"

chmod 777 /coverage 2>/dev/null || log "warn: chmod 777 /coverage failed"
chmod 777 /dev/shm  2>/dev/null || log "warn: chmod 777 /dev/shm failed"
umask 000

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

cleanup() {
    kill "$APP_PID" 2>/dev/null || true
    [ -n "${TRACELIB_PID:-}" ] && kill "$TRACELIB_PID" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

forward_usr1() { kill -USR1 "$APP_PID" 2>/dev/null || true; }
trap forward_usr1 USR1

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

sleep 2

TRACELIB_BACKEND="${TRACELIB_BACKEND:-ebpf}"
TRACELIB_COVERAGE_MODE="${TRACELIB_COVERAGE_MODE:-ngram}"

log "starting tracelib_ebpf on port $TRACELIB_PORT header $TRACELIB_HEADER backend $TRACELIB_BACKEND coverage-mode $TRACELIB_COVERAGE_MODE"

TRACELIB_EXTRA=""
[ "${TRACELIB_NO_ARG_HASH:-0}"    = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --no-arg-hash"
[ "${TRACELIB_NO_SQL:-0}"         = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --no-sql"
case "${TRACELIB_END_ON_STATUS_LINE:-}" in
    0|false|no)  TRACELIB_EXTRA="$TRACELIB_EXTRA --no-end-on-status-line" ;;
    1|true|yes)  TRACELIB_EXTRA="$TRACELIB_EXTRA --end-on-status-line" ;;
esac
[ "${TRACELIB_FILE_SQL_ONLY:-0}"  = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --file-sql-only"
[ "${TRACELIB_FILE_SQL_UNFILTERED:-0}" = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --file-sql-unfiltered"
[ "${TRACELIB_FILE_SQL_FILTERED:-0}" = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --bigram-file-sql-filtered"
[ "${TRACELIB_SYSCALL_FILTER:-0}" = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --syscall-filter"
[ "${TRACELIB_FILE_EDGES:-0}"     = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --file-edges"
[ "${TRACELIB_TOP_EDGES:-0}" != "0" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --top-edges ${TRACELIB_TOP_EDGES}"
[ "${TRACELIB_BIGRAM_FILE_SQL_SEPARATED:-0}" = "1" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --bigram-file-sql-separated"
[ -n "${TRACELIB_SEPARATED_MIN_HITS:-}" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --separated-min-hits ${TRACELIB_SEPARATED_MIN_HITS}"
[ -n "${TRACELIB_FILE_PATH_MONITORED:-${FILE_PATH_MONITORED:-}}" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --file-path-monitored ${TRACELIB_FILE_PATH_MONITORED:-$FILE_PATH_MONITORED}"
[ -n "${TRACELIB_EXCLUDED_FILE_PATH:-}" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --excluded-file-path ${TRACELIB_EXCLUDED_FILE_PATH}"
[ -n "${TRACELIB_RAW_TRACE_DIR:-}" ] && TRACELIB_EXTRA="$TRACELIB_EXTRA --raw-trace-dir ${TRACELIB_RAW_TRACE_DIR}"
[ -n "$TRACELIB_EXTRA" ] && log "tracelib_ebpf flags:$TRACELIB_EXTRA"

tracelib_ebpf --port "$TRACELIB_PORT" --header "$TRACELIB_HEADER" --backend "$TRACELIB_BACKEND" \
              --coverage-mode "$TRACELIB_COVERAGE_MODE" $TRACELIB_EXTRA &
TRACELIB_PID=$!

while kill -0 "$APP_PID" 2>/dev/null && kill -0 "$TRACELIB_PID" 2>/dev/null; do
    wait -n "$APP_PID" "$TRACELIB_PID" 2>/dev/null || true
done
log "app or tracelib_ebpf exited — shutting down"
