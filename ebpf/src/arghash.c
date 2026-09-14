#include "arghash.h"
#include "procmem.h"
#include "sql_detect.h"
#include "bitmap.h"

#include <sys/syscall.h>
#include <string.h>
#include <ctype.h>

#ifndef __NR_openat2
#define __NR_openat2 437
#endif

int arghash_is_open_family(long sc)
{
    return sc == __NR_open || sc == __NR_openat || sc == __NR_openat2;
}

static size_t read_path_arg(pid_t pid, long sc, const unsigned long args[6], char *buf, size_t cap)
{
    uintptr_t addr = 0;
    if (sc == __NR_open || sc == __NR_execve)
        addr = (uintptr_t)args[0];
    else if (sc == __NR_openat || sc == __NR_openat2)
        addr = (uintptr_t)args[1];
    else
        return 0;
    return pm_read_cstr(pid, addr, buf, cap);
}

static int is_all_digit(const char *s, int n)
{
    if (n == 0) return 0;
    for (int i = 0; i < n; i++)
        if (!isdigit((unsigned char)s[i])) return 0;
    return 1;
}

static int is_long_hex(const char *s, int n)
{
    if (n < 8) return 0;
    for (int i = 0; i < n; i++)
        if (!isxdigit((unsigned char)s[i])) return 0;
    return 1;
}

static int run_is_generated(const char *s, int n)
{
    if (n >= 8) {
        int hex = 1;
        for (int i = 0; i < n; i++)
            if (!isxdigit((unsigned char)s[i])) { hex = 0; break; }
        if (hex) return 1;
    }
    if (n >= 16) {
        int upper = 0, lower = 0, digit = 0;
        for (int i = 0; i < n; i++) {
            unsigned char c = (unsigned char)s[i];
            if (isdigit(c)) digit = 1;
            else if (isupper(c)) upper = 1;
            else if (islower(c)) lower = 1;
        }
        if (upper && lower && digit) return 1;
    }
    return 0;
}

static int is_alnum_b(char c) { return isalnum((unsigned char)c) != 0; }

size_t arghash_canon_path(const char *in, size_t inlen, char *out, size_t cap)
{
    size_t o = 0;
    size_t i = 0;
    while (i < inlen && o + 1 < cap) {
        if (in[i] == '/') {
            out[o++] = '/';
            i++;
            continue;
        }

        size_t start = i;
        while (i < inlen && in[i] != '/')
            i++;
        int clen = (int)(i - start);

        if (is_all_digit(in + start, clen)) {
            if (o + 1 < cap) out[o++] = '#';
            continue;
        }
        for (int k = 0; k < clen && o + 1 < cap; ) {
            if (!is_alnum_b(in[start + k])) {
                out[o++] = in[start + k];
                k++;
                continue;
            }
            int rl = 0;
            while (k + rl < clen && is_alnum_b(in[start + k + rl]))
                rl++;
            if (run_is_generated(in + start + k, rl)) {
                if (o + 1 < cap) out[o++] = '#';
            } else {
                for (int m = 0; m < rl && o + 1 < cap; m++)
                    out[o++] = in[start + k + m];
            }
            k += rl;
        }
    }
    out[o] = '\0';
    return o;
}

uint16_t file_edge_loc(pid_t pid, long sc, const unsigned long args[6])
{
    char path[FILE_SQL_DATA_MAX];
    size_t n = read_path_arg(pid, sc, args, path, sizeof(path));
    if (n == 0)
        return 0;
    char canon[FILE_SQL_DATA_MAX];
    size_t cn = arghash_canon_path(path, n, canon, sizeof(canon));
    return djb2_16(canon, cn);
}

static uint8_t djb2_8_canon(const char *path, size_t n)
{
    char canon[FILE_SQL_DATA_MAX];
    size_t cn = arghash_canon_path(path, n, canon, sizeof(canon));
    return djb2_8(canon, cn);
}

int arghash_path_hash(const struct config *cfg, const char *path, size_t n, uint8_t *out)
{
    if (!n || !config_path_is_monitored(cfg, path, n))
        return 0;
    *out = djb2_8_canon(path, n);
    return 1;
}

uint8_t compute_arg_hash_semantic(pid_t pid, long sc, const unsigned long args[6],
                                  const struct config *cfg, int *kind)
{
    if (kind)
        *kind = ARG_SEMANTIC_NONE;
    if (cfg->no_arg_hash)
        return 0;

    switch (sc) {
    case __NR_open:
    case __NR_openat:
    case __NR_openat2:
    case __NR_execve: {
        if (!cfg->mask[PARAM_OPEN_PATH])
            return 0;
        char path[FILE_SQL_DATA_MAX];
        size_t n = read_path_arg(pid, sc, args, path, sizeof(path));
        if (!n)
            return 0;
        if (!config_path_is_monitored(cfg, path, n))
            return 0;
        if (kind)
            *kind = ARG_SEMANTIC_FILE_PATH;
        return djb2_8_canon(path, n);
    }
    case __NR_connect: {
        if (config_file_sql_args(cfg))
            return 0;
        if (!cfg->mask[PARAM_CONNECT_PORT])
            return 0;
        uint16_t port = 0;
        if (pm_read_sockaddr_port(pid, (uintptr_t)args[1], &port) != 0)
            return 0;
        return (uint8_t)(port & 0xFF);
    }
    case __NR_write:
    case __NR_sendto: {
        if (cfg->no_sql || !cfg->mask[PARAM_SQL])
            return 0;
        size_t len = (size_t)args[2];
        if (len > FILE_SQL_DATA_MAX) len = FILE_SQL_DATA_MAX;
        char buf[FILE_SQL_DATA_MAX];
        ssize_t got = pm_read(pid, (uintptr_t)args[1], buf, len);
        if (got <= 0)
            return 0;

        if (config_sql_compact(cfg)) {
            char canon[FILE_SQL_DATA_MAX + 1];
            size_t n = sql_compact_query(buf, (size_t)got, canon, sizeof(canon));
            if (!n)
                return 0;
            if (kind && config_file_sql_args(cfg))
                *kind = ARG_SEMANTIC_SQL;
            return djb2_8(canon, n);
        }
        if (config_file_sql_args(cfg)) {
            char canon[FILE_SQL_DATA_MAX + 1];
            size_t n = sql_query_reduced(buf, (size_t)got, canon, sizeof(canon));
            if (!n)
                return 0;
            if (kind)
                *kind = ARG_SEMANTIC_SQL;
            return djb2_8(canon, n);
        }
        return sql_skeleton_hash(buf, (size_t)got);
    }
    case __NR_writev: {
        if (cfg->no_sql || !cfg->mask[PARAM_SQL])
            return 0;
        uintptr_t base; size_t len;
        if (pm_read_iovec0(pid, (uintptr_t)args[1], &base, &len) != 0)
            return 0;
        if (len > FILE_SQL_DATA_MAX) len = FILE_SQL_DATA_MAX;
        char buf[FILE_SQL_DATA_MAX];
        ssize_t got = pm_read(pid, base, buf, len);
        if (got <= 0)
            return 0;

        if (config_sql_compact(cfg)) {
            char canon[FILE_SQL_DATA_MAX + 1];
            size_t n = sql_compact_query(buf, (size_t)got, canon, sizeof(canon));
            if (!n)
                return 0;
            if (kind && config_file_sql_args(cfg))
                *kind = ARG_SEMANTIC_SQL;
            return djb2_8(canon, n);
        }
        if (config_file_sql_args(cfg)) {
            char canon[FILE_SQL_DATA_MAX + 1];
            size_t n = sql_query_reduced(buf, (size_t)got, canon, sizeof(canon));
            if (!n)
                return 0;
            if (kind)
                *kind = ARG_SEMANTIC_SQL;
            return djb2_8(canon, n);
        }
        return sql_skeleton_hash(buf, (size_t)got);
    }
    default:
        return 0;
    }
}

uint8_t compute_arg_hash(pid_t pid, long sc, const unsigned long args[6],
                         const struct config *cfg)
{
    return compute_arg_hash_semantic(pid, sc, args, cfg, NULL);
}
