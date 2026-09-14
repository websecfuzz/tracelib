#ifndef TRACELIB_NGRAM_H
#define TRACELIB_NGRAM_H

#include <stdint.h>
#include "tracer.h"

void ngram_record(uint8_t *map, struct tracee *t, uint32_t sc, uint8_t arg_hash, int theta);

void ngram_fold_full_one(uint8_t *map, struct tracee *t);

#endif
