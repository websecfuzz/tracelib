#ifndef TRACELIB_PID_DISCOVERY_H
#define TRACELIB_PID_DISCOVERY_H

#include <stdint.h>
#include <sys/types.h>

int pid_discover(uint16_t port, pid_t **out);

#endif
