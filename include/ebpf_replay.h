#ifndef TRACELIB_EBPF_REPLAY_H
#define TRACELIB_EBPF_REPLAY_H

#include "tl_ebpf.h"

void tl_replay_config(int no_arg_hash, int no_sql, int syscall_filter,
                      int file_edges);

void tl_replay_event(const struct tl_event *e);

#endif
