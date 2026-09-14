#!/usr/bin/env python3
"""coverage_report.py — aggregator the sidecar runs inside the container.

Combines the per-process .coverage.<pid>.<random> files coverage.py
writes under /coverage/ and prints a one-line summary in the same shape
as php-common/coverage_report.php so the sidecar's regex picks it up:

    coverage_report: <files> files, <hit> / <total> lines covered (<pct>%)
    coverage_hash: <sha256 of sorted covered file:line entries>
    coverage_item: <covered file:line>  (TRACELIB_COVERAGE_INCLUDE_ITEMS=1)
"""

import hashlib
import os
import sys

import coverage

DATA_FILE = os.environ.get("COVERAGE_DATA_FILE", "/coverage/.coverage")
EMPTY_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

def main() -> int:
    cov = coverage.Coverage(data_file=DATA_FILE)
    try:
        cov.combine(strict=False, keep=True)
    except coverage.misc.CoverageException:

        print("coverage_report: 0 files, 0 / 0 lines covered (0.00%)")
        print(f"coverage_hash: {EMPTY_HASH}")
        return 0

    cov.load()

    total_hit = 0
    total_exec = 0
    file_count = 0
    covered_lines = []
    skipped = 0
    for fname in cov.get_data().measured_files():
        try:
            analysis = cov.analysis2(fname)
        except Exception:

            skipped += 1
            continue

        executable = set(analysis[1])
        missing = set(analysis[3])
        hit = executable - missing
        if not executable:
            continue
        file_count += 1
        total_hit += len(hit)
        total_exec += len(executable)
        covered_lines.extend(f"{fname}:{line}" for line in hit)

    pct = (100.0 * total_hit / total_exec) if total_exec > 0 else 0.0
    print(
        "coverage_report: {} files, {} / {} lines covered ({:.2f}%)".format(
            file_count, total_hit, total_exec, pct
        )
    )
    if skipped:
        print(f"coverage_note: skipped {skipped} unparsable measured file(s)", file=sys.stderr)
    digest = hashlib.sha256()
    for item in sorted(set(covered_lines)):
        digest.update(item.encode("utf-8"))
        digest.update(b"\n")
    print(f"coverage_hash: {digest.hexdigest()}")
    if os.environ.get("TRACELIB_COVERAGE_INCLUDE_ITEMS") == "1":
        for item in sorted(set(covered_lines)):
            print(f"coverage_item: {item}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
