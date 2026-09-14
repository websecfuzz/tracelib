#!/usr/bin/env bash

set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CAMPAIGN_RUNNER="${CAMPAIGN_RUNNER:-$ROOT/eval/run_campaign_v6.sh}"
DOCKER=( sudo -n /usr/bin/docker )
export TRACELIB_NOVELTY=index

PHP_APPS=(
    wordpress
    hotcrp
    phpbb
    joomla
    bagisto
    drupal
    prestashop
    zencart
)
NONPHP_APPS=(
    ghost
    redmine
    gogs
    huginn
    superset
    wikijs
    petclinic
    roller
)
DEFAULT_APPS=( "${PHP_APPS[@]}" "${NONPHP_APPS[@]}" )

DEFAULT_PHP_MODES="tracelib_bigram_file_sql_filtered tracelib_ebpf_simple native blackbox tracelib_ebpf"
DEFAULT_NONPHP_MODES="tracelib_bigram_file_sql_filtered tracelib_ebpf_simple blackbox tracelib_ebpf"

TOTAL_TIME_BUDGET="${TOTAL_TIME_BUDGET:-7200}"
ENDPOINT_TIME_BUDGET="${ENDPOINT_TIME_BUDGET:-720}"
ENDPOINTS_PER_APP="${ENDPOINTS_PER_APP:-10}"
BLEND_ENDPOINTS="${BLEND_ENDPOINTS:-1}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-2}"
STATS_POLL_INTERVAL="${STATS_POLL_INTERVAL:-1}"
MODE_GRACE_SECONDS="${MODE_GRACE_SECONDS:-180}"
JOBS="${CONCURRENT_CAMPAIGNS:-${JOBS:-4}}"
NONPHP_COVERAGE_FINAL_ONLY="${NONPHP_COVERAGE_FINAL_ONLY:-1}"
COVERAGE_SAMPLE_TIMEOUT="${COVERAGE_SAMPLE_TIMEOUT:-120}"
BLACKBOX_CORPUS_MODE="${BLACKBOX_CORPUS_MODE:-keep-submitted}"
BLACKBOX_MAX_CORPUS_SIZE="${BLACKBOX_MAX_CORPUS_SIZE:-50000}"
export BLACKBOX_MAX_CORPUS_SIZE
STOP_ONGOING="${STOP_ONGOING:-1}"
RESUME="${RESUME:-1}"
VERIFY_ENDPOINTS="${VERIFY_ENDPOINTS:-1}"
VALIDATE_ONLY="${VALIDATE_ONLY:-0}"
MAX_CORPUS_SIZE="${MAX_CORPUS_SIZE:-0}"
FUZZ_REQUEST_BUDGET="${FUZZ_REQUEST_BUDGET:-0}"
ALLOW_NON_HTML="${ALLOW_NON_HTML:-1}"
PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
NODE_COVERAGE_INTERVAL_MS="${NODE_COVERAGE_INTERVAL_MS:-30000}"
NODE_COVERAGE_TAKE_ON_RESPONSE="${NODE_COVERAGE_TAKE_ON_RESPONSE:-0}"
CAMPAIGN_RUN_ID="${CAMPAIGN_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_DIR="${RESULT_DIR:-$ROOT/eval_result_single_endpoint/$CAMPAIGN_RUN_ID}"
ENDPOINT_SOURCE_DIR="${ENDPOINT_SOURCE_DIR:-$HERE/default_endpoints}"
RUNLOG_DIR="$RESULT_DIR/campaign_logs"
ENDPOINT_DIR="$RESULT_DIR/endpoints"
MATRIX_CSV="$RESULT_DIR/single_endpoint_matrix.csv"
DRY_RUN=0

if [ -n "${MODES:-}" ]; then
    PHP_MODE_LIST="$MODES"
    NONPHP_MODE_LIST="$MODES"
else
    PHP_MODE_LIST="${PHP_MODES:-$DEFAULT_PHP_MODES}"
    NONPHP_MODE_LIST="${NONPHP_MODES:-$DEFAULT_NONPHP_MODES}"
fi
APPS_STR="${APPS:-${DEFAULT_APPS[*]}}"

usage() {
    sed -n '2,17p' "$0"
    cat <<EOF

Options:
  -j, --jobs N              Concurrent application drivers (default: $JOBS)
      --apps APP...         Application list
      --modes MODE...       Global mode list; native is filtered for non-PHP
      --php-modes LIST      PHP mode list
      --nonphp-modes LIST   Non-PHP mode list
                            tracelib_bigram aliases tracelib_ebpf_simple
      --endpoint-time-budget N
                            Seconds per endpoint in sequential mode (default: $ENDPOINT_TIME_BUDGET)
      --total-time-budget N
                            Seconds for the full blended endpoint campaign (default: $TOTAL_TIME_BUDGET)
      --endpoints-per-app N Endpoint count written for each app (default: $ENDPOINTS_PER_APP)
      --blend-endpoints     Seed all selected endpoints into one campaign for each app/mode (default)
      --sequential-endpoints
                            Fuzz selected endpoints one by one
      --endpoint-source-dir DIR
                            Directory containing default endpoint files named APP.txt
      --sample-interval N   Coverage sample interval in seconds (default: $SAMPLE_INTERVAL)
      --nonphp-coverage-every-sample
                            Run non-PHP coverage reporters at every sample instead of final-only
      --coverage-sample-timeout N
                            Maximum seconds for one platform coverage report (default: $COVERAGE_SAMPLE_TIMEOUT)
      --blackbox-corpus-mode MODE
                            BlackBox corpus policy: keep-submitted (default) or seed-only
      --result-dir DIR      Output directory
      --no-stop-ongoing     Do not kill existing campaign processes/containers first
      --no-verify           Skip pre-fuzz endpoint validation
      --validate-only       Start apps, run authenticated endpoint validation, then stop
      --no-resume           Re-run cells even if summaries already exist
      --dry-run             Print matrix and endpoint files only
  -h, --help                Show this help

Outputs:
  Per-cell coverage CSVs:      RESULT_DIR/*_<app>_<mode>_t0h_*.csv
  Per-endpoint coverage CSVs:  RESULT_DIR/*_<app>_<mode>_t0h_*.endpoint_coverage.csv
  Endpoint validation CSVs:    RESULT_DIR/*_<app>_<mode>_t0h_*.endpoints.csv
  Matrix CSV:                  RESULT_DIR/single_endpoint_matrix.csv
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -j|--jobs) JOBS="$2"; shift 2 ;;
        --apps)
            shift; APPS_STR=""
            while [ "$#" -gt 0 ] && [ "x${1#-}" = "x$1" ]; do
                APPS_STR="${APPS_STR:+$APPS_STR }$1"; shift
            done
            [ -n "$APPS_STR" ] || { echo "ERROR: --apps needs at least one value" >&2; exit 2; } ;;
        --modes)
            shift; PHP_MODE_LIST=""; NONPHP_MODE_LIST=""
            while [ "$#" -gt 0 ] && [ "x${1#-}" = "x$1" ]; do
                PHP_MODE_LIST="${PHP_MODE_LIST:+$PHP_MODE_LIST }$1"
                NONPHP_MODE_LIST="${NONPHP_MODE_LIST:+$NONPHP_MODE_LIST }$1"
                shift
            done
            [ -n "$PHP_MODE_LIST" ] || { echo "ERROR: --modes needs at least one value" >&2; exit 2; } ;;
        --php-modes) PHP_MODE_LIST="$2"; shift 2 ;;
        --nonphp-modes) NONPHP_MODE_LIST="$2"; shift 2 ;;
        --endpoint-time-budget) ENDPOINT_TIME_BUDGET="$2"; shift 2 ;;
        --total-time-budget) TOTAL_TIME_BUDGET="$2"; shift 2 ;;
        --endpoints-per-app) ENDPOINTS_PER_APP="$2"; shift 2 ;;
        --blend-endpoints) BLEND_ENDPOINTS=1; shift ;;
        --sequential-endpoints) BLEND_ENDPOINTS=0; shift ;;
        --endpoint-source-dir) ENDPOINT_SOURCE_DIR="$2"; shift 2 ;;
        --sample-interval)
            SAMPLE_INTERVAL="$2"
            shift 2 ;;
        --nonphp-coverage-every-sample) NONPHP_COVERAGE_FINAL_ONLY=0; shift ;;
        --coverage-sample-timeout) COVERAGE_SAMPLE_TIMEOUT="$2"; shift 2 ;;
        --blackbox-corpus-mode) BLACKBOX_CORPUS_MODE="$2"; shift 2 ;;
        --result-dir) RESULT_DIR="$2"; RUNLOG_DIR="$RESULT_DIR/campaign_logs"; ENDPOINT_DIR="$RESULT_DIR/endpoints"; MATRIX_CSV="$RESULT_DIR/single_endpoint_matrix.csv"; shift 2 ;;
        --no-stop-ongoing) STOP_ONGOING=0; shift ;;
        --no-verify) VERIFY_ENDPOINTS=0; shift ;;
        --validate-only) VALIDATE_ONLY=1; VERIFY_ENDPOINTS=1; shift ;;
        --no-resume) RESUME=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "ERROR: unknown option '$1'" >&2; exit 2 ;;
        *) APPS_STR="${APPS_STR:+$APPS_STR }$1"; shift ;;
    esac
done

is_php_app() {
    case "$1" in
        wordpress|hotcrp|phpbb|joomla|bagisto|drupal|prestashop|zencart) return 0 ;;
        *) return 1 ;;
    esac
}

is_nonphp_app() {
    case "$1" in
        ghost|redmine|gogs|huginn|superset|wikijs|petclinic|roller) return 0 ;;
        *) return 1 ;;
    esac
}

runtime_for_app() {
    case "$1" in
        ghost|wikijs) echo node ;;
        gogs) echo go ;;
        redmine|huginn) echo ruby ;;
        superset) echo python ;;
        petclinic|roller) echo java ;;
        *) echo php ;;
    esac
}

port_for_app() {
    case "$1" in
        ghost) echo 2368 ;;
        wordpress) echo 8081 ;;
        hotcrp) echo 8087 ;;
        redmine) echo 8088 ;;
        phpbb) echo 8089 ;;
        joomla) echo 8090 ;;
        bagisto) echo 8093 ;;
        zencart) echo 8094 ;;
        drupal) echo 8095 ;;
        gogs) echo 8091 ;;
        huginn) echo 8092 ;;
        superset) echo 8096 ;;
        wikijs) echo 8097 ;;
        petclinic) echo 8098 ;;
        roller) echo 8099 ;;
        prestashop) echo 8100 ;;
    esac
}

is_supported_mode() {
    case "$1" in
        native|tracelib_ebpf|tracelib_bigram|tracelib_ebpf_simple|blackbox) return 0 ;;
        tracelib_bigram_file_sql_filtered) return 0 ;;
        *) return 1 ;;
    esac
}

canonical_mode() {
    case "$1" in
        tracelib_bigram) printf '%s\n' tracelib_ebpf_simple ;;
        *) printf '%s\n' "$1" ;;
    esac
}

require_positive_integer() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $name must be a positive integer (got '$value')" >&2
        return 1
    fi
}

require_nonnegative_integer() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $name must be a non-negative integer (got '$value')" >&2
        return 1
    fi
}

require_boolean() {
    local name="$1" value="$2"
    case "$value" in
        0|1) ;;
        *) echo "ERROR: $name must be 0 or 1 (got '$value')" >&2; return 1 ;;
    esac
}

filter_native_mode() {
    local mode
    for mode in "$@"; do
        [ "$mode" = "native" ] || printf '%s\n' "$mode"
    done
}

endpoint_paths_for_app() {
    local app="$1" source_file="$ENDPOINT_SOURCE_DIR/$1.txt"
    [ -r "$source_file" ] || {
        echo "ERROR: endpoint source file is not readable for $app: $source_file" >&2
        return 1
    }
    awk '
        /^[[:space:]]*(#|$)/ { next }
        { print; count += 1 }
        count >= limit { exit }
    ' limit="$ENDPOINTS_PER_APP" "$source_file"
}

write_endpoint_file() {
    local app="$1" file="$2" base_url path count
    base_url="http://localhost:$(port_for_app "$app")"
    mkdir -p "$(dirname "$file")"
    : > "$file"
    count=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            http://*|https://*) printf '%s\n' "$path" >> "$file" ;;
            /*) printf '%s%s\n' "$base_url" "$path" >> "$file" ;;
            *) printf '%s/%s\n' "$base_url" "$path" >> "$file" ;;
        esac
        count=$((count + 1))
    done < <(endpoint_paths_for_app "$app")
    if [ "$count" -ne "$ENDPOINTS_PER_APP" ]; then
        echo "ERROR: $app endpoint list has $count entries, expected $ENDPOINTS_PER_APP" >&2
        return 1
    fi
}

selected_modes_for_app() {
    local app="$1" mode canonical
    local -a raw=()
    if is_php_app "$app"; then
        read -r -a raw <<< "$PHP_MODE_LIST"
    else
        read -r -a raw <<< "$NONPHP_MODE_LIST"
        mapfile -t raw < <(filter_native_mode "${raw[@]}")
    fi
    for mode in "${raw[@]}"; do
        [ -n "$mode" ] || continue
        is_supported_mode "$mode" || { echo "ERROR: unsupported mode '$mode'" >&2; return 2; }
        canonical="$(canonical_mode "$mode")"
        printf '%s\n' "$canonical"
    done
}

latest_file_since() {
    local pattern="$1" started_epoch="$2"
    find "$RESULT_DIR" -maxdepth 1 -type f \
        -name "$pattern" -newermt "@$started_epoch" \
        -printf '%T@\t%p\n' 2>/dev/null \
        | sort -nr \
        | sed -n $'1{s/^[^\t]*\t//;p;}'
}

latest_coverage_csv_since() {
    local pattern="$1" started_epoch="$2"
    find "$RESULT_DIR" -maxdepth 1 -type f \
        -name "$pattern" \
        ! -name '*.endpoints.csv' \
        ! -name '*.endpoint_coverage.csv' \
        -newermt "@$started_epoch" \
        -printf '%T@\t%p\n' 2>/dev/null \
        | sort -nr \
        | sed -n $'1{s/^[^\t]*\t//;p;}'
}

summary_value() {
    local file="$1" key="$2"
    [ -s "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key {print $2; exit}' "$file"
}

init_matrix_csv() {
    mkdir -p "$RESULT_DIR"
    if [ ! -s "$MATRIX_CSV" ]; then
        printf '%s\n' "timestamp,app,runtime,mode,endpoint_schedule,endpoint_count,endpoint_time_budget_s,total_time_budget_s,sample_interval_s,return_code,wall_seconds,coverage_csv,summary_file,endpoint_validation_csv,endpoint_coverage_csv,final_elapsed_s,final_coverage_pct,final_coverage_covered,final_coverage_total,final_fuzz_requests,completion_reason" > "$MATRIX_CSV"
    fi
}

append_matrix_row() {
    local app="$1" mode="$2" runtime="$3" endpoint_count="$4" endpoint_budget="$5" total_budget="$6" rc="$7" wall="$8" csv="$9" summary="${10}" endpoint_csv="${11}" endpoint_coverage_csv="${12}"
    local final_row final_elapsed final_pct final_covered final_total final_fuzz reason
    final_elapsed=""; final_pct=""; final_covered=""; final_total=""; final_fuzz=""
    if [ -s "$csv" ]; then
        final_row="$(tail -n 1 "$csv")"
        IFS=, read -r _ts final_elapsed _elapsed_h _host _app _runtime _mode _cov_source final_pct final_covered final_total _req _tp _corpus _pending _rt _signals _phase final_fuzz _fuzz_started _fz_elapsed _crawl _login_state _login_calls <<< "$final_row"
    fi
    reason="$(summary_value "$summary" completion_reason)"
    {
        flock 9
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$app" "$runtime" "$mode" "$([ "$BLEND_ENDPOINTS" = "1" ] && echo blend || echo sequential)" "$endpoint_count" \
            "$endpoint_budget" "$total_budget" "$SAMPLE_INTERVAL" "$rc" "$wall" \
            "$csv" "$summary" "$endpoint_csv" "$endpoint_coverage_csv" \
            "${final_elapsed:-}" "${final_pct:-}" "${final_covered:-}" "${final_total:-}" \
            "${final_fuzz:-}" "${reason:-}"
    } 9>>"$MATRIX_CSV.lock" >> "$MATRIX_CSV"
}

write_endpoint_coverage() {
    local app="$1" mode="$2" runtime="$3" endpoint_file="$4" coverage_csv="$5" summary="$6" output_csv="$7"
    [ -s "$coverage_csv" ] || return 0
    [ -s "$endpoint_file" ] || return 0

    python3 - "$app" "$mode" "$runtime" "$endpoint_file" "$coverage_csv" "$summary" "$output_csv" "$ENDPOINT_TIME_BUDGET" "$([ "$BLEND_ENDPOINTS" = "1" ] && echo blend || echo sequential)" <<'PY'
import csv
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

app, mode, runtime, endpoint_file, coverage_csv, summary_file, output_csv, endpoint_budget, endpoint_schedule = sys.argv[1:]
endpoint_budget = int(endpoint_budget)

ansi = re.compile(r"\x1b\[[0-9;]*m")
log_ts = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(\d+)\]")
start_re = re.compile(r"Starting endpoint ([0-9]+)/([0-9]+).*?: ([A-Z]+) (.+)$")
complete_re = re.compile(
    r"Completed endpoint ([0-9]+)/([0-9]+)( early due to lack of fuzz targets)?; "
    r"campaign coverage is ([0-9.]+)%"
)

def read_summary(path):
    values = {}
    p = Path(path)
    if not p.is_file():
        return values
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values

def parse_csv_epoch(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None

def parse_log_epoch(line):
    match = log_ts.match(line)
    if not match:
        return None
    dt = datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S")
    return time.mktime(dt.timetuple()) + (int(match.group(2)) / 1000.0)

def iso_utc(epoch):
    if epoch is None:
        return ""
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def number(value):
    try:
        return float(value)
    except Exception:
        return None

def integer(value):
    try:
        return int(float(value))
    except Exception:
        return None

endpoints = [
    line.strip()
    for line in Path(endpoint_file).read_text(encoding="utf-8", errors="replace").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]

coverage_rows = []
with Path(coverage_csv).open(newline="", encoding="utf-8", errors="replace") as handle:
    for row in csv.DictReader(handle):
        epoch = parse_csv_epoch(row.get("timestamp", ""))
        if epoch is None:
            continue
        coverage_rows.append((epoch, row))

summary = read_summary(summary_file)
stem = summary.get("stem") or Path(coverage_csv).stem
fuzzer_log = Path(coverage_csv).with_name(stem + ".fuzzer.log")
starts = {}
completions = {}

if fuzzer_log.is_file():
    for raw_line in fuzzer_log.read_text(encoding="utf-8", errors="replace").splitlines():
        line = ansi.sub("", raw_line)
        epoch = parse_log_epoch(line)
        start = start_re.search(line)
        if start:
            idx = int(start.group(1))
            starts[idx] = {
                "epoch": epoch,
                "url": start.group(4).strip(),
            }
            continue
        complete = complete_re.search(line)
        if complete:
            idx = int(complete.group(1))
            completions[idx] = {
                "epoch": epoch,
                "reason": "empty_queue" if complete.group(3) else "endpoint_time_budget",
                "webfuzz_internal_coverage_pct": complete.group(4),
            }

def row_at_or_before(cutoff_epoch):
    if not coverage_rows:
        return {}
    if cutoff_epoch is None:
        return coverage_rows[-1][1]
    chosen = None
    for epoch, row in coverage_rows:
        if epoch <= cutoff_epoch + 1.0:
            chosen = row
        else:
            break
    if chosen is not None:
        return chosen
    return coverage_rows[0][1]

rows = []
if endpoint_schedule == "blend":
    first_epoch = coverage_rows[0][0] if coverage_rows else None
    final_epoch = coverage_rows[-1][0] if coverage_rows else None
    sample = coverage_rows[-1][1] if coverage_rows else {}
    for idx, endpoint in enumerate(endpoints, start=1):
        rows.append({
            "app": app,
            "runtime": runtime,
            "mode": mode,
            "endpoint_schedule": endpoint_schedule,
            "endpoint_index": idx,
            "endpoint_total": len(endpoints),
            "endpoint_url": endpoint,
            "start_iso": iso_utc(first_epoch),
            "completion_iso": iso_utc(final_epoch),
            "completion_reason": "blend_campaign_final",
            "sample_elapsed_s": sample.get("elapsed_s", ""),
            "coverage_pct": sample.get("coverage_pct", ""),
            "coverage_covered": sample.get("coverage_covered", ""),
            "coverage_total": sample.get("coverage_total", ""),
            "coverage_delta_pct": "",
            "coverage_delta_covered": "",
            "total_requests": sample.get("total_requests", ""),
            "fuzz_requests": sample.get("fuzz_requests", ""),
            "webfuzz_internal_coverage_pct": "",
        })
else:
    previous_pct = None
    previous_covered = None
    last_known_completion = None
    for idx, endpoint in enumerate(endpoints, start=1):
        start_epoch = starts.get(idx, {}).get("epoch")
        if start_epoch is None and idx == 1 and coverage_rows:
            start_epoch = coverage_rows[0][0]
        if start_epoch is None and last_known_completion is not None:
            start_epoch = last_known_completion

        completion = completions.get(idx, {})
        completion_epoch = completion.get("epoch")
        reason = completion.get("reason", "")
        if completion_epoch is None and start_epoch is not None and endpoint_budget > 0:
            completion_epoch = start_epoch + endpoint_budget
            reason = "estimated_endpoint_budget"
        if completion_epoch is not None:
            last_known_completion = completion_epoch

        sample = row_at_or_before(completion_epoch)
        pct = sample.get("coverage_pct", "")
        covered = sample.get("coverage_covered", "")
        total = sample.get("coverage_total", "")
        pct_num = number(pct)
        covered_num = integer(covered)
        delta_pct = ""
        delta_covered = ""
        if pct_num is not None and previous_pct is not None:
            delta_pct = f"{pct_num - previous_pct:.4f}"
        if covered_num is not None and previous_covered is not None:
            delta_covered = str(covered_num - previous_covered)
        if pct_num is not None:
            previous_pct = pct_num
        if covered_num is not None:
            previous_covered = covered_num

        rows.append({
            "app": app,
            "runtime": runtime,
            "mode": mode,
            "endpoint_schedule": endpoint_schedule,
            "endpoint_index": idx,
            "endpoint_total": len(endpoints),
            "endpoint_url": starts.get(idx, {}).get("url") or endpoint,
            "start_iso": iso_utc(start_epoch),
            "completion_iso": iso_utc(completion_epoch),
            "completion_reason": reason,
            "sample_elapsed_s": sample.get("elapsed_s", ""),
            "coverage_pct": pct,
            "coverage_covered": covered,
            "coverage_total": total,
            "coverage_delta_pct": delta_pct,
            "coverage_delta_covered": delta_covered,
            "total_requests": sample.get("total_requests", ""),
            "fuzz_requests": sample.get("fuzz_requests", ""),
            "webfuzz_internal_coverage_pct": completion.get("webfuzz_internal_coverage_pct", ""),
        })

out = Path(output_csv)
out.parent.mkdir(parents=True, exist_ok=True)
fieldnames = [
    "app",
    "runtime",
    "mode",
    "endpoint_schedule",
    "endpoint_index",
    "endpoint_total",
    "endpoint_url",
    "start_iso",
    "completion_iso",
    "completion_reason",
    "sample_elapsed_s",
    "coverage_pct",
    "coverage_covered",
    "coverage_total",
    "coverage_delta_pct",
    "coverage_delta_covered",
    "total_requests",
    "fuzz_requests",
    "webfuzz_internal_coverage_pct",
]
with out.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

print(f"[single-all {datetime.now(timezone.utc).strftime('%H:%M:%S')}] endpoint coverage {app}/{mode}: {out}")
for row in rows:
    delta = row["coverage_delta_pct"] or "n/a"
    print(
        f"  endpoint {row['endpoint_index']}/{row['endpoint_total']}: "
        f"coverage={row['coverage_pct'] or '?'}% "
        f"covered={row['coverage_covered'] or '?'}/{row['coverage_total'] or '?'} "
        f"delta={delta}% "
        f"fuzz_requests={row['fuzz_requests'] or '?'}"
    )
PY
}

stop_ongoing() {
    local pids cids
    echo "[single-all $(date -u +%H:%M:%S)] stopping existing campaign processes and campv6 containers"
    pids="$(pgrep -f 'run_campaign_v6\.sh|run_all_apps_time_budget_parallel\.sh|single_endpoint_campaign/run_all_apps_single_endpoint_campaign\.sh|webFuzz\.py|single_endpoint_campaign/run\.py|run_wordpress_multi_endpoint_test\.sh' 2>/dev/null | grep -vw "$$" || true)"
    if [ -n "$pids" ]; then
        kill -TERM $pids 2>/dev/null || true
        sleep 5
        kill -KILL $pids 2>/dev/null || true
    fi
    cids="$("${DOCKER[@]}" ps -aq --filter 'name=campv6-' 2>/dev/null || true)"
    if [ -n "$cids" ]; then
        "${DOCKER[@]}" rm -f $cids >/dev/null 2>&1 || true
    fi
    cids="$("${DOCKER[@]}" ps -aq --filter 'name=sewp-' 2>/dev/null || true)"
    if [ -n "$cids" ]; then
        "${DOCKER[@]}" rm -f $cids >/dev/null 2>&1 || true
    fi
    "${DOCKER[@]}" network prune -f >/dev/null 2>&1 || true
}

run_cell() {
    local app="$1" mode="$2" runtime endpoint_file endpoint_count max_seconds total_time_budget cell_log started ended rc wall csv summary endpoint_csv endpoint_coverage_csv completion_reason
    local single_endpoint_budget_arg schedule_label
    local platform_coverage_final_only force_platform_flush node_take_on_response node_interval_ms
    local resume_valid resume_coverage_status resume_coverage_total
    runtime="$(runtime_for_app "$app")"
    endpoint_file="$ENDPOINT_DIR/${app}.txt"
    endpoint_count="$(grep -Evc '^[[:space:]]*(#|$)' "$endpoint_file")"
    if [ "$BLEND_ENDPOINTS" = "1" ]; then
        schedule_label="blend"
        single_endpoint_budget_arg=0
        total_time_budget="$TOTAL_TIME_BUDGET"
        max_seconds="$TOTAL_TIME_BUDGET"
    else
        schedule_label="sequential"
        single_endpoint_budget_arg="$ENDPOINT_TIME_BUDGET"
        total_time_budget=$(( endpoint_count * ENDPOINT_TIME_BUDGET ))
        if [ "$ENDPOINT_TIME_BUDGET" -gt 0 ]; then
            max_seconds=$(( total_time_budget + MODE_GRACE_SECONDS ))
        else
            max_seconds=0
        fi
    fi

    cell_log="$RUNLOG_DIR/cell_${app}_${mode}.log"
    summary=""
    if [ "$RESUME" = "1" ]; then
        summary="$(find "$RESULT_DIR" -maxdepth 1 -type f -name "*_${app}_${mode}_t0h_*.summary.txt" -printf '%T@\t%p\n' 2>/dev/null | sort -nr | sed -n $'1{s/^[^\t]*\t//;p;}')"
    fi
    resume_valid=1
    if [ -n "$summary" ] && is_nonphp_app "$app"; then
        resume_coverage_status="$(sed -n 's/^coverage_status=//p' "$summary" | tail -n1)"
        resume_coverage_total="$(sed -n 's/^final_csv_row=//p' "$summary" | tail -n1 | cut -d, -f11)"
        if [ "$resume_coverage_status" = "failed" ] \
           || ! [ "${resume_coverage_total:-0}" -gt 0 ] 2>/dev/null; then
            resume_valid=0
        fi
    fi
    if [ -n "$summary" ] && [ "$resume_valid" = "1" ]; then
        echo "[single-all $(date -u +%H:%M:%S)] skip $app/$mode (resume)"
        csv="${summary%.summary.txt}.csv"
        if [ -s "$csv" ]; then
            endpoint_coverage_csv="${csv%.csv}.endpoint_coverage.csv"
            write_endpoint_coverage "$app" "$mode" "$runtime" "$endpoint_file" "$csv" "$summary" "$endpoint_coverage_csv" || true
        fi
        return 0
    fi
    [ -n "$summary" ] && echo "[single-all $(date -u +%H:%M:%S)] rerun $app/$mode (previous final coverage missing or invalid)"

    platform_coverage_final_only=0
    force_platform_flush=1
    node_take_on_response="$NODE_COVERAGE_TAKE_ON_RESPONSE"
    node_interval_ms="$NODE_COVERAGE_INTERVAL_MS"
    if is_nonphp_app "$app" && [ "$NONPHP_COVERAGE_FINAL_ONLY" = "1" ]; then
        platform_coverage_final_only=1
        force_platform_flush=0
        node_take_on_response=0
        [ "$runtime" = "node" ] && node_interval_ms=0
    fi

    echo "[single-all $(date -u +%H:%M:%S)] begin $app/$mode runtime=$runtime endpoints=$endpoint_count schedule=$schedule_label total_budget=${total_time_budget}s"
    started="$(date +%s)"
    if SINGLE_ENDPOINT_MODE=1 \
       SINGLE_ENDPOINT_FILE="$endpoint_file" \
       SINGLE_ENDPOINT_TIME_BUDGET="$single_endpoint_budget_arg" \
       SINGLE_ENDPOINT_BLEND="$BLEND_ENDPOINTS" \
       SINGLE_ENDPOINT_VALIDATE="$VERIFY_ENDPOINTS" \
       SINGLE_ENDPOINT_VALIDATE_ONLY="$VALIDATE_ONLY" \
       FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS="$force_platform_flush" \
       FUZZ_REQUEST_BUDGET="$FUZZ_REQUEST_BUDGET" \
       MAX_CORPUS_SIZE="$MAX_CORPUS_SIZE" \
       MAX_HOURS=0 \
       MAX_SECONDS="$max_seconds" \
       INTERVAL="$SAMPLE_INTERVAL" \
       FUZZ_INTERVAL="$SAMPLE_INTERVAL" \
       STATS_POLL_INTERVAL="$STATS_POLL_INTERVAL" \
       ALLOW_NON_HTML="$ALLOW_NON_HTML" \
       PLATFORM_COVERAGE_SAMPLE=1 \
       PLATFORM_COVERAGE_FINAL_ONLY="$platform_coverage_final_only" \
       COVERAGE_SAMPLE_TIMEOUT="$COVERAGE_SAMPLE_TIMEOUT" \
       NODE_COVERAGE_INTERVAL_MS="$node_interval_ms" \
       NODE_COVERAGE_TAKE_ON_RESPONSE="$node_take_on_response" \
       BLACKBOX_CORPUS_MODE="$BLACKBOX_CORPUS_MODE" \
       BLACKBOX_MAX_CORPUS_SIZE="$BLACKBOX_MAX_CORPUS_SIZE" \
       RESULT_DIR="$RESULT_DIR" \
       PYTHONHASHSEED="$PYTHONHASHSEED" \
       "$CAMPAIGN_RUNNER" "$app" "$mode" > "$cell_log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    ended="$(date +%s)"
    wall=$(( ended - started ))
    csv="$(latest_coverage_csv_since "*_${app}_${mode}_t0h_*.csv" "$started")"
    summary="$(latest_file_since "*_${app}_${mode}_t0h_*.summary.txt" "$started")"
    endpoint_csv="$(latest_file_since "*_${app}_${mode}_t0h_*.endpoints.csv" "$started")"
    endpoint_coverage_csv=""
    if [ -n "${csv:-}" ]; then
        endpoint_coverage_csv="${csv%.csv}.endpoint_coverage.csv"
        write_endpoint_coverage "$app" "$mode" "$runtime" "$endpoint_file" "$csv" "${summary:-}" "$endpoint_coverage_csv" || endpoint_coverage_csv=""
    fi
    append_matrix_row "$app" "$mode" "$runtime" "$endpoint_count" "$single_endpoint_budget_arg" "$total_time_budget" "$rc" "$wall" "${csv:-}" "${summary:-}" "${endpoint_csv:-}" "${endpoint_coverage_csv:-}"
    echo "[single-all $(date -u +%H:%M:%S)] end $app/$mode rc=$rc wall=${wall}s coverage_csv=${csv:-none} endpoint_coverage_csv=${endpoint_coverage_csv:-none}"
    completion_reason="$(summary_value "${summary:-}" completion_reason)"
    if [ "$rc" -eq 5 ] \
       && { [ "$completion_reason" = "budget_reached" ] || [ "$completion_reason" = "empty_queue" ]; }; then
        echo "[single-all $(date -u +%H:%M:%S)] accept $app/$mode rc=5 as planned completion ($completion_reason)"
        return 0
    fi
    return "$rc"
}

run_app_driver() {
    local app="$1" mode rc modes_rc
    local -a app_modes=()
    modes_rc=0
    mapfile -t app_modes < <(selected_modes_for_app "$app")
    for mode in "${app_modes[@]}"; do
        [ -n "$mode" ] || continue
        run_cell "$app" "$mode" || modes_rc=1
    done
    return "$modes_rc"
}

read -r -a APPS <<< "$APPS_STR"
require_positive_integer JOBS "$JOBS" || exit 2
require_positive_integer ENDPOINTS_PER_APP "$ENDPOINTS_PER_APP" || exit 2
require_positive_integer SAMPLE_INTERVAL "$SAMPLE_INTERVAL" || exit 2
require_positive_integer STATS_POLL_INTERVAL "$STATS_POLL_INTERVAL" || exit 2
require_positive_integer COVERAGE_SAMPLE_TIMEOUT "$COVERAGE_SAMPLE_TIMEOUT" || exit 2
require_positive_integer TOTAL_TIME_BUDGET "$TOTAL_TIME_BUDGET" || exit 2
require_nonnegative_integer ENDPOINT_TIME_BUDGET "$ENDPOINT_TIME_BUDGET" || exit 2
require_nonnegative_integer MODE_GRACE_SECONDS "$MODE_GRACE_SECONDS" || exit 2
require_nonnegative_integer NODE_COVERAGE_INTERVAL_MS "$NODE_COVERAGE_INTERVAL_MS" || exit 2
require_boolean NONPHP_COVERAGE_FINAL_ONLY "$NONPHP_COVERAGE_FINAL_ONLY" || exit 2
case "$BLACKBOX_CORPUS_MODE" in
    seed-only|keep-submitted) ;;
    *) echo "ERROR: BLACKBOX_CORPUS_MODE must be seed-only or keep-submitted (got '$BLACKBOX_CORPUS_MODE')" >&2; exit 2 ;;
esac
require_boolean BLEND_ENDPOINTS "$BLEND_ENDPOINTS" || exit 2
require_boolean STOP_ONGOING "$STOP_ONGOING" || exit 2
require_boolean RESUME "$RESUME" || exit 2
require_boolean VERIFY_ENDPOINTS "$VERIFY_ENDPOINTS" || exit 2
require_boolean VALIDATE_ONLY "$VALIDATE_ONLY" || exit 2
[ -d "$ENDPOINT_SOURCE_DIR" ] || { echo "ERROR: endpoint source dir does not exist: $ENDPOINT_SOURCE_DIR" >&2; exit 2; }

for app in "${APPS[@]}"; do
    if ! is_php_app "$app" && ! is_nonphp_app "$app"; then
        echo "ERROR: unsupported app '$app'" >&2
        exit 2
    fi
    mapfile -t _modes < <(selected_modes_for_app "$app")
    [ "${#_modes[@]}" -gt 0 ] || { echo "ERROR: no modes selected for $app" >&2; exit 2; }
done

mkdir -p "$RESULT_DIR" "$RUNLOG_DIR" "$ENDPOINT_DIR"
for app in "${APPS[@]}"; do
    write_endpoint_file "$app" "$ENDPOINT_DIR/${app}.txt" || exit 2
done
init_matrix_csv

echo "================ single-endpoint all-app campaign ================"
echo " apps                 : ${APPS[*]}"
echo " php modes            : $PHP_MODE_LIST"
echo " non-php modes        : $NONPHP_MODE_LIST (native filtered)"
echo " endpoint schedule    : $([ "$BLEND_ENDPOINTS" = "1" ] && echo blend || echo sequential)"
if [ "$BLEND_ENDPOINTS" = "1" ]; then
    echo " total budget         : ${TOTAL_TIME_BUDGET}s for all endpoints"
else
    echo " endpoint budget      : ${ENDPOINT_TIME_BUDGET}s per endpoint"
    echo " total budget/app     : $(( ENDPOINTS_PER_APP * ENDPOINT_TIME_BUDGET ))s plus ${MODE_GRACE_SECONDS}s runner grace"
fi
echo " endpoints/app        : $ENDPOINTS_PER_APP"
echo " endpoint source dir  : $ENDPOINT_SOURCE_DIR"
echo " PHP coverage sampling: every ${SAMPLE_INTERVAL}s (poll ${STATS_POLL_INTERVAL}s)"
echo " non-PHP coverage     : $([ "$NONPHP_COVERAGE_FINAL_ONLY" = "1" ] && echo final-only || echo every-sample)"
echo " coverage timeout     : ${COVERAGE_SAMPLE_TIMEOUT}s per report"
echo " BlackBox corpus      : $BLACKBOX_CORPUS_MODE"
if [ "$NONPHP_COVERAGE_FINAL_ONLY" = "1" ]; then
    echo " node v8 flush        : on final sample (periodic disabled)"
else
    echo " node v8 flush        : ${NODE_COVERAGE_INTERVAL_MS}ms, take-on-response=${NODE_COVERAGE_TAKE_ON_RESPONSE}"
fi
echo " jobs                 : $JOBS"
echo " verify endpoints     : $VERIFY_ENDPOINTS"
echo " validate only        : $VALIDATE_ONLY"
echo " stop ongoing first   : $STOP_ONGOING"
echo " result dir           : $RESULT_DIR"
echo " matrix CSV           : $MATRIX_CSV"
echo "=================================================================="

if [ "$DRY_RUN" = "1" ]; then
    for app in "${APPS[@]}"; do
        echo
        echo "[$app] endpoints:"
        sed 's/^/  /' "$ENDPOINT_DIR/${app}.txt"
        echo "[$app] modes: $(selected_modes_for_app "$app" | tr '\n' ' ')"
    done
    echo
    echo "(dry-run: endpoint files written, campaigns not launched)"
    exit 0
fi

[ "$STOP_ONGOING" = "1" ] && stop_ongoing

failures=0
pids=()
pid_apps=()
for app in "${APPS[@]}"; do
    while [ "${#pids[@]}" -ge "$JOBS" ]; do
        if ! wait "${pids[0]}"; then
            failures=$((failures + 1))
        fi
        pids=( "${pids[@]:1}" )
        pid_apps=( "${pid_apps[@]:1}" )
    done
    run_app_driver "$app" &
    pids+=( "$!" )
    pid_apps+=( "$app" )
    echo "[single-all $(date -u +%H:%M:%S)] launched $app driver pid=${pids[$(( ${#pids[@]} - 1 ))]}"
done

for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        failures=$((failures + 1))
    fi
done

echo "[single-all $(date -u +%H:%M:%S)] finished with driver_failures=$failures"
echo "Coverage CSVs and matrix are under: $RESULT_DIR"
exit "$failures"
