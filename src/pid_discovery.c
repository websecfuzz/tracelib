#include "pid_discovery.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_LISTEN_INODES 64

static int collect_listen_inodes(const char *path, uint16_t port,
                                 uint64_t *inodes, int max_inodes, int count)
{
    FILE *f = fopen(path, "r");
    if (!f) {

        return count;
    }

    char line[1024];

    if (!fgets(line, sizeof line, f)) {
        fclose(f);
        return count;
    }

    while (fgets(line, sizeof line, f)) {

        char local_addr[128];
        char rem_addr[128];
        unsigned state = 0;
        unsigned long tx = 0, rx = 0;
        unsigned long tr = 0, tm_when = 0;
        unsigned long retrnsmt = 0;
        unsigned long uid = 0;
        unsigned long timeout = 0;
        unsigned long inode = 0;

        int n = sscanf(line,
                       " %*u: %127s %127s %x %lx:%lx %lx:%lx %lx %lu %lu %lu",
                       local_addr, rem_addr, &state,
                       &tx, &rx, &tr, &tm_when, &retrnsmt,
                       &uid, &timeout, &inode);
        if (n < 11) continue;
        if (state != 0x0A) continue;

        const char *colon = strrchr(local_addr, ':');
        if (!colon) continue;
        unsigned port_hex = 0;
        if (sscanf(colon + 1, "%x", &port_hex) != 1) continue;
        if ((uint16_t)port_hex != port) continue;

        if (count < max_inodes) {
            inodes[count++] = inode;
        }
    }

    fclose(f);
    return count;
}

static int fd_links_to_listen_inode(const char *link_path,
                                    const uint64_t *inodes, int n_inodes)
{
    char target[128];
    ssize_t r = readlink(link_path, target, sizeof target - 1);
    if (r <= 0) return 0;
    target[r] = '\0';

    if (strncmp(target, "socket:[", 8) != 0) return 0;
    char *endp = NULL;
    unsigned long ino = strtoul(target + 8, &endp, 10);
    if (!endp || *endp != ']') return 0;

    for (int i = 0; i < n_inodes; i++) {
        if (inodes[i] == (uint64_t)ino) return 1;
    }
    return 0;
}

static int pid_has_listen_fd(pid_t pid, const uint64_t *inodes, int n_inodes)
{
    char dir[64];
    snprintf(dir, sizeof dir, "/proc/%d/fd", (int)pid);

    DIR *d = opendir(dir);
    if (!d) return 0;

    int matched = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;

        if (!isdigit((unsigned char)e->d_name[0])) continue;

        char link_path[96 + sizeof ((struct dirent *)0)->d_name];
        snprintf(link_path, sizeof link_path, "%s/%s", dir, e->d_name);
        if (fd_links_to_listen_inode(link_path, inodes, n_inodes)) {
            matched = 1;
            break;
        }
    }
    closedir(d);
    return matched;
}

int discover_pids(uint16_t port, pid_t *out_pids, int max_pids)
{
    if (!out_pids || max_pids <= 0) {
        errno = EINVAL;
        return -1;
    }

    uint64_t inodes[MAX_LISTEN_INODES];
    int n_inodes = 0;

    n_inodes = collect_listen_inodes("/proc/net/tcp", port, inodes,
                                     MAX_LISTEN_INODES, n_inodes);
    n_inodes = collect_listen_inodes("/proc/net/tcp6", port, inodes,
                                     MAX_LISTEN_INODES, n_inodes);

    if (n_inodes == 0) {

        return 0;
    }

    DIR *proc = opendir("/proc");
    if (!proc) return -1;

    int count = 0;
    struct dirent *e;
    while ((e = readdir(proc)) != NULL && count < max_pids) {
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        char *endp = NULL;
        long v = strtol(e->d_name, &endp, 10);
        if (!endp || *endp != '\0') continue;
        if (v <= 0) continue;

        pid_t pid = (pid_t)v;
        if (pid == getpid()) continue;

        if (pid_has_listen_fd(pid, inodes, n_inodes)) {
            out_pids[count++] = pid;
        }
    }
    closedir(proc);
    return count;
}
