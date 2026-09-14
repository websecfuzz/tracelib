#ifndef TRACELIB_COV_SHARED_H
#define TRACELIB_COV_SHARED_H

#define MAP_SIZE          65536u

#define THETA_MAX         32
#define RING_CAP          (2 * THETA_MAX)
#define DEFAULT_THETA     4

#define DEFAULT_FILE_PATH_MONITORED "/var/www"
#define FILE_PATH_MONITORED_MAX 128

#define DEFAULT_EXCLUDED_FILE_PATH "temp,cache,debugbar,tmp,sessions,images,logs"

#define FILE_SQL_DATA_MAX 1024
#define EXCLUDED_FILE_PATH_MAX 128
#define EXCLUDED_TOKEN_MAX     32

#define EXCLUDED_TOKENS_MAX    8

#define PATH_MATCH_MAX 256

#define FNV_OFFSET        2166136261u
#define FNV_PRIME         16777619u

#define SALT_THETA        0x1111u
#define SALT_2THETA       0x2222u
#define SALT_FULL         0x4444u
#define FILE_CHANNEL_SALT 0x8888u

#define COV_TOKEN(sc, arg_hash) \
    ((unsigned short)((((unsigned)(sc) & 0xFFu) << 8) | ((unsigned)(arg_hash) & 0xFFu)))

#endif
