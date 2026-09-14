#ifndef TRACELIB_SQL_DETECT_H
#define TRACELIB_SQL_DETECT_H

#include <stdint.h>
#include <stddef.h>

uint8_t sql_skeleton_hash(const char *buf, size_t len);

size_t  sql_skeleton_canonical(const char *buf, size_t len, char *out, size_t outsz);

size_t  sql_query_reduced(const char *buf, size_t len, char *out, size_t outsz);
uint8_t sql_query_reduced_hash(const char *buf, size_t len);

size_t  sql_compact_query(const char *buf, size_t len, char *out, size_t outsz);
uint8_t sql_compact_query_hash(const char *buf, size_t len);

#endif
