#!/usr/bin/env bash

set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT_PATH="$HERE/$(basename "$0")"
CAMPAIGN_RUNNER="${CAMPAIGN_RUNNER:-$HERE/run_campaign_v6.sh}"

BLACKBOX_MAX_CORPUS_SIZE="${BLACKBOX_MAX_CORPUS_SIZE:-50000}"
export BLACKBOX_MAX_CORPUS_SIZE

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

DEFAULT_PHP_MODE_LIST="tracelib_bigram_file_sql_filtered tracelib_ebpf_simple native blackbox tracelib_ebpf"
DEFAULT_NONPHP_MODE_LIST="tracelib_bigram_file_sql_filtered tracelib_ebpf_simple blackbox tracelib_ebpf"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [APP ...]

Run all supported PHP and non-PHP applications under a shared crawl+fuzz
wall-clock budget for each app/mode cell.

Options:
  -j, --jobs N          Maximum concurrent applications (default: 3)
      --hours N         Crawl+fuzz hours per app/mode cell (default: 12)
      --result-dir DIR  Output directory
      --php-modes LIST  Quoted, space-separated PHP modes
      --nonphp-modes LIST
                        Quoted, space-separated non-PHP modes
  -h, --help            Show this help

Environment:
  CONCURRENT_CAMPAIGNS  Alternative to -j
  TIME_BUDGET_HOURS     Alternative to --hours
  APPS                  Apps used when APP arguments are omitted
  MODES                 Override modes globally; native is removed for non-PHP
  PHP_MODES             PHP-only mode override
  NONPHP_MODES          Non-PHP-only mode override
  CRAWLER_PER_BASE_LIMIT
                        Crawl cap per exact base URL (default: 50)
  RESULT_DIR            Output directory
  RESUME=1              Skip completed time-budget cells (default: 1)
  STAGGER_SECONDS       Delay between application launches (default: 5)
  GENERATE_GRAPHS=1     Generate consolidated figures after success (default: 1)
  DRY_RUN=1             Validate and print the expanded matrix only

Hard settings:
  FUZZ_REQUEST_BUDGET=0 No fuzz-request limit
  MAX_CORPUS_SIZE=0     No corpus limit for the guided arms
  BLACKBOX_MAX_CORPUS_SIZE=$BLACKBOX_MAX_CORPUS_SIZE
                        Upper bound on the BLACKBOX corpus only. Blackbox keeps
                        every request it sends; uncapped it exhausted memory and
                        the kernel OOM killer ended a campaign (eval.v7.19
                        Sec. 11.8). Set to 0 to restore unbounded behaviour.

Supported modes:
  native                PHP only
  tracelib_ebpf
  tracelib_ebpf_simple
  blackbox
EOF
}

is_php_app() {
    case "$1" in
        wordpress|hotcrp|phpbb|joomla|bagisto|drupal|prestashop|zencart)
            return 0
            ;;
        *)
            return 1
            ;;
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
        native|blackbox) return 0 ;;
        tracelib_ebpf) return 0 ;;
        tracelib_ebpf_simple) return 0 ;;
        tracelib_bigram_file_sql_filtered) return 0 ;;
        *) return 1 ;;
    esac
}

validate_identifier() {
    local kind="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: invalid $kind '$value'" >&2
        return 1
    fi
}

require_positive_integer() {
    local name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $name must be a positive integer (got '$value')" >&2
        return 1
    fi
}

require_nonnegative_integer() {
    local name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $name must be a non-negative integer (got '$value')" >&2
        return 1
    fi
}

require_boolean() {
    local name="$1"
    local value="$2"

    case "$value" in
        0|1) ;;
        *)
            echo "ERROR: $name must be 0 or 1 (got '$value')" >&2
            return 1
            ;;
    esac
}

filter_native_mode() {
    local raw_list="$1"
    local mode
    local -a source_modes=()
    local -a filtered_modes=()

    read -r -a source_modes <<< "$raw_list"
    for mode in "${source_modes[@]}"; do
        [ "$mode" = "native" ] || filtered_modes+=( "$mode" )
    done
    printf '%s' "${filtered_modes[*]}"
}

latest_file_since() {
    local pattern="$1"
    local started_epoch="$2"

    find "$RESULT_DIR" -maxdepth 1 -type f \
        -name "$pattern" -newermt "@$started_epoch" \
        -printf '%T@\t%p\n' \
        | sort -nr \
        | sed -n $'1{s/^[^\t]*\t//;p;}'
}

completion_reason() {
    local summary_file="$1"

    if [ -s "$summary_file" ]; then
        awk -F= '/^completion_reason=/{print $2; exit}' "$summary_file"
    fi
}

existing_completed_summary() {
    local app="$1"
    local mode="$2"
    local summary reason

    summary="$(
        find "$RESULT_DIR" -maxdepth 1 -type f \
            -name "*_${app}_${mode}_t${TIME_BUDGET_HOURS}h_*.summary.txt" \
            -printf '%T@\t%p\n' \
            | sort -nr \
            | sed -n $'1{s/^[^\t]*\t//;p;}'
    )"
    [ -n "$summary" ] || return 1

    reason="$(completion_reason "$summary")"
    case "$reason" in
        max_time_cap|empty_queue)
            printf '%s\n' "$summary"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if [ -n "${MODES:-}" ]; then
    DEFAULT_SELECTED_PHP_MODES="$MODES"
    DEFAULT_SELECTED_NONPHP_MODES="$(filter_native_mode "$MODES")"
else
    DEFAULT_SELECTED_PHP_MODES="$DEFAULT_PHP_MODE_LIST"
    DEFAULT_SELECTED_NONPHP_MODES="$DEFAULT_NONPHP_MODE_LIST"
fi

TIME_BUDGET_HOURS="${ALL_APPS_TIME_BUDGET_HOURS:-${TIME_BUDGET_HOURS:-${HOURS:-8}}}"
TIME_BUDGET_SECONDS="${ALL_APPS_TIME_BUDGET_SECONDS:-}"
PHP_MODE_LIST="${ALL_APPS_PHP_MODE_LIST:-${PHP_MODES:-$DEFAULT_SELECTED_PHP_MODES}}"
NONPHP_MODE_LIST="${ALL_APPS_NONPHP_MODE_LIST:-${NONPHP_MODES:-$DEFAULT_SELECTED_NONPHP_MODES}}"
CAMPAIGN_RUN_ID="${CAMPAIGN_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_DIR="${RESULT_DIR:-}"

CRAWLER_PER_BASE_LIMIT="${CRAWLER_PER_BASE_LIMIT:-50}"
PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
QUIESCE_SECONDS="${QUIESCE_SECONDS:-60}"
PHP_INTERVAL="${PHP_INTERVAL:-${INTERVAL:-60}}"
PHP_FUZZ_INTERVAL="${PHP_FUZZ_INTERVAL:-${FUZZ_INTERVAL:-20}}"
PHP_COVERAGE_SAMPLE_TIMEOUT="${PHP_COVERAGE_SAMPLE_TIMEOUT:-20}"
NONPHP_INTERVAL="${NONPHP_INTERVAL:-${INTERVAL:-60}}"
NONPHP_FUZZ_INTERVAL="${NONPHP_FUZZ_INTERVAL:-${FUZZ_INTERVAL:-60}}"
NONPHP_COVERAGE_SAMPLE_TIMEOUT="${NONPHP_COVERAGE_SAMPLE_TIMEOUT:-15}"
NONPHP_PLATFORM_COVERAGE_SAMPLE="${NONPHP_PLATFORM_COVERAGE_SAMPLE:-1}"
NONPHP_NODE_PLATFORM_COVERAGE_SAMPLE="${NONPHP_NODE_PLATFORM_COVERAGE_SAMPLE:-0}"
NONPHP_NODE_COVERAGE_INTERVAL_MS="${NONPHP_NODE_COVERAGE_INTERVAL_MS:-60000}"
NONPHP_NODE_COVERAGE_TAKE_ON_RESPONSE="${NONPHP_NODE_COVERAGE_TAKE_ON_RESPONSE:-0}"
AUTO_APP_SEED_FILE="${AUTO_APP_SEED_FILE:-1}"
ENABLE_APP_SEEDS="${ENABLE_APP_SEEDS:-0}"
RESUME="${RESUME:-1}"
STAGGER_SECONDS="${STAGGER_SECONDS:-5}"
GENERATE_GRAPHS="${GENERATE_GRAPHS:-1}"
DRY_RUN="${DRY_RUN:-0}"

FUZZ_REQUEST_BUDGET=0
MAX_CORPUS_SIZE=0

run_cell() {
    local app="$1"
    local mode="$2"
    local runtime_group interval fuzz_interval allow_non_html
    local platform_coverage_sample node_interval node_take_on_response
    local coverage_sample_timeout
    local started_epoch rc summary reason cell_log existing

    if [ "$RESUME" = "1" ]; then
        existing="$(existing_completed_summary "$app" "$mode" || true)"
        if [ -n "$existing" ]; then
            echo "=== Skipping app=$app mode=$mode (completed: $existing) ==="
            return 0
        fi
    fi

    if is_php_app "$app"; then
        runtime_group="php"
        interval="$PHP_INTERVAL"
        fuzz_interval="$PHP_FUZZ_INTERVAL"
        allow_non_html=0
        platform_coverage_sample=1
        coverage_sample_timeout="$PHP_COVERAGE_SAMPLE_TIMEOUT"
        node_interval=30000
        node_take_on_response=0
    else
        runtime_group="nonphp"
        interval="$NONPHP_INTERVAL"
        fuzz_interval="$NONPHP_FUZZ_INTERVAL"
        allow_non_html=1
        coverage_sample_timeout="$NONPHP_COVERAGE_SAMPLE_TIMEOUT"
        node_interval="$NONPHP_NODE_COVERAGE_INTERVAL_MS"
        node_take_on_response="$NONPHP_NODE_COVERAGE_TAKE_ON_RESPONSE"
        case "$app" in
            ghost)
                platform_coverage_sample="$NONPHP_NODE_PLATFORM_COVERAGE_SAMPLE"
                ;;
            *)
                platform_coverage_sample="$NONPHP_PLATFORM_COVERAGE_SAMPLE"
                ;;
        esac
    fi

    echo "=== Starting app=$app mode=$mode runtime=$runtime_group ==="
    echo "    time_budget=${TIME_BUDGET_HOURS}h/${TIME_BUDGET_SECONDS}s (crawl+fuzz combined)"
    echo "    fuzz_request_budget=unlimited corpus=unlimited crawl_per_base=$CRAWLER_PER_BASE_LIMIT"

    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] $CAMPAIGN_RUNNER $app $mode"
        return 0
    fi

    cell_log="$RUN_LOG_DIR/${app}_${mode}.log"
    started_epoch="$(date +%s)"
    MAX_HOURS="$TIME_BUDGET_HOURS" \
    MAX_SECONDS="$TIME_BUDGET_SECONDS" \
    FUZZ_REQUEST_BUDGET="$FUZZ_REQUEST_BUDGET" \
    MAX_CORPUS_SIZE="$MAX_CORPUS_SIZE" \
    CRAWLER_PER_BASE_LIMIT="$CRAWLER_PER_BASE_LIMIT" \
    RESULT_DIR="$RESULT_DIR" \
    INTERVAL="$interval" \
    FUZZ_INTERVAL="$fuzz_interval" \
    QUIESCE_SECONDS="$QUIESCE_SECONDS" \
    PYTHONHASHSEED="$PYTHONHASHSEED" \
    RESET_STATE=1 \
    AUTO_APP_SEED_FILE="$AUTO_APP_SEED_FILE" \
    ENABLE_APP_SEEDS="$ENABLE_APP_SEEDS" \
    ALLOW_NON_HTML="$allow_non_html" \
    PLATFORM_COVERAGE_SAMPLE="$platform_coverage_sample" \
    COVERAGE_SAMPLE_TIMEOUT="$coverage_sample_timeout" \
    NODE_COVERAGE_INTERVAL_MS="$node_interval" \
    NODE_COVERAGE_TAKE_ON_RESPONSE="$node_take_on_response" \
    REQUEST_FEEDBACK_FILE="" \
    FEEDBACK_CAPTURE_DIR="" \
    REQUEST_FEEDBACK_SYNC_INTERVAL=0 \
    FEEDBACK_CAPTURE_SYNC_INTERVAL=0 \
    NONPHP_REQUEST_FEEDBACK_REFERENCE=0 \
    BLACKBOX_MAX_CORPUS_SIZE="$BLACKBOX_MAX_CORPUS_SIZE" \
        "$CAMPAIGN_RUNNER" "$app" "$mode" 2>&1 \
        | tee "$cell_log" \
        | sed -u "s|^|[$app/$mode] |"
    rc=${PIPESTATUS[0]}

    summary="$(latest_file_since "*_${app}_${mode}_t${TIME_BUDGET_HOURS}h_*.summary.txt" "$started_epoch")"
    reason="$(completion_reason "$summary")"

    case "$reason" in
        max_time_cap)
            echo "=== Completed app=$app mode=$mode at the shared crawl+fuzz time cap (runner rc=$rc) ==="
            return 0
            ;;
        empty_queue)
            echo "=== Completed app=$app mode=$mode early because WebFuzz exhausted its queues (runner rc=$rc) ==="
            return 0
            ;;
    esac

    if [ "$rc" -ne 0 ]; then
        echo "ERROR: app=$app mode=$mode failed with exit code $rc (reason=${reason:-missing})" >&2
        echo "       log: $cell_log" >&2
        return "$rc"
    fi

    echo "=== Completed app=$app mode=$mode (reason=${reason:-unknown}) ==="
}

run_app() {
    local app="$1"
    local mode
    local mode_list
    local -a modes=()

    if is_php_app "$app"; then
        mode_list="$PHP_MODE_LIST"
    else
        mode_list="$NONPHP_MODE_LIST"
    fi
    read -r -a modes <<< "$mode_list"

    for mode in "${modes[@]}"; do
        run_cell "$app" "$mode" || return $?
    done
    echo "=== Completed all modes for app=$app ==="
}

if [ "${1:-}" = "--internal-run-app" ]; then
    if [ "$#" -ne 2 ]; then
        echo "ERROR: internal worker requires exactly one application" >&2
        exit 2
    fi
    is_supported_app "$2" || {
        echo "ERROR: unsupported application '$2'" >&2
        exit 2
    }
    run_app "$2"
    exit $?
fi

jobs="${CONCURRENT_CAMPAIGNS:-4}"
declare -a requested_apps=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        -j|--jobs)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: $1 requires a value" >&2
                usage >&2
                exit 2
            fi
            jobs="$2"
            shift 2
            ;;
        --jobs=*)
            jobs="${1#*=}"
            shift
            ;;
        --hours)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --hours requires a value" >&2
                exit 2
            fi
            TIME_BUDGET_HOURS="$2"
            TIME_BUDGET_SECONDS=""
            shift 2
            ;;
        --hours=*)
            TIME_BUDGET_HOURS="${1#*=}"
            TIME_BUDGET_SECONDS=""
            shift
            ;;
        --result-dir)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --result-dir requires a value" >&2
                exit 2
            fi
            RESULT_DIR="$2"
            shift 2
            ;;
        --result-dir=*)
            RESULT_DIR="${1#*=}"
            shift
            ;;
        --php-modes)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --php-modes requires a quoted list" >&2
                exit 2
            fi
            PHP_MODE_LIST="$2"
            shift 2
            ;;
        --php-modes=*)
            PHP_MODE_LIST="${1#*=}"
            shift
            ;;
        --nonphp-modes)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --nonphp-modes requires a quoted list" >&2
                exit 2
            fi
            NONPHP_MODE_LIST="$2"
            shift 2
            ;;
        --nonphp-modes=*)
            NONPHP_MODE_LIST="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            requested_apps+=( "$@" )
            break
            ;;
        -*)
            echo "ERROR: unknown option '$1'" >&2
            usage >&2
            exit 2
            ;;
        *)
            requested_apps+=( "$1" )
            shift
            ;;
    esac
done

if [[ ! "$TIME_BUDGET_HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
   || ! awk -v hours="$TIME_BUDGET_HOURS" 'BEGIN { exit !(hours > 0) }'; then
    echo "ERROR: time budget must be a positive number of hours (got '$TIME_BUDGET_HOURS')" >&2
    exit 2
fi
if [ -z "$TIME_BUDGET_SECONDS" ]; then
    TIME_BUDGET_SECONDS="$(
        awk -v hours="$TIME_BUDGET_HOURS" 'BEGIN { printf "%d", hours * 3600 }'
    )"
fi
require_positive_integer TIME_BUDGET_SECONDS "$TIME_BUDGET_SECONDS" || exit 2
require_positive_integer CONCURRENT_CAMPAIGNS "$jobs" || exit 2
require_nonnegative_integer CRAWLER_PER_BASE_LIMIT "$CRAWLER_PER_BASE_LIMIT" || exit 2
require_nonnegative_integer STAGGER_SECONDS "$STAGGER_SECONDS" || exit 2
require_positive_integer QUIESCE_SECONDS "$QUIESCE_SECONDS" || exit 2
require_positive_integer PHP_INTERVAL "$PHP_INTERVAL" || exit 2
require_positive_integer PHP_FUZZ_INTERVAL "$PHP_FUZZ_INTERVAL" || exit 2
require_positive_integer PHP_COVERAGE_SAMPLE_TIMEOUT "$PHP_COVERAGE_SAMPLE_TIMEOUT" || exit 2
require_positive_integer NONPHP_INTERVAL "$NONPHP_INTERVAL" || exit 2
require_positive_integer NONPHP_FUZZ_INTERVAL "$NONPHP_FUZZ_INTERVAL" || exit 2
require_positive_integer NONPHP_COVERAGE_SAMPLE_TIMEOUT "$NONPHP_COVERAGE_SAMPLE_TIMEOUT" || exit 2
require_positive_integer NONPHP_NODE_COVERAGE_INTERVAL_MS "$NONPHP_NODE_COVERAGE_INTERVAL_MS" || exit 2

require_boolean RESUME "$RESUME" || exit 2
require_boolean GENERATE_GRAPHS "$GENERATE_GRAPHS" || exit 2
require_boolean DRY_RUN "$DRY_RUN" || exit 2
require_boolean AUTO_APP_SEED_FILE "$AUTO_APP_SEED_FILE" || exit 2
require_boolean ENABLE_APP_SEEDS "$ENABLE_APP_SEEDS" || exit 2
require_boolean NONPHP_PLATFORM_COVERAGE_SAMPLE "$NONPHP_PLATFORM_COVERAGE_SAMPLE" || exit 2
require_boolean NONPHP_NODE_PLATFORM_COVERAGE_SAMPLE "$NONPHP_NODE_PLATFORM_COVERAGE_SAMPLE" || exit 2
require_boolean NONPHP_NODE_COVERAGE_TAKE_ON_RESPONSE "$NONPHP_NODE_COVERAGE_TAKE_ON_RESPONSE" || exit 2

if [ "${#requested_apps[@]}" -eq 0 ]; then
    if [ -n "${APPS:-}" ]; then
        read -r -a requested_apps <<< "$APPS"
    else
        requested_apps=( "${DEFAULT_APPS[@]}" )
    fi
fi

selected_php=0
selected_nonphp=0
declare -A app_seen=()
for app in "${requested_apps[@]}"; do
    validate_identifier application "$app" || exit 2
    if ! is_supported_app "$app"; then
        echo "ERROR: unsupported application '$app'" >&2
        echo "       allowed: ${DEFAULT_APPS[*]}" >&2
        exit 2
    fi
    if [ -n "${app_seen[$app]:-}" ]; then
        echo "ERROR: application '$app' was requested more than once" >&2
        exit 2
    fi
    app_seen["$app"]=1
    if is_php_app "$app"; then
        selected_php=1
    else
        selected_nonphp=1
    fi
done

validate_mode_list() {
    local runtime_group="$1"
    local raw_list="$2"
    local mode
    local -a modes=()
    local -A seen=()

    read -r -a modes <<< "$raw_list"
    if [ "${#modes[@]}" -eq 0 ]; then
        echo "ERROR: $runtime_group mode list is empty" >&2
        return 2
    fi
    for mode in "${modes[@]}"; do
        validate_identifier mode "$mode" || return 2
        if ! is_supported_mode "$mode"; then
            echo "ERROR: unsupported $runtime_group mode '$mode'" >&2
            return 2
        fi
        if [ "$runtime_group" = "non-PHP" ] && [ "$mode" = "native" ]; then
            echo "ERROR: native mode is PHP-only" >&2
            return 2
        fi
        if [ -n "${seen[$mode]:-}" ]; then
            echo "ERROR: duplicate $runtime_group mode '$mode'" >&2
            return 2
        fi
        seen["$mode"]=1
    done
}

[ "$selected_php" = "0" ] || validate_mode_list PHP "$PHP_MODE_LIST" || exit 2
[ "$selected_nonphp" = "0" ] || validate_mode_list non-PHP "$NONPHP_MODE_LIST" || exit 2

if [ -z "$RESULT_DIR" ]; then
    RESULT_DIR="$ROOT/eval_result/all_apps_time_${TIME_BUDGET_HOURS}h_$CAMPAIGN_RUN_ID"
fi
RUN_LOG_DIR="$RESULT_DIR/parallel_logs"

export ALL_APPS_TIME_BUDGET_HOURS="$TIME_BUDGET_HOURS"
export ALL_APPS_TIME_BUDGET_SECONDS="$TIME_BUDGET_SECONDS"
export ALL_APPS_PHP_MODE_LIST="$PHP_MODE_LIST"
export ALL_APPS_NONPHP_MODE_LIST="$NONPHP_MODE_LIST"
export CAMPAIGN_RUN_ID RESULT_DIR RUN_LOG_DIR
export CRAWLER_PER_BASE_LIMIT PYTHONHASHSEED QUIESCE_SECONDS
export PHP_INTERVAL PHP_FUZZ_INTERVAL PHP_COVERAGE_SAMPLE_TIMEOUT
export NONPHP_INTERVAL NONPHP_FUZZ_INTERVAL
export NONPHP_COVERAGE_SAMPLE_TIMEOUT
export NONPHP_PLATFORM_COVERAGE_SAMPLE
export NONPHP_NODE_PLATFORM_COVERAGE_SAMPLE
export NONPHP_NODE_COVERAGE_INTERVAL_MS
export NONPHP_NODE_COVERAGE_TAKE_ON_RESPONSE
export AUTO_APP_SEED_FILE ENABLE_APP_SEEDS
export CAMPAIGN_RUNNER RESUME STAGGER_SECONDS GENERATE_GRAPHS DRY_RUN

if [ "$DRY_RUN" != "1" ] && [ ! -x "$CAMPAIGN_RUNNER" ]; then
    echo "ERROR: campaign runner is not executable: $CAMPAIGN_RUNNER" >&2
    exit 2
fi
if ! command -v setsid >/dev/null 2>&1; then
    echo "ERROR: setsid is required for coordinated campaign cleanup" >&2
    exit 2
fi

mkdir -p "$RESULT_DIR" "$RUN_LOG_DIR"

php_modes=()
nonphp_modes=()
read -r -a php_modes <<< "$PHP_MODE_LIST"
read -r -a nonphp_modes <<< "$NONPHP_MODE_LIST"
total_cells=0
for app in "${requested_apps[@]}"; do
    if is_php_app "$app"; then
        total_cells=$(( total_cells + ${#php_modes[@]} ))
    else
        total_cells=$(( total_cells + ${#nonphp_modes[@]} ))
    fi
done
total_cell_hours="$(
    awk -v cells="$total_cells" -v hours="$TIME_BUDGET_HOURS" \
        'BEGIN { printf "%.2f", cells * hours }'
)"
ideal_wall_hours="$(
    awk -v cells="$total_cells" -v hours="$TIME_BUDGET_HOURS" -v jobs="$jobs" \
        'BEGIN { printf "%.2f", cells * hours / jobs }'
)"

echo "All-application time-budget campaign"
echo "  applications: ${#requested_apps[@]} (${requested_apps[*]})"
echo "  PHP modes: $PHP_MODE_LIST"
echo "  non-PHP modes: $NONPHP_MODE_LIST"
echo "  cells: $total_cells"
echo "  time per cell: ${TIME_BUDGET_HOURS}h (${TIME_BUDGET_SECONDS}s)"
echo "  timer scope: crawling + fuzzing combined"
echo "  fuzz request limit: none (FUZZ_REQUEST_BUDGET=0)"
echo "  corpus limit: none for guided arms (MAX_CORPUS_SIZE=0)"
if [ "${BLACKBOX_MAX_CORPUS_SIZE:-0}" -gt 0 ] 2>/dev/null; then
    echo "  blackbox corpus cap: $BLACKBOX_MAX_CORPUS_SIZE inputs"
else
    echo "  blackbox corpus cap: none — WARNING: an uncapped blackbox corpus"
    echo "                       exhausted memory and ended a campaign (eval.v7.19 Sec. 11.8)"
fi
echo "  crawler per-base limit: $CRAWLER_PER_BASE_LIMIT"
echo "  concurrent applications: $jobs"
echo "  total cell-hours: $total_cell_hours"
echo "  idealized minimum wall-hours at full utilization: $ideal_wall_hours"
echo "  result_dir: $RESULT_DIR"
echo "  resume: $RESUME"

declare -A running_apps=()
declare -a failed_apps=()

stop_children() {
    local exit_code="$1"
    local pid

    trap - INT TERM
    echo
    echo "Stopping ${#running_apps[@]} active application campaign(s)..."
    for pid in "${!running_apps[@]}"; do
        kill -TERM -- "-$pid" 2>/dev/null || true
    done
    for pid in "${!running_apps[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    exit "$exit_code"
}

trap 'stop_children 130' INT
trap 'stop_children 143' TERM

launch_app() {
    local app="$1"
    local pid

    setsid "$SCRIPT_PATH" --internal-run-app "$app" &
    pid=$!
    running_apps["$pid"]="$app"
    echo "Launched app=$app pid=$pid (${#running_apps[@]}/$jobs slots active)"
}

reap_one() {
    local completed_pid=""
    local app rc
    local -a active_pids=( "${!running_apps[@]}" )

    if wait -n -p completed_pid "${active_pids[@]}"; then
        rc=0
    else
        rc=$?
    fi

    app="${running_apps[$completed_pid]:-unknown}"
    unset 'running_apps[$completed_pid]'
    if [ "$rc" -eq 0 ]; then
        echo "Application app=$app completed successfully"
    else
        echo "ERROR: application app=$app stopped with exit code $rc" >&2
        failed_apps+=( "$app:$rc" )
    fi
}

for app in "${requested_apps[@]}"; do
    while [ "${#running_apps[@]}" -ge "$jobs" ]; do
        reap_one
    done
    launch_app "$app"
    if [ "$DRY_RUN" != "1" ] && [ "$STAGGER_SECONDS" -gt 0 ]; then
        sleep "$STAGGER_SECONDS"
    fi
done

while [ "${#running_apps[@]}" -gt 0 ]; do
    reap_one
done

if [ "$DRY_RUN" = "1" ]; then
    echo "All-application time-budget dry run completed."
elif [ "${#failed_apps[@]}" -gt 0 ]; then
    echo "Time-budget campaign finished with failures: ${failed_apps[*]}" >&2
    exit 1
else
    if [ "$GENERATE_GRAPHS" = "1" ]; then
        if RESULT_DIR="$RESULT_DIR" python3 "$HERE/make_campaign_figs.py"; then
            echo "Consolidated figures generated in $RESULT_DIR/figs"
        else
            echo "WARNING: figure generation failed; campaign CSVs are intact" >&2
        fi
    fi
    echo "All-application time-budget campaign completed: $RESULT_DIR"
fi
