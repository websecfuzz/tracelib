#include "config.h"
#include "backend.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

volatile sig_atomic_t g_should_stop = 0;

static void on_term(int sig) { (void)sig; g_should_stop = 1; }

static const struct collect_backend *select_backend(const struct config *cfg)
{
    switch (cfg->backend) {
    case BACKEND_EBPF:
        if (!backend_ebpf.available()) {
            LOGE("--backend ebpf requested but eBPF is unavailable on this host.");
            LOGE("(needs BTF + CAP_BPF/CAP_PERFMON, and a build with EBPF=1)");
            return NULL;
        }
        return &backend_ebpf;

    case BACKEND_PTRACE:
        return &backend_ptrace;

    case BACKEND_AUTO:
    default:
        if (backend_ebpf.available()) {
            LOGI("auto: eBPF backend available — using it (in-kernel aggregation).");
            return &backend_ebpf;
        }
        LOGI("auto: eBPF unavailable — falling back to ptrace backend.");
        return &backend_ptrace;
    }
}

int main(int argc, char **argv)
{
    struct config cfg;
    config_defaults(&cfg);
    config_load_calib(&cfg);
    config_from_env(&cfg);
    int rc = config_from_args(&cfg, argc, argv);
    if (rc == 1) return 0;
    if (rc < 0)  return 2;
    if (config_load_syscall_filter(&cfg) != 0)
        return 2;
    config_finalize_header(&cfg);

    if (cfg.port == 0) {
        LOGE("missing required --port (or TRACELIB_PORT)");
        config_usage(argv[0]);
        return 2;
    }
    if (cfg.file_sql_only && cfg.file_sql_unfiltered) {
        LOGE("--file-sql-only and --file-sql-unfiltered are mutually exclusive");
        return 2;
    }

    if (cfg.file_sql_unfiltered && cfg.coverage_mode != COV_BIGRAM) {
        LOGE("--file-sql-unfiltered requires --coverage-mode bigram");
        return 2;
    }

    if (cfg.file_sql_filtered && cfg.coverage_mode != COV_BIGRAM) {
        LOGE("--bigram-file-sql-filtered requires --coverage-mode bigram");
        return 2;
    }
    if (cfg.file_sql_filtered && cfg.file_sql_unfiltered) {
        LOGE("--bigram-file-sql-filtered and --file-sql-unfiltered are mutually exclusive");
        return 2;
    }
    if (cfg.file_sql_filtered && config_bigram_separated(&cfg)) {
        LOGE("--bigram-file-sql-filtered and --bigram-file-sql-separated are mutually exclusive");
        return 2;
    }

    struct sigaction sa = {0};
    sa.sa_handler = on_term;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    const struct collect_backend *be = select_backend(&cfg);
    if (!be)
        return 3;
    if (cfg.raw_trace_dir[0] && be != &backend_ebpf) {
        LOGE("--raw-trace-dir requires the eBPF backend.");
        return 3;
    }

    if (config_sql_compact(&cfg) && be == &backend_ebpf && !cfg.no_sql) {
        if (cfg.coverage_mode != COV_BIGRAM)
            LOGE("NOTE: --coverage-mode ngram on the eBPF backend keys SQL buffers "
                 "on the in-kernel fold, NOT on <<COMMANDS>><<TABLES>>. Use "
                 "--backend ptrace for the compact encoding under N-gram.");
        else if (config_bigram_separated(&cfg))
            LOGE("NOTE: --bigram-file-sql-separated on the eBPF backend keys SQL "
                 "buffers on the in-kernel fold, NOT on <<COMMANDS>><<TABLES>>. "
                 "Use --backend ptrace for the compact encoding.");
    }

    config_banner(&cfg, be->name);

    if (be->start(cfg.port, &cfg) != 0) {

        if (cfg.backend == BACKEND_AUTO && be == &backend_ebpf) {
            LOGE("eBPF backend failed to start — falling back to ptrace.");
            be = &backend_ptrace;
            if (be->start(cfg.port, &cfg) != 0) {
                LOGE("ptrace backend also failed to start.");
                return 4;
            }
        } else {
            LOGE("backend '%s' failed to start.", be->name);
            return 4;
        }
    }

    LOGI("tracing... (Ctrl-C to stop)");
    be->run();
    be->stop();
    LOGI("stopped.");
    return 0;
}
