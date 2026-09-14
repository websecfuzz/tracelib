#include "ngram.h"
#include "bitmap.h"

static uint32_t fnv_window(const struct tracee *t, int k)
{
    uint32_t h = FNV_OFFSET;
    for (int j = 0; j < k; j++) {
        int idx = (t->ring_head - k + j + RING_CAP) % RING_CAP;
        h = (h ^ t->ring[idx]) * FNV_PRIME;
    }
    return h;
}

void ngram_record(uint8_t *map, struct tracee *t, uint32_t sc, uint8_t arg_hash, int theta)
{
    uint16_t token = COV_TOKEN(sc, arg_hash);

    t->ring[t->ring_head] = token;
    t->ring_head = (t->ring_head + 1) % RING_CAP;
    if (t->ring_count < RING_CAP)
        t->ring_count++;
    t->participated = 1;

    t->full_hash = (t->full_hash ^ token) * FNV_PRIME;

    if (t->ring_count >= theta) {
        uint32_t h = fnv_window(t, theta);
        hit(map, (uint16_t)((h ^ SALT_THETA) & 0xFFFF));
    }

    if (t->ring_count >= 2 * theta) {
        uint32_t h = fnv_window(t, 2 * theta);
        hit(map, (uint16_t)((h ^ SALT_2THETA) & 0xFFFF));
    }
}

void ngram_fold_full_one(uint8_t *map, struct tracee *t)
{
    if (!t->participated)
        return;
    hit(map, (uint16_t)((t->full_hash ^ SALT_FULL) & 0xFFFF));
}
