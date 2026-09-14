#!/bin/bash

set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PREVIOUS_APPS=(
    wordpress hotcrp phpbb joomla bagisto drupal prestashop zencart
 ghost redmine gogs huginn superset wikijs petclinic roller
)
BUDGET="${FUZZ_REQUEST_BUDGET:-1000}"
TRACELIB_MODE="${TRACELIB_MODE:-tracelib_ebpf}"
RUN_DIR="${FEEDBACK_QUALITY_RESULT_DIR:-}"
QUALITY_PYTHON="${FEEDBACK_QUALITY_PYTHON:-python3}"
SELECTED_APPS=()

usage() {
    cat <<'EOF'
Usage: eval/evaluate_feedback_quality.sh [options] [all|APP ...]

Options:
  --budget N       Fuzzing-phase requests per application (default: 1000)
  --mode MODE      tracelib_ebpf, tracelib_ebpf_simple,
                   or tracelib_bigram_file_sql_filtered
  --output DIR     New directory for captures and reports
  -h, --help       Show this help

Allowed applications:
  wordpress hotcrp phpbb joomla bagisto drupal prestashop zencart
 ghost redmine gogs huginn superset wikijs

The default is all allowed applications. MAX_HOURS defaults to 0 (no wall-clock
limit); set MAX_HOURS or MAX_SECONDS explicitly if a safety cap is desired.

For PHP apps the report includes exact AST-vs-TraceLib pairwise metrics. For
non-PHP apps the current oracle is cumulative language-native line coverage, so
the report includes sequential line-novelty metrics and marks exact pairwise
classification unsupported.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --budget)
            [ "$#" -ge 2 ] || { echo "--budget requires a value" >&2; exit 2; }
            BUDGET="$2"; shift 2 ;;
        --mode)
            [ "$#" -ge 2 ] || { echo "--mode requires a value" >&2; exit 2; }
            TRACELIB_MODE="$2"; shift 2 ;;
        --output)
            [ "$#" -ge 2 ] || { echo "--output requires a value" >&2; exit 2; }
            RUN_DIR="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do SELECTED_APPS+=("$1"); shift; done ;;
        -* )
            echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            SELECTED_APPS+=("$1"); shift ;;
    esac
done

case "$BUDGET" in
    ''|*[!0-9]*) echo "--budget must be a positive integer" >&2; exit 2 ;;
esac
[ "$BUDGET" -gt 0 ] || { echo "--budget must be greater than zero" >&2; exit 2; }

case "$TRACELIB_MODE" in
    tracelib_ebpf|tracelib_ebpf_simple|tracelib_bigram_file_sql_filtered) ;;
    *)
        echo "--mode must be one of: tracelib_ebpf, tracelib_ebpf_simple," >&2
        echo "  tracelib_bigram_file_sql_filtered" >&2
        exit 2 ;;
esac

if [ "${#SELECTED_APPS[@]}" -eq 0 ] || [ "${SELECTED_APPS[*]}" = "all" ]; then
    SELECTED_APPS=("${PREVIOUS_APPS[@]}")
elif [[ " ${SELECTED_APPS[*]} " == *" all "* ]]; then
    echo "use 'all' by itself, or list individual applications" >&2
    exit 2
fi

for app in "${SELECTED_APPS[@]}"; do
    case " ${PREVIOUS_APPS[*]} " in
        *" $app "*) ;;
        *)
            echo "unsupported application for this evaluation: $app" >&2
            echo "Only the previous applications are allowed: ${PREVIOUS_APPS[*]}" >&2
            exit 2 ;;
    esac
done

command -v "$QUALITY_PYTHON" >/dev/null 2>&1 || {
    echo "Python not found: $QUALITY_PYTHON" >&2
    exit 1
}

if [ -z "$RUN_DIR" ]; then
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    RUN_DIR="$ROOT/eval_result/feedback_quality_${timestamp}"
fi
RUN_DIR="$(realpath -m "$RUN_DIR")"
case "$RUN_DIR" in
    /|/tmp|"$ROOT") echo "refusing unsafe output directory: $RUN_DIR" >&2; exit 2 ;;
esac
if [ -e "$RUN_DIR" ] && find "$RUN_DIR" -mindepth 1 -print -quit | grep -q .; then
    echo "output directory is not empty: $RUN_DIR" >&2
    echo "Choose a new directory so captures from separate experiments cannot mix." >&2
    exit 2
fi
mkdir -p "$RUN_DIR"

campaign_max_hours="${MAX_HOURS:-0}"
if [ -n "${MAX_SECONDS+x}" ]; then
    campaign_max_seconds="$MAX_SECONDS"
else
    campaign_max_seconds=$(( campaign_max_hours * 3600 ))
fi

echo "[feedback-quality] applications: ${SELECTED_APPS[*]}"
echo "[feedback-quality] mode: $TRACELIB_MODE"
echo "[feedback-quality] fuzz budget per app: $BUDGET"
echo "[feedback-quality] output: $RUN_DIR"
if [ "$campaign_max_seconds" -gt 0 ] 2>/dev/null; then
    echo "[feedback-quality] wall-clock cap per app: ${campaign_max_seconds}s"
else
    echo "[feedback-quality] wall-clock cap per app: none"
fi

failures=0
completed=0
for app in "${SELECTED_APPS[@]}"; do
    capture_dir="$RUN_DIR/$app"
    mkdir -p "$capture_dir/campaign"
    echo "[feedback-quality] starting $app"

    FEEDBACK_CAPTURE_DIR="$capture_dir" \
    RESULT_DIR="$capture_dir/campaign" \
    FUZZ_REQUEST_BUDGET="$BUDGET" \
    MAX_HOURS="$campaign_max_hours" \
    MAX_SECONDS="$campaign_max_seconds" \
    "$HERE/run_campaign_v6.sh" "$app" "$TRACELIB_MODE"
    campaign_rc=$?

    "$QUALITY_PYTHON" "$HERE/analyze_feedback_quality.py" "$capture_dir"
    analysis_rc=$?
    if [ "$analysis_rc" -eq 0 ]; then
        completed=$((completed + 1))
    else
        echo "[feedback-quality] analysis failed for $app (rc=$analysis_rc)" >&2
        failures=$((failures + 1))
    fi
    if [ "$campaign_rc" -ne 0 ]; then
        echo "[feedback-quality] campaign for $app returned rc=$campaign_rc; retained artifacts were still analyzed" >&2
        failures=$((failures + 1))
    fi
done

if [ "$completed" -gt 0 ]; then
    "$QUALITY_PYTHON" "$HERE/analyze_feedback_quality.py" --aggregate "$RUN_DIR" || failures=$((failures + 1))
fi

echo "[feedback-quality] completed analyses: $completed/${#SELECTED_APPS[@]}"
echo "[feedback-quality] aggregate report: $RUN_DIR/aggregate_feedback_quality_summary.md"
[ "$failures" -eq 0 ]
