#include "demux.h"
#include "tracer.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <unistd.h>

#define REQUEST_ID_MAX 127
#define HEADER_NAME_MAX 64
#define DEMUX_SCAN_BYTES 4096

static struct {
    char header_name[HEADER_NAME_MAX + 1];
    size_t header_name_len;

    int active;
    char request_id[REQUEST_ID_MAX + 1];

    uint8_t *bitmap;
    int bitmap_fd;

    int request_fd;

    long long last_activity_ms;
} S;

static long long now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000LL + (long long)tv.tv_usec / 1000LL;
}

static void lower_copy(char *dst, const char *src, size_t n)
{
    size_t i;
    for (i = 0; i + 1 < n && src[i]; i++) {
        dst[i] = (char)tolower((unsigned char)src[i]);
    }
    dst[i] = '\0';
}

void demux_init(const char *header_name)
{
    memset(&S, 0, sizeof S);
    if (!header_name) header_name = "";
    lower_copy(S.header_name, header_name, sizeof S.header_name);
    S.header_name_len = strlen(S.header_name);
    S.request_fd = -1;
    S.bitmap_fd = -1;
    S.last_activity_ms = now_ms();
}

uint8_t *demux_active_bitmap(void)
{
    return S.active ? S.bitmap : NULL;
}

int demux_has_active_request(void)
{
    return S.active;
}

void demux_touch(void)
{
    S.last_activity_ms = now_ms();
}

static const char *find_header_value(const char *buf, size_t buf_len,
                                     size_t *out_len)
{
    if (S.header_name_len == 0) return NULL;

    size_t i = 0;
    while (i < buf_len) {
        size_t line_start = i;
        while (i < buf_len && buf[i] != '\n') i++;

        size_t line_end = i;
        if (line_end > line_start && buf[line_end - 1] == '\r') line_end--;

        size_t line_len = line_end - line_start;

        if (line_len >= S.header_name_len + 2) {

            int match = 1;
            for (size_t k = 0; k < S.header_name_len; k++) {
                unsigned char a = (unsigned char)buf[line_start + k];
                unsigned char b = (unsigned char)S.header_name[k];
                if (tolower(a) != b) { match = 0; break; }
            }
            if (match && buf[line_start + S.header_name_len] == ':') {

                size_t vs = line_start + S.header_name_len + 1;
                while (vs < line_end && (buf[vs] == ' ' || buf[vs] == '\t'))
                    vs++;
                size_t ve = line_end;
                while (ve > vs &&
                       (buf[ve - 1] == ' ' || buf[ve - 1] == '\t'))
                    ve--;
                *out_len = ve - vs;
                return buf + vs;
            }
        }

        if (i < buf_len && buf[i] == '\n') i++;
    }
    return NULL;
}

static int normalise_request_id(const char *v, size_t vl, char *out)
{
    if (vl == 0 || vl > REQUEST_ID_MAX) return 0;
    for (size_t i = 0; i < vl; i++) {
        unsigned char c = (unsigned char)v[i];
        if (!(isalnum(c) || c == '-' || c == '_')) return 0;
        out[i] = (char)c;
    }
    out[vl] = '\0';
    return 1;
}

static size_t read_tracee_bytes(pid_t pid, unsigned long addr,
                                char *dst, size_t want)
{
    if (addr == 0 || want == 0) return 0;
    struct iovec liov = { .iov_base = dst, .iov_len = want };
    struct iovec riov = { .iov_base = (void *)addr, .iov_len = want };
    ssize_t got = process_vm_readv(pid, &liov, 1, &riov, 1, 0);
    if (got <= 0) return 0;
    return (size_t)got;
}

static uint8_t *open_shm_bitmap(const char *id, int *out_fd)
{
    char path[sizeof "/dev/shm/" + REQUEST_ID_MAX + 1];
    snprintf(path, sizeof path, "/dev/shm/%s", id);

    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
    if (fd < 0) return NULL;

    fchmod(fd, 0666);

    if (ftruncate(fd, TRACELIB_MAP_SIZE) != 0) {
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, TRACELIB_MAP_SIZE, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        close(fd);
        return NULL;
    }

    memset(p, 0, TRACELIB_MAP_SIZE);
    *out_fd = fd;
    return (uint8_t *)p;
}

static void close_shm_bitmap(void)
{
    if (S.bitmap) {

        msync(S.bitmap, TRACELIB_MAP_SIZE, MS_SYNC);
        munmap(S.bitmap, TRACELIB_MAP_SIZE);
        S.bitmap = NULL;
    }
    if (S.bitmap_fd >= 0) {
        close(S.bitmap_fd);
        S.bitmap_fd = -1;
    }
}

int demux_finalise(void)
{
    if (!S.active) return 0;
    close_shm_bitmap();
    S.active = 0;
    S.request_id[0] = '\0';
    S.request_fd = -1;
    return 1;
}

static void start_new_request(const char *id, int fd)
{

    if (S.active) {
        close_shm_bitmap();
        S.active = 0;
    }

    int bmfd = -1;
    uint8_t *p = open_shm_bitmap(id, &bmfd);
    if (!p) {
        S.request_id[0] = '\0';
        S.request_fd = -1;
        return;
    }
    S.bitmap = p;
    S.bitmap_fd = bmfd;
    strncpy(S.request_id, id, REQUEST_ID_MAX);
    S.request_id[REQUEST_ID_MAX] = '\0';
    S.active = 1;
    S.request_fd = fd;
    tracer_reset_all_prev_chains();
    demux_touch();
}

void demux_begin_request(const char *request_id)
{
    if (!request_id) return;
    char id[REQUEST_ID_MAX + 1];
    size_t vl = strlen(request_id);
    if (!normalise_request_id(request_id, vl, id)) return;
    start_new_request(id, -1);
}

void demux_on_write_buf(int fd, const char *buf, size_t buf_len)
{
    demux_touch();

    if (!buf) return;
    size_t got = buf_len;
    if (got == 0) return;
    if (got > DEMUX_SCAN_BYTES) got = DEMUX_SCAN_BYTES;

    size_t vlen = 0;
    const char *vp = find_header_value(buf, got, &vlen);
    if (vp) {
        char id[REQUEST_ID_MAX + 1];
        if (normalise_request_id(vp, vlen, id)) {

            if (!S.active || strcmp(S.request_id, id) != 0) {
                start_new_request(id, fd);
                return;
            }
        }
    }

    if (S.active && got >= 7 && memcmp(buf, "HTTP/1.", 7) == 0) {
        if (S.request_fd == -1 || fd != S.request_fd) {
            demux_finalise();
        }
    }
}

void demux_on_read_buf(int fd, const char *buf, size_t buf_len)
{
    (void)fd;
    demux_touch();

    if (!buf) return;
    size_t got = buf_len;
    if (got == 0) return;
    if (got > DEMUX_SCAN_BYTES) got = DEMUX_SCAN_BYTES;

    size_t vlen = 0;
    const char *vp = find_header_value(buf, got, &vlen);
    if (!vp) return;

    char id[REQUEST_ID_MAX + 1];
    if (!normalise_request_id(vp, vlen, id)) return;

    if (S.active && strcmp(S.request_id, id) == 0) return;

    start_new_request(id, -1);
}

void demux_on_write(pid_t pid, int fd, unsigned long buf_addr, size_t buf_len)
{

    char local[DEMUX_SCAN_BYTES];
    size_t want = buf_len;
    if (want == 0 || want > sizeof local) want = sizeof local;
    size_t got = read_tracee_bytes(pid, buf_addr, local, want);
    if (got == 0) { demux_touch(); return; }
    demux_on_write_buf(fd, local, got);
}

void demux_on_read(pid_t pid, int fd, unsigned long buf_addr, size_t buf_len)
{
    char local[DEMUX_SCAN_BYTES];
    size_t want = buf_len;
    if (want == 0 || want > sizeof local) want = sizeof local;
    size_t got = read_tracee_bytes(pid, buf_addr, local, want);
    if (got == 0) { demux_touch(); return; }
    demux_on_read_buf(fd, local, got);
}

int demux_maybe_flush_idle(unsigned idle_ms)
{
    if (!S.active) return 0;
    long long diff = now_ms() - S.last_activity_ms;
    if (diff >= (long long)idle_ms) {
        return demux_finalise();
    }
    return 0;
}
