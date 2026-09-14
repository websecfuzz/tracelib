#!/bin/sh

set -u

OUT="${OUT:?OUT (output dir) must be set}"
SERVICE="${SERVICE:-app}"
INTERVAL="${INTERVAL:-60}"
BITMAPS="${BITMAPS:-/dev/shm}"
WEBFUZZ_LOG="${WEBFUZZ_LOG:-}"
MODE_LABEL="${MODE_LABEL:-unknown}"
CSV_NAME="${CSV_NAME:-stats.csv}"
CSV_PATH="${CSV_PATH:-}"

if [ -n "$CSV_PATH" ]; then
    CSV="$CSV_PATH"
else
    CSV="$OUT/$CSV_NAME"
fi
COV_FILE="$OUT/external_coverage.txt"

mkdir -p "$OUT"

if [ ! -s "$CSV" ]; then
    echo "timestamp,elapsed_h,mode,webfuzz_requests,webfuzz_throughput_rps,coverage_pct,bitmaps_on_disk,coverage_covered,coverage_total,webfuzz_runtime,webfuzz_crawler_pending_urls,webfuzz_crawler_login_state,webfuzz_corpus_size" > "$CSV"
fi

t0=$(date +%s)

trap 'exit 0' INT TERM

while true; do
    now=$(date +%s)
    elapsed_h=$(awk -v now="$now" -v t0="$t0" 'BEGIN { printf "%.2f", (now - t0) / 3600.0 }')
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    : > "$COV_FILE"

    n_bm=$(find "$BITMAPS" -maxdepth 1 -type f -name 'wf-*' 2>/dev/null | wc -l)

    wf_req=""; wf_tp=""; wf_rt=""; wf_cp=""; wf_cl=""; wf_cs=""
    if [ -n "$WEBFUZZ_LOG" ] && [ -s "$WEBFUZZ_LOG" ]; then
        tail_block=$(tail -n 40 "$WEBFUZZ_LOG" 2>/dev/null)
        wf_req=$(echo "$tail_block" | awk '/^Total Requests:/ { v=$3 } END { print v }')
        wf_tp=$(echo  "$tail_block" | awk '/^Throughput:/    { v=$2 } END { print v }')
        wf_rt=$(echo "$tail_block" | awk '/^Runtime:/ { v=$2 } END { print v }')
        wf_cp=$(echo "$tail_block" | awk '/^Crawler Pending URLs:/ { v=$4 } END { print v }')
        wf_cl=$(echo "$tail_block" | awk '/^Crawler Login State:/ { v=$4 } END { print v }')
        wf_cs=$(echo "$tail_block" | awk '/^Corpus size:/ { v=$3 } END { print v }')
    fi

    printf '%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s\n' \
        "$ts" "$elapsed_h" "$MODE_LABEL" \
        "${wf_req:-}" "${wf_tp:-}" "" \
        "$n_bm" "" "" \
        "${wf_rt:-}" "${wf_cp:-}" "${wf_cl:-}" "${wf_cs:-}" \
        >> "$CSV"

    sleep "$INTERVAL"
done