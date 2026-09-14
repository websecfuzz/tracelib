#ifndef TRACELIB_BACKEND_EBPF_IMPL_H
#define TRACELIB_BACKEND_EBPF_IMPL_H

#include "tracelib.skel.h"
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#include "config.h"
#include "arghash.h"
#include "bitmap.h"
#include "pid_discovery.h"
#include "sql_detect.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <inttypes.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>

struct ts_state {
    uint16_t ring[RING_CAP];
    uint64_t rd_buf;
    uint32_t ring_count, ring_head, full_hash, epoch;
    int32_t  rd_fd;
    uint32_t participated;
    uint32_t prev_syscall;
    uint32_t prev_arg;
};
struct ctrl_state {
    uint32_t active_idx, epoch, active;
    int32_t  req_fd;
    uint32_t id_hash;
};
#define EV_START 1
#define EV_END   2
#define EV_RAW   3
#define EV_FILE_SQL 4
#define RAW_DETAIL_MAX 128
#define RAW_DETAIL_NONE 0
#define RAW_DETAIL_PATH 1
#define RAW_DETAIL_BUFFER 2
#define RAW_DETAIL_SOCKADDR 3
#define EBPF_SCAN_MAX 1024
struct ev {
    uint32_t type, idx, epoch, id_hash, vstart, vlen;
    char     payload[EBPF_SCAN_MAX];
};
struct raw_ev {
    uint32_t type, epoch;
    uint64_t ktime_ns;
    uint32_t tid, tgid;
    int64_t  nr;
    uint64_t args[6];
    uint32_t arg_hash, detail_kind, detail_len, detail_total_len;
    char     detail[RAW_DETAIL_MAX];
};
struct file_sql_ev {
    uint32_t type, epoch, tid, semantic_kind;
    int64_t  nr;
    uint32_t arg_hash, data_len;
    uint32_t prev_syscall;
    uint32_t prev_arg;
    char     data[FILE_SQL_DATA_MAX];
};
#define FILE_SQL_PATH 1
#define FILE_SQL_BUFFER 2
#define FILE_SQL_EDGE_BUFFER 3
#define FILE_SQL_EDGE_AFTER_SQL 4
#define PREV_ARG_DEFERRED 0x100u

static struct tracelib    *e_skel;
static struct ring_buffer *e_rb;
static uint8_t            *e_bm;
static const struct config *e_cfg;
static uint16_t            e_port;

static struct {
    int      active;
    uint32_t idx;
    uint32_t epoch;
    char     id[128];
    uint64_t last_ms;
    FILE    *raw_fp;
    uint64_t raw_events;
    uint64_t raw_drop_start;
} e_cur;

struct ebpf_semantic_state {
    uint32_t tid;
    uint32_t prev_syscall;

    uint8_t  last_sql_arg_hash;

    uint8_t  prev_arg_hash;
};
#define EBPF_SEMANTIC_TIDS_MAX 4096
static struct ebpf_semantic_state e_semantic_tids[EBPF_SEMANTIC_TIDS_MAX];
static size_t e_semantic_tid_count;

static uint64_t ebpf_raw_drop_count(void)
{
    if (!e_skel)
        return 0;
    int fd = bpf_map__fd(e_skel->maps.raw_drops);
    uint32_t z = 0;
    uint64_t drops = 0;
    if (fd >= 0)
        bpf_map_lookup_elem(fd, &z, &drops);
    return drops;
}

static const char *ebpf_raw_detail_name(uint32_t kind)
{
    switch (kind) {
    case RAW_DETAIL_PATH: return "path";
    case RAW_DETAIL_BUFFER: return "buffer";
    case RAW_DETAIL_SOCKADDR: return "sockaddr";
    default: return "none";
    }
}

static void ebpf_json_bytes(FILE *out, const char *data, size_t len)
{
    fputc('"', out);
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)data[i];
        switch (c) {
        case '"': fputs("\\\"", out); break;
        case '\\': fputs("\\\\", out); break;
        case '\b': fputs("\\b", out); break;
        case '\f': fputs("\\f", out); break;
        case '\n': fputs("\\n", out); break;
        case '\r': fputs("\\r", out); break;
        case '\t': fputs("\\t", out); break;
        default:
            if (c >= 0x20 && c <= 0x7e)
                fputc(c, out);
            else
                fprintf(out, "\\u%04x", c);
        }
    }
    fputc('"', out);
}

static void ebpf_raw_open(const char *id)
{
    e_cur.raw_fp = NULL;
    e_cur.raw_events = 0;
    e_cur.raw_drop_start = ebpf_raw_drop_count();
    if (!e_cfg->raw_trace_dir[0])
        return;

    char path[512];
    snprintf(path, sizeof(path), "%s/%s.syscalls.jsonl", e_cfg->raw_trace_dir, id);
    e_cur.raw_fp = fopen(path, "w");
    if (!e_cur.raw_fp) {
        LOGE("open(%s): %s", path, strerror(errno));
        return;
    }
    chmod(path, 0600);
    setvbuf(e_cur.raw_fp, NULL, _IOLBF, 0);
}

static void ebpf_raw_write(const struct raw_ev *e)
{
    if (!e_cur.raw_fp || !e_cur.active || e->epoch != e_cur.epoch)
        return;
    FILE *out = e_cur.raw_fp;
    fprintf(out,
        "{\"seq\":%" PRIu64 ",\"ktime_ns\":%" PRIu64
        ",\"tid\":%u,\"tgid\":%u,\"epoch\":%u,\"syscall_nr\":%" PRId64
        ",\"args\":[\"0x%016" PRIx64 "\",\"0x%016" PRIx64
        "\",\"0x%016" PRIx64 "\",\"0x%016" PRIx64
        "\",\"0x%016" PRIx64 "\",\"0x%016" PRIx64
        "\"],\"arg_hash\":%u,\"detail_kind\":\"%s\",\"detail_len\":%u"
        ",\"detail_total_len\":%u,\"detail\":",
        e_cur.raw_events, e->ktime_ns, e->tid, e->tgid, e->epoch, e->nr,
        e->args[0], e->args[1], e->args[2], e->args[3], e->args[4], e->args[5],
        e->arg_hash, ebpf_raw_detail_name(e->detail_kind), e->detail_len,
        e->detail_total_len);
    size_t len = e->detail_len > RAW_DETAIL_MAX ? RAW_DETAIL_MAX : e->detail_len;
    ebpf_json_bytes(out, e->detail, len);
    fputs("}\n", out);
    e_cur.raw_events++;
}

static struct ebpf_semantic_state *ebpf_semantic_state_for(uint32_t tid)
{
    for (size_t i = 0; i < e_semantic_tid_count; i++) {
        if (e_semantic_tids[i].tid == tid)
            return &e_semantic_tids[i];
    }
    if (e_semantic_tid_count == EBPF_SEMANTIC_TIDS_MAX)
        return NULL;
    struct ebpf_semantic_state *state = &e_semantic_tids[e_semantic_tid_count++];
    state->tid = tid;
    state->prev_syscall = 0;
    state->last_sql_arg_hash = 0;
    state->prev_arg_hash = 0;
    return state;
}

static uint8_t ebpf_pred_arg_hash(const struct file_sql_ev *e)
{
    if (!(e->prev_arg & PREV_ARG_DEFERRED))
        return (uint8_t)(e->prev_arg & 0xFF);
    struct ebpf_semantic_state *state = ebpf_semantic_state_for(e->tid);
    return state ? state->last_sql_arg_hash : 0;
}

static void ebpf_file_sql_write(const struct file_sql_ev *e)
{
    if (!e_cur.active || e->epoch != e_cur.epoch)
        return;

    uint8_t *half = e_bm + (size_t)e_cur.idx * MAP_SIZE;

    if (e->semantic_kind == FILE_SQL_EDGE_BUFFER) {
        size_t len = e->data_len > FILE_SQL_DATA_MAX ? FILE_SQL_DATA_MAX : e->data_len;
        char canonical[FILE_SQL_DATA_MAX + 1];
        size_t n = config_sql_compact(e_cfg)
            ? sql_compact_query(e->data, len, canonical, sizeof(canonical))
            : sql_query_reduced(e->data, len, canonical, sizeof(canonical));
        uint8_t ah = n ? djb2_8(canonical, n) : 0;
        if (!config_file_sql_pred_args(e_cfg)) {
            bitmap_record_bigram(half, e->prev_syscall, (uint32_t)e->nr, ah);
            return;
        }
        bitmap_record_bigram_pred(half, e->prev_syscall, ebpf_pred_arg_hash(e),
                                  (uint32_t)e->nr, ah);

        struct ebpf_semantic_state *state = ebpf_semantic_state_for(e->tid);
        if (state)
            state->last_sql_arg_hash = ah;
        return;
    }

    if (e->semantic_kind == FILE_SQL_EDGE_AFTER_SQL) {
        bitmap_record_bigram_pred(half, e->prev_syscall, ebpf_pred_arg_hash(e),
                                  (uint32_t)e->nr, (uint8_t)e->arg_hash);
        return;
    }

    uint8_t ah;
    if (e->semantic_kind == FILE_SQL_PATH) {

        size_t len = e->data_len;
        if (len > FILE_SQL_DATA_MAX - 1)
            len = FILE_SQL_DATA_MAX - 1;
        if (!arghash_path_hash(e_cfg, e->data, len, &ah))
            return;
    } else if (e->semantic_kind == FILE_SQL_BUFFER) {
        size_t len = e->data_len > FILE_SQL_DATA_MAX ? FILE_SQL_DATA_MAX : e->data_len;
        char canonical[FILE_SQL_DATA_MAX + 1];
        size_t n = config_sql_compact(e_cfg)
            ? sql_compact_query(e->data, len, canonical, sizeof(canonical))
            : sql_query_reduced(e->data, len, canonical, sizeof(canonical));
        if (!n)
            return;
        ah = djb2_8(canonical, n);
    } else {
        return;
    }

    struct ebpf_semantic_state *state = ebpf_semantic_state_for(e->tid);
    if (!state)
        return;
    if (config_file_sql_filtered(e_cfg)) {

        bitmap_record_bigram_pred(half, state->prev_syscall, state->prev_arg_hash,
                                  (uint32_t)e->nr, ah);
        state->prev_arg_hash = ah;
    } else {
        bitmap_record_bigram(half, state->prev_syscall, (uint32_t)e->nr, ah);
    }
    state->prev_syscall = (uint32_t)e->nr;
}

static void ebpf_raw_close(const char *id)
{
    if (!e_cfg->raw_trace_dir[0])
        return;
    if (e_cur.raw_fp) {
        fflush(e_cur.raw_fp);
        fclose(e_cur.raw_fp);
        e_cur.raw_fp = NULL;
    }
    uint64_t drops = ebpf_raw_drop_count() - e_cur.raw_drop_start;
    char path[512];
    snprintf(path, sizeof(path), "%s/%s.syscalls.meta.json", e_cfg->raw_trace_dir, id);
    FILE *meta = fopen(path, "w");
    if (!meta) {
        LOGE("open(%s): %s", path, strerror(errno));
        return;
    }
    chmod(path, 0600);
    fprintf(meta,
        "{\n  \"request_id\": \"%s\",\n  \"syscall_events\": %" PRIu64
        ",\n  \"ringbuf_drops\": %" PRIu64 ",\n  \"complete\": %s\n}\n",
        id, e_cur.raw_events, drops, drops ? "false" : "true");
    fclose(meta);
}

static unsigned long long ebpf_capeff(void)
{
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return 0;
    char line[128];
    unsigned long long eff = 0;
    while (fgets(line, sizeof(line), f))
        if (sscanf(line, "CapEff: %llx", &eff) == 1) break;
    fclose(f);
    return eff;
}

static int ebpf_available(void)
{
    if (access("/sys/kernel/btf/vmlinux", R_OK) != 0)
        return 0;
    unsigned long long e = ebpf_capeff();
    int cap_bpf     = (e >> 39) & 1ULL;
    int cap_perfmon = (e >> 38) & 1ULL;
    int cap_admin   = (e >> 21) & 1ULL;
    return (cap_bpf && cap_perfmon) || cap_admin;
}

static void ebpf_finish(uint32_t idx, const char *id, uint32_t epoch)
{
    uint8_t *half = e_bm + (size_t)idx * MAP_SIZE;

    if (e_cfg->coverage_mode == COV_NGRAM) {

        int mfd = bpf_map__fd(e_skel->maps.tstates);
        uint32_t key, next;
        struct ts_state v;
        int err = bpf_map_get_next_key(mfd, NULL, &next);
        while (err == 0) {
            if (bpf_map_lookup_elem(mfd, &next, &v) == 0 &&
                v.epoch == epoch && v.participated) {
                uint16_t cell = (uint16_t)((v.full_hash ^ SALT_FULL) & 0xFFFF);
                if (half[cell] != 0xFF) half[cell]++;
            }
            key = next;
            err = bpf_map_get_next_key(mfd, &key, &next);
        }
    }

    if (config_bigram_separated(e_cfg)) {
        size_t kept = bitmap_prune_upper_half(half, (unsigned)e_cfg->separated_min_hits);
        LOGI("separated map: %zu upper-half cells survived the <%d prune",
             kept, e_cfg->separated_min_hits);
    }
    if (config_top_edges(e_cfg))
        bitmap_keep_top_edges(half, (size_t)e_cfg->top_edges);

    char path[160];
    snprintf(path, sizeof(path), "/dev/shm/%s", id);
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (fd >= 0) {
        if (ftruncate(fd, MAP_SIZE) == 0) {
            ssize_t off = 0;
            while (off < (ssize_t)MAP_SIZE) {
                ssize_t w = pwrite(fd, half + off, MAP_SIZE - off, off);
                if (w <= 0) break;
                off += w;
            }
        }
        close(fd);
    } else {
        LOGE("open(%s): %s", path, strerror(errno));
    }

    uint32_t nz = 0;
    for (uint32_t i = 0; i < MAP_SIZE; i++)
        if (half[i]) nz++;
    LOGI("request done: %s (idx %u, cells=%u)", id, idx, nz);

    ebpf_raw_close(id);
    memset(half, 0, MAP_SIZE);
    e_cur.active = 0;
}

static void ebpf_force_end_kernel(void)
{
    int cfd = bpf_map__fd(e_skel->maps.ctrl_map);
    uint32_t z = 0;
    struct ctrl_state cs;
    if (bpf_map_lookup_elem(cfd, &z, &cs) == 0 && cs.active) {
        cs.active = 0;
        cs.epoch += 1;
        cs.req_fd = -1;
        bpf_map_update_elem(cfd, &z, &cs, BPF_ANY);
    }
}

static void ebpf_extract_id(const struct ev *e, char *out, size_t cap)
{
    uint32_t vs = e->vstart, vl = e->vlen;
    if (vs >= EBPF_SCAN_MAX) { out[0] = 0; return; }
    if (vs + vl > EBPF_SCAN_MAX) vl = EBPF_SCAN_MAX - vs;
    size_t o = 0;
    for (uint32_t i = 0; i < vl && o + 1 < cap; i++) {
        char c = e->payload[vs + i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-')
            out[o++] = c;
    }
    out[o] = 0;
}

static int ebpf_on_event(void *ctx, void *data, size_t sz)
{
    (void)ctx;
    if (sz < sizeof(uint32_t))
        return 0;
    struct ev *e = data;
    if (e->type == EV_RAW) {
        if (sz >= sizeof(struct raw_ev))
            ebpf_raw_write((const struct raw_ev *)data);
    } else if (e->type == EV_FILE_SQL) {
        if (sz >= sizeof(struct file_sql_ev))
            ebpf_file_sql_write((const struct file_sql_ev *)data);
    } else if (e->type == EV_START) {
        if (sz < sizeof(struct ev))
            return 0;

        if (e_cur.active)
            ebpf_finish(e_cur.idx, e_cur.id, e_cur.epoch);
        char id[128];
        ebpf_extract_id(e, id, sizeof(id));
        if (id[0] == 0) { e_cur.active = 0; return 0; }
        e_cur.active = 1;
        e_cur.idx = e->idx;
        e_cur.epoch = e->epoch;
        snprintf(e_cur.id, sizeof(e_cur.id), "%s", id);
        e_cur.last_ms = now_ms();
        e_semantic_tid_count = 0;
        ebpf_raw_open(e_cur.id);
        LOGI("request start: %s (idx %u)", e_cur.id, e->idx);
    } else if (e->type == EV_END) {

        if (e_cur.active && e_cur.idx == e->idx)
            ebpf_finish(e->idx, e_cur.id, e->epoch);
    }
    return 0;
}

static int ebpf_start(uint16_t port, const struct config *cfg)
{
    e_cfg = cfg;
    e_port = port;

    e_skel = tracelib__open();
    if (!e_skel) {
        LOGE("tracelib__open failed: %s", strerror(errno));
        return -1;
    }

    int theta = cfg->theta < 2 ? 2 : (cfg->theta > THETA_MAX ? THETA_MAX : cfg->theta);
    e_skel->rodata->cfg_theta = (uint32_t)theta;
    size_t hl = cfg->header_len < 31 ? cfg->header_len : 31;
    memset((void *)e_skel->rodata->cfg_hdr_lc, 0, sizeof(e_skel->rodata->cfg_hdr_lc));
    memcpy((void *)e_skel->rodata->cfg_hdr_lc, cfg->header_lc, hl);
    e_skel->rodata->cfg_hdr_len = (uint32_t)hl;
    e_skel->rodata->cfg_no_arg_hash = cfg->no_arg_hash ? 1 : 0;
    e_skel->rodata->cfg_no_sql = cfg->no_sql ? 1 : 0;
    e_skel->rodata->cfg_file_sql_only = cfg->file_sql_only ? 1 : 0;
    e_skel->rodata->cfg_file_sql_filtered = config_file_sql_filtered(cfg) ? 1 : 0;
    e_skel->rodata->cfg_file_sql_unfiltered = cfg->file_sql_unfiltered ? 1 : 0;
    e_skel->rodata->cfg_file_sql_pred_args = config_file_sql_pred_args(cfg) ? 1 : 0;
    e_skel->rodata->cfg_sql_compact = config_sql_compact(cfg) ? 1 : 0;
    e_skel->rodata->cfg_syscall_filter = cfg->syscall_filter ? 1 : 0;
    e_skel->rodata->cfg_syscall_filter_file = cfg->syscall_filter_file[0] ? 1 : 0;
    e_skel->rodata->cfg_mask_sql = cfg->mask[PARAM_SQL] ? 1 : 0;
    e_skel->rodata->cfg_mask_open = cfg->mask[PARAM_OPEN_PATH] ? 1 : 0;
    e_skel->rodata->cfg_mask_conn = cfg->mask[PARAM_CONNECT_PORT] ? 1 : 0;
    e_skel->rodata->cfg_cov_mode = (cfg->coverage_mode == COV_BIGRAM) ? 1 : 0;
    e_skel->rodata->cfg_end_on_status = config_end_on_status_line(cfg) ? 1 : 0;
    e_skel->rodata->cfg_bigram_separated = config_bigram_separated(cfg) ? 1 : 0;
    {
        size_t ml = strlen(cfg->file_path_monitored);
        if (ml > FILE_PATH_MONITORED_MAX) ml = FILE_PATH_MONITORED_MAX;
        memset((void *)e_skel->rodata->cfg_monitored_path, 0,
               sizeof(e_skel->rodata->cfg_monitored_path));
        memcpy((void *)e_skel->rodata->cfg_monitored_path, cfg->file_path_monitored, ml);
        e_skel->rodata->cfg_monitored_len = (uint32_t)ml;

    }
    e_skel->rodata->cfg_raw_trace = cfg->raw_trace_dir[0] ? 1 : 0;

    if (cfg->raw_trace_dir[0] && access(cfg->raw_trace_dir, W_OK) != 0) {
        LOGE("raw trace directory is not writable: %s: %s",
             cfg->raw_trace_dir, strerror(errno));
        goto fail;
    }

    if (getenv("TRACELIB_BPF_VERBOSE")) {
        bpf_program__set_log_level(e_skel->progs.tracelib_sys_enter, 1);
        bpf_program__set_log_level(e_skel->progs.tracelib_sys_exit, 1);
    }

    if (tracelib__load(e_skel)) {
        LOGE("tracelib__load/verify failed: %s", strerror(errno));
        goto fail;
    }

    if (cfg->syscall_filter_file[0]) {
        int afd = bpf_map__fd(e_skel->maps.allowed_syscalls);
        uint8_t one = 1;
        if (afd < 0) {
            LOGE("cannot access eBPF syscall allowlist map");
            goto fail;
        }
        for (size_t i = 0; i < cfg->syscall_allowlist_count; i++) {
            uint32_t nr = cfg->syscall_allowlist[i];
            if (bpf_map_update_elem(afd, &nr, &one, BPF_ANY) != 0) {
                LOGE("install syscall %u in eBPF allowlist: %s", nr, strerror(errno));
                goto fail;
            }
        }
    }

    pid_t *pids = NULL;
    int n = pid_discover(port, &pids);
    if (n == 0) {
        LOGE("no process found listening on port %u", port);
        goto fail;
    }
    int tfd = bpf_map__fd(e_skel->maps.target_tgids);
    for (int i = 0; i < n; i++) {
        uint32_t tgid = (uint32_t)pids[i];
        uint8_t one = 1;
        bpf_map_update_elem(tfd, &tgid, &one, BPF_ANY);
        LOGI("tracking tgid %u", tgid);
    }
    free(pids);

    int bfd = bpf_map__fd(e_skel->maps.bitmap);
    e_bm = mmap(NULL, 2 * MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, bfd, 0);
    if (e_bm == MAP_FAILED) {
        LOGE("mmap bitmap: %s", strerror(errno));
        e_bm = NULL;
        goto fail;
    }
    memset(e_bm, 0, 2 * MAP_SIZE);

    int cfd = bpf_map__fd(e_skel->maps.ctrl_map);
    uint32_t z = 0;
    struct ctrl_state cs = {0};
    cs.req_fd = -1;
    bpf_map_update_elem(cfd, &z, &cs, BPF_ANY);

    if (tracelib__attach(e_skel)) {
        LOGE("tracelib__attach failed: %s", strerror(errno));
        goto fail;
    }

    e_rb = ring_buffer__new(bpf_map__fd(e_skel->maps.events), ebpf_on_event, NULL, NULL);
    if (!e_rb) {
        LOGE("ring_buffer__new failed: %s", strerror(errno));
        goto fail;
    }

    memset(&e_cur, 0, sizeof(e_cur));
    return 0;

fail:
    if (e_bm) { munmap(e_bm, 2 * MAP_SIZE); e_bm = NULL; }
    if (e_skel) { tracelib__destroy(e_skel); e_skel = NULL; }
    return -1;
}

static void ebpf_run(void)
{
    while (!g_should_stop) {
        int r = ring_buffer__poll(e_rb, 200 );
        if (r < 0 && errno != EINTR)
            break;

        if (e_cur.active && now_ms() - e_cur.last_ms > 500) {
            LOGI("request idle-flush: %s", e_cur.id);
            ebpf_force_end_kernel();
            ebpf_finish(e_cur.idx, e_cur.id, e_cur.epoch);
        }
    }
}

static void ebpf_stop(void)
{
    if (e_cur.active) {
        ebpf_force_end_kernel();
        ebpf_finish(e_cur.idx, e_cur.id, e_cur.epoch);
    }
    if (e_rb) { ring_buffer__free(e_rb); e_rb = NULL; }
    if (e_bm) { munmap(e_bm, 2 * MAP_SIZE); e_bm = NULL; }
    if (e_skel) { tracelib__destroy(e_skel); e_skel = NULL; }
}

const struct collect_backend backend_ebpf = {
    .name = "ebpf",
    .available = ebpf_available,
    .start = ebpf_start,
    .run = ebpf_run,
    .stop = ebpf_stop,
};

#endif
