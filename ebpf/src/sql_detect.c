#include "sql_detect.h"
#include "bitmap.h"

#include <stdio.h>
#include <ctype.h>
#include <string.h>

#define SQL_MAX_INPUT FILE_SQL_DATA_MAX
#define SQL_MAX_TOK   FILE_SQL_DATA_MAX
#define TOK_LEN       40
#define MAX_COLS      16

enum tok_kind { TK_IDENT, TK_STRING, TK_NUMBER, TK_PARAM, TK_OP, TK_PUNC };

struct tok {
    char s[TOK_LEN];
    int  kind;
    int  start;
    int  end;
};

static char lc(char c) { return (char)tolower((unsigned char)c); }
static int  is_ident_start(char c) { return isalpha((unsigned char)c) || c == '_'; }
static int  is_ident_cont(char c)  { return isalnum((unsigned char)c) || c == '_' || c == '.' || c == '$'; }

static void tok_set(struct tok *t, int kind, const char *src, int n,
                    int start, int end)
{
    int k = 0;
    for (int i = 0; i < n && k < TOK_LEN - 1; i++)
        t->s[k++] = src[i];
    t->s[k] = '\0';
    t->kind = kind;
    t->start = start;
    t->end = end;
}

static int tokenize(const char *b, int n, struct tok *out)
{
    int ti = 0, i = 0;
    char tmp[TOK_LEN];

    while (i < n && ti < SQL_MAX_TOK) {
        char c = b[i];

        if (isspace((unsigned char)c)) { i++; continue; }

        if (c == '`') {
            int start = i;
            i++;
            int k = 0;
            while (i < n && b[i] && b[i] != '`') { if (k < TOK_LEN - 1) tmp[k++] = lc(b[i]); i++; }
            if (i < n && b[i] == '`') i++;
            tok_set(&out[ti++], TK_IDENT, tmp, k, start, i);
            continue;
        }
        if (c == '\'' || c == '"') {
            int start = i;
            char q = c; i++;
            int k = 0;
            while (i < n && b[i] && b[i] != q) {
                if (b[i] == '\\' && i + 1 < n) { i += 2; continue; }
                if (k < TOK_LEN - 1) tmp[k++] = lc(b[i]);
                i++;
            }
            if (i < n && b[i] == q) i++;
            tok_set(&out[ti++], TK_STRING, tmp, k, start, i);
            continue;
        }
        if (c == '=') {
            int start = i++;
            tok_set(&out[ti++], TK_OP, "=", 1, start, i);
            continue;
        }
        if (c == '<') {
            int start = i;
            if (i + 1 < n && b[i + 1] == '=') { i += 2; tok_set(&out[ti++], TK_OP, "<=", 2, start, i); }
            else if (i + 1 < n && b[i + 1] == '>') { i += 2; tok_set(&out[ti++], TK_OP, "<>", 2, start, i); }
            else { i++; tok_set(&out[ti++], TK_OP, "<", 1, start, i); }
            continue;
        }
        if (c == '>') {
            int start = i;
            if (i + 1 < n && b[i + 1] == '=') { i += 2; tok_set(&out[ti++], TK_OP, ">=", 2, start, i); }
            else { i++; tok_set(&out[ti++], TK_OP, ">", 1, start, i); }
            continue;
        }
        if (c == '!') {
            int start = i;
            if (i + 1 < n && b[i + 1] == '=') { i += 2; tok_set(&out[ti++], TK_OP, "!=", 2, start, i); }
            else { i++; }
            continue;
        }
        if (isdigit((unsigned char)c) ||
            (c == '.' && i + 1 < n && isdigit((unsigned char)b[i + 1]))) {
            int start = i;
            int k = 0;
            while (i < n &&
                   (isalnum((unsigned char)b[i]) || b[i] == '.' || b[i] == '_')) {
                if (k < TOK_LEN - 1) tmp[k++] = lc(b[i]);
                i++;
            }
            tok_set(&out[ti++], TK_NUMBER, tmp, k, start, i);
            continue;
        }
        if (c == '?' ||
            (c == ':' && i + 1 < n && is_ident_start(b[i + 1])) ||
            (c == '$' && i + 1 < n && isdigit((unsigned char)b[i + 1]))) {
            int start = i;
            int k = 0;
            if (c == '?') {
                tmp[k++] = b[i++];
            } else {
                tmp[k++] = b[i++];
                while (i < n && is_ident_cont(b[i])) {
                    if (k < TOK_LEN - 1) tmp[k++] = lc(b[i]);
                    i++;
                }
            }
            tok_set(&out[ti++], TK_PARAM, tmp, k, start, i);
            continue;
        }
        if (is_ident_start(c)) {
            int start = i;
            int k = 0;
            while (i < n && is_ident_cont(b[i])) { if (k < TOK_LEN - 1) tmp[k++] = lc(b[i]); i++; }
            tok_set(&out[ti++], TK_IDENT, tmp, k, start, i);
            continue;
        }

        int start = i;
        tmp[0] = c;
        tok_set(&out[ti++], TK_PUNC, tmp, 1, start, start + 1);
        i++;
    }
    return ti;
}

static const char *const VERBS[] = {
    "select", "insert", "update", "delete", "create",
    "drop", "alter", "replace", "call", "exec"
};
#define NVERBS ((int)(sizeof(VERBS) / sizeof(VERBS[0])))

static int match_verb(const char *s)
{
    for (int i = 0; i < NVERBS; i++)
        if (strcmp(s, VERBS[i]) == 0)
            return i;
    return -1;
}

static int is_comparison(const struct tok *t)
{
    if (t->kind == TK_OP)
        return 1;
    if (t->kind == TK_IDENT &&
        (strcmp(t->s, "like") == 0 || strcmp(t->s, "in") == 0 ||
         strcmp(t->s, "is") == 0 || strcmp(t->s, "between") == 0 ||
         strcmp(t->s, "rlike") == 0 || strcmp(t->s, "regexp") == 0 ||
         strcmp(t->s, "ilike") == 0 || strcmp(t->s, "match") == 0 ||
         strcmp(t->s, "against") == 0))
        return 1;
    return 0;
}

static int find_kw(const struct tok *t, int nt, int from, const char *kw)
{
    for (int i = from; i < nt; i++)
        if (t[i].kind == TK_IDENT && strcmp(t[i].s, kw) == 0)
            return i;
    return -1;
}

static void cols_insert(char cols[][TOK_LEN], int *nc, const char *name)
{

    for (int i = 0; i < *nc; i++) {
        int cmp = strcmp(name, cols[i]);
        if (cmp == 0) return;
        if (cmp < 0) {
            if (*nc >= MAX_COLS) return;
            for (int j = *nc; j > i; j--)
                memcpy(cols[j], cols[j - 1], TOK_LEN);
            snprintf(cols[i], TOK_LEN, "%s", name);
            (*nc)++;
            return;
        }
    }
    if (*nc < MAX_COLS)
        snprintf(cols[(*nc)++], TOK_LEN, "%s", name);
}

size_t sql_skeleton_canonical(const char *buf, size_t len, char *out, size_t outsz)
{
    if (outsz) out[0] = '\0';
    if (!buf || len == 0 || outsz == 0)
        return 0;

    int n = (int)(len < SQL_MAX_INPUT ? len : SQL_MAX_INPUT);

    struct tok tok[SQL_MAX_TOK];
    int nt = tokenize(buf, n, tok);
    if (nt == 0 || tok[0].kind != TK_IDENT)
        return 0;

    int verb = match_verb(tok[0].s);
    if (verb < 0)
        return 0;

    char table[TOK_LEN]; table[0] = '\0';
    {
        int ti = -1;
        if (verb == 0  || verb == 3 ) {
            int k = find_kw(tok, nt, 1, "from");
            if (k >= 0 && k + 1 < nt) ti = k + 1;
        } else if (verb == 1  || verb == 7 ) {
            int k = find_kw(tok, nt, 1, "into");
            if (k >= 0 && k + 1 < nt) ti = k + 1;
        } else if (verb == 2 ) {
            if (nt > 1) ti = 1;
        }
        if (ti >= 0 && ti < nt && (tok[ti].kind == TK_IDENT || tok[ti].kind == TK_STRING))
            snprintf(table, sizeof(table), "%s", tok[ti].s);
    }

    char cols[MAX_COLS][TOK_LEN];
    int nc = 0;
    {
        int w = find_kw(tok, nt, 1, "where");
        if (w >= 0) {
            for (int j = w + 1; j + 1 < nt; j++) {
                if (tok[j].kind == TK_IDENT && is_comparison(&tok[j + 1]))
                    cols_insert(cols, &nc, tok[j].s);
            }
        }
    }

    char canon[256];
    int p = 0;
    for (const char *v = VERBS[verb]; *v && p < (int)sizeof(canon) - 1; v++)
        canon[p++] = (char)toupper((unsigned char)*v);
    if (p < (int)sizeof(canon) - 1) canon[p++] = ':';
    for (const char *tt = table; *tt && p < (int)sizeof(canon) - 1; tt++)
        canon[p++] = *tt;
    if (p < (int)sizeof(canon) - 1) canon[p++] = ':';
    for (int i = 0; i < nc; i++) {
        if (i && p < (int)sizeof(canon) - 1) canon[p++] = ',';
        for (const char *cc = cols[i]; *cc && p < (int)sizeof(canon) - 1; cc++)
            canon[p++] = *cc;
    }
    canon[p] = '\0';

    snprintf(out, outsz, "%s", canon);
    return strlen(out);
}

uint8_t sql_skeleton_hash(const char *buf, size_t len)
{
    char canon[256];
    size_t n = sql_skeleton_canonical(buf, len, canon, sizeof(canon));
    if (n == 0)
        return 0;
    return djb2_8(canon, n);
}

static int first_sql_verb(const struct tok *tok, int nt)
{
    for (int i = 0; i < nt; i++) {
        if (tok[i].kind == TK_IDENT && match_verb(tok[i].s) >= 0)
            return i;
    }
    return -1;
}

static int query_table_index(const struct tok *tok, int nt, int vi, int verb)
{
    int ti = -1;
    if (verb == 0  || verb == 3 ) {
        int k = find_kw(tok, nt, vi + 1, "from");
        if (k >= 0 && k + 1 < nt) ti = k + 1;
    } else if (verb == 1  || verb == 7 ) {
        int k = find_kw(tok, nt, vi + 1, "into");
        if (k >= 0 && k + 1 < nt) ti = k + 1;
    } else if (verb == 2  || verb == 8  || verb == 9 ) {
        if (vi + 1 < nt) ti = vi + 1;
    } else if (verb == 4  || verb == 5  || verb == 6 ) {
        int k = find_kw(tok, nt, vi + 1, "table");
        if (k >= 0 && k + 1 < nt) ti = k + 1;
    }
    if (ti < 0 || ti >= nt ||
        (tok[ti].kind != TK_IDENT && tok[ti].kind != TK_STRING))
        return -1;
    return ti;
}

static int is_rhs_boundary(const struct tok *t)
{
    if (t->kind != TK_IDENT)
        return 0;
    static const char *const boundary[] = {
        "and", "or", "where", "group", "order", "limit", "having",
        "returning", "union", "except", "intersect", "window", "qualify",
        "offset", "fetch", "for", "from", "set", "values"
    };
    for (size_t i = 0; i < sizeof(boundary) / sizeof(boundary[0]); i++)
        if (strcmp(t->s, boundary[i]) == 0)
            return 1;
    return 0;
}

static int is_redacted_literal(const struct tok *t)
{
    if (t->kind == TK_STRING || t->kind == TK_NUMBER || t->kind == TK_PARAM)
        return 1;
    return t->kind == TK_IDENT &&
           (strcmp(t->s, "null") == 0 || strcmp(t->s, "true") == 0 ||
            strcmp(t->s, "false") == 0 || strcmp(t->s, "unknown") == 0);
}

static void redact_bytes(unsigned char *redacted, int n, int start, int end)
{
    if (start < 0) start = 0;
    if (end > n) end = n;
    for (int i = start; i < end; i++)
        redacted[i] = 1;
}

static void redact_literal_token(const char *buf, const struct tok *tok, int i,
                                 int first, unsigned char *redacted, int n)
{
    int value_start = tok[i].start;
    int value_end = tok[i].end;

    if (tok[i].kind == TK_NUMBER && i > first &&
        tok[i - 1].kind == TK_PUNC &&
        (strcmp(tok[i - 1].s, "+") == 0 || strcmp(tok[i - 1].s, "-") == 0))
        value_start = tok[i - 1].start;
    if (tok[i].kind == TK_STRING && i > first &&
        tok[i - 1].kind == TK_IDENT && tok[i - 1].end == tok[i].start &&
        strlen(tok[i - 1].s) == 1 && strchr("xbne", tok[i - 1].s[0]))
        value_start = tok[i - 1].start;

    if (value_start > 0 && isspace((unsigned char)buf[value_start - 1]))
        while (value_end < n && isspace((unsigned char)buf[value_end]))
            value_end++;
    redact_bytes(redacted, n, value_start, value_end);
}

static void redact_values_clause(const char *buf, const struct tok *tok,
                                 int nt, int vi, unsigned char *redacted, int n)
{
    int kw = find_kw(tok, nt, vi + 1, "values");
    if (kw < 0)
        return;

    for (int i = kw + 1; i < nt; i++) {
        if (tok[i].kind == TK_IDENT &&
            (strcmp(tok[i].s, "on") == 0 || strcmp(tok[i].s, "returning") == 0))
            break;
        if (!is_redacted_literal(&tok[i]))
            continue;
        redact_literal_token(buf, tok, i, kw + 1, redacted, n);
    }
}

static void redact_limit_offset(const char *buf, const struct tok *tok,
                                int nt, int vi, unsigned char *redacted, int n)
{
    for (int i = vi + 1; i < nt; i++) {
        if (tok[i].kind != TK_IDENT ||
            (strcmp(tok[i].s, "limit") != 0 && strcmp(tok[i].s, "offset") != 0))
            continue;
        for (int j = i + 1; j < nt; j++) {
            if (tok[j].kind == TK_PUNC && strcmp(tok[j].s, ",") == 0)
                continue;
            if (!is_redacted_literal(&tok[j]))
                break;
            redact_literal_token(buf, tok, j, i + 1, redacted, n);
        }
    }
}

static void redact_comparison_rhs(const char *buf, const struct tok *tok,
                                  int nt, int op, unsigned char *redacted, int n)
{
    int depth = 0;
    int between_and_pending = tok[op].kind == TK_IDENT &&
                              strcmp(tok[op].s, "between") == 0;

    for (int i = op + 1; i < nt; i++) {
        if (tok[i].kind == TK_PUNC && strcmp(tok[i].s, "(") == 0) {
            depth++;
        } else if (tok[i].kind == TK_PUNC && strcmp(tok[i].s, ")") == 0) {
            if (depth == 0)
                break;
            depth--;
        } else if (depth == 0 && tok[i].kind == TK_PUNC &&
                   (strcmp(tok[i].s, ",") == 0 || strcmp(tok[i].s, ";") == 0)) {
            break;
        } else if (depth == 0 && is_rhs_boundary(&tok[i])) {
            if (between_and_pending && strcmp(tok[i].s, "and") == 0) {
                between_and_pending = 0;
                continue;
            }
            break;
        }

        if (!is_redacted_literal(&tok[i]))
            continue;
        redact_literal_token(buf, tok, i, op + 1, redacted, n);
    }
}

#define SQL_LIST_MARKER "..."

static int paren_group_end(const char *buf, int open, int end)
{
    int depth = 0;
    for (int i = open; i < end; i++) {
        if (buf[i] == '(') {
            depth++;
        } else if (buf[i] == ')') {
            if (--depth == 0)
                return i;
        }
    }
    return -1;
}

static int paren_group_is_blank(const char *buf, const unsigned char *redacted,
                                int open, int close)
{
    int any_redacted = 0;
    for (int i = open + 1; i < close; i++) {
        if (redacted[i]) { any_redacted = 1; continue; }
        if (buf[i] == ',' || isspace((unsigned char)buf[i]))
            continue;
        return 0;
    }
    return any_redacted;
}

static int tok_is(const struct tok *t, const char *s)
{
    return t->kind == TK_IDENT && strcmp(t->s, s) == 0;
}

static int rear_clause_start(const struct tok *tok, int nt, int vi, int end)
{
    int depth = 0;

    for (int i = vi + 1; i < nt; i++) {
        if (tok[i].kind == TK_PUNC && strcmp(tok[i].s, "(") == 0) {
            depth++;
            continue;
        }
        if (tok[i].kind == TK_PUNC && strcmp(tok[i].s, ")") == 0) {
            if (depth > 0)
                depth--;
            continue;
        }
        if (depth != 0 || tok[i].kind != TK_IDENT)
            continue;

        const struct tok *nx = (i + 1 < nt) ? &tok[i + 1] : NULL;

        if (tok_is(&tok[i], "order") && nx && tok_is(nx, "by"))
            return tok[i].start;

        if ((tok_is(&tok[i], "limit") || tok_is(&tok[i], "offset")) && nx &&
            (nx->kind == TK_NUMBER || nx->kind == TK_PARAM || tok_is(nx, "all")))
            return tok[i].start;

        if (tok_is(&tok[i], "fetch") && nx && (tok_is(nx, "first") || tok_is(nx, "next")))
            return tok[i].start;

        if (tok_is(&tok[i], "for") && nx &&
            (tok_is(nx, "update") || tok_is(nx, "share") || tok_is(nx, "no")))
            return tok[i].start;

        if (tok_is(&tok[i], "lock") && nx && tok_is(nx, "in"))
            return tok[i].start;
    }
    return end;
}

size_t sql_query_reduced(const char *buf, size_t len, char *out, size_t outsz)
{
    if (outsz)
        out[0] = '\0';
    if (!buf || len == 0 || outsz == 0)
        return 0;

    int n = (int)(len < SQL_MAX_INPUT ? len : SQL_MAX_INPUT);
    struct tok tok[SQL_MAX_TOK];
    int nt = tokenize(buf, n, tok);
    int vi = first_sql_verb(tok, nt);
    if (vi < 0)
        return 0;
    int verb = match_verb(tok[vi].s);
    if (query_table_index(tok, nt, vi, verb) < 0)
        return 0;

    int query_end = n;
    const char *nul = memchr(buf + tok[vi].start, '\0',
                             (size_t)(n - tok[vi].start));
    if (nul)
        query_end = (int)(nul - buf);

    int rear = rear_clause_start(tok, nt, vi, query_end);
    if (rear < query_end)
        query_end = rear;

    unsigned char redacted[SQL_MAX_INPUT] = {0};
    if (verb == 1  || verb == 7 )
        redact_values_clause(buf, tok, nt, vi, redacted, n);
    for (int i = vi + 1; i < nt; i++)
        if (is_comparison(&tok[i]))
            redact_comparison_rhs(buf, tok, nt, i, redacted, n);
    redact_limit_offset(buf, tok, nt, vi, redacted, n);

    size_t written = 0;
    for (int i = tok[vi].start; i < query_end && written + 1 < outsz; i++) {
        if (buf[i] == '(' && !redacted[i]) {
            int close = paren_group_end(buf, i, query_end);
            if (close > i && paren_group_is_blank(buf, redacted, i, close)) {
                for (const char *m = "(" SQL_LIST_MARKER ")";
                     *m && written + 1 < outsz; m++)
                    out[written++] = *m;
                i = close;
                continue;
            }
        }
        if (!redacted[i])
            out[written++] = buf[i];
    }
    out[written] = '\0';
    return written;
}

uint8_t sql_query_reduced_hash(const char *buf, size_t len)
{
    char canon[SQL_MAX_INPUT + 1];
    size_t n = sql_query_reduced(buf, len, canon, sizeof(canon));
    return n ? djb2_8(canon, n) : 0;
}

#define SQL_COMPACT_MAX_ITEMS 16
#define SQL_COMPACT_ITEM_LEN  (TOK_LEN + 16)

struct compact_set {
    char item[SQL_COMPACT_MAX_ITEMS][SQL_COMPACT_ITEM_LEN];
    int  n;
};

static void compact_add(struct compact_set *set, const char *s)
{
    if (set->n >= SQL_COMPACT_MAX_ITEMS || !s || !s[0])
        return;
    char up[SQL_COMPACT_ITEM_LEN];
    int k = 0;
    for (const char *p = s; *p && k < (int)sizeof(up) - 1; p++)
        up[k++] = (char)toupper((unsigned char)*p);
    up[k] = '\0';
    for (int i = 0; i < set->n; i++)
        if (strcmp(set->item[i], up) == 0)
            return;
    snprintf(set->item[set->n++], SQL_COMPACT_ITEM_LEN, "%s", up);
}

static int compact_is_reserved(const char *s)
{
    static const char *const reserved[] = {
        "select", "insert", "update", "delete", "replace", "create", "drop",
        "alter", "truncate", "call", "exec", "into", "from", "where", "set",
        "values", "group", "order", "having", "limit", "offset", "fetch",
        "for", "union", "except", "intersect", "join", "inner", "left",
        "right", "full", "outer", "cross", "natural", "straight_join", "on",
        "using", "as", "and", "or", "not", "in", "is", "like", "rlike",
        "regexp", "ilike", "match", "against", "between", "by", "asc", "desc",
        "distinct", "all", "table", "if", "exists", "lock", "share", "mode",
        "window", "qualify", "returning", "with", "recursive", "duplicate",
        "key", "ignore", "low_priority", "delayed", "high_priority", "case",
        "when", "then", "else", "end", "null", "true", "false"
    };
    for (size_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++)
        if (strcmp(s, reserved[i]) == 0)
            return 1;
    return 0;
}

static int compact_tok_is(const struct tok *t, const char *s)
{
    return t->kind == TK_IDENT && strcmp(t->s, s) == 0;
}

static int compact_is_name(const struct tok *t)
{
    if (t->kind == TK_STRING)
        return 1;
    return t->kind == TK_IDENT && !compact_is_reserved(t->s);
}

static int compact_emit_command(const struct tok *tok, int nt, int i,
                                struct compact_set *cmds)
{
    char phrase[SQL_COMPACT_ITEM_LEN];
    const char *w = tok[i].s;

    if (match_verb(w) >= 0) {
        const char *particle = NULL;
        if (i + 1 < nt && tok[i + 1].kind == TK_IDENT) {
            const char *nx = tok[i + 1].s;
            if ((strcmp(w, "insert") == 0 || strcmp(w, "replace") == 0) &&
                strcmp(nx, "into") == 0)
                particle = "into";
            else if (strcmp(w, "delete") == 0 && strcmp(nx, "from") == 0)
                particle = "from";
            else if ((strcmp(w, "create") == 0 || strcmp(w, "drop") == 0 ||
                      strcmp(w, "alter") == 0) && strcmp(nx, "table") == 0)
                particle = "table";
        }
        if (particle) {
            snprintf(phrase, sizeof(phrase), "%s %s", w, particle);
            compact_add(cmds, phrase);
            return 1;
        }
        compact_add(cmds, w);
        return 0;
    }

    if (strcmp(w, "truncate") == 0) {
        if (i + 1 < nt && compact_tok_is(&tok[i + 1], "table")) {
            compact_add(cmds, "truncate table");
            return 1;
        }
        compact_add(cmds, "truncate");
        return 0;
    }

    if (strcmp(w, "union") == 0 || strcmp(w, "except") == 0 ||
        strcmp(w, "intersect") == 0) {
        if (i + 1 < nt && compact_tok_is(&tok[i + 1], "all")) {
            snprintf(phrase, sizeof(phrase), "%s all", w);
            compact_add(cmds, phrase);
            return 1;
        }
        compact_add(cmds, w);
        return 0;
    }

    if (strcmp(w, "straight_join") == 0) {
        compact_add(cmds, w);
        return 0;
    }
    if (strcmp(w, "join") == 0) {
        int first = i;
        if (first > 0 && compact_tok_is(&tok[first - 1], "outer"))
            first--;
        if (first > 0 &&
            (compact_tok_is(&tok[first - 1], "inner") ||
             compact_tok_is(&tok[first - 1], "left") ||
             compact_tok_is(&tok[first - 1], "right") ||
             compact_tok_is(&tok[first - 1], "full") ||
             compact_tok_is(&tok[first - 1], "cross")))
            first--;
        if (first > 0 && compact_tok_is(&tok[first - 1], "natural"))
            first--;
        int p = 0;
        for (int j = first; j <= i && p < (int)sizeof(phrase) - 1; j++) {
            if (j > first && p < (int)sizeof(phrase) - 1)
                phrase[p++] = ' ';
            for (const char *c = tok[j].s; *c && p < (int)sizeof(phrase) - 1; c++)
                phrase[p++] = *c;
        }
        phrase[p] = '\0';
        compact_add(cmds, phrase);
        return 0;
    }
    return -1;
}

static int compact_collect_tables(const struct tok *tok, int nt, int i,
                                  int allow_list, struct compact_set *tabs)
{
    int j = i + 1;

    while (j < nt && (compact_tok_is(&tok[j], "if") ||
                      compact_tok_is(&tok[j], "not") ||
                      compact_tok_is(&tok[j], "exists")))
        j++;

    for (;;) {
        if (j >= nt)
            break;
        if (!compact_is_name(&tok[j]))
            break;
        compact_add(tabs, tok[j].s);
        j++;

        if (j < nt && compact_tok_is(&tok[j], "as")) {
            j++;
            if (j < nt && compact_is_name(&tok[j]))
                j++;
        } else if (j < nt && compact_is_name(&tok[j])) {
            j++;
        }
        if (allow_list && j < nt && tok[j].kind == TK_PUNC &&
            tok[j].s[0] == ',') {
            j++;
            continue;
        }
        break;
    }
    return j - 1;
}

size_t sql_compact_query(const char *buf, size_t len, char *out, size_t outsz)
{
    if (outsz)
        out[0] = '\0';
    if (!buf || len == 0 || outsz == 0)
        return 0;

    int n = (int)(len < SQL_MAX_INPUT ? len : SQL_MAX_INPUT);
    struct tok tok[SQL_MAX_TOK];
    int nt = tokenize(buf, n, tok);

    int vi = first_sql_verb(tok, nt);
    if (vi < 0) {
        for (int i = 0; i < nt; i++) {
            if (compact_tok_is(&tok[i], "truncate")) { vi = i; break; }
        }
    }
    if (vi < 0)
        return 0;

    int query_end = n;
    const char *nul = memchr(buf + tok[vi].start, '\0',
                             (size_t)(n - tok[vi].start));
    if (nul)
        query_end = (int)(nul - buf);

    struct compact_set cmds = {0};
    struct compact_set tabs = {0};

    for (int i = vi; i < nt && tok[i].start < query_end; i++) {
        if (tok[i].kind != TK_IDENT)
            continue;

        int extra = compact_emit_command(tok, nt, i, &cmds);
        if (extra >= 0) {

            if (strcmp(tok[i].s, "update") == 0)
                i = compact_collect_tables(tok, nt, i, 1, &tabs);
            else if (strcmp(tok[i].s, "call") == 0 ||
                     strcmp(tok[i].s, "exec") == 0 ||
                     strcmp(tok[i].s, "join") == 0 ||
                     strcmp(tok[i].s, "straight_join") == 0 ||
                     (strcmp(tok[i].s, "truncate") == 0 && extra == 0))
                i = compact_collect_tables(tok, nt, i, 0, &tabs);
            continue;
        }

        if (strcmp(tok[i].s, "from") == 0)
            i = compact_collect_tables(tok, nt, i, 1, &tabs);
        else if (strcmp(tok[i].s, "into") == 0 ||
                 strcmp(tok[i].s, "table") == 0)
            i = compact_collect_tables(tok, nt, i, 0, &tabs);
    }

    if (cmds.n == 0 || tabs.n == 0)
        return 0;

    size_t w = 0;
    for (int pass = 0; pass < 2; pass++) {
        const struct compact_set *set = pass ? &tabs : &cmds;
        if (w + 2 < outsz) { out[w++] = '<'; out[w++] = '<'; }
        for (int k = 0; k < set->n; k++) {
            if (k && w + 1 < outsz)
                out[w++] = ',';
            for (const char *c = set->item[k]; *c && w + 1 < outsz; c++)
                out[w++] = *c;
        }
        if (w + 2 < outsz) { out[w++] = '>'; out[w++] = '>'; }
    }
    out[w] = '\0';
    return w;
}

uint8_t sql_compact_query_hash(const char *buf, size_t len)
{
    char canon[SQL_MAX_INPUT + 1];
    size_t n = sql_compact_query(buf, len, canon, sizeof(canon));
    return n ? djb2_8(canon, n) : 0;
}
