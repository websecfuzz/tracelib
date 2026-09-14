#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sql_detect.h"
#include "bitmap.h"

int main(void)
{
    const char *v = getenv("TRACELIB_SQL_COMPACT");
    int compact = v ? (atoi(v) != 0) : 1;

    char line[8192], out[512];
    while (fgets(line, sizeof line, stdin)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
            line[--n] = '\0';
        if (!n)
            continue;
        size_t rn = compact ? sql_compact_query(line, n, out, sizeof out)
                            : sql_query_reduced(line, n, out, sizeof out);
        if (!rn) {
            printf("-\t\n");
            continue;
        }
        printf("%u\t%s\n", (unsigned)djb2_8(out, rn), out);
    }
    return 0;
}
