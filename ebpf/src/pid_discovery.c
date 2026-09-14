#include "pid_discovery.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>

#define LISTEN_STATE 0x0A
#define MAX_INODES   1024
#define MAX_PIDS     4096

static int collect_inodes(const char *file, uint16_t port,
                          unsigned long *inodes, int n_in, int cap)
{
    FILE *f = fopen(file, "r");
    if (!f)
        return n_in;

    char line[512];
    int first = 1;
    while (fgets(line, sizeof(line), f)) {
        if (first) { first = 0; continue; }
        unsigned local_port = 0, state = 0;
        unsigned long inode = 0;

        int got = sscanf(line,
            "%*u: %*[0-9A-Fa-f]:%X %*[0-9A-Fa-f]:%*X %X %*X:%*X %*X:%*X %*X %*u %*u %lu",
            &local_port, &state, &inode);
        if (got != 3)
            continue;
        if (state != LISTEN_STATE || (uint16_t)local_port != port)
            continue;
        if (inode == 0)
            continue;

        int seen = 0;
        for (int i = 0; i < n_in; i++)
            if (inodes[i] == inode) { seen = 1; break; }
        if (!seen && n_in < cap)
            inodes[n_in++] = inode;
    }
    fclose(f);
    return n_in;
}

static int inode_in_set(unsigned long inode, const unsigned long *inodes, int n)
{
    for (int i = 0; i < n; i++)
        if (inodes[i] == inode)
            return 1;
    return 0;
}

static int pid_owns_socket(pid_t pid, const unsigned long *inodes, int n)
{
    char dir[64];
    snprintf(dir, sizeof(dir), "/proc/%d/fd", (int)pid);
    DIR *d = opendir(dir);
    if (!d)
        return 0;

    int owns = 0;
    struct dirent *e;
    char linkpath[64 + 256 + 2], target[128];
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9')
            continue;
        snprintf(linkpath, sizeof(linkpath), "%s/%s", dir, e->d_name);
        ssize_t len = readlink(linkpath, target, sizeof(target) - 1);
        if (len <= 0)
            continue;
        target[len] = '\0';
        unsigned long ino;
        if (sscanf(target, "socket:[%lu]", &ino) == 1 && inode_in_set(ino, inodes, n)) {
            owns = 1;
            break;
        }
    }
    closedir(d);
    return owns;
}

int pid_discover(uint16_t port, pid_t **out)
{
    *out = NULL;

    unsigned long inodes[MAX_INODES];
    int n_ino = 0;
    n_ino = collect_inodes("/proc/net/tcp",  port, inodes, n_ino, MAX_INODES);
    n_ino = collect_inodes("/proc/net/tcp6", port, inodes, n_ino, MAX_INODES);
    if (n_ino == 0)
        return 0;

    pid_t *pids = calloc(MAX_PIDS, sizeof(pid_t));
    if (!pids)
        return 0;
    int n_pid = 0;
    pid_t self = getpid();

    DIR *proc = opendir("/proc");
    if (!proc) {
        free(pids);
        return 0;
    }
    struct dirent *e;
    while ((e = readdir(proc)) != NULL) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9')
            continue;
        pid_t pid = (pid_t)atoi(e->d_name);
        if (pid == self)
            continue;
        if (pid_owns_socket(pid, inodes, n_ino) && n_pid < MAX_PIDS)
            pids[n_pid++] = pid;
    }
    closedir(proc);

    if (n_pid == 0) {
        free(pids);
        return 0;
    }
    *out = pids;
    return n_pid;
}
