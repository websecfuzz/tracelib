#ifndef TRACELIB_ARGHASH_H
#define TRACELIB_ARGHASH_H

#include <stdint.h>
#include <sys/types.h>
#include "config.h"

enum arg_semantic_kind {
    ARG_SEMANTIC_NONE = 0,
    ARG_SEMANTIC_FILE_PATH,
    ARG_SEMANTIC_SQL,
};

uint8_t compute_arg_hash(pid_t pid, long sc, const unsigned long args[6], const struct config *cfg);

uint8_t compute_arg_hash_semantic(pid_t pid, long sc, const unsigned long args[6],
                                  const struct config *cfg, int *kind);

int     arghash_is_open_family(long sc);

size_t  arghash_canon_path(const char *in, size_t inlen, char *out, size_t cap);

int     arghash_path_hash(const struct config *cfg, const char *path, size_t n, uint8_t *out);

uint16_t file_edge_loc(pid_t pid, long sc, const unsigned long args[6]);

#endif
