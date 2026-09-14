#include "bitmap.h"

#include <ctype.h>
#include <string.h>

void bitmap_init(uint8_t *map)
{
    memset(map, 0, TRACELIB_MAP_SIZE);
}

void bitmap_record(uint8_t *map, uint32_t prev_sc, uint32_t curr_sc,
                   uint8_t arg_hash)
{
    uint16_t idx = (uint16_t)(
        ((prev_sc & 0xFFu) << 8) ^
         (curr_sc & 0xFFu) ^
         (uint32_t)arg_hash
    );
    if (map[idx] != 0xFF) {
        map[idx]++;
    }
}

uint8_t djb2_8(const char *str, size_t len)
{
    uint32_t h = 5381u;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)str[i];
        if (c == 0) break;
        h = ((h << 5) + h) ^ c;
    }
    return (uint8_t)(h & 0xFFu);
}

uint16_t djb2_16(const char *str, size_t len)
{
    uint32_t h = 5381u;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)str[i];
        if (c == 0) break;
        h = ((h << 5) + h) ^ c;
    }
    return (uint16_t)(h & 0xFFFFu);
}

uint16_t bitmap_file_index(uint32_t prev_loc, uint16_t cur)
{
    uint32_t idx = ((prev_loc >> 1) ^ (uint32_t)cur) ^ (uint32_t)FILE_CHANNEL_SALT;
    return (uint16_t)(idx & 0xFFFFu);
}

void bitmap_record_file_edge(uint8_t *map, uint32_t prev_loc, uint16_t cur)
{
    uint16_t idx = bitmap_file_index(prev_loc, cur);
    if (map[idx] != 0xFF) {
        map[idx]++;
    }
}

static int component_is_variable(const char *s, size_t n)
{
    if (n == 0) return 0;
    size_t digits = 0, hexes = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (isdigit(c)) digits++;
        if (isxdigit(c)) hexes++;
    }
    if (digits == n) return 1;
    if (n >= 16 && hexes == n) return 1;
    return 0;
}

static size_t canonicalize_path(const char *in, size_t inlen,
                                char *out, size_t outcap)
{
    if (outcap == 0) return 0;

    size_t n = 0;
    while (n < inlen && in[n] != '\0') n++;

    size_t o = 0, i = 0;
    while (i < n && o + 1 < outcap) {
        if (in[i] == '/') { out[o++] = '/'; i++; continue; }
        size_t j = i;
        while (j < n && in[j] != '/') j++;
        if (component_is_variable(in + i, j - i)) {
            out[o++] = '#';
        } else {
            for (size_t k = i; k < j && o + 1 < outcap; k++) out[o++] = in[k];
        }
        i = j;
    }
    out[o] = '\0';
    return o;
}

uint16_t bitmap_path_loc(const char *path, size_t len)
{
    char canon[512];
    size_t cn = canonicalize_path(path, len, canon, sizeof canon);
    return djb2_16(canon, cn);
}
