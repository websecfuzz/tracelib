#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "config.h"
#include "arghash.h"
#include "bitmap.h"

int main(void)
{
    struct config cfg;
    config_defaults(&cfg);
    config_from_env(&cfg);

    struct config old_cfg = cfg;
    old_cfg.excluded_file_path[0] = '\0';
    config_excluded_parse(&old_cfg);

    char line[8192], canon[256];
    while (fgets(line, sizeof line, stdin)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
            line[--n] = '\0';
        if (!n)
            continue;

        int old_kept = config_path_is_monitored(&old_cfg, line, n);
        unsigned old_hash = old_kept ? djb2_8(line, n) : 0;

        unsigned char nh = 0;
        int new_kept = arghash_path_hash(&cfg, line, n, &nh);

        size_t cn = arghash_canon_path(line, n, canon, sizeof canon);
        (void)cn;

        printf("%d\t%u\t%d\t%u\t%s\n", old_kept, old_hash, new_kept, (unsigned)nh, canon);
    }
    return 0;
}
