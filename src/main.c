#include "bitmap.h"
#include "demux.h"
#include "pid_discovery.h"
#include "sql_detect.h"
#include "tracer.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/reg.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <unistd.h>

#define IDLE_FLUSH_MS 500
#define MAX_INITIAL_PIDS 256

static volatile sig_atomic_t g_stop;

static int g_ablate_no_arg_hash  = 0;
static int g_ablate_no_sql       = 0;
static int g_ablate_filter_sysc  = 0;

static int g_file_edges          = 0;

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
#ifdef SYS_send
    case SYS_send:
#endif
    case SYS_read:
    case SYS_recvfrom:
        return 1;
    default:
        return 0;
    }
}

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "Usage: %s --port <PORT> --header <HEADER_NAME>\n"
        "           [--no-arg-hash] [--no-sql] [--syscall-filter] [--file-edges]\n"
        "\n"
        "  --port             TCP port the target web server listens on\n"
        "  --header           HTTP header name whose value is the bitmap filename\n"
        "  --no-arg-hash      [RQ4] skip path/port/exec arg hashing\n"
        "                     (open/openat/execve/connect contribute 0 instead\n"
        "                     of their argument-derived hash)\n"
        "  --no-sql           [RQ4] skip SQL detection on write/sendto/writev —\n"
        "                     they contribute 0 instead of the SQL skeleton hash\n"
        "  --syscall-filter   [RQ4] only record bitmap edges for the curated\n"
        "                     interesting-syscall set (open/openat/execve/connect/\n"
        "                     write/sendto/writev/read/recvfrom). Other syscalls\n"
        "                     are still observed by the tracer (ptrace overhead\n"
        "                     unchanged) but excluded from the bitmap.\n"
        "  --file-edges       opt-in: additionally record file->file transition\n"
        "                     edges (open/openat/openat2, 16-bit salted channel)\n"
        "                     into the same bitmap. Default OFF — enabling it adds\n"
        "                     a signal absent from the default deterministic\n"
        "                     baseline.\n",
        argv0);
}

static ssize_t read_tracee_cstr(pid_t pid, unsigned long addr,
                                char *dst, size_t cap)
{
    if (cap == 0) return 0;
    if (addr == 0) { dst[0] = '\0'; return 0; }

    size_t filled = 0;
    while (filled + 1 < cap) {
        size_t want = cap - 1 - filled;
        if (want > 256) want = 256;
        struct iovec liov = { .iov_base = dst + filled, .iov_len = want };
        struct iovec riov = { .iov_base = (void *)(addr + filled),
                              .iov_len = want };
        ssize_t got = process_vm_readv(pid, &liov, 1, &riov, 1, 0);
        if (got <= 0) break;
        for (ssize_t i = 0; i < got; i++) {
            if (dst[filled + i] == '\0') {
                dst[filled + i] = '\0';
                return (ssize_t)(filled + i);
            }
        }
        filled += (size_t)got;
    }
    dst[filled] = '\0';
    return (ssize_t)filled;
}

static int read_first_iovec(pid_t pid, unsigned long iov_addr,
                            unsigned long *out_base, size_t *out_len)
{

    struct { unsigned long base; unsigned long len; } iov0;
    struct iovec liov = { .iov_base = &iov0, .iov_len = sizeof iov0 };
    struct iovec riov = { .iov_base = (void *)iov_addr,
                          .iov_len = sizeof iov0 };
    ssize_t got = process_vm_readv(pid, &liov, 1, &riov, 1, 0);
    if (got != (ssize_t)sizeof iov0) return -1;
    *out_base = iov0.base;
    *out_len  = iov0.len;
    return 0;
}

static int read_sockaddr_port(pid_t pid, unsigned long addr, socklen_t alen)
{
    if (alen > sizeof(struct sockaddr_storage)) {
        alen = sizeof(struct sockaddr_storage);
    }
    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof ss);
    struct iovec liov = { .iov_base = &ss, .iov_len = alen };
    struct iovec riov = { .iov_base = (void *)addr, .iov_len = alen };
    ssize_t got = process_vm_readv(pid, &liov, 1, &riov, 1, 0);
    if (got <= 0) return -1;

    if (ss.ss_family == AF_INET && alen >= sizeof(struct sockaddr_in)) {
        struct sockaddr_in *a = (struct sockaddr_in *)&ss;
        return ntohs(a->sin_port);
    }
    if (ss.ss_family == AF_INET6 && alen >= sizeof(struct sockaddr_in6)) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&ss;
        return ntohs(a->sin6_port);
    }
    return -1;
}

static uint8_t compute_arg_hash(pid_t pid, long nr,
                                unsigned long a0, unsigned long a1,
                                unsigned long a2)
{
    switch (nr) {
    case SYS_open: {
        if (g_ablate_no_arg_hash) return 0;
        char path[512];
        ssize_t n = read_tracee_cstr(pid, a0, path, sizeof path);
        if (n <= 0) return 0;
        return djb2_8(path, (size_t)n);
    }
    case SYS_openat: {
        if (g_ablate_no_arg_hash) return 0;
        char path[512];
        ssize_t n = read_tracee_cstr(pid, a1, path, sizeof path);
        if (n <= 0) return 0;
        return djb2_8(path, (size_t)n);
    }
    case SYS_execve: {
        if (g_ablate_no_arg_hash) return 0;
        char path[512];
        ssize_t n = read_tracee_cstr(pid, a0, path, sizeof path);
        if (n <= 0) return 0;
        return djb2_8(path, (size_t)n);
    }
    case SYS_connect: {
        if (g_ablate_no_arg_hash) return 0;
        int port = read_sockaddr_port(pid, a1, (socklen_t)a2);
        if (port < 0) return 0;
        return (uint8_t)(port & 0xFF);
    }
    case SYS_write:
    case SYS_sendto:
        if (g_ablate_no_sql) return 0;
        return detect_sql_hash(pid, a1, (size_t)a2);
#ifdef SYS_send
    case SYS_send:
        if (g_ablate_no_sql) return 0;
        return detect_sql_hash(pid, a1, (size_t)a2);
#endif
    case SYS_writev: {
        if (g_ablate_no_sql) return 0;

        unsigned long base = 0; size_t len = 0;
        if (read_first_iovec(pid, a1, &base, &len) != 0) return 0;
        return detect_sql_hash(pid, base, len);
    }
    default:
        return 0;
    }
}

static void feed_demux(pid_t pid, long nr, unsigned long a0, unsigned long a1,
                       unsigned long a2)
{
    switch (nr) {
    case SYS_write:
    case SYS_sendto:
        demux_on_write(pid, (int)a0, a1, (size_t)a2);
        break;
#ifdef SYS_send
    case SYS_send:
        demux_on_write(pid, (int)a0, a1, (size_t)a2);
        break;
#endif
    case SYS_writev: {
        unsigned long base = 0; size_t len = 0;
        if (read_first_iovec(pid, a1, &base, &len) == 0 && base && len) {
            demux_on_write(pid, (int)a0, base, len);
        }
        break;
    }
    default:
        break;
    }
}

static void on_syscall_stop(pid_t pid)
{
    struct user_regs_struct regs;
    if (ptrace(PTRACE_GETREGS, pid, 0, &regs) != 0) return;

    long nr = (long)regs.orig_rax;
    int is_entry = ((long long)regs.rax == -ENOSYS);

    if (is_entry) {
        unsigned long a0 = regs.rdi;
        unsigned long a1 = regs.rsi;
        unsigned long a2 = regs.rdx;

        feed_demux(pid, nr, a0, a1, a2);

        uint8_t *bm = demux_active_bitmap();
        uint32_t prev_sc = tracer_get_prev_syscall(pid);

        int record_this = (bm != NULL);
        if (record_this && g_ablate_filter_sysc && !syscall_is_interesting(nr)) {
            record_this = 0;
        }

        if (record_this) {
            uint8_t arg_hash = compute_arg_hash(pid, nr, a0, a1, a2);
            bitmap_record(bm, prev_sc, (uint32_t)nr, arg_hash);
        }

        if (g_file_edges && bm != NULL) {
            int is_open = (nr == SYS_open || nr == SYS_openat);
#ifdef SYS_openat2
            if (nr == SYS_openat2) is_open = 1;
#endif
            if (is_open) {
                unsigned long path_addr = (nr == SYS_open) ? a0 : a1;
                char path[512];
                ssize_t pn = read_tracee_cstr(pid, path_addr, path,
                                              sizeof path);
                if (pn > 0) {
                    uint16_t cur = bitmap_path_loc(path, (size_t)pn);
                    bitmap_record_file_edge(bm, tracer_get_prev_loc(pid), cur);
                    tracer_set_prev_loc(pid, cur);
                }
            }
        }

        tracer_set_prev_syscall(pid, (uint32_t)nr);
    } else {

        long long ret = (long long)regs.rax;
        if (ret > 0) {
            switch (nr) {
            case SYS_read:
            case SYS_recvfrom:
                demux_on_read(pid, (int)regs.rdi, regs.rsi, (size_t)ret);
                break;
            default:
                break;
            }
        }
    }

    demux_touch();
}

static int drain_events(int blocking)
{
    int processed = 0;

    for (;;) {
        int status = 0;
        pid_t pid;
        if (blocking && processed == 0) {
            pid = waitpid(-1, &status, __WALL);
        } else {
            pid = waitpid(-1, &status, __WALL | WNOHANG);
        }

        if (pid == 0) break;
        if (pid < 0) {
            if (errno == EINTR) continue;
            if (errno == ECHILD) return processed;
            break;
        }

        processed++;

        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            tracer_unregister(pid);
            continue;
        }

        if (!WIFSTOPPED(status)) {

            ptrace(PTRACE_SYSCALL, pid, 0, 0);
            continue;
        }

        int sig = WSTOPSIG(status);
        int inject = 0;

        if (sig == (SIGTRAP | 0x80)) {

            on_syscall_stop(pid);
            demux_touch();
        } else if (sig == SIGTRAP) {

            unsigned event = ((unsigned)status >> 16) & 0xFFFFu;
            if (event == PTRACE_EVENT_FORK ||
                event == PTRACE_EVENT_VFORK ||
                event == PTRACE_EVENT_CLONE) {
                unsigned long newpid = 0;
                if (ptrace(PTRACE_GETEVENTMSG, pid, 0, &newpid) == 0 &&
                    newpid > 0) {

                    if (!tracer_is_traced((pid_t)newpid)) {
                        tracer_register((pid_t)newpid);

                        tracer_set_options((pid_t)newpid);

                        ptrace(PTRACE_SYSCALL, (pid_t)newpid, 0, 0);
                    }
                }
            } else if (event == PTRACE_EVENT_EXEC) {

                tracer_set_prev_syscall(pid, 0);
                tracer_set_prev_loc(pid, 0);
            }

        } else {

            inject = sig;
        }

        if (ptrace(PTRACE_SYSCALL, pid, 0, (void *)(long)inject) != 0) {

            if (errno == ESRCH) tracer_unregister(pid);
        }
    }

    return processed;
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
            g_ablate_no_arg_hash = 1;
        } else if (strcmp(argv[i], "--no-sql") == 0) {
            g_ablate_no_sql = 1;
        } else if (strcmp(argv[i], "--syscall-filter") == 0) {
            g_ablate_filter_sysc = 1;
        } else if (strcmp(argv[i], "--file-edges") == 0) {
            g_file_edges = 1;
        } else if (strcmp(argv[i], "-h") == 0 ||
                   strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }
    if (port == 0 || !header || !*header) {
        usage(argv[0]);
        return 2;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    demux_init(header);

    pid_t pids[MAX_INITIAL_PIDS];
    int n = discover_pids(port, pids, MAX_INITIAL_PIDS);
    if (n < 0) {
        fprintf(stderr, "tracelib: pid discovery failed: %s\n",
                strerror(errno));
        return 1;
    }
    if (n == 0) {
        fprintf(stderr,
                "tracelib: no processes listening on port %u found\n",
                (unsigned)port);
        return 1;
    }

    int attached = 0;
    for (int i = 0; i < n; i++) {
        char task_dir[64];
        snprintf(task_dir, sizeof task_dir, "/proc/%d/task", (int)pids[i]);
        DIR *d = opendir(task_dir);
        int per_pid_attached = 0;
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)) != NULL) {
                if (!isdigit((unsigned char)e->d_name[0])) continue;
                char *endp = NULL;
                long v = strtol(e->d_name, &endp, 10);
                if (!endp || *endp != '\0' || v <= 0) continue;
                pid_t tid = (pid_t)v;
                if (tracer_is_traced(tid)) continue;
                if (tracer_attach(tid) == 0) {
                    attached++;
                    per_pid_attached++;
                } else {
                    fprintf(stderr,
                            "tracelib: attach failed for tid %d (pid %d): %s\n",
                            (int)tid, (int)pids[i], strerror(errno));
                }
            }
            closedir(d);
        }
        if (per_pid_attached == 0) {

            if (tracer_attach(pids[i]) == 0) {
                attached++;
            } else {
                fprintf(stderr,
                        "tracelib: attach failed for pid %d: %s\n",
                        (int)pids[i], strerror(errno));
            }
        }
    }
    if (attached == 0) {
        fprintf(stderr, "tracelib: no pids successfully attached\n");
        return 1;
    }

    fprintf(stderr,
            "tracelib: watching port %u, header '%s', %d pid(s) attached"
            " [arg_hash=%s sql=%s filter=%s file_edges=%s]\n",
            (unsigned)port, header, attached,
            g_ablate_no_arg_hash ? "off" : "on",
            g_ablate_no_sql      ? "off" : "on",
            g_ablate_filter_sysc ? "on"  : "off",
            g_file_edges         ? "on"  : "off");

    while (!g_stop) {
        int got = drain_events(0);
        if (got == 0) {

            demux_maybe_flush_idle(IDLE_FLUSH_MS);
            drain_events(1);
        }
        if (tracer_count() == 0) {
            fprintf(stderr, "tracelib: all tracees exited, shutting down\n");
            break;
        }
    }

    demux_finalise();
    return 0;
}
