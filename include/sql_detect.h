#ifndef TRACELIB_SQL_DETECT_H
#define TRACELIB_SQL_DETECT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

uint8_t detect_sql_hash(pid_t pid, unsigned long buf_addr, size_t buf_len);

uint8_t detect_sql_hash_local(const char *buf, size_t buf_len);

#endif
