#include "demux.h"
#include "bitmap.h"
#include "util.h"

#include <ctype.h>
#include <string.h>

static const struct config *g_cfg;
static demux_start_cb       g_on_start;
static demux_finalize_cb    g_on_finalize;

static struct reqmap g_active;
static int           g_req_fd = -1;
static uint64_t      g_last_ms;

void demux_init(const struct config *cfg, demux_start_cb on_start, demux_finalize_cb on_finalize)
{
    g_cfg = cfg;
    g_on_start = on_start;
    g_on_finalize = on_finalize;
    g_active.map = NULL;
    g_active.fd = -1;
    g_req_fd = -1;
    g_last_ms = now_ms();
}

uint8_t *demux_active_map(void) { return g_active.map; }
void     demux_touch(void)      { g_last_ms = now_ms(); }

size_t demux_find_header_value(const char *buf, size_t len,
                               const char *header_lc, size_t header_len,
                               char *out, size_t outcap)
{
    if (outcap == 0) return 0;
    out[0] = '\0';
    if (header_len == 0)
        return 0;

    size_t i = 0;
    while (i < len) {

        size_t j = i;
        while (j < len && buf[j] != '\n')
            j++;
        size_t e = j;
        if (e > i && buf[e - 1] == '\r')
            e--;

        if (e - i > header_len) {
            int match = 1;
            for (size_t k = 0; k < header_len; k++) {
                if ((char)tolower((unsigned char)buf[i + k]) != header_lc[k]) {
                    match = 0;
                    break;
                }
            }
            if (match && buf[i + header_len] == ':') {
                size_t v = i + header_len + 1;
                while (v < e && (buf[v] == ' ' || buf[v] == '\t')) v++;
                size_t ve = e;
                while (ve > v && (buf[ve - 1] == ' ' || buf[ve - 1] == '\t')) ve--;
                size_t vl = ve - v;
                if (vl > outcap - 1) vl = outcap - 1;
                memcpy(out, buf + v, vl);
                out[vl] = '\0';
                return vl;
            }
        }
        i = (j < len) ? j + 1 : len;
    }
    return 0;
}

int demux_normalize_request_id(const char *value, char *out, size_t outcap)
{
    size_t o = 0;
    for (size_t i = 0; value[i] && o + 1 < outcap && o < 127; i++) {
        char c = value[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-')
            out[o++] = c;
    }
    out[o] = '\0';
    return o > 0;
}

static void finalize_active(void)
{
    if (!g_active.map)
        return;
    if (g_on_finalize)
        g_on_finalize(g_active.map);
    if (g_cfg && config_bigram_separated(g_cfg)) {

        size_t kept = bitmap_prune_upper_half(g_active.map,
                                              (unsigned)g_cfg->separated_min_hits);
        LOGI("separated map: %zu upper-half cells survived the <%d prune",
             kept, g_cfg->separated_min_hits);
    }
    if (g_cfg && config_top_edges(g_cfg)) {

        size_t kept = bitmap_keep_top_edges(g_active.map, (size_t)g_cfg->top_edges);
        LOGI("top-edges projection: kept %zu of %d positions", kept, g_cfg->top_edges);
    }
    reqmap_close(&g_active);
    g_req_fd = -1;
}

static void start_request(const char *id, int fd)
{

    if (g_active.map && strcmp(g_active.id, id) == 0) {
        demux_touch();
        return;
    }
    finalize_active();

    if (reqmap_open(&g_active, id) != 0)
        return;
    g_req_fd = fd;
    if (g_on_start)
        g_on_start();
    demux_touch();
    LOGI("request start: %s (fd %d)", id, fd);
}

static int detect_id(const char *buf, size_t len, char *id, size_t idcap)
{
    char raw[256];
    size_t n = demux_find_header_value(buf, len, g_cfg->header_lc, g_cfg->header_len,
                                       raw, sizeof(raw));
    if (n == 0)
        return 0;
    return demux_normalize_request_id(raw, id, idcap);
}

void demux_on_read(int fd, const char *buf, size_t len)
{
    char id[128];
    if (detect_id(buf, len, id, sizeof(id)))
        start_request(id, fd);
}

void demux_on_write(int fd, const char *buf, size_t len)
{
    char id[128];
    int same_id = 0;
    if (detect_id(buf, len, id, sizeof(id))) {
        same_id = (g_active.map && strcmp(g_active.id, id) == 0);
        if (!same_id) {
            start_request(id, fd);
            return;
        }

    }
    if (!g_active.map)
        return;
    if (len >= 7 && memcmp(buf, "HTTP/1.", 7) == 0) {

        if (config_end_on_status_line(g_cfg) || fd != g_req_fd) {
            LOGI("request end at response status line: %s", g_active.id);
            finalize_active();
        }
    }
}

void demux_maybe_flush_idle(void)
{
    if (g_active.map && now_ms() - g_last_ms > IDLE_FLUSH_MS) {
        LOGI("request idle-flush: %s", g_active.id);
        finalize_active();
    }
}

void demux_shutdown(void)
{
    finalize_active();
}
