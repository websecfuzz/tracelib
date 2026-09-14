#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
#include "cov_shared.h"

char LICENSE[] SEC("license") = "GPL";

#define SYS_read     0
#define SYS_write    1
#define SYS_open     2
#define SYS_close    3
#define SYS_writev   20
#define SYS_connect  42
#define SYS_sendto   44
#define SYS_recvfrom 45
#define SYS_clone    56
#define SYS_fork     57
#define SYS_vfork    58
#define SYS_execve   59
#define SYS_openat   257
#define SYS_openat2  437

#define SCAN_MAX   4096
#define ARG_SCAN_MAX 64

#ifndef barrier_var
#define barrier_var(var) asm volatile("" : "+r"(var))
#endif
#define ID_MAX     128
#define EV_START   1
#define EV_END     2
#define EV_RAW     3
#define EV_FILE_SQL 4
#define RAW_DETAIL_MAX 128

enum raw_detail_kind {
    RAW_DETAIL_NONE = 0,
    RAW_DETAIL_PATH = 1,
    RAW_DETAIL_BUFFER = 2,
    RAW_DETAIL_SOCKADDR = 3,
};

const volatile __u32 cfg_theta      = DEFAULT_THETA;
const volatile __u8  cfg_cov_mode   = 0;
const volatile __u32 cfg_hdr_len    = 12;
const volatile char  cfg_hdr_lc[32] = "x-request-id";
const volatile __u8  cfg_no_arg_hash = 0;
const volatile __u8  cfg_no_sql      = 0;
const volatile __u8  cfg_file_sql_only = 0;
const volatile __u8  cfg_file_sql_filtered = 0;
const volatile __u8  cfg_bigram_separated = 0;
const volatile __u8  cfg_end_on_status = 1;
const volatile __u32 cfg_monitored_len = 0;
const volatile char  cfg_monitored_path[FILE_PATH_MONITORED_MAX] = DEFAULT_FILE_PATH_MONITORED;
const volatile __u8  cfg_file_sql_unfiltered = 0;

const volatile __u8  cfg_file_sql_pred_args = 0;

const volatile __u8  cfg_sql_compact = 0;
const volatile __u8  cfg_syscall_filter = 0;
const volatile __u8  cfg_syscall_filter_file = 0;
const volatile __u8  cfg_mask_sql    = 1;
const volatile __u8  cfg_mask_open   = 1;
const volatile __u8  cfg_mask_conn   = 1;
const volatile __u8  cfg_raw_trace   = 0;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, __u32);
    __type(value, __u8);
} target_tgids SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 512);
    __type(key, __u32);
    __type(value, __u8);
} allowed_syscalls SEC(".maps");

struct tstate {
    __u16 ring[RING_CAP];
    __u64 rd_buf;
    __u32 ring_count;
    __u32 ring_head;
    __u32 full_hash;
    __u32 epoch;
    __s32 rd_fd;
    __u32 participated;
    __u32 prev_syscall;

    __u32 prev_arg;
};
#define PREV_ARG_DEFERRED 0x100u
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 8192);
    __type(key, __u32);
    __type(value, struct tstate);
} tstates SEC(".maps");

struct bitmap_blob { __u8 b[2 * MAP_SIZE]; };
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct bitmap_blob);
    __uint(map_flags, BPF_F_MMAPABLE);
} bitmap SEC(".maps");

struct ctrl {
    __u32 active_idx;
    __u32 epoch;
    __u32 active;
    __s32 req_fd;
    __u32 id_hash;
};
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct ctrl);
} ctrl_map SEC(".maps");

struct scratch {
    char buf[SCAN_MAX];
};
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct scratch);
} scratch_map SEC(".maps");

struct event {
    __u32 type;
    __u32 idx;
    __u32 epoch;
    __u32 id_hash;
    __u32 vstart;
    __u32 vlen;
    char  payload[SCAN_MAX];
};

struct raw_event {
    __u32 type;
    __u32 epoch;
    __u64 ktime_ns;
    __u32 tid;
    __u32 tgid;
    __s64 nr;
    __u64 args[6];
    __u32 arg_hash;
    __u32 detail_kind;
    __u32 detail_len;
    __u32 detail_total_len;
    char  detail[RAW_DETAIL_MAX];
};

enum file_sql_semantic_kind {
    FILE_SQL_PATH = 1,
    FILE_SQL_BUFFER = 2,

    FILE_SQL_EDGE_BUFFER = 3,

    FILE_SQL_EDGE_AFTER_SQL = 4,
};

struct file_sql_event {
    __u32 type, epoch, tid, semantic_kind;
    __s64 nr;
    __u32 arg_hash, data_len;
    __u32 prev_syscall;

    __u32 prev_arg;
    char data[FILE_SQL_DATA_MAX];
};
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);

    __uint(max_entries, 1 << 23);
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} raw_drops SEC(".maps");

static __always_inline struct ctrl *ctrl_get(void)
{
    __u32 z = 0;
    return bpf_map_lookup_elem(&ctrl_map, &z);
}

static __always_inline struct scratch *scratch_get(void)
{
    __u32 z = 0;
    return bpf_map_lookup_elem(&scratch_map, &z);
}

static __always_inline char lc(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

static __always_inline void hit_cell(__u32 active_idx, __u32 cell)
{
    __u32 z = 0;
    struct bitmap_blob *bb = bpf_map_lookup_elem(&bitmap, &z);
    if (!bb)
        return;

    __u32 off = ((active_idx ? MAP_SIZE : 0u) + (cell & 0xFFFFu)) & (2u * MAP_SIZE - 1u);
    if (bb->b[off] != 0xFF)
        bb->b[off]++;
}

static __always_inline __u32 read_user_bounded(char *dst, __u64 src, __u32 want)
{
    if (want > SCAN_MAX - 1) want = SCAN_MAX - 1;
    if (want == 0) return 0;

    barrier_var(want);
    want &= (SCAN_MAX - 1);
    if (bpf_probe_read_user(dst, want, (void *)src) != 0) return 0;
    return want;
}

static __always_inline void tstate_zero(struct tstate *z)
{
    #pragma unroll
    for (int i = 0; i < RING_CAP; i++) z->ring[i] = 0;
    z->rd_buf = 0; z->ring_count = 0; z->ring_head = 0;
    z->full_hash = 0; z->epoch = 0; z->rd_fd = 0; z->participated = 0;
    z->prev_syscall = 0; z->prev_arg = 0;
}

#define NOINLINE __always_inline

static NOINLINE __u8 sql_bpf_hash(const char *s, __u32 n)
{

    __u32 vs = 0; int found = 0;
    #pragma unroll
    for (__u32 t = 0; t < 8; t++) {
        if (!found && t < n) {
            char c = s[t & (SCAN_MAX - 1)];
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') { vs = t; found = 1; }
        }
    }
    if (!found || vs >= n) return 0;
    char v0 = lc(s[vs & (SCAN_MAX - 1)]);
    if (v0 != 's' && v0 != 'i' && v0 != 'u' && v0 != 'd' &&
        v0 != 'c' && v0 != 'r' && v0 != 'a' && v0 != 'e')
        return 0;

    __u32 h = 5381u;
    int in_q = 0; char q = 0;
    #pragma unroll
    for (__u32 k = 0; k < ARG_SCAN_MAX; k++) {
        if (k < n) {
            char c = s[k & (SCAN_MAX - 1)];
            if (in_q) {
                if (c == q) in_q = 0;
            } else if (c == '\'' || c == '"') {
                in_q = 1; q = c;
            } else if (c >= '0' && c <= '9') {

            } else {
                if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
                if ((c >= 'a' && c <= 'z') || c == '_' ||
                    c == '=' || c == '<' || c == '>' || c == '(' || c == ')' ||
                    c == ',' || c == '.' || c == '*')
                    h = ((h << 5) + h) ^ (__u8)c;
            }
        }
    }
    return (__u8)(h & 0xFFu);
}

static __always_inline int bpf_is_alpha(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static __always_inline char bpf_lc(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : c;
}

static __always_inline int path_is_monitored(const char *path, __u32 len)
{

    __u32 plen = cfg_monitored_len;
    if (plen == 0)
        return 1;
    if (plen > FILE_PATH_MONITORED_MAX)
        plen = FILE_PATH_MONITORED_MAX;
    if (len < plen)
        return 0;
    #pragma unroll
    for (__u32 i = 0; i < FILE_PATH_MONITORED_MAX; i++) {
        if (i >= plen)
            break;
        if (path[i & (SCAN_MAX - 1)] != cfg_monitored_path[i])
            return 0;
    }
    if (len == plen)
        return 1;
    return path[plen & (SCAN_MAX - 1)] == '/';
}

static NOINLINE __u8 djb2_8_buf(const char *s, __u32 n)
{
    __u32 h = 5381u;
    #pragma unroll
    for (__u32 i = 0; i < ARG_SCAN_MAX; i++) {
        if (i < n)
            h = ((h << 5) + h) ^ (__u8)s[i & (SCAN_MAX - 1)];
    }
    return (__u8)(h & 0xFFu);
}

static __always_inline __u64 path_arg_ptr(long sc, const __u64 *a)
{
    if (sc == SYS_open || sc == SYS_execve)
        return a[0];
    if (sc == SYS_openat || sc == SYS_openat2)
        return a[1];
    return 0;
}

static __always_inline int path_arg_monitored(long sc, const __u64 *a, struct scratch *s)
{
    __u64 ptr = path_arg_ptr(sc, a);
    if (!ptr)
        return 0;
    long n = bpf_probe_read_user_str(s->buf, SCAN_MAX, (void *)ptr);
    if (n <= 1)
        return 0;
    return path_is_monitored(s->buf, (__u32)(n - 1));
}

static __always_inline __u16 arg_hash_result(long sc, const __u64 *a, struct scratch *sc_buf)
{
    if (cfg_no_arg_hash)
        return 0;

    switch (sc) {
    case SYS_open:
    case SYS_execve: {
        if (!cfg_mask_open) return 0;
        long n = bpf_probe_read_user_str(sc_buf->buf, SCAN_MAX, (void *)a[0]);
        if (n <= 1) return 0;
        if (!path_is_monitored(sc_buf->buf, (__u32)(n - 1))) return 0;
        return (__u16)(0x100u | djb2_8_buf(sc_buf->buf, (__u32)(n - 1)));
    }
    case SYS_openat:
    case SYS_openat2: {
        if (!cfg_mask_open) return 0;
        long n = bpf_probe_read_user_str(sc_buf->buf, SCAN_MAX, (void *)a[1]);
        if (n <= 1) return 0;
        if (!path_is_monitored(sc_buf->buf, (__u32)(n - 1))) return 0;
        return (__u16)(0x100u | djb2_8_buf(sc_buf->buf, (__u32)(n - 1)));
    }
    case SYS_connect: {
        if (cfg_file_sql_unfiltered) return 0;
        if (!cfg_mask_conn) return 0;
        __u8 b[4];
        if (bpf_probe_read_user(b, sizeof(b), (void *)a[1]) != 0) return 0;
        __u16 port = (__u16)((b[2] << 8) | b[3]);
        return (__u8)(port & 0xFF);
    }
    case SYS_write:
    case SYS_sendto: {
        if (cfg_no_sql || !cfg_mask_sql) return 0;
        if (cfg_file_sql_unfiltered) return 0;
        __u32 len = read_user_bounded(sc_buf->buf, a[1], (__u32)a[2]);
        if (len == 0) return 0;
        __u8 h = sql_bpf_hash(sc_buf->buf, len);
        if (!h) return 0;
        return (__u16)(0x200u | h);
    }
    case SYS_writev: {
        if (cfg_no_sql || !cfg_mask_sql) return 0;
        if (cfg_file_sql_unfiltered) return 0;
        struct { __u64 base; __u64 len; } iov;
        if (bpf_probe_read_user(&iov, sizeof(iov), (void *)a[1]) != 0) return 0;
        __u32 len = read_user_bounded(sc_buf->buf, iov.base, (__u32)iov.len);
        if (len == 0) return 0;
        __u8 h = sql_bpf_hash(sc_buf->buf, len);
        if (!h) return 0;
        return (__u16)(0x200u | h);
    }
    default:
        return 0;
    }
}

static NOINLINE __u32 fnv_window(struct tstate *t, __u32 k)
{
    __u32 h = FNV_OFFSET;
    #pragma unroll
    for (__u32 j = 0; j < RING_CAP; j++) {
        if (j < k) {
            __u32 idx = (t->ring_head - k + j) & (RING_CAP - 1);
            h = (h ^ t->ring[idx]) * FNV_PRIME;
        }
    }
    return h;
}

static __always_inline int is_curated(long sc)
{
    switch (sc) {
    case SYS_open: case SYS_openat: case SYS_execve: case SYS_connect:
    case SYS_write: case SYS_writev: case SYS_sendto:
    case SYS_read: case SYS_recvfrom:
        return 1;
    default:
        return 0;
    }
}

static __always_inline int syscall_feedback_allowed(long sc)
{
    if (cfg_syscall_filter_file) {
        if (sc < 0)
            return 0;
        __u32 nr = (__u32)sc;
        return bpf_map_lookup_elem(&allowed_syscalls, &nr) != 0;
    }
    return !cfg_syscall_filter || is_curated(sc);
}

static __always_inline void raw_drop(void)
{
    __u32 z = 0;
    __u64 *drops = bpf_map_lookup_elem(&raw_drops, &z);
    if (drops)
        __sync_fetch_and_add(drops, 1);
}

static __always_inline void emit_file_sql_candidate(__u32 tid, struct ctrl *c,
                                                     long sc, const __u64 *a)
{
    if (cfg_no_arg_hash)
        return;

    __u32 kind = 0, ah = 0, data_len = 0;
    __u64 data_src = 0;
    if (sc == SYS_open || sc == SYS_execve || sc == SYS_openat || sc == SYS_openat2) {
        if (!cfg_mask_open)
            return;
        struct scratch *s = scratch_get();
        if (!s)
            return;
        if (!path_arg_monitored(sc, a, s))
            return;

        kind = FILE_SQL_PATH;
        data_src = path_arg_ptr(sc, a);
    } else if (sc == SYS_write || sc == SYS_sendto) {
        if (cfg_no_sql || !cfg_mask_sql)
            return;
        kind = FILE_SQL_BUFFER;
        data_src = a[1];
        data_len = (__u32)a[2];
    } else if (sc == SYS_writev) {
        if (cfg_no_sql || !cfg_mask_sql)
            return;
        struct { __u64 base; __u64 len; } iov;
        if (bpf_probe_read_user(&iov, sizeof(iov), (void *)a[1]) != 0)
            return;
        kind = FILE_SQL_BUFFER;
        data_src = iov.base;
        data_len = (__u32)iov.len;
    } else {
        return;
    }

    if (kind == FILE_SQL_BUFFER) {
        if (!data_src || !data_len)
            return;
        if (data_len > FILE_SQL_DATA_MAX - 1)
            data_len = FILE_SQL_DATA_MAX - 1;
        barrier_var(data_len);
        data_len &= FILE_SQL_DATA_MAX - 1;
    }

    struct file_sql_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        raw_drop();
        return;
    }

    __builtin_memset(e, 0, offsetof(struct file_sql_event, data));
    e->type = EV_FILE_SQL;
    e->epoch = c->epoch;
    e->tid = tid;
    e->semantic_kind = kind;
    e->nr = sc;
    e->arg_hash = ah;
    if (kind == FILE_SQL_BUFFER) {
        if (bpf_probe_read_user(e->data, data_len, (void *)data_src) != 0) {
            bpf_ringbuf_discard(e, 0);
            return;
        }
        e->data_len = data_len;
    } else if (kind == FILE_SQL_PATH) {
        long pn = bpf_probe_read_user_str(e->data, FILE_SQL_DATA_MAX, (void *)data_src);
        if (pn <= 1) {
            bpf_ringbuf_discard(e, 0);
            return;
        }
        e->data_len = (__u32)(pn - 1);
    }
    bpf_ringbuf_submit(e, 0);
}

static __always_inline void emit_raw_syscall(__u32 tid, __u32 tgid,
                                             struct ctrl *c, long sc,
                                             const __u64 *a, __u8 ah)
{
    if (!cfg_raw_trace)
        return;
    if (!syscall_feedback_allowed(sc))
        return;

    struct raw_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        raw_drop();
        return;
    }
    __builtin_memset(e, 0, sizeof(*e));
    e->type = EV_RAW;
    e->epoch = c->epoch;
    e->ktime_ns = bpf_ktime_get_ns();
    e->tid = tid;
    e->tgid = tgid;
    e->nr = sc;
    e->arg_hash = ah;
    #pragma unroll
    for (int i = 0; i < 6; i++)
        e->args[i] = a[i];

    __u64 src = 0;
    __u32 want = 0;
    switch (sc) {
    case SYS_open:
    case SYS_execve:
        e->detail_kind = RAW_DETAIL_PATH;
        src = a[0];
        break;
    case SYS_openat:
    case SYS_openat2:
        e->detail_kind = RAW_DETAIL_PATH;
        src = a[1];
        break;
    case SYS_connect:
        e->detail_kind = RAW_DETAIL_SOCKADDR;
        src = a[1];
        want = (__u32)a[2];
        break;
    case SYS_write:
    case SYS_sendto:
        e->detail_kind = RAW_DETAIL_BUFFER;
        src = a[1];
        want = (__u32)a[2];
        break;
    case SYS_writev: {
        struct { __u64 base; __u64 len; } iov;
        e->detail_kind = RAW_DETAIL_BUFFER;
        if (bpf_probe_read_user(&iov, sizeof(iov), (void *)a[1]) == 0) {
            src = iov.base;
            want = (__u32)iov.len;
        }
        break;
    }
    default:
        break;
    }

    if (e->detail_kind == RAW_DETAIL_PATH && src) {
        long n = bpf_probe_read_user_str(e->detail, RAW_DETAIL_MAX, (void *)src);
        if (n > 1) {
            e->detail_len = (__u32)(n - 1);
            e->detail_total_len = e->detail_len;
        }
    } else if (e->detail_kind != RAW_DETAIL_NONE && src && want) {
        e->detail_total_len = want;
        if (want > RAW_DETAIL_MAX - 1)
            want = RAW_DETAIL_MAX - 1;
        barrier_var(want);
        want &= (RAW_DETAIL_MAX - 1);
        if (want && bpf_probe_read_user(e->detail, want, (void *)src) == 0)
            e->detail_len = want;
    }
    bpf_ringbuf_submit(e, 0);
}

static __always_inline void record_token(__u32 tid, struct ctrl *c, long sc, __u8 ah)
{
    if (!syscall_feedback_allowed(sc))
        return;

    struct tstate *t = bpf_map_lookup_elem(&tstates, &tid);
    if (!t) {
        struct tstate z;
        tstate_zero(&z);
        z.full_hash = FNV_OFFSET;
        z.epoch = c->epoch;
        z.rd_fd = -1;
        bpf_map_update_elem(&tstates, &tid, &z, BPF_ANY);
        t = bpf_map_lookup_elem(&tstates, &tid);
        if (!t) return;
    }
    if (t->epoch != c->epoch) {
        t->ring_count = 0;
        t->ring_head = 0;
        t->full_hash = FNV_OFFSET;
        t->participated = 0;
        t->epoch = c->epoch;
    }

    __u16 token = COV_TOKEN(sc, ah);
    __u32 head = t->ring_head & (RING_CAP - 1);
    t->ring[head] = token;
    t->ring_head = (head + 1) & (RING_CAP - 1);
    if (t->ring_count < RING_CAP) t->ring_count++;
    t->participated = 1;
    t->full_hash = (t->full_hash ^ token) * FNV_PRIME;

    __u32 theta = cfg_theta;
    if (theta < 2) theta = 2;
    if (theta > THETA_MAX) theta = THETA_MAX;

    if (t->ring_count >= theta) {
        __u32 h = fnv_window(t, theta);
        hit_cell(c->active_idx, (h ^ SALT_THETA) & 0xFFFF);
    }
    if (t->ring_count >= 2 * theta) {
        __u32 h = fnv_window(t, 2 * theta);
        hit_cell(c->active_idx, (h ^ SALT_2THETA) & 0xFFFF);
    }
}

static __always_inline struct tstate *tstate_for_epoch(__u32 tid, struct ctrl *c)
{
    struct tstate *t = bpf_map_lookup_elem(&tstates, &tid);
    if (!t) {
        struct tstate z;
        tstate_zero(&z);
        z.full_hash = FNV_OFFSET;
        z.epoch = c->epoch;
        z.rd_fd = -1;
        bpf_map_update_elem(&tstates, &tid, &z, BPF_ANY);
        t = bpf_map_lookup_elem(&tstates, &tid);
        if (!t) return 0;
    }
    if (t->epoch != c->epoch) {
        t->ring_count = 0;
        t->ring_head = 0;
        t->full_hash = FNV_OFFSET;
        t->participated = 0;
        t->prev_syscall = 0;
        t->prev_arg = 0;
        t->epoch = c->epoch;
    }
    return t;
}

static __always_inline void record_bigram(__u32 tid, struct ctrl *c, long sc, __u8 ah)
{
    int allowed = syscall_feedback_allowed(sc);
    if (cfg_syscall_filter_file && !allowed)
        return;

    struct tstate *t = tstate_for_epoch(tid, c);
    if (!t) return;

    if (allowed) {
        __u16 idx = (__u16)((((__u32)t->prev_syscall & 0xFFu) << 8) ^
                            ((__u32)sc & 0xFFu) ^ (__u32)ah);
        hit_cell(c->active_idx, idx);
    }
    t->prev_syscall = (__u32)sc;
    t->participated = 1;
}

#define BPF_MAP_HALF (MAP_SIZE / 2u)

static __always_inline void record_bigram_separated(__u32 tid, struct ctrl *c,
                                                    long sc, __u16 ah_result)
{
    int allowed = syscall_feedback_allowed(sc);
    if (cfg_syscall_filter_file && !allowed)
        return;

    struct tstate *t = tstate_for_epoch(tid, c);
    if (!t) return;

    if (allowed) {
        __u32 prev = (__u32)t->prev_syscall & 0xFFu;
        __u32 curr = (__u32)sc & 0xFFu;

        __u16 raw_up = (__u16)((prev << 8) ^ curr);
        __u16 up = (__u16)(BPF_MAP_HALF +
                           (__u16)((raw_up ^ (raw_up >> 15)) & (BPF_MAP_HALF - 1u)));
        hit_cell(c->active_idx, up);

        if (ah_result & 0x300u) {
            __u8 ah = (__u8)ah_result;
            __u16 raw_lo = (__u16)((prev << 8) ^ curr ^ (__u32)ah);
            __u16 lo = (__u16)((raw_lo ^ (raw_lo >> 15)) & (BPF_MAP_HALF - 1u));
            hit_cell(c->active_idx, lo);
        }
    }
    t->prev_syscall = (__u32)sc;
    t->participated = 1;
}

static __always_inline int is_sql_buffer_syscall(long sc)
{
    return sc == SYS_write || sc == SYS_sendto || sc == SYS_writev;
}

static __always_inline void record_bigram_pred(__u32 tid, struct ctrl *c, long sc, __u8 ah)
{
    int allowed = syscall_feedback_allowed(sc);
    if (cfg_syscall_filter_file && !allowed)
        return;

    struct tstate *t = tstate_for_epoch(tid, c);
    if (!t) return;

    __u32 prev = t->prev_syscall;
    __u32 prev_arg = t->prev_arg;
    t->prev_syscall = (__u32)sc;
    t->prev_arg = ah;
    t->participated = 1;
    if (!allowed)
        return;

    if (prev_arg & PREV_ARG_DEFERRED) {
        struct file_sql_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {

    __builtin_memset(e, 0, offsetof(struct file_sql_event, data));
            e->type = EV_FILE_SQL;
            e->epoch = c->epoch;
            e->tid = tid;
            e->semantic_kind = FILE_SQL_EDGE_AFTER_SQL;
            e->nr = sc;
            e->arg_hash = ah;
            e->prev_syscall = prev;
            e->prev_arg = prev_arg;
            bpf_ringbuf_submit(e, 0);
            return;
        }
        raw_drop();
        prev_arg = 0;
    }

    __u16 idx = (__u16)((((prev ^ prev_arg) & 0xFFu) << 8) ^
                        ((__u32)sc & 0xFFu) ^ (__u32)ah);
    hit_cell(c->active_idx, idx);
}

static __always_inline void record_bigram_sql_deferred(__u32 tid, struct ctrl *c,
                                                       long sc, const __u64 *a)
{
    int allowed = syscall_feedback_allowed(sc);
    if (cfg_syscall_filter_file && !allowed)
        return;

    __u64 data_src = 0;
    __u32 data_len = 0;
    if (sc == SYS_writev) {
        struct { __u64 base; __u64 len; } iov;
        if (bpf_probe_read_user(&iov, sizeof(iov), (void *)a[1]) == 0) {
            data_src = iov.base;
            data_len = (__u32)iov.len;
        }
    } else {
        data_src = a[1];
        data_len = (__u32)a[2];
    }
    if (data_len > FILE_SQL_DATA_MAX - 1)
        data_len = FILE_SQL_DATA_MAX - 1;
    barrier_var(data_len);
    data_len &= FILE_SQL_DATA_MAX - 1;

    struct tstate *t = tstate_for_epoch(tid, c);
    if (!t) return;
    __u32 prev = t->prev_syscall;
    __u32 prev_arg = t->prev_arg;
    t->prev_syscall = (__u32)sc;

    t->prev_arg = 0;
    t->participated = 1;
    if (!allowed)
        return;

    if (data_src && data_len) {
        struct file_sql_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (!e) {
            raw_drop();
        } else {

    __builtin_memset(e, 0, offsetof(struct file_sql_event, data));
            e->type = EV_FILE_SQL;
            e->epoch = c->epoch;
            e->tid = tid;
            e->semantic_kind = FILE_SQL_EDGE_BUFFER;
            e->nr = sc;
            e->prev_syscall = prev;
            e->prev_arg = prev_arg;
            if (bpf_probe_read_user(e->data, data_len, (void *)data_src) == 0) {
                e->data_len = data_len;
                bpf_ringbuf_submit(e, 0);
                if (cfg_file_sql_pred_args)
                    t->prev_arg = PREV_ARG_DEFERRED;
                return;
            }
            bpf_ringbuf_discard(e, 0);
        }
    }

    if (!cfg_file_sql_pred_args)
        prev_arg = 0;
    else if (prev_arg & PREV_ARG_DEFERRED)
        prev_arg = 0;
    hit_cell(c->active_idx, (__u16)((((prev ^ prev_arg) & 0xFFu) << 8) ^
                                    ((__u32)sc & 0xFFu)));
}

static __always_inline void record_file_sql_unfiltered(__u32 tid, struct ctrl *c,
                                                       long sc, const __u64 *a)
{
    if (!cfg_no_arg_hash && !cfg_no_sql && cfg_mask_sql && is_sql_buffer_syscall(sc)) {
        record_bigram_sql_deferred(tid, c, sc, a);
        return;
    }
    struct scratch *s = scratch_get();
    if (!s) return;
    __u8 ah = (__u8)arg_hash_result(sc, a, s);
    if (cfg_file_sql_pred_args)
        record_bigram_pred(tid, c, sc, ah);
    else
        record_bigram(tid, c, sc, ah);
}

struct id_info { __u32 found; __u32 hash; __u32 vstart; __u32 vlen; };

struct detect_ctx {
    __u32 n;
    __u32 hlen;
    int   mpos;
    int   capture;
    int   skipsp;
    __u32 h;
    __u32 vstart;
    __u32 vlen;
};

static long detect_id_step(__u32 i, void *ctx)
{
    struct detect_ctx *d = ctx;
    if (i >= d->n)
        return 1;
    struct scratch *s = scratch_get();
    if (!s)
        return 1;
    char c = s->buf[i & (SCAN_MAX - 1)];
    if (d->capture) {
        if (d->skipsp && (c == ' ' || c == '\t'))
            return 0;
        d->skipsp = 0;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-') {
            if (d->vlen == 0) d->vstart = i;
            d->h = ((d->h << 5) + d->h) ^ (__u8)c;
            d->vlen++;
            return 0;
        }
        return 1;
    }
    if (c == '\n') {
        d->mpos = 0;
    } else if (d->mpos >= 0) {
        if ((__u32)d->mpos < d->hlen) {
            if (lc(c) == cfg_hdr_lc[d->mpos & 31]) d->mpos++;
            else d->mpos = -1;
        } else {
            if (c == ':') { d->capture = 1; d->skipsp = 1; d->mpos = -1; }
            else d->mpos = -1;
        }
    }
    return 0;
}

static __always_inline void detect_id(struct scratch *s, __u32 n, struct id_info *out)
{
    (void)s;
    out->found = 0; out->hash = 0; out->vstart = 0; out->vlen = 0;
    __u32 hlen = cfg_hdr_len;
    if (hlen == 0 || hlen > 31) return;

    struct detect_ctx d = { .n = n, .hlen = hlen, .mpos = 0, .capture = 0,
                            .skipsp = 0, .h = 5381u, .vstart = 0, .vlen = 0 };
    bpf_loop(SCAN_MAX, detect_id_step, &d, 0);
    if (d.vlen > 0) { out->found = 1; out->hash = d.h; out->vstart = d.vstart; out->vlen = d.vlen; }
}

static __always_inline void emit_start(__u32 idx, __u32 epoch, struct id_info *ii, struct scratch *s)
{
    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return;
    e->type = EV_START;
    e->idx = idx;
    e->epoch = epoch;
    e->id_hash = ii->hash;
    e->vstart = 0;
    e->vlen = ii->vlen > 127 ? 127 : ii->vlen;
    #pragma unroll
    for (__u32 i = 0; i < 128; i++) {
        if (i < e->vlen) {
            __u32 pos = (ii->vstart + i) & (SCAN_MAX - 1);
            e->payload[i] = s->buf[pos];
        }
    }
    bpf_ringbuf_submit(e, 0);
}

static __always_inline void emit_end(__u32 idx, __u32 epoch)
{
    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return;
    e->type = EV_END;
    e->idx = idx;
    e->epoch = epoch;
    e->id_hash = 0; e->vstart = 0; e->vlen = 0;
    bpf_ringbuf_submit(e, 0);
}

static __always_inline void start_request(struct ctrl *c, struct id_info *ii, __s32 fd, struct scratch *s)
{
    if (c->active && c->id_hash == ii->hash)
        return;
    __u32 newidx = c->active_idx ^ 1u;
    c->active_idx = newidx;
    c->active = 1;
    c->req_fd = fd;
    c->epoch += 1;
    c->id_hash = ii->hash;
    emit_start(newidx, c->epoch, ii, s);
}

static __always_inline void end_request(struct ctrl *c)
{
    if (!c->active) return;
    emit_end(c->active_idx, c->epoch);
    c->active = 0;
    c->epoch += 1;
    c->req_fd = -1;
}

static __always_inline void demux_write(struct ctrl *c, __s32 fd, __u64 base, __u32 len)
{
    struct scratch *s = scratch_get();
    if (!s) return;
    __u32 n = read_user_bounded(s->buf, base, len);
    if (n == 0) return;

    struct id_info ii;
    detect_id(s, n, &ii);
    if (ii.found && !(c->active && c->id_hash == ii.hash)) {
        start_request(c, &ii, fd, s);
        return;
    }

    if (!c->active) return;
    int is_status = (n >= 7 &&
        s->buf[0] == 'H' && s->buf[1] == 'T' && s->buf[2] == 'T' && s->buf[3] == 'P' &&
        s->buf[4] == '/' && s->buf[5] == '1' && s->buf[6] == '.');
    if (is_status && (cfg_end_on_status || fd != c->req_fd))
        end_request(c);
}

static __always_inline void demux_read(struct ctrl *c, __s32 fd, __u64 base, __u32 len)
{
    struct scratch *s = scratch_get();
    if (!s) return;
    __u32 n = read_user_bounded(s->buf, base, len);
    if (n == 0) return;

    struct id_info ii;
    detect_id(s, n, &ii);
    if (ii.found) start_request(c, &ii, fd, s);
}

SEC("tp/raw_syscalls/sys_enter")
int tracelib_sys_enter(struct trace_event_raw_sys_enter *ctx)
{
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32, tid = (__u32)pt;
    if (!bpf_map_lookup_elem(&target_tgids, &tgid))
        return 0;

    long sc = ctx->id;
    __u64 a[6];
    a[0] = ctx->args[0]; a[1] = ctx->args[1]; a[2] = ctx->args[2];
    a[3] = ctx->args[3]; a[4] = ctx->args[4]; a[5] = ctx->args[5];

    struct ctrl *c = ctrl_get();
    if (!c) return 0;

    if (sc == SYS_read || sc == SYS_recvfrom) {
        struct tstate *t = bpf_map_lookup_elem(&tstates, &tid);
        if (t) { t->rd_buf = a[1]; t->rd_fd = (__s32)a[0]; }
        else {
            struct tstate z;
            tstate_zero(&z);
            z.full_hash = FNV_OFFSET; z.epoch = c->epoch;
            z.rd_buf = a[1]; z.rd_fd = (__s32)a[0];
            bpf_map_update_elem(&tstates, &tid, &z, BPF_ANY);
        }
    }

    __u64 wbase = 0; __u32 wlen = 0; int do_w = 0;
    if (sc == SYS_write || sc == SYS_sendto) {
        wbase = a[1]; wlen = (__u32)a[2]; do_w = 1;
    } else if (sc == SYS_writev) {
        struct { __u64 base; __u64 len; } iov;
        if (bpf_probe_read_user(&iov, sizeof(iov), (void *)a[1]) == 0) {
            wbase = iov.base; wlen = (__u32)iov.len; do_w = 1;
        }
    }
    if (do_w)
        demux_write(c, (__s32)a[0], wbase, wlen);

    c = ctrl_get();
    if (!c || !c->active)
        return 0;

    if (cfg_syscall_filter_file && !syscall_feedback_allowed(sc))
        return 0;

    if (cfg_file_sql_only) {
        emit_file_sql_candidate(tid, c, sc, a);
        return 0;
    }

    if (cfg_file_sql_unfiltered) {
        record_file_sql_unfiltered(tid, c, sc, a);
        return 0;
    }

    if (cfg_sql_compact && cfg_cov_mode && !cfg_bigram_separated &&
        !cfg_no_arg_hash && !cfg_no_sql && cfg_mask_sql &&
        is_sql_buffer_syscall(sc)) {
        record_bigram_sql_deferred(tid, c, sc, a);
        return 0;
    }

    struct scratch *s = scratch_get();
    if (!s) return 0;
    __u16 ah_result = arg_hash_result(sc, a, s);
    __u8 ah = (__u8)ah_result;
    emit_raw_syscall(tid, tgid, c, sc, a, ah);
    if (cfg_bigram_separated)
        record_bigram_separated(tid, c, sc, ah_result);
    else if (cfg_cov_mode)
        record_bigram(tid, c, sc, ah);
    else
        record_token(tid, c, sc, ah);
    return 0;
}

SEC("tp/raw_syscalls/sys_exit")
int tracelib_sys_exit(struct trace_event_raw_sys_exit *ctx)
{
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32, tid = (__u32)pt;
    if (!bpf_map_lookup_elem(&target_tgids, &tgid))
        return 0;

    long sc = ctx->id;
    long ret = ctx->ret;

    if ((sc == SYS_clone || sc == SYS_fork || sc == SYS_vfork) && ret > 0) {
        __u32 child = (__u32)ret;
        __u8 one = 1;
        bpf_map_update_elem(&target_tgids, &child, &one, BPF_ANY);
    }

    if ((sc == SYS_read || sc == SYS_recvfrom) && ret > 0) {
        struct ctrl *c = ctrl_get();
        struct tstate *t = bpf_map_lookup_elem(&tstates, &tid);
        if (c && t)
            demux_read(c, t->rd_fd, t->rd_buf, (__u32)ret);
    }
    return 0;
}
