#!/usr/bin/env bash

set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT_PATH="$HERE/$(basename "$0")"
CAMPAIGN_RUNNER="${CAMPAIGN_RUNNER:-$ROOT/eval/run_campaign_v6.sh}"
ANALYZER="${ANALYZER:-$ROOT/eval/compare_request_feedback_hashes.py}"

PHP_APPS=(wordpress hotcrp phpbb joomla bagisto drupal prestashop zencart)
NONPHP_APPS=(ghost redmine gogs huginn superset wikijs petclinic roller)
DEFAULT_APPS=("${PHP_APPS[@]}" "${NONPHP_APPS[@]}")
DEFAULT_MODES=(tracelib_bigram_file_sql_filtered tracelib_ebpf_simple tracelib_ebpf)

RUN_ID="${APPS_FEEDBACK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_DIR="${RESULT_DIR:-$ROOT/eval_result_single_endpoint/apps_feedback_$RUN_ID}"
ENDPOINT_SOURCE_DIR="${ENDPOINT_SOURCE_DIR:-$HERE/default_endpoints}"
PHP_FUZZ_REQUEST_BUDGET="${PHP_FUZZ_REQUEST_BUDGET:-1000}"
NONPHP_FUZZ_REQUEST_BUDGET="${NONPHP_FUZZ_REQUEST_BUDGET:-50}"
MAX_SECONDS="${MAX_SECONDS:-0}"
JOBS="${CONCURRENT_CAMPAIGNS:-${JOBS:-4}}"
MAX_CORPUS_SIZE="${MAX_CORPUS_SIZE:-400}"
REQUEST_FEEDBACK_SYNC_INTERVAL="${REQUEST_FEEDBACK_SYNC_INTERVAL:-30}"
FEEDBACK_CAPTURE_SYNC_INTERVAL="${FEEDBACK_CAPTURE_SYNC_INTERVAL:-$REQUEST_FEEDBACK_SYNC_INTERVAL}"
NONPHP_COVERAGE_SAMPLE_TIMEOUT="${NONPHP_COVERAGE_SAMPLE_TIMEOUT:-12}"
NONPHP_COVERAGE_SAMPLE_TIMEOUT_SLOW="${NONPHP_COVERAGE_SAMPLE_TIMEOUT_SLOW:-60}"
EXTERNAL_COVERAGE_TIMEOUT="${WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT:-20}"
SINGLE_ENDPOINT_VALIDATE_TIMEOUT="${SINGLE_ENDPOINT_VALIDATE_TIMEOUT:-20}"
COMPOSE_UP_ATTEMPTS="${COMPOSE_UP_ATTEMPTS:-3}"
COMPOSE_UP_RETRY_DELAY="${COMPOSE_UP_RETRY_DELAY:-15}"
PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
RESUME="${RESUME:-1}"
DRY_RUN="${DRY_RUN:-0}"
WRITE_PAIRS_CSV="${WRITE_PAIRS_CSV:-0}"
BITMAP_HASH_LIST="${BITMAP_HASH_LIST:-index bucket}"

set_result_paths() {
    REQUEST_FEEDBACK_DIR="$RESULT_DIR/request_feedback"
    ANALYSIS_DIR="$RESULT_DIR/alignment"
    PAIR_DIR="$RESULT_DIR/pairs"
    CELL_DIR="$RESULT_DIR/cells"
    LOG_DIR="$RESULT_DIR/campaign_logs"
    ENDPOINT_DIR="$RESULT_DIR/endpoints"
    MATRIX_CSV="$RESULT_DIR/feedback_quality_matrix.csv"
    CONFIG_JSON="$RESULT_DIR/feedback_quality_config.json"
}
set_result_paths

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [APP ...]

Evaluate whether TraceLib request bitmaps preserve the equivalence relation
defined by platform code coverage. The three TraceLib encodings are:
  tracelib_ebpf_simple  TraceLib argument-sensitive syscall bigram
  tracelib_ebpf         TraceLib N-gram comparator over every syscall
  tracelib_bigram_file_sql_filtered
                        TraceLib bigram projected to monitored file paths and
                        recognised SQL buffers
  tracelib_bigram_file_sql_filtered
                        Records ONLY syscalls carrying a monitored file path or a
                        SQL query; everything else is skipped and never becomes a
                        predecessor. Edge = ((prev^prev_arg)<<8) ^ (curr^curr_arg)

Defaults:
  applications          all 8 PHP and 6 non-PHP applications
  endpoint schedule     the existing 10 seeds per app, blended
  PHP fuzz requests     $PHP_FUZZ_REQUEST_BUDGET per app/mode
  non-PHP fuzz requests $NONPHP_FUZZ_REQUEST_BUDGET per app/mode
  concurrent apps       $JOBS; modes for one app are always sequential
  request phase         fuzz only; session checks are excluded

Options:
  -j, --jobs N                    Concurrent applications
      --apps APP...               Select applications (positional APP also works)
      --modes MODE...             Select TraceLib modes (default: all eight)
      --php-fuzz-requests N       PHP request budget (default: 1000)
      --nonphp-fuzz-requests N    Non-PHP request budget (default: 50)
      --max-seconds N             Safety cap per cell; 0 disables it (default: 0)
      --max-corpus-size N         Retained corpus cap; 0 is unlimited (default: 400)
      --compose-up-attempts N     Compose build/start attempts (default: 3)
      --compose-up-retry-delay N  Seconds between Compose attempts (default: 15)
      --result-dir DIR            Result directory
      --endpoint-source-dir DIR   Directory containing APP.txt endpoint files
      --bitmap-hash WHICH         TraceLib relation to score: index, bucket or
                                  both (default: both). index = lit cells only;
                                  bucket = lit cells and their hit-count buckets
      --write-pairs               Write every comparable pair to CSV
      --no-write-pairs            Do not write quadratic pair CSVs (default)
      --no-resume                 Re-run cells with existing usable analyses
      --dry-run                   Validate and print the schedule without Docker
  -h, --help                      Show this help

Outputs:
  request_feedback/APP_MODE_requests.json   both hashes per request
  alignment/APP_MODE_HASH_alignment_summary.json
  pairs/APP_MODE_HASH_alignment_pairs.csv   only with --write-pairs
  cells/APP_MODE_HASH.json
  feedback_quality_matrix.csv               one row per app/mode/bitmap_hash
  feedback_quality_config.json

Existing campaigns are never stopped. A selected application is checked for
process/container collisions immediately before its first mode starts.
EOF
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

validate_identifier() {
    local kind="$1" value="$2"
    if [[ ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: invalid $kind '$value'" >&2
        return 1
    fi
}

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

is_supported_app() {
    is_php_app "$1" || is_nonphp_app "$1"
}

is_supported_mode() {
    case "$1" in
        tracelib_ebpf_simple|tracelib_ebpf|tracelib_bigram_file_sql_filtered) return 0 ;;
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
        *) return 1 ;;
    esac
}

write_absolute_endpoint_file() {
    local app="$1" source_file="$2" output_file="$3" base_url endpoint
    base_url="http://localhost:$(port_for_app "$app")"
    : > "$output_file"
    while IFS= read -r endpoint || [ -n "$endpoint" ]; do
        endpoint="${endpoint#${endpoint%%[![:space:]]*}}"
        endpoint="${endpoint%${endpoint##*[![:space:]]}}"
        [ -n "$endpoint" ] || continue
        case "$endpoint" in
            \#*) continue ;;
            http://*|https://*) printf '%s\n' "$endpoint" >> "$output_file" ;;
            /*) printf '%s%s\n' "$base_url" "$endpoint" >> "$output_file" ;;
            *) printf '%s/%s\n' "$base_url" "$endpoint" >> "$output_file" ;;
        esac
    done < "$source_file"
}

oracle_for_app() {
    case "$1" in
        ghost|wikijs) echo v8_lines ;;
        gogs) echo go_lines ;;
        redmine|huginn) echo ruby_lines ;;
        superset) echo python_lines ;;
        petclinic|roller) echo java_lines ;;
        *) echo php_ast_edges ;;
    esac
}

budget_for_app() {
    if is_php_app "$1"; then
        echo "$PHP_FUZZ_REQUEST_BUDGET"
    else
        echo "$NONPHP_FUZZ_REQUEST_BUDGET"
    fi
}

mode_label() {
    case "$1" in
        tracelib_ebpf_simple) echo tracelib_bigram ;;
        tracelib_ebpf) echo tracelib_ngram ;;
        tracelib_bigram_file_sql_filtered) echo tracelib_bigram_file_sql_filtered ;;
    esac
}

latest_file_since() {
    local pattern="$1" started_epoch="$2"
    find "$RESULT_DIR" -maxdepth 1 -type f -name "$pattern" \
        -newermt "@$started_epoch" -printf '%T@\t%p\n' 2>/dev/null \
        | sort -nr | sed -n $'1{s/^[^\t]*\t//;p;}'
}

docker_names() {
    if /usr/bin/docker ps --format '{{.Names}}' >/dev/null 2>&1; then
        /usr/bin/docker ps --format '{{.Names}}' 2>/dev/null
    else
        sudo -n /usr/bin/docker ps --format '{{.Names}}' 2>/dev/null
    fi
}

check_app_collision() {
    local app="$1" active_processes active_containers
    [ "$DRY_RUN" = "0" ] || return 0
    active_processes="$(
        pgrep -af 'run_campaign_v6\.sh|single_endpoint_campaign/run_all_apps_single_endpoint_campaign\.sh|single_endpoint_campaign/run\.py|webFuzz\.py' 2>/dev/null \
            | grep -E "run_campaign_v6\\.sh[[:space:]]+${app}[[:space:]]|/endpoints/${app}\\.txt" \
            || true
    )"
    active_containers="$(docker_names | grep -E -- "^campv6-.*-${app}-" || true)"
    if [ -n "$active_processes" ]; then
        echo "ERROR: app=$app collides with an active campaign cell:" >&2
        printf '%s\n' "$active_processes" >&2
        [ -z "$active_containers" ] || printf '%s\n' "$active_containers" >&2
        return 2
    fi
    if [ -n "$active_containers" ]; then
        echo "WARNING: app=$app has stale campaign containers; the campaign runner will replace them:" >&2
        printf '%s\n' "$active_containers" >&2
    else
        echo "Collision check passed for app=$app"
    fi
}

stale_platform_coverage_exec_count() {
    local app="$1" mode="$2" project="campv6-${mode}-${app}"
    python3 - "$project" <<'PY'
import os
import sys

project = sys.argv[1]
markers = (
    "c8 report",
    "/tracelib-support/coverage_report.sh",
    "/tracelib-support/coverage_report.py",
)
count = 0
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    try:
        parts = [
            value.decode("utf-8", "replace")
            for value in open(f"/proc/{name}/cmdline", "rb").read().split(b"\0")
            if value
        ]
    except OSError:
        continue
    if not parts:
        continue
    command = " ".join(parts)
    if project in command and any(marker in command for marker in markers):
        count += 1
print(count)
PY
}

analysis_is_usable() {
    local path="$1"
    python3 - "$path" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
if int(data.get("summary", {}).get("complete_records", 0)) <= 0:
    raise SystemExit(1)
PY
}

analyze_capture() {
    local app="$1" mode="$2" request_json="$3" hash summary_json pairs_csv rc
    local -a analyzer_args

    python3 - "$request_json" "$app" "$mode" "$BITMAP_HASH_LIST" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
app, mode, hashes = sys.argv[2:]
FIELD = {"index": "bitmap_coverage_hash", "bucket": "bitmap_coverage_hash_bucket"}
records = json.loads(path.read_text(encoding="utf-8"))
if not isinstance(records, list) or not records:
    raise SystemExit(f"{app}/{mode}: no fuzz-phase feedback records")
code = sum(bool(item.get("code_coverage_hash")) for item in records)
if code == 0:
    raise SystemExit(f"{app}/{mode}: platform coverage produced no request hashes")
for name in hashes.split():
    field = FIELD[name]
    bitmap = sum(bool(item.get(field)) for item in records)
    both = sum(
        bool(item.get("code_coverage_hash")) and bool(item.get(field))
        for item in records
    )
    print(
        f"{app}/{mode} [{name}]: records={len(records)} code_hashes={code} "
        f"bitmap_hashes={bitmap} complete={both}"
    )
    if bitmap == 0:
        raise SystemExit(f"{app}/{mode} [{name}]: TraceLib produced no request bitmap hashes")
    if both == 0:
        raise SystemExit(f"{app}/{mode} [{name}]: no request has both feedback hashes")
PY
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    for hash in $BITMAP_HASH_LIST; do
        summary_json="$ANALYSIS_DIR/${app}_${mode}_${hash}_alignment_summary.json"
        pairs_csv="$PAIR_DIR/${app}_${mode}_${hash}_alignment_pairs.csv"
        analyzer_args=(
            "$request_json"
            --max-requests 0
            --bitmap-hash "$hash"
            --summary-json "$summary_json"
        )
        if [ "$WRITE_PAIRS_CSV" = "1" ]; then
            analyzer_args+=( --pairs-csv "$pairs_csv" )
        else
            rm -f "$pairs_csv"
        fi
        echo "--- alignment for $app/$mode using the '$hash' relation ---"
        python3 "$ANALYZER" "${analyzer_args[@]}" || return $?
    done
}

write_failure_cell() {
    local app="$1" mode="$2" budget="$3" runner_rc="$4" reason="$5" hash
    for hash in $BITMAP_HASH_LIST; do
    local cell_file="$CELL_DIR/${app}_${mode}_${hash}.json"
    python3 - "$cell_file" "$app" "$(runtime_for_app "$app")" "$mode" \
        "$(mode_label "$mode")" "$(oracle_for_app "$app")" "$budget" \
        "$runner_rc" "$reason" "$hash" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path, app, runtime, mode, label, oracle, budget, runner_rc, reason, bitmap_hash = sys.argv[1:]
payload = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "app": app,
    "runtime": runtime,
    "mode": mode,
    "mode_label": label,
    "bitmap_hash": bitmap_hash,
    "platform_oracle": oracle,
    "endpoint_count": 10,
    "fuzz_request_budget": int(budget),
    "runner_return_code": int(runner_rc),
    "status": "failed",
    "failure": reason,
}
target = Path(path)
target.parent.mkdir(parents=True, exist_ok=True)
temporary = target.with_name(f".{target.name}.tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(target)
PY
    done
}

write_success_cell() {
    local app="$1" mode="$2" budget="$3" runner_rc="$4" wall="$5"
    local campaign_summary="$6" endpoint_csv="$7" request_json="$8" hash="$9"
    local analysis_json="$ANALYSIS_DIR/${app}_${mode}_${hash}_alignment_summary.json"
    local pairs_csv="$PAIR_DIR/${app}_${mode}_${hash}_alignment_pairs.csv"
    local endpoint_file="$ENDPOINT_DIR/${app}.txt"
    local cell_file="$CELL_DIR/${app}_${mode}_${hash}.json"

    python3 - "$cell_file" "$app" "$(runtime_for_app "$app")" "$mode" \
        "$(mode_label "$mode")" "$(oracle_for_app "$app")" "$budget" \
        "$runner_rc" "$wall" "$campaign_summary" "$endpoint_csv" \
        "$endpoint_file" "$request_json" "$analysis_json" "$pairs_csv" \
        "$WRITE_PAIRS_CSV" "$hash" <<'PY'
import csv
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    cell_path,
    app,
    runtime,
    mode,
    mode_label,
    oracle,
    budget,
    runner_rc,
    wall,
    campaign_summary_path,
    endpoint_csv_path,
    endpoint_file_path,
    request_json_path,
    analysis_json_path,
    pairs_csv_path,
    write_pairs,
    bitmap_hash,
) = sys.argv[1:]
budget = int(budget)

summary_values = {}
for raw in Path(campaign_summary_path).read_text(encoding="utf-8").splitlines():
    if raw == "--- fuzzstart ---":
        break
    if "=" in raw:
        key, value = raw.split("=", 1)
        summary_values[key] = value

errors = []
completion_reason = summary_values.get("completion_reason", "")
if completion_reason not in {"budget_reached", "empty_queue"}:
    errors.append(
        "completion_reason=" + (completion_reason or "missing")
    )
if summary_values.get("single_endpoint_count") != "10":
    errors.append("single_endpoint_count is not 10")
if summary_values.get("single_endpoint_schedule") != "blend":
    errors.append("single_endpoint_schedule is not blend")

final_row = next(csv.reader([summary_values.get("final_csv_row", "")]), [])
final_fuzz_requests = int(final_row[18] or 0) if len(final_row) > 18 else 0
if final_fuzz_requests <= 0 or final_fuzz_requests > budget:
    errors.append(
        f"final_fuzz_requests={final_fuzz_requests}, expected range=1..{budget}"
    )

with Path(endpoint_csv_path).open(newline="", encoding="utf-8") as handle:
    endpoints = list(csv.DictReader(handle))
if len(endpoints) != 10 or any(
    row.get("method") != "GET"
    or row.get("http_status") != "200"
    or row.get("ok") != "yes"
    for row in endpoints
):
    errors.append("not all ten GET endpoint seeds validated successfully")

analysis_payload = json.loads(Path(analysis_json_path).read_text(encoding="utf-8"))
alignment = analysis_payload["summary"]
records = int(alignment["records"])
complete_records = int(alignment["complete_records"])
if complete_records <= 0:
    errors.append("no complete request-feedback observations")

if errors:
    status = "failed"
elif completion_reason == "empty_queue" or records != final_fuzz_requests or complete_records != records:
    status = "complete_partial"
else:
    status = "complete"

endpoint_bytes = Path(endpoint_file_path).read_bytes()
payload = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "app": app,
    "runtime": runtime,
    "mode": mode,
    "mode_label": mode_label,
    "bitmap_hash": bitmap_hash,
    "platform_oracle": oracle,
    "endpoint_count": 10,
    "endpoint_schedule": "blend",
    "endpoint_file": endpoint_file_path,
    "endpoint_sha256": hashlib.sha256(endpoint_bytes).hexdigest(),
    "fuzz_request_budget": budget,
    "final_fuzz_requests": final_fuzz_requests,
    "runner_return_code": int(runner_rc),
    "wall_seconds": int(wall),
    "completion_reason": completion_reason,
    "status": status,
    "failure": "; ".join(errors),
    "request_feedback_file": request_json_path,
    "alignment_summary_file": analysis_json_path,
    "pairs_csv": pairs_csv_path if write_pairs == "1" else "",
    "records": records,
    "complete_records": complete_records,
    "unique_requests": int(alignment["unique_requests"]),
    "missing_code_hash_records": int(alignment["missing_code_hash_records"]),
    "missing_bitmap_hash_records": int(alignment["missing_bitmap_hash_records"]),
    "comparable_pairs": int(alignment["comparable_pairs"]),
    "true_positive": int(alignment["true_positive_code_diff_bitmap_diff"]),
    "false_negative_merge": int(alignment["false_merge_code_diff_bitmap_same"]),
    "false_positive_split": int(alignment["false_split_code_same_bitmap_diff"]),
    "true_negative": int(alignment["true_negative_code_same_bitmap_same"]),
    "alignment_rate": alignment["alignment_rate"],
}
classification = alignment.get("classification")
if classification is None:
    tp = payload["true_positive"]
    fn = payload["false_negative_merge"]
    fp = payload["false_positive_split"]
    tn = payload["true_negative"]
    div = lambda a, b: (a / b) if b else None
    classification = {
        "tpr": div(tp, tp + fn),
        "tnr": div(tn, tn + fp),
        "fpr": div(fp, tn + fp),
        "fnr": div(fn, tp + fn),
        "precision": div(tp, tp + fp),
        "f1": None,
        "accuracy": div(tp + tn, tp + tn + fp + fn),
        "balanced_accuracy": None,
        "matthews_corrcoef": None,
        "adjusted_rand_index": None,
    }
for key in (
    "tpr",
    "tnr",
    "fpr",
    "fnr",
    "precision",
    "f1",
    "accuracy",
    "balanced_accuracy",
    "matthews_corrcoef",
    "adjusted_rand_index",
):
    payload[key] = classification.get(key)
target = Path(cell_path)
target.parent.mkdir(parents=True, exist_ok=True)
temporary = target.with_name(f".{target.name}.tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(target)
print(status)
if errors:
    for error in errors:
        print(f"CELL AUDIT ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

run_feedback_cell() {
    local app="$1" mode="$2" budget runtime request_json analysis_json
    local cell_log cell_stamp started ended wall runner_rc summary endpoint_csv
    local completion_reason rc
    local nonphp_reference platform_sample interval fuzz_interval coverage_timeout
    local node_take_on_response node_interval stale_count hash

    budget="$(budget_for_app "$app")"
    runtime="$(runtime_for_app "$app")"
    request_json="$REQUEST_FEEDBACK_DIR/${app}_${mode}_requests.json"
    cell_log="$LOG_DIR/apps_feedback_${app}_${mode}.log"

    if [ "$RESUME" = "1" ]; then
        local resume_ok=1 hash
        for hash in $BITMAP_HASH_LIST; do
            analysis_json="$ANALYSIS_DIR/${app}_${mode}_${hash}_alignment_summary.json"
            if [ ! -s "$analysis_json" ] || [ ! -s "$CELL_DIR/${app}_${mode}_${hash}.json" ] \
               || ! analysis_is_usable "$analysis_json"; then
                resume_ok=0
                break
            fi
        done
        if [ "$resume_ok" = "1" ]; then
            echo "=== Skipping app=$app mode=$mode (usable analyses exist for: $BITMAP_HASH_LIST) ==="
            return 0
        fi
    fi

    check_app_collision "$app"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        write_failure_cell "$app" "$mode" "$budget" "$rc" "active campaign collision"
        return "$rc"
    fi

    if is_nonphp_app "$app"; then
        nonphp_reference=1
        platform_sample=0
        interval=60
        fuzz_interval=60
        coverage_timeout="$NONPHP_COVERAGE_SAMPLE_TIMEOUT"
        case "$runtime" in
            python|java) coverage_timeout="$NONPHP_COVERAGE_SAMPLE_TIMEOUT_SLOW" ;;
        esac
        node_take_on_response=1
        node_interval=5000
        stale_count="$(stale_platform_coverage_exec_count "$app" "$mode")"
        if [ "$stale_count" -gt 0 ] 2>/dev/null; then
            echo "ERROR: found $stale_count stale platform reporter process(es) for $app/$mode" >&2
            write_failure_cell "$app" "$mode" "$budget" 2 "stale platform coverage reporter"
            return 2
        fi
    else
        nonphp_reference=0
        platform_sample=1
        interval=60
        fuzz_interval=20
        coverage_timeout=20
        node_take_on_response=0
        node_interval=30000
    fi

    rm -f "$request_json"
    for hash in $BITMAP_HASH_LIST; do
        rm -f "$ANALYSIS_DIR/${app}_${mode}_${hash}_alignment_summary.json" \
              "$PAIR_DIR/${app}_${mode}_${hash}_alignment_pairs.csv"
    done
    cell_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    started="$(date +%s)"
    echo "=== Starting app=$app mode=$mode budget=$budget oracle=$(oracle_for_app "$app") ==="

    SINGLE_ENDPOINT_MODE=1 \
    SINGLE_ENDPOINT_FILE="$ENDPOINT_DIR/${app}.txt" \
    SINGLE_ENDPOINT_TIME_BUDGET=0 \
    SINGLE_ENDPOINT_BLEND=1 \
    SINGLE_ENDPOINT_VALIDATE=1 \
    SINGLE_ENDPOINT_VALIDATE_TIMEOUT="$SINGLE_ENDPOINT_VALIDATE_TIMEOUT" \
    FUZZ_REQUEST_BUDGET="$budget" \
    MAX_CORPUS_SIZE="$MAX_CORPUS_SIZE" \
    MAX_HOURS=0 \
    MAX_SECONDS="$MAX_SECONDS" \
    INTERVAL="$interval" \
    FUZZ_INTERVAL="$fuzz_interval" \
    STATS_POLL_INTERVAL=1 \
    RESULT_DIR="$RESULT_DIR" \
    REQUEST_FEEDBACK_FILE="$request_json" \
    REQUEST_FEEDBACK_PHASE=fuzz \
    REQUEST_FEEDBACK_SYNC_INTERVAL="$REQUEST_FEEDBACK_SYNC_INTERVAL" \
    FEEDBACK_CAPTURE_SYNC_INTERVAL="$FEEDBACK_CAPTURE_SYNC_INTERVAL" \
    NONPHP_REQUEST_FEEDBACK_REFERENCE="$nonphp_reference" \
    NONPHP_REQUEST_FEEDBACK_MODE=reset \
    PLATFORM_COVERAGE_SAMPLE="$platform_sample" \
    PLATFORM_COVERAGE_FINAL_ONLY=0 \
    COVERAGE_SAMPLE_TIMEOUT="$coverage_timeout" \
    WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT="$EXTERNAL_COVERAGE_TIMEOUT" \
    NODE_COVERAGE_TAKE_ON_RESPONSE="$node_take_on_response" \
    NODE_COVERAGE_INTERVAL_MS="$node_interval" \
    COMPOSE_UP_ATTEMPTS="$COMPOSE_UP_ATTEMPTS" \
    COMPOSE_UP_RETRY_DELAY="$COMPOSE_UP_RETRY_DELAY" \
    AUTO_APP_SEED_FILE=0 \
    ENABLE_APP_SEEDS=0 \
    APP_SEED_URLS= \
    APP_SEED_FILE= \
    ALLOW_NON_HTML=1 \
    PYTHONHASHSEED="$PYTHONHASHSEED" \
        "$CAMPAIGN_RUNNER" "$app" "$mode" 2>&1 \
        | tee "$cell_log" \
        | sed -u "s|^|[$app/$mode] |"
    runner_rc=${PIPESTATUS[0]}
    ended="$(date +%s)"
    wall=$((ended - started))

    summary="$(latest_file_since "*_${app}_${mode}_t0h_${cell_stamp}.summary.txt" "$started")"
    [ -n "$summary" ] || summary="$(latest_file_since "*_${app}_${mode}_t0h_*.summary.txt" "$started")"
    endpoint_csv="$(latest_file_since "*_${app}_${mode}_t0h_${cell_stamp}.endpoints.csv" "$started")"
    [ -n "$endpoint_csv" ] || endpoint_csv="$(latest_file_since "*_${app}_${mode}_t0h_*.endpoints.csv" "$started")"

    if [ -z "$summary" ] || [ -z "$endpoint_csv" ] || [ ! -s "$request_json" ]; then
        echo "ERROR: app=$app mode=$mode did not produce all required artifacts" >&2
        write_failure_cell "$app" "$mode" "$budget" "$runner_rc" "required campaign artifact missing"
        return 1
    fi

    completion_reason="$(sed -n 's/^completion_reason=//p' "$summary" | tail -n1)"
    if [ "$completion_reason" != "budget_reached" ] && [ "$completion_reason" != "empty_queue" ]; then
        echo "ERROR: app=$app mode=$mode completion_reason=${completion_reason:-missing}" >&2
        write_failure_cell "$app" "$mode" "$budget" "$runner_rc" "completion reason is ${completion_reason:-missing}"
        return 1
    fi
    if [ "$runner_rc" -ne 0 ] && [ "$runner_rc" -ne 5 ]; then
        echo "ERROR: app=$app mode=$mode runner returned $runner_rc" >&2
        write_failure_cell "$app" "$mode" "$budget" "$runner_rc" "unexpected runner return code"
        return "$runner_rc"
    fi

    if analyze_capture "$app" "$mode" "$request_json"; then
        rc=0
    else
        rc=$?
        write_failure_cell "$app" "$mode" "$budget" "$runner_rc" "alignment analysis failed"
        return "$rc"
    fi
    for hash in $BITMAP_HASH_LIST; do
        if ! write_success_cell "$app" "$mode" "$budget" "$runner_rc" "$wall" \
            "$summary" "$endpoint_csv" "$request_json" "$hash"; then
            write_failure_cell "$app" "$mode" "$budget" "$runner_rc" "cell integrity audit failed"
            return 1
        fi
    done
    echo "=== Completed app=$app mode=$mode ==="
}

run_app() {
    local app="$1" mode rc=0 cell_rc first_hash
    for mode in $MODE_LIST; do
        if run_feedback_cell "$app" "$mode"; then
            :
        else
            cell_rc=$?
            local first_hash="${BITMAP_HASH_LIST%% *}"
            if [ ! -s "$CELL_DIR/${app}_${mode}_${first_hash}.json" ]; then
                write_failure_cell "$app" "$mode" "$(budget_for_app "$app")" \
                    "$cell_rc" "cell failed before campaign artifacts were produced"
            fi
            rc=1
        fi
    done
    return "$rc"
}

write_config() {
    python3 - "$CONFIG_JSON" "$RESULT_DIR" "$ENDPOINT_SOURCE_DIR" \
        "$PHP_FUZZ_REQUEST_BUDGET" "$NONPHP_FUZZ_REQUEST_BUDGET" "$MAX_SECONDS" \
        "$JOBS" "$MAX_CORPUS_SIZE" "$MODE_LIST" "$APP_LIST" "$ENDPOINT_DIR" \
        "$COMPOSE_UP_ATTEMPTS" "$COMPOSE_UP_RETRY_DELAY" "$BITMAP_HASH_LIST" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    output,
    result_dir,
    endpoint_source_dir,
    php_budget,
    nonphp_budget,
    max_seconds,
    jobs,
    max_corpus,
    modes,
    apps,
    endpoint_dir,
    compose_up_attempts,
    compose_up_retry_delay,
    bitmap_hashes,
) = sys.argv[1:]
payload = {
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "result_dir": result_dir,
    "endpoint_source_dir": endpoint_source_dir,
    "endpoint_schedule": "blend",
    "endpoints_per_app": 10,
    "request_feedback_phase": "fuzz",
    "php_fuzz_request_budget": int(php_budget),
    "nonphp_fuzz_request_budget": int(nonphp_budget),
    "max_seconds_per_cell": int(max_seconds),
    "concurrent_applications": int(jobs),
    "max_corpus_size": int(max_corpus),
    "compose_up_attempts": int(compose_up_attempts),
    "compose_up_retry_delay_seconds": int(compose_up_retry_delay),
    "modes": modes.split(),
    "bitmap_hashes": bitmap_hashes.split(),
    "applications": apps.split(),
    "nonphp_reference_mode": "reset",
    "endpoint_files": {},
}
for app in payload["applications"]:
    path = Path(endpoint_dir) / f"{app}.txt"
    payload["endpoint_files"][app] = {
        "path": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
Path(output).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

build_matrix() {
    python3 - "$CELL_DIR" "$MATRIX_CSV" <<'PY'
import csv
import json
import sys
from pathlib import Path

cell_dir, output = map(Path, sys.argv[1:])
rows = [json.loads(path.read_text(encoding="utf-8")) for path in cell_dir.glob("*.json")]
rows.sort(key=lambda row: (row.get("app", ""), row.get("mode", ""), row.get("bitmap_hash", "")))
fields = [
    "timestamp",
    "app",
    "runtime",
    "mode",
    "mode_label",
    "bitmap_hash",
    "platform_oracle",
    "status",
    "failure",
    "endpoint_count",
    "endpoint_sha256",
    "fuzz_request_budget",
    "final_fuzz_requests",
    "completion_reason",
    "runner_return_code",
    "wall_seconds",
    "records",
    "complete_records",
    "unique_requests",
    "missing_code_hash_records",
    "missing_bitmap_hash_records",
    "comparable_pairs",
    "true_positive",
    "false_negative_merge",
    "false_positive_split",
    "true_negative",
    "alignment_rate",
    "tpr",
    "tnr",
    "fpr",
    "fnr",
    "precision",
    "f1",
    "accuracy",
    "balanced_accuracy",
    "matthews_corrcoef",
    "adjusted_rand_index",
    "request_feedback_file",
    "alignment_summary_file",
    "pairs_csv",
]
with output.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
print(f"Wrote feedback-quality matrix: {output} ({len(rows)} cells)")
PY
}

INTERNAL_APP=""
if [ "${1:-}" = "--internal-run-app" ]; then
    [ "$#" -eq 2 ] || { echo "ERROR: internal worker requires one app" >&2; exit 2; }
    INTERNAL_APP="$2"
fi

if [ -n "$INTERNAL_APP" ]; then
    is_supported_app "$INTERNAL_APP" || exit 2
    run_app "$INTERNAL_APP"
    exit $?
fi

declare -a requested_apps=()
declare -a requested_modes=()
if [ -n "${APPS:-}" ]; then
    read -r -a requested_apps <<< "$APPS"
fi
if [ -n "${MODES:-}" ]; then
    read -r -a requested_modes <<< "$MODES"
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        -j|--jobs)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            JOBS="$2"; shift 2 ;;
        --apps)
            shift
            while [ "$#" -gt 0 ] && [[ "$1" != -* ]]; do requested_apps+=("$1"); shift; done
            ;;
        --modes)
            shift
            while [ "$#" -gt 0 ] && [[ "$1" != -* ]]; do requested_modes+=("$1"); shift; done
            ;;
        --php-fuzz-requests)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            PHP_FUZZ_REQUEST_BUDGET="$2"; shift 2 ;;
        --nonphp-fuzz-requests)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            NONPHP_FUZZ_REQUEST_BUDGET="$2"; shift 2 ;;
        --max-seconds)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            MAX_SECONDS="$2"; shift 2 ;;
        --max-corpus-size)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            MAX_CORPUS_SIZE="$2"; shift 2 ;;
        --compose-up-attempts)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            COMPOSE_UP_ATTEMPTS="$2"; shift 2 ;;
        --compose-up-retry-delay)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            COMPOSE_UP_RETRY_DELAY="$2"; shift 2 ;;
        --result-dir)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            RESULT_DIR="$(realpath -m "$2")"; shift 2 ;;
        --endpoint-source-dir)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            ENDPOINT_SOURCE_DIR="$(realpath -m "$2")"; shift 2 ;;
        --bitmap-hash)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            case "$2" in
                index)  BITMAP_HASH_LIST="index" ;;
                bucket) BITMAP_HASH_LIST="bucket" ;;
                both)   BITMAP_HASH_LIST="index bucket" ;;
                *) echo "ERROR: --bitmap-hash must be index, bucket or both (got '$2')" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --write-pairs) WRITE_PAIRS_CSV=1; shift ;;
        --no-write-pairs) WRITE_PAIRS_CSV=0; shift ;;
        --no-resume) RESUME=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; requested_apps+=("$@"); break ;;
        -*) echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        *) requested_apps+=("$1"); shift ;;
    esac
done

[ "${#requested_apps[@]}" -gt 0 ] || requested_apps=("${DEFAULT_APPS[@]}")
[ "${#requested_modes[@]}" -gt 0 ] || requested_modes=("${DEFAULT_MODES[@]}")
set_result_paths

require_positive_integer JOBS "$JOBS" || exit 2
require_positive_integer PHP_FUZZ_REQUEST_BUDGET "$PHP_FUZZ_REQUEST_BUDGET" || exit 2
require_positive_integer NONPHP_FUZZ_REQUEST_BUDGET "$NONPHP_FUZZ_REQUEST_BUDGET" || exit 2
require_nonnegative_integer MAX_SECONDS "$MAX_SECONDS" || exit 2
require_nonnegative_integer MAX_CORPUS_SIZE "$MAX_CORPUS_SIZE" || exit 2
require_positive_integer COMPOSE_UP_ATTEMPTS "$COMPOSE_UP_ATTEMPTS" || exit 2
require_nonnegative_integer COMPOSE_UP_RETRY_DELAY "$COMPOSE_UP_RETRY_DELAY" || exit 2
require_nonnegative_integer REQUEST_FEEDBACK_SYNC_INTERVAL "$REQUEST_FEEDBACK_SYNC_INTERVAL" || exit 2
require_nonnegative_integer FEEDBACK_CAPTURE_SYNC_INTERVAL "$FEEDBACK_CAPTURE_SYNC_INTERVAL" || exit 2
require_positive_integer NONPHP_COVERAGE_SAMPLE_TIMEOUT "$NONPHP_COVERAGE_SAMPLE_TIMEOUT" || exit 2
require_positive_integer NONPHP_COVERAGE_SAMPLE_TIMEOUT_SLOW "$NONPHP_COVERAGE_SAMPLE_TIMEOUT_SLOW" || exit 2
require_positive_integer EXTERNAL_COVERAGE_TIMEOUT "$EXTERNAL_COVERAGE_TIMEOUT" || exit 2
case "$RESUME" in 0|1) ;; *) echo "ERROR: RESUME must be 0 or 1" >&2; exit 2 ;; esac
case "$DRY_RUN" in 0|1) ;; *) echo "ERROR: DRY_RUN must be 0 or 1" >&2; exit 2 ;; esac
case "$WRITE_PAIRS_CSV" in 0|1) ;; *) echo "ERROR: WRITE_PAIRS_CSV must be 0 or 1" >&2; exit 2 ;; esac
[ -n "$BITMAP_HASH_LIST" ] || { echo "ERROR: BITMAP_HASH_LIST must not be empty" >&2; exit 2; }
for hash in $BITMAP_HASH_LIST; do
    case "$hash" in
        index|bucket) ;;
        *) echo "ERROR: unsupported bitmap hash relation '$hash' (use index and/or bucket)" >&2; exit 2 ;;
    esac
done

declare -A seen_apps=()
for app in "${requested_apps[@]}"; do
    validate_identifier application "$app" || exit 2
    is_supported_app "$app" || { echo "ERROR: unsupported application '$app'" >&2; exit 2; }
    [ -z "${seen_apps[$app]:-}" ] || { echo "ERROR: duplicate application '$app'" >&2; exit 2; }
    seen_apps["$app"]=1
done
declare -A seen_modes=()
for mode in "${requested_modes[@]}"; do
    validate_identifier mode "$mode" || exit 2
    is_supported_mode "$mode" || { echo "ERROR: unsupported mode '$mode'" >&2; exit 2; }
    [ -z "${seen_modes[$mode]:-}" ] || { echo "ERROR: duplicate mode '$mode'" >&2; exit 2; }
    seen_modes["$mode"]=1
done

[ -x "$CAMPAIGN_RUNNER" ] || { echo "ERROR: missing campaign runner: $CAMPAIGN_RUNNER" >&2; exit 2; }
[ -r "$ANALYZER" ] || { echo "ERROR: missing analyzer: $ANALYZER" >&2; exit 2; }
command -v setsid >/dev/null 2>&1 || { echo "ERROR: setsid is required" >&2; exit 2; }

mkdir -p "$RESULT_DIR" "$REQUEST_FEEDBACK_DIR" "$ANALYSIS_DIR" "$PAIR_DIR" \
    "$CELL_DIR" "$LOG_DIR" "$ENDPOINT_DIR"
for app in "${requested_apps[@]}"; do
    source_file="$ENDPOINT_SOURCE_DIR/${app}.txt"
    [ -s "$source_file" ] || { echo "ERROR: missing endpoint file: $source_file" >&2; exit 2; }
    count="$(grep -Evc '^[[:space:]]*(#|$)' "$source_file")"
    [ "$count" -eq 10 ] || { echo "ERROR: expected 10 endpoints in $source_file, found $count" >&2; exit 2; }
    write_absolute_endpoint_file "$app" "$source_file" "$ENDPOINT_DIR/${app}.txt"
    generated_count="$(grep -Evc '^[[:space:]]*(#|$)' "$ENDPOINT_DIR/${app}.txt")"
    [ "$generated_count" -eq 10 ] || {
        echo "ERROR: endpoint normalization produced $generated_count entries for $app" >&2
        exit 2
    }
done

APP_LIST="${requested_apps[*]}"
MODE_LIST="${requested_modes[*]}"
export RESULT_DIR ENDPOINT_SOURCE_DIR PHP_FUZZ_REQUEST_BUDGET NONPHP_FUZZ_REQUEST_BUDGET
export MAX_SECONDS JOBS MAX_CORPUS_SIZE REQUEST_FEEDBACK_SYNC_INTERVAL
export FEEDBACK_CAPTURE_SYNC_INTERVAL NONPHP_COVERAGE_SAMPLE_TIMEOUT NONPHP_COVERAGE_SAMPLE_TIMEOUT_SLOW
export EXTERNAL_COVERAGE_TIMEOUT SINGLE_ENDPOINT_VALIDATE_TIMEOUT PYTHONHASHSEED
export COMPOSE_UP_ATTEMPTS COMPOSE_UP_RETRY_DELAY
export RESUME DRY_RUN WRITE_PAIRS_CSV BITMAP_HASH_LIST REQUEST_FEEDBACK_DIR ANALYSIS_DIR PAIR_DIR
export CELL_DIR LOG_DIR ENDPOINT_DIR MATRIX_CSV CONFIG_JSON APP_LIST MODE_LIST
export CAMPAIGN_RUNNER ANALYZER

if [ "$RESUME" = "1" ] && [ -s "$CONFIG_JSON" ]; then
    echo "Preserving existing campaign configuration for resume: $CONFIG_JSON"
else
    write_config
fi

echo "================ fixed-endpoint feedback-quality campaign ================"
echo "apps                   : $APP_LIST"
echo "modes                  : $MODE_LIST"
echo "endpoints              : 10 per app, blended"
echo "PHP fuzz requests      : $PHP_FUZZ_REQUEST_BUDGET per cell"
echo "non-PHP fuzz requests  : $NONPHP_FUZZ_REQUEST_BUDGET per cell"
echo "non-PHP reference      : reset-mode platform line coverage"
echo "request phase          : fuzz only"
echo "concurrent apps        : $JOBS"
echo "Compose start retries  : $COMPOSE_UP_ATTEMPTS attempts, ${COMPOSE_UP_RETRY_DELAY}s delay"
echo "result dir             : $RESULT_DIR"
echo "bitmap hash relations  : $BITMAP_HASH_LIST"
echo "write pair CSVs        : $WRITE_PAIRS_CSV"
echo "========================================================================="

if [ "$DRY_RUN" = "1" ]; then
    for app in "${requested_apps[@]}"; do
        echo "$app runtime=$(runtime_for_app "$app") oracle=$(oracle_for_app "$app") budget=$(budget_for_app "$app")"
        echo "  endpoints: $ENDPOINT_DIR/${app}.txt"
        for mode in "${requested_modes[@]}"; do
            for hash in $BITMAP_HASH_LIST; do
                echo "  cell: $mode ($(mode_label "$mode")) bitmap_hash=$hash"
            done
        done
    done
    echo "Dry run complete. Docker was not started."
    exit 0
fi

declare -A running_apps=()
declare -a failed_apps=()

stop_children() {
    local exit_code="$1" pid
    trap - INT TERM
    for pid in "${!running_apps[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
    for pid in "${!running_apps[@]}"; do wait "$pid" 2>/dev/null || true; done
    build_matrix || true
    exit "$exit_code"
}
trap 'stop_children 130' INT
trap 'stop_children 143' TERM

launch_app() {
    local app="$1" pid
    setsid "$SCRIPT_PATH" --internal-run-app "$app" &
    pid=$!
    running_apps["$pid"]="$app"
    echo "Launched app=$app pid=$pid (${#running_apps[@]}/$JOBS slots active)"
}

reap_one() {
    local completed_pid="" app rc
    local -a pids=("${!running_apps[@]}")
    if wait -n -p completed_pid "${pids[@]}"; then rc=0; else rc=$?; fi
    app="${running_apps[$completed_pid]:-unknown}"
    unset 'running_apps[$completed_pid]'
    if [ "$rc" -eq 0 ]; then
        echo "Application app=$app completed successfully"
    else
        echo "ERROR: application app=$app failed with exit code $rc" >&2
        failed_apps+=("$app:$rc")
    fi
}

for app in "${requested_apps[@]}"; do
    while [ "${#running_apps[@]}" -ge "$JOBS" ]; do reap_one; done
    launch_app "$app"
done
while [ "${#running_apps[@]}" -gt 0 ]; do reap_one; done

build_matrix
if [ "${#failed_apps[@]}" -gt 0 ]; then
    echo "Feedback-quality campaign finished with failures: ${failed_apps[*]}" >&2
    exit 1
fi
echo "Feedback-quality campaign completed: $RESULT_DIR"
