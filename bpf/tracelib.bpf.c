#include "bpf_helpers_min.h"
#include "tl_ebpf.h"

char LICENSE[] SEC("license") = "GPL";

#define TL_NR_read      0
#define TL_NR_write     1
#define TL_NR_open      2
#define TL_NR_writev    20
#define TL_NR_connect   42
#define TL_NR_sendto    44
#define TL_NR_recvfrom  45
#define TL_NR_execve    59
#define TL_NR_openat    257
#define TL_NR_openat2   437

struct sys_enter_args {
    unsigned long long _common;
    long id;
    unsigned long args[6];
};
struct sys_exit_args {
    unsigned long long _common;
    long id;
    long ret;
};
struct sched_fork_args {
    unsigned long long _common;
    char parent_comm[16];
    int  parent_pid;
    char child_comm[16];
    int  child_pid;
};
struct sched_exit_args {
    unsigned long long _common;
    char comm[16];
    int  pid;
    int  prio;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 16 * 1024 * 1024);
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 8192);
    __type(key, __u32);
    __type(value, __u8);
} watched_tgids SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 8192);
    __type(key, __u32);
    __type(value, __u64);
} rd_bufs SEC(".maps");

static __always_inline void emit_plain(__u32 tid, __u32 tgid, long nr,
                                       int fd, __u32 flags)
{
    struct tl_event *e = bpf_ringbuf_reserve(&events, TL_EVENT_HDR_SIZE, 0);
    if (!e)
        return;
    e->tid = tid;
    e->tgid = tgid;
    e->nr = (int)nr;
    e->fd = fd;
    e->ret = 0;
    e->flags = flags;
    e->payload_len = 0;
    bpf_ringbuf_submit(e, 0);
}

static __always_inline void emit_user(__u32 tid, __u32 tgid, long nr, int fd,
                                      __s64 ret, __u32 flags,
                                      const void *src, unsigned long len)
{
    struct tl_event *e = bpf_ringbuf_reserve(&events, sizeof(struct tl_event), 0);
    if (!e)
        return;
    e->tid = tid;
    e->tgid = tgid;
    e->nr = (int)nr;
    e->fd = fd;
    e->ret = ret;
    e->flags = flags | TL_F_HASPAYLOAD;

    __u32 n = 0;
    if (src && len) {
        n = (len > TL_PAYLOAD_MAX) ? TL_PAYLOAD_MAX : (__u32)len;
        if (bpf_probe_read_user(e->payload, n, src) != 0)
            n = 0;
    }
    e->payload_len = n;
    bpf_ringbuf_submit(e, 0);
}

static __always_inline void emit_user_str(__u32 tid, __u32 tgid, long nr,
                                          const void *src)
{
    struct tl_event *e = bpf_ringbuf_reserve(&events, sizeof(struct tl_event), 0);
    if (!e)
        return;
    e->tid = tid;
    e->tgid = tgid;
    e->nr = (int)nr;
    e->fd = -1;
    e->ret = 0;
    e->flags = TL_F_ENTRY | TL_F_HASPAYLOAD;

    long r = -1;
    if (src)
        r = bpf_probe_read_user_str(e->payload, TL_PAYLOAD_MAX, src);

    if (r <= 0)
        e->payload_len = 0;
    else
        e->payload_len = (r > (long)TL_PAYLOAD_MAX) ? TL_PAYLOAD_MAX : (__u32)r;
    bpf_ringbuf_submit(e, 0);
}

SEC("tracepoint/raw_syscalls/sys_enter")
int tl_sys_enter(struct sys_enter_args *ctx)
{
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32;
    __u32 tid = (__u32)pt;
    if (!bpf_map_lookup_elem(&watched_tgids, &tgid))
        return 0;

    long nr = ctx->id;
    unsigned long a0 = ctx->args[0];
    unsigned long a1 = ctx->args[1];
    unsigned long a2 = ctx->args[2];

    switch (nr) {
    case TL_NR_read:
    case TL_NR_recvfrom: {

        __u64 bufp = a1;
        bpf_map_update_elem(&rd_bufs, &tid, &bufp, BPF_ANY);
        emit_plain(tid, tgid, nr, (int)a0, TL_F_ENTRY);
        return 0;
    }
    case TL_NR_write:
    case TL_NR_sendto:
        emit_user(tid, tgid, nr, (int)a0, 0, TL_F_ENTRY, (const void *)a1, a2);
        return 0;
    case TL_NR_writev: {

        struct { unsigned long base; unsigned long len; } iov0 = {};
        bpf_probe_read_user(&iov0, sizeof(iov0), (const void *)a1);
        emit_user(tid, tgid, nr, (int)a0, 0, TL_F_ENTRY,
                  (const void *)iov0.base, iov0.len);
        return 0;
    }
    case TL_NR_open:
    case TL_NR_execve:
        emit_user_str(tid, tgid, nr, (const void *)a0);
        return 0;
    case TL_NR_openat:
    case TL_NR_openat2:
        emit_user_str(tid, tgid, nr, (const void *)a1);
        return 0;
    case TL_NR_connect:
        emit_user(tid, tgid, nr, (int)a0, 0, TL_F_ENTRY, (const void *)a1, a2);
        return 0;
    default:
        emit_plain(tid, tgid, nr, -1, TL_F_ENTRY);
        return 0;
    }
}

SEC("tracepoint/raw_syscalls/sys_exit")
int tl_sys_exit(struct sys_exit_args *ctx)
{
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32;
    __u32 tid = (__u32)pt;
    if (!bpf_map_lookup_elem(&watched_tgids, &tgid))
        return 0;

    long nr = ctx->id;
    if (nr != TL_NR_read && nr != TL_NR_recvfrom)
        return 0;

    __u64 *bufp = bpf_map_lookup_elem(&rd_bufs, &tid);
    long ret = ctx->ret;
    if (bufp && ret > 0) {

        emit_user(tid, tgid, nr, -1, ret, 0, (const void *)*bufp,
                  (unsigned long)ret);
    }
    bpf_map_delete_elem(&rd_bufs, &tid);
    return 0;
}

SEC("tracepoint/sched/sched_process_fork")
int tl_fork(struct sched_fork_args *ctx)
{
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 parent_tgid = pt >> 32;
    if (!bpf_map_lookup_elem(&watched_tgids, &parent_tgid))
        return 0;
    __u32 child = (__u32)ctx->child_pid;
    __u8 one = 1;
    bpf_map_update_elem(&watched_tgids, &child, &one, BPF_ANY);
    return 0;
}

SEC("tracepoint/sched/sched_process_exit")
int tl_exit(struct sched_exit_args *ctx)
{
    (void)ctx;
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32;
    __u32 tid = (__u32)pt;
    if (!bpf_map_lookup_elem(&watched_tgids, &tgid))
        return 0;
    bpf_map_delete_elem(&rd_bufs, &tid);

    emit_plain(tid, tgid, -1, -1, TL_F_TASK_EXIT);
    if (tid == tgid)
        bpf_map_delete_elem(&watched_tgids, &tgid);
    return 0;
}
