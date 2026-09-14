#!/usr/bin/env python3
"""Aggregate TraceLib-vs-Native feedback alignment across applications and modes.

Reads the per-cell artifacts produced by
``single_endpoint_campaign/apps_feedback.sh`` (or any directory holding
``request_feedback/APP_MODE_requests.json`` files) and reports the standard
binary-classification view of how well each TraceLib encoding reproduces the
equivalence relation induced by the native code-coverage oracle.

Positive class = "the native oracle says these two requests differ".

    TP  native different, TraceLib different   correct split
    FN  native different, TraceLib same        false merge  (missed novelty)
    FP  native same,      TraceLib different   false split  (spurious novelty)
    TN  native same,      TraceLib same        correct merge

Per-cell metrics come straight from the cell's own pair counts. Pooled metrics
sum the four pair counts over the selected cells and recompute the rates, so a
large application cannot be hidden by a small one; per-application macro means
are reported alongside for the opposite view.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from compare_request_feedback_hashes import (
    classification_metrics,
    load_records,
    select_records,
    summarize,
)

MODE_ORDER = (
    "tracelib_ebpf_simple",
    "tracelib_ebpf",
    "tracelib_bigram_file_sql_filtered",
)
MODE_LABELS = {
    "tracelib_ebpf_simple": "Bigram",
    "tracelib_ebpf": "N-gram",
    "tracelib_bigram_file_sql_filtered": "Filtered file/SQL bigram",
}

PHP_APPS = (
    "wordpress",
    "hotcrp",
    "phpbb",
    "joomla",
    "bagisto",
    "drupal",
    "prestashop",
    "zencart",
)
NONPHP_APPS = ("ghost", "", "", "", "redmine", "", "gogs", "huginn", "superset", "wikijs", "petclinic", "roller")
APP_ORDER = PHP_APPS + NONPHP_APPS

REQUEST_FILE_RE = re.compile(r"^(?P<app>[a-z0-9]+)_(?P<mode>tracelib_[a-z0-9_]+)_requests\.json$")

@dataclass
class Cell:
    app: str
    mode: str
    source: Path
    records: int
    complete_records: int
    unique_requests: int
    comparable_pairs: int
    tp: int
    fn: int
    fp: int
    tn: int
    unique_code_hashes: Optional[int] = None
    unique_bitmap_hashes: Optional[int] = None

    @property
    def runtime(self) -> str:
        return "php" if self.app in PHP_APPS else "nonphp"

    def metrics(self) -> Dict[str, Any]:
        return classification_metrics(self.tp, self.fn, self.fp, self.tn)

def discover_cells(root: Path, limit: int) -> List[Cell]:
    """Recompute every cell from its raw request-hash stream."""
    request_dir = root / "request_feedback"
    search_dir = request_dir if request_dir.is_dir() else root
    cells: List[Cell] = []
    for path in sorted(search_dir.rglob("*_requests.json")):
        match = REQUEST_FILE_RE.match(path.name)
        if not match:
            print(f"  skipping unrecognized file name: {path.name}", file=sys.stderr)
            continue
        app = match.group("app")
        mode = match.group("mode")
        if mode not in MODE_LABELS:
            print(f"  skipping unknown mode {mode!r} in {path.name}", file=sys.stderr)
            continue
        records = select_records(load_records(path), limit)
        if not records:
            print(f"  skipping empty capture: {path.name}", file=sys.stderr)
            continue
        summary = summarize(records)
        if summary["complete_records"] < 2:
            print(
                f"  skipping {app}/{mode}: only {summary['complete_records']} paired records",
                file=sys.stderr,
            )
            continue
        cells.append(
            Cell(
                app=app,
                mode=mode,
                source=path,
                records=summary["records"],
                complete_records=summary["complete_records"],
                unique_requests=summary["complete_unique_requests"],
                comparable_pairs=summary["comparable_pairs"],
                tp=summary["true_positive_code_diff_bitmap_diff"],
                fn=summary["false_merge_code_diff_bitmap_same"],
                fp=summary["false_split_code_same_bitmap_diff"],
                tn=summary["true_negative_code_same_bitmap_same"],
                unique_code_hashes=summary["unique_code_hashes"],
                unique_bitmap_hashes=summary["unique_bitmap_hashes"],
            )
        )
    return cells

def pool(cells: Sequence[Cell]) -> Dict[str, Any]:
    tp = sum(c.tp for c in cells)
    fn = sum(c.fn for c in cells)
    fp = sum(c.fp for c in cells)
    tn = sum(c.tn for c in cells)
    result = classification_metrics(tp, fn, fp, tn)
    result["cells"] = len(cells)
    result["applications"] = sorted({c.app for c in cells})
    result["complete_records"] = sum(c.complete_records for c in cells)
    return result

def macro(cells: Sequence[Cell], key: str) -> Optional[float]:
    values = [c.metrics()[key] for c in cells]
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None

def fmt(value: Optional[float], digits: int = 2, scale: float = 100.0) -> str:
    if value is None:
        return "n/a"
    return f"{value * scale:.{digits}f}"

def fmt_signed(value: Optional[float]) -> str:
    return "n/a" if value is None else f"{value:+.4f}"

def app_sort_key(app: str) -> tuple:
    return (APP_ORDER.index(app) if app in APP_ORDER else len(APP_ORDER), app)

def mode_sort_key(mode: str) -> tuple:
    return (MODE_ORDER.index(mode) if mode in MODE_ORDER else len(MODE_ORDER), mode)

def print_table(rows: Sequence[Sequence[str]], headers: Sequence[str]) -> None:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, value in enumerate(row):
            widths[i] = max(widths[i], len(value))
    line = "  ".join(h.ljust(widths[i]) if i == 0 else h.rjust(widths[i]) for i, h in enumerate(headers))
    print(line)
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print(
            "  ".join(
                value.ljust(widths[i]) if i == 0 else value.rjust(widths[i])
                for i, value in enumerate(row)
            )
        )

METRIC_COLUMNS = (
    ("TPR%", "tpr"),
    ("TNR%", "tnr"),
    ("FPR%", "fpr"),
    ("FNR%", "fnr"),
    ("Prec%", "precision"),
    ("F1%", "f1"),
    ("Acc%", "accuracy"),
    ("BalAcc%", "balanced_accuracy"),
)

def report(cells: Sequence[Cell], runtime: str, matched_only: bool) -> Dict[str, Any]:
    subset = [c for c in cells if c.runtime == runtime]
    if not subset:
        return {}
    modes = sorted({c.mode for c in subset}, key=mode_sort_key)
    apps = sorted({c.app for c in subset}, key=app_sort_key)
    if matched_only:
        available = {(c.app, c.mode) for c in subset}
        apps = [a for a in apps if all((a, m) in available for m in modes)]
        subset = [c for c in subset if c.app in apps]
        if not subset:
            return {}

    title = "PHP (native AST-edge oracle)" if runtime == "php" else "non-PHP (runtime line oracle)"
    print()
    print("=" * 100)
    print(f"{title} — {len(apps)} applications x {len(modes)} TraceLib encodings")
    if matched_only:
        print("matched set: only applications captured under every listed encoding")
    print("=" * 100)

    index = {(c.app, c.mode): c for c in subset}

    print()
    print("Per-cell alignment (positive class = native coverage differs)")
    headers = ["app / encoding", "pairs", "TP", "FN", "FP", "TN"] + [h for h, _ in METRIC_COLUMNS] + ["MCC", "ARI"]
    rows: List[List[str]] = []
    for app in apps:
        for mode in modes:
            cell = index.get((app, mode))
            if cell is None:
                continue
            m = cell.metrics()
            rows.append(
                [
                    f"{app} / {MODE_LABELS[mode]}",
                    f"{cell.comparable_pairs:,}",
                    f"{cell.tp:,}",
                    f"{cell.fn:,}",
                    f"{cell.fp:,}",
                    f"{cell.tn:,}",
                ]
                + [fmt(m[key]) for _, key in METRIC_COLUMNS]
                + [fmt_signed(m["matthews_corrcoef"]), fmt_signed(m["adjusted_rand_index"])]
            )
    print_table(rows, headers)

    print()
    print("Pooled by encoding (pair counts summed over applications, then recomputed)")
    pooled_rows: List[List[str]] = []
    payload: Dict[str, Any] = {"applications": apps, "modes": modes, "per_mode": {}}
    for mode in modes:
        mode_cells = [c for c in subset if c.mode == mode]
        p = pool(mode_cells)
        payload["per_mode"][mode] = {
            "pooled": p,
            "macro_tpr": macro(mode_cells, "tpr"),
            "macro_tnr": macro(mode_cells, "tnr"),
            "macro_fpr": macro(mode_cells, "fpr"),
            "macro_fnr": macro(mode_cells, "fnr"),
            "macro_balanced_accuracy": macro(mode_cells, "balanced_accuracy"),
            "per_app": {
                c.app: {
                    "comparable_pairs": c.comparable_pairs,
                    "true_positive": c.tp,
                    "false_negative": c.fn,
                    "false_positive": c.fp,
                    "true_negative": c.tn,
                    "complete_records": c.complete_records,
                    "unique_requests": c.unique_requests,
                    "unique_code_hashes": c.unique_code_hashes,
                    "unique_bitmap_hashes": c.unique_bitmap_hashes,
                    **c.metrics(),
                }
                for c in mode_cells
            },
        }
        pooled_rows.append(
            [
                MODE_LABELS[mode],
                f"{p['comparable_pairs']:,}",
                f"{p['true_positive']:,}",
                f"{p['false_negative']:,}",
                f"{p['false_positive']:,}",
                f"{p['true_negative']:,}",
            ]
            + [fmt(p[key]) for _, key in METRIC_COLUMNS]
            + [fmt_signed(p["matthews_corrcoef"]), fmt_signed(p["adjusted_rand_index"])]
        )
    print_table(pooled_rows, ["encoding", "pairs", "TP", "FN", "FP", "TN"] + [h for h, _ in METRIC_COLUMNS] + ["MCC", "ARI"])

    print()
    print("Macro means over applications (each application weighted equally)")
    macro_rows = [
        [
            MODE_LABELS[mode],
            fmt(payload["per_mode"][mode]["macro_tpr"]),
            fmt(payload["per_mode"][mode]["macro_tnr"]),
            fmt(payload["per_mode"][mode]["macro_fpr"]),
            fmt(payload["per_mode"][mode]["macro_fnr"]),
            fmt(payload["per_mode"][mode]["macro_balanced_accuracy"]),
        ]
        for mode in modes
    ]
    print_table(macro_rows, ["encoding", "TPR%", "TNR%", "FPR%", "FNR%", "BalAcc%"])
    return payload

def write_csv(cells: Sequence[Cell], output: Path) -> None:
    fields = [
        "app",
        "runtime",
        "mode",
        "mode_label",
        "complete_records",
        "unique_requests",
        "unique_code_hashes",
        "unique_bitmap_hashes",
        "comparable_pairs",
        "native_different_pairs",
        "native_same_pairs",
        "true_positive",
        "false_negative",
        "false_positive",
        "true_negative",
        "tpr",
        "tnr",
        "fpr",
        "fnr",
        "precision",
        "negative_predictive_value",
        "f1",
        "jaccard",
        "accuracy",
        "balanced_accuracy",
        "matthews_corrcoef",
        "adjusted_rand_index",
        "source",
    ]
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for cell in sorted(cells, key=lambda c: (app_sort_key(c.app), mode_sort_key(c.mode))):
            m = cell.metrics()
            writer.writerow(
                {
                    "app": cell.app,
                    "runtime": cell.runtime,
                    "mode": cell.mode,
                    "mode_label": MODE_LABELS[cell.mode],
                    "complete_records": cell.complete_records,
                    "unique_requests": cell.unique_requests,
                    "unique_code_hashes": cell.unique_code_hashes,
                    "unique_bitmap_hashes": cell.unique_bitmap_hashes,
                    "comparable_pairs": cell.comparable_pairs,
                    "native_different_pairs": m["native_different_pairs"],
                    "native_same_pairs": m["native_same_pairs"],
                    "true_positive": cell.tp,
                    "false_negative": cell.fn,
                    "false_positive": cell.fp,
                    "true_negative": cell.tn,
                    "tpr": m["tpr"],
                    "tnr": m["tnr"],
                    "fpr": m["fpr"],
                    "fnr": m["fnr"],
                    "precision": m["precision"],
                    "negative_predictive_value": m["negative_predictive_value"],
                    "f1": m["f1"],
                    "jaccard": m["jaccard"],
                    "accuracy": m["accuracy"],
                    "balanced_accuracy": m["balanced_accuracy"],
                    "matthews_corrcoef": m["matthews_corrcoef"],
                    "adjusted_rand_index": m["adjusted_rand_index"],
                    "source": str(cell.source),
                }
            )
    print(f"\nwrote {output}")

def self_test() -> None:

    m = classification_metrics(tp=4, fn=0, fp=0, tn=2)
    assert m["tpr"] == 1.0 and m["tnr"] == 1.0 and m["fpr"] == 0.0 and m["fnr"] == 0.0
    assert m["balanced_accuracy"] == 1.0
    assert abs(m["adjusted_rand_index"] - 1.0) < 1e-12

    m = classification_metrics(tp=4, fn=0, fp=2, tn=0)
    assert m["tpr"] == 1.0 and m["tnr"] == 0.0 and m["fpr"] == 1.0
    assert m["balanced_accuracy"] == 0.5

    m = classification_metrics(tp=0, fn=4, fp=0, tn=2)
    assert m["tpr"] == 0.0 and m["tnr"] == 1.0 and m["fnr"] == 1.0
    assert m["balanced_accuracy"] == 0.5

    a = Cell("a", "tracelib_ebpf_simple", Path("a"), 2, 2, 2, 1, 1, 0, 0, 0)
    b = Cell("b", "tracelib_ebpf_simple", Path("b"), 2, 2, 2, 1, 0, 0, 1, 0)
    p = pool([a, b])
    assert p["true_positive"] == 1 and p["false_positive"] == 1
    assert p["comparable_pairs"] == 2
    print("aggregate_feedback_alignment: self-test passed")

def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "run_dirs",
        nargs="*",
        type=Path,
        help="apps_feedback result directories (each holding request_feedback/)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="analyze only the first N records of each capture; 0 uses all (default: 0)",
    )
    parser.add_argument(
        "--matched-only",
        action="store_true",
        help="restrict each runtime block to applications captured under every encoding",
    )
    parser.add_argument("--csv", type=Path, help="write the per-cell table to this CSV")
    parser.add_argument("--json", type=Path, help="write the pooled summary to this JSON")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        return 0
    if not args.run_dirs:
        parser.error("at least one result directory is required")

    cells: List[Cell] = []
    for run_dir in args.run_dirs:
        if not run_dir.is_dir():
            parser.error(f"not a directory: {run_dir}")
        print(f"scanning {run_dir}", file=sys.stderr)
        found = discover_cells(run_dir, args.limit)
        print(f"  loaded {len(found)} cells", file=sys.stderr)
        cells.extend(found)
    if not cells:
        print("no usable alignment cells were found", file=sys.stderr)
        return 1

    payload: Dict[str, Any] = {
        "run_dirs": [str(d) for d in args.run_dirs],
        "record_limit": args.limit,
        "matched_only": bool(args.matched_only),
        "cells": len(cells),
    }
    for runtime in ("php", "nonphp"):
        block = report(cells, runtime, args.matched_only)
        if block:
            payload[runtime] = block

    if args.csv:
        write_csv(cells, args.csv)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        print(f"wrote {args.json}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
