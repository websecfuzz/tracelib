#!/bin/sh

set -u

EMPTY_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
COVDIR="${NODE_V8_COVERAGE:-/coverage/v8}"

if [ ! -d "$COVDIR" ] || [ -z "$(find "$COVDIR" -maxdepth 1 -name '*.json' -type f -print -quit 2>/dev/null)" ]; then
    echo "coverage_error: no_v8_coverage_files" >&2
    exit 3
fi

REPORT_DIR="$(mktemp -d /tmp/c8-report.XXXXXX)" || {
    echo "coverage_error: report_temp_dir_failed" >&2
    exit 3
}
cleanup() {
    rm -rf "$REPORT_DIR"
}
trap cleanup EXIT

C8_ERROR_FILE="$REPORT_DIR/c8.stderr"
env -u NODE_OPTIONS -u NODE_V8_COVERAGE c8 report \
    --reporter=json \
    --reporter=json-summary \
    --report-dir "$REPORT_DIR" \
    --temp-directory "$COVDIR" >/dev/null 2>"$C8_ERROR_FILE"
c8_status=$?
if [ "$c8_status" -ne 0 ]; then
    c8_detail="$(tr '\r\n' ' ' < "$C8_ERROR_FILE" | cut -c1-500)"
    echo "coverage_error: c8_report_failed rc=$c8_status detail=${c8_detail:-none}" >&2
    exit 3
fi

env -u NODE_OPTIONS -u NODE_V8_COVERAGE node - "$REPORT_DIR" "$EMPTY_HASH" <<'JS'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const reportDir = process.argv[2];
const emptyHash = process.argv[3];

function readJson(name) {
  return JSON.parse(fs.readFileSync(path.join(reportDir, name), 'utf8'));
}

try {
  const summary = readJson('coverage-summary.json');
  const coverage = readJson('coverage-final.json');
  const lineSummary = summary.total && summary.total.lines ? summary.total.lines : {};
  const total = Number(lineSummary.total || 0);
  const covered = Number(lineSummary.covered || 0);
  const pct = Number(lineSummary.pct || 0);
  if (!Number.isFinite(total) || total <= 0) {
    throw new Error('zero_total_lines');
  }
  const coveredLines = new Set();

  for (const [fileName, fileCoverage] of Object.entries(coverage || {})) {
    const statementMap = fileCoverage.statementMap || {};
    const statements = fileCoverage.s || {};
    for (const [statementId, count] of Object.entries(statements)) {
      if (Number(count) <= 0) {
        continue;
      }
      const location = statementMap[statementId];
      if (!location || !location.start || !location.end) {
        continue;
      }
      const startLine = Number(location.start.line || 0);
      const endLine = Number(location.end.line || startLine);
      if (startLine <= 0) {
        continue;
      }
      for (let line = startLine; line <= Math.max(startLine, endLine); line += 1) {
        coveredLines.add(`${fileName}:${line}`);
      }
    }
  }

  let coverageHash = emptyHash;
  if (coveredLines.size > 0) {
    const digest = crypto.createHash('sha256');
    for (const item of Array.from(coveredLines).sort()) {
      digest.update(item);
      digest.update('\n');
    }
    coverageHash = digest.digest('hex');
  }

  console.log(`coverage_report: ${Object.keys(coverage || {}).length} files, ${covered} / ${total} lines covered (${pct.toFixed(2)}%)`);
  console.log(`coverage_hash: ${coverageHash}`);
  if (process.env.TRACELIB_COVERAGE_INCLUDE_ITEMS === '1') {
    for (const item of Array.from(coveredLines).sort()) {
      console.log(`coverage_item: ${item}`);
    }
  }
} catch (error) {
  console.error(`coverage_error: ${String(error && error.message || error).replace(/\s+/g, '_')}`);
  process.exitCode = 3;
}
JS
