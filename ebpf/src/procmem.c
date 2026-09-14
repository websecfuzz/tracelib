#include "procmem.h"

#include <sys/uio.h>
#include <string.h>
#include <errno.h>

ssize_t pm_read(pid_t pid, uintptr_t addr, void *buf, size_t n)
{
    if (n == 0)
        return 0;
    struct iovec local  = { .iov_base = buf, .iov_len = n };
    struct iovec remote = { .iov_base = (void *)addr, .iov_len = n };
    ssize_t r = process_vm_readv(pid, &local, 1, &remote, 1, 0);
    return r < 0 ? 0 : r;
}

size_t pm_read_cstr(pid_t pid, uintptr_t addr, char *buf, size_t cap)
{
    if (cap == 0)
        return 0;
    size_t total = 0;
    buf[0] = '\0';

    while (total + 1 < cap) {
        size_t want = cap - 1 - total;
        if (want > 64) want = 64;
        ssize_t got = pm_read(pid, addr + total, buf + total, want);
        if (got <= 0)
            break;
        for (ssize_t i = 0; i < got; i++) {
            if (buf[total + i] == '\0') {
                return total + (size_t)i;
            }
        }
        total += (size_t)got;
        if ((size_t)got < want)
            break;
    }
    buf[total] = '\0';
    return total;
}

int pm_read_iovec0(pid_t pid, uintptr_t addr, uintptr_t *base, size_t *len)
{
    struct { uintptr_t base; size_t len; } io;
    if (pm_read(pid, addr, &io, sizeof(io)) != (ssize_t)sizeof(io))
        return -1;
    *base = io.base;
    *len  = io.len;
    return 0;
}

int pm_read_sockaddr_port(pid_t pid, uintptr_t addr, uint16_t *port)
{

    unsigned char b[4];
    if (pm_read(pid, addr, b, sizeof(b)) != (ssize_t)sizeof(b))
        return -1;
    *port = (uint16_t)((b[2] << 8) | b[3]);
    return 0;
}
