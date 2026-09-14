#!/usr/bin/env bash

set -u
set -o pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$REPO/ebpf/tracelib"
PORT=59999
TIMEOUT=25

case "${1:-bigram_file_sql_filtered}" in
    bigram_file_sql_filtered) MODE_ARGS=(--coverage-mode bigram --bigram-file-sql-filtered) ;;
    bigram_separated)         MODE_ARGS=(--coverage-mode bigram --bigram-file-sql-separated) ;;
    file_sql_unfiltered)      MODE_ARGS=(--coverage-mode bigram --file-sql-unfiltered) ;;
    bigram)                   MODE_ARGS=(--coverage-mode bigram) ;;
    ngram)                    MODE_ARGS=(--coverage-mode ngram) ;;
    *) echo "verify-bpf: unknown mode '${1}'" >&2; exit 2 ;;
esac

[ -x "$BIN" ] || { echo "verify-bpf: $BIN not built (run: make -C $REPO/ebpf EBPF=1)" >&2; exit 2; }

if [ -z "${CLANG:-}" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
echo "verify-bpf: compiling BPF object with $($CLANG --version | head -1)"
case "$($CLANG --version | head -1)" in
    *"version 19"*) : ;;
    *) echo "verify-bpf: WARNING -- the campaign images build with clang 19."
       echo "  A verdict from a different LLVM version does not transfer."
       echo "  Install it with: sudo apt-get install -y clang-19" ;;
esac
( cd "$REPO/ebpf" && CLANG="$CLANG" make EBPF=1 ) >/dev/null 2>&1     || { echo "verify-bpf: EBPF=1 build failed" >&2; exit 2; }

LOG="$(mktemp /tmp/verify-bpf.XXXXXXXX.log)" || { echo "verify-bpf: cannot create log" >&2; exit 2; }
chmod 0644 "$LOG" 2>/dev/null || true
: > "$LOG" || { echo "verify-bpf: log $LOG is not writable" >&2; exit 2; }

TRACELIB_EXCLUDED_FILE_PATH="${TRACELIB_EXCLUDED_FILE_PATH-temp,cache,debugbar,tmp,sessions,images}" \
TRACELIB_FILE_PATH_MONITORED="${TRACELIB_FILE_PATH_MONITORED:-/var/www}" \
timeout -s KILL "$TIMEOUT" "$BIN" --backend ebpf --port "$PORT" "${MODE_ARGS[@]}" \
    >"$LOG" 2>&1 &
pid=$!

verdict=""
for _ in $(seq 1 $((TIMEOUT * 2))); do
    if grep -q "eBPF is unavailable on this host" "$LOG"; then
        verdict="unavailable"; break
    fi
    if grep -qE "failed to load|too large|verify failed|backend 'ebpf' failed" "$LOG"; then
        verdict="rejected"; break
    fi
    if grep -qE "backend 'ebpf' (started|ready)|attached|waiting for" "$LOG"; then
        verdict="loaded"; break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
done

kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

case "$verdict" in
    loaded)
        echo "verify-bpf: OK -- verifier accepted the program"
        exit 0 ;;
    unavailable)
        echo "verify-bpf: CANNOT TEST -- eBPF backend unavailable, so nothing was verified."
        echo "  Needs BOTH: a build with EBPF=1, and CAP_BPF/CAP_PERFMON (run under sudo)."
        grep -E "^\[tracelib\]\[err\]" "$LOG" | tail -4
        exit 2 ;;
    rejected)
        echo "verify-bpf: REJECTED"
        grep -vE "^[0-9]+: \(" "$LOG" | grep -vE "^; " | tail -25
        echo "--- full log: $LOG ---"
        exit 1 ;;
    *)
        echo "verify-bpf: no verdict within ${TIMEOUT}s -- collector output follows"
        tail -15 "$LOG"
        exit 1 ;;
esac
