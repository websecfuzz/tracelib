#include "tracer.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/types.h>
#include <sys/user.h>
#include <sys/wait.h>

#ifndef PTRACE_SEIZE
#define PTRACE_SEIZE 0x4206
#endif
#ifndef PTRACE_INTERRUPT
#define PTRACE_INTERRUPT 0x4207
#endif
#ifndef PTRACE_O_EXITKILL
#define PTRACE_O_EXITKILL (1 << 20)
#endif

#define MAX_TRACED 4096

struct entry {
    pid_t pid;
    uint32_t prev_syscall;
    uint32_t prev_loc;
};

static struct entry g_table[MAX_TRACED];
static int g_count;

static unsigned hash_pid(pid_t pid)
{

    uint32_t x = (uint32_t)pid * 2654435761u;
    return (unsigned)(x & (MAX_TRACED - 1));
}

static struct entry *lookup(pid_t pid)
{
    if (pid <= 0) return NULL;
    unsigned i = hash_pid(pid);
    for (unsigned probe = 0; probe < MAX_TRACED; probe++) {
        struct entry *e = &g_table[(i + probe) & (MAX_TRACED - 1)];
        if (e->pid == 0) return NULL;
        if (e->pid == pid) return e;
    }
    return NULL;
}

static struct entry *insert(pid_t pid)
{
    if (pid <= 0 || g_count >= MAX_TRACED - 1) return NULL;
    unsigned i = hash_pid(pid);
    for (unsigned probe = 0; probe < MAX_TRACED; probe++) {
        struct entry *e = &g_table[(i + probe) & (MAX_TRACED - 1)];
        if (e->pid == 0) {
            e->pid = pid;
            e->prev_syscall = 0;
            e->prev_loc = 0;
            g_count++;
            return e;
        }
        if (e->pid == pid) return e;
    }
    return NULL;
}

int tracer_set_options(pid_t pid)
{
    long opts = PTRACE_O_TRACESYSGOOD
              | PTRACE_O_TRACEFORK
              | PTRACE_O_TRACEVFORK
              | PTRACE_O_TRACECLONE
              | PTRACE_O_TRACEEXEC
              | PTRACE_O_EXITKILL;
    if (ptrace(PTRACE_SETOPTIONS, pid, 0, (void *)opts) != 0) {
        return -1;
    }
    return 0;
}

int tracer_register(pid_t pid)
{
    if (!insert(pid)) return -1;
    return 0;
}

void tracer_unregister(pid_t pid)
{
    struct entry *e = lookup(pid);
    if (!e) return;
    e->pid = 0;
    e->prev_syscall = 0;
    e->prev_loc = 0;
    g_count--;
}

int tracer_count(void)
{
    return g_count;
}

int tracer_is_traced(pid_t pid)
{
    return lookup(pid) != NULL;
}

int tracer_syscall_is_entry(pid_t pid)
{
    struct user_regs_struct regs;
    if (ptrace(PTRACE_GETREGS, pid, 0, &regs) != 0) return 0;

    return (long long)regs.rax == -ENOSYS;
}

uint32_t tracer_get_prev_syscall(pid_t pid)
{
    struct entry *e = lookup(pid);
    return e ? e->prev_syscall : 0;
}

void tracer_set_prev_syscall(pid_t pid, uint32_t nr)
{
    struct entry *e = lookup(pid);
    if (e) e->prev_syscall = nr;
}

uint32_t tracer_get_prev_loc(pid_t pid)
{
    struct entry *e = lookup(pid);
    return e ? e->prev_loc : 0;
}

void tracer_set_prev_loc(pid_t pid, uint32_t loc)
{
    struct entry *e = lookup(pid);
    if (e) e->prev_loc = loc;
}

void tracer_reset_all_prev_chains(void)
{
    for (unsigned i = 0; i < MAX_TRACED; i++) {
        if (g_table[i].pid != 0) {
            g_table[i].prev_syscall = 0;
            g_table[i].prev_loc = 0;
        }
    }
}

int tracer_attach(pid_t pid)
{
    if (pid <= 0) { errno = EINVAL; return -1; }

    long opts = PTRACE_O_TRACESYSGOOD
              | PTRACE_O_TRACEFORK
              | PTRACE_O_TRACEVFORK
              | PTRACE_O_TRACECLONE
              | PTRACE_O_TRACEEXEC
              | PTRACE_O_EXITKILL;

    if (ptrace(PTRACE_SEIZE, pid, 0, (void *)opts) == 0) {
        if (ptrace(PTRACE_INTERRUPT, pid, 0, 0) != 0) return -1;
        int status = 0;
        if (waitpid(pid, &status, __WALL) < 0) return -1;
    } else {
        if (ptrace(PTRACE_ATTACH, pid, 0, 0) != 0) return -1;

        int status = 0;
        if (waitpid(pid, &status, __WALL) < 0) return -1;
        if (tracer_set_options(pid) != 0) return -1;
    }

    if (!insert(pid)) return -1;

    if (ptrace(PTRACE_SYSCALL, pid, 0, 0) != 0) {
        return -1;
    }

    return 0;
}
