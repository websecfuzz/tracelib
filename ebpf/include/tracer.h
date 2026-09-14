#ifndef TRACELIB_TRACER_H
#define TRACELIB_TRACER_H

#include <stdint.h>
#include <sys/types.h>
#include "cov_shared.h"

#define MAX_TRACED 4096

struct tracee {
    pid_t    pid;
    uint32_t prev_syscall;
    uint8_t  prev_arg_hash;
    uint16_t prev_loc;

    uint16_t ring[RING_CAP];
    int      ring_count;
    int      ring_head;
    uint32_t full_hash;
    int      participated;
};

struct tracee *tracer_get(pid_t pid);
struct tracee *tracer_add(pid_t pid);
void           tracer_remove(pid_t pid);
int            tracer_count(void);

void           tracer_reset_one(struct tracee *t);

void           tracer_reset_all_prev_syscall(void);

void           tracer_fold_full_all(uint8_t *map);

int  tracer_attach_all_tids(pid_t pid);

int  tracer_attach_one(pid_t tid);

#endif
