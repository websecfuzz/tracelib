#ifndef TRACELIB_BACKEND_H
#define TRACELIB_BACKEND_H

#include <stdint.h>
#include <signal.h>
#include "config.h"

struct collect_backend {
    const char *name;
    int  (*available)(void);
    int  (*start)(uint16_t port, const struct config *cfg);
    void (*run)(void);
    void (*stop)(void);
};

extern const struct collect_backend backend_ptrace;
extern const struct collect_backend backend_ebpf;

extern volatile sig_atomic_t g_should_stop;

#endif
