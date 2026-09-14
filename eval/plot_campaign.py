#!/usr/bin/env python3
"""plot_campaign.py — graphs for a single long campaign.

Reads the per-5-minute stats CSV produced by eval/run_campaign_all.sh and
emits PNG graphs of the (mode-independent) coverage counter and the
campaign's throughput / request / corpus growth over wall-clock time.

The coverage_pct column is the apple-to-apple counter chosen per runtime:
AST-edge coverage for PHP (all modes), and the platform's own line tool
for non-PHP (c8/V8 for Node, go-cover for Go, coverage.py for Python).

Output files are named after the CSV stem and written next to the CSV
(default) so eval_result/ stays flat:
    <stem>_coverage.png   headline coverage-over-time
    <stem>_overview.png   coverage / throughput / requests / corpus

Usage:
    plot_campaign.py <stats.csv> [<out_dir>]
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def _f(row: dict, key: str):
    v = (row.get(key) or "").strip()
    if v == "":
        return None
    try:
        return float(v)
    except ValueError:
        return None

def load(csv_path: Path):
    with csv_path.open(newline="") as f:
        return list(csv.DictReader(f))

def series(rows, ykey):
    xs, ys = [], []
    for r in rows:
        x = _f(r, "elapsed_h")
        y = _f(r, ykey)
        if x is None or y is None:
            continue
        xs.append(x)
        ys.append(y)
    return xs, ys

def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    csv_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else csv_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = csv_path.stem

    rows = load(csv_path)
    if not rows:
        print(f"plot_campaign: no rows in {csv_path}", file=sys.stderr)
        return 1

    last = rows[-1]
    app = last.get("app", "?")
    mode = last.get("mode", "?")
    csrc = last.get("coverage_source", "coverage")
    title_suffix = f"{app} / {mode} (coverage: {csrc})"

    panels = [
        ("coverage_pct",   "Coverage (%)",       "#2ca02c"),
        ("throughput_rps", "Throughput (req/s)", "#1f77b4"),
        ("total_requests", "Total requests",     "#1f77b4"),
        ("corpus_size",    "Corpus size",        "#1f77b4"),
    ]

    fig, axes = plt.subplots(2, 2, figsize=(13, 9))
    for ax, (ykey, ylabel, color) in zip(axes.flat, panels):
        xs, ys = series(rows, ykey)
        if xs:
            ax.plot(xs, ys, marker="o", ms=2.5, lw=1.3, color=color)
        else:
            ax.text(0.5, 0.5, "no data", ha="center", va="center",
                    transform=ax.transAxes, color="#999")
        ax.set_xlabel("Elapsed (hours)")
        ax.set_ylabel(ylabel)
        ax.grid(True, alpha=0.3)
    fig.suptitle(f"Campaign — {title_suffix}", fontsize=13)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    overview = out_dir / f"{stem}_overview.png"
    fig.savefig(overview, dpi=130)
    plt.close(fig)

    xs, ys = series(rows, "coverage_pct")
    fig, ax = plt.subplots(figsize=(9, 5.5))
    if xs:
        ax.plot(xs, ys, marker="o", ms=3, lw=1.5, color="#2ca02c")
        ax.set_ylim(bottom=0)
    else:
        ax.text(0.5, 0.5, "no coverage data", ha="center", va="center",
                transform=ax.transAxes, color="#999")
    ax.set_xlabel("Elapsed (hours)")
    ax.set_ylabel("Coverage (%)")
    ax.set_title(f"Coverage over time — {title_suffix}")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    cov = out_dir / f"{stem}_coverage.png"
    fig.savefig(cov, dpi=130)
    plt.close(fig)

    print(f"plot_campaign: wrote {overview}")
    print(f"plot_campaign: wrote {cov}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
