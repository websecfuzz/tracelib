#ifndef TRACELIB_BITMAP_H
#define TRACELIB_BITMAP_H

#include <stdint.h>
#include <stddef.h>
#include "cov_shared.h"

static inline void hit(uint8_t *map, uint16_t idx)
{
    if (map[idx] != 0xFF)
        map[idx]++;
}

uint8_t  djb2_8 (const char *s, size_t n);
uint16_t djb2_16(const char *s, size_t n);

void bitmap_record_bigram(uint8_t *map, uint32_t prev_sc, uint32_t curr_sc, uint8_t arg_hash);

void bitmap_record_bigram_pred(uint8_t *map, uint32_t prev_sc, uint8_t prev_arg_hash,
                               uint32_t curr_sc, uint8_t curr_arg_hash);

struct reqmap {
    uint8_t *map;
    int      fd;
    char     id[128];
};

int  reqmap_open(struct reqmap *out, const char *id);

void reqmap_close(struct reqmap *rm);

#define MAP_HALF (MAP_SIZE / 2u)

static inline uint16_t bigram_upper_index(uint32_t prev_sc, uint32_t curr_sc)
{
    uint16_t raw = (uint16_t)((((prev_sc & 0xFFu) << 8) ^ (curr_sc & 0xFFu)));
    return (uint16_t)(MAP_HALF + (uint16_t)((raw ^ (raw >> 15)) & (MAP_HALF - 1u)));
}

static inline uint16_t bigram_lower_index(uint32_t prev_sc, uint32_t curr_sc,
                                          uint8_t arg_hash)
{
    uint16_t raw = (uint16_t)((((prev_sc & 0xFFu) << 8) ^ (curr_sc & 0xFFu) ^ arg_hash));
    return (uint16_t)((raw ^ (raw >> 15)) & (MAP_HALF - 1u));
}

void bitmap_record_bigram_separated(uint8_t *map, uint32_t prev_sc, uint32_t curr_sc,
                                    uint8_t arg_hash, int is_semantic);

size_t bitmap_prune_upper_half(uint8_t *map, unsigned min_hits);

size_t bitmap_keep_top_edges(uint8_t *map, size_t n);

size_t bitmap_count_nonzero(const uint8_t *map);

#endif
