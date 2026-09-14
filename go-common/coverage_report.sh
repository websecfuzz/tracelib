#!/bin/sh

set -u

EMPTY_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
GO_BIN="${GO_BIN:-}"
if [ -z "$GO_BIN" ]; then
    if command -v go >/dev/null 2>&1; then
        GO_BIN="$(command -v go)"
    elif [ -x /usr/local/go/bin/go ]; then
        GO_BIN="/usr/local/go/bin/go"
    fi
fi

COVDIR="${GOCOVERDIR:-/coverage}"
SNAP="/tmp/cov-snapshot"

if [ -z "$GO_BIN" ]; then
    echo "coverage_report: 0 files, 0 / 0 lines covered (0.00%)"
    echo "coverage_hash: $EMPTY_HASH"
    echo "coverage_error: go_tool_not_found"
    exit 0
fi

if [ ! -d "$COVDIR" ] || [ -z "$(ls -A "$COVDIR" 2>/dev/null)" ]; then
    echo "coverage_report: 0 files, 0 / 0 lines covered (0.00%)"
    echo "coverage_hash: $EMPTY_HASH"
    exit 0
fi

rm -rf "$SNAP"
mkdir -p "$SNAP"
cp -a "$COVDIR"/. "$SNAP"/ 2>/dev/null || true

text=$("$GO_BIN" tool covdata textfmt -i "$SNAP" -o /dev/stdout 2>/dev/null || true)
if [ -z "$text" ]; then
    echo "coverage_report: 0 files, 0 / 0 lines covered (0.00%)"
    echo "coverage_hash: $EMPTY_HASH"
    exit 0
fi

coverage_hash=$(
    printf '%s\n' "$text" |
        awk 'NF >= 3 && $1 !~ /^mode:/ && ($3 + 0) > 0 { print $1 }' |
        LC_ALL=C sort -u |
        sha256sum |
        awk '{print $1}'
)
echo "$text" | awk '
    BEGIN { hit = 0; total = 0; files[""] = 0; delete files[""] }
    /^mode:/ { next }
    NF >= 3 {
        split($1, a, ":")
        files[a[1]] = 1
        total += $2
        if ($3 + 0 > 0) hit += $2
    }
    END {
        n_files = 0
        for (f in files) if (f != "") n_files++
        pct = (total > 0) ? (100.0 * hit / total) : 0.0
        printf("coverage_report: %d files, %d / %d lines covered (%.2f%%)\n",
               n_files, hit, total, pct)
    }
'
echo "coverage_hash: $coverage_hash"
if [ "${TRACELIB_COVERAGE_INCLUDE_ITEMS:-0}" = "1" ]; then
    printf '%s\n' "$text" |
        awk 'NF >= 3 && $1 !~ /^mode:/ && ($3 + 0) > 0 { print $1 }' |
        LC_ALL=C sort -u |
        sed 's/^/coverage_item: /'
fi
