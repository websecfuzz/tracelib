#ifndef TRACELIB_EBPF_EVENT_H
#define TRACELIB_EBPF_EVENT_H

#include <stdint.h>
#include <stddef.h>

#ifndef TL_PAYLOAD_MAX
#define TL_PAYLOAD_MAX 4096u
#endif

#define TL_F_ENTRY      0x1u
#define TL_F_HASPAYLOAD 0x2u
#define TL_F_TASK_EXIT  0x4u

struct tl_event {
    uint32_t tid;
    uint32_t tgid;
    int32_t  nr;
    int32_t  fd;
    int64_t  ret;
    uint32_t flags;
    uint32_t payload_len;
    uint8_t  payload[TL_PAYLOAD_MAX];
};

#define TL_EVENT_HDR_SIZE (offsetof(struct tl_event, payload))

#endif
