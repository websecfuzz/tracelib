#ifndef TRACELIB_TRACER_H
#define TRACELIB_TRACER_H

#include <stdint.h>
#include <sys/types.h>

int tracer_attach(pid_t pid);

int tracer_register(pid_t pid);

void tracer_unregister(pid_t pid);

int tracer_count(void);

int tracer_syscall_is_entry(pid_t pid);

uint32_t tracer_get_prev_syscall(pid_t pid);
void     tracer_set_prev_syscall(pid_t pid, uint32_t nr);

uint32_t tracer_get_prev_loc(pid_t pid);
void     tracer_set_prev_loc(pid_t pid, uint32_t loc);

void tracer_reset_all_prev_chains(void);

int tracer_is_traced(pid_t pid);

int tracer_set_options(pid_t pid);

#endif
