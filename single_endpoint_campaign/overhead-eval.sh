#!/usr/bin/env bash

set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT_PATH="$HERE/$(basename "$0")"
CAMPAIGN_RUNNER="${CAMPAIGN_RUNNER:-$ROOT/eval/run_campaign_v6.sh}"
ANALYZER="${ANALYZER:-$ROOT/eval/compare_request_feedback_hashes.py}"
COMBINED_FEEDBACK_EVAL="${COMBINED_FEEDBACK_EVAL:-0}"
RECORD_MODE_FEEDBACK_HASHES="${RECORD_MODE_FEEDBACK_HASHES:-0}"
PROGRAM_NAME="${OVERHEAD_EVAL_PROGRAM_NAME:-$(basename "$0")}"

PHP_APPS=(wordpress hotcrp phpbb joomla bagisto drupal prestashop zencart)
NONPHP_APPS=(ghost redmine gogs huginn superset wikijs petclinic roller)
DEFAULT_APPS=("${PHP_APPS[@]}" "${NONPHP_APPS[@]}")
DEFAULT_MODES=(blackbox native tracelib_ebpf_simple tracelib_ebpf)

RUN_ID="${OVERHEAD_EVAL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [ "$COMBINED_FEEDBACK_EVAL" = "1" ]; then
    DEFAULT_RESULT_NAME="overhead_feedback_eval_$RUN_ID"
else
    DEFAULT_RESULT_NAME="overhead_eval_$RUN_ID"
fi
RESULT_DIR="${RESULT_DIR:-$ROOT/eval_result_single_endpoint/$DEFAULT_RESULT_NAME}"
ENDPOINT_SOURCE_DIR="${ENDPOINT_SOURCE_DIR:-$HERE/default_endpoints}"
PHP_FUZZ_REQUEST_BUDGET="${PHP_FUZZ_REQUEST_BUDGET:-1000}"
NONPHP_FUZZ_REQUEST_BUDGET="${NONPHP_FUZZ_REQUEST_BUDGET:-50}"
MAX_SECONDS="${MAX_SECONDS:-0}"
ACCEPTED_COMPLETION_REASONS="${ACCEPTED_COMPLETION_REASONS:-budget_reached empty_queue}"
JOBS="${CONCURRENT_CAMPAIGNS:-${JOBS:-1}}"
MAX_CORPUS_SIZE="${MAX_CORPUS_SIZE:-400}"
REPETITIONS="${REPETITIONS:-1}"
SINGLE_ENDPOINT_VALIDATE_TIMEOUT="${SINGLE_ENDPOINT_VALIDATE_TIMEOUT:-20}"
COMPOSE_UP_ATTEMPTS="${COMPOSE_UP_ATTEMPTS:-3}"
COMPOSE_UP_RETRY_DELAY="${COMPOSE_UP_RETRY_DELAY:-15}"
PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
BLACKBOX_CORPUS_MODE="${BLACKBOX_CORPUS_MODE:-keep-submitted}"
BLACKBOX_MAX_CORPUS_SIZE="${BLACKBOX_MAX_CORPUS_SIZE:-50000}"
export BLACKBOX_MAX_CORPUS_SIZE
SIDECAR_SAMPLE_INTERVAL="${SIDECAR_SAMPLE_INTERVAL:-86400}"
RESUME="${RESUME:-1}"
DRY_RUN="${DRY_RUN:-0}"
REQUEST_FEEDBACK_SYNC_INTERVAL="${REQUEST_FEEDBACK_SYNC_INTERVAL:-30}"
FEEDBACK_CAPTURE_SYNC_INTERVAL="${FEEDBACK_CAPTURE_SYNC_INTERVAL:-$REQUEST_FEEDBACK_SYNC_INTERVAL}"
NONPHP_COVERAGE_SAMPLE_TIMEOUT="${NONPHP_COVERAGE_SAMPLE_TIMEOUT:-12}"
EXTERNAL_COVERAGE_TIMEOUT="${WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT:-20}"
WRITE_PAIRS_CSV="${WRITE_PAIRS_CSV:-0}"
IDENTICAL_REQUEST_REPLAY="${IDENTICAL_REQUEST_REPLAY:-0}"

set_result_paths() {
    ENDPOINT_DIR="$RESULT_DIR/endpoints"
    CELL_DIR="$RESULT_DIR/cells"
    TIMING_DIR="$RESULT_DIR/timings"
    LOG_DIR="$RESULT_DIR/campaign_logs"
    CONFIG_JSON="$RESULT_DIR/overhead_config.json"
    MATRIX_CSV="$RESULT_DIR/overhead_matrix.csv"
    REQUEST_TIMINGS_CSV="$RESULT_DIR/request_timings.csv"
    OVERHEAD_SERIES_CSV="$RESULT_DIR/overhead_over_time.csv"
    OVERHEAD_SUMMARY_CSV="$RESULT_DIR/overhead_summary.csv"
    REQUEST_FEEDBACK_DIR="$RESULT_DIR/request_feedback"
    ANALYSIS_DIR="$RESULT_DIR/alignment"
    PAIR_DIR="$RESULT_DIR/pairs"
    FEEDBACK_MATRIX_CSV="$RESULT_DIR/feedback_quality_matrix.csv"
    FEEDBACK_SUMMARY_CSV="$RESULT_DIR/feedback_summary.csv"
    FEEDBACK_CONFIG_JSON="$RESULT_DIR/feedback_quality_config.json"
    COMBINED_REPORT_MD="$RESULT_DIR/combined_report.md"
    REQUEST_BASELINE_DIR="$RESULT_DIR/request_baselines"
    FEEDBACK_HASH_DIR="$RESULT_DIR/feedback_hashes"
    MODE_FEEDBACK_HASHES_CSV="$RESULT_DIR/mode_feedback_hashes.csv"
}
set_result_paths

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME [options] [APP ...]

Measure request-processing overhead for TraceLib Bigram, N-gram, and their
strict filtered variants against a Blackbox baseline. Applications are run with the
fixed-endpoint configuration used by apps_feedback.sh.

EOF
    if [ "$COMBINED_FEEDBACK_EVAL" = "1" ]; then
        cat <<EOF
The same TraceLib cells also capture per-request platform and bitmap hashes,
so one campaign produces both overhead and feedback-quality reports.

EOF
    fi
    cat <<EOF
Defaults:
  applications          all 8 PHP and 6 non-PHP applications
  PHP modes             blackbox, Native, TraceLib Bigram/N-gram and filtered variants
  non-PHP modes         blackbox, TraceLib Bigram/N-gram and filtered variants
                        (Native is inapplicable)
  endpoint schedule     the existing 10 seeds per app, blended
  PHP fuzz requests     $PHP_FUZZ_REQUEST_BUDGET per app/mode/repetition
  non-PHP fuzz requests $NONPHP_FUZZ_REQUEST_BUDGET per app/mode/repetition
  repetitions           $REPETITIONS
  concurrent apps       $JOBS; modes for one app are always sequential

Options:
  -j, --jobs N                    Concurrent applications (default: $JOBS)
      --apps APP...               Select applications (positional APP also works)
      --modes MODE...             Select modes; blackbox and PHP-native are required
      --php-fuzz-requests N       PHP request budget (default: 1000)
      --nonphp-fuzz-requests N    Non-PHP request budget (default: 50)
      --repetitions N             Repetitions per app/mode (default: 1)
      --max-seconds N             Safety cap per cell; 0 disables it (default: 0)
      --max-corpus-size N         Retained corpus cap (default: 400)
      --compose-up-attempts N     Compose build/start attempts (default: 3)
      --compose-up-retry-delay N  Seconds between Compose attempts (default: 15)
      --result-dir DIR            Result directory
      --endpoint-source-dir DIR   Directory containing APP.txt endpoint files
      --write-pairs               Write every comparable feedback pair to CSV
      --no-write-pairs            Do not write quadratic pair CSVs (default)
      --record-feedback-hashes    Record each measured mode's compact feedback hash
      --no-record-feedback-hashes Disable per-mode hash recording (default)
      --no-resume                 Re-run cells already marked complete
      --identical-request-replay  Generate with Blackbox, then replay in every measured mode
      --independent-requests      Let each mode generate its own requests (default)
      --dry-run                   Validate and print the schedule without Docker
  -h, --help                      Show this help

Outputs:
  timings/APP_MODE_rNN_requests.csv  raw per-request timing observations
  request_timings.csv                all raw timing observations
  overhead_over_time.csv             graph-ready deltas against Blackbox
  overhead_summary.csv               per-cell final/median overhead summary
  overhead_matrix.csv                cell status and artifact inventory
  overhead_config.json               complete campaign configuration
  request_baselines/APP_rNN.jsonl    canonical Blackbox requests for identical replay
  request_baselines/APP_rNN.meta.json durable generator completion/integrity manifest
  feedback_hashes/APP_MODE_rNN.jsonl per-request mode feedback hashes (when enabled)
  mode_feedback_hashes.csv              combined per-mode hash observations
EOF
    if [ "$COMBINED_FEEDBACK_EVAL" = "1" ]; then
        cat <<EOF
  request_feedback/APP_MODE_rNN_requests.json
  alignment/APP_MODE_rNN_alignment_summary.json
  pairs/APP_MODE_rNN_alignment_pairs.csv    only with --write-pairs
  feedback_quality_matrix.csv               per-cell feedback-quality report
  feedback_summary.csv                      aggregate feedback report by mode
  feedback_quality_config.json              feedback campaign configuration
  combined_report.md                        readable overhead + feedback report
EOF
    fi
    cat <<EOF

The default JOBS=1 avoids host-contention bias. Existing campaigns are never
stopped; a selected application is collision-checked before every cell.
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

completion_reason_is_accepted() {
    local actual="$1" accepted
    for accepted in $ACCEPTED_COMPLETION_REASONS; do
        [ "$actual" = "$accepted" ] && return 0
    done
    return 1
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
        blackbox|native|tracelib_ebpf_simple|tracelib_ebpf|tracelib_bigram_file_sql_filtered) return 0 ;;
        *) return 1 ;;
    esac
}

is_tracelib_mode() {
    case "$1" in
        tracelib_ebpf_simple|tracelib_ebpf|tracelib_bigram_file_sql_filtered) return 0 ;;
        *) return 1 ;;
    esac
}

mode_applies_to_app() {
    local app="$1" mode="$2"
    [ "$mode" != "native" ] || is_php_app "$app"
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

budget_for_app() {
    if is_php_app "$1"; then
        echo "$PHP_FUZZ_REQUEST_BUDGET"
    else
        echo "$NONPHP_FUZZ_REQUEST_BUDGET"
    fi
}

mode_label() {
    case "$1" in
        blackbox) echo "Blackbox baseline" ;;
        native) echo "Native AST-edge baseline" ;;
        tracelib_ebpf_simple) echo "TraceLib Bigram" ;;
        tracelib_ebpf) echo "TraceLib N-gram" ;;
        tracelib_bigram_file_sql_filtered) echo "TraceLib Bigram (projected file/SQL)" ;;
    esac
}

request_baseline_file() {
    local app="$1" repetition="$2"
    printf '%s/%s_r%02d.jsonl\n' "$REQUEST_BASELINE_DIR" "$app" "$repetition"
}

request_baseline_metadata_file() {
    local app="$1" repetition="$2"
    printf '%s/%s_r%02d.meta.json\n' "$REQUEST_BASELINE_DIR" "$app" "$repetition"
}

request_baseline_count() {
    local path="$1"
    awk 'NF { count += 1 } END { print count + 0 }' "$path"
}

write_request_baseline_metadata() {
    local cell_file="$1" metadata_file="$2"
    python3 - "$cell_file" "$metadata_file" <<'PY'
import json
import sys
from pathlib import Path

cell_path, metadata_path = map(Path, sys.argv[1:])
cell = json.loads(cell_path.read_text(encoding="utf-8"))
if (
    cell.get("status") not in ("complete", "complete_partial")
    or cell.get("request_workload") != "blackbox_recorded_baseline"
    or not cell.get("request_identity_verified")
):
    raise SystemExit("refusing to publish metadata for an unverified request baseline")
payload = {
    **cell,
    "artifact_role": "request_baseline_generator",
    "source": "generator_cell_audit",
}
temporary = metadata_path.with_name(f".{metadata_path.name}.tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(metadata_path)
PY
}

oracle_for_app() {
    case "$1" in
        ghost|wikijs) echo c8_v8_lines ;;
        gogs) echo go_cover_lines ;;
        redmine|huginn) echo ruby_coverage_lines ;;
        superset) echo coverage_py_lines ;;
        petclinic|roller) echo jacoco_lines ;;
        *) echo native_ast_edges ;;
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
    local app="$1" active_processes active_containers extra_process_pattern="a^"
    [ "$DRY_RUN" = "0" ] || return 0
    if [ "$app" = "wordpress" ]; then
        extra_process_pattern='run_wordpress_multi_endpoint_test\.sh'
    fi
    active_processes="$(
        scan_pid="$BASHPID"
        pgrep -af 'run_campaign_v6\.sh|single_endpoint_campaign/run_all_apps_single_endpoint_campaign\.sh|single_endpoint_campaign/run\.py|webFuzz\.py|apps_feedback\.sh|overhead-eval\.sh|overhead-feedback-eval\.sh|[r]un_wordpress_multi_endpoint_test\.sh' 2>/dev/null \
            | grep -Ev "^($$|${scan_pid})[[:space:]]" \
            | grep -E "run_campaign_v6\\.sh[[:space:]]+${app}[[:space:]]|/endpoints/${app}\\.txt|(apps_feedback|overhead-eval|overhead-feedback-eval)\\.sh[[:space:]]+--internal-run-app[[:space:]]+${app}([[:space:]]|$)|${extra_process_pattern}" \
            || true
    )"
    if [ "$app" = "wordpress" ]; then
        active_containers="$(docker_names | grep -E -- "^campv6-.*-${app}-|^sewp-multi-" || true)"
    else
        active_containers="$(docker_names | grep -E -- "^campv6-.*-${app}-" || true)"
    fi
    if [ -n "$active_processes" ] || [ -n "$active_containers" ]; then
        echo "ERROR: app=$app collides with an active campaign process or container:" >&2
        [ -z "$active_processes" ] || printf '%s\n' "$active_processes" >&2
        [ -z "$active_containers" ] || printf '%s\n' "$active_containers" >&2
        return 2
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

analyze_capture() {
    local app="$1" mode="$2" repetition="$3" request_json="$4" rep_tag
    local summary_json pairs_csv
    rep_tag="r$(printf '%02d' "$repetition")"
    summary_json="$ANALYSIS_DIR/${app}_${mode}_${rep_tag}_alignment_summary.json"
    pairs_csv="$PAIR_DIR/${app}_${mode}_${rep_tag}_alignment_pairs.csv"

    python3 - "$request_json" "$app" "$mode" "$repetition" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
app, mode, repetition = sys.argv[2:]
records = json.loads(path.read_text(encoding="utf-8"))
if not isinstance(records, list) or not records:
    raise SystemExit(f"{app}/{mode}/r{int(repetition):02d}: no fuzz-phase feedback records")
code = sum(bool(item.get("code_coverage_hash")) for item in records)
bitmap = sum(bool(item.get("bitmap_coverage_hash")) for item in records)
both = sum(
    bool(item.get("code_coverage_hash")) and bool(item.get("bitmap_coverage_hash"))
    for item in records
)
print(
    f"{app}/{mode}/r{int(repetition):02d}: records={len(records)} "
    f"code_hashes={code} bitmap_hashes={bitmap} complete={both}"
)
if code == 0:
    raise SystemExit(f"{app}/{mode}: platform coverage produced no request hashes")
if bitmap == 0:
    raise SystemExit(f"{app}/{mode}: TraceLib produced no request bitmap hashes")
if both == 0:
    raise SystemExit(f"{app}/{mode}: no request has both feedback hashes")
PY
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    local -a analyzer_args=(
        "$request_json"
        --max-requests 0
        --summary-json "$summary_json"
    )
    if [ "$WRITE_PAIRS_CSV" = "1" ]; then
        analyzer_args+=( --pairs-csv "$pairs_csv" )
    fi
    python3 "$ANALYZER" "${analyzer_args[@]}"
}

cell_is_usable() {
    local path="$1" mode="$2" baseline_file="${3:-}"
    python3 - "$path" "$COMBINED_FEEDBACK_EVAL" "$mode" \
        "$IDENTICAL_REQUEST_REPLAY" "$baseline_file" \
        "$RECORD_MODE_FEEDBACK_HASHES" <<'PY' >/dev/null 2>&1
import hashlib
import json
import sys
from pathlib import Path

cell = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
combined, mode, identical_replay, baseline_path, record_mode_hashes = sys.argv[2:]
timing = Path(cell.get("request_timing_file", ""))
if cell.get("status") != "complete" or not timing.is_file() or timing.stat().st_size == 0:
    raise SystemExit(1)
if identical_replay == "1":
    baseline = Path(baseline_path)
    if not baseline.is_file() or baseline.stat().st_size == 0:
        raise SystemExit(1)
    with baseline.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    if (
        cell.get("request_workload") != "identical_request_replay"
        or not cell.get("request_identity_verified")
        or cell.get("request_baseline_sha256") != digest
    ):
        raise SystemExit(1)
if combined == "1" and mode in {"tracelib_ebpf_simple", "tracelib_ebpf", "tracelib_bigram_file_sql_filtered"}:
    feedback = Path(cell.get("request_feedback_file", ""))
    analysis = Path(cell.get("alignment_summary_file", ""))
    if (
        int(cell.get("complete_records", 0)) <= 0
        or not feedback.is_file()
        or feedback.stat().st_size == 0
        or not analysis.is_file()
        or analysis.stat().st_size == 0
    ):
        raise SystemExit(1)
if record_mode_hashes == "1":
    hashes = Path(cell.get("mode_feedback_hash_file", ""))
    if (
        not cell.get("feedback_hash_capture_enabled")
        or int(cell.get("feedback_hash_records", 0)) <= 0
        or not hashes.is_file()
        or hashes.stat().st_size == 0
    ):
        raise SystemExit(1)
PY
}

request_baseline_is_usable() {
    local baseline_file="$1" metadata_file="$2" generator_log="$3"
    python3 - "$baseline_file" "$metadata_file" "$generator_log" \
        "$ACCEPTED_COMPLETION_REASONS" <<'PY' >/dev/null 2>&1
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

baseline = Path(sys.argv[1])
metadata_path = Path(sys.argv[2])
generator_log = Path(sys.argv[3])
accepted_reasons = set(sys.argv[4].split())
if not baseline.is_file() or baseline.stat().st_size == 0:
    raise SystemExit(1)

record_count = 0
with baseline.open(encoding="utf-8") as source:
    for raw_line in source:
        if not raw_line.strip():
            continue
        record = json.loads(raw_line)
        record_count += 1
        if record.get("ordinal") != record_count:
            raise SystemExit(1)
        core = {key: value for key, value in record.items() if key != "request_sha256"}
        encoded = json.dumps(
            core, ensure_ascii=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        if record.get("request_sha256") != hashlib.sha256(encoded).hexdigest():
            raise SystemExit(1)
if record_count <= 0:
    raise SystemExit(1)
with baseline.open("rb") as handle:
    digest = hashlib.file_digest(handle, "sha256").hexdigest()

if metadata_path.is_file():
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if (
        metadata.get("status") not in ("complete", "complete_partial")
        or metadata.get("request_workload") != "blackbox_recorded_baseline"
        or not metadata.get("request_identity_verified")
        or int(metadata.get("request_baseline_records", 0)) != record_count
        or metadata.get("request_baseline_sha256") != digest
    ):
        raise SystemExit(1)
    raise SystemExit(0)

if not generator_log.is_file():
    raise SystemExit(1)
completion_reason = ""
with generator_log.open(encoding="utf-8", errors="replace") as source:
    for raw_line in source:
        marker = "completion_reason="
        if marker in raw_line:
            completion_reason = raw_line.split(marker, 1)[1].split()[0].strip()
if completion_reason not in accepted_reasons:
    raise SystemExit(1)
payload = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "artifact_role": "request_baseline_generator",
    "source": "recovered_from_legacy_generator_log",
    "status": "complete",
    "request_workload": "blackbox_recorded_baseline",
    "completion_reason": completion_reason,
    "request_baseline_file": str(baseline),
    "request_baseline_sha256": digest,
    "request_baseline_records": record_count,
    "request_identity_verified": True,
    "generator_log": str(generator_log),
}
temporary = metadata_path.with_name(f".{metadata_path.name}.tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(metadata_path)
PY
}

write_failure_cell() {
    local app="$1" mode="$2" repetition="$3" budget="$4" runner_rc="$5" reason="$6"
    local cell_file="$CELL_DIR/${app}_${mode}_r$(printf '%02d' "$repetition").json"
    python3 - "$cell_file" "$app" "$(runtime_for_app "$app")" "$mode" \
        "$(mode_label "$mode")" "$repetition" "$budget" "$runner_rc" "$reason" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path, app, runtime, mode, label, repetition, budget, runner_rc, reason = sys.argv[1:]
payload = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "app": app,
    "runtime": runtime,
    "mode": mode,
    "mode_label": label,
    "repetition": int(repetition),
    "status": "failed",
    "failure": reason,
    "endpoint_count": 10,
    "endpoint_schedule": "blend",
    "fuzz_request_budget": int(budget),
    "runner_return_code": int(runner_rc),
}
target = Path(path)
target.parent.mkdir(parents=True, exist_ok=True)
temporary = target.with_name(f".{target.name}.tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(target)
PY
}

extract_request_timings() {
    local fuzzer_log="$1" output_csv="$2" app="$3" mode="$4" repetition="$5"
    python3 - "$fuzzer_log" "$output_csv" "$app" "$(runtime_for_app "$app")" \
        "$mode" "$(mode_label "$mode")" "$repetition" <<'PY'
import csv
import json
import re
import sys
from datetime import datetime
from pathlib import Path

source, output, app, runtime, mode, mode_label, repetition = sys.argv[1:]
ansi = re.compile(r"\x1b\[[0-9;]*m")
prefix = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(\d{3})\]")
start_marker = "FUZZING PHASE STARTED:"
completion_marker = "Request Completed: "

def timestamp(line):
    match = prefix.match(line)
    if not match:
        return None
    return datetime.strptime(
        f"{match.group(1)}.{match.group(2)}", "%Y-%m-%d %H:%M:%S.%f"
    )

start = None
previous = None
records = []
for raw in Path(source).read_text(encoding="utf-8", errors="replace").splitlines():
    line = ansi.sub("", raw)
    current = timestamp(line)
    if current is None:
        continue
    if start_marker in line and start is None:
        start = current
        continue
    if completion_marker not in line:
        continue
    raw_payload = line.split(completion_marker, 1)[1]
    try:
        payload = json.loads(raw_payload)
        response_ms = float(payload.get("exec_time", 0.0)) * 1000.0
    except (json.JSONDecodeError, TypeError, ValueError):
        continue
    if start is None:
        start = current
    elapsed_s = max(0.0, (current - start).total_seconds())
    if previous is None:
        cycle_ms = elapsed_s * 1000.0
    else:
        cycle_ms = max(0.0, (current - previous).total_seconds() * 1000.0)
    previous = current
    records.append(
        {
            "app": app,
            "runtime": runtime,
            "mode": mode,
            "mode_label": mode_label,
            "repetition": int(repetition),
            "request_ordinal": len(records) + 1,
            "request_baseline_ordinal": payload.get("request_baseline_ordinal", ""),
            "request_sha256": payload.get("request_sha256", ""),
            "completion_timestamp_local": current.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3],
            "completed_elapsed_s": f"{elapsed_s:.3f}",
            "http_response_ms": f"{response_ms:.3f}",
            "request_cycle_ms": f"{cycle_ms:.3f}",
        }
    )

if not records:
    raise SystemExit(f"no completed-request timing records found in {source}")

fields = [
    "app",
    "runtime",
    "mode",
    "mode_label",
    "repetition",
    "request_ordinal",
    "request_baseline_ordinal",
    "request_sha256",
    "completion_timestamp_local",
    "completed_elapsed_s",
    "http_response_ms",
    "request_cycle_ms",
]
target = Path(output)
target.parent.mkdir(parents=True, exist_ok=True)
temporary = target.with_name(f".{target.name}.tmp")
with temporary.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    writer.writerows(records)
temporary.replace(target)
print(f"Extracted {len(records)} request timings: {target}")
PY
}

write_success_cell() {
    local app="$1" mode="$2" repetition="$3" budget="$4" runner_rc="$5" wall="$6"
    local summary="$7" endpoint_csv="$8" raw_csv="$9" fuzzer_log="${10}" timing_csv="${11}"
    local request_json="${12:-}" analysis_json="${13:-}" pairs_csv="${14:-}"
    local request_workload="${15:-independent_generation}" request_baseline="${16:-}"
    local mode_feedback_hash_file="${17:-}"
    local endpoint_file="$ENDPOINT_DIR/${app}.txt"
    local cell_file="$CELL_DIR/${app}_${mode}_r$(printf '%02d' "$repetition").json"

    python3 - "$cell_file" "$app" "$(runtime_for_app "$app")" "$mode" \
        "$(mode_label "$mode")" "$repetition" "$budget" "$runner_rc" "$wall" \
        "$summary" "$endpoint_csv" "$endpoint_file" "$raw_csv" "$fuzzer_log" \
        "$timing_csv" "$COMBINED_FEEDBACK_EVAL" "$(oracle_for_app "$app")" \
        "$request_json" "$analysis_json" "$pairs_csv" "$WRITE_PAIRS_CSV" \
        "$ACCEPTED_COMPLETION_REASONS" "$request_workload" "$request_baseline" \
        "$RECORD_MODE_FEEDBACK_HASHES" "$mode_feedback_hash_file" <<'PY'
import csv
import hashlib
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    cell_path,
    app,
    runtime,
    mode,
    mode_label,
    repetition,
    budget,
    runner_rc,
    wall,
    summary_path,
    endpoint_csv_path,
    endpoint_file_path,
    raw_csv_path,
    fuzzer_log_path,
    timing_csv_path,
    combined_feedback,
    platform_oracle,
    request_json_path,
    analysis_json_path,
    pairs_csv_path,
    write_pairs,
    accepted_completion_reasons,
    request_workload,
    request_baseline_path,
    record_mode_feedback_hashes,
    mode_feedback_hash_path,
) = sys.argv[1:]
budget = int(budget)
accepted_reasons = set(accepted_completion_reasons.split())

summary = {}
for raw in Path(summary_path).read_text(encoding="utf-8", errors="replace").splitlines():
    if raw == "--- fuzzstart ---":
        break
    if "=" in raw:
        key, value = raw.split("=", 1)
        summary[key] = value

errors = []
completion_reason = summary.get("completion_reason", "")
if completion_reason not in accepted_reasons:
    errors.append(f"completion_reason={completion_reason or 'missing'}")
if summary.get("single_endpoint_count") != "10":
    errors.append("single_endpoint_count is not 10")
if summary.get("single_endpoint_schedule") != "blend":
    errors.append("single_endpoint_schedule is not blend")

final_row = next(csv.reader([summary.get("final_csv_row", "")]), [])
final_fuzz_requests = int(final_row[18] or 0) if len(final_row) > 18 else 0
fuzz_elapsed_s = int(float(final_row[20] or 0)) if len(final_row) > 20 else 0

with Path(endpoint_csv_path).open(newline="", encoding="utf-8") as handle:
    endpoints = list(csv.DictReader(handle))
if len(endpoints) != 10 or any(
    row.get("method") != "GET"
    or row.get("http_status") != "200"
    or row.get("ok") != "yes"
    for row in endpoints
):
    errors.append("not all ten GET endpoint seeds validated successfully")

with Path(timing_csv_path).open(newline="", encoding="utf-8") as handle:
    timings = list(csv.DictReader(handle))
http = [float(row["http_response_ms"]) for row in timings]
cycle = [float(row["request_cycle_ms"]) for row in timings]
timing_records = len(timings)
if not timings:
    errors.append("no request timing observations")

request_identity_verified = False
request_baseline_sha256 = ""
request_baseline_records = 0
if request_workload in {"blackbox_recorded_baseline", "identical_request_replay"}:
    baseline_path = Path(request_baseline_path)
    if not baseline_path.is_file() or baseline_path.stat().st_size == 0:
        errors.append("request baseline is missing or empty")
    else:
        with baseline_path.open("rb") as handle:
            request_baseline_sha256 = hashlib.file_digest(handle, "sha256").hexdigest()
        baseline_valid = True
        identities_match = True
        observed_by_ordinal = {}
        try:
            for timing in timings:
                observed_ordinal = int(timing["request_baseline_ordinal"])
                if observed_ordinal in observed_by_ordinal:
                    identities_match = False
                observed_by_ordinal[observed_ordinal] = timing["request_sha256"]
        except (KeyError, TypeError, ValueError):
            identities_match = False
        try:
            with baseline_path.open(encoding="utf-8") as baseline_handle:
                for raw_line in baseline_handle:
                    if not raw_line.strip():
                        continue
                    record = json.loads(raw_line)
                    request_baseline_records += 1
                    expected_identity = (
                        int(record["ordinal"]),
                        str(record["request_sha256"]),
                    )
                    if expected_identity[0] != request_baseline_records:
                        baseline_valid = False
                    observed_digest = observed_by_ordinal.get(expected_identity[0])
                    if observed_digest is not None and observed_digest != expected_identity[1]:
                        identities_match = False
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"invalid request baseline: {exc}")
            baseline_valid = False
        identities_match = identities_match and all(
            1 <= ordinal <= request_baseline_records
            for ordinal in observed_by_ordinal
        )
        if request_workload == "blackbox_recorded_baseline":
            complete_population = baseline_valid
        else:
            complete_population = (
                request_baseline_records == len(timings)
                and len(observed_by_ordinal) == request_baseline_records
            )
        if (
            request_baseline_records
            and baseline_valid
            and identities_match
            and complete_population
        ):
            request_identity_verified = True
        elif request_baseline_records:
            errors.append(
                "request identities do not satisfy the workload audit "
                f"(baseline={request_baseline_records} submitted={final_fuzz_requests} "
                f"completed={len(timings)})"
            )

feedback_hash_capture_enabled = (
    record_mode_feedback_hashes == "1"
    and request_workload != "blackbox_recorded_baseline"
)
feedback_hash_records = 0
if feedback_hash_capture_enabled:
    hash_path = Path(mode_feedback_hash_path)
    hash_rows = []
    if not hash_path.is_file() or hash_path.stat().st_size == 0:
        errors.append("mode feedback hash artifact is missing or empty")
    else:
        try:
            with hash_path.open(encoding="utf-8") as hash_handle:
                for line_number, raw_line in enumerate(hash_handle, 1):
                    if not raw_line.strip():
                        continue
                    row = json.loads(raw_line)
                    if not isinstance(row, dict) or row.get("schema_version") != 1:
                        raise ValueError(f"invalid schema at line {line_number}")
                    hash_rows.append(row)
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            errors.append(f"invalid mode feedback hash artifact: {exc}")
            hash_rows = []

    feedback_hash_records = len(hash_rows)
    seen_hash_ordinals = set()
    expected_timing_identities = {}
    try:
        expected_timing_identities = {
            int(row["request_baseline_ordinal"]): str(row["request_sha256"])
            for row in timings
        }
    except (KeyError, TypeError, ValueError):
        errors.append("timing rows lack canonical identities for feedback hash audit")

    for row in hash_rows:
        try:
            ordinal = int(row["request_baseline_ordinal"])
            request_digest = str(row["request_sha256"])
        except (KeyError, TypeError, ValueError):
            errors.append("feedback hash row lacks a canonical request identity")
            break
        if ordinal in seen_hash_ordinals:
            errors.append(f"duplicate feedback hash ordinal {ordinal}")
            break
        seen_hash_ordinals.add(ordinal)
        if expected_timing_identities.get(ordinal) != request_digest:
            errors.append(f"feedback hash identity mismatch at ordinal {ordinal}")
            break
        if row.get("treatment_mode") != mode:
            errors.append(
                f"feedback hash treatment mismatch: expected {mode}, "
                f"got {row.get('treatment_mode')!r}"
            )
            break
        feedback_digest = row.get("feedback_sha256")
        if mode == "blackbox":
            valid_feedback = row.get("feedback_kind") == "none" and feedback_digest is None
        else:
            valid_feedback = (
                row.get("feedback_kind")
                in {"native_ast_edges", "tracelib_bitmap_indices"}
                and isinstance(feedback_digest, str)
                and len(feedback_digest) == 64
                and all(character in "0123456789abcdef" for character in feedback_digest)
            )
        if not valid_feedback:
            errors.append(f"invalid {mode} feedback hash at ordinal {ordinal}")
            break
    if feedback_hash_records != timing_records:
        errors.append(
            "feedback hash count does not match completed timings "
            f"(hashes={feedback_hash_records} timings={timing_records})"
        )
    if seen_hash_ordinals != set(expected_timing_identities):
        errors.append("feedback hash ordinals do not match completed timing ordinals")

alignment = None
feedback_partial = False
if combined_feedback == "1" and mode in {"tracelib_ebpf_simple", "tracelib_ebpf", "tracelib_bigram_file_sql_filtered"}:
    analysis_payload = json.loads(Path(analysis_json_path).read_text(encoding="utf-8"))
    alignment = analysis_payload["summary"]
    records = int(alignment["records"])
    complete_records = int(alignment["complete_records"])
    if complete_records <= 0:
        errors.append("no complete request-feedback observations")
    feedback_partial = records != final_fuzz_requests or complete_records != records

def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight

reason_completed = (
    completion_reason == "max_time_cap"
    or (completion_reason == "budget_reached" and final_fuzz_requests == budget)
)
timing_records_complete = (
    completion_reason == "max_time_cap"
    or timing_records == final_fuzz_requests
)
if errors:
    status = "failed"
elif (
    not reason_completed
    or not timing_records_complete
    or feedback_partial
):
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
    "repetition": int(repetition),
    "status": status,
    "failure": "; ".join(errors),
    "endpoint_count": 10,
    "endpoint_schedule": "blend",
    "endpoint_file": endpoint_file_path,
    "endpoint_sha256": hashlib.sha256(endpoint_bytes).hexdigest(),
    "fuzz_request_budget": budget,
    "final_fuzz_requests": final_fuzz_requests,
    "completion_reason": completion_reason,
    "runner_return_code": int(runner_rc),
    "wall_seconds": int(wall),
    "fuzz_elapsed_seconds": fuzz_elapsed_s,
    "timing_records": timing_records,
    "missing_timing_records": max(
        0,
        (
            request_baseline_records
            if request_workload == "blackbox_recorded_baseline"
            else final_fuzz_requests
        )
        - timing_records,
    ),
    "mean_http_response_ms": statistics.fmean(http) if http else None,
    "median_http_response_ms": statistics.median(http) if http else None,
    "p95_http_response_ms": percentile(http, 0.95),
    "mean_request_cycle_ms": statistics.fmean(cycle) if cycle else None,
    "median_request_cycle_ms": statistics.median(cycle) if cycle else None,
    "p95_request_cycle_ms": percentile(cycle, 0.95),
    "cumulative_cycle_ms_per_request": (
        1000.0
        * fuzz_elapsed_s
        / (
            request_baseline_records
            if request_workload == "blackbox_recorded_baseline"
            else final_fuzz_requests
        )
        if (
            request_baseline_records
            if request_workload == "blackbox_recorded_baseline"
            else final_fuzz_requests
        )
        > 0
        else None
    ),
    "raw_campaign_csv": raw_csv_path,
    "campaign_summary_file": summary_path,
    "endpoint_validation_csv": endpoint_csv_path,
    "fuzzer_log": fuzzer_log_path,
    "request_timing_file": timing_csv_path,
    "request_workload": request_workload,
    "request_baseline_file": request_baseline_path,
    "request_baseline_sha256": request_baseline_sha256,
    "request_baseline_records": request_baseline_records,
    "authoritative_submitted_requests": (
        request_baseline_records
        if request_workload == "blackbox_recorded_baseline"
        else final_fuzz_requests
    ),
    "sampled_counter_lag_requests": (
        request_baseline_records - final_fuzz_requests
        if request_workload == "blackbox_recorded_baseline"
        else 0
    ),
    "request_identity_verified": request_identity_verified,
    "request_cookie_policy": (
        "fresh_per_treatment_validation_cookies"
        if request_identity_verified
        else "independent_session"
    ),
    "feedback_hash_capture_enabled": feedback_hash_capture_enabled,
    "mode_feedback_hash_file": (
        mode_feedback_hash_path if feedback_hash_capture_enabled else ""
    ),
    "feedback_hash_records": feedback_hash_records,
    "feedback_capture_enabled": alignment is not None,
    "platform_oracle": platform_oracle if alignment is not None else "",
    "request_feedback_file": request_json_path if alignment is not None else "",
    "alignment_summary_file": analysis_json_path if alignment is not None else "",
    "pairs_csv": pairs_csv_path if alignment is not None and write_pairs == "1" else "",
    "records": int(alignment["records"]) if alignment is not None else None,
    "complete_records": int(alignment["complete_records"]) if alignment is not None else None,
    "unique_requests": int(alignment["unique_requests"]) if alignment is not None else None,
    "missing_code_hash_records": int(alignment["missing_code_hash_records"]) if alignment is not None else None,
    "missing_bitmap_hash_records": int(alignment["missing_bitmap_hash_records"]) if alignment is not None else None,
    "comparable_pairs": int(alignment["comparable_pairs"]) if alignment is not None else None,
    "true_positive": int(alignment["true_positive_code_diff_bitmap_diff"]) if alignment is not None else None,
    "false_negative_merge": int(alignment["false_merge_code_diff_bitmap_same"]) if alignment is not None else None,
    "false_positive_split": int(alignment["false_split_code_same_bitmap_diff"]) if alignment is not None else None,
    "true_negative": int(alignment["true_negative_code_same_bitmap_same"]) if alignment is not None else None,
    "alignment_rate": alignment["alignment_rate"] if alignment is not None else None,
}
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

run_overhead_cell() {
    local app="$1" mode="$2" repetition="$3" phase="${4:-measure}" budget runtime rep_tag
    local cell_file timing_csv cell_log cell_stamp started ended wall runner_rc
    local summary endpoint_csv raw_csv fuzzer_log completion_reason rc
    local request_json="" analysis_json="" pairs_csv="" request_feedback_file=""
    local nonphp_reference=0 platform_sample=0 platform_final_only=1
    local interval="$SIDECAR_SAMPLE_INTERVAL" fuzz_interval="$SIDECAR_SAMPLE_INTERVAL"
    local coverage_timeout=20 node_take_on_response=0 node_interval=0 stale_count=0
    local baseline_file baseline_metadata_file request_record_file="" request_replay_file=""
    local request_workload="independent_generation" cell_max_seconds="$MAX_SECONDS"
    local mode_feedback_hash_file=""

    budget="$(budget_for_app "$app")"
    runtime="$(runtime_for_app "$app")"
    rep_tag="r$(printf '%02d' "$repetition")"
    cell_file="$CELL_DIR/${app}_${mode}_${rep_tag}.json"
    timing_csv="$TIMING_DIR/${app}_${mode}_${rep_tag}_requests.csv"
    if [ "$phase" = "generate_baseline" ]; then
        cell_log="$LOG_DIR/overhead_${app}_${mode}_${rep_tag}_request_generator.log"
    else
        cell_log="$LOG_DIR/overhead_${app}_${mode}_${rep_tag}.log"
    fi
    baseline_file="$(request_baseline_file "$app" "$repetition")"
    baseline_metadata_file="$(request_baseline_metadata_file "$app" "$repetition")"

    if [ "$RECORD_MODE_FEEDBACK_HASHES" = "1" ] && [ "$phase" != "generate_baseline" ]; then
        mode_feedback_hash_file="$FEEDBACK_HASH_DIR/${app}_${mode}_${rep_tag}.jsonl"
    fi

    if [ "$IDENTICAL_REQUEST_REPLAY" = "1" ]; then
        if [ "$phase" = "generate_baseline" ]; then
            if [ "$mode" != "blackbox" ]; then
                echo "ERROR: only Blackbox may generate an identical-request baseline" >&2
                return 2
            fi
            request_record_file="$baseline_file"
            request_workload="blackbox_recorded_baseline"
        else
            if [ ! -s "$baseline_file" ]; then
                echo "ERROR: app=$app mode=$mode has no completed Blackbox request baseline: $baseline_file" >&2
                write_failure_cell "$app" "$mode" "$repetition" "$budget" 2 \
                    "Blackbox request baseline missing"
                return 2
            fi
            budget="$(request_baseline_count "$baseline_file")"
            if [ "$budget" -le 0 ] 2>/dev/null; then
                write_failure_cell "$app" "$mode" "$repetition" "$budget" 2 \
                    "Blackbox request baseline is empty"
                return 2
            fi
            request_replay_file="$baseline_file"
            request_workload="identical_request_replay"
            cell_max_seconds=0
        fi
    fi

    if [ "$COMBINED_FEEDBACK_EVAL" = "1" ] && is_tracelib_mode "$mode"; then
        request_json="$REQUEST_FEEDBACK_DIR/${app}_${mode}_${rep_tag}_requests.json"
        analysis_json="$ANALYSIS_DIR/${app}_${mode}_${rep_tag}_alignment_summary.json"
        pairs_csv="$PAIR_DIR/${app}_${mode}_${rep_tag}_alignment_pairs.csv"
        request_feedback_file="$request_json"
        platform_final_only=0
        if is_nonphp_app "$app"; then
            nonphp_reference=1
            platform_sample=0
            interval=60
            fuzz_interval=60
            coverage_timeout="$NONPHP_COVERAGE_SAMPLE_TIMEOUT"
            node_take_on_response=1
            node_interval=5000
        else
            platform_sample=1
            interval=60
            fuzz_interval=20
            coverage_timeout=20
            node_take_on_response=0
            node_interval=30000
        fi
    fi

    if [ "$phase" != "generate_baseline" ] \
       && [ "$RESUME" = "1" ] && [ -s "$cell_file" ] \
       && cell_is_usable "$cell_file" "$mode" "$baseline_file"; then
        echo "=== Skipping app=$app mode=$mode repetition=$repetition (complete cell exists) ==="
        return 0
    fi

    check_app_collision "$app"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        write_failure_cell "$app" "$mode" "$repetition" "$budget" "$rc" "active campaign collision"
        return "$rc"
    fi

    if [ "$COMBINED_FEEDBACK_EVAL" = "1" ] && is_tracelib_mode "$mode" \
       && is_nonphp_app "$app"; then
        stale_count="$(stale_platform_coverage_exec_count "$app" "$mode")"
        if [ "$stale_count" -gt 0 ] 2>/dev/null; then
            echo "ERROR: found $stale_count stale platform reporter process(es) for $app/$mode" >&2
            write_failure_cell "$app" "$mode" "$repetition" "$budget" 2 "stale platform coverage reporter"
            return 2
        fi
    fi

    cell_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    started="$(date +%s)"
    if [ -n "$mode_feedback_hash_file" ]; then
        : > "$mode_feedback_hash_file"
    fi
    echo "=== Starting app=$app mode=$mode repetition=$repetition phase=$phase budget=$budget workload=$request_workload paired_capture=$([ -n "$request_feedback_file" ] && echo enabled || echo disabled) ==="

    SINGLE_ENDPOINT_MODE=1 \
    SINGLE_ENDPOINT_FILE="$ENDPOINT_DIR/${app}.txt" \
    SINGLE_ENDPOINT_TIME_BUDGET=0 \
    SINGLE_ENDPOINT_BLEND=1 \
    SINGLE_ENDPOINT_VALIDATE=1 \
    SINGLE_ENDPOINT_VALIDATE_TIMEOUT="$SINGLE_ENDPOINT_VALIDATE_TIMEOUT" \
    FUZZ_REQUEST_BUDGET="$budget" \
    MAX_CORPUS_SIZE="$MAX_CORPUS_SIZE" \
    MAX_HOURS=0 \
    MAX_SECONDS="$cell_max_seconds" \
    INTERVAL="$interval" \
    FUZZ_INTERVAL="$fuzz_interval" \
    STATS_POLL_INTERVAL=1 \
    PLATFORM_COVERAGE_SAMPLE="$platform_sample" \
    PLATFORM_COVERAGE_FINAL_ONLY="$platform_final_only" \
    FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS=0 \
    NONPHP_REQUEST_FEEDBACK_REFERENCE="$nonphp_reference" \
    NONPHP_REQUEST_FEEDBACK_MODE=reset \
    COVERAGE_SAMPLE_TIMEOUT="$coverage_timeout" \
    WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT="$EXTERNAL_COVERAGE_TIMEOUT" \
    NODE_COVERAGE_TAKE_ON_RESPONSE="$node_take_on_response" \
    NODE_COVERAGE_INTERVAL_MS="$node_interval" \
    REQUEST_FEEDBACK_FILE="$request_feedback_file" \
    REQUEST_FEEDBACK_PHASE=fuzz \
    REQUEST_FEEDBACK_SYNC_INTERVAL="$REQUEST_FEEDBACK_SYNC_INTERVAL" \
    FEEDBACK_CAPTURE_SYNC_INTERVAL="$FEEDBACK_CAPTURE_SYNC_INTERVAL" \
    FEEDBACK_CAPTURE_DIR= \
    DISABLE_PCOV=1 \
    BLACKBOX_CORPUS_MODE="$BLACKBOX_CORPUS_MODE" \
    BLACKBOX_MAX_CORPUS_SIZE="$BLACKBOX_MAX_CORPUS_SIZE" \
    SINGLE_ENDPOINT_REQUEST_RECORD_FILE="$request_record_file" \
    SINGLE_ENDPOINT_REQUEST_REPLAY_FILE="$request_replay_file" \
    SINGLE_ENDPOINT_DISABLE_SESSION_CHECKS="$IDENTICAL_REQUEST_REPLAY" \
    COMPOSE_UP_ATTEMPTS="$COMPOSE_UP_ATTEMPTS" \
    COMPOSE_UP_RETRY_DELAY="$COMPOSE_UP_RETRY_DELAY" \
    AUTO_APP_SEED_FILE=0 \
    ENABLE_APP_SEEDS=0 \
    APP_SEED_URLS= \
    APP_SEED_FILE= \
    ALLOW_NON_HTML=1 \
    WEBFUZZ_FEEDBACK_HASH_FILE="$mode_feedback_hash_file" \
    WEBFUZZ_FEEDBACK_TREATMENT_MODE="$mode" \
    RESULT_DIR="$RESULT_DIR" \
    PYTHONHASHSEED="$PYTHONHASHSEED" \
        "$CAMPAIGN_RUNNER" "$app" "$mode" 2>&1 \
        | tee "$cell_log" \
        | sed -u "s|^|[$app/$mode/$rep_tag] |"
    runner_rc=${PIPESTATUS[0]}
    ended="$(date +%s)"
    wall=$((ended - started))

    summary="$(latest_file_since "*_${app}_${mode}_t0h_${cell_stamp}.summary.txt" "$started")"
    [ -n "$summary" ] || summary="$(latest_file_since "*_${app}_${mode}_t0h_*.summary.txt" "$started")"
    endpoint_csv="$(latest_file_since "*_${app}_${mode}_t0h_${cell_stamp}.endpoints.csv" "$started")"
    [ -n "$endpoint_csv" ] || endpoint_csv="$(latest_file_since "*_${app}_${mode}_t0h_*.endpoints.csv" "$started")"

    raw_csv=""
    fuzzer_log=""
    if [ -n "$summary" ]; then
        raw_csv="${summary%.summary.txt}.csv"
        fuzzer_log="${summary%.summary.txt}.fuzzer.log"
    fi
    if [ -z "$summary" ] || [ -z "$endpoint_csv" ] \
       || [ ! -s "$raw_csv" ] || [ ! -s "$fuzzer_log" ]; then
        echo "ERROR: app=$app mode=$mode repetition=$repetition did not produce required artifacts" >&2
        write_failure_cell "$app" "$mode" "$repetition" "$budget" "$runner_rc" "required campaign artifact missing"
        return 1
    fi

    completion_reason="$(sed -n 's/^completion_reason=//p' "$summary" | tail -n1)"
    if ! completion_reason_is_accepted "$completion_reason"; then
        echo "ERROR: app=$app mode=$mode repetition=$repetition completion_reason=${completion_reason:-missing}" >&2
        write_failure_cell "$app" "$mode" "$repetition" "$budget" "$runner_rc" "completion reason is ${completion_reason:-missing}"
        return 1
    fi
    if [ "$runner_rc" -ne 0 ] && [ "$runner_rc" -ne 5 ]; then
        echo "ERROR: app=$app mode=$mode repetition=$repetition runner returned $runner_rc" >&2
        write_failure_cell "$app" "$mode" "$repetition" "$budget" "$runner_rc" "unexpected runner return code"
        return "$runner_rc"
    fi

    if extract_request_timings "$fuzzer_log" "$timing_csv" "$app" "$mode" "$repetition"; then
        :
    else
        rc=$?
        write_failure_cell "$app" "$mode" "$repetition" "$budget" "$runner_rc" "request timing extraction failed"
        return "$rc"
    fi
    if [ -n "$request_feedback_file" ]; then
        if [ ! -s "$request_json" ]; then
            write_failure_cell "$app" "$mode" "$repetition" "$budget" "$runner_rc" "request feedback artifact missing"
            return 1
        fi
        if analyze_capture "$app" "$mode" "$repetition" "$request_json"; then
            :
        else
            rc=$?
            write_failure_cell "$app" "$mode" "$repetition" "$budget" "$runner_rc" "feedback alignment analysis failed"
            return "$rc"
        fi
    fi
    if ! write_success_cell "$app" "$mode" "$repetition" "$budget" "$runner_rc" "$wall" \
        "$summary" "$endpoint_csv" "$raw_csv" "$fuzzer_log" "$timing_csv" \
        "$request_json" "$analysis_json" "$pairs_csv" "$request_workload" \
        "$baseline_file" "$mode_feedback_hash_file"; then
        echo "ERROR: app=$app mode=$mode repetition=$repetition failed its cell integrity audit; preserving detailed metadata in $cell_file" >&2
        return 1
    fi
    if [ "$phase" = "generate_baseline" ]; then
        if ! write_request_baseline_metadata "$cell_file" "$baseline_metadata_file"; then
            echo "ERROR: could not publish verified request-baseline metadata: $baseline_metadata_file" >&2
            return 1
        fi
    fi
    echo "=== Completed app=$app mode=$mode repetition=$repetition ==="
}

run_app() {
    local app="$1" repetition mode rc=0 cell_rc ordered_modes="$MODE_LIST"
    local baseline_file baseline_metadata_file generator_log
    if [ "$IDENTICAL_REQUEST_REPLAY" = "1" ]; then
        ordered_modes="blackbox"
        for mode in $MODE_LIST; do
            [ "$mode" = "blackbox" ] || ordered_modes="$ordered_modes $mode"
        done
    fi
    for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
        if [ "$IDENTICAL_REQUEST_REPLAY" = "1" ]; then
            baseline_file="$(request_baseline_file "$app" "$repetition")"
            baseline_metadata_file="$(request_baseline_metadata_file "$app" "$repetition")"
            generator_log="$LOG_DIR/overhead_${app}_blackbox_r$(printf '%02d' "$repetition")_request_generator.log"
            if ! request_baseline_is_usable "$baseline_file" "$baseline_metadata_file" "$generator_log"; then
                echo "=== Generating one-hour Blackbox request baseline for app=$app repetition=$repetition ==="
                if run_overhead_cell "$app" blackbox "$repetition" generate_baseline; then
                    :
                else
                    cell_rc=$?
                    rc=1
                    echo "ERROR: cannot replay app=$app repetition=$repetition because Blackbox baseline generation failed (rc=$cell_rc)" >&2
                    continue
                fi
            else
                echo "=== Reusing verified Blackbox request baseline: $baseline_file ==="
            fi
        fi
        for mode in $ordered_modes; do
            mode_applies_to_app "$app" "$mode" || continue
            if run_overhead_cell "$app" "$mode" "$repetition"; then
                :
            else
                cell_rc=$?
                if [ ! -s "$CELL_DIR/${app}_${mode}_r$(printf '%02d' "$repetition").json" ]; then
                    write_failure_cell "$app" "$mode" "$repetition" \
                        "$(budget_for_app "$app")" "$cell_rc" \
                        "cell failed before campaign artifacts were produced"
                fi
                rc=1
            fi
        done
    done
    return "$rc"
}

write_config() {
    python3 - "$CONFIG_JSON" "$FEEDBACK_CONFIG_JSON" "$RESULT_DIR" "$ENDPOINT_SOURCE_DIR" \
        "$PHP_FUZZ_REQUEST_BUDGET" "$NONPHP_FUZZ_REQUEST_BUDGET" "$MAX_SECONDS" \
        "$JOBS" "$MAX_CORPUS_SIZE" "$REPETITIONS" "$MODE_LIST" "$APP_LIST" \
        "$ENDPOINT_DIR" "$COMPOSE_UP_ATTEMPTS" "$COMPOSE_UP_RETRY_DELAY" \
        "$SIDECAR_SAMPLE_INTERVAL" "$BLACKBOX_CORPUS_MODE" \
        "$COMBINED_FEEDBACK_EVAL" "$REQUEST_FEEDBACK_SYNC_INTERVAL" \
        "$FEEDBACK_CAPTURE_SYNC_INTERVAL" "$NONPHP_COVERAGE_SAMPLE_TIMEOUT" \
        "$EXTERNAL_COVERAGE_TIMEOUT" "$WRITE_PAIRS_CSV" \
        "$IDENTICAL_REQUEST_REPLAY" "$REQUEST_BASELINE_DIR" \
        "$RECORD_MODE_FEEDBACK_HASHES" "$FEEDBACK_HASH_DIR" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    output,
    feedback_output,
    result_dir,
    endpoint_source_dir,
    php_budget,
    nonphp_budget,
    max_seconds,
    jobs,
    max_corpus,
    repetitions,
    modes,
    apps,
    endpoint_dir,
    compose_attempts,
    compose_delay,
    sidecar_interval,
    blackbox_corpus_mode,
    combined_feedback,
    request_feedback_sync_interval,
    feedback_capture_sync_interval,
    nonphp_coverage_sample_timeout,
    external_coverage_timeout,
    write_pairs,
    identical_request_replay,
    request_baseline_dir,
    record_mode_feedback_hashes,
    feedback_hash_dir,
) = sys.argv[1:]
feedback_enabled = combined_feedback == "1"
php_apps = {"wordpress", "hotcrp", "phpbb", "joomla", "bagisto", "drupal", "prestashop", "zencart"}
selected_modes = modes.split()
selected_apps = apps.split()
has_php = any(app in php_apps for app in selected_apps)
payload = {
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "result_dir": result_dir,
    "endpoint_source_dir": endpoint_source_dir,
    "endpoint_schedule": "blend",
    "endpoints_per_app": 10,
    "php_fuzz_request_budget": int(php_budget),
    "nonphp_fuzz_request_budget": int(nonphp_budget),
    "max_seconds_per_cell": int(max_seconds),
    "concurrent_applications": int(jobs),
    "max_corpus_size": int(max_corpus),
    "repetitions": int(repetitions),
    "modes": selected_modes,
    "applications": selected_apps,
    "modes_by_application": {
        app: [mode for mode in selected_modes if mode != "native" or app in php_apps]
        for app in selected_apps
    },
    "baseline_mode": "blackbox",
    "baseline_modes": ["blackbox"] + (["native"] if has_php else []),
    "baseline_applicability": {
        "blackbox": "all applications",
        "native": "PHP applications only; Native AST-edge feedback",
    },
    "blackbox_corpus_mode": blackbox_corpus_mode,
    "identical_request_replay": identical_request_replay == "1",
    "request_workload_protocol": (
        {
            "generator": "blackbox",
            "generator_is_measured_cell": False,
            "record_format": "canonical cookie-free JSONL",
            "baseline_directory": request_baseline_dir,
            "measured_blackbox": "mutation-free replay of the generated sequence",
            "replay_order": "all measured modes use exact recorded order without mutation",
            "cookie_policy": "fresh endpoint-validation cookies per treatment",
            "session_checks": "disabled to avoid unpaired requests",
            "blackbox_time_cap_seconds": int(max_seconds),
            "replay_time_cap_seconds": None,
        }
        if identical_request_replay == "1"
        else {"generator": "independent per mode"}
    ),
    "compose_up_attempts": int(compose_attempts),
    "compose_up_retry_delay_seconds": int(compose_delay),
    "sidecar_sample_interval_seconds": int(sidecar_interval),
    "platform_coverage_sampling_during_fuzzing": (
        "feedback-enabled TraceLib cells only" if feedback_enabled else False
    ),
    "request_feedback_capture": feedback_enabled,
    "record_mode_feedback_hashes": record_mode_feedback_hashes == "1",
    "mode_feedback_hash_directory": (
        feedback_hash_dir if record_mode_feedback_hashes == "1" else None
    ),
    "mode_feedback_hash_semantics": (
        {
            "blackbox": "null (no feedback)",
            "native": "SHA-256 of the sorted set of covered Native AST edge labels",
            "tracelib": "SHA-256 of the sorted set of non-zero TraceLib bitmap indices",
            "alignment_key": ["request_baseline_ordinal", "request_sha256"],
        }
        if record_mode_feedback_hashes == "1"
        else None
    ),
    "request_feedback_phase": "fuzz" if feedback_enabled else None,
    "request_feedback_sync_interval": int(request_feedback_sync_interval),
    "feedback_capture_sync_interval": int(feedback_capture_sync_interval),
    "nonphp_reference_mode": "reset" if feedback_enabled else None,
    "nonphp_coverage_sample_timeout": int(nonphp_coverage_sample_timeout),
    "external_coverage_timeout": int(external_coverage_timeout),
    "write_feedback_pairs": write_pairs == "1",
    "feedback_reference_oracles": {
        "php": "Native AST edge coverage",
        "node": "V8 line coverage counted by c8",
        "go": "Go line coverage counted by go-cover",
        "ruby": "Ruby line coverage counted by Ruby Coverage",
        "python": "Python line coverage counted by coverage.py",
    },
    "timing_signals": {
        "http_response_ms": "aiohttp request/response duration from Node.exec_time",
        "request_cycle_ms": "completion-to-completion wall time including client feedback processing",
    },
    "overhead_comparison": {
        "baselines": ["blackbox"] + (["native (PHP only)"] if has_php else []),
        "match": (
            "same verified request SHA-256 and baseline ordinal"
            if identical_request_replay == "1"
            else "same completed-request ordinal within app and repetition"
        ),
        "interpretation": (
            "identical cookie-free HTTP method, URL, query, and body parameters; "
            "authentication cookies are refreshed per treatment"
            if identical_request_replay == "1"
            else "descriptive matched progress; feedback modes may execute different requests"
        ),
        "combined_feedback_caveat": (
            "TraceLib cycle timings include request-local platform/bitmap feedback collection; "
            "use HTTP response overhead to isolate the server-observed request path more closely"
            if feedback_enabled else None
        ),
    },
    "endpoint_files": {},
}
for app in payload["applications"]:
    path = Path(endpoint_dir) / f"{app}.txt"
    payload["endpoint_files"][app] = {
        "path": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
serialized = json.dumps(payload, indent=2) + "\n"
Path(output).write_text(serialized, encoding="utf-8")
if feedback_enabled:
    Path(feedback_output).write_text(serialized, encoding="utf-8")
PY
}

build_outputs() {
    python3 - "$CELL_DIR" "$MATRIX_CSV" "$REQUEST_TIMINGS_CSV" \
        "$OVERHEAD_SERIES_CSV" "$OVERHEAD_SUMMARY_CSV" "$COMBINED_FEEDBACK_EVAL" \
        "$FEEDBACK_MATRIX_CSV" "$FEEDBACK_SUMMARY_CSV" "$COMBINED_REPORT_MD" \
        "$MODE_FEEDBACK_HASHES_CSV" "$FEEDBACK_HASH_DIR" <<'PY'
import csv
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

cell_dir, matrix_path, timings_path, series_path, summary_path = map(Path, sys.argv[1:6])
combined_feedback = sys.argv[6] == "1"
feedback_matrix_path, feedback_summary_path, report_path = map(Path, sys.argv[7:10])
mode_feedback_hashes_path = Path(sys.argv[10])
feedback_hash_dir = Path(sys.argv[11])
mode_order = {
    "blackbox": 0,
    "native": 1,
    "tracelib_ebpf_simple": 2,
    "tracelib_ebpf": 3,
    "tracelib_bigram_file_sql_filtered": 4,
}
baseline_labels = {"blackbox": "Blackbox", "native": "Native AST edges"}

cells = [json.loads(path.read_text(encoding="utf-8")) for path in cell_dir.glob("*.json")]
cells.sort(key=lambda row: (row.get("app", ""), int(row.get("repetition", 0)), mode_order.get(row.get("mode", ""), 99)))

matrix_fields = [
    "timestamp", "app", "runtime", "mode", "mode_label", "repetition",
    "status", "failure", "endpoint_count", "endpoint_schedule", "endpoint_sha256",
    "fuzz_request_budget", "final_fuzz_requests", "completion_reason",
    "runner_return_code", "wall_seconds", "fuzz_elapsed_seconds", "timing_records",
    "missing_timing_records", "mean_http_response_ms", "median_http_response_ms",
    "p95_http_response_ms", "mean_request_cycle_ms", "median_request_cycle_ms",
    "p95_request_cycle_ms", "cumulative_cycle_ms_per_request", "raw_campaign_csv",
    "campaign_summary_file", "endpoint_validation_csv", "fuzzer_log", "request_timing_file",
    "request_workload", "request_baseline_file", "request_baseline_sha256",
    "request_baseline_records", "authoritative_submitted_requests",
    "sampled_counter_lag_requests", "request_identity_verified", "request_cookie_policy",
    "feedback_hash_capture_enabled", "mode_feedback_hash_file", "feedback_hash_records",
    "feedback_capture_enabled", "platform_oracle", "request_feedback_file",
    "alignment_summary_file", "pairs_csv", "records", "complete_records",
    "unique_requests", "missing_code_hash_records", "missing_bitmap_hash_records",
    "comparable_pairs", "true_positive", "false_negative_merge",
    "false_positive_split", "true_negative", "alignment_rate",
]

def atomic_csv(path, fields, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)

atomic_csv(matrix_path, matrix_fields, cells)

mode_feedback_hash_fields = [
    "app", "runtime", "mode", "mode_label", "repetition", "schema_version",
    "request_ordinal", "request_baseline_ordinal", "request_sha256", "method",
    "url", "http_status", "feedback_mode", "feedback_kind", "feature_count",
    "feedback_sha256", "timestamp_ns",
]
mode_feedback_hash_rows = []
cell_index_for_hashes = {
    (cell.get("app"), int(cell.get("repetition", 0)), cell.get("mode")): cell
    for cell in cells
}
mode_labels = {
    "blackbox": "Blackbox baseline",
    "native": "Native AST-edge baseline",
    "tracelib_ebpf_simple": "TraceLib Bigram",
    "tracelib_ebpf": "TraceLib N-gram",
    "tracelib_bigram_file_sql_filtered": "TraceLib Bigram (projected file/SQL)",
}
php_apps = {"wordpress", "hotcrp", "phpbb", "joomla", "bagisto", "drupal", "prestashop", "zencart"}
runtime_by_app = {
    **{app: "php" for app in php_apps},
 "ghost": "node", "": "node", "": "go", "": "go",
 "redmine": "ruby", "": "python",
}
for path in sorted(feedback_hash_dir.glob("*.jsonl")):
    app = mode = ""
    repetition = 0
    for candidate in sorted(mode_order, key=len, reverse=True):
        marker = f"_{candidate}_r"
        if marker not in path.stem:
            continue
        app, raw_repetition = path.stem.rsplit(marker, 1)
        mode = candidate
        try:
            repetition = int(raw_repetition)
        except ValueError:
            app = mode = ""
        break
    if not app or not mode or repetition <= 0:
        continue
    cell = cell_index_for_hashes.get((app, repetition, mode), {})
    with path.open(encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            if not raw_line.strip():
                continue
            try:
                record = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                continue
            mode_feedback_hash_rows.append({
                "app": cell.get("app", app),
                "runtime": cell.get("runtime", runtime_by_app.get(app, "")),
                "mode": mode,
                "mode_label": cell.get("mode_label", mode_labels.get(mode, mode)),
                "repetition": repetition,
                **record,
            })
mode_feedback_hash_rows.sort(key=lambda row: (
    row["app"], int(row["repetition"]), mode_order.get(row["mode"], 99),
    int(row.get("request_ordinal") or 0),
))
atomic_csv(mode_feedback_hashes_path, mode_feedback_hash_fields, mode_feedback_hash_rows)

timing_fields = [
    "app", "runtime", "mode", "mode_label", "repetition", "request_ordinal",
    "request_baseline_ordinal", "request_sha256",
    "completion_timestamp_local", "completed_elapsed_s", "http_response_ms", "request_cycle_ms",
]
timings = []
for cell in cells:
    path = Path(cell.get("request_timing_file", ""))
    if not path.is_file():
        continue
    with path.open(newline="", encoding="utf-8") as handle:
        timings.extend(csv.DictReader(handle))
timings.sort(key=lambda row: (row["app"], int(row["repetition"]), mode_order.get(row["mode"], 99), int(row["request_ordinal"])))
atomic_csv(timings_path, timing_fields, timings)

grouped = defaultdict(dict)
for row in timings:
    key = (row["app"], int(row["repetition"]), row["mode"])
    grouped[key][int(row["request_ordinal"])] = row

series_fields = [
    "app", "runtime", "repetition", "mode", "mode_label", "baseline_mode",
    "baseline_mode_label",
    "request_ordinal", "request_baseline_ordinal", "request_sha256",
    "request_identity_match", "normalized_progress", "trace_completed_elapsed_s",
    "baseline_completed_elapsed_s", "trace_http_response_ms", "baseline_http_response_ms",
    "http_overhead_ms", "http_overhead_percent", "trace_request_cycle_ms",
    "baseline_request_cycle_ms", "cycle_overhead_ms", "cycle_overhead_percent",
]
series_rows = []
for (app, repetition, mode), trace in sorted(grouped.items()):
    if mode not in {"tracelib_ebpf_simple", "tracelib_ebpf", "tracelib_bigram_file_sql_filtered"}:
        continue
    for baseline_mode in ("blackbox", "native"):
        baseline = grouped.get((app, repetition, baseline_mode), {})
        if not baseline:
            continue
        common = sorted(set(trace) & set(baseline))
        denominator = max(common) if common else 0
        for ordinal in common:
            current = trace[ordinal]
            base = baseline[ordinal]
            trace_http = float(current["http_response_ms"])
            base_http = float(base["http_response_ms"])
            trace_cycle = float(current["request_cycle_ms"])
            base_cycle = float(base["request_cycle_ms"])
            http_delta = trace_http - base_http
            cycle_delta = trace_cycle - base_cycle
            current_identity = current.get("request_sha256", "")
            base_identity = base.get("request_sha256", "")
            series_rows.append({
                "app": app,
                "runtime": current["runtime"],
                "repetition": repetition,
                "mode": mode,
                "mode_label": current["mode_label"],
                "baseline_mode": baseline_mode,
                "baseline_mode_label": baseline_labels[baseline_mode],
                "request_ordinal": ordinal,
                "request_baseline_ordinal": current.get("request_baseline_ordinal", ""),
                "request_sha256": current_identity,
                "request_identity_match": (
                    "yes"
                    if current_identity and current_identity == base_identity
                    else "no" if current_identity or base_identity else ""
                ),
                "normalized_progress": f"{ordinal / denominator:.8f}" if denominator else "",
                "trace_completed_elapsed_s": current["completed_elapsed_s"],
                "baseline_completed_elapsed_s": base["completed_elapsed_s"],
                "trace_http_response_ms": f"{trace_http:.3f}",
                "baseline_http_response_ms": f"{base_http:.3f}",
                "http_overhead_ms": f"{http_delta:.3f}",
                "http_overhead_percent": f"{100.0 * http_delta / base_http:.6f}" if base_http else "",
                "trace_request_cycle_ms": f"{trace_cycle:.3f}",
                "baseline_request_cycle_ms": f"{base_cycle:.3f}",
                "cycle_overhead_ms": f"{cycle_delta:.3f}",
                "cycle_overhead_percent": f"{100.0 * cycle_delta / base_cycle:.6f}" if base_cycle else "",
            })
atomic_csv(series_path, series_fields, series_rows)

cell_index = {
    (cell.get("app"), int(cell.get("repetition", 0)), cell.get("mode")): cell
    for cell in cells
}
summary_fields = [
    "app", "runtime", "repetition", "mode", "mode_label", "baseline_mode",
    "baseline_mode_label", "status",
    "matched_requests", "trace_median_http_response_ms", "baseline_median_http_response_ms",
    "median_http_overhead_ms", "median_http_overhead_percent",
    "trace_median_request_cycle_ms", "baseline_median_request_cycle_ms",
    "median_cycle_overhead_ms", "median_cycle_overhead_percent",
    "trace_cumulative_cycle_ms_per_request", "baseline_cumulative_cycle_ms_per_request",
    "cumulative_cycle_overhead_ms_per_request", "cumulative_cycle_overhead_percent",
]
summary_rows = []
for (app, repetition, mode), trace in sorted(grouped.items()):
    if mode not in {"tracelib_ebpf_simple", "tracelib_ebpf", "tracelib_bigram_file_sql_filtered"}:
        continue
    for baseline_mode in ("blackbox", "native"):
        baseline = grouped.get((app, repetition, baseline_mode), {})
        if not baseline:
            continue
        common = sorted(set(trace) & set(baseline))
        trace_cell = cell_index.get((app, repetition, mode), {})
        base_cell = cell_index.get((app, repetition, baseline_mode), {})
        status = "complete" if trace_cell.get("status") == base_cell.get("status") == "complete" and common else "incomplete"
        trace_http = [float(trace[i]["http_response_ms"]) for i in common]
        base_http = [float(baseline[i]["http_response_ms"]) for i in common]
        trace_cycle = [float(trace[i]["request_cycle_ms"]) for i in common]
        base_cycle = [float(baseline[i]["request_cycle_ms"]) for i in common]

        def median(values):
            return statistics.median(values) if values else math.nan

        th, bh, tc, bc = map(median, (trace_http, base_http, trace_cycle, base_cycle))
        http_delta = th - bh
        cycle_delta = tc - bc
        trace_cumulative = trace_cell.get("cumulative_cycle_ms_per_request")
        base_cumulative = base_cell.get("cumulative_cycle_ms_per_request")
        cumulative_delta = (
            float(trace_cumulative) - float(base_cumulative)
            if trace_cumulative is not None and base_cumulative is not None
            else math.nan
        )
        summary_rows.append({
            "app": app,
            "runtime": trace_cell.get("runtime", ""),
            "repetition": repetition,
            "mode": mode,
            "mode_label": trace_cell.get("mode_label", ""),
            "baseline_mode": baseline_mode,
            "baseline_mode_label": baseline_labels[baseline_mode],
            "status": status,
            "matched_requests": len(common),
            "trace_median_http_response_ms": "" if math.isnan(th) else f"{th:.3f}",
            "baseline_median_http_response_ms": "" if math.isnan(bh) else f"{bh:.3f}",
            "median_http_overhead_ms": "" if math.isnan(http_delta) else f"{http_delta:.3f}",
            "median_http_overhead_percent": "" if not bh or math.isnan(http_delta) else f"{100.0 * http_delta / bh:.6f}",
            "trace_median_request_cycle_ms": "" if math.isnan(tc) else f"{tc:.3f}",
            "baseline_median_request_cycle_ms": "" if math.isnan(bc) else f"{bc:.3f}",
            "median_cycle_overhead_ms": "" if math.isnan(cycle_delta) else f"{cycle_delta:.3f}",
            "median_cycle_overhead_percent": "" if not bc or math.isnan(cycle_delta) else f"{100.0 * cycle_delta / bc:.6f}",
            "trace_cumulative_cycle_ms_per_request": trace_cumulative if trace_cumulative is not None else "",
            "baseline_cumulative_cycle_ms_per_request": base_cumulative if base_cumulative is not None else "",
            "cumulative_cycle_overhead_ms_per_request": "" if math.isnan(cumulative_delta) else f"{cumulative_delta:.6f}",
            "cumulative_cycle_overhead_percent": (
                "" if base_cumulative in (None, 0) or math.isnan(cumulative_delta)
                else f"{100.0 * cumulative_delta / float(base_cumulative):.6f}"
            ),
        })
atomic_csv(summary_path, summary_fields, summary_rows)

if combined_feedback:
    feedback_fields = [
        "timestamp", "app", "runtime", "mode", "mode_label", "repetition",
        "platform_oracle", "status", "failure", "endpoint_count", "endpoint_sha256",
        "fuzz_request_budget", "final_fuzz_requests", "completion_reason",
        "runner_return_code", "wall_seconds", "records", "complete_records",
        "unique_requests", "missing_code_hash_records", "missing_bitmap_hash_records",
        "comparable_pairs", "true_positive", "false_negative_merge",
        "false_positive_split", "true_negative", "alignment_rate",
        "request_feedback_file", "alignment_summary_file", "pairs_csv",
    ]
    feedback_cells = [
        cell for cell in cells
        if cell.get("mode") in {"tracelib_ebpf_simple", "tracelib_ebpf", "tracelib_bigram_file_sql_filtered"}
    ]
    atomic_csv(feedback_matrix_path, feedback_fields, feedback_cells)

    feedback_summary_fields = [
        "mode", "mode_label", "cells", "complete_cells", "partial_cells",
        "failed_cells", "records", "complete_records", "comparable_pairs",
        "true_positive", "false_negative_merge", "false_positive_split",
        "true_negative", "alignment_rate",
    ]

    def integer(cell, key):
        value = cell.get(key)
        return int(value) if value not in (None, "") else 0

    feedback_summary_rows = []
    for mode in ("tracelib_ebpf_simple", "tracelib_ebpf", "tracelib_bigram_file_sql_filtered"):
        selected = [cell for cell in feedback_cells if cell.get("mode") == mode]
        if not selected:
            continue
        totals = {
            key: sum(integer(cell, key) for cell in selected)
            for key in (
                "records", "complete_records", "comparable_pairs", "true_positive",
                "false_negative_merge", "false_positive_split", "true_negative",
            )
        }
        comparable = totals["comparable_pairs"]
        aligned = totals["true_positive"] + totals["true_negative"]
        feedback_summary_rows.append({
            "mode": mode,
            "mode_label": selected[0].get("mode_label", ""),
            "cells": len(selected),
            "complete_cells": sum(cell.get("status") == "complete" for cell in selected),
            "partial_cells": sum(cell.get("status") == "complete_partial" for cell in selected),
            "failed_cells": sum(cell.get("status") == "failed" for cell in selected),
            **totals,
            "alignment_rate": f"{aligned / comparable:.12f}" if comparable else "",
        })
    atomic_csv(feedback_summary_path, feedback_summary_fields, feedback_summary_rows)

    def display(value, digits=3):
        if value in (None, ""):
            return "—"
        try:
            return f"{float(value):.{digits}f}"
        except (TypeError, ValueError):
            return str(value)

    lines = [
        "# Combined TraceLib overhead and feedback report",
        "",
        "Blackbox is the universal overhead baseline; PHP additionally uses Native "
        "AST-edge feedback as a second baseline. Feedback-quality observations are "
        "captured from the same Bigram and N-gram cells used for overhead timing.",
        "",
        "> `http_response_ms` is the closer measure of request-path overhead. "
        "`request_cycle_ms` also includes request-local platform coverage and bitmap "
        "collection performed after each TraceLib response.",
        "",
        "## Overhead report",
        "",
        "| App | Rep | Mode | Baseline | Status | Matched | Median HTTP overhead (ms) | HTTP overhead (%) | Median cycle overhead (ms) | Cycle overhead (%) |",
        "|---|---:|---|---|---|---:|---:|---:|---:|---:|",
    ]
    for row in summary_rows:
        lines.append(
            f"| {row['app']} | {row['repetition']} | {row['mode_label']} | "
            f"{row['baseline_mode_label']} | {row['status']} | "
            f"{row['matched_requests']} | {display(row['median_http_overhead_ms'])} | "
            f"{display(row['median_http_overhead_percent'])} | "
            f"{display(row['median_cycle_overhead_ms'])} | "
            f"{display(row['median_cycle_overhead_percent'])} |"
        )
    lines.extend([
        "",
        "## Feedback report",
        "",
        "| App | Rep | Mode | Oracle | Status | Records | Complete | Pairs | Alignment | False merges | False splits |",
        "|---|---:|---|---|---|---:|---:|---:|---:|---:|---:|",
    ])
    for cell in feedback_cells:
        lines.append(
            f"| {cell.get('app', '')} | {cell.get('repetition', '')} | "
            f"{cell.get('mode_label', '')} | {cell.get('platform_oracle', '')} | "
            f"{cell.get('status', '')} | {integer(cell, 'records')} | "
            f"{integer(cell, 'complete_records')} | {integer(cell, 'comparable_pairs')} | "
            f"{display(cell.get('alignment_rate'), 6)} | "
            f"{integer(cell, 'false_negative_merge')} | {integer(cell, 'false_positive_split')} |"
        )
    lines.extend([
        "",
        "## Data files",
        "",
        "- `overhead_over_time.csv`: graph-ready request-ordinal overhead series",
        "- `overhead_summary.csv`: per-cell overhead summary",
        "- `feedback_quality_matrix.csv`: per-cell feedback-quality observations",
        "- `feedback_summary.csv`: feedback totals grouped by TraceLib mode",
        "- `request_timings.csv`: combined raw timing observations",
        "",
    ])
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_tmp = report_path.with_name(f".{report_path.name}.tmp")
    report_tmp.write_text("\n".join(lines), encoding="utf-8")
    report_tmp.replace(report_path)

print(
    f"Built outputs: cells={len(cells)} timings={len(timings)} "
    f"matched_series={len(series_rows)} overhead_summaries={len(summary_rows)} "
    f"feedback_cells={len(feedback_cells) if combined_feedback else 0} "
    f"mode_feedback_hashes={len(mode_feedback_hash_rows)}"
)
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
        --repetitions)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            REPETITIONS="$2"; shift 2 ;;
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
        --write-pairs) WRITE_PAIRS_CSV=1; shift ;;
        --no-write-pairs) WRITE_PAIRS_CSV=0; shift ;;
        --record-feedback-hashes) RECORD_MODE_FEEDBACK_HASHES=1; shift ;;
        --no-record-feedback-hashes) RECORD_MODE_FEEDBACK_HASHES=0; shift ;;
        --identical-request-replay) IDENTICAL_REQUEST_REPLAY=1; shift ;;
        --independent-requests) IDENTICAL_REQUEST_REPLAY=0; shift ;;
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
require_positive_integer REPETITIONS "$REPETITIONS" || exit 2
require_nonnegative_integer MAX_SECONDS "$MAX_SECONDS" || exit 2
require_nonnegative_integer MAX_CORPUS_SIZE "$MAX_CORPUS_SIZE" || exit 2
require_positive_integer COMPOSE_UP_ATTEMPTS "$COMPOSE_UP_ATTEMPTS" || exit 2
require_nonnegative_integer COMPOSE_UP_RETRY_DELAY "$COMPOSE_UP_RETRY_DELAY" || exit 2
require_positive_integer SIDECAR_SAMPLE_INTERVAL "$SIDECAR_SAMPLE_INTERVAL" || exit 2
require_nonnegative_integer REQUEST_FEEDBACK_SYNC_INTERVAL "$REQUEST_FEEDBACK_SYNC_INTERVAL" || exit 2
require_nonnegative_integer FEEDBACK_CAPTURE_SYNC_INTERVAL "$FEEDBACK_CAPTURE_SYNC_INTERVAL" || exit 2
require_positive_integer NONPHP_COVERAGE_SAMPLE_TIMEOUT "$NONPHP_COVERAGE_SAMPLE_TIMEOUT" || exit 2
require_positive_integer EXTERNAL_COVERAGE_TIMEOUT "$EXTERNAL_COVERAGE_TIMEOUT" || exit 2
case "$RESUME" in 0|1) ;; *) echo "ERROR: RESUME must be 0 or 1" >&2; exit 2 ;; esac
case "$DRY_RUN" in 0|1) ;; *) echo "ERROR: DRY_RUN must be 0 or 1" >&2; exit 2 ;; esac
case "$COMBINED_FEEDBACK_EVAL" in 0|1) ;; *) echo "ERROR: COMBINED_FEEDBACK_EVAL must be 0 or 1" >&2; exit 2 ;; esac
case "$RECORD_MODE_FEEDBACK_HASHES" in 0|1) ;; *) echo "ERROR: RECORD_MODE_FEEDBACK_HASHES must be 0 or 1" >&2; exit 2 ;; esac
case "$WRITE_PAIRS_CSV" in 0|1) ;; *) echo "ERROR: WRITE_PAIRS_CSV must be 0 or 1" >&2; exit 2 ;; esac
case "$IDENTICAL_REQUEST_REPLAY" in 0|1) ;; *) echo "ERROR: IDENTICAL_REQUEST_REPLAY must be 0 or 1" >&2; exit 2 ;; esac
if [ "$RECORD_MODE_FEEDBACK_HASHES" = "1" ] && [ "$IDENTICAL_REQUEST_REPLAY" != "1" ]; then
    echo "ERROR: --record-feedback-hashes requires --identical-request-replay so mode streams have canonical cross-mode identities" >&2
    exit 2
fi
case "$BLACKBOX_CORPUS_MODE" in
    seed-only|keep-submitted) ;;
    *) echo "ERROR: BLACKBOX_CORPUS_MODE must be seed-only or keep-submitted" >&2; exit 2 ;;
esac

declare -A seen_apps=()
php_selected=0
nonphp_selected=0
for app in "${requested_apps[@]}"; do
    validate_identifier application "$app" || exit 2
    is_supported_app "$app" || { echo "ERROR: unsupported application '$app'" >&2; exit 2; }
    [ -z "${seen_apps[$app]:-}" ] || { echo "ERROR: duplicate application '$app'" >&2; exit 2; }
    seen_apps["$app"]=1
    if is_php_app "$app"; then php_selected=1; else nonphp_selected=1; fi
done

declare -A seen_modes=()
for mode in "${requested_modes[@]}"; do
    validate_identifier mode "$mode" || exit 2
    is_supported_mode "$mode" || { echo "ERROR: unsupported mode '$mode'" >&2; exit 2; }
    [ -z "${seen_modes[$mode]:-}" ] || { echo "ERROR: duplicate mode '$mode'" >&2; exit 2; }
    seen_modes["$mode"]=1
done
[ -n "${seen_modes[blackbox]:-}" ] || {
    echo "ERROR: blackbox must be selected because it is the overhead baseline" >&2
    exit 2
}
if [ "$php_selected" = "1" ] && [ -z "${seen_modes[native]:-}" ]; then
    echo "ERROR: native must be selected as the PHP AST-edge overhead baseline" >&2
    exit 2
fi
if [ -z "${seen_modes[tracelib_ebpf_simple]:-}" ] \
   && [ -z "${seen_modes[tracelib_ebpf]:-}" ] \
   && [ -z "${seen_modes[tracelib_bigram_file_sql_filtered]:-}" ]; then
    echo "ERROR: select at least one TraceLib mode" >&2
    exit 2
fi

[ -x "$CAMPAIGN_RUNNER" ] || { echo "ERROR: missing campaign runner: $CAMPAIGN_RUNNER" >&2; exit 2; }
[ "$COMBINED_FEEDBACK_EVAL" = "0" ] || [ -r "$ANALYZER" ] || {
    echo "ERROR: missing feedback analyzer: $ANALYZER" >&2
    exit 2
}
command -v setsid >/dev/null 2>&1 || { echo "ERROR: setsid is required" >&2; exit 2; }

mkdir -p "$RESULT_DIR" "$ENDPOINT_DIR" "$CELL_DIR" "$TIMING_DIR" "$LOG_DIR"
if [ "$IDENTICAL_REQUEST_REPLAY" = "1" ]; then
    mkdir -p "$REQUEST_BASELINE_DIR"
fi
if [ "$RECORD_MODE_FEEDBACK_HASHES" = "1" ]; then
    mkdir -p "$FEEDBACK_HASH_DIR"
fi
if [ "$COMBINED_FEEDBACK_EVAL" = "1" ]; then
    mkdir -p "$REQUEST_FEEDBACK_DIR" "$ANALYSIS_DIR" "$PAIR_DIR"
fi
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
export MAX_SECONDS JOBS MAX_CORPUS_SIZE REPETITIONS SINGLE_ENDPOINT_VALIDATE_TIMEOUT
export ACCEPTED_COMPLETION_REASONS
export COMPOSE_UP_ATTEMPTS COMPOSE_UP_RETRY_DELAY PYTHONHASHSEED BLACKBOX_CORPUS_MODE
export SIDECAR_SAMPLE_INTERVAL RESUME DRY_RUN ENDPOINT_DIR CELL_DIR TIMING_DIR LOG_DIR
export CONFIG_JSON MATRIX_CSV REQUEST_TIMINGS_CSV OVERHEAD_SERIES_CSV OVERHEAD_SUMMARY_CSV
export REQUEST_FEEDBACK_SYNC_INTERVAL FEEDBACK_CAPTURE_SYNC_INTERVAL
export NONPHP_COVERAGE_SAMPLE_TIMEOUT EXTERNAL_COVERAGE_TIMEOUT WRITE_PAIRS_CSV
export REQUEST_FEEDBACK_DIR ANALYSIS_DIR PAIR_DIR FEEDBACK_MATRIX_CSV FEEDBACK_SUMMARY_CSV
export FEEDBACK_CONFIG_JSON COMBINED_REPORT_MD COMBINED_FEEDBACK_EVAL PROGRAM_NAME
export IDENTICAL_REQUEST_REPLAY REQUEST_BASELINE_DIR
export RECORD_MODE_FEEDBACK_HASHES FEEDBACK_HASH_DIR MODE_FEEDBACK_HASHES_CSV
export OVERHEAD_EVAL_PROGRAM_NAME
export APP_LIST MODE_LIST CAMPAIGN_RUNNER ANALYZER

if [ "$RESUME" = "1" ] && [ -s "$CONFIG_JSON" ] \
   && [ "$IDENTICAL_REQUEST_REPLAY" != "1" ]; then
    echo "Preserving existing overhead campaign configuration for resume: $CONFIG_JSON"
else
    write_config
fi

if [ "$COMBINED_FEEDBACK_EVAL" = "1" ]; then
    echo "============= fixed-endpoint TraceLib overhead + feedback campaign ============="
else
    echo "================ fixed-endpoint TraceLib overhead campaign ================"
fi
echo "apps                   : $APP_LIST"
echo "modes                  : $MODE_LIST"
if [ "$php_selected" = "1" ]; then
    echo "overhead baselines     : blackbox + native AST edges (PHP only)"
else
    echo "overhead baselines     : blackbox (Native is not applicable to non-PHP apps)"
fi
echo "endpoints              : 10 per app, blended"
echo "PHP fuzz requests      : $PHP_FUZZ_REQUEST_BUDGET per cell"
echo "non-PHP fuzz requests  : $NONPHP_FUZZ_REQUEST_BUDGET per cell"
echo "repetitions            : $REPETITIONS"
echo "max corpus size        : $MAX_CORPUS_SIZE"
if [ "$COMBINED_FEEDBACK_EVAL" = "1" ]; then
    echo "feedback capture       : enabled for TraceLib cells (fuzz phase)"
    [ "$php_selected" = "0" ] || echo "feedback reference     : Native AST edges (PHP)"
    if [ "$nonphp_selected" = "1" ]; then
        if [ "$php_selected" = "1" ]; then
            echo "                        : c8/go-cover/Ruby Coverage/coverage.py (non-PHP)"
        else
            echo "feedback reference     : c8/go-cover/Ruby Coverage/coverage.py (non-PHP)"
        fi
    fi
    echo "write pair CSVs        : $WRITE_PAIRS_CSV"
else
    echo "platform sampling      : disabled during fuzzing"
fi
echo "timing source          : per-request WebFuzz completion log"
if [ "$IDENTICAL_REQUEST_REPLAY" = "1" ]; then
    echo "request workload       : Blackbox record, then exact mutation-free replay"
    echo "request cookies        : refreshed independently for every treatment"
    echo "replay time cap        : none; every mode must finish the complete baseline"
else
    echo "request workload       : generated independently by each mode"
fi
if [ "$RECORD_MODE_FEEDBACK_HASHES" = "1" ]; then
    echo "mode feedback hashes   : enabled (Blackbox null, Native AST edges, TraceLib bitmap indices)"
    echo "feedback hash dir      : $FEEDBACK_HASH_DIR"
else
    echo "mode feedback hashes   : disabled"
fi
echo "concurrent apps        : $JOBS"
echo "result dir             : $RESULT_DIR"
echo "================================================================================="
if [ "$JOBS" -gt 1 ]; then
    echo "WARNING: concurrent applications can add host-contention noise to overhead measurements" >&2
fi

if [ "$DRY_RUN" = "1" ]; then
    for app in "${requested_apps[@]}"; do
        echo "$app runtime=$(runtime_for_app "$app") oracle=$(oracle_for_app "$app") budget=$(budget_for_app "$app")"
        echo "  endpoints: $ENDPOINT_DIR/${app}.txt"
        for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
            for mode in "${requested_modes[@]}"; do
                mode_applies_to_app "$app" "$mode" || continue
                if [ "$COMBINED_FEEDBACK_EVAL" = "1" ] && is_tracelib_mode "$mode"; then
                    echo "  cell: repetition=$repetition mode=$mode ($(mode_label "$mode")) paired_capture=enabled"
                else
                    echo "  cell: repetition=$repetition mode=$mode ($(mode_label "$mode")) paired_capture=disabled"
                fi
            done
        done
    done
    echo "Dry run complete. Docker was not started."
    exit 0
fi

declare -A running_apps=()
declare -a failed_apps=()

stop_children() {
    local exit_code="$1" signal_name="${2:-unknown}" pid active_apps=""
    trap - INT TERM
    for pid in "${!running_apps[@]}"; do
        active_apps="${active_apps}${active_apps:+ }${running_apps[$pid]}"
    done
    python3 - "$RESULT_DIR/campaign_interruption.json" "$exit_code" \
        "$signal_name" "$active_apps" <<'PY' || true
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path, exit_code, signal_name, active_apps = sys.argv[1:]
payload = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": "interrupted",
    "signal": signal_name,
    "exit_code": int(exit_code),
    "active_applications": active_apps.split(),
    "note": "Aggregate outputs were rebuilt from every durable cell/timing artifact.",
}
target = Path(path)
temporary = target.with_name(f".{target.name}.tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(target)
PY
    for pid in "${!running_apps[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
    for pid in "${!running_apps[@]}"; do wait "$pid" 2>/dev/null || true; done
    build_outputs || true
    exit "$exit_code"
}
trap 'stop_children 130 SIGINT' INT
trap 'stop_children 143 SIGTERM' TERM

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
    if check_app_collision "$app"; then
        launch_app "$app"
    else
        echo "ERROR: refusing to launch app=$app because another campaign owns it" >&2
        failed_apps+=("$app:collision")
    fi
done
while [ "${#running_apps[@]}" -gt 0 ]; do reap_one; done

build_outputs
if [ "${#failed_apps[@]}" -gt 0 ]; then
    echo "TraceLib campaign finished with failures: ${failed_apps[*]}" >&2
    exit 1
fi
if [ "$COMBINED_FEEDBACK_EVAL" = "1" ]; then
    echo "TraceLib overhead + feedback campaign completed: $RESULT_DIR"
else
    echo "TraceLib overhead campaign completed: $RESULT_DIR"
fi
