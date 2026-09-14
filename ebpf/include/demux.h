#ifndef TRACELIB_DEMUX_H
#define TRACELIB_DEMUX_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include "config.h"

#define IDLE_FLUSH_MS 500

typedef void (*demux_start_cb)(void);
typedef void (*demux_finalize_cb)(uint8_t *map);

void demux_init(const struct config *cfg, demux_start_cb on_start, demux_finalize_cb on_finalize);

void demux_on_read(int fd, const char *buf, size_t len);

void demux_on_write(int fd, const char *buf, size_t len);

void demux_touch(void);

void demux_maybe_flush_idle(void);

void demux_shutdown(void);

uint8_t *demux_active_map(void);

size_t demux_find_header_value(const char *buf, size_t len,
                               const char *header_lc, size_t header_len,
                               char *out, size_t outcap);
int    demux_normalize_request_id(const char *value, char *out, size_t outcap);

#endif
