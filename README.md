# TraceLib

Coverage-guided fuzzing of black-box web applications using **system-call
feedback**. TraceLib observes a web application through its syscall interface
rather than through its source code, so the same feedback mechanism works on an
application written in any language, without instrumenting it, rebuilding it, or
having access to its source.

The tracer runs as a sidecar next to the application container,
attributes syscall activity to individual HTTP requests, and reduces each
request's syscall stream to a 65,536-cell coverage bitmap that the fuzzer uses to
decide which inputs to keep.

---

## Feedback modes

Five modes are provided. The three TraceLib modes run the **same uninstrumented
application image** as Blackbox and differ only in how the observed syscall
stream is reduced to a bitmap.

| Mode | Application build | Feedback |
|---|---|---|
| `blackbox` | uninstrumented | none; every submitted input is kept |
| `native` | AST-instrumented source | edge coverage from the instrumented build (**PHP only**) |
| `tracelib_ebpf_simple` | uninstrumented | bigram over every traced syscall, arguments included |
| `tracelib_ebpf` | uninstrumented | rolling n-gram over every traced syscall |
| `tracelib_bigram_file_sql_filtered` | uninstrumented | bigram over **only** monitored-path file opens and recognised SQL buffers |

`blackbox` is the baseline that isolates the cost of feedback collection:
comparing it against a TraceLib mode compares two runs of one image that differ
only in whether a sidecar is watching. `native` is the conventional
source-instrumented alternative and exists for PHP applications only, so non-PHP
applications run four modes rather than five.

---

## Applications under test

Sixteen real-world applications across five language runtimes.

| Runtime | Applications |
|---|---|
| PHP | Bagisto, Drupal, HotCRP, Joomla, phpBB, PrestaShop, WordPress, Zen Cart |
| Node.js | Ghost, Wiki.js |
| Ruby | Redmine, Huginn |
| Java | Roller, PetClinic |
| Go | Gogs |
| Python | Superset |

Each lives in `apps/<name>/` with a `docker-compose.yml`, one `Dockerfile` per
image profile, and the login and seeding scripts that bring it to a usable state.
Drupal, PrestaShop and Zen Cart additionally ship a pre-installed application
tree and a matching database dump, because their upstream installers were not
reliable enough to run unattended.

---

## Requirements

- Linux with a kernel that supports eBPF (`CONFIG_DEBUG_INFO_BTF`), and `root`
  or `CAP_BPF` + `CAP_PERFMON` for the sidecar
- Docker and the Compose plugin
- `clang`, `llvm`, `libbpf` headers and `make` to build the tracer
- Python 3.10+ for the fuzzer and the analysis scripts
- Roughly 80 GB of disk for images and campaign output

```bash
make                                    # build the TraceLib tracer
make ebpf                               # build the eBPF loader
python3 -m pip install -r webfuzz/requirements.txt
python3 -m pip install matplotlib numpy # analysis scripts only
```

---

## Running a single cell

One cell is one application under one mode for one time budget. This is the unit
every campaign is built from.

```bash
MAX_HOURS=1 eval/run_campaign_v6.sh wordpress tracelib_bigram_file_sql_filtered
```

Results land in `eval_result/` as a per-cell CSV series, a summary file, the
fuzzer log and a coverage plot. Useful environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `MAX_HOURS` | `4` | wall-clock budget for the cell |
| `FUZZ_REQUEST_BUDGET` | unlimited | stop after this many fuzz requests instead |
| `INTERVAL` | `60` | seconds between coverage samples |
| `CRAWLER_PER_BASE_LIMIT` | `50` | crawl breadth before fuzzing starts |
| `RESULT_DIR` | `eval_result` | where to write |

---

## The three evaluations

Each campaign driver writes a result directory; each plot script turns one such
directory into figures. The plot scripts take the directory as an argument, so
they work on any campaign you run.

### 1. Coverage over time

How much of each application each mode reaches, sampled through the run.

```bash
eval/run_all_apps_time_budget_parallel.sh --hours 4 -j 4
python3 eval/make_coverage_graphs.py eval_result/all_apps_time_4h_<STAMP> \
        --outdir figures --prefix coverage
```

Produces a final-coverage bar figure and, when the campaign sampled coverage more
than once per cell, a coverage-over-time line figure. Coverage is reported in
covered lines (or AST edges for the PHP `native` oracle) rather than as a
percentage: the denominator a language runtime reports counts only the files it
actually loaded, so it varies between cells and percentages are not comparable
across modes.

### 2. Feedback quality

Whether a mode's bitmap preserves the equivalence relation that the language
runtime's own coverage defines. Each cell records, per request, the runtime's
coverage hash and the fuzzer's bitmap hash; the requests of a cell are
cross-multiplied into pairs and each pair is classified:

| | runtime says differ | runtime says same |
|---|---|---|
| **bitmap differs** | true positive, a correct split | false positive, a spurious novelty |
| **bitmap same** | false negative, a missed novelty | true negative, a correct merge |

```bash
single_endpoint_campaign/apps_feedback.sh --apps ghost redmine wikijs roller -j 4
python3 eval/make_feedback_quality_graphs.py \
        eval_result_single_endpoint/apps_feedback_<STAMP> \
        --outdir figures --prefix feedback
```

Produces a TPR/FNR/FPR/TNR figure and a Matthews-correlation figure.

### 3. Time overhead

What feedback collection costs per request. Comparing modes that each generate
their own requests would measure the mutator as much as the tracer, so this
campaign does not do that:

1. an unmeasured `blackbox` generator fuzzes the application and records its
   request sequence;
2. every measured cell, `blackbox` included, replays that sequence without
   mutation;
3. replays have no wall-clock cap, so every mode finishes the whole sequence;
4. cells are compared over the requests they share, matched on **request
   SHA-256** — a digest of the method, URL, query and body parameters and the
   request's position in the sequence, excluding cookies and headers, so two
   cells match only when they issued the same request at the same point.

```bash
./time-eval.sh --requests 1000 -j 1
python3 eval/make_time_overhead_graphs.py \
        eval_result_single_endpoint/time_eval_<STAMP> \
        --outdir figures --prefix overhead
```

Two signals are recorded per request: `http_response_ms`, the server-side
request/response duration, and `request_cycle_ms`, the completion-to-completion
time that adds the client-side feedback work. Run this with `-j 1`; measuring
latency while a second application competes for the host inflates it by tens of
percent.

---

## Repository layout

```
src/  include/         TraceLib core: request demultiplexing, bitmap, SQL detection
ebpf/                  eBPF loader, BPF programs and the syscall configuration
ebpf-sidecar/          sidecar image that attaches the tracer to an app container
bpf/                   shared BPF headers
common/                container entrypoints for the instrumented and bare profiles
php-common/  node-common/  python-common/
ruby-common/ go-common/    java-common/
                       per-runtime coverage hooks used by the measurement oracle
webfuzz/               the fuzzer, its TraceLib feedback client and per-app logins
webFuzz/instrumentor/  the PHP AST instrumentor used by the `native` mode
webfuzz-patches/       the instrumentor visitor that emits edge counters
single_endpoint_campaign/
                       fixed-endpoint drivers: paired feedback capture and the
                       record/replay overhead harness
eval/                  campaign runners and the three analysis scripts
apps/                  the sixteen applications under test
```

---

## Notes

**Coverage percentages are not comparable across cells.** Tools such as `c8` and
`coverage.py` count only the files a run actually loaded, so a mode that reaches
further can report a *lower* percentage on a larger denominator. Compare covered
lines, and treat an application whose denominator moves between cells as
unusable for comparing modes.

**`native` is PHP-only.** There is no source-instrumented build for the other
runtimes, so any Native-versus-TraceLib comparison is a comparison over PHP
applications alone and should not be pooled with the rest.
