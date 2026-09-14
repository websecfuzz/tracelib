#ifndef TRACELIB_BITMAP_H
#define TRACELIB_BITMAP_H

#include <stddef.h>
#include <stdint.h>

#define TRACELIB_MAP_SIZE (1u << 16)

#define FILE_CHANNEL_SALT 0x9E37u

void bitmap_init(uint8_t *map);

void bitmap_record(uint8_t *map, uint32_t prev_sc, uint32_t curr_sc,
                   uint8_t arg_hash);

uint8_t djb2_8(const char *str, size_t len);

uint16_t djb2_16(const char *str, size_t len);

uint16_t bitmap_file_index(uint32_t prev_loc, uint16_t cur);

void bitmap_record_file_edge(uint8_t *map, uint32_t prev_loc, uint16_t cur);

uint16_t bitmap_path_loc(const char *path, size_t len);

#endif
