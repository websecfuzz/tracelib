#!/bin/bash
set -u
log() { echo "[ebpf-sidecar] $*"; }

TRACELIB_PORT="${TRACELIB_PORT:-80}"
TRACELIB_HEADER="${TRACELIB_HEADER:-X-REQUEST-ID}"
TRACELIB_BACKEND="${TRACELIB_BACKEND:-ebpf}"
TRACELIB_COVERAGE_MODE="${TRACELIB_COVERAGE_MODE:-ngram}"

log "waiting for the app to listen on :$TRACELIB_PORT (shared netns)"
for _ in $(seq 1 900); do
    if ss -lnt "sport = :$TRACELIB_PORT" 2>/dev/null | grep -q LISTEN; then
        log "app is listening on :$TRACELIB_PORT"; break
    fi
    sleep 1
done
sleep 3

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

log "attaching tracelib_ebpf --port $TRACELIB_PORT --header $TRACELIB_HEADER --backend $TRACELIB_BACKEND --coverage-mode $TRACELIB_COVERAGE_MODE$TRACELIB_EXTRA"
exec tracelib_ebpf --port "$TRACELIB_PORT" --header "$TRACELIB_HEADER" \
                   --backend "$TRACELIB_BACKEND" \
                   --coverage-mode "$TRACELIB_COVERAGE_MODE" $TRACELIB_EXTRA
