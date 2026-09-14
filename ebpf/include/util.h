#ifndef TRACELIB_UTIL_H
#define TRACELIB_UTIL_H

#include <stdint.h>
#include <stdio.h>

uint64_t now_ms(void);

#define LOGI(...) do { fprintf(stderr, "[tracelib] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define LOGE(...) do { fprintf(stderr, "[tracelib][err] " __VA_ARGS__); fputc('\n', stderr); } while (0)

#endif
