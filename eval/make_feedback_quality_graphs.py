#!/usr/bin/env python3
"""Feedback-quality figures for one paired-feedback campaign directory.

A paired-feedback campaign records, for every fuzz request, the language
runtime's own coverage hash and the fuzzer's bitmap hash. Cross-multiplying the
requests of a cell gives n(n-1)/2 comparable pairs, each classified against the
runtime oracle:

  TP  runtime differs, bitmap differs   correct split
  FN  runtime differs, bitmap same      false merge, a missed novelty
  FP  runtime same,    bitmap differs   false split, a spurious novelty
  TN  runtime same,    bitmap same      correct merge

Produces:

  <prefix>-confusion.png     TPR, FNR, FPR and TNR per application and mode
  <prefix>-quality.png       Matthews correlation and balanced accuracy

A bar marked n/a is a metric the campaign left undefined: the Matthews
correlation has no value when one of the two classes is empty, which happens
when a bitmap answers "same" or "different" for every comparable pair.

Usage:
  python3 eval/make_feedback_quality_graphs.py RESULT_DIR [--outdir DIR]
                                               [--prefix NAME]
                                               [--novelty bucket|index]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

PROJ, PLAIN, NGRAM = ("tracelib_bigram_file_sql_filtered",
                      "tracelib_ebpf_simple", "tracelib_ebpf")
MODES = [PROJ, PLAIN, NGRAM]
COLORS = {PROJ: "#cc0000", PLAIN: "#cc0000", NGRAM: "#e08214"}
HATCH = {PROJ: "", PLAIN: "///", NGRAM: ""}
LABEL = {PROJ: "TraceLib_Projected", PLAIN: "TraceLib_Plain",
         NGRAM: "TraceLib_Ngram"}

RATES = [("tpr", "TPR"), ("fnr", "FNR"), ("fpr", "FPR"), ("tnr", "TNR")]
QUALITY = [("matthews_corrcoef", "Matthews correlation"),
           ("balanced_accuracy", "Balanced accuracy")]

FS_TITLE, FS_TICK, FS_AXLABEL = 21, 16, 17
FS_VALUE, FS_SUPTITLE, FS_LEGEND = 13, 26, 19
PANEL_W, PANEL_H = 2.60, 4.35
LEGEND_ENTRY_IN = 3.4


def load(result_dir: Path, novelty: str):
    out = {}
    pattern = str(result_dir / "alignment" / f"*_{novelty}_alignment_summary.json")
    for path in sorted(glob.glob(pattern)):
        base = os.path.basename(path)
        base = base[: -len(f"_{novelty}_alignment_summary.json")]
        if "_tracelib" not in base:
            continue
        app = base.split("_tracelib")[0]
        mode = "tracelib" + base.split("_tracelib")[1]
        if mode not in MODES:
            continue
        with open(path, encoding="utf-8") as fh:
            summary = json.load(fh)["summary"]
        out[(app, mode)] = summary["classification"]
    return out


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
    return ncol, min(0.32, (0.18 + 0.42 * rows) / fig.get_size_inches()[1])


def add_legend(fig, modes):
    ncol, _ = legend_geometry(fig, modes)
    handles = [plt.Rectangle((0, 0), 1, 1, facecolor=COLORS[m], hatch=HATCH[m],
                             edgecolor="white" if HATCH[m] else COLORS[m],
                             lw=0.9) for m in modes]
    fig.legend(handles, [LABEL[m] for m in modes], loc="lower center",
               ncol=ncol, fontsize=FS_LEGEND, frameon=False,
               bbox_to_anchor=(0.5, 0.004))


def grouped(data, apps, keys, title, ylim, out: Path, ncol):
    fig, axes, nrow = grid(apps, ncol)
    present = [m for m in MODES if any((a, m) in data for a in apps)]
    width = 0.8 / max(len(present), 1)
    for ax, app in zip(axes, apps):
        x = np.arange(len(keys))
        for j, m in enumerate(present):
            c = data.get((app, m))
            if not c:
                continue
            vals = []
            for k, _ in keys:
                v = c.get(k)
                vals.append(float("nan") if v is None else float(v))
            off = (j - (len(present) - 1) / 2) * width
            ax.bar(x + off, vals, width=width * 0.92, color=COLORS[m],
                   hatch=HATCH[m],
                   edgecolor="white" if HATCH[m] else COLORS[m], lw=0.8)
            for xi, v in zip(x + off, vals):
                if v == v:
                    ax.text(xi, max(v, 0) + 0.02, f"{v:.2f}", ha="center",
                            va="bottom", fontsize=FS_VALUE, rotation=90)
                else:
                    ax.text(xi, 0.02, "n/a", ha="center", va="bottom",
                            fontsize=FS_VALUE, rotation=90, color="#777777")
        ax.set_xticks(x)
        ax.set_xticklabels([lab for _, lab in keys], fontsize=FS_TICK)
        ax.set_ylim(*ylim)
        ax.tick_params(axis="y", labelsize=FS_TICK)
        ax.set_title(app, fontsize=FS_TITLE)
        ax.grid(axis="y", alpha=0.25, lw=0.7)
        ax.set_axisbelow(True)
    for r in range(nrow):
        axes[r * ncol].set_ylabel("rate", fontsize=FS_AXLABEL)
    fig.suptitle(title, fontsize=FS_SUPTITLE, y=0.985)
    _, margin = legend_geometry(fig, present)
    fig.tight_layout(rect=(0, margin, 1, 0.945))
    add_legend(fig, present)
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("result_dir", type=Path)
    ap.add_argument("--outdir", type=Path, default=Path("."))
    ap.add_argument("--prefix", default="feedback")
    ap.add_argument("--novelty", default="bucket", choices=["bucket", "index"])
    ap.add_argument("--columns", type=int, default=0)
    args = ap.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)

    data = load(args.result_dir, args.novelty)
    if not data:
        raise SystemExit(
            f"no {args.novelty} alignment summaries under "
            f"{args.result_dir / 'alignment'}")
    apps = sorted({a for a, _ in data})
    ncol = args.columns or (len(apps) if len(apps) <= 8 else 8)

    written = [
        grouped(data, apps, RATES,
                "Feedback agreement with the runtime coverage oracle",
                (0, 1.25), args.outdir / f"{args.prefix}-confusion.png", ncol),
        grouped(data, apps, QUALITY, "Feedback quality",
                (-0.35, 1.25), args.outdir / f"{args.prefix}-quality.png", ncol),
    ]
    for p in written:
        print("wrote", p)


if __name__ == "__main__":
    main()
