#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

#include "config.h"
#include "arghash.h"

struct mode { const char *name; void (*apply)(struct config *); };

static void m_ngram(struct config *c)     { c->coverage_mode = COV_NGRAM; }
static void m_bigram(struct config *c)    { c->coverage_mode = COV_BIGRAM; }
static void m_separated(struct config *c) { c->coverage_mode = COV_BIGRAM;
                                            c->bigram_file_sql_separated = 1; }
static void m_filtered(struct config *c)  { c->coverage_mode = COV_BIGRAM;
                                            c->file_sql_filtered = 1;
                                            c->file_sql_only = 1; }

int main(void)
{
    static const struct mode modes[] = {
        { "ngram",     m_ngram },
        { "bigram",    m_bigram },
        { "separated", m_separated },
        { "filtered",  m_filtered },
    };
    const int nmodes = (int)(sizeof(modes) / sizeof(modes[0]));

    printf("%-7s %-7s %-10s %-9s %s\n",
           "ngram", "bigram", "separated", "filtered", "buffer");

    char line[4096];
    while (fgets(line, sizeof line, stdin)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
            line[--n] = '\0';
        if (!n)
            continue;

        unsigned long args[6] = {0};
        args[0] = 3;
        args[1] = (unsigned long)line;
        args[2] = (unsigned long)n;

        for (int i = 0; i < nmodes; i++) {
            struct config cfg;
            config_defaults(&cfg);
            config_from_env(&cfg);
            modes[i].apply(&cfg);
            int kind = 0;
            unsigned h = compute_arg_hash_semantic(getpid(), __NR_write, args,
                                                   &cfg, &kind);
            printf("%-7u ", h);
            (void)kind;
        }
        printf("  %.80s\n", line);
    }
    return 0;
}
