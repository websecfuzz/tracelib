#include "sql_detect.h"
#include "bitmap.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

static const char *const kSqlKeywords[] = {
    "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE",
    "DROP",   "ALTER",  "REPLACE","CALL",   "EXEC",
};
static const size_t kSqlKeywordCount =
    sizeof(kSqlKeywords) / sizeof(kSqlKeywords[0]);

#define SQL_MAX_COLUMNS   16
#define SQL_COL_MAX       63
#define SQL_TABLE_MAX     127
#define SQL_CANON_MAX     512

static int starts_with_ci(const char *buf, size_t buf_len, const char *kw)
{
    size_t kl = strlen(kw);
    if (buf_len < kl) return 0;
    for (size_t i = 0; i < kl; i++) {
        unsigned char a = (unsigned char)buf[i];
        unsigned char b = (unsigned char)kw[i];
        if (toupper(a) != toupper(b)) return 0;
    }
    return 1;
}

static int is_ident_char(unsigned char c)
{
    return isalnum(c) || c == '_' || c == '.' || c == '$';
}

static size_t skip_string_literal(const char *buf, size_t buf_len, size_t pos)
{
    char q = buf[pos++];
    while (pos < buf_len) {
        if (buf[pos] == '\\' && pos + 1 < buf_len) { pos += 2; continue; }
        if (buf[pos] == q) {
            if (pos + 1 < buf_len && buf[pos + 1] == q) { pos += 2; continue; }
            return pos + 1;
        }
        pos++;
    }
    return pos;
}

static size_t find_keyword_ci(const char *buf, size_t buf_len,
                              size_t start, const char *kw)
{
    size_t kl = strlen(kw);
    if (kl == 0 || buf_len < kl) return (size_t)-1;
    size_t i = start;
    while (i + kl <= buf_len) {
        char c = buf[i];
        if (c == '\'' || c == '"') {
            i = skip_string_literal(buf, buf_len, i);
            continue;
        }
        size_t m = 0;
        for (; m < kl; m++) {
            if (toupper((unsigned char)buf[i + m]) !=
                toupper((unsigned char)kw[m])) break;
        }
        if (m == kl) {
            int lb = (i == 0) || !is_ident_char((unsigned char)buf[i - 1]);
            int rb = (i + kl >= buf_len) ||
                     !is_ident_char((unsigned char)buf[i + kl]);
            if (lb && rb) return i;
        }
        i++;
    }
    return (size_t)-1;
}

static size_t read_ident(const char *buf, size_t buf_len, size_t pos,
                         char *out, size_t outcap)
{
    out[0] = '\0';
    while (pos < buf_len && isspace((unsigned char)buf[pos])) pos++;
    size_t o = 0;
    while (pos < buf_len) {
        unsigned char c = (unsigned char)buf[pos];
        if (c == '`' || c == '"' || c == '[' || c == ']') { pos++; continue; }
        if (!is_ident_char(c)) break;
        if (o + 1 < outcap) out[o++] = (char)tolower(c);
        pos++;
    }
    out[o] = '\0';
    return pos;
}

static int cmp_str(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int extract_table(const char *buf, size_t buf_len, size_t verb_end,
                         const char *verb, char *table, size_t table_cap)
{
    table[0] = '\0';
    size_t tpos = (size_t)-1;

    if (strcmp(verb, "UPDATE") == 0) {

        tpos = verb_end;
    } else if (strcmp(verb, "INSERT") == 0 || strcmp(verb, "REPLACE") == 0) {
        size_t k = find_keyword_ci(buf, buf_len, verb_end, "INTO");
        if (k != (size_t)-1) tpos = k + 4;
    } else if (strcmp(verb, "SELECT") == 0 || strcmp(verb, "DELETE") == 0) {
        size_t k = find_keyword_ci(buf, buf_len, verb_end, "FROM");
        if (k != (size_t)-1) tpos = k + 4;
    }

    if (tpos == (size_t)-1) return 0;
    read_ident(buf, buf_len, tpos, table, table_cap);
    return table[0] != '\0';
}

static size_t collect_where_columns(const char *buf, size_t buf_len,
                                    size_t after_verb,
                                    char cols[][SQL_COL_MAX + 1])
{
    size_t wpos = find_keyword_ci(buf, buf_len, after_verb, "WHERE");
    if (wpos == (size_t)-1) return 0;

    size_t p = wpos + 5;
    size_t n = 0;
    while (p < buf_len && n < SQL_MAX_COLUMNS) {
        unsigned char c = (unsigned char)buf[p];
        if (isspace(c)) { p++; continue; }
        if (c == '\'' || c == '"') {
            p = skip_string_literal(buf, buf_len, p);
            continue;
        }
        if (isalpha(c) || c == '_' || c == '`') {
            char ident[SQL_COL_MAX + 1];
            size_t q = read_ident(buf, buf_len, p, ident, sizeof ident);

            size_t r = q;
            while (r < buf_len && isspace((unsigned char)buf[r])) r++;
            int is_cmp = 0;
            if (r < buf_len) {
                char d = buf[r];
                if (d == '=' || d == '<' || d == '>') {
                    is_cmp = 1;
                } else if (d == '!' && r + 1 < buf_len && buf[r + 1] == '=') {
                    is_cmp = 1;
                } else if (find_keyword_ci(buf, buf_len, r, "LIKE") == r ||
                           find_keyword_ci(buf, buf_len, r, "IN")   == r) {
                    is_cmp = 1;
                }
            }
            if (is_cmp && ident[0]) {
                int dup = 0;
                for (size_t i = 0; i < n; i++)
                    if (strcmp(cols[i], ident) == 0) { dup = 1; break; }
                if (!dup) {

                    size_t L = strlen(ident);
                    memcpy(cols[n], ident, L + 1);
                    n++;
                }
            }
            p = (q > p) ? q : p + 1;
            continue;
        }
        p++;
    }
    return n;
}

uint8_t detect_sql_hash_local(const char *buf, size_t buf_len)
{
    size_t i = 0;
    while (i < buf_len && isspace((unsigned char)buf[i])) i++;
    if (i >= buf_len) return 0;

    const char *p = buf + i;
    size_t remaining = buf_len - i;

    const char *verb = NULL;
    size_t verb_len = 0;
    for (size_t k = 0; k < kSqlKeywordCount; k++) {
        if (starts_with_ci(p, remaining, kSqlKeywords[k])) {
            verb = kSqlKeywords[k];
            verb_len = strlen(kSqlKeywords[k]);
            break;
        }
    }
    if (!verb) return 0;

    char table[SQL_TABLE_MAX + 1];
    int have_table = extract_table(p, remaining, verb_len, verb,
                                   table, sizeof table);

    char canon[SQL_CANON_MAX];
    size_t off = 0;

    for (size_t k = 0; verb[k] && off + 1 < sizeof canon; k++)
        canon[off++] = verb[k];

    if (have_table) {
        if (off + 1 < sizeof canon) canon[off++] = ':';
        for (size_t k = 0; table[k] && off + 1 < sizeof canon; k++)
            canon[off++] = table[k];

        char cols[SQL_MAX_COLUMNS][SQL_COL_MAX + 1];
        size_t ncols = collect_where_columns(p, remaining, verb_len, cols);
        if (ncols > 0) {
            char *ptrs[SQL_MAX_COLUMNS];
            for (size_t k = 0; k < ncols; k++) ptrs[k] = cols[k];
            qsort(ptrs, ncols, sizeof ptrs[0], cmp_str);

            if (off + 1 < sizeof canon) canon[off++] = ':';
            for (size_t k = 0; k < ncols; k++) {
                if (k > 0 && off + 1 < sizeof canon) canon[off++] = ',';
                for (size_t m = 0; ptrs[k][m] && off + 1 < sizeof canon; m++)
                    canon[off++] = ptrs[k][m];
            }
        }
    }
    canon[off] = '\0';

    return djb2_8(canon, off);
}

uint8_t detect_sql_hash(pid_t pid, unsigned long buf_addr, size_t buf_len)
{
    if (buf_addr == 0) return 0;

    char local[256];
    size_t want = buf_len;
    if (want == 0 || want > sizeof local) want = sizeof local;

    struct iovec liov = { .iov_base = local, .iov_len = want };
    struct iovec riov = { .iov_base = (void *)buf_addr, .iov_len = want };

    ssize_t got = process_vm_readv(pid, &liov, 1, &riov, 1, 0);
    if (got <= 0) return 0;

    return detect_sql_hash_local(local, (size_t)got);
}
