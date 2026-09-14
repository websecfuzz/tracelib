#include "backend.h"
#include "tracer.h"
#include "ngram.h"
#include "demux.h"
#include "bitmap.h"
#include "arghash.h"
#include "procmem.h"
#include "pid_discovery.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/user.h>
#include <sys/time.h>
#include <sys/syscall.h>

#ifndef __NR_openat2
#define __NR_openat2 437
#endif

static const struct config *cfg;
static volatile sig_atomic_t s_alarm;

static void on_alarm(int sig) { (void)sig; s_alarm = 1; }

static int is_write_family(long sc)
{
    return sc == __NR_write || sc == __NR_writev || sc == __NR_sendto;
}

static void demux_read_exit(pid_t pid, long sc, const unsigned long args[6], long ret)
{
    (void)sc;
    size_t n = (size_t)ret;
    if (n > 1024) n = 1024;
    char buf[1024];
    ssize_t got = pm_read(pid, (uintptr_t)args[1], buf, n);
    if (got > 0)
        demux_on_read((int)args[0], buf, (size_t)got);
}

static void demux_write_entry(pid_t pid, long sc, const unsigned long args[6])
{
    uintptr_t base; size_t len;
    if (sc == __NR_writev) {
        if (pm_read_iovec0(pid, (uintptr_t)args[1], &base, &len) != 0)
            return;
    } else {
        base = (uintptr_t)args[1];
        len  = (size_t)args[2];
    }
    if (len > 1024) len = 1024;
    char buf[1024];
    ssize_t got = pm_read(pid, base, buf, len);
    if (got > 0)
        demux_on_write((int)args[0], buf, (size_t)got);
}

static void record_syscall(pid_t pid, struct tracee *t, long sc, const unsigned long args[6])
{
    uint8_t *map = demux_active_map();
    if (!map)
        return;

    int allowed = config_syscall_allowed(cfg, sc);
    if (cfg->syscall_filter_file[0] && !allowed)
        return;

    int semantic_kind = ARG_SEMANTIC_NONE;
    uint8_t ah = compute_arg_hash_semantic(pid, sc, args, cfg, &semantic_kind);
    if (cfg->file_sql_only && semantic_kind == ARG_SEMANTIC_NONE)
        return;

    if (cfg->file_edges && cfg->mask[PARAM_FILE_EDGE] && arghash_is_open_family(sc)) {
        uint16_t cur = file_edge_loc(pid, sc, args);
        uint16_t idx = (uint16_t)((((t->prev_loc >> 1) ^ cur) ^ FILE_CHANNEL_SALT) & 0xFFFF);
        hit(map, idx);
        t->prev_loc = cur;
    }

    if (cfg->coverage_mode == COV_NGRAM) {
        if (allowed)
            ngram_record(map, t, (uint32_t)sc, ah, cfg->theta);
    } else if (config_bigram_separated(cfg)) {

        if (allowed)
            bitmap_record_bigram_separated(map, t->prev_syscall, (uint32_t)sc, ah,
                                           semantic_kind != ARG_SEMANTIC_NONE);
        t->prev_syscall = (uint32_t)sc;
        t->prev_arg_hash = ah;
    } else {
        if (allowed) {
            if (config_file_sql_pred_args(cfg))
                bitmap_record_bigram_pred(map, t->prev_syscall, t->prev_arg_hash,
                                          (uint32_t)sc, ah);
            else
                bitmap_record_bigram(map, t->prev_syscall, (uint32_t)sc, ah);
        }
        t->prev_syscall = (uint32_t)sc;
        t->prev_arg_hash = ah;
    }
}

static void handle_syscall(pid_t pid)
{
    struct user_regs_struct regs;
    if (ptrace(PTRACE_GETREGS, pid, 0, &regs) < 0) {
        if (errno == ESRCH) tracer_remove(pid);
        return;
    }
    long sc = (long)regs.orig_rax;
    unsigned long args[6] = { regs.rdi, regs.rsi, regs.rdx, regs.r10, regs.r8, regs.r9 };
    long rax = (long)regs.rax;

    struct tracee *t = tracer_add(pid);
    if (!t) return;
    demux_touch();

    if (rax == -ENOSYS) {
        if (is_write_family(sc))
            demux_write_entry(pid, sc, args);
        record_syscall(pid, t, sc, args);
    } else {
        if ((sc == __NR_read || sc == __NR_recvfrom) && rax > 0)
            demux_read_exit(pid, sc, args, rax);
    }
}

static void register_child(pid_t child)
{
    tracer_add(child);

}

static void handle_stop(pid_t pid, int status)
{
    unsigned ev = (unsigned)status >> 8;
    int sig = WSTOPSIG(status);
    int deliver = 0;

    if (!tracer_get(pid))
        tracer_add(pid);

    if (sig == (SIGTRAP | 0x80)) {
        handle_syscall(pid);
    } else if (ev == (SIGTRAP | (PTRACE_EVENT_FORK  << 8)) ||
               ev == (SIGTRAP | (PTRACE_EVENT_VFORK << 8)) ||
               ev == (SIGTRAP | (PTRACE_EVENT_CLONE << 8))) {
        unsigned long child = 0;
        if (ptrace(PTRACE_GETEVENTMSG, pid, 0, &child) == 0)
            register_child((pid_t)child);
    } else if (ev == (SIGTRAP | (PTRACE_EVENT_EXEC << 8))) {
        struct tracee *t = tracer_get(pid);
        if (t) tracer_reset_one(t);
    } else if (sig != SIGTRAP) {
        deliver = sig;
    }

    if (ptrace(PTRACE_SYSCALL, pid, 0, (void *)(long)deliver) < 0) {
        if (errno == ESRCH) tracer_remove(pid);
    }
}

static int read_ptrace_scope(void)
{
    FILE *f = fopen("/proc/sys/kernel/yama/ptrace_scope", "r");
    if (!f) return 0;
    int v = 0;
    if (fscanf(f, "%d", &v) != 1) v = 0;
    fclose(f);
    return v;
}

static int have_cap_sys_ptrace(void)
{
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return 0;
    char line[128];
    unsigned long long eff = 0;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "CapEff: %llx", &eff) == 1)
            break;
    }
    fclose(f);
    return (eff >> 19) & 1ULL;
}

static int ptrace_available(void)
{
    int scope = read_ptrace_scope();
    if (scope >= 3) return 0;
    if (scope >= 2) return have_cap_sys_ptrace();
    return 1;
}

static int ptrace_start(uint16_t port, const struct config *c)
{
    cfg = c;
    demux_init(cfg, tracer_reset_all_prev_syscall, tracer_fold_full_all);

    struct sigaction sa = {0};
    sa.sa_handler = on_alarm;
    sigaction(SIGALRM, &sa, NULL);
    struct itimerval it = { {0, 100000}, {0, 100000} };
    setitimer(ITIMER_REAL, &it, NULL);

    pid_t *pids = NULL;
    int n = pid_discover(port, &pids);
    if (n == 0) {
        LOGE("no process found listening on port %u", port);
        return -1;
    }
    int attached = 0;
    for (int i = 0; i < n; i++) {
        int a = tracer_attach_all_tids(pids[i]);
        LOGI("pid %d: attached %d TID(s)", (int)pids[i], a);
        attached += a;
    }
    free(pids);
    if (attached == 0) {
        LOGE("could not attach any TID (ptrace permission?). ptrace_scope=%d", read_ptrace_scope());
        return -1;
    }
    return 0;
}

static void ptrace_run(void)
{
    int status;
    pid_t pid;

    while (!g_should_stop) {

        while ((pid = waitpid(-1, &status, __WALL | WNOHANG)) > 0)
            handle_stop(pid, status);
        if (pid < 0 && errno == ECHILD)
            break;

        demux_maybe_flush_idle();

        pid = waitpid(-1, &status, __WALL);
        if (pid > 0)
            handle_stop(pid, status);
        else if (pid < 0) {
            if (errno == ECHILD) break;

        }
    }
}

static void ptrace_stop(void)
{
    demux_shutdown();
    struct itimerval it = {{0, 0}, {0, 0}};
    setitimer(ITIMER_REAL, &it, NULL);
}

const struct collect_backend backend_ptrace = {
    .name = "ptrace",
    .available = ptrace_available,
    .start = ptrace_start,
    .run = ptrace_run,
    .stop = ptrace_stop,
};
