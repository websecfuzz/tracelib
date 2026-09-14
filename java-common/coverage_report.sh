#!/bin/sh

set -u

EMPTY_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

JACOCO_CLI="${JACOCO_CLI:-/tracelib-support/jacococli.jar}"
JACOCO_AGENT_HOST="${JACOCO_AGENT_HOST:-127.0.0.1}"
JACOCO_AGENT_PORT="${JACOCO_AGENT_PORT:-6300}"
JACOCO_CLASSFILES="${JACOCO_CLASSFILES:-}"
JAVA_BIN="${JAVA_BIN:-java}"

WORK="/tmp/jacoco-report"
EXEC="$WORK/jacoco.exec"
XML="$WORK/jacoco.xml"

empty_report() {
    echo "coverage_report: 0 files, 0 / 0 lines covered (0.00%)"
    echo "coverage_hash: $EMPTY_HASH"
    [ -n "${1:-}" ] && echo "coverage_error: $1"
    exit 0
}

command -v "$JAVA_BIN" >/dev/null 2>&1 || empty_report java_not_found
[ -f "$JACOCO_CLI" ] || empty_report jacoco_cli_missing
[ -n "$JACOCO_CLASSFILES" ] || empty_report jacoco_classfiles_unset

rm -rf "$WORK"
mkdir -p "$WORK" || empty_report report_temp_dir_failed

dump_args="--address $JACOCO_AGENT_HOST --port $JACOCO_AGENT_PORT --destfile $EXEC"
[ "${TRACELIB_COVERAGE_RESET:-0}" = "1" ] && dump_args="$dump_args --reset"
"$JAVA_BIN" -jar "$JACOCO_CLI" dump $dump_args >/dev/null 2>&1 || empty_report jacoco_dump_failed
[ -s "$EXEC" ] || empty_report jacoco_exec_empty

cf_args=""
old_ifs="$IFS"; IFS=":"
for entry in $JACOCO_CLASSFILES; do
    [ -e "$entry" ] && cf_args="$cf_args --classfiles $entry"
done
IFS="$old_ifs"
[ -n "$cf_args" ] && : || empty_report jacoco_classfiles_missing

"$JAVA_BIN" -jar "$JACOCO_CLI" report "$EXEC" $cf_args --xml "$XML" >/dev/null 2>&1 || empty_report jacoco_report_failed
[ -s "$XML" ] || empty_report jacoco_xml_empty

XML="$XML" python3 - <<'PY'
import hashlib
import os
import xml.etree.ElementTree as ET

path = os.environ["XML"]
try:
    root = ET.parse(path).getroot()
except Exception:
    print("coverage_report: 0 files, 0 / 0 lines covered (0.00%)")
    print("coverage_hash: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    print("coverage_error: jacoco_xml_unparsable")
    raise SystemExit(0)

files = 0
hit = 0
total = 0
covered = []
for package in root.iter("package"):
    pkg = package.get("name", "")
    for sourcefile in package.findall("sourcefile"):
        lines = sourcefile.findall("line")
        if not lines:
            continue
        files += 1
        name = f"{pkg}/{sourcefile.get('name', '')}" if pkg else sourcefile.get("name", "")
        for line in lines:
            total += 1
            if int(line.get("ci", "0")) > 0:
                hit += 1
                covered.append(f"{name}:{line.get('nr')}")

pct = (100.0 * hit / total) if total else 0.0
print(f"coverage_report: {files} files, {hit} / {total} lines covered ({pct:.2f}%)")
digest = hashlib.sha256()
for item in sorted(set(covered)):
    digest.update(item.encode("utf-8"))
    digest.update(b"\n")
print(f"coverage_hash: {digest.hexdigest()}")
if os.environ.get("TRACELIB_COVERAGE_INCLUDE_ITEMS") == "1":
    for item in sorted(set(covered)):
        print(f"coverage_item: {item}")
PY
