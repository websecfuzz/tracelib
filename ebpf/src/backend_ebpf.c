#include "backend.h"
#include "util.h"

#ifdef TRACELIB_EBPF

#include "backend_ebpf_impl.h"
#else

static int  ebpf_available(void) { return 0; }
static int  ebpf_start(uint16_t port, const struct config *cfg)
{
    (void)port; (void)cfg;
    LOGE("eBPF backend not built into this binary (rebuild with `make EBPF=1`).");
    return -1;
}
static void ebpf_run(void)  {}
static void ebpf_stop(void) {}

const struct collect_backend backend_ebpf = {
    .name = "ebpf",
    .available = ebpf_available,
    .start = ebpf_start,
    .run = ebpf_run,
    .stop = ebpf_stop,
};

#endif
