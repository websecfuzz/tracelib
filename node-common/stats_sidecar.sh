#!/bin/bash
set -u

OUT="${OUT:?OUT (output dir) must be set}"
SERVICE="${SERVICE:-nodebb}"
INTERVAL="${INTERVAL:-60}"
APP_DIR="${APP_DIR:-/opt/nodebb}"
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

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

if [ ! -s "$CSV" ]; then
    echo "timestamp,elapsed_h,mode,webfuzz_requests,webfuzz_throughput_rps,tracelib_edge_pct,bitmaps_on_disk,c8_lines_pct,c8_lines_covered,c8_lines_total,webfuzz_runtime,webfuzz_crawler_pending_urls,webfuzz_crawler_login_state,webfuzz_corpus_size" > "$CSV"
fi

t0=$(date +%s)

trap 'exit 0' INT TERM

while true; do
    now=$(date +%s)
    elapsed_h=$(awk -v now="$now" -v t0="$t0" 'BEGIN { printf "%.2f", (now - t0) / 3600.0 }')
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    c8_out="$($DC exec -T -w "$APP_DIR" -e NODE_V8_COVERAGE=/coverage/v8 "$SERVICE" \
        c8 report --reporter=text-summary --temp-directory /coverage/v8 2>/dev/null || true)"
    c8_line=$(echo "$c8_out" | awk '/^Lines/ { gsub("%",""); print $3; exit }')
    c8_frac=$(echo "$c8_out" | awk -F'[ (/)]+' '/^Lines/ { print $5","$6; exit }')
    c8_cov="${c8_frac%,*}"
    c8_tot="${c8_frac#*,}"
    : "${c8_line:=}"
    : "${c8_cov:=}"
    : "${c8_tot:=}"

    if [ -n "$c8_line" ]; then
        echo "$c8_line" > "$COV_FILE.tmp" && mv "$COV_FILE.tmp" "$COV_FILE"
    fi

    n_bm=$(find "$BITMAPS" -maxdepth 1 -type f -name 'wf-*' 2>/dev/null | wc -l)

    wf_req=""; wf_tp=""; wf_cov=""; wf_rt=""; wf_cp=""; wf_cl=""; wf_cs=""
    if [ -n "$WEBFUZZ_LOG" ] && [ -s "$WEBFUZZ_LOG" ]; then
        tail_block=$(tail -n 40 "$WEBFUZZ_LOG" 2>/dev/null)
        wf_req=$(echo "$tail_block" | awk '/^Total Requests:/ { v=$3 } END { print v }')
        wf_tp=$(echo  "$tail_block" | awk '/^Throughput:/    { v=$2 } END { print v }')
        wf_cov=$(echo "$tail_block" | awk '/^Total Coverage Score:/ { gsub("%","",$4); v=$4 } END { print v }')
        wf_rt=$(echo "$tail_block" | awk '/^Runtime:/ { v=$2 } END { print v }')
        wf_cp=$(echo "$tail_block" | awk '/^Crawler Pending URLs:/ { v=$4 } END { print v }')
        wf_cl=$(echo "$tail_block" | awk '/^Crawler Login State:/ { v=$4 } END { print v }')
        wf_cs=$(echo "$tail_block" | awk '/^Corpus size:/ { v=$3 } END { print v }')
    fi

    printf '%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s\n' \
        "$ts" "$elapsed_h" "$MODE_LABEL" \
        "${wf_req:-}" "${wf_tp:-}" "${wf_cov:-}" \
        "$n_bm" "${c8_line:-}" "${c8_cov:-}" "${c8_tot:-}" \
        "${wf_rt:-}" "${wf_cp:-}" "${wf_cl:-}" "${wf_cs:-}" \
        >> "$CSV"

    sleep "$INTERVAL"
done
