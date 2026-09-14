#!/usr/bin/env bash

set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
OVERHEAD_RUNNER="${TIME_EVAL_OVERHEAD_RUNNER:-$ROOT/single_endpoint_campaign/overhead-eval.sh}"
RUN_ID="${TIME_EVAL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_DIR="${RESULT_DIR:-$ROOT/eval_result_single_endpoint/time_eval_$RUN_ID}"

MODES=(blackbox native tracelib_bigram_file_sql_filtered tracelib_ebpf_simple tracelib_ebpf)

REQUESTS="${TIME_EVAL_REQUESTS:-1000}"
REPETITIONS="${TIME_EVAL_REPETITIONS:-1}"
JOBS="${TIME_EVAL_JOBS:-1}"
DRY_RUN=0
SUMMARIZE_ONLY=0
SIGNAL_RC=0

declare -a APPS=()

trap 'SIGNAL_RC=130' INT
trap 'SIGNAL_RC=143' TERM

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [APP ...]

Measure per-request time overhead of each feedback mode against a bare
blackbox baseline, on a byte-identical replayed request workload.

Modes (5 for PHP, 4 for non-PHP — Native is PHP-only):
  blackbox                           no instrumentation, no tracing  [baseline]
  native                             source-code (AST) instrumented WUT
  tracelib_bigram_file_sql_filtered  uninstrumented WUT + syscall tracing
  tracelib_ebpf_simple               uninstrumented WUT + syscall tracing
  tracelib_ebpf                      uninstrumented WUT + syscall tracing

Options:
  -j, --jobs N          Concurrent applications (default: $JOBS; 1 is recommended,
                        because concurrent cells contend and inflate timings)
      --apps APP...     Select applications (positional APP also works)
      --requests N      Blackbox generator budget, i.e. the replay length
                        (default: $REQUESTS)
      --repetitions N   Repetitions per app/mode (default: $REPETITIONS)
      --result-dir DIR  Result directory (default: eval_result_single_endpoint/time_eval_<UTC>)
      --dry-run         Print the schedule without starting Docker
  -h, --help            Show this help

Outputs, under the result directory:
  request_baselines/APP_rNN.jsonl  the recorded blackbox request sequence
  request_timings.csv              every per-request observation, all modes
  overhead_summary.csv             overhead-eval.sh's own TraceLib summary
  time_overhead_by_mode.csv        per app x mode overhead vs blackbox, joined
                                   on request SHA-256, Native included
  time_overhead_by_mode.txt        the same table, formatted
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -j|--jobs)        [ "$#" -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; JOBS="$2"; shift 2 ;;
        --requests)       [ "$#" -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; REQUESTS="$2"; shift 2 ;;
        --repetitions)    [ "$#" -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; REPETITIONS="$2"; shift 2 ;;
        --result-dir)     [ "$#" -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; RESULT_DIR="$(realpath -m "$2")"; shift 2 ;;
        --apps)           shift; while [ "$#" -gt 0 ] && [[ "$1" != -* ]]; do APPS+=("$1"); shift; done ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --summarize-only) [ "$#" -ge 2 ] || { echo "ERROR: $1 needs a directory" >&2; exit 2; }
                          RESULT_DIR="$(realpath -m "$2")"; SUMMARIZE_ONLY=1; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; APPS+=("$@"); break ;;
        -*)               echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        *)                APPS+=("$1"); shift ;;
    esac
done

for name in REQUESTS REPETITIONS JOBS; do
    if [[ ! "${!name}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $name must be a positive integer (got '${!name}')" >&2
        exit 2
    fi
done
if [ "$SUMMARIZE_ONLY" != "1" ]; then
    [ -x "$OVERHEAD_RUNNER" ] || { echo "ERROR: missing overhead runner: $OVERHEAD_RUNNER" >&2; exit 2; }
fi

declare -a runner_args=(
    --identical-request-replay
    --modes "${MODES[@]}"
    --php-fuzz-requests "$REQUESTS"
    --nonphp-fuzz-requests "$REQUESTS"
    --repetitions "$REPETITIONS"
    --jobs "$JOBS"
    --result-dir "$RESULT_DIR"
)
[ "$DRY_RUN" = "1" ] && runner_args+=(--dry-run)
[ "${#APPS[@]}" -gt 0 ] && runner_args+=(--apps "${APPS[@]}")

summarize() {
    python3 - "$RESULT_DIR" <<'PY'
"""Per app x mode time overhead against blackbox, joined on request identity."""
import csv, math, statistics, sys
from pathlib import Path

result_dir = Path(sys.argv[1])
timings = result_dir / "request_timings.csv"
if not timings.is_file():
    print(f"time-eval: no {timings}; nothing to summarize", file=sys.stderr)
    raise SystemExit(0)

LABEL = {
    "blackbox": "Blackbox (no instrumentation)",
    "native": "Native (AST-instrumented WUT)",
    "tracelib_bigram_file_sql_filtered": "TraceLib projected (syscall)",
    "tracelib_ebpf_simple": "TraceLib plain bigram (syscall)",
    "tracelib_ebpf": "TraceLib N-gram (syscall)",
}
ORDER = list(LABEL)

obs, runtime_of = {}, {}
with timings.open(newline="", encoding="utf-8") as fh:
    for r in csv.DictReader(fh):
        try:
            http, cycle = float(r["http_response_ms"]), float(r["request_cycle_ms"])
        except (TypeError, ValueError):
            continue
        key = (r["app"], r["repetition"], r["mode"])
        sha = r.get("request_sha256") or f"ord:{r.get('request_ordinal')}"
        obs.setdefault(key, {})[sha] = (http, cycle)
        runtime_of[r["app"]] = r.get("runtime", "")

def med(v):
    return statistics.median(v) if v else math.nan

rows = []
for (app, rep, mode), cur in sorted(obs.items()):
    base = obs.get((app, rep, "blackbox"))
    if not base:
        continue
    common = sorted(set(cur) & set(base))
    if not common:
        continue
    ch = [cur[s][0] for s in common]; bh = [base[s][0] for s in common]
    cc = [cur[s][1] for s in common]; bc = [base[s][1] for s in common]
    mh, mbh, mc, mbc = med(ch), med(bh), med(cc), med(bc)
    rows.append(dict(
        app=app, runtime=runtime_of.get(app, ""), repetition=rep, mode=mode,
        mode_label=LABEL.get(mode, mode), baseline_mode="blackbox",
        matched_requests=len(common),
        matched_fraction_of_mode=round(len(common) / len(cur), 4),
        median_http_response_ms=round(mh, 3),
        baseline_median_http_response_ms=round(mbh, 3),
        median_http_overhead_ms=round(mh - mbh, 3),
        median_http_overhead_percent=(round(100.0 * (mh - mbh) / mbh, 2) if mbh else ""),
        median_request_cycle_ms=round(mc, 3),
        baseline_median_request_cycle_ms=round(mbc, 3),
        median_cycle_overhead_ms=round(mc - mbc, 3),
        median_cycle_overhead_percent=(round(100.0 * (mc - mbc) / mbc, 2) if mbc else ""),
    ))

if not rows:
    print("time-eval: no mode shares requests with its blackbox baseline yet", file=sys.stderr)
    raise SystemExit(0)

fields = list(rows[0])
out_csv = result_dir / "time_overhead_by_mode.csv"
rows.sort(key=lambda r: (r["app"], r["repetition"],
                         ORDER.index(r["mode"]) if r["mode"] in ORDER else 99))
with out_csv.open("w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=fields); w.writeheader(); w.writerows(rows)

lines = [
    "Per-request time overhead against the blackbox baseline.",
    "Modes replay a byte-identical request sequence; rows are joined on request SHA-256.",
    "http = server-side (instrumentation/tracing); cycle = http + client-side feedback work.",
    "",
    f"{'app':11s} {'runtime':8s} {'mode':32s} {'n':>5s} "
    f"{'http ms':>9s} {'Δ ms':>8s} {'Δ %':>8s} {'cycle ms':>9s} {'Δ ms':>8s} {'Δ %':>8s}",
    "-" * 118,
]
last = None
for r in rows:
    if last and last != (r["app"], r["repetition"]):
        lines.append("")
    last = (r["app"], r["repetition"])
    lines.append(
        f"{r['app']:11s} {r['runtime']:8s} {r['mode_label']:32s} {r['matched_requests']:5d} "
        f"{r['median_http_response_ms']:9.3f} {r['median_http_overhead_ms']:8.3f} "
        f"{str(r['median_http_overhead_percent']):>8s} "
        f"{r['median_request_cycle_ms']:9.3f} {r['median_cycle_overhead_ms']:8.3f} "
        f"{str(r['median_cycle_overhead_percent']):>8s}")
text = "\n".join(lines) + "\n"
(result_dir / "time_overhead_by_mode.txt").write_text(text, encoding="utf-8")
print(text)
print(f"wrote {out_csv}")
PY
}

if [ "$SUMMARIZE_ONLY" = "1" ]; then
    [ -d "$RESULT_DIR" ] || { echo "ERROR: no such result directory: $RESULT_DIR" >&2; exit 2; }
    summarize
    exit $?
fi

echo "======================== time-eval ========================"
echo "modes            : ${MODES[*]}"
echo "                   (native is dropped automatically for non-PHP apps)"
echo "workload         : blackbox records ${REQUESTS} requests, every mode replays them"
echo "repetitions      : $REPETITIONS"
echo "concurrent apps  : $JOBS"
echo "result dir       : $RESULT_DIR"
echo "==========================================================="

"$OVERHEAD_RUNNER" "${runner_args[@]}"
runner_rc=$?

if [ "$DRY_RUN" = "1" ]; then
    exit "$runner_rc"
fi

summarize
summary_rc=$?

if [ "$SIGNAL_RC" -ne 0 ]; then
    exit "$SIGNAL_RC"
fi
if [ "$runner_rc" -ne 0 ]; then
    exit "$runner_rc"
fi
exit "$summary_rc"
