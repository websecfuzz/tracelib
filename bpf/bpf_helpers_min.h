#ifndef TL_BPF_HELPERS_MIN_H
#define TL_BPF_HELPERS_MIN_H

#include <linux/bpf.h>

#ifndef SEC
#define SEC(name) __attribute__((section(name), used))
#endif

#ifndef __always_inline
#define __always_inline inline __attribute__((always_inline))
#endif

#define __uint(name, val)  int (*name)[val]
#define __type(name, val)  typeof(val) *name
#define __array(name, val) typeof(val) *name[]

typedef unsigned char      __u8;
typedef unsigned int       __u32;
typedef unsigned long long __u64;
typedef signed long long   __s64;

static void *(*bpf_map_lookup_elem)(void *map, const void *key) =
    (void *)BPF_FUNC_map_lookup_elem;
static long (*bpf_map_update_elem)(void *map, const void *key,
                                   const void *value, __u64 flags) =
    (void *)BPF_FUNC_map_update_elem;
static long (*bpf_map_delete_elem)(void *map, const void *key) =
    (void *)BPF_FUNC_map_delete_elem;
static __u64 (*bpf_get_current_pid_tgid)(void) =
    (void *)BPF_FUNC_get_current_pid_tgid;
static long (*bpf_probe_read_user)(void *dst, __u32 size, const void *src) =
    (void *)BPF_FUNC_probe_read_user;
static long (*bpf_probe_read_user_str)(void *dst, __u32 size, const void *src) =
    (void *)BPF_FUNC_probe_read_user_str;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) =
    (void *)BPF_FUNC_ringbuf_reserve;
static void (*bpf_ringbuf_submit)(void *data, __u64 flags) =
    (void *)BPF_FUNC_ringbuf_submit;
static void (*bpf_ringbuf_discard)(void *data, __u64 flags) =
    (void *)BPF_FUNC_ringbuf_discard;

#endif
