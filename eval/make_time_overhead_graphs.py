#!/usr/bin/env python3
"""Time-overhead figures for one time-eval campaign directory.

A time-eval campaign replays the same recorded request sequence under every
mode and records two signals per request:

  http_response_ms   the aiohttp request/response duration, that is the
                     server-side cost of instrumentation or tracing
  request_cycle_ms   completion-to-completion wall time, which adds the
                     client-side feedback work: bitmap wait, decode and the
                     corpus decision

Cells are compared over the requests they share with their own blackbox cell,
matched on request SHA-256, so every figure summarises the same requests under
different observers. Bars are means; the mean is used rather than the median
because these latency distributions are heavy-tailed and, on applications whose
responses fall into two clusters, the median is not a stable summary.

Produces:

  <prefix>-http-mean.png     mean HTTP response time per request
  <prefix>-cycle-mean.png    mean request cycle time per request

Usage:
  python3 eval/make_time_overhead_graphs.py RESULT_DIR [--outdir DIR]
                                            [--prefix NAME]
"""
from __future__ import annotations

import argparse
import csv
import statistics as st
from collections import defaultdict
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
LABEL = {BLACKBOX: "Blackbox", NATIVE: "Native", PROJ: "TraceLib_Projected",
         PLAIN: "TraceLib_Plain", NGRAM: "TraceLib_Ngram"}

FS_TITLE, FS_TICK, FS_AXLABEL = 21, 16, 17
FS_VALUE, FS_SUPTITLE, FS_LEGEND = 14, 26, 19
PANEL_W, PANEL_H = 2.30, 4.35
LEGEND_ENTRY_IN = 3.4


def load(result_dir: Path):
    obs = defaultdict(dict)
    path = result_dir / "request_timings.csv"
    if not path.is_file():
        raise SystemExit(f"no request_timings.csv under {result_dir}")
    with open(path, newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            try:
                h = float(r["http_response_ms"])
                c = float(r["request_cycle_ms"])
            except (TypeError, ValueError, KeyError):
                continue
            if r.get("mode") not in MODES:
                continue
            obs[(r["app"], r["mode"])][r["request_sha256"]] = (h, c)
    return obs


def mean_paired(obs, app, mode, idx):
    base, cur = obs.get((app, BLACKBOX)), obs.get((app, mode))
    if not base or not cur:
        return None
    shared = sorted(set(cur) & set(base))
    return st.fmean(cur[s][idx] for s in shared) if shared else None


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


def fmt(v):
    return f"{v:,.0f}" if v >= 1000 else f"{v:.1f}"


def figure(obs, apps, idx, metric, title, out: Path, ncol):
    fig, axes, nrow = grid(apps, ncol)
    for ax, app in zip(axes, apps):
        modes, vals = [], []
        for m in MODES:
            v = mean_paired(obs, app, m, idx)
            if v is None:
                continue
            modes.append(m)
            vals.append(v)
        for xi, (m, v) in enumerate(zip(modes, vals)):
            ax.bar(xi, v, color=COLORS[m], hatch=HATCH[m],
                   edgecolor="white" if HATCH[m] else COLORS[m], lw=0.9,
                   width=0.76)
        top = max(vals) if vals else 1.0
        for xi, v in enumerate(vals):
            ax.text(xi, v + top * 0.04, fmt(v), ha="center", va="bottom",
                    fontsize=FS_VALUE, rotation=90)
        ax.set_xlim(-0.62, len(modes) - 0.38)
        ax.set_ylim(0, (top or 1.0) * 1.62)
        ax.set_xticks([])
        ax.tick_params(axis="y", labelsize=FS_TICK)
        ax.set_title(app, fontsize=FS_TITLE)
        ax.grid(axis="y", alpha=0.25, lw=0.7)
        ax.set_axisbelow(True)
    for r in range(nrow):
        axes[r * ncol].set_ylabel(f"mean {metric} (ms)", fontsize=FS_AXLABEL)
    fig.suptitle(title, fontsize=FS_SUPTITLE, y=0.985)
    present = [m for m in MODES if any(mean_paired(obs, a, m, idx) is not None
                                       for a in apps)]
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
    ap.add_argument("--prefix", default="overhead")
    ap.add_argument("--columns", type=int, default=0)
    args = ap.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)

    obs = load(args.result_dir)
    apps = sorted({a for a, m in obs if m == BLACKBOX})
    if not apps:
        raise SystemExit("no application has a blackbox baseline cell")
    ncol = args.columns or (len(apps) if len(apps) <= 8 else 8)

    written = [
        figure(obs, apps, 0, "HTTP response time",
               "Mean HTTP response time per request",
               args.outdir / f"{args.prefix}-http-mean.png", ncol),
        figure(obs, apps, 1, "request cycle time",
               "Mean request cycle time per request",
               args.outdir / f"{args.prefix}-cycle-mean.png", ncol),
    ]
    for p in written:
        print("wrote", p)


if __name__ == "__main__":
    main()
