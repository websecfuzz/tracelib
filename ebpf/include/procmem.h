#ifndef TRACELIB_PROCMEM_H
#define TRACELIB_PROCMEM_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

ssize_t pm_read(pid_t pid, uintptr_t addr, void *buf, size_t n);

size_t  pm_read_cstr(pid_t pid, uintptr_t addr, char *buf, size_t cap);

int     pm_read_iovec0(pid_t pid, uintptr_t addr, uintptr_t *base, size_t *len);

int     pm_read_sockaddr_port(pid_t pid, uintptr_t addr, uint16_t *port);

#endif
