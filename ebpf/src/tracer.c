#include "tracer.h"
#include "ngram.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>
#include <signal.h>
#include <sys/ptrace.h>
#include <sys/wait.h>

#define TOMBSTONE ((pid_t)-1)

static struct tracee g_tab[MAX_TRACED];
static int g_count;

static unsigned slot_index(pid_t pid)
{

    uint32_t h = (uint32_t)pid * 2654435761u;
    return (unsigned)(h >> (32 - 12));
}

static void tracee_init(struct tracee *t, pid_t pid)
{
    memset(t, 0, sizeof(*t));
    t->pid = pid;
    t->full_hash = FNV_OFFSET;
}

struct tracee *tracer_get(pid_t pid)
{
    unsigned i = slot_index(pid);
    for (unsigned probe = 0; probe < MAX_TRACED; probe++) {
        struct tracee *t = &g_tab[(i + probe) & (MAX_TRACED - 1)];
        if (t->pid == 0)
            return NULL;
        if (t->pid == pid)
            return t;

    }
    return NULL;
}

struct tracee *tracer_add(pid_t pid)
{
    unsigned i = slot_index(pid);
    struct tracee *tomb = NULL;
    for (unsigned probe = 0; probe < MAX_TRACED; probe++) {
        struct tracee *t = &g_tab[(i + probe) & (MAX_TRACED - 1)];
        if (t->pid == pid)
            return t;
        if (t->pid == TOMBSTONE) {
            if (!tomb) tomb = t;
            continue;
        }
        if (t->pid == 0) {
            struct tracee *slot = tomb ? tomb : t;
            tracee_init(slot, pid);
            g_count++;
            return slot;
        }
    }
    if (tomb) {
        tracee_init(tomb, pid);
        g_count++;
        return tomb;
    }
    LOGE("tracee table full (%d) — dropping pid %d", MAX_TRACED, (int)pid);
    return NULL;
}

void tracer_remove(pid_t pid)
{
    struct tracee *t = tracer_get(pid);
    if (t) {
        t->pid = TOMBSTONE;
        g_count--;
    }
}

int tracer_count(void) { return g_count; }

void tracer_reset_one(struct tracee *t)
{
    pid_t pid = t->pid;
    tracee_init(t, pid);
}

void tracer_reset_all_prev_syscall(void)
{
    for (int i = 0; i < MAX_TRACED; i++) {
        if (g_tab[i].pid != 0 && g_tab[i].pid != TOMBSTONE)
            tracer_reset_one(&g_tab[i]);
    }
}

void tracer_fold_full_all(uint8_t *map)
{
    for (int i = 0; i < MAX_TRACED; i++) {
        if (g_tab[i].pid != 0 && g_tab[i].pid != TOMBSTONE)
            ngram_fold_full_one(map, &g_tab[i]);
    }
}

static const long ATTACH_OPTS =
    PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK |
    PTRACE_O_TRACECLONE   | PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL;

int tracer_attach_one(pid_t tid)
{
    if (tid == getpid())
        return -1;
    if (tracer_get(tid))
        return 0;

    if (ptrace(PTRACE_SEIZE, tid, 0, ATTACH_OPTS) == 0) {

        ptrace(PTRACE_INTERRUPT, tid, 0, 0);
        int st;
        waitpid(tid, &st, __WALL);
        ptrace(PTRACE_SYSCALL, tid, 0, 0);
        tracer_add(tid);
        return 0;
    }

    if (ptrace(PTRACE_ATTACH, tid, 0, 0) == 0) {
        int st;
        waitpid(tid, &st, __WALL);
        ptrace(PTRACE_SETOPTIONS, tid, 0, ATTACH_OPTS);
        ptrace(PTRACE_SYSCALL, tid, 0, 0);
        tracer_add(tid);
        return 0;
    }

    return -1;
}

int tracer_attach_all_tids(pid_t pid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/task", (int)pid);
    DIR *d = opendir(path);
    if (!d) {
        LOGE("opendir(%s): %s", path, strerror(errno));
        return 0;
    }
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9')
            continue;
        pid_t tid = (pid_t)atoi(e->d_name);
        if (tracer_attach_one(tid) == 0)
            n++;
    }
    closedir(d);
    return n;
}
