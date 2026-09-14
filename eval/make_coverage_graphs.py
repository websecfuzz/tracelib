#!/usr/bin/env python3
"""Coverage figures for one campaign directory.

Produces two figures from the per-cell CSV series a campaign writes:

  <prefix>-final-coverage.png        covered lines or edges at the end of the run,
                                     one panel per application, one bar per mode
  <prefix>-coverage-over-time.png    the same quantity sampled over the run

The second figure is written only when the campaign sampled coverage more than
once per cell. Coverage is reported in covered lines (or AST edges) rather than
as a percentage, because the denominator reported by a language runtime counts
only the files it actually loaded and therefore varies between cells.

Usage:
  python3 eval/make_coverage_graphs.py RESULT_DIR [--outdir DIR] [--prefix NAME]
"""
from __future__ import annotations

import argparse
import csv
import glob
import os
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

BLACKBOX, NATIVE = "blackbox", "native"
PROJ, PLAIN, NGRAM = ("tracelib_bigram_file_sql_filtered",
                      "tracelib_ebpf_simple", "tracelib_ebpf")
MODES = [BLACKBOX, NATIVE, PROJ, PLAIN, NGRAM]

COLORS = {BLACKBOX: "#000000", NATIVE: "#0033cc", PROJ: "#cc0000",
          PLAIN: "#cc0000", NGRAM: "#e08214"}
HATCH = {BLACKBOX: "", NATIVE: "", PROJ: "", PLAIN: "///", NGRAM: ""}
STYLE = {BLACKBOX: "-", NATIVE: "-", PROJ: "-", PLAIN: "--", NGRAM: ":"}
LW = {BLACKBOX: 2.4, NATIVE: 2.4, PROJ: 2.8, PLAIN: 2.4, NGRAM: 2.6}
LABEL = {BLACKBOX: "Blackbox", NATIVE: "Native", PROJ: "TraceLib_Projected",
         PLAIN: "TraceLib_Plain", NGRAM: "TraceLib_Ngram"}

FS_TITLE, FS_TICK, FS_AXLABEL = 21, 16, 17
FS_VALUE, FS_SUPTITLE, FS_LEGEND = 14, 26, 19
PANEL_W, PANEL_H = 2.30, 4.35
LEGEND_ENTRY_IN = 3.4


def load(result_dir: Path):
    series, final, unit = {}, {}, "covered lines"
    for path in sorted(glob.glob(str(result_dir / "*.csv"))):
        if "endpoint" in os.path.basename(path):
            continue
        with open(path, newline="", encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))
        if not rows or "coverage_covered" not in rows[0]:
            continue
        app, mode = rows[0].get("app"), rows[0].get("mode")
        if mode not in MODES:
            continue
        t, c = [], []
        for r in rows:
            try:
                c.append(int(r["coverage_covered"]))
                t.append(float(r["elapsed_s"]))
            except (TypeError, ValueError, KeyError):
                continue
            if r.get("coverage_source") == "ast_edges":
                unit = "covered AST edges"
        if not t:
            continue
        series[(app, mode)] = (np.array(t), np.array(c))
        final[(app, mode)] = c[-1]
    return series, final, unit


def grid(apps, ncol):
    nrow = int(np.ceil(len(apps) / ncol))
    fig, axes = plt.subplots(nrow, ncol,
                             figsize=(PANEL_W * ncol, PANEL_H * nrow))
    axes = np.atleast_1d(axes).ravel()
    for ax in axes[len(apps):]:
        ax.axis("off")
    return fig, axes, nrow


def legend_geometry(fig, modes):
    import math
    ncol = max(1, min(len(modes),
                      int(fig.get_size_inches()[0] / LEGEND_ENTRY_IN)))
    rows = math.ceil(len(modes) / ncol)
    margin = min(0.32, (0.18 + 0.42 * rows) / fig.get_size_inches()[1])
    return ncol, margin


def add_legend(fig, modes, line=False):
    ncol, _ = legend_geometry(fig, modes)
    if line:
        handles = [plt.Line2D([0], [0], color=COLORS[m], ls=STYLE[m], lw=LW[m])
                   for m in modes]
    else:
        handles = [plt.Rectangle((0, 0), 1, 1, facecolor=COLORS[m],
                                 hatch=HATCH[m],
                                 edgecolor="white" if HATCH[m] else COLORS[m],
                                 lw=0.9) for m in modes]
    fig.legend(handles, [LABEL[m] for m in modes], loc="lower center",
               ncol=ncol, fontsize=FS_LEGEND, frameon=False,
               bbox_to_anchor=(0.5, 0.004))


def fmt(v):
    return f"{v:,.0f}"


def fig_final(final, apps, unit, ncol, out: Path):
    fig, axes, nrow = grid(apps, ncol)
    for ax, app in zip(axes, apps):
        modes = [m for m in MODES if (app, m) in final]
        vals = [final[(app, m)] for m in modes]
        for xi, (m, v) in enumerate(zip(modes, vals)):
            ax.bar(xi, v, color=COLORS[m], hatch=HATCH[m],
                   edgecolor="white" if HATCH[m] else COLORS[m], lw=0.9,
                   width=0.76)
        top = max(vals) if vals else 1.0
        for xi, v in enumerate(vals):
            ax.text(xi, v + top * 0.04, fmt(v), ha="center", va="bottom",
                    fontsize=FS_VALUE, rotation=90)
        ax.set_xlim(-0.62, len(modes) - 0.38)
        ax.set_ylim(0, (top or 1.0) * 1.72)
        ax.set_xticks([])
        ax.tick_params(axis="y", labelsize=FS_TICK)
        ax.set_title(app, fontsize=FS_TITLE)
        ax.grid(axis="y", alpha=0.25, lw=0.7)
        ax.set_axisbelow(True)
    for r in range(nrow):
        axes[r * ncol].set_ylabel(unit, fontsize=FS_AXLABEL)
    fig.suptitle("Final coverage", fontsize=FS_SUPTITLE, y=0.985)
    present = [m for m in MODES if any((a, m) in final for a in apps)]
    _, margin = legend_geometry(fig, present)
    fig.tight_layout(rect=(0, margin, 1, 0.945))
    add_legend(fig, present)
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def fig_over_time(series, apps, unit, ncol, out: Path):
    fig, axes, nrow = grid(apps, ncol)
    for ax, app in zip(axes, apps):
        for m in MODES:
            s = series.get((app, m))
            if s is None:
                continue
            t, c = s
            ax.plot(t / 60.0, c, STYLE[m], color=COLORS[m], lw=LW[m])
        ax.set_xlim(left=0)
        ax.set_xlabel("elapsed (min)", fontsize=FS_AXLABEL)
        ax.tick_params(labelsize=FS_TICK)
        ax.set_title(app, fontsize=FS_TITLE)
        ax.grid(alpha=0.25, lw=0.7)
        ax.set_axisbelow(True)
    for r in range(nrow):
        axes[r * ncol].set_ylabel(unit, fontsize=FS_AXLABEL)
    fig.suptitle("Coverage over the run", fontsize=FS_SUPTITLE, y=0.985)
    present = [m for m in MODES if any((a, m) in series for a in apps)]
    _, margin = legend_geometry(fig, present)
    fig.tight_layout(rect=(0, margin, 1, 0.945))
    add_legend(fig, present, line=True)
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("result_dir", type=Path)
    ap.add_argument("--outdir", type=Path, default=Path("."))
    ap.add_argument("--prefix", default="coverage")
    ap.add_argument("--columns", type=int, default=0,
                    help="panels per row (default: all applications on one row "
                         "when there are at most eight)")
    args = ap.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)

    series, final, unit = load(args.result_dir)
    if not final:
        raise SystemExit(f"no coverage series found under {args.result_dir}")
    apps = sorted({a for a, _ in final})
    ncol = args.columns or (len(apps) if len(apps) <= 8 else 8)

    written = [fig_final(final, apps, unit, ncol,
                         args.outdir / f"{args.prefix}-final-coverage.png")]
    if max(len(s[0]) for s in series.values()) > 1:
        written.append(fig_over_time(
            series, apps, unit, ncol,
            args.outdir / f"{args.prefix}-coverage-over-time.png"))
    else:
        print("only one coverage sample per cell; skipping the over-time figure")
    for p in written:
        print("wrote", p)


if __name__ == "__main__":
    main()
