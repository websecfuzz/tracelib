#ifndef TRACELIB_DEMUX_H
#define TRACELIB_DEMUX_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "bitmap.h"

void demux_init(const char *header_name);

uint8_t *demux_active_bitmap(void);

int demux_has_active_request(void);

void demux_on_write(pid_t pid, int fd, unsigned long buf_addr, size_t buf_len);

void demux_on_read(pid_t pid, int fd, unsigned long buf_addr, size_t buf_len);

void demux_on_write_buf(int fd, const char *buf, size_t buf_len);
void demux_on_read_buf(int fd, const char *buf, size_t buf_len);

void demux_touch(void);

int demux_maybe_flush_idle(unsigned idle_ms);

int demux_finalise(void);

void demux_begin_request(const char *request_id);

#endif
