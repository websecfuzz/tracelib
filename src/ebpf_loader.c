#include "demux.h"
#include "ebpf_replay.h"
#include "pid_discovery.h"
#include "tl_ebpf.h"

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IDLE_FLUSH_MS    500
#define MAX_INITIAL_PIDS 256
#define MAX_PROC         65536

static volatile sig_atomic_t g_stop;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

static int g_no_arg_hash, g_no_sql, g_filter, g_file_edges;

static void usage(const char *a0)
{
    fprintf(stderr,
        "Usage: %s --port <PORT> --header <HEADER_NAME>\n"
        "           [--no-arg-hash] [--no-sql] [--syscall-filter] [--file-edges]\n"
        "\n"
        "eBPF variant of tracelib: same bitmap semantics, captured via BPF\n"
        "tracepoints + ring buffer instead of ptrace. Needs CAP_BPF/CAP_PERFMON\n"
        "(or root) and a BTF-enabled kernel; needs NO SYS_PTRACE.\n"
        "  --port            TCP port the target web server listens on\n"
        "  --header          HTTP header name whose value is the bitmap filename\n"
        "  --no-arg-hash     skip path/port/exec arg hashing\n"
        "  --no-sql          skip SQL detection on write/sendto/writev\n"
        "  --syscall-filter  record edges only for the interesting-syscall set\n"
        "  --file-edges      additionally record file->file open transitions\n"
        "Env:\n"
        "  TRACELIB_BPF_OBJ  path to tracelib.bpf.o (default: next to this binary)\n",
        a0);
}

static int libbpf_print(enum libbpf_print_level level, const char *fmt,
                        va_list args)
{
    if (level == LIBBPF_DEBUG) return 0;
    return vfprintf(stderr, fmt, args);
}

static const char *resolve_bpf_obj(char *buf, size_t cap)
{
    const char *env = getenv("TRACELIB_BPF_OBJ");
    if (env && *env) return env;

    char exe[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n > 0) {
        exe[n] = '\0';
        char *dir = dirname(exe);
        snprintf(buf, cap, "%s/tracelib.bpf.o", dir);
        if (access(buf, R_OK) == 0) return buf;
    }
    if (access("build/tracelib.bpf.o", R_OK) == 0) return "build/tracelib.bpf.o";
    return "tracelib.bpf.o";
}

static void add_tgid(int map_fd, uint32_t tgid)
{
    uint8_t one = 1;
    bpf_map_update_elem(map_fd, &tgid, &one, BPF_ANY);
}

static int read_ppid(int pid)
{
    char path[64], line[512];
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t got = fread(line, 1, sizeof line - 1, f);
    fclose(f);
    if (got == 0) return -1;
    line[got] = '\0';

    char *rp = strrchr(line, ')');
    if (!rp) return -1;
    int state; int ppid = -1;
    if (sscanf(rp + 1, " %c %d", (char *)&state, &ppid) >= 2) return ppid;
    return -1;
}

static void add_descendants(int map_fd, const pid_t *seeds, int nseeds)
{
    static int pids[MAX_PROC];
    static int ppids[MAX_PROC];
    static char watched[MAX_PROC];
    int np = 0;

    DIR *d = opendir("/proc");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL && np < MAX_PROC) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int pid = atoi(de->d_name);
        if (pid <= 0) continue;
        pids[np] = pid;
        ppids[np] = read_ppid(pid);
        watched[np] = 0;
        np++;
    }
    closedir(d);

    for (int i = 0; i < np; i++)
        for (int s = 0; s < nseeds; s++)
            if (pids[i] == (int)seeds[s]) watched[i] = 1;

    int changed = 1, passes = 0;
    while (changed && passes++ < 64) {
        changed = 0;
        for (int i = 0; i < np; i++) {
            if (watched[i]) continue;
            for (int j = 0; j < np; j++) {
                if (watched[j] && pids[j] == ppids[i]) {
                    watched[i] = 1;
                    changed = 1;
                    break;
                }
            }
        }
    }
    for (int i = 0; i < np; i++)
        if (watched[i]) add_tgid(map_fd, (uint32_t)pids[i]);
}

static int g_debug;
static unsigned long g_ev_count;

static int handle_event(void *ctx, void *data, size_t size)
{
    (void)ctx;
    if (size < TL_EVENT_HDR_SIZE) return 0;
    const struct tl_event *e = data;
    g_ev_count++;
    if (g_debug && (e->flags & TL_F_HASPAYLOAD) && e->payload_len) {
        int show = (int)(e->payload_len > 48 ? 48 : e->payload_len);
        fprintf(stderr, "[ev] nr=%d flags=0x%x fd=%d len=%u '%.*s'\n",
                e->nr, e->flags, e->fd, e->payload_len, show, e->payload);
    }
    tl_replay_event(e);
    return 0;
}

int main(int argc, char **argv)
{
    uint16_t port = 0;
    const char *header = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            long v = strtol(argv[++i], NULL, 10);
            if (v <= 0 || v > 65535) { usage(argv[0]); return 2; }
            port = (uint16_t)v;
        } else if (strcmp(argv[i], "--header") == 0 && i + 1 < argc) {
            header = argv[++i];
        } else if (strcmp(argv[i], "--no-arg-hash") == 0) {
            g_no_arg_hash = 1;
        } else if (strcmp(argv[i], "--no-sql") == 0) {
            g_no_sql = 1;
        } else if (strcmp(argv[i], "--syscall-filter") == 0) {
            g_filter = 1;
        } else if (strcmp(argv[i], "--file-edges") == 0) {
            g_file_edges = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]); return 0;
        } else {
            usage(argv[0]); return 2;
        }
    }
    if (port == 0 || !header || !*header) { usage(argv[0]); return 2; }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    demux_init(header);
    tl_replay_config(g_no_arg_hash, g_no_sql, g_filter, g_file_edges);

    pid_t pids[MAX_INITIAL_PIDS];
    int n = discover_pids(port, pids, MAX_INITIAL_PIDS);
    if (n < 0) {
        fprintf(stderr, "tracelib-ebpf: pid discovery failed: %s\n",
                strerror(errno));
        return 1;
    }
    if (n == 0) {
        fprintf(stderr, "tracelib-ebpf: no processes listening on port %u\n",
                (unsigned)port);
        return 1;
    }

    libbpf_set_print(libbpf_print);

    char objbuf[PATH_MAX];
    const char *obj_path = resolve_bpf_obj(objbuf, sizeof objbuf);

    struct bpf_object *obj = bpf_object__open_file(obj_path, NULL);
    if (!obj || libbpf_get_error(obj)) {
        fprintf(stderr, "tracelib-ebpf: cannot open BPF object '%s': %s\n",
                obj_path, strerror(errno));
        return 1;
    }
    if (bpf_object__load(obj) != 0) {
        fprintf(stderr, "tracelib-ebpf: BPF load/verify failed for '%s' "
                "(need CAP_BPF/CAP_PERFMON or root, and a BTF kernel)\n",
                obj_path);
        bpf_object__close(obj);
        return 1;
    }

    int watched_fd = bpf_object__find_map_fd_by_name(obj, "watched_tgids");
    int events_fd  = bpf_object__find_map_fd_by_name(obj, "events");
    if (watched_fd < 0 || events_fd < 0) {
        fprintf(stderr, "tracelib-ebpf: missing maps in BPF object\n");
        bpf_object__close(obj);
        return 1;
    }

    for (int i = 0; i < n; i++) add_tgid(watched_fd, (uint32_t)pids[i]);
    add_descendants(watched_fd, pids, n);

    struct bpf_program *prog;
    int attached = 0;
    bpf_object__for_each_program(prog, obj) {
        struct bpf_link *link = bpf_program__attach(prog);
        if (!link || libbpf_get_error(link)) {
            fprintf(stderr, "tracelib-ebpf: attach failed for %s\n",
                    bpf_program__name(prog));
        } else {
            attached++;
        }
    }
    if (attached == 0) {
        fprintf(stderr, "tracelib-ebpf: no programs attached\n");
        bpf_object__close(obj);
        return 1;
    }

    struct ring_buffer *rb = ring_buffer__new(events_fd, handle_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "tracelib-ebpf: ring_buffer__new failed\n");
        bpf_object__close(obj);
        return 1;
    }

    fprintf(stderr,
        "tracelib-ebpf: watching port %u, header '%s', %d pid(s) seeded, "
        "%d prog(s) attached [ebpf] "
        "[arg_hash=%s sql=%s filter=%s file_edges=%s]\n",
        (unsigned)port, header, n, attached,
        g_no_arg_hash ? "off" : "on",
        g_no_sql      ? "off" : "on",
        g_filter      ? "on"  : "off",
        g_file_edges  ? "on"  : "off");

    while (!g_stop) {
        int err = ring_buffer__poll(rb, 200 );
        if (err < 0 && err != -EINTR) {
            fprintf(stderr, "tracelib-ebpf: ring_buffer__poll: %d\n", err);
            break;
        }
        demux_maybe_flush_idle(IDLE_FLUSH_MS);
    }

    demux_finalise();
    ring_buffer__free(rb);
    bpf_object__close(obj);
    return 0;
}
