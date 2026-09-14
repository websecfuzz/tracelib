#include "bitmap.h"
#include "util.h"

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

uint8_t djb2_8(const char *s, size_t n)
{
    uint32_t h = 5381u;
    for (size_t i = 0; i < n; i++)
        h = ((h << 5) + h) ^ (uint8_t)s[i];
    return (uint8_t)(h & 0xFFu);
}

uint16_t djb2_16(const char *s, size_t n)
{
    uint32_t h = 5381u;
    for (size_t i = 0; i < n; i++)
        h = ((h << 5) + h) ^ (uint8_t)s[i];
    return (uint16_t)(h & 0xFFFFu);
}

void bitmap_record_bigram(uint8_t *map, uint32_t prev_sc, uint32_t curr_sc, uint8_t arg_hash)
{
    uint16_t idx = (uint16_t)(((prev_sc & 0xFF) << 8) ^ (curr_sc & 0xFF) ^ arg_hash);
    hit(map, idx);
}

void bitmap_record_bigram_pred(uint8_t *map, uint32_t prev_sc, uint8_t prev_arg_hash,
                               uint32_t curr_sc, uint8_t curr_arg_hash)
{
    uint16_t idx = (uint16_t)((((prev_sc ^ prev_arg_hash) & 0xFF) << 8) ^
                              (curr_sc & 0xFF) ^ curr_arg_hash);
    hit(map, idx);
}

int reqmap_open(struct reqmap *out, const char *id)
{
    char path[160];

    out->map = NULL;
    out->fd = -1;
    out->id[0] = '\0';

    snprintf(path, sizeof(path), "/dev/shm/%s", id);
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        LOGE("open(%s): %s", path, strerror(errno));
        return -1;
    }
    if (ftruncate(fd, MAP_SIZE) != 0) {
        LOGE("ftruncate(%s): %s", path, strerror(errno));
        close(fd);
        return -1;
    }
    void *m = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) {
        LOGE("mmap(%s): %s", path, strerror(errno));
        close(fd);
        return -1;
    }
    memset(m, 0, MAP_SIZE);

    out->map = (uint8_t *)m;
    out->fd = fd;
    snprintf(out->id, sizeof(out->id), "%s", id);
    return 0;
}

void reqmap_close(struct reqmap *rm)
{
    if (!rm->map)
        return;
    msync(rm->map, MAP_SIZE, MS_SYNC);
    munmap(rm->map, MAP_SIZE);
    if (rm->fd >= 0)
        close(rm->fd);
    rm->map = NULL;
    rm->fd = -1;
    rm->id[0] = '\0';
}

void bitmap_record_bigram_separated(uint8_t *map, uint32_t prev_sc, uint32_t curr_sc,
                                    uint8_t arg_hash, int is_semantic)
{
    hit(map, bigram_upper_index(prev_sc, curr_sc));
    if (is_semantic)
        hit(map, bigram_lower_index(prev_sc, curr_sc, arg_hash));
}

size_t bitmap_prune_upper_half(uint8_t *map, unsigned min_hits)
{
    size_t kept = 0;
    if (min_hits <= 1) {
        for (size_t i = MAP_HALF; i < MAP_SIZE; i++)
            if (map[i])
                kept++;
        return kept;
    }
    for (size_t i = MAP_HALF; i < MAP_SIZE; i++) {
        if (!map[i])
            continue;
        if (map[i] < min_hits)
            map[i] = 0;
        else
            kept++;
    }
    return kept;
}

size_t bitmap_keep_top_edges(uint8_t *map, size_t n)
{
    if (n == 0)
        return 0;

    size_t hist[256];
    memset(hist, 0, sizeof(hist));
    size_t nonzero = 0;
    for (size_t i = 0; i < MAP_SIZE; i++) {
        if (map[i]) {
            hist[map[i]]++;
            nonzero++;
        }
    }
    if (nonzero <= n)
        return nonzero;

    size_t above = 0;
    unsigned cut = 0;
    for (unsigned v = 255; v >= 1; v--) {
        if (above + hist[v] >= n) {
            cut = v;
            break;
        }
        above += hist[v];
    }
    size_t allow_at_cut = n - above;

    size_t kept = 0;
    for (size_t i = 0; i < MAP_SIZE; i++) {
        uint8_t v = map[i];
        if (!v)
            continue;
        if (v > cut) {
            kept++;
            continue;
        }
        if (v == cut && allow_at_cut > 0) {
            allow_at_cut--;
            kept++;
            continue;
        }
        map[i] = 0;
    }
    return kept;
}

size_t bitmap_count_nonzero(const uint8_t *map)
{
    size_t n = 0;
    for (size_t i = 0; i < MAP_SIZE; i++)
        if (map[i])
            n++;
    return n;
}
