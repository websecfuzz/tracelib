#ifndef TRACELIB_CONFIG_H
#define TRACELIB_CONFIG_H

#include <stdint.h>
#include <stddef.h>
#include "cov_shared.h"

enum backend_kind { BACKEND_AUTO = 0, BACKEND_PTRACE, BACKEND_EBPF };
enum coverage_mode { COV_NGRAM = 0, COV_BIGRAM };

#define SYSCALL_FILTER_MAX 512

enum param_source {
    PARAM_SQL = 0,
    PARAM_OPEN_PATH,
    PARAM_FILE_EDGE,
    PARAM_CONNECT_PORT,
    PARAM_COUNT
};

struct config {
    uint16_t port;
    char     header[128];
    char     header_lc[128];
    size_t   header_len;

    int      backend;
    int      coverage_mode;
    int      theta;
    char     calib_file[256];
    char     raw_trace_dir[256];

    int      no_arg_hash;
    int      no_sql;
    int      file_sql_only;
    int      file_sql_unfiltered;
    int      file_sql_filtered;
    int      file_sql_pred_args;
    int      end_on_status_line;
    int      sql_compact;
    int      syscall_filter;
    char     syscall_filter_file[256];
    uint32_t syscall_allowlist[SYSCALL_FILTER_MAX];
    size_t   syscall_allowlist_count;
    int      file_edges;
    int      top_edges;
    int      bigram_file_sql_separated;
    int      separated_min_hits;
    char     file_path_monitored[256];
    char     excluded_file_path[EXCLUDED_FILE_PATH_MAX];
    char     excluded_tokens[EXCLUDED_TOKENS_MAX][EXCLUDED_TOKEN_MAX + 1];
    int      excluded_token_count;

    int      mask[PARAM_COUNT];
};

static inline int config_file_sql_args(const struct config *cfg)
{
    return cfg->file_sql_only || cfg->file_sql_unfiltered || cfg->file_sql_filtered;
}

static inline int config_file_sql_filtered(const struct config *cfg)
{
    return cfg->file_sql_filtered;
}

static inline int config_end_on_status_line(const struct config *cfg)
{
    return cfg->end_on_status_line;
}

static inline int config_sql_compact(const struct config *cfg)
{
    return cfg->sql_compact;
}

static inline int config_file_sql_pred_args(const struct config *cfg)
{
    if (cfg->file_sql_filtered)
        return 1;
    return cfg->file_sql_unfiltered && cfg->file_sql_pred_args;
}

int config_path_is_monitored(const struct config *cfg, const char *path, size_t len);

void config_excluded_parse(struct config *cfg);

static inline int config_bigram_separated(const struct config *cfg)
{
    return cfg->bigram_file_sql_separated;
}

static inline int config_top_edges(const struct config *cfg)
{
    return cfg->top_edges > 0;
}

void config_defaults(struct config *cfg);

void config_from_env(struct config *cfg);

int  config_from_args(struct config *cfg, int argc, char **argv);

int  config_load_syscall_filter(struct config *cfg);

int  config_syscall_allowed(const struct config *cfg, long syscall_nr);

void config_load_calib(struct config *cfg);

void config_finalize_header(struct config *cfg);

void config_banner(const struct config *cfg, const char *active_backend);

void config_usage(const char *argv0);

#endif
