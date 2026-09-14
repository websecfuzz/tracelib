#include "config.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <sys/syscall.h>

struct syscall_name {
    const char *name;
    uint32_t nr;
};

#define SYSCALL_NAME(name) { #name, (uint32_t)SYS_##name },

static const struct syscall_name syscall_names[] = {
#ifdef SYS_read
    SYSCALL_NAME(read)
#endif
#ifdef SYS_write
    SYSCALL_NAME(write)
#endif
#ifdef SYS_open
    SYSCALL_NAME(open)
#endif
#ifdef SYS_stat
    SYSCALL_NAME(stat)
#endif
#ifdef SYS_fstat
    SYSCALL_NAME(fstat)
#endif
#ifdef SYS_lstat
    SYSCALL_NAME(lstat)
#endif
#ifdef SYS_pread64
    SYSCALL_NAME(pread64)
#endif
#ifdef SYS_pwrite64
    SYSCALL_NAME(pwrite64)
#endif
#ifdef SYS_readv
    SYSCALL_NAME(readv)
#endif
#ifdef SYS_writev
    SYSCALL_NAME(writev)
#endif
#ifdef SYS_access
    SYSCALL_NAME(access)
#endif
#ifdef SYS_sendfile
    SYSCALL_NAME(sendfile)
#endif
#ifdef SYS_connect
    SYSCALL_NAME(connect)
#endif
#ifdef SYS_sendto
    SYSCALL_NAME(sendto)
#endif
#ifdef SYS_recvfrom
    SYSCALL_NAME(recvfrom)
#endif
#ifdef SYS_sendmsg
    SYSCALL_NAME(sendmsg)
#endif
#ifdef SYS_recvmsg
    SYSCALL_NAME(recvmsg)
#endif
#ifdef SYS_execve
    SYSCALL_NAME(execve)
#endif
#ifdef SYS_fsync
    SYSCALL_NAME(fsync)
#endif
#ifdef SYS_fdatasync
    SYSCALL_NAME(fdatasync)
#endif
#ifdef SYS_truncate
    SYSCALL_NAME(truncate)
#endif
#ifdef SYS_ftruncate
    SYSCALL_NAME(ftruncate)
#endif
#ifdef SYS_getdents
    SYSCALL_NAME(getdents)
#endif
#ifdef SYS_rename
    SYSCALL_NAME(rename)
#endif
#ifdef SYS_mkdir
    SYSCALL_NAME(mkdir)
#endif
#ifdef SYS_rmdir
    SYSCALL_NAME(rmdir)
#endif
#ifdef SYS_creat
    SYSCALL_NAME(creat)
#endif
#ifdef SYS_link
    SYSCALL_NAME(link)
#endif
#ifdef SYS_unlink
    SYSCALL_NAME(unlink)
#endif
#ifdef SYS_symlink
    SYSCALL_NAME(symlink)
#endif
#ifdef SYS_readlink
    SYSCALL_NAME(readlink)
#endif
#ifdef SYS_mknod
    SYSCALL_NAME(mknod)
#endif
#ifdef SYS_getdents64
    SYSCALL_NAME(getdents64)
#endif
#ifdef SYS_openat
    SYSCALL_NAME(openat)
#endif
#ifdef SYS_mkdirat
    SYSCALL_NAME(mkdirat)
#endif
#ifdef SYS_mknodat
    SYSCALL_NAME(mknodat)
#endif
#ifdef SYS_newfstatat
    SYSCALL_NAME(newfstatat)
#endif
#ifdef SYS_unlinkat
    SYSCALL_NAME(unlinkat)
#endif
#ifdef SYS_renameat
    SYSCALL_NAME(renameat)
#endif
#ifdef SYS_linkat
    SYSCALL_NAME(linkat)
#endif
#ifdef SYS_symlinkat
    SYSCALL_NAME(symlinkat)
#endif
#ifdef SYS_readlinkat
    SYSCALL_NAME(readlinkat)
#endif
#ifdef SYS_faccessat
    SYSCALL_NAME(faccessat)
#endif
#ifdef SYS_splice
    SYSCALL_NAME(splice)
#endif
#ifdef SYS_fallocate
    SYSCALL_NAME(fallocate)
#endif
#ifdef SYS_preadv
    SYSCALL_NAME(preadv)
#endif
#ifdef SYS_pwritev
    SYSCALL_NAME(pwritev)
#endif
#ifdef SYS_recvmmsg
    SYSCALL_NAME(recvmmsg)
#endif
#ifdef SYS_syncfs
    SYSCALL_NAME(syncfs)
#endif
#ifdef SYS_sendmmsg
    SYSCALL_NAME(sendmmsg)
#endif
#ifdef SYS_renameat2
    SYSCALL_NAME(renameat2)
#endif
#ifdef SYS_execveat
    SYSCALL_NAME(execveat)
#endif
#ifdef SYS_copy_file_range
    SYSCALL_NAME(copy_file_range)
#endif
#ifdef SYS_preadv2
    SYSCALL_NAME(preadv2)
#endif
#ifdef SYS_pwritev2
    SYSCALL_NAME(pwritev2)
#endif
#ifdef SYS_statx
    SYSCALL_NAME(statx)
#endif
#ifdef SYS_openat2
    SYSCALL_NAME(openat2)
#endif
#ifdef SYS_faccessat2
    SYSCALL_NAME(faccessat2)
#endif
};

#undef SYSCALL_NAME

static int uint32_cmp(const void *a, const void *b)
{
    uint32_t av = *(const uint32_t *)a;
    uint32_t bv = *(const uint32_t *)b;
    return av > bv ? 1 : av < bv ? -1 : 0;
}

static int syscall_name_to_nr(const char *token, uint32_t *nr)
{
    if (!strncmp(token, "SYS_", 4))
        token += 4;
    else if (!strncmp(token, "__NR_", 5))
        token += 5;

    for (size_t i = 0; i < sizeof(syscall_names) / sizeof(syscall_names[0]); i++) {
        if (!strcmp(token, syscall_names[i].name)) {
            *nr = syscall_names[i].nr;
            return 0;
        }
    }
    return -1;
}

static int parse_syscall_token(const char *token, uint32_t *nr)
{
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(token, &end, 0);
    if (!errno && end != token && *end == '\0') {
        if (value > INT_MAX)
            return -1;
        *nr = (uint32_t)value;
        return 0;
    }
    return syscall_name_to_nr(token, nr);
}

static int legacy_syscall_allowed(long sc)
{
#ifdef SYS_open
    if (sc == SYS_open) return 1;
#endif
#ifdef SYS_openat
    if (sc == SYS_openat) return 1;
#endif
#ifdef SYS_execve
    if (sc == SYS_execve) return 1;
#endif
#ifdef SYS_connect
    if (sc == SYS_connect) return 1;
#endif
#ifdef SYS_write
    if (sc == SYS_write) return 1;
#endif
#ifdef SYS_writev
    if (sc == SYS_writev) return 1;
#endif
#ifdef SYS_sendto
    if (sc == SYS_sendto) return 1;
#endif
#ifdef SYS_read
    if (sc == SYS_read) return 1;
#endif
#ifdef SYS_recvfrom
    if (sc == SYS_recvfrom) return 1;
#endif
    return 0;
}

int config_load_syscall_filter(struct config *cfg)
{
    cfg->syscall_allowlist_count = 0;
    if (!cfg->syscall_filter_file[0])
        return 0;

    FILE *f = fopen(cfg->syscall_filter_file, "r");
    if (!f) {
        LOGE("open syscall filter %s: %s", cfg->syscall_filter_file, strerror(errno));
        return -1;
    }

    char line[512];
    unsigned long line_no = 0;
    while (fgets(line, sizeof(line), f)) {
        line_no++;
        if (!strchr(line, '\n') && !feof(f)) {
            LOGE("%s:%lu: line is too long", cfg->syscall_filter_file, line_no);
            fclose(f);
            return -1;
        }

        char *comment = strchr(line, '#');
        if (comment) *comment = '\0';
        char *start = line;
        while (isspace((unsigned char)*start)) start++;
        char *end = start + strlen(start);
        while (end > start && isspace((unsigned char)end[-1])) *--end = '\0';
        if (!*start)
            continue;

        uint32_t nr;
        if (parse_syscall_token(start, &nr) != 0) {
            LOGE("%s:%lu: unknown syscall '%s' (use a supported name or number)",
                 cfg->syscall_filter_file, line_no, start);
            fclose(f);
            return -1;
        }

        int duplicate = 0;
        for (size_t i = 0; i < cfg->syscall_allowlist_count; i++) {
            if (cfg->syscall_allowlist[i] == nr) {
                duplicate = 1;
                break;
            }
        }
        if (duplicate)
            continue;
        if (cfg->syscall_allowlist_count == SYSCALL_FILTER_MAX) {
            LOGE("%s: more than %d distinct syscalls", cfg->syscall_filter_file,
                 SYSCALL_FILTER_MAX);
            fclose(f);
            return -1;
        }
        cfg->syscall_allowlist[cfg->syscall_allowlist_count++] = nr;
    }
    if (ferror(f)) {
        LOGE("read syscall filter %s: %s", cfg->syscall_filter_file, strerror(errno));
        fclose(f);
        return -1;
    }
    fclose(f);

    if (cfg->syscall_allowlist_count == 0) {
        LOGE("syscall filter %s contains no syscalls", cfg->syscall_filter_file);
        return -1;
    }
    qsort(cfg->syscall_allowlist, cfg->syscall_allowlist_count,
          sizeof(cfg->syscall_allowlist[0]), uint32_cmp);
    LOGI("loaded %zu syscall(s) from %s", cfg->syscall_allowlist_count,
         cfg->syscall_filter_file);
    return 0;
}

int config_syscall_allowed(const struct config *cfg, long syscall_nr)
{
    if (cfg->syscall_filter_file[0]) {
        if (syscall_nr < 0 || syscall_nr > INT_MAX)
            return 0;
        uint32_t key = (uint32_t)syscall_nr;
        return bsearch(&key, cfg->syscall_allowlist, cfg->syscall_allowlist_count,
                       sizeof(cfg->syscall_allowlist[0]), uint32_cmp) != NULL;
    }
    return !cfg->syscall_filter || legacy_syscall_allowed(syscall_nr);
}

static int clamp_theta(int t)
{
    if (t < 2) t = 2;
    if (t > THETA_MAX) t = THETA_MAX;
    return t;
}

void config_finalize_header(struct config *cfg)
{
    snprintf(cfg->header_lc, sizeof(cfg->header_lc), "%s", cfg->header);
    for (char *p = cfg->header_lc; *p; p++)
        *p = (char)tolower((unsigned char)*p);
    cfg->header_len = strlen(cfg->header_lc);
}

static int is_alpha_byte(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static char lc_byte(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : c;
}

void config_excluded_parse(struct config *cfg)
{
    cfg->excluded_token_count = 0;
    memset(cfg->excluded_tokens, 0, sizeof(cfg->excluded_tokens));

    const char *p = cfg->excluded_file_path;
    while (*p && cfg->excluded_token_count < EXCLUDED_TOKENS_MAX) {
        while (*p == ',' || *p == ';' || isspace((unsigned char)*p))
            p++;
        const char *start = p;
        while (*p && *p != ',' && *p != ';' && !isspace((unsigned char)*p))
            p++;
        size_t n = (size_t)(p - start);
        if (n == 0 || n > EXCLUDED_TOKEN_MAX)
            continue;
        memcpy(cfg->excluded_tokens[cfg->excluded_token_count], start, n);
        cfg->excluded_tokens[cfg->excluded_token_count][n] = '\0';
        cfg->excluded_token_count++;
    }
}

static void config_set_excluded(struct config *cfg, const char *value)
{
    snprintf(cfg->excluded_file_path, sizeof(cfg->excluded_file_path), "%s", value);
    config_excluded_parse(cfg);
}

static int path_contains_token(const char *path, size_t len, const char *needle)
{
    size_t nlen = strlen(needle);
    if (nlen == 0 || nlen > len)
        return 0;
    if (nlen > EXCLUDED_TOKEN_MAX)
        nlen = EXCLUDED_TOKEN_MAX;
    size_t scan = len > PATH_MATCH_MAX ? PATH_MATCH_MAX : len;
    for (size_t i = 0; i + nlen <= scan; i++) {
        size_t j = 0;
        while (j < nlen && lc_byte(path[i + j]) == lc_byte(needle[j]))
            j++;
        if (j != nlen)
            continue;
        if (i > 0 && is_alpha_byte(path[i - 1]))
            continue;
        if (i + nlen < scan && is_alpha_byte(path[i + nlen]))
            continue;
        return 1;
    }
    return 0;
}

int config_path_is_monitored(const struct config *cfg, const char *path, size_t len)
{

    for (int t = 0; t < cfg->excluded_token_count && t < EXCLUDED_TOKENS_MAX; t++)
        if (path_contains_token(path, len, cfg->excluded_tokens[t]))
            return 0;

    const char *pref = cfg->file_path_monitored;
    size_t plen = strlen(pref);
    if (plen == 0)
        return 1;
    while (plen > 1 && pref[plen - 1] == '/')
        plen--;
    if (len < plen || strncmp(path, pref, plen) != 0)
        return 0;
    if (len == plen)
        return 1;
    return path[plen] == '/';
}

void config_defaults(struct config *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->port = 0;
    snprintf(cfg->header, sizeof(cfg->header), "X-REQUEST-ID");
    cfg->backend = BACKEND_AUTO;
    cfg->coverage_mode = COV_NGRAM;
    cfg->theta = DEFAULT_THETA;
    snprintf(cfg->calib_file, sizeof(cfg->calib_file), "/dev/shm/tracelib.calib");
    cfg->raw_trace_dir[0] = '\0';
    cfg->no_arg_hash = 0;
    cfg->no_sql = 0;
    cfg->file_sql_only = 0;
    cfg->file_sql_unfiltered = 0;
    cfg->file_sql_filtered = 0;
    cfg->top_edges = 0;
    cfg->bigram_file_sql_separated = 0;
    cfg->separated_min_hits = 8;
    snprintf(cfg->file_path_monitored, sizeof(cfg->file_path_monitored),
             "%s", DEFAULT_FILE_PATH_MONITORED);
    config_set_excluded(cfg, DEFAULT_EXCLUDED_FILE_PATH);
    cfg->file_sql_pred_args = 1;
    cfg->end_on_status_line = 1;
    cfg->sql_compact = 1;
    cfg->syscall_filter = 0;
    cfg->syscall_filter_file[0] = '\0';
    cfg->syscall_allowlist_count = 0;
    cfg->file_edges = 0;
    for (int i = 0; i < PARAM_COUNT; i++)
        cfg->mask[i] = 1;
    config_finalize_header(cfg);
}

static int parse_backend(const char *s)
{
    if (!strcmp(s, "auto"))   return BACKEND_AUTO;
    if (!strcmp(s, "ptrace")) return BACKEND_PTRACE;
    if (!strcmp(s, "ebpf"))   return BACKEND_EBPF;
    return -1;
}

static int parse_mode(const char *s)
{
    if (!strcmp(s, "ngram"))  return COV_NGRAM;
    if (!strcmp(s, "bigram")) return COV_BIGRAM;
    return -1;
}

void config_from_env(struct config *cfg)
{
    const char *v;
    if ((v = getenv("TRACELIB_PORT")))   cfg->port = (uint16_t)atoi(v);
    if ((v = getenv("TRACELIB_HEADER")))
        snprintf(cfg->header, sizeof(cfg->header), "%s", v);
    if ((v = getenv("TRACELIB_BACKEND"))) {
        int b = parse_backend(v);
        if (b >= 0) cfg->backend = b;
    }
    if ((v = getenv("TRACELIB_COVERAGE_MODE"))) {
        int m = parse_mode(v);
        if (m >= 0) cfg->coverage_mode = m;
    }
    if ((v = getenv("TRACELIB_NGRAM_THETA"))) cfg->theta = clamp_theta(atoi(v));
    if ((v = getenv("TRACELIB_CALIB_FILE")))
        snprintf(cfg->calib_file, sizeof(cfg->calib_file), "%s", v);
    if ((v = getenv("TRACELIB_RAW_TRACE_DIR")))
        snprintf(cfg->raw_trace_dir, sizeof(cfg->raw_trace_dir), "%s", v);
    if ((v = getenv("TRACELIB_NO_ARG_HASH")) && atoi(v))    cfg->no_arg_hash = 1;
    if ((v = getenv("TRACELIB_NO_SQL")) && atoi(v))         cfg->no_sql = 1;
    if ((v = getenv("TRACELIB_FILE_SQL_ONLY")) && atoi(v))  cfg->file_sql_only = 1;
    if ((v = getenv("TRACELIB_FILE_SQL_UNFILTERED")) && atoi(v)) cfg->file_sql_unfiltered = 1;
    if ((v = getenv("TRACELIB_FILE_SQL_FILTERED")) && atoi(v)) {
        cfg->file_sql_filtered = 1;
        cfg->file_sql_only = 1;
    }
    if ((v = getenv("TRACELIB_NO_FILE_SQL_PRED_ARGS")) && atoi(v)) cfg->file_sql_pred_args = 0;
    if ((v = getenv("TRACELIB_END_ON_STATUS_LINE")))
        cfg->end_on_status_line = atoi(v) ? 1 : 0;
    if ((v = getenv("TRACELIB_SQL_COMPACT")))
        cfg->sql_compact = atoi(v) ? 1 : 0;
    if ((v = getenv("TRACELIB_SYSCALL_FILTER")) && atoi(v)) cfg->syscall_filter = 1;
    if ((v = getenv("TRACELIB_SYSCALL_FILTER_FILE")))
        snprintf(cfg->syscall_filter_file, sizeof(cfg->syscall_filter_file), "%s", v);
    if ((v = getenv("TRACELIB_FILE_EDGES")) && atoi(v))     cfg->file_edges = 1;
    if ((v = getenv("TRACELIB_TOP_EDGES"))) {
        int n = atoi(v);
        cfg->top_edges = (n > 0) ? n : 0;
    }
    if ((v = getenv("TRACELIB_BIGRAM_FILE_SQL_SEPARATED")) && atoi(v))
        cfg->bigram_file_sql_separated = 1;
    if ((v = getenv("TRACELIB_SEPARATED_MIN_HITS"))) {
        int n = atoi(v);
        cfg->separated_min_hits = (n > 0) ? n : 0;
    }
    if ((v = getenv("TRACELIB_FILE_PATH_MONITORED")) || (v = getenv("FILE_PATH_MONITORED")))
        snprintf(cfg->file_path_monitored, sizeof(cfg->file_path_monitored), "%s", v);
    if ((v = getenv("TRACELIB_EXCLUDED_FILE_PATH")) || (v = getenv("EXCLUDED_FILE_PATH")))
        config_set_excluded(cfg, v);
}

void config_load_calib(struct config *cfg)
{
    FILE *f = fopen(cfg->calib_file, "r");
    if (!f)
        return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char key[64];
        int val;
        if (sscanf(line, "%63[^=]=%d", key, &val) != 2)
            continue;
        if      (!strcmp(key, "theta"))            cfg->theta = clamp_theta(val);
        else if (!strcmp(key, "mask_sql"))         cfg->mask[PARAM_SQL] = !!val;
        else if (!strcmp(key, "mask_open_path"))   cfg->mask[PARAM_OPEN_PATH] = !!val;
        else if (!strcmp(key, "mask_file_edge"))   cfg->mask[PARAM_FILE_EDGE] = !!val;
        else if (!strcmp(key, "mask_connect_port"))cfg->mask[PARAM_CONNECT_PORT] = !!val;
    }
    fclose(f);
    LOGI("loaded calibration from %s (theta=%d)", cfg->calib_file, cfg->theta);
}

static const char *opt_value(int argc, char **argv, int *i, const char *eq)
{
    if (eq && *eq)
        return eq + 1;
    if (*i + 1 < argc)
        return argv[++(*i)];
    return NULL;
}

int config_from_args(struct config *cfg, int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        char *a = argv[i];
        char *eq = strchr(a, '=');
        size_t namelen = eq ? (size_t)(eq - a) : strlen(a);
        const char *val;

        #define IS(opt) (namelen == strlen(opt) && strncmp(a, opt, namelen) == 0)

        if (IS("-h") || IS("--help")) {
            config_usage(argv[0]);
            return 1;
        } else if (IS("--port")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            cfg->port = (uint16_t)atoi(val);
        } else if (IS("--header")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            snprintf(cfg->header, sizeof(cfg->header), "%s", val);
        } else if (IS("--backend")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            int b = parse_backend(val);
            if (b < 0) { LOGE("bad --backend '%s'", val); return -1; }
            cfg->backend = b;
        } else if (IS("--coverage-mode")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            int m = parse_mode(val);
            if (m < 0) { LOGE("bad --coverage-mode '%s'", val); return -1; }
            cfg->coverage_mode = m;
        } else if (IS("--ngram-theta")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            cfg->theta = clamp_theta(atoi(val));
        } else if (IS("--calib-file")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            snprintf(cfg->calib_file, sizeof(cfg->calib_file), "%s", val);
        } else if (IS("--raw-trace-dir")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            snprintf(cfg->raw_trace_dir, sizeof(cfg->raw_trace_dir), "%s", val);
        } else if (IS("--no-arg-hash")) {
            cfg->no_arg_hash = 1;
        } else if (IS("--no-sql")) {
            cfg->no_sql = 1;
        } else if (IS("--file-sql-only")) {
            cfg->file_sql_only = 1;
        } else if (IS("--file-sql-unfiltered")) {
            cfg->file_sql_unfiltered = 1;
        } else if (IS("--bigram-file-sql-filtered")) {
            cfg->file_sql_filtered = 1;
            cfg->file_sql_only = 1;
        } else if (IS("--no-file-sql-pred-args")) {
            cfg->file_sql_pred_args = 0;
        } else if (IS("--end-on-status-line")) {
            cfg->end_on_status_line = 1;
        } else if (IS("--no-end-on-status-line")) {
            cfg->end_on_status_line = 0;
        } else if (IS("--sql-compact")) {
            cfg->sql_compact = 1;
        } else if (IS("--no-sql-compact")) {
            cfg->sql_compact = 0;
        } else if (IS("--syscall-filter")) {
            cfg->syscall_filter = 1;
        } else if (IS("--syscall-filter-file")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            snprintf(cfg->syscall_filter_file, sizeof(cfg->syscall_filter_file), "%s", val);
        } else if (IS("--file-edges")) {
            cfg->file_edges = 1;
        } else if (IS("--bigram-file-sql-separated")) {
            cfg->bigram_file_sql_separated = 1;
        } else if (IS("--file-path-monitored")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            snprintf(cfg->file_path_monitored, sizeof(cfg->file_path_monitored), "%s", val);
        } else if (IS("--excluded-file-path")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            config_set_excluded(cfg, val);
        } else if (IS("--separated-min-hits")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            {
                int n = atoi(val);
                cfg->separated_min_hits = (n > 0) ? n : 0;
            }
        } else if (IS("--top-edges")) {
            if (!(val = opt_value(argc, argv, &i, eq))) goto need_arg;
            {
                int n = atoi(val);
                cfg->top_edges = (n > 0) ? n : 0;
            }
        } else {
            LOGE("unknown argument '%s' (try --help)", a);
            return -1;
        }
        #undef IS
        continue;
    need_arg:
        LOGE("option '%.*s' needs a value", (int)namelen, a);
        return -1;
    }
    return 0;
}

void config_banner(const struct config *cfg, const char *active_backend)
{
    char separated_text[320];
    if (config_bigram_separated(cfg))
        snprintf(separated_text, sizeof(separated_text),
                 "on (upper=structural, prune <%d; lower=file/SQL, kept)",
                 cfg->separated_min_hits);
    else
        snprintf(separated_text, sizeof(separated_text), "off (single 65536-cell map)");
    char top_edges_text[64];
    if (config_top_edges(cfg))
        snprintf(top_edges_text, sizeof(top_edges_text),
                 "on (keep %d hottest positions)", cfg->top_edges);
    else
        snprintf(top_edges_text, sizeof(top_edges_text), "off (full map)");

    fprintf(stderr,
        "================ TraceLib-NG ================\n"
        " backend        : %s (requested: %s)\n"
        " port           : %u\n"
        " header         : %s\n"
        " coverage mode  : %s\n"
        " theta (window) : %d   (uses theta, 2*theta=%d, full)\n"
        " arg_hash       : %s   sql: %s\n"
        " sql encoding   : %s\n"
        " file/sql only  : %s\n"
        " edge arg keying: %s\n"
        " syscall filter : %s\n"
        " file edges     : %s\n"
        " path policy    : under %s, excluding *%s*\n"
        " separated map  : %s\n"
        " top edges      : %s\n"
        " raw syscall log: %s\n"
        " request end    : %s\n"
        " param mask     : sql=%d open_path=%d file_edge=%d connect_port=%d\n"
        " map size       : %u bytes  (/dev/shm/<id>)\n"
        "=============================================\n",
        active_backend,
        cfg->backend == BACKEND_AUTO ? "auto" : cfg->backend == BACKEND_PTRACE ? "ptrace" : "ebpf",
        cfg->port, cfg->header,
        cfg->coverage_mode == COV_NGRAM ? "ngram (SPC)" : "bigram (legacy)",
        cfg->theta, 2 * cfg->theta,
        cfg->no_arg_hash ? "off" : "on", cfg->no_sql ? "off" : "on",
        config_sql_compact(cfg)
            ? (strcmp(active_backend, "ebpf") == 0 &&
               (cfg->coverage_mode != COV_BIGRAM || config_bigram_separated(cfg))
                   ? "compact <<COMMANDS>><<TABLES>> (NOT this mode: in-kernel fold)"
                   : "compact <<COMMANDS>><<TABLES>>")
            : "value-reduced statement text / verb:table:cols skeleton",
        cfg->file_sql_filtered ? "on (strict projection + predecessor args)" :
            (cfg->file_sql_only ? "on (strict event projection)" :
            (cfg->file_sql_unfiltered ? "on (arguments only, no event projection)" : "off")),
        config_file_sql_pred_args(cfg) ? "predecessor + current" : "current only",
        cfg->syscall_filter_file[0] ? cfg->syscall_filter_file :
            (cfg->syscall_filter ? "legacy built-in" : "off"),
        cfg->file_edges ? "on" : "off",
        cfg->file_path_monitored[0] ? cfg->file_path_monitored : "<all>",
        cfg->excluded_file_path[0] ? cfg->excluded_file_path : "<none>",
        separated_text,
        top_edges_text,
        cfg->raw_trace_dir[0] ? cfg->raw_trace_dir : "off",
        config_end_on_status_line(cfg)
            ? "response status line, else idle timer"
            : "idle timer only",
        cfg->mask[PARAM_SQL], cfg->mask[PARAM_OPEN_PATH],
        cfg->mask[PARAM_FILE_EDGE], cfg->mask[PARAM_CONNECT_PORT],
        MAP_SIZE);
}

void config_usage(const char *argv0)
{
    fprintf(stderr,
        "Usage: %s --port <P> [options]\n"
        "  --port <P>                 TCP port the target listens on (required)\n"
        "  --header <H>               request-id header (default X-REQUEST-ID)\n"
        "  --backend <auto|ptrace|ebpf>  collection backend (default auto)\n"
        "  --coverage-mode <ngram|bigram>  default ngram (SPC)\n"
        "  --ngram-theta <N>          window length theta in [2,%d] (default %d)\n"
        "  --calib-file <path>        calibration file (default /dev/shm/tracelib.calib)\n"
        "  --raw-trace-dir <path>     write per-request raw syscall JSONL (off by default)\n"
        "  --no-arg-hash              drop path/port/exec/sql arg hashing\n"
        "  --no-sql                   drop SQL-skeleton hashing\n"
        "  --file-sql-only            record only path/SQL-bearing syscalls\n"
        "  --bigram-file-sql-filtered record ONLY syscalls carrying a monitored file\n"
        "                             path or a SQL query; everything else is skipped\n"
        "                             and never becomes a predecessor. Edge index is\n"
        "                             ((prev^prev_arg)<<8) ^ (curr^curr_arg)\n"
        "  --file-sql-unfiltered      path/SQL argument semantics for every recorded\n"
        "                             syscall (no event projection; bigram only)\n"
        "  --no-file-sql-pred-args    with --file-sql-unfiltered, key each edge on the\n"
        "                             current syscall's argument hash only (the old\n"
        "                             behaviour); by default the predecessor's hash is\n"
        "                             folded in too\n"
        "  --end-on-status-line       finalize the request as soon as the response\n"
        "                             status line is written (DEFAULT; publishes the\n"
        "                             bitmap without waiting for the idle timer)\n"
        "  --no-end-on-status-line    keep the request open until the traced processes\n"
        "                             fall silent; slower, but keeps the syscalls a\n"
        "                             server emits after flushing its headers\n"
        "  --sql-compact              encode a SQL buffer as <<COMMANDS>><<TABLES>>,\n"
        "                             dropping every literal by construction (default)\n"
        "  --no-sql-compact           encode it as the value-reduced statement text\n"
        "                             instead (the pre-2026-08-31 behaviour)\n"
        "  --syscall-filter           record only curated interesting syscalls\n"
        "  --syscall-filter-file <P>  strict runtime syscall allowlist\n"
        "  --file-edges               enable file-open transition channel\n"
        "  --bigram-file-sql-separated\n"
        "                             split the map: argument-free syscall transitions\n"
        "                             in the upper half, file-path/reduced-SQL edges in\n"
        "                             the lower half (bigram only)\n"
        "  --file-path-monitored <P>  ALL modes: only file paths under P contribute an\n"
        "                             argument hash (default " DEFAULT_FILE_PATH_MONITORED ";\n"
        "                             empty string monitors every path)\n"
        "  --excluded-file-path <S>   ALL modes: a file path containing substring S never\n"
        "                             contributes an argument hash, even under P\n"
        "                             (default: empty, i.e. no exclusion)\n"
        "  --separated-min-hits <K>   with --bigram-file-sql-separated, zero upper-half\n"
        "                             cells hit fewer than K times (default 8); the\n"
        "                             lower half is never pruned\n"
        "  --top-edges <N>            publish only the N hottest map positions per\n"
        "                             request, dropping the incidental single-hit\n"
        "                             tail (0 = off, the default)\n"
        "  -h, --help                 this help\n"
        "Environment overrides: TRACELIB_PORT/HEADER/BACKEND/COVERAGE_MODE/\n"
        "  NGRAM_THETA/CALIB_FILE/RAW_TRACE_DIR/NO_ARG_HASH/NO_SQL/FILE_SQL_ONLY/\n"
        "  FILE_SQL_UNFILTERED/SYSCALL_FILTER/SYSCALL_FILTER_FILE/FILE_EDGES\n",
        argv0, THETA_MAX, DEFAULT_THETA);
}
