#include "ebpf_replay.h"

#include "bitmap.h"
#include "demux.h"
#include "sql_detect.h"
#include "tracer.h"

#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/types.h>

static int g_no_arg_hash;
static int g_no_sql;
static int g_filter;
static int g_file_edges;

void tl_replay_config(int no_arg_hash, int no_sql, int syscall_filter,
                      int file_edges)
{
    g_no_arg_hash = no_arg_hash;
    g_no_sql      = no_sql;
    g_filter      = syscall_filter;
    g_file_edges  = file_edges;
}

static int syscall_is_interesting(long nr)
{
    switch (nr) {
    case SYS_open:
    case SYS_openat:
    case SYS_execve:
    case SYS_connect:
    case SYS_write:
    case SYS_writev:
    case SYS_sendto:
    case SYS_read:
    case SYS_recvfrom:
        return 1;
    default:
        return 0;
    }
}

static size_t path_len(const char *p, size_t n)
{
    if (n && p[n - 1] == '\0') n--;
    return n;
}

static int port_from_sockaddr(const char *b, size_t n)
{
    if (n < 4) return -1;
    unsigned short fam;
    memcpy(&fam, b, sizeof fam);
    if ((fam == AF_INET || fam == AF_INET6) && n >= 8) {
        unsigned short p;
        memcpy(&p, b + 2, sizeof p);
        return (int)ntohs(p);
    }
    return -1;
}

static uint8_t arg_hash_from_payload(long nr, const char *pl, size_t len)
{
    switch (nr) {
    case SYS_open:
    case SYS_openat:
    case SYS_execve:
        if (g_no_arg_hash || !pl) return 0;
        { size_t l = path_len(pl, len); return l ? djb2_8(pl, l) : 0; }
    case SYS_connect:
        if (g_no_arg_hash || !pl) return 0;
        { int port = port_from_sockaddr(pl, len);
          return port < 0 ? 0 : (uint8_t)(port & 0xFF); }
    case SYS_write:
    case SYS_sendto:
    case SYS_writev:
        if (g_no_sql || !pl) return 0;
        return detect_sql_hash_local(pl, len);
    default:
        return 0;
    }
}

void tl_replay_event(const struct tl_event *e)
{
    if (!e) return;

    if (e->flags & TL_F_TASK_EXIT) {
        tracer_unregister((pid_t)e->tid);
        return;
    }

    const char *pl = (e->flags & TL_F_HASPAYLOAD) ? (const char *)e->payload
                                                   : NULL;
    size_t pl_len = e->payload_len;

    if (!(e->flags & TL_F_ENTRY)) {

        if (e->nr == SYS_read || e->nr == SYS_recvfrom)
            demux_on_read_buf(e->fd, pl, pl_len);
        return;
    }

    if (!tracer_is_traced((pid_t)e->tid))
        tracer_register((pid_t)e->tid);

    switch (e->nr) {
    case SYS_write:
    case SYS_sendto:
    case SYS_writev:
        demux_on_write_buf(e->fd, pl, pl_len);
        break;
    default:
        break;
    }

    uint8_t *bm = demux_active_bitmap();
    uint32_t prev_sc = tracer_get_prev_syscall((pid_t)e->tid);

    int record = (bm != NULL);
    if (record && g_filter && !syscall_is_interesting(e->nr))
        record = 0;
    if (record) {
        uint8_t ah = arg_hash_from_payload(e->nr, pl, pl_len);
        bitmap_record(bm, prev_sc, (uint32_t)e->nr, ah);
    }

    if (g_file_edges && bm) {
        int is_open = (e->nr == SYS_open || e->nr == SYS_openat);
#ifdef SYS_openat2
        if (e->nr == SYS_openat2) is_open = 1;
#endif
        if (is_open && pl) {
            size_t l = path_len(pl, pl_len);
            uint16_t cur = bitmap_path_loc(pl, l);
            bitmap_record_file_edge(bm, tracer_get_prev_loc((pid_t)e->tid), cur);
            tracer_set_prev_loc((pid_t)e->tid, cur);
        }
    }

    tracer_set_prev_syscall((pid_t)e->tid, (uint32_t)e->nr);
}
