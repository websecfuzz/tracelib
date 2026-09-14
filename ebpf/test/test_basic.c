#include "config.h"
#include "arghash.h"
#include "bitmap.h"
#include "ngram.h"
#include "procmem.h"
#include "sql_detect.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define CHECK(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); \
        return -1; \
    } \
} while (0)

static int write_temp_file(const char *contents, char path[64])
{
    snprintf(path, 64, "/tmp/tracelib-filter-test-XXXXXX");
    int fd = mkstemp(path);
    if (fd < 0)
        return -1;
    size_t len = strlen(contents);
    ssize_t written = write(fd, contents, len);
    int saved = errno;
    close(fd);
    errno = saved;
    return written == (ssize_t)len ? 0 : -1;
}

static int test_shipped_policy(void)
{
    struct config cfg;
    config_defaults(&cfg);
    snprintf(cfg.syscall_filter_file, sizeof(cfg.syscall_filter_file),
             "config/web_related_syscalls.txt");
    CHECK(config_load_syscall_filter(&cfg) == 0);
    CHECK(cfg.syscall_allowlist_count >= 50);
    CHECK(config_syscall_allowed(&cfg, SYS_read));
    CHECK(config_syscall_allowed(&cfg, SYS_write));
#ifdef SYS_openat2
    CHECK(config_syscall_allowed(&cfg, SYS_openat2));
#endif
#ifdef SYS_futex
    CHECK(!config_syscall_allowed(&cfg, SYS_futex));
#endif
#ifdef SYS_clock_gettime
    CHECK(!config_syscall_allowed(&cfg, SYS_clock_gettime));
#endif
    return 0;
}

static int test_parser_and_deduplication(void)
{
    char path[64];
    CHECK(write_temp_file(
        "# names, prefixes, a numeric id, and duplicates\n"
        " read # inline comment\n"
        "SYS_write\n"
        "__NR_openat\n"
        "0\n",
        path) == 0);

    struct config cfg;
    config_defaults(&cfg);
    snprintf(cfg.syscall_filter_file, sizeof(cfg.syscall_filter_file), "%s", path);
    int rc = config_load_syscall_filter(&cfg);
    unlink(path);
    CHECK(rc == 0);
    CHECK(cfg.syscall_allowlist_count == 3);
    CHECK(config_syscall_allowed(&cfg, SYS_read));
    CHECK(config_syscall_allowed(&cfg, SYS_write));
    CHECK(config_syscall_allowed(&cfg, SYS_openat));
#ifdef SYS_futex
    CHECK(!config_syscall_allowed(&cfg, SYS_futex));
#endif
    return 0;
}

static int test_invalid_policies_fail_closed(void)
{
    const char *cases[] = { "# empty\n\n", "definitely_not_a_syscall\n" };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        char path[64];
        CHECK(write_temp_file(cases[i], path) == 0);
        struct config cfg;
        config_defaults(&cfg);
        snprintf(cfg.syscall_filter_file, sizeof(cfg.syscall_filter_file), "%s", path);
        int rc = config_load_syscall_filter(&cfg);
        unlink(path);
        CHECK(rc == -1);
    }
    return 0;
}

static int test_strict_ngram_projection(void)
{
    char path[64];
    CHECK(write_temp_file("read\nwrite\nopenat\n", path) == 0);
    struct config cfg;
    config_defaults(&cfg);
    snprintf(cfg.syscall_filter_file, sizeof(cfg.syscall_filter_file), "%s", path);
    int rc = config_load_syscall_filter(&cfg);
    unlink(path);
    CHECK(rc == 0);

    uint8_t projected_map[MAP_SIZE] = {0};
    uint8_t expected_map[MAP_SIZE] = {0};
    struct tracee projected = { .full_hash = FNV_OFFSET };
    struct tracee expected = { .full_hash = FNV_OFFSET };
    const long observed[] = {
        SYS_read,
#ifdef SYS_futex
        SYS_futex,
#endif
        SYS_write,
#ifdef SYS_clock_gettime
        SYS_clock_gettime,
#endif
        SYS_openat,
    };
    const long retained[] = { SYS_read, SYS_write, SYS_openat };

    for (size_t i = 0; i < sizeof(observed) / sizeof(observed[0]); i++) {
        if (config_syscall_allowed(&cfg, observed[i]))
            ngram_record(projected_map, &projected, (uint32_t)observed[i], 0, 2);
    }
    for (size_t i = 0; i < sizeof(retained) / sizeof(retained[0]); i++)
        ngram_record(expected_map, &expected, (uint32_t)retained[i], 0, 2);
    ngram_fold_full_one(projected_map, &projected);
    ngram_fold_full_one(expected_map, &expected);

    CHECK(projected.ring_count == 3);
    CHECK(projected.full_hash == expected.full_hash);
    CHECK(memcmp(projected_map, expected_map, MAP_SIZE) == 0);
    return 0;
}

static int test_strict_bigram_projection(void)
{
    char path[64];
    CHECK(write_temp_file("read\nwrite\nopenat\n", path) == 0);
    struct config cfg;
    config_defaults(&cfg);
    cfg.coverage_mode = COV_BIGRAM;
    snprintf(cfg.syscall_filter_file, sizeof(cfg.syscall_filter_file), "%s", path);
    int rc = config_load_syscall_filter(&cfg);
    unlink(path);
    CHECK(rc == 0);

    uint8_t projected_map[MAP_SIZE] = {0};
    uint8_t expected_map[MAP_SIZE] = {0};
    uint32_t projected_prev = 0;
    uint32_t expected_prev = 0;
    const long observed[] = {
        SYS_read,
#ifdef SYS_futex
        SYS_futex,
#endif
        SYS_write,
#ifdef SYS_clock_gettime
        SYS_clock_gettime,
#endif
        SYS_openat,
    };
    const long retained[] = { SYS_read, SYS_write, SYS_openat };

    for (size_t i = 0; i < sizeof(observed) / sizeof(observed[0]); i++) {
        if (!config_syscall_allowed(&cfg, observed[i]))
            continue;
        bitmap_record_bigram(
            projected_map, projected_prev, (uint32_t)observed[i], 0
        );
        projected_prev = (uint32_t)observed[i];
    }
    for (size_t i = 0; i < sizeof(retained) / sizeof(retained[0]); i++) {
        bitmap_record_bigram(expected_map, expected_prev, (uint32_t)retained[i], 0);
        expected_prev = (uint32_t)retained[i];
    }

    CHECK(projected_prev == expected_prev);
    CHECK(memcmp(projected_map, expected_map, MAP_SIZE) == 0);
    return 0;
}

static int test_file_sql_mode_config(void)
{
    struct config cfg;
    config_defaults(&cfg);
    CHECK(cfg.file_sql_only == 0);
    char *argv[] = { (char *)"tracelib", (char *)"--file-sql-only" };
    CHECK(config_from_args(&cfg, 2, argv) == 0);
    CHECK(cfg.file_sql_only == 1);
    return 0;
}

static int test_sql_query_reduction(void)
{
    const char *q1 =
        "SELECT display_name FROM Users WHERE id = 7 AND status LIKE 'active'";
    const char *q2 =
        "SELECT display_name FROM Users WHERE id = 999 AND status LIKE 'disabled'";
    char c1[256], c2[256];
    CHECK(sql_query_reduced(q1, strlen(q1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(q2, strlen(q2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1,
        "SELECT display_name FROM Users WHERE id = AND status LIKE ") == 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(sql_query_reduced_hash(q1, strlen(q1)) ==
          sql_query_reduced_hash(q2, strlen(q2)));

    const char embedded[] =
        "\x27\0\x02" "UPDATE Accounts SET balance=100 WHERE owner_id=4\0trailer";
    CHECK(sql_query_reduced(embedded, sizeof(embedded) - 1,
                            c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "UPDATE Accounts SET balance= WHERE owner_id=") == 0);

    const char operators[] =
        "SELECT * FROM t WHERE score BETWEEN -1 AND +2 OR state IN (1, 2, :state) "
        "AND deleted IS NOT NULL AND tag = $1";
    CHECK(sql_query_reduced(operators, strlen(operators), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1,
        "SELECT * FROM t WHERE score BETWEEN AND OR state IN (...) "
        "AND deleted IS NOT AND tag = ") == 0);

    CHECK(sql_query_reduced("<select name='mode'>", 20,
                            c1, sizeof(c1)) == 0);
    CHECK(sql_query_reduced("ordinary response body", 22,
                            c1, sizeof(c1)) == 0);
    return 0;
}

static int test_sql_values_reduction(void)
{
    char c1[256], c2[256];

    const char *i1 =
        "INSERT INTO `wp_options` (`option_name`, `option_value`, `autoload`) "
        "VALUES ('_transient_doing_cron', '1787594275.020225048065185546875', 'off')";
    const char *i2 =
        "INSERT INTO `wp_options` (`option_name`, `option_value`, `autoload`) "
        "VALUES ('_transient_doing_cron', '1787594999.111111111111111111111', 'off')";
    CHECK(sql_query_reduced(i1, strlen(i1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(i2, strlen(i2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, "INSERT INTO `wp_options` (`option_name`, `option_value`, "
                     "`autoload`) VALUES (...)") == 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(sql_query_reduced_hash(i1, strlen(i1)) ==
          sql_query_reduced_hash(i2, strlen(i2)));

    const char *m1 = "INSERT INTO t (a, b) VALUES ('x', 1), ('y', 2)";
    const char *m2 = "INSERT INTO t (a, b) VALUES ('p', 8), ('q', 9)";
    CHECK(sql_query_reduced(m1, strlen(m1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(m2, strlen(m2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, "INSERT INTO t (a, b) VALUES (...), (...)") == 0);
    CHECK(strcmp(c1, c2) == 0);

    const char *r1 = "REPLACE INTO cache (k, v) VALUES ('key', 'blob-991')";
    const char *r2 = "REPLACE INTO cache (k, v) VALUES ('key', 'blob-773')";
    CHECK(sql_query_reduced_hash(r1, strlen(r1)) ==
          sql_query_reduced_hash(r2, strlen(r2)));

    const char *d1 = "INSERT INTO t (a,b) VALUES (1,2) ON DUPLICATE KEY UPDATE b = 3";
    const char *d2 = "INSERT INTO t (a,b) VALUES (4,5) ON DUPLICATE KEY UPDATE b = 6";
    CHECK(sql_query_reduced(d1, strlen(d1), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1,
        "INSERT INTO t (a,b) VALUES (...) ON DUPLICATE KEY UPDATE b = ") == 0);
    CHECK(sql_query_reduced_hash(d1, strlen(d1)) ==
          sql_query_reduced_hash(d2, strlen(d2)));

    const char *s1 = "INSERT INTO t (a) SELECT b FROM u WHERE c = 5";
    CHECK(sql_query_reduced(s1, strlen(s1), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "INSERT INTO t (a) SELECT b FROM u WHERE c = ") == 0);

    const char *base    = "INSERT INTO t (a, b) VALUES ('x', 1)";
    const char *other_t = "INSERT INTO u (a, b) VALUES ('x', 1)";
    const char *other_c = "INSERT INTO t (a, c) VALUES ('x', 1)";
    const char *wider   = "INSERT INTO t (a, b, c) VALUES ('x', 1, 2)";
    const char *two_row = "INSERT INTO t (a, b) VALUES ('x', 1), ('y', 2)";
    CHECK(sql_query_reduced(base, strlen(base), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(other_t, strlen(other_t), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) != 0);
    CHECK(sql_query_reduced(other_c, strlen(other_c), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) != 0);
    CHECK(sql_query_reduced(wider, strlen(wider), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) != 0);
    CHECK(sql_query_reduced(two_row, strlen(two_row), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) != 0);

    const char *no_cols = "INSERT INTO t VALUES (1, 'a')";
    CHECK(sql_query_reduced(no_cols, strlen(no_cols), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "INSERT INTO t VALUES (...)") == 0);
    const char *unterminated = "INSERT INTO t (a) VALUES ('abc";
    CHECK(sql_query_reduced(unterminated, strlen(unterminated), c1, sizeof(c1)) > 0);
    const char *cut = "INSERT INTO t (a, b) VALUES ('abc', 1";
    CHECK(sql_query_reduced(cut, strlen(cut), c1, sizeof(c1)) > 0);
    const char *empty_values = "INSERT INTO t (a) VALUES ()";
    CHECK(sql_query_reduced(empty_values, strlen(empty_values), c1, sizeof(c1)) > 0);
    return 0;
}

static int test_sql_limit_and_list_reduction(void)
{
    char c1[256], c2[256], c3[256];

    const char *p1 = "SELECT id FROM posts ORDER BY id LIMIT 20 OFFSET 40";
    const char *p2 = "SELECT id FROM posts ORDER BY id LIMIT 20 OFFSET 60";
    CHECK(sql_query_reduced(p1, strlen(p1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(p2, strlen(p2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, "SELECT id FROM posts ") == 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(sql_query_reduced_hash(p1, strlen(p1)) ==
          sql_query_reduced_hash(p2, strlen(p2)));

    const char *s1 = "SELECT a FROM t WHERE id = 7 ORDER BY lastName, firstName";
    const char *s2 = "SELECT a FROM t WHERE id = 9 ORDER BY email DESC";
    CHECK(sql_query_reduced(s1, strlen(s1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(s2, strlen(s2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, "SELECT a FROM t WHERE id = ") == 0);
    CHECK(strcmp(c1, c2) == 0);

    const char *m1 = "SELECT a FROM t LIMIT 40, 20";
    const char *m2 = "SELECT a FROM t LIMIT 60, 20";
    const char *ph = "SELECT a FROM t LIMIT ?";
    const char *all = "SELECT a FROM t LIMIT ALL";
    CHECK(sql_query_reduced(m1, strlen(m1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(m2, strlen(m2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, "SELECT a FROM t ") == 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(sql_query_reduced(ph, strlen(ph), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(sql_query_reduced(all, strlen(all), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) == 0);

    const char *lk = "SELECT a FROM t WHERE id = 7 FOR UPDATE";
    CHECK(sql_query_reduced(lk, strlen(lk), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "SELECT a FROM t WHERE id = ") == 0);

    const char *agg = "SELECT group_concat(rating ORDER BY ratingId) FROM r WHERE pid = 7 ORDER BY pid";
    CHECK(sql_query_reduced(agg, strlen(agg), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "SELECT group_concat(rating ORDER BY ratingId) FROM r WHERE pid = ") == 0);

    const char *rl1 = "SELECT * FROM ActionLog WHERE action rlike '(alert)'";
    const char *rl2 = "SELECT * FROM ActionLog WHERE action rlike '(xss|inject)'";
    CHECK(sql_query_reduced(rl1, strlen(rl1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(rl2, strlen(rl2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, "SELECT * FROM ActionLog WHERE action rlike ") == 0);
    CHECK(strcmp(c1, c2) == 0);

    const char *re1 = "SELECT a FROM t WHERE b regexp 'x'";
    const char *re2 = "SELECT a FROM t WHERE b regexp 'yy'";
    const char *il1 = "SELECT a FROM t WHERE b ilike 'x'";
    const char *il2 = "SELECT a FROM t WHERE b ilike 'yy'";
    CHECK(sql_query_reduced(re1, strlen(re1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(re2, strlen(re2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(sql_query_reduced(il1, strlen(il1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(il2, strlen(il2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) == 0);

    const char *ft1 = "SELECT * FROM p WHERE match(name,description) against ('alert' in boolean mode)";
    const char *ft2 = "SELECT * FROM p WHERE match(name,description) against ('xss' in boolean mode)";
    const char *ft3 = "SELECT * FROM p WHERE match(sku) against ('alert' in boolean mode)";
    CHECK(sql_query_reduced(ft1, strlen(ft1), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(ft2, strlen(ft2), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(sql_query_reduced(ft3, strlen(ft3), c3, sizeof(c3)) > 0);
    CHECK(strcmp(c1, c3) != 0);

    const char *named = "SELECT a FROM t WHERE order = 7 AND b = 3";
    CHECK(sql_query_reduced(named, strlen(named), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "SELECT a FROM t WHERE order = AND b = ") == 0);

    const char *l3 = "SELECT a FROM t WHERE id IN (1, 2, 3)";
    const char *l5 = "SELECT a FROM t WHERE id IN (11, 12, 13, 14, 15)";
    const char *l1 = "SELECT a FROM t WHERE id IN ('x')";
    CHECK(sql_query_reduced(l3, strlen(l3), c1, sizeof(c1)) > 0);
    CHECK(sql_query_reduced(l5, strlen(l5), c2, sizeof(c2)) > 0);
    CHECK(sql_query_reduced(l1, strlen(l1), c3, sizeof(c3)) > 0);
    CHECK(strcmp(c1, "SELECT a FROM t WHERE id IN (...)") == 0);
    CHECK(strcmp(c1, c2) == 0);
    CHECK(strcmp(c1, c3) == 0);
    CHECK(sql_query_reduced_hash(l3, strlen(l3)) ==
          sql_query_reduced_hash(l5, strlen(l5)));

    const char *other_col = "SELECT a FROM t WHERE uid IN (1, 2, 3)";
    CHECK(sql_query_reduced(other_col, strlen(other_col), c2, sizeof(c2)) > 0);
    CHECK(strcmp(c1, c2) != 0);

    const char *pred = "SELECT a FROM t WHERE (x = 1 AND y = 2)";
    CHECK(sql_query_reduced(pred, strlen(pred), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "SELECT a FROM t WHERE (x = AND y = )") == 0);

    const char *cnt = "SELECT COUNT() FROM t WHERE id = 3";
    CHECK(sql_query_reduced(cnt, strlen(cnt), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "SELECT COUNT() FROM t WHERE id = ") == 0);

    const char *nested = "SELECT a FROM t WHERE id IN ((1), (2))";
    CHECK(sql_query_reduced(nested, strlen(nested), c1, sizeof(c1)) > 0);
    CHECK(strcmp(c1, "SELECT a FROM t WHERE id IN ((...), (...))") == 0);

    const char *cut = "SELECT a FROM t WHERE id IN (1, 2";
    CHECK(sql_query_reduced(cut, strlen(cut), c1, sizeof(c1)) > 0);
    return 0;
}

static int test_file_sql_argument_projection(void)
{
    char probe = 'x', copied = 0;
    if (pm_read(getpid(), (uintptr_t)&probe, &copied, 1) != 1) {
        puts("SKIP: process_vm_readv is blocked; argument-memory projection test unavailable");
        return 0;
    }

    struct config cfg;
    config_defaults(&cfg);
    cfg.coverage_mode = COV_BIGRAM;
    cfg.file_sql_only = 1;

    const char path[] = "/var/www/app/config.json";
    unsigned long path_args[6] = { (unsigned long)(uintptr_t)path, 0, 0, 0, 0, 0 };
    int kind = ARG_SEMANTIC_NONE;
    uint8_t path_hash = compute_arg_hash_semantic(
        getpid(), SYS_open, path_args, &cfg, &kind
    );
    CHECK(kind == ARG_SEMANTIC_FILE_PATH);
    CHECK(path_hash == djb2_8(path, strlen(path)));

    const char sql1[] = "SELECT a FROM users WHERE id=1";
    const char sql2[] = "SELECT a FROM users WHERE id=999";
    unsigned long sql_args[6] = {
        1, (unsigned long)(uintptr_t)sql1, sizeof(sql1) - 1, 0, 0, 0
    };
    uint8_t sql_hash1 = compute_arg_hash_semantic(
        getpid(), SYS_write, sql_args, &cfg, &kind
    );
    CHECK(kind == ARG_SEMANTIC_SQL);
    sql_args[1] = (unsigned long)(uintptr_t)sql2;
    sql_args[2] = sizeof(sql2) - 1;
    uint8_t sql_hash2 = compute_arg_hash_semantic(
        getpid(), SYS_write, sql_args, &cfg, &kind
    );
    CHECK(kind == ARG_SEMANTIC_SQL);
    CHECK(sql_hash1 == sql_hash2);

    const char plain[] = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    unsigned long plain_args[6] = {
        1, (unsigned long)(uintptr_t)plain, sizeof(plain) - 1, 0, 0, 0
    };
    CHECK(compute_arg_hash_semantic(getpid(), SYS_write, plain_args,
                                    &cfg, &kind) == 0);
    CHECK(kind == ARG_SEMANTIC_NONE);

    unsigned long scalar_args[6] = {0};
    CHECK(compute_arg_hash_semantic(getpid(), SYS_read, scalar_args,
                                    &cfg, &kind) == 0);
    CHECK(kind == ARG_SEMANTIC_NONE);

    uint8_t projected[MAP_SIZE] = {0};
    uint8_t expected[MAP_SIZE] = {0};
    uint32_t prev = 0;
    bitmap_record_bigram(projected, prev, SYS_open, path_hash);
    prev = SYS_open;
    bitmap_record_bigram(projected, prev, SYS_write, sql_hash1);
    bitmap_record_bigram(expected, 0, SYS_open, path_hash);
    bitmap_record_bigram(expected, SYS_open, SYS_write, sql_hash1);
    CHECK(memcmp(projected, expected, MAP_SIZE) == 0);
    CHECK(bitmap_count_nonzero(projected) == 2);
    return 0;
}

static int test_file_sql_unfiltered_arguments(void)
{
    struct config cfg;
    config_defaults(&cfg);
    CHECK(cfg.file_sql_unfiltered == 0);
    char *argv[] = { (char *)"tracelib", (char *)"--file-sql-unfiltered" };
    CHECK(config_from_args(&cfg, 2, argv) == 0);
    CHECK(cfg.file_sql_unfiltered == 1);
    CHECK(cfg.file_sql_only == 0);
    CHECK(config_file_sql_args(&cfg) == 1);

    char probe = 'x', copied = 0;
    if (pm_read(getpid(), (uintptr_t)&probe, &copied, 1) != 1) {
        puts("SKIP: process_vm_readv is blocked; unfiltered argument test unavailable");
        return 0;
    }
    cfg.coverage_mode = COV_BIGRAM;

    const char path[] = "/var/www/app/config.json";
    unsigned long path_args[6] = { (unsigned long)(uintptr_t)path, 0, 0, 0, 0, 0 };
    int kind = ARG_SEMANTIC_NONE;
    uint8_t path_hash = compute_arg_hash_semantic(getpid(), SYS_open, path_args,
                                                  &cfg, &kind);
    CHECK(kind == ARG_SEMANTIC_FILE_PATH);
    CHECK(path_hash == djb2_8(path, strlen(path)));

    const char sql1[] = "SELECT a FROM users WHERE id=1";
    const char sql2[] = "SELECT a FROM users WHERE id=999";
    unsigned long sql_args[6] = {
        1, (unsigned long)(uintptr_t)sql1, sizeof(sql1) - 1, 0, 0, 0
    };
    uint8_t sql_hash = compute_arg_hash_semantic(getpid(), SYS_write, sql_args,
                                                 &cfg, &kind);
    CHECK(kind == ARG_SEMANTIC_SQL);
    CHECK(sql_hash != 0);
    sql_args[1] = (unsigned long)(uintptr_t)sql2;
    sql_args[2] = sizeof(sql2) - 1;
    CHECK(compute_arg_hash_semantic(getpid(), SYS_write, sql_args, &cfg, &kind)
          == sql_hash);
    CHECK(sql_hash == sql_query_reduced_hash(sql1, sizeof(sql1) - 1));

    const char plain[] = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    unsigned long plain_args[6] = {
        1, (unsigned long)(uintptr_t)plain, sizeof(plain) - 1, 0, 0, 0
    };
    CHECK(compute_arg_hash_semantic(getpid(), SYS_write, plain_args, &cfg, &kind) == 0);
    CHECK(kind == ARG_SEMANTIC_NONE);

    unsigned long scalar_args[6] = {0};
    CHECK(compute_arg_hash_semantic(getpid(), SYS_read, scalar_args, &cfg, &kind) == 0);
    CHECK(kind == ARG_SEMANTIC_NONE);

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(3306);
    unsigned long conn_args[6] = { 3, (unsigned long)(uintptr_t)&sa, sizeof(sa), 0, 0, 0 };
    CHECK(compute_arg_hash_semantic(getpid(), SYS_connect, conn_args, &cfg, &kind) == 0);
    CHECK(kind == ARG_SEMANTIC_NONE);
    struct config plain_cfg;
    config_defaults(&plain_cfg);
    plain_cfg.coverage_mode = COV_BIGRAM;
    CHECK(compute_arg_hash_semantic(getpid(), SYS_connect, conn_args, &plain_cfg, &kind)
          == (uint8_t)(3306 & 0xFF));

    uint8_t recorded[MAP_SIZE] = {0};
    uint8_t expected[MAP_SIZE] = {0};
    const long observed[] = { SYS_open, SYS_read, SYS_write, SYS_write };
    const uint8_t observed_ah[] = { path_hash, 0, 0, sql_hash };
    uint32_t prev = 0;
    for (size_t i = 0; i < sizeof(observed) / sizeof(observed[0]); i++) {
        bitmap_record_bigram(recorded, prev, (uint32_t)observed[i], observed_ah[i]);
        prev = (uint32_t)observed[i];
    }
    bitmap_record_bigram(expected, 0, SYS_open, path_hash);
    bitmap_record_bigram(expected, SYS_open, SYS_read, 0);
    bitmap_record_bigram(expected, SYS_read, SYS_write, 0);
    bitmap_record_bigram(expected, SYS_write, SYS_write, sql_hash);
    CHECK(prev == (uint32_t)SYS_write);
    CHECK(memcmp(recorded, expected, MAP_SIZE) == 0);

    CHECK(recorded[(uint16_t)(((SYS_open & 0xFF) << 8) ^ (SYS_read & 0xFF))] != 0);
    CHECK(recorded[(uint16_t)(((SYS_read & 0xFF) << 8) ^ (SYS_write & 0xFF))] != 0);
    return 0;
}

static int test_file_sql_pred_args_config(void)
{
    struct config cfg;
    config_defaults(&cfg);
    CHECK(cfg.file_sql_pred_args == 1);
    CHECK(config_file_sql_pred_args(&cfg) == 0);

    char *on[] = { (char *)"tracelib", (char *)"--file-sql-unfiltered" };
    CHECK(config_from_args(&cfg, 2, on) == 0);
    CHECK(config_file_sql_pred_args(&cfg) == 1);

    struct config off;
    config_defaults(&off);
    char *off_argv[] = { (char *)"tracelib", (char *)"--file-sql-unfiltered",
                         (char *)"--no-file-sql-pred-args" };
    CHECK(config_from_args(&off, 3, off_argv) == 0);
    CHECK(off.file_sql_unfiltered == 1);
    CHECK(off.file_sql_pred_args == 0);
    CHECK(config_file_sql_pred_args(&off) == 0);

    struct config only;
    config_defaults(&only);
    char *only_argv[] = { (char *)"tracelib", (char *)"--file-sql-only" };
    CHECK(config_from_args(&only, 2, only_argv) == 0);
    CHECK(config_file_sql_pred_args(&only) == 0);
    return 0;
}

static int test_pred_arg_edge_index(void)
{
    uint8_t with_pred[MAP_SIZE] = {0};
    uint8_t blind[MAP_SIZE] = {0};

    bitmap_record_bigram_pred(with_pred, SYS_read, 0, SYS_write, 0x5A);
    bitmap_record_bigram(blind, SYS_read, SYS_write, 0x5A);
    CHECK(memcmp(with_pred, blind, MAP_SIZE) == 0);

    memset(with_pred, 0, MAP_SIZE);
    memset(blind, 0, MAP_SIZE);
    bitmap_record_bigram_pred(with_pred, SYS_open, 0x3C, SYS_read, 0);
    bitmap_record_bigram(blind, SYS_open, SYS_read, 0);
    CHECK(memcmp(with_pred, blind, MAP_SIZE) != 0);
    CHECK(with_pred[(uint16_t)((((SYS_open ^ 0x3C) & 0xFF) << 8) ^ (SYS_read & 0xFF))] == 1);
    return 0;
}

static int test_pred_args_distinguishes_predecessor_argument(void)
{
    const long trace[] = { SYS_open, SYS_read, SYS_close };
    const uint8_t ah_a[] = { 0x11, 0, 0 };
    const uint8_t ah_b[] = { 0x22, 0, 0 };
    const size_t n = sizeof(trace) / sizeof(trace[0]);

    uint8_t pred_a[MAP_SIZE] = {0}, pred_b[MAP_SIZE] = {0};
    uint8_t blind_a[MAP_SIZE] = {0}, blind_b[MAP_SIZE] = {0};
    uint32_t prev_a = 0, prev_b = 0;
    uint8_t prev_ah_a = 0, prev_ah_b = 0;

    for (size_t i = 0; i < n; i++) {
        bitmap_record_bigram_pred(pred_a, prev_a, prev_ah_a, (uint32_t)trace[i], ah_a[i]);
        bitmap_record_bigram_pred(pred_b, prev_b, prev_ah_b, (uint32_t)trace[i], ah_b[i]);
        bitmap_record_bigram(blind_a, prev_a, (uint32_t)trace[i], ah_a[i]);
        bitmap_record_bigram(blind_b, prev_b, (uint32_t)trace[i], ah_b[i]);
        prev_a = prev_b = (uint32_t)trace[i];
        prev_ah_a = ah_a[i];
        prev_ah_b = ah_b[i];
    }

    CHECK(memcmp(pred_a, pred_b, MAP_SIZE) != 0);
    CHECK(memcmp(blind_a, blind_b, MAP_SIZE) != 0);
    CHECK(bitmap_count_nonzero(pred_a) == 3);
    CHECK(bitmap_count_nonzero(blind_a) == 3);

    uint16_t blind_edge = (uint16_t)(((SYS_open & 0xFF) << 8) ^ (SYS_read & 0xFF));
    CHECK(blind_a[blind_edge] != 0 && blind_b[blind_edge] != 0);
    uint16_t pred_edge_a = (uint16_t)((((SYS_open ^ 0x11) & 0xFF) << 8) ^ (SYS_read & 0xFF));
    uint16_t pred_edge_b = (uint16_t)((((SYS_open ^ 0x22) & 0xFF) << 8) ^ (SYS_read & 0xFF));
    CHECK(pred_edge_a != pred_edge_b);
    CHECK(pred_a[pred_edge_a] != 0);
    CHECK(pred_b[pred_edge_b] != 0);
    CHECK(pred_a[pred_edge_b] == 0);
    return 0;
}

static int test_separated_index_halves(void)
{

    for (uint32_t prev = 0; prev < 256; prev += 7) {
        for (uint32_t curr = 0; curr < 256; curr += 11) {
            uint16_t up = bigram_upper_index(prev, curr);
            CHECK(up >= MAP_HALF && up < MAP_SIZE);
            for (uint32_t ah = 0; ah < 256; ah += 37) {
                uint16_t lo = bigram_lower_index(prev, curr, (uint8_t)ah);
                CHECK(lo < MAP_HALF);
            }
        }
    }

    CHECK(bigram_upper_index(257, 0) == bigram_upper_index(257, 0));
    CHECK(bigram_lower_index(257, 0, 204) == bigram_lower_index(257, 0, 204));

    CHECK(bigram_upper_index(257, 0) == bigram_upper_index(257, 0));

    CHECK(bigram_lower_index(257, 0, 204) != bigram_lower_index(257, 0, 32));

    CHECK(bigram_upper_index(257, 0) != bigram_upper_index(42, 44));
    return 0;
}

static int test_separated_recording(void)
{
    static uint8_t map[MAP_SIZE];
    memset(map, 0, sizeof(map));

    bitmap_record_bigram_separated(map, 0, 3, 0, 0);
    uint16_t up = bigram_upper_index(0, 3);
    CHECK(map[up] == 1);
    size_t lower_set = 0;
    for (size_t i = 0; i < MAP_HALF; i++) if (map[i]) lower_set++;
    CHECK(lower_set == 0);

    memset(map, 0, sizeof(map));
    bitmap_record_bigram_separated(map, 257, 0, 204, 1);
    CHECK(map[bigram_upper_index(257, 0)] == 1);
    CHECK(map[bigram_lower_index(257, 0, 204)] == 1);

    memset(map, 0, sizeof(map));
    bitmap_record_bigram_separated(map, 257, 0, 204, 1);
    bitmap_record_bigram_separated(map, 257, 0, 32, 1);
    CHECK(map[bigram_upper_index(257, 0)] == 2);
    CHECK(map[bigram_lower_index(257, 0, 204)] == 1);
    CHECK(map[bigram_lower_index(257, 0, 32)] == 1);

    memset(map, 0, sizeof(map));
    for (int i = 0; i < 300; i++)
        bitmap_record_bigram_separated(map, 0, 0, 0, 0);
    CHECK(map[bigram_upper_index(0, 0)] == 0xFF);
    return 0;
}

static int test_separated_prune_upper_half(void)
{
    static uint8_t map[MAP_SIZE];
    memset(map, 0, sizeof(map));

    map[10] = 1;
    map[20] = 3;
    map[MAP_HALF + 5]  = 1;
    map[MAP_HALF + 6]  = 7;
    map[MAP_HALF + 7]  = 8;
    map[MAP_HALF + 8]  = 255;

    size_t kept = bitmap_prune_upper_half(map, 8);
    CHECK(kept == 2);

    CHECK(map[10] == 1);
    CHECK(map[20] == 3);

    CHECK(map[MAP_HALF + 5] == 0);
    CHECK(map[MAP_HALF + 6] == 0);
    CHECK(map[MAP_HALF + 7] == 8);
    CHECK(map[MAP_HALF + 8] == 255);

    memset(map, 0, sizeof(map));
    map[MAP_HALF + 1] = 1;
    map[3] = 1;
    CHECK(bitmap_prune_upper_half(map, 1) == 1);
    CHECK(map[MAP_HALF + 1] == 1);
    CHECK(bitmap_prune_upper_half(map, 0) == 1);
    CHECK(map[MAP_HALF + 1] == 1);
    CHECK(map[3] == 1);

    memset(map, 0, sizeof(map));
    CHECK(bitmap_prune_upper_half(map, 8) == 0);
    return 0;
}

static int test_separated_config(void)
{
    struct config cfg;
    config_defaults(&cfg);
    CHECK(cfg.bigram_file_sql_separated == 0);
    CHECK(cfg.separated_min_hits == 8);
    CHECK(config_bigram_separated(&cfg) == 0);

    char *argv_on[] = { (char *)"tracelib", (char *)"--bigram-file-sql-separated",
                        (char *)"--separated-min-hits", (char *)"3" };
    config_defaults(&cfg);
    CHECK(config_from_args(&cfg, 4, argv_on) == 0);
    CHECK(config_bigram_separated(&cfg) == 1);
    CHECK(cfg.separated_min_hits == 3);

    config_defaults(&cfg);
    char *argv_default_k[] = { (char *)"tracelib", (char *)"--bigram-file-sql-separated" };
    CHECK(config_from_args(&cfg, 2, argv_default_k) == 0);
    CHECK(cfg.separated_min_hits == 8);
    CHECK(config_top_edges(&cfg) == 0);
    return 0;
}

static int test_file_path_monitored(void)
{
    struct config cfg;
    config_defaults(&cfg);

    CHECK(strcmp(cfg.file_path_monitored, "/var/www") == 0);
    CHECK(strcmp(cfg.excluded_file_path, "temp,cache,debugbar,tmp,sessions,images,logs") == 0);
    CHECK(cfg.excluded_token_count == 7);
    CHECK(strcmp(cfg.excluded_tokens[0], "temp") == 0);
    CHECK(strcmp(cfg.excluded_tokens[1], "cache") == 0);
    CHECK(strcmp(cfg.excluded_tokens[2], "debugbar") == 0);
    CHECK(strcmp(cfg.excluded_tokens[3], "tmp") == 0);
    CHECK(strcmp(cfg.excluded_tokens[4], "sessions") == 0);

    CHECK(strcmp(cfg.excluded_tokens[5], "images") == 0);

    CHECK(strcmp(cfg.excluded_tokens[6], "logs") == 0);
    CHECK(config_path_is_monitored(
              &cfg, "/var/www/html/logs/myDEBUG-adm-20260828-120001-a3f9c.log", 56) == 0);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/login.php", 23) == 1);
    CHECK(config_path_is_monitored(
              &cfg, "/var/www/html/images/banners/125x125_zen_logo.gif", 50) == 0);
    CHECK(config_path_is_monitored(
              &cfg, "/var/www/html/includes/templates/responsive_classic/images/free.png", 67) == 0);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/imagemagick.php", 28) == 1);

    CHECK(config_bigram_separated(&cfg) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/index.php", 23) == 1);
    CHECK(config_path_is_monitored(&cfg, "/tmp/sess_abc", 13) == 0);

    CHECK(config_path_is_monitored(
              &cfg, "/var/www/html/wp-content/temp-write-test-6a887e24c8fc19-46878693", 63) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/bagisto/storage/framework/cache/data/x", 46) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/tmp/sess", 22) == 0);
    CHECK(config_path_is_monitored(
              &cfg, "/var/www/bagisto/storage/debugbar/Xbf8d0ce8da599bdc.json", 55) == 0);
    CHECK(config_path_is_monitored(
              &cfg, "/var/www/bagisto/storage/framework/sessions/tXpbQreFtR9WA", 55) == 0);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/wp-includes/template.php", 38) == 1);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/storage/debug/x.log", 33) == 1);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/lib/debugbarrier.php", 33) == 1);

    {
        char *argv_x[] = { (char *)"tracelib", (char *)"--excluded-file-path", (char *)"temp" };
        config_defaults(&cfg);
        CHECK(config_from_args(&cfg, 3, argv_x) == 0);
    }

    CHECK(config_path_is_monitored(&cfg, "/var/www", 8) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/", 9) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/wp-config.php", 27) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/other/app.php", 22) == 1);

    CHECK(config_path_is_monitored(&cfg, "/var/wwwroot/x.php", 18) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/ww", 7) == 0);

    CHECK(config_path_is_monitored(&cfg, "/proc/self/status", 17) == 0);
    CHECK(config_path_is_monitored(&cfg, "/etc/passwd", 11) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/instr/map.req-1", 20) == 0);

    CHECK(config_path_is_monitored(
              &cfg, "/var/www/html/wp-content/temp-write-test-6a887e24c8fc19-46878693", 63) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/a/temp/b.php", 26) == 0);

    CHECK(config_path_is_monitored(&cfg, "/var/www/temp", 13) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/wp-temp.php", 25) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/temp2/x.php", 20) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/temp/", 14) == 0);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/template.php", 26) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/contemporary.php", 25) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/tempfile", 22) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/attempt.php", 25) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/mytemp.php", 24) == 1);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/tem.php", 21) == 1);

    CHECK(config_path_is_monitored(&cfg, "/var/www/template/temp-x", 24) == 0);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/TEMP-x.php", 24) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/Temp/x.php", 19) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/tEmP-write-test-1", 31) == 0);

    CHECK(config_path_is_monitored(&cfg, "/var/www/html/TEMPLATE.php", 26) == 1);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/Template.php", 26) == 1);

    char *argv_uc[] = { (char *)"tracelib", (char *)"--excluded-file-path", (char *)"TEMP" };
    config_defaults(&cfg);
    CHECK(config_from_args(&cfg, 3, argv_uc) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/temp-write-test-1", 31) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/template.php", 26) == 1);
    config_defaults(&cfg);

    char *argv_sep[] = { (char *)"tracelib", (char *)"--bigram-file-sql-separated",
                         (char *)"--excluded-file-path", (char *)"temp" };
    config_defaults(&cfg);
    CHECK(config_from_args(&cfg, 4, argv_sep) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/wp-content/temp-write-test-x", 41) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/wp-config.php", 27) == 1);

    char *argv_c[] = { (char *)"tracelib", (char *)"--file-path-monitored", (char *)"/srv/app",
                       (char *)"--excluded-file-path", (char *)"cache" };
    config_defaults(&cfg);
    CHECK(config_from_args(&cfg, 5, argv_c) == 0);
    CHECK(config_path_is_monitored(&cfg, "/srv/app/index.php", 18) == 1);
    CHECK(config_path_is_monitored(&cfg, "/srv/app/cache/x.php", 20) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/x.php", 19) == 0);

    CHECK(config_path_is_monitored(&cfg, "/srv/app/temp-write-test-1", 26) == 1);
    CHECK(config_path_is_monitored(&cfg, "/srv/app/my-cache/x", 19) == 0);
    CHECK(config_path_is_monitored(&cfg, "/srv/app/cached.php", 19) == 1);

    char *argv_e[] = { (char *)"tracelib", (char *)"--file-path-monitored", (char *)"",
                       (char *)"--excluded-file-path", (char *)"" };
    config_defaults(&cfg);
    CHECK(config_from_args(&cfg, 5, argv_e) == 0);
    CHECK(config_path_is_monitored(&cfg, "/tmp/anything-temp", 18) == 1);

    char *argv_none[] = { (char *)"tracelib", (char *)"--excluded-file-path", (char *)"" };
    config_defaults(&cfg);
    CHECK(config_from_args(&cfg, 3, argv_none) == 0);
    CHECK(config_path_is_monitored(&cfg, "/var/www/html/temp-write-test-1", 31) == 1);
    CHECK(config_path_is_monitored(&cfg, "/tmp/x", 6) == 0);
    return 0;
}

static int test_file_sql_filtered_config(void)
{
    struct config cfg;
    config_defaults(&cfg);
    CHECK(cfg.file_sql_filtered == 0);
    CHECK(config_file_sql_filtered(&cfg) == 0);

    char *argv[] = { (char *)"tracelib", (char *)"--bigram-file-sql-filtered" };
    config_defaults(&cfg);
    CHECK(config_from_args(&cfg, 2, argv) == 0);
    CHECK(config_file_sql_filtered(&cfg) == 1);

    CHECK(cfg.file_sql_only == 1);

    CHECK(config_file_sql_pred_args(&cfg) == 1);

    CHECK(config_file_sql_args(&cfg) == 1);

    CHECK(cfg.file_sql_unfiltered == 0);
    CHECK(config_bigram_separated(&cfg) == 0);

    config_defaults(&cfg);
    char *argv_only[] = { (char *)"tracelib", (char *)"--file-sql-only" };
    CHECK(config_from_args(&cfg, 2, argv_only) == 0);
    CHECK(config_file_sql_filtered(&cfg) == 0);
    CHECK(config_file_sql_pred_args(&cfg) == 0);
    return 0;
}

static int test_file_sql_filtered_index(void)
{

    static uint8_t map[MAP_SIZE];
    const uint32_t prev_sc = 257, curr_sc = 44;
    const uint8_t prev_ah = 0xC3, curr_ah = 0x5A;

    memset(map, 0, sizeof(map));
    bitmap_record_bigram_pred(map, prev_sc, prev_ah, curr_sc, curr_ah);
    uint16_t expect = (uint16_t)((((prev_sc ^ prev_ah) & 0xFF) << 8) ^
                                 ((curr_sc ^ curr_ah) & 0xFF));
    CHECK(map[expect] == 1);
    CHECK(bitmap_count_nonzero(map) == 1);

    memset(map, 0, sizeof(map));
    bitmap_record_bigram_pred(map, prev_sc, (uint8_t)(prev_ah ^ 1), curr_sc, curr_ah);
    CHECK(map[expect] == 0);
    memset(map, 0, sizeof(map));
    bitmap_record_bigram_pred(map, prev_sc, prev_ah, curr_sc, (uint8_t)(curr_ah ^ 1));
    CHECK(map[expect] == 0);

    static uint8_t plain[MAP_SIZE];
    memset(map, 0, sizeof(map)); memset(plain, 0, sizeof(plain));
    bitmap_record_bigram_pred(map, prev_sc, 0, curr_sc, 0);
    bitmap_record_bigram(plain, prev_sc, curr_sc, 0);
    CHECK(memcmp(map, plain, MAP_SIZE) == 0);
    return 0;
}

static int test_file_sql_filtered_projection(void)
{

    char probe = 'x', copied = 0;
    if (pm_read(getpid(), (uintptr_t)&probe, &copied, 1) != 1) {
        puts("SKIP: process_vm_readv is blocked; filtered-projection test unavailable");
        return 0;
    }
    struct config cfg;
    config_defaults(&cfg);
    cfg.coverage_mode = COV_BIGRAM;
    char *argv[] = { (char *)"tracelib", (char *)"--bigram-file-sql-filtered" };
    CHECK(config_from_args(&cfg, 2, argv) == 0);
    cfg.coverage_mode = COV_BIGRAM;

    const char path[] = "/var/www/app/config.json";
    unsigned long path_args[6] = { (unsigned long)(uintptr_t)path, 0, 0, 0, 0, 0 };
    int kind = ARG_SEMANTIC_NONE;
    uint8_t h = compute_arg_hash_semantic(getpid(), SYS_open, path_args, &cfg, &kind);
    CHECK(kind == ARG_SEMANTIC_FILE_PATH);
    CHECK(h == djb2_8(path, strlen(path)));

    unsigned long none_args[6] = { 3, 0, 0, 0, 0, 0 };
    kind = ARG_SEMANTIC_FILE_PATH;
    (void)compute_arg_hash_semantic(getpid(), SYS_close, none_args, &cfg, &kind);
    CHECK(kind == ARG_SEMANTIC_NONE);

    const char outside[] = "/etc/passwd";
    unsigned long out_args[6] = { (unsigned long)(uintptr_t)outside, 0, 0, 0, 0, 0 };
    kind = ARG_SEMANTIC_FILE_PATH;
    CHECK(compute_arg_hash_semantic(getpid(), SYS_open, out_args, &cfg, &kind) == 0);
    CHECK(kind == ARG_SEMANTIC_NONE);
    return 0;
}

static int canon_eq(const char *in, const char *want)
{
    char out[256];
    size_t n = arghash_canon_path(in, strlen(in), out, sizeof(out));
    if (n != strlen(want) || strcmp(out, want) != 0) {
        fprintf(stderr, "canon(%s) = '%s', want '%s'\n", in, out, want);
        return -1;
    }
    return 0;
}

static int test_path_canonicalization(void)
{

    CHECK(canon_eq("/var/www/html/storage/framework/cache/data/17/df/"
                   "17df15dcea62857ffa8facf0cff6f41899ef3c42",
                   "/var/www/html/storage/framework/cache/data/#/df/#") == 0);

    CHECK(canon_eq("/var/www/html/storage/debugbar/Xbf8d0ce8da5991f0a1e2c3d4e5f60718.json",
                   "/var/www/html/storage/debugbar/#.json") == 0);

    CHECK(canon_eq("/var/www/bagisto/storage/framework/sessions/tXpbQreFtR9WAoTC0TbUvJ2bMZVCpoomt0EsbIaE",
                   "/var/www/bagisto/storage/framework/sessions/#") == 0);

    CHECK(canon_eq("/var/www/html/vendor/x/InstantiatorInterface.php",
                   "/var/www/html/vendor/x/InstantiatorInterface.php") == 0);
    CHECK(canon_eq("/var/www/html/controllers/admin/AdminDashboardController.php",
                   "/var/www/html/controllers/admin/AdminDashboardController.php") == 0);
    CHECK(canon_eq("/var/www/html/wp-content/themes/twentytwentyfive/style.css",
                   "/var/www/html/wp-content/themes/twentytwentyfive/style.css") == 0);
    CHECK(canon_eq("/var/www/html/libs/sysplugins/smarty_internal_runtime_foreach.php",
                   "/var/www/html/libs/sysplugins/smarty_internal_runtime_foreach.php") == 0);

    CHECK(canon_eq("/var/www/html/wp-includes/template.php",
                   "/var/www/html/wp-includes/template.php") == 0);

    CHECK(canon_eq("/var/www/cache/2026/08/25/page.php", "/var/www/cache/#/#/#/page.php") == 0);
    CHECK(canon_eq("/var/www/cache/abc/file", "/var/www/cache/abc/file") == 0);
    CHECK(canon_eq("/var/www/cache/deadbeef", "/var/www/cache/#") == 0);
    CHECK(canon_eq("/var/www/cache/deadbee", "/var/www/cache/deadbee") == 0);

    const char *a = "/var/www/html/storage/framework/cache/data/17/df/"
                    "17df15dcea62857ffa8facf0cff6f41899ef3c42";
    const char *a2 = "/var/www/html/storage/framework/cache/data/17/df/"
                     "17dfaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *b = "/var/www/html/storage/framework/cache/data/07/c9/"
                    "07c9d9e4fefa575f8c8ddf7337be807464ebec39";
    char ca[256], ca2[256], cb[256];
    size_t na  = arghash_canon_path(a,  strlen(a),  ca,  sizeof(ca));
    size_t na2 = arghash_canon_path(a2, strlen(a2), ca2, sizeof(ca2));
    size_t nb  = arghash_canon_path(b,  strlen(b),  cb,  sizeof(cb));
    CHECK(djb2_8(ca, na) == djb2_8(ca2, na2));
    CHECK(djb2_8(a, strlen(a)) != djb2_8(a2, strlen(a2)));

    CHECK(djb2_8(ca, na) != djb2_8(cb, nb));

    const char *t = "/var/www/html/wp-includes/template.php";
    char ct[256];
    size_t nt = arghash_canon_path(t, strlen(t), ct, sizeof(ct));
    CHECK(djb2_8(ct, nt) != djb2_8(ca, na));

    const char *paths[] = {
        a, a2, b, t,
        "/var/www/html/storage/debugbar/Xbf8d0ce8da5991f0a1e2c3d4e5f60718.json",
        "/var/www/cache/2026/08/25/page.php",
        "/var/www/cache/deadbeef",
        "/var/www/cache/deadbee",
        "/var/www",
        "/var/www/",
        "/",
    };

    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        char c[256];
        size_t n = arghash_canon_path(paths[i], strlen(paths[i]), c, sizeof(c));
        CHECK(n < sizeof(c));
        CHECK(c[n] == '\0');
    }

    {
        struct config pcfg;
        config_defaults(&pcfg);
        uint8_t h1 = 0, h2 = 0;

        CHECK(arghash_path_hash(&pcfg, a, strlen(a), &h1) == 0);
        const char *probe = "/var/www/html/wp-content/temp-write-test-6a887e24-99";
        CHECK(arghash_path_hash(&pcfg, probe, strlen(probe), &h1) == 0);

        CHECK(arghash_path_hash(&pcfg, "/etc/passwd", 11, &h1) == 0);

        CHECK(arghash_path_hash(&pcfg, t, strlen(t), &h1) == 1);
        CHECK(h1 == djb2_8(ct, nt));

        const char *q1 = "/var/www/html/sites/default/files/php/twig/"
                         "17df15dcea62857ffa8facf0cff6f41899ef3c42";
        const char *q2 = "/var/www/html/sites/default/files/php/twig/"
                         "07c9d9e4fefa575f8c8ddf7337be807464ebec39";
        CHECK(arghash_path_hash(&pcfg, q1, strlen(q1), &h1) == 1);
        CHECK(arghash_path_hash(&pcfg, q2, strlen(q2), &h2) == 1);
        CHECK(h1 == h2);
        CHECK(djb2_8(q1, strlen(q1)) != djb2_8(q2, strlen(q2)));

        const char *r1 = "/var/www/html/sites/default/files/php/twig/"
                         "17df15dcea62857ffa8facf0cff6f41899ef3c42.php";
        const char *r2 = "/var/www/html/sites/default/files/php/twig/"
                         "07c9d9e4fefa575f8c8ddf7337be807464ebec39.php";
        CHECK(arghash_path_hash(&pcfg, r1, strlen(r1), &h1) == 1);
        CHECK(arghash_path_hash(&pcfg, r2, strlen(r2), &h2) == 1);
        CHECK(h1 == h2);
    }
    return 0;
}

int main(void)
{
    CHECK(test_shipped_policy() == 0);
    CHECK(test_parser_and_deduplication() == 0);
    CHECK(test_invalid_policies_fail_closed() == 0);
    CHECK(test_strict_ngram_projection() == 0);
    CHECK(test_strict_bigram_projection() == 0);
    CHECK(test_file_sql_mode_config() == 0);
    CHECK(test_sql_query_reduction() == 0);
    CHECK(test_sql_values_reduction() == 0);
    CHECK(test_sql_limit_and_list_reduction() == 0);
    CHECK(test_file_sql_argument_projection() == 0);
    CHECK(test_file_sql_unfiltered_arguments() == 0);
    CHECK(test_file_sql_pred_args_config() == 0);
    CHECK(test_pred_arg_edge_index() == 0);
    CHECK(test_pred_args_distinguishes_predecessor_argument() == 0);
    CHECK(test_separated_index_halves() == 0);
    CHECK(test_separated_recording() == 0);
    CHECK(test_separated_prune_upper_half() == 0);
    CHECK(test_separated_config() == 0);
    CHECK(test_file_path_monitored() == 0);
    CHECK(test_path_canonicalization() == 0);
    CHECK(test_file_sql_filtered_config() == 0);
    CHECK(test_file_sql_filtered_index() == 0);
    CHECK(test_file_sql_filtered_projection() == 0);
    puts("TraceLib syscall-filter, file/SQL normalization, projection, and separated-map tests passed");
    return 0;
}
