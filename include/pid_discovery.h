#ifndef TRACELIB_PID_DISCOVERY_H
#define TRACELIB_PID_DISCOVERY_H

#include <stdint.h>
#include <sys/types.h>

int discover_pids(uint16_t port, pid_t *out_pids, int max_pids);

#endif
