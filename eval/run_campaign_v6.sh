#!/bin/bash

set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RESULT_DIR="${RESULT_DIR:-$ROOT/eval_result}"
mkdir -p "$RESULT_DIR"

APP_NAME="${1:-${APP:-wordpress}}"
MODE="${2:-${MODE:-tracelib_ebpf_simple}}"

MAX_HOURS="${MAX_HOURS:-4}"
MAX_SECONDS="${MAX_SECONDS:-$(( MAX_HOURS * 3600 ))}"
FUZZ_REQUEST_BUDGET="${FUZZ_REQUEST_BUDGET:-100000000}"
INTERVAL="${INTERVAL:-60}"
FUZZ_INTERVAL="${FUZZ_INTERVAL:-20}"
CRAWLER_PER_BASE_LIMIT="${CRAWLER_PER_BASE_LIMIT:-50}"
COVERAGE_COMPACT="${HERE}/assets/native_coverage_compact.php"
PHP_CLI_IMAGE="${PHP_CLI_IMAGE:-php:8.2-cli}"
DISABLE_PCOV="${DISABLE_PCOV:-1}"
WUT_IMAGE_PROFILE="${WUT_IMAGE_PROFILE:-instrumented}"
RESET_STATE="${RESET_STATE:-1}"
BITMAP_DIR="${BITMAP_DIR:-/dev/shm}"
MAX_CORPUS_SIZE="${MAX_CORPUS_SIZE:-0}"
BLACKBOX_MAX_CORPUS_SIZE="${BLACKBOX_MAX_CORPUS_SIZE:-50000}"
QUIESCE_SECONDS="${QUIESCE_SECONDS:-60}"
COMPOSE_UP_ATTEMPTS="${COMPOSE_UP_ATTEMPTS:-1}"
COMPOSE_UP_RETRY_DELAY="${COMPOSE_UP_RETRY_DELAY:-15}"
AUTO_LOGIN_DIR="${AUTO_LOGIN_DIR:-$ROOT/webfuzz/auto_login}"
APP_SEED_DIR="${APP_SEED_DIR:-$HERE/seeds/nonphp}"
AUTO_APP_SEED_FILE="${AUTO_APP_SEED_FILE:-1}"
ENABLE_APP_SEEDS="${ENABLE_APP_SEEDS:-0}"
APP_SEED_URLS="${APP_SEED_URLS:-}"
APP_SEED_FILE="${APP_SEED_FILE:-}"
ALLOW_NON_HTML="${ALLOW_NON_HTML:-0}"
WEBFUZZ_EXTRA_HEADERS="${WEBFUZZ_EXTRA_HEADERS:-}"
FEEDBACK_CAPTURE_DIR="${FEEDBACK_CAPTURE_DIR:-}"
FEEDBACK_CAPTURE_SETTLE_SECONDS="${FEEDBACK_CAPTURE_SETTLE_SECONDS:-4}"
FEEDBACK_REFERENCE_CMD=""
FEEDBACK_REFERENCE_RESET_CMD=""
NONPHP_REQUEST_FEEDBACK_REFERENCE="${NONPHP_REQUEST_FEEDBACK_REFERENCE:-0}"
NONPHP_REQUEST_FEEDBACK_MODE="${NONPHP_REQUEST_FEEDBACK_MODE:-reset}"
COVERAGE_SAMPLE_TIMEOUT="${COVERAGE_SAMPLE_TIMEOUT:-120}"
WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT="${WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT:-15}"
PLATFORM_COVERAGE_SAMPLE="${PLATFORM_COVERAGE_SAMPLE:-1}"
PLATFORM_COVERAGE_FINAL_ONLY="${PLATFORM_COVERAGE_FINAL_ONLY:-0}"
STATS_POLL_INTERVAL="${STATS_POLL_INTERVAL:-5}"
NODE_COVERAGE_INTERVAL_MS="${NODE_COVERAGE_INTERVAL_MS:-30000}"
NODE_COVERAGE_TAKE_ON_RESPONSE="${NODE_COVERAGE_TAKE_ON_RESPONSE:-0}"
NODE_FLUSH_SIGNAL_SH='n=0; for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null); case "${e##*/}" in node|nodejs) kill -USR2 "${p#/proc/}" 2>/dev/null && n=$((n+1)) ;; esac; done; [ "$n" -gt 0 ] || pkill -USR2 -x node 2>/dev/null || true'
FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS="${FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS:-0}"
SINGLE_ENDPOINT_MODE="${SINGLE_ENDPOINT_MODE:-0}"
SINGLE_ENDPOINT_FILE="${SINGLE_ENDPOINT_FILE:-}"
SINGLE_ENDPOINT_BLEND="${SINGLE_ENDPOINT_BLEND:-1}"
if [ -z "${SINGLE_ENDPOINT_TIME_BUDGET+x}" ]; then
    if [ "$SINGLE_ENDPOINT_BLEND" = "1" ]; then
        SINGLE_ENDPOINT_TIME_BUDGET=0
    else
        SINGLE_ENDPOINT_TIME_BUDGET="${ENDPOINT_TIME_BUDGET:-300}"
    fi
fi
SINGLE_ENDPOINT_VALIDATE="${SINGLE_ENDPOINT_VALIDATE:-1}"
SINGLE_ENDPOINT_VALIDATE_TIMEOUT="${SINGLE_ENDPOINT_VALIDATE_TIMEOUT:-20}"
SINGLE_ENDPOINT_VALIDATE_ONLY="${SINGLE_ENDPOINT_VALIDATE_ONLY:-0}"
BLACKBOX_CORPUS_MODE="${BLACKBOX_CORPUS_MODE:-keep-submitted}"
SINGLE_ENDPOINT_REQUEST_RECORD_FILE="${SINGLE_ENDPOINT_REQUEST_RECORD_FILE:-}"
SINGLE_ENDPOINT_REQUEST_REPLAY_FILE="${SINGLE_ENDPOINT_REQUEST_REPLAY_FILE:-}"
SINGLE_ENDPOINT_DISABLE_SESSION_CHECKS="${SINGLE_ENDPOINT_DISABLE_SESSION_CHECKS:-0}"
REQUEST_FEEDBACK_FILE="${REQUEST_FEEDBACK_FILE:-}"
REQUEST_FEEDBACK_PHASE="${REQUEST_FEEDBACK_PHASE:-crawl}"
REQUEST_FEEDBACK_PYTHON="${REQUEST_FEEDBACK_PYTHON:-python3}"
REQUEST_FEEDBACK_SYNC_INTERVAL="${REQUEST_FEEDBACK_SYNC_INTERVAL:-30}"
FEEDBACK_CAPTURE_SYNC_INTERVAL="${FEEDBACK_CAPTURE_SYNC_INTERVAL:-$REQUEST_FEEDBACK_SYNC_INTERVAL}"
REQUEST_FEEDBACK_INTERNAL_CAPTURE=0
WEBFUZZ_FEEDBACK_HASH_FILE="${WEBFUZZ_FEEDBACK_HASH_FILE:-}"
WEBFUZZ_FEEDBACK_TREATMENT_MODE="${WEBFUZZ_FEEDBACK_TREATMENT_MODE:-$MODE}"

case "$WUT_IMAGE_PROFILE" in
    instrumented|bare) ;;
    *) echo "WUT_IMAGE_PROFILE must be instrumented or bare (got '$WUT_IMAGE_PROFILE')" >&2; exit 1 ;;
esac

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"

DOCKER=( sudo -n /usr/bin/docker )

TMPRUN="$(mktemp -d "/tmp/campaign-v6-XXXXXX")"
WEBFUZZ_LOG="$TMPRUN/webfuzz.log"
EXT_COV_FILE="$TMPRUN/external_coverage.txt"
ENVFILE="$TMPRUN/compose.env"
KEEP_CAMPAIGN_TMP="${KEEP_CAMPAIGN_TMP:-0}"

cleanup_campaign_tmp() {
    [ "$KEEP_CAMPAIGN_TMP" = "1" ] || rm -rf -- "$TMPRUN" 2>/dev/null || true
}
trap cleanup_campaign_tmp EXIT INT TERM

if [ -n "$REQUEST_FEEDBACK_FILE" ]; then
    REQUEST_FEEDBACK_FILE="$(realpath -m "$REQUEST_FEEDBACK_FILE")"
    mkdir -p "$(dirname "$REQUEST_FEEDBACK_FILE")"
    if [ -z "$FEEDBACK_CAPTURE_DIR" ]; then
        FEEDBACK_CAPTURE_DIR="$TMPRUN/request-feedback-capture"
        REQUEST_FEEDBACK_INTERNAL_CAPTURE=1
    fi
fi
if [ -n "$WEBFUZZ_FEEDBACK_HASH_FILE" ]; then
    WEBFUZZ_FEEDBACK_HASH_FILE="$(realpath -m "$WEBFUZZ_FEEDBACK_HASH_FILE")"
    mkdir -p "$(dirname "$WEBFUZZ_FEEDBACK_HASH_FILE")"
fi

log() { echo "[campv6 $(date -u +%H:%M:%S)] $*"; }

META_C=""
MONITOR_ROOT="/var/www"
case "$APP_NAME" in
    wordpress)  RUNTIME=php;    APP_DIR="$ROOT/apps/wordpress";  SERVICE="wordpress";  PORT="${PORT:-8081}"; META_C="/var/www/html/instr.meta" ;;
    hotcrp)     RUNTIME=php;    APP_DIR="$ROOT/apps/hotcrp";     SERVICE="hotcrp";     PORT="${PORT:-8087}"; META_C="/var/www/html/instr.meta" ;;
    phpbb)      RUNTIME=php;    APP_DIR="$ROOT/apps/phpbb";      SERVICE="phpbb";      PORT="${PORT:-8089}"; META_C="/var/www/html/instr.meta" ;;
    joomla)     RUNTIME=php;    APP_DIR="$ROOT/apps/joomla";     SERVICE="joomla";     PORT="${PORT:-8090}"; META_C="/var/www/html/instr.meta" ;;
    bagisto)    RUNTIME=php;    APP_DIR="$ROOT/apps/bagisto";    SERVICE="bagisto";    PORT="${PORT:-8093}"; META_C="/var/www/bagisto/instr.meta" ;;
    drupal)     RUNTIME=php;    APP_DIR="$ROOT/apps/drupal";     SERVICE="drupal";     PORT="${PORT:-8095}"; META_C="/var/www/html/instr.meta" ;;
    prestashop) RUNTIME=php;    APP_DIR="$ROOT/apps/prestashop"; SERVICE="prestashop"; PORT="${PORT:-8100}"; META_C="/var/www/html/instr.meta" ;;
    zencart)    RUNTIME=php;    APP_DIR="$ROOT/apps/zencart";    SERVICE="zencart";    PORT="${PORT:-8094}"; META_C="/var/www/html/instr.meta" ;;
    ghost)      RUNTIME=node;   APP_DIR="$ROOT/apps/ghost";      SERVICE="ghost";      PORT="${PORT:-2368}"; MONITOR_ROOT="/var/lib/ghost" ;;
    redmine)    RUNTIME=ruby;   APP_DIR="$ROOT/apps/redmine";    SERVICE="redmine";    PORT="${PORT:-8088}"; MONITOR_ROOT="/usr/src/redmine" ;;
    gogs)       RUNTIME=go;     APP_DIR="$ROOT/apps/gogs";       SERVICE="gogs";       PORT="${PORT:-8091}"; MONITOR_ROOT="/data" ;;
    huginn)     RUNTIME=ruby;   APP_DIR="$ROOT/apps/huginn";     SERVICE="huginn";     PORT="${PORT:-8092}"; MONITOR_ROOT="/app" ;;
    superset)   RUNTIME=python; APP_DIR="$ROOT/apps/superset";   SERVICE="superset";   PORT="${PORT:-8096}"; MONITOR_ROOT="/app" ;;
    wikijs)     RUNTIME=node;   APP_DIR="$ROOT/apps/wikijs";     SERVICE="wikijs";     PORT="${PORT:-8097}"; MONITOR_ROOT="/wiki" ;;
    petclinic)  RUNTIME=java;   APP_DIR="$ROOT/apps/petclinic";  SERVICE="petclinic";  PORT="${PORT:-8098}"; MONITOR_ROOT="/app" ;;
    roller)     RUNTIME=java;   APP_DIR="$ROOT/apps/roller";     SERVICE="roller";     PORT="${PORT:-8099}"; MONITOR_ROOT="/usr/local/tomcat" ;;
    *)
        echo "run_campaign_v6: unsupported app '$APP_NAME'" >&2
        exit 1 ;;
esac
[ "$RUNTIME" = "php" ] && COMPOSE_MODE="php" || COMPOSE_MODE="nonphp"

if [ -z "${WUT_LISTEN_PORT:-}" ]; then
    case "$APP_NAME" in
        wikijs) WUT_LISTEN_PORT=3000 ;;
        *)      WUT_LISTEN_PORT="$PORT" ;;
    esac
fi

IS_EBPF=0; TL_COV_MODE="bigram"; TL_FILE_SQL_ONLY=0; TL_FILE_SQL_UNFILTERED=0; TL_FILE_SQL_FILTERED=0
TL_BIGRAM_SEPARATED=0; TL_SEPARATED_MIN_HITS="${TRACELIB_SEPARATED_MIN_HITS:-8}"
TL_FILE_PATH_MONITORED="${TRACELIB_FILE_PATH_MONITORED:-${FILE_PATH_MONITORED:-$MONITOR_ROOT}}"
TL_EXCLUDED_FILE_PATH="${TRACELIB_EXCLUDED_FILE_PATH-temp,cache,debugbar,tmp,sessions,images,logs}"
TL_END_ON_STATUS_LINE="${TRACELIB_END_ON_STATUS_LINE:-1}"
TL_SQL_COMPACT="${TRACELIB_SQL_COMPACT:-1}"
TL_FILTER_FILE=""; TL_FILTER_SHA256=""
TL_FILTER_CONTAINER="/etc/tracelib/web-related-syscalls.txt"
case "$MODE" in
    native)
        if [ "$COMPOSE_MODE" != "php" ]; then
            echo "run_campaign_v6: 'native' mode is PHP-only (app=$APP_NAME runtime=$RUNTIME)" >&2; exit 1
        fi
        WF_MODE="native" ;;
    blackbox)             WF_MODE="blackbox" ;;
    tracelib_ebpf)        WF_MODE="tracelib"; IS_EBPF=1; TL_COV_MODE="ngram" ;;
    tracelib_ebpf_simple) WF_MODE="tracelib"; IS_EBPF=1; TL_COV_MODE="bigram" ;;
    tracelib_bigram_file_sql_filtered)
        WF_MODE="tracelib"; IS_EBPF=1; TL_COV_MODE="bigram"; TL_FILE_SQL_FILTERED=1 ;;
    tracelib)
        echo "run_campaign_v6: use 'tracelib_ebpf', 'tracelib_ebpf_simple' or 'tracelib_bigram_file_sql_filtered' (got bare 'tracelib')." >&2
        exit 1 ;;
    *) echo "mode must be native | blackbox | tracelib_ebpf | tracelib_ebpf_simple | tracelib_bigram_file_sql_filtered (got '$MODE')" >&2; exit 1 ;;
esac

if [ "$WF_MODE" = "blackbox" ] && [ "${BLACKBOX_MAX_CORPUS_SIZE:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$MAX_CORPUS_SIZE" -eq 0 ] 2>/dev/null \
       || [ "$MAX_CORPUS_SIZE" -gt "$BLACKBOX_MAX_CORPUS_SIZE" ] 2>/dev/null; then
        MAX_CORPUS_SIZE="$BLACKBOX_MAX_CORPUS_SIZE"
    fi
fi

USE_BARE_WUT=0
EFFECTIVE_WUT_IMAGE_PROFILE="instrumented"
if [ "$WUT_IMAGE_PROFILE" = "bare" ] && [ "$MODE" != "native" ]; then
    USE_BARE_WUT=1
    EFFECTIVE_WUT_IMAGE_PROFILE="bare"
    [ -r "$APP_DIR/docker-compose.bare.yml" ] || {
        echo "run_campaign_v6: bare WUT stack is unavailable for app '$APP_NAME': $APP_DIR/docker-compose.bare.yml" >&2
        exit 1
    }
    META_C=""
fi
if [ -n "$TL_FILTER_FILE" ]; then
    [ -r "$TL_FILTER_FILE" ] || {
        echo "run_campaign_v6: syscall filter is not readable: $TL_FILTER_FILE" >&2
        exit 1
    }
    TL_FILTER_FILE="$(realpath "$TL_FILTER_FILE")"
    TL_FILTER_SHA256="$(sha256sum "$TL_FILTER_FILE" | awk '{print $1}')"
fi
case "$REQUEST_FEEDBACK_PHASE" in
    crawl|fuzz|all) ;;
    *) echo "REQUEST_FEEDBACK_PHASE must be 'crawl', 'fuzz', or 'all' (got '$REQUEST_FEEDBACK_PHASE')" >&2; exit 1 ;;
esac
case "$NONPHP_REQUEST_FEEDBACK_MODE" in
    cumulative|reset) ;;
    *) echo "NONPHP_REQUEST_FEEDBACK_MODE must be 'cumulative' or 'reset' (got '$NONPHP_REQUEST_FEEDBACK_MODE')" >&2; exit 1 ;;
esac
case "$FEEDBACK_CAPTURE_SYNC_INTERVAL" in
    ""|*[!0-9]*)
        echo "FEEDBACK_CAPTURE_SYNC_INTERVAL must be a non-negative integer" >&2
        exit 1 ;;
esac
case "$COVERAGE_SAMPLE_TIMEOUT" in
    ""|*[!0-9]*)
        echo "COVERAGE_SAMPLE_TIMEOUT must be a positive integer" >&2
        exit 1 ;;
    0)
        echo "COVERAGE_SAMPLE_TIMEOUT must be greater than zero" >&2
        exit 1 ;;
esac
case "$STATS_POLL_INTERVAL" in
    ""|*[!0-9]*)
        echo "STATS_POLL_INTERVAL must be a positive integer" >&2
        exit 1 ;;
    0)
        echo "STATS_POLL_INTERVAL must be greater than zero" >&2
        exit 1 ;;
esac
case "$NODE_COVERAGE_INTERVAL_MS" in
    ""|*[!0-9]*)
        echo "NODE_COVERAGE_INTERVAL_MS must be a non-negative integer" >&2
        exit 1 ;;
esac
case "$COMPOSE_UP_ATTEMPTS" in
    ""|*[!0-9]*)
        echo "COMPOSE_UP_ATTEMPTS must be a positive integer" >&2
        exit 1 ;;
    0)
        echo "COMPOSE_UP_ATTEMPTS must be greater than zero" >&2
        exit 1 ;;
esac
case "$COMPOSE_UP_RETRY_DELAY" in
    ""|*[!0-9]*)
        echo "COMPOSE_UP_RETRY_DELAY must be a non-negative integer" >&2
        exit 1 ;;
esac
case "$SINGLE_ENDPOINT_MODE" in
    0|1) ;;
    *) echo "SINGLE_ENDPOINT_MODE must be 0 or 1 (got '$SINGLE_ENDPOINT_MODE')" >&2; exit 1 ;;
esac
case "$SINGLE_ENDPOINT_VALIDATE" in
    0|1) ;;
    *) echo "SINGLE_ENDPOINT_VALIDATE must be 0 or 1 (got '$SINGLE_ENDPOINT_VALIDATE')" >&2; exit 1 ;;
esac
case "$SINGLE_ENDPOINT_VALIDATE_ONLY" in
    0|1) ;;
    *) echo "SINGLE_ENDPOINT_VALIDATE_ONLY must be 0 or 1 (got '$SINGLE_ENDPOINT_VALIDATE_ONLY')" >&2; exit 1 ;;
esac
case "$SINGLE_ENDPOINT_BLEND" in
    0|1) ;;
    *) echo "SINGLE_ENDPOINT_BLEND must be 0 or 1 (got '$SINGLE_ENDPOINT_BLEND')" >&2; exit 1 ;;
esac
case "$SINGLE_ENDPOINT_DISABLE_SESSION_CHECKS" in
    0|1) ;;
    *) echo "SINGLE_ENDPOINT_DISABLE_SESSION_CHECKS must be 0 or 1 (got '$SINGLE_ENDPOINT_DISABLE_SESSION_CHECKS')" >&2; exit 1 ;;
esac
if [ -n "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE" ] \
   && [ -n "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" ]; then
    echo "request recording and replay cannot be enabled in the same cell" >&2
    exit 1
fi
if [ -n "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE" ]; then
    [ "$SINGLE_ENDPOINT_MODE" = "1" ] || {
        echo "request recording requires SINGLE_ENDPOINT_MODE=1" >&2
        exit 1
    }
    [ "$MODE" = "blackbox" ] || {
        echo "request recording requires blackbox mode (got '$MODE')" >&2
        exit 1
    }
    SINGLE_ENDPOINT_REQUEST_RECORD_FILE="$(realpath -m "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE")"
    mkdir -p "$(dirname "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE")"
fi
if [ -n "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" ]; then
    [ "$SINGLE_ENDPOINT_MODE" = "1" ] || {
        echo "request replay requires SINGLE_ENDPOINT_MODE=1" >&2
        exit 1
    }
    [ -s "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" ] || {
        echo "request replay file is missing or empty: $SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" >&2
        exit 1
    }
    SINGLE_ENDPOINT_REQUEST_REPLAY_FILE="$(realpath "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE")"
fi
if { [ -n "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE" ] \
      || [ -n "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" ]; } \
   && [ "$SINGLE_ENDPOINT_VALIDATE" != "1" ]; then
    echo "identical-request recording/replay requires endpoint validation for fresh cookies" >&2
    exit 1
fi
case "$BLACKBOX_CORPUS_MODE" in
    seed-only|keep-submitted) ;;
    *) echo "BLACKBOX_CORPUS_MODE must be 'seed-only' or 'keep-submitted' (got '$BLACKBOX_CORPUS_MODE')" >&2; exit 1 ;;
esac
case "$FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS" in
    0|1) ;;
    *) echo "FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS must be 0 or 1 (got '$FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS')" >&2; exit 1 ;;
esac
case "$PLATFORM_COVERAGE_SAMPLE" in
    0|1) ;;
    *) echo "PLATFORM_COVERAGE_SAMPLE must be 0 or 1 (got '$PLATFORM_COVERAGE_SAMPLE')" >&2; exit 1 ;;
esac
case "$PLATFORM_COVERAGE_FINAL_ONLY" in
    0|1) ;;
    *) echo "PLATFORM_COVERAGE_FINAL_ONLY must be 0 or 1 (got '$PLATFORM_COVERAGE_FINAL_ONLY')" >&2; exit 1 ;;
esac
case "$SINGLE_ENDPOINT_TIME_BUDGET" in
    ""|*[!0-9]*)
        echo "SINGLE_ENDPOINT_TIME_BUDGET must be a non-negative integer" >&2
        exit 1 ;;
esac
case "$SINGLE_ENDPOINT_VALIDATE_TIMEOUT" in
    ""|*[!0-9]*)
        echo "SINGLE_ENDPOINT_VALIDATE_TIMEOUT must be a positive integer" >&2
        exit 1 ;;
    0)
        echo "SINGLE_ENDPOINT_VALIDATE_TIMEOUT must be greater than zero" >&2
        exit 1 ;;
esac
if [ -n "$REQUEST_FEEDBACK_FILE" ] && [ "$WF_MODE" != "tracelib" ]; then
    echo "run_campaign_v6: REQUEST_FEEDBACK_FILE requires a TraceLib eBPF mode" >&2
    exit 1
fi
if [ "$SINGLE_ENDPOINT_MODE" = "1" ]; then
    [ -n "$SINGLE_ENDPOINT_FILE" ] || {
        echo "run_campaign_v6: SINGLE_ENDPOINT_MODE=1 requires SINGLE_ENDPOINT_FILE" >&2
        exit 1
    }
    SINGLE_ENDPOINT_FILE="$(realpath -m "$SINGLE_ENDPOINT_FILE")"
    [ -r "$SINGLE_ENDPOINT_FILE" ] || {
        echo "run_campaign_v6: SINGLE_ENDPOINT_FILE is not readable: $SINGLE_ENDPOINT_FILE" >&2
        exit 1
    }
    SINGLE_ENDPOINT_COUNT="$(grep -Evc '^[[:space:]]*(#|$)' "$SINGLE_ENDPOINT_FILE" || true)"
    [ "${SINGLE_ENDPOINT_COUNT:-0}" -gt 0 ] 2>/dev/null || {
        echo "run_campaign_v6: SINGLE_ENDPOINT_FILE contains no endpoints: $SINGLE_ENDPOINT_FILE" >&2
        exit 1
    }
fi
if [ "$SINGLE_ENDPOINT_VALIDATE_ONLY" = "1" ] && { [ "$SINGLE_ENDPOINT_MODE" != "1" ] || [ "$SINGLE_ENDPOINT_VALIDATE" != "1" ]; }; then
    echo "run_campaign_v6: SINGLE_ENDPOINT_VALIDATE_ONLY=1 requires SINGLE_ENDPOINT_MODE=1 and SINGLE_ENDPOINT_VALIDATE=1" >&2
    exit 1
fi
case "$COMPOSE_MODE" in
    php)    COVERAGE_SOURCE="ast_edges"; COVERAGE_LABEL="Edge Coverage (AST)" ;;
    nonphp) case "$RUNTIME" in
                node)   COVERAGE_SOURCE="v8_lines";  COVERAGE_LABEL="Line Coverage (c8)" ;;
                go)     COVERAGE_SOURCE="go_lines";   COVERAGE_LABEL="Line Coverage (go-cover)" ;;
                ruby)   COVERAGE_SOURCE="ruby_lines"; COVERAGE_LABEL="Line Coverage (Ruby Coverage)" ;;
                java)   COVERAGE_SOURCE="java_lines"; COVERAGE_LABEL="Line Coverage (JaCoCo)" ;;
                python) COVERAGE_SOURCE="py_lines";   COVERAGE_LABEL="Line Coverage (coverage.py)" ;;
                *)      COVERAGE_SOURCE="unknown";    COVERAGE_LABEL="Coverage" ;;
            esac ;;
esac

CATCH=""; TPATH=""
case "$APP_NAME" in
    wordpress)  CATCH="wpadminbar" ;;
    hotcrp)     CATCH="Sign out" ;;
    phpbb)      CATCH="Administration Control Panel" ;;
    joomla)     CATCH="com_cpanel";    TPATH="administrator/" ;;
    bagisto)    CATCH="adminLogout";   TPATH="admin/dashboard" ;;
    drupal)     CATCH="Administration menu" ;;
    prestashop) CATCH="header_logout"; TPATH="admin9671czlrok7qbdn2pre/" ;;
    zencart)    CATCH="Logoff";        TPATH="adminzcfuzz/index.php" ;;
    ghost)      CATCH="";              TPATH="ghost/" ;;
    redmine)    CATCH="Logged in as" ;;
    gogs)       CATCH="logout-form" ;;
    huginn)     CATCH="/users/sign_out" ;;
    superset)   CATCH="";              TPATH="superset/welcome/" ;;
    wikijs)     CATCH="" ;;
    petclinic)  CATCH="" ;;
    roller)     CATCH="";              TPATH="roller/" ;;
esac
if [ "${CATCH_PHRASE+x}" = "x" ]; then
    CATCH="$CATCH_PHRASE"
fi

BLOCK_RULES_DEFAULT=()
case "$APP_NAME" in
    wordpress)  BLOCK_RULES_DEFAULT=(
                    'wp-login\.php|action|logout|*'
                    'wp-admin/update\.php|||*'
                    'wp-admin/update-core\.php|||*'
                    'wp-admin/plugin-install\.php|||*'
                    'wp-admin/theme-install\.php|||*'
                    'wp-admin/plugins\.php|action|activate|*'
                    'wp-admin/plugins\.php|action|delete|*'
                    'wp-admin/themes\.php|action|activate|*'
                    'wp-admin/themes\.php|action|delete|*'
                    'wp-admin/options\.php|||*'
                    'wp-admin/users\.php|action|delete|*'
                    'wp-admin/users\.php|action|resetpassword|*'
                ) ;;
    hotcrp)     BLOCK_RULES_DEFAULT=( '.*|signout|.*|*' ) ;;
    phpbb)      BLOCK_RULES_DEFAULT=( 'ucp\.php|mode|logout|*' ) ;;
    joomla)     BLOCK_RULES_DEFAULT=( 'index\.php|task|logout|*' ) ;;
    drupal)     BLOCK_RULES_DEFAULT=( 'user/logout|||*' ) ;;
    zencart)    BLOCK_RULES_DEFAULT=( '.*|cmd|logoff|*' ) ;;
    prestashop) BLOCK_RULES_DEFAULT=( '.*|logout|.*|*' ) ;;
    bagisto)    BLOCK_RULES_DEFAULT=( 'admin/logout|||*' ) ;;
    ghost)      BLOCK_RULES_DEFAULT=( '.*/ghost/signout.*|||*' '.*/ghost/api/admin/users.*|||POST' ) ;;
    redmine)    BLOCK_RULES_DEFAULT=( '.*/logout.*|||*' '.*/users/[0-9]+.*|||POST' '.*/my/account.*|||POST' '.*/my/password.*|||POST' ) ;;
    gogs)       BLOCK_RULES_DEFAULT=( '.*/user/logout.*|||*' '.*/user/settings.*|||POST' '.*/admin/users/[0-9]+.*|||POST' ) ;;
    huginn)     BLOCK_RULES_DEFAULT=( '.*/users/sign_out.*|||*' '.*/admin/users/[0-9]+/switch_to_user.*|||*' '.*/users/edit.*|||POST' '.*/admin/users/[0-9]+.*|||POST' ) ;;
    superset)   BLOCK_RULES_DEFAULT=( '.*/logout.*|||*' '.*/users/edit/[0-9]+.*|||POST' '.*/users/delete/[0-9]+.*|||*' '.*/resetmypassword.*|||*' '.*/api/v1/me/roles.*|||POST' ) ;;
    wikijs)     BLOCK_RULES_DEFAULT=( '.*/logout.*|||*' '.*/a/utilities.*|||*' '.*/a/users/[0-9]+.*|||POST' ) ;;
    petclinic)  BLOCK_RULES_DEFAULT=( '.*/actuator/shutdown.*|||*' ) ;;
    roller)     BLOCK_RULES_DEFAULT=( '.*/roller-ui/logout.*|||*' '.*/logout.*|||*' '.*/roller-ui/admin/.*|||POST' '.*/roller-ui/register.*|||POST' ) ;;
esac
if [ "${NO_BLOCK:-0}" = "1" ]; then
    BLOCK_RULES=()
else
    BLOCK_RULES=( "${BLOCK_RULES_DEFAULT[@]}" )
    [ -n "${EXTRA_BLOCK_RULE:-}" ] && BLOCK_RULES+=( "$EXTRA_BLOCK_RULE" )
    if [ -n "${EXTRA_BLOCK_RULES:-}" ]; then
        while IFS= read -r _extra_block_rule; do
            [ -n "$_extra_block_rule" ] && BLOCK_RULES+=( "$_extra_block_rule" )
        done <<< "$EXTRA_BLOCK_RULES"
    fi
fi

BASE_URL="http://localhost:${PORT}"
TARGET_URL="${TARGET_URL:-${BASE_URL}/${TPATH}}"
WEBFUZZ_USER_AGENT="${WEBFUZZ_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36}"
HOST_NAME="$(hostname -s 2>/dev/null || echo unknown)"; HOST_NAME="${HOST_NAME//[^A-Za-z0-9._-]/-}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
STEM="${HOST_NAME}_${APP_NAME}_${MODE}_t${MAX_HOURS}h_${TS}"
CSV="$RESULT_DIR/${STEM}.csv"
FUZZSTART_FILE="$RESULT_DIR/${STEM}.fuzzstart.txt"
SUMMARY_FILE="$RESULT_DIR/${STEM}.summary.txt"
FUZZER_LOG_OUT="$RESULT_DIR/${STEM}.fuzzer.log"

exec > >(tee -a "$TMPRUN/campaign.log") 2>&1

log "SCHEMA=time-budget app=$APP_NAME mode=$MODE (webfuzz=$WF_MODE) max=${MAX_HOURS}h interval=${INTERVAL}s per_base_limit=${CRAWLER_PER_BASE_LIMIT}"
log "target=$TARGET_URL  csv=$CSV"
log "WUT image profile: $EFFECTIVE_WUT_IMAGE_PROFILE"
[ -n "$TL_FILTER_FILE" ] && log "syscall filter: $TL_FILTER_FILE sha256=$TL_FILTER_SHA256"
log "PYTHONHASHSEED=$PYTHONHASHSEED (deterministic crawl frontier ordering)"
    [ "$SINGLE_ENDPOINT_MODE" = "1" ] && log "single-endpoint mode: endpoints=$SINGLE_ENDPOINT_COUNT file=$SINGLE_ENDPOINT_FILE endpoint_budget=${SINGLE_ENDPOINT_TIME_BUDGET}s sample=${FUZZ_INTERVAL}s schedule=$([ "$SINGLE_ENDPOINT_BLEND" = "1" ] && echo blend || echo sequential) blackbox_corpus=$BLACKBOX_CORPUS_MODE"
[ -n "$REQUEST_FEEDBACK_FILE" ] && log "request feedback export enabled: $REQUEST_FEEDBACK_FILE (phase=$REQUEST_FEEDBACK_PHASE)"
if [ "$COMPOSE_MODE" = "nonphp" ] && [ "${PLATFORM_COVERAGE_SAMPLE:-1}" != "1" ]; then
    log "platform CSV coverage sampling disabled for this non-PHP cell"
fi
if [ "$COMPOSE_MODE" = "nonphp" ] && [ "${PLATFORM_COVERAGE_FINAL_ONLY:-0}" = "1" ]; then
    log "non-PHP platform coverage reporter runs only for the final CSV sample"
fi
if [ "$RUNTIME" = "node" ]; then
    if [ "$NODE_COVERAGE_INTERVAL_MS" = "0" ]; then
        log "Node V8 periodic snapshots disabled; coverage flushes on reporter signal"
    else
        log "Node V8 periodic snapshot interval: ${NODE_COVERAGE_INTERVAL_MS}ms"
    fi
fi

APP_ENV_NAME="$(printf '%s' "$APP_NAME" | tr '[:lower:]-' '[:upper:]_')"
APP_SEED_URLS_VAR="${APP_ENV_NAME}_SEED_URLS"
APP_SEED_FILE_VAR="${APP_ENV_NAME}_SEED_FILE"
APP_SPECIFIC_SEED_URLS="${!APP_SEED_URLS_VAR:-}"
APP_SPECIFIC_SEED_FILE="${!APP_SEED_FILE_VAR:-}"
[ -n "$APP_SPECIFIC_SEED_FILE" ] && APP_SEED_FILE="$APP_SPECIFIC_SEED_FILE"
DEFAULT_APP_SEED_FILE="$APP_SEED_DIR/$APP_NAME.json"
if [ -z "$APP_SEED_FILE" ] && [ "$AUTO_APP_SEED_FILE" = "1" ] && [ -r "$DEFAULT_APP_SEED_FILE" ]; then
    APP_SEED_FILE="$DEFAULT_APP_SEED_FILE"
fi

APP_SEED_URLS_ALL="$APP_SEED_URLS"
[ -n "$APP_SPECIFIC_SEED_URLS" ] && APP_SEED_URLS_ALL="${APP_SEED_URLS_ALL:+$APP_SEED_URLS_ALL }$APP_SPECIFIC_SEED_URLS"

BUILTIN_SEED_SPECS=()
if [ "$ENABLE_APP_SEEDS" = "1" ]; then
    case "$APP_NAME" in
        ghost)
            BUILTIN_SEED_SPECS=(
                'GET:/ghost/'
                'GET:/ghost/api/admin/session/'
                'GET:/ghost/api/admin/users/me/?include=roles'
                'GET:/ghost/api/admin/config/'
                'GET:/ghost/api/admin/site/'
                'GET:/ghost/api/admin/posts/?limit=10'
                'GET:/ghost/api/admin/pages/?limit=10'
                'GET:/ghost/api/admin/tags/?limit=10'
                'GET:/ghost/api/admin/settings/?group=site%2Ctheme%2Cprivate'
                'GET:/ghost/api/admin/themes/'
            )
            ;;
        redmine)
            BUILTIN_SEED_SPECS=(
                'GET:/'
                'GET:/admin'
                'GET:/my/account'
                'GET:/projects'
                'GET:/issues'
                'GET:/users'
                'GET:/groups'
                'GET:/roles'
                'GET:/trackers'
                'GET:/settings'
            )
            ;;
        gogs)
            BUILTIN_SEED_SPECS=(
                'GET:/'
                'GET:/admin'
                'GET:/admin/users'
                'GET:/admin/repos'
                'GET:/admin/config'
                'GET:/user/settings'
                'GET:/explore/repos'
                'GET:/repo/create'
                'GET:/api/v1/user'
            )
            ;;
        huginn)
            BUILTIN_SEED_SPECS=(
                'GET:/'
                'GET:/agents'
                'GET:/agents/new'
                'GET:/events'
                'GET:/scenarios'
                'GET:/user_credentials'
                'GET:/services'
                'GET:/jobs'
                'GET:/worker_status'
                'GET:/admin/users'
            )
            ;;
        superset)
            BUILTIN_SEED_SPECS=(
                'GET:/superset/welcome/'
                'GET:/dashboard/list/'
                'GET:/chart/list/'
                'GET:/tablemodelview/list/'
                'GET:/databaseview/list/'
                'GET:/users/list/'
                'GET:/roles/list/'
                'GET:/sqllab/'
                'GET:/api/v1/me/'
                'GET:/api/v1/dashboard/'
                'GET:/api/v1/chart/'
                'GET:/api/v1/database/'
            )
            ;;
        wikijs)
            BUILTIN_SEED_SPECS=(
                'GET:/'
                'GET:/home'
                'GET:/login'
                'GET:/a/dashboard'
                'GET:/a/pages'
                'GET:/a/users'
                'GET:/a/groups'
                'GET:/a/theme'
                'GET:/p/list'
                'GET:/t/all'
            )
            ;;
        petclinic)
            BUILTIN_SEED_SPECS=(
                'GET:/'
                'GET:/owners/find'
                'GET:/owners?lastName='
                'GET:/owners/new'
                'GET:/vets.html'
                'GET:/vets'
                'GET:/oups'
                'GET:/actuator/health'
            )
            ;;
        roller)
            BUILTIN_SEED_SPECS=(
                'GET:/roller/'
                'GET:/roller/roller-ui/login.rol'
                'GET:/roller/roller-ui/register.rol'
                'GET:/roller/roller-ui/profile.rol'
                'GET:/roller/roller-ui/menu.rol'
                'GET:/roller/roller-ui/createWeblog.rol'
            )
            ;;
    esac
fi
if [ "$APP_NAME" = "ghost" ] && [ -z "$WEBFUZZ_EXTRA_HEADERS" ] \
   && { [ "${#BUILTIN_SEED_SPECS[@]}" -gt 0 ] || [ -n "$APP_SEED_URLS_ALL" ] || [ -n "$APP_SEED_FILE" ]; }; then
    WEBFUZZ_EXTRA_HEADERS='{"Accept":"text/html,application/xhtml+xml,application/json","Accept-Version":"v5.0"}'
fi

WEBFUZZ_SEED_FILE=""
APP_SEEDS_NEED_NON_HTML=0
if [ "${#BUILTIN_SEED_SPECS[@]}" -gt 0 ] || [ -n "$APP_SEED_URLS_ALL" ] || [ -n "$APP_SEED_FILE" ]; then
    APP_SEED_SPEC_FILE="$TMPRUN/app-seeds.specs"
    GENERATED_SEED_FILE="$TMPRUN/app-seeds.json"
    : > "$APP_SEED_SPEC_FILE"
    for seed_spec in "${BUILTIN_SEED_SPECS[@]}"; do
        printf '%s\n' "$seed_spec" >> "$APP_SEED_SPEC_FILE"
    done
    APP_SEED_FILE_REAL=""
    if [ -n "$APP_SEED_FILE" ]; then
        APP_SEED_FILE_REAL="$(realpath -m "$APP_SEED_FILE")"
        [ -r "$APP_SEED_FILE_REAL" ] || { log "ERROR: APP_SEED_FILE is not readable: $APP_SEED_FILE_REAL"; exit 1; }
    fi
    BASE_URL="$BASE_URL" \
    TARGET_URL="$TARGET_URL" \
    APP_SEED_SPEC_FILE="$APP_SEED_SPEC_FILE" \
    APP_SEED_URLS_ALL="$APP_SEED_URLS_ALL" \
    APP_SEED_FILE_REAL="$APP_SEED_FILE_REAL" \
    GENERATED_SEED_FILE="$GENERATED_SEED_FILE" \
    python3 - <<'PY'
import json
import os
import shlex
import sys
from urllib.parse import urljoin, urlparse

base_url = os.environ["BASE_URL"].rstrip("/")
spec_file = os.environ["APP_SEED_SPEC_FILE"]
custom_specs = os.environ.get("APP_SEED_URLS_ALL", "")
seed_file = os.environ.get("APP_SEED_FILE_REAL", "")
output = os.environ["GENERATED_SEED_FILE"]

entries = []
if seed_file:
    with open(seed_file, "r", encoding="utf-8") as handle:
        loaded = json.load(handle)
    if not isinstance(loaded, list):
        raise SystemExit(f"seed file must contain a JSON list: {seed_file}")
    entries.extend(loaded)

specs = []
with open(spec_file, "r", encoding="utf-8") as handle:
    specs.extend(line.strip() for line in handle if line.strip() and not line.lstrip().startswith("#"))

if custom_specs.strip():
    normalized = custom_specs.replace(",", " ").replace("\n", " ")
    specs.extend(shlex.split(normalized))

def normalize_url(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        raise ValueError("empty seed URL")
    parsed = urlparse(raw)
    if parsed.scheme in {"http", "https"}:
        return raw
    if raw.startswith("/"):
        return base_url + raw
    return urljoin(base_url + "/", raw)

def entry_from_spec(spec: str) -> dict:
    method = "GET"
    raw = spec.strip()
    if ":" in raw:
        maybe_method, rest = raw.split(":", 1)
        if maybe_method.upper() in {"GET", "POST"}:
            method = maybe_method.upper()
            raw = rest
    return {
        "url": normalize_url(raw),
        "method": method,
        "params": {"GET": {}, "POST": {}},
    }

for spec in specs:
    try:
        entries.append(entry_from_spec(spec))
    except Exception as exc:
        raise SystemExit(f"invalid seed spec {spec!r}: {exc}") from exc

deduped = []
seen = set()
for entry in entries:
    if not isinstance(entry, dict):
        raise SystemExit(f"invalid seed entry: {entry!r}")
    method = str(entry.get("method", "GET")).upper()
    url = str(entry.get("url", ""))
    params = entry.get("params") or {"GET": {}, "POST": {}}
    if not url:
        raise SystemExit(f"seed entry is missing url: {entry!r}")
    normalized = {
        "url": normalize_url(url),
        "method": method,
        "params": {
            "GET": dict((params.get("GET") or {})),
            "POST": dict((params.get("POST") or {})),
        },
    }
    key = json.dumps(normalized, sort_keys=True)
    if key in seen:
        continue
    seen.add(key)
    deduped.append(normalized)

needs_non_html = any(
    "/api/" in entry["url"] or entry["url"].endswith((".json", ".xml", ".rss"))
    or any(marker in entry["url"] for marker in (".json?", ".xml?", ".rss?"))
    for entry in deduped
)

with open(output, "w", encoding="utf-8") as handle:
    json.dump(deduped, handle, indent=2, sort_keys=True)
with open(output + ".meta", "w", encoding="utf-8") as handle:
    json.dump({"count": len(deduped), "needs_non_html": needs_non_html}, handle)
PY
    seed_count=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["count"])' "$GENERATED_SEED_FILE.meta")
    seed_non_html=$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1]))["needs_non_html"] else 0)' "$GENERATED_SEED_FILE.meta")
    if [ "$seed_count" -gt 0 ] 2>/dev/null; then
        WEBFUZZ_SEED_FILE="$GENERATED_SEED_FILE"
        [ "$seed_non_html" = "1" ] && APP_SEEDS_NEED_NON_HTML=1
        log "app seed file enabled: $WEBFUZZ_SEED_FILE (entries=$seed_count builtins=${#BUILTIN_SEED_SPECS[@]} custom=${APP_SEED_URLS_ALL:+yes} user_file=${APP_SEED_FILE_REAL:-none})"
    else
        log "app seed file requested but no seed entries were generated"
    fi
fi

cd "$APP_DIR"
if [ -n "$FEEDBACK_CAPTURE_DIR" ]; then
    [ "$WF_MODE" = "tracelib" ] || {
        log "ERROR: paired feedback capture requires a TraceLib eBPF mode"
        exit 1
    }
    FEEDBACK_CAPTURE_DIR="$(realpath -m "$FEEDBACK_CAPTURE_DIR")"
    case "$FEEDBACK_CAPTURE_DIR" in
        /|/tmp|"$ROOT")
            log "ERROR: refusing unsafe FEEDBACK_CAPTURE_DIR=$FEEDBACK_CAPTURE_DIR"
            exit 1 ;;
    esac
    if [ -s "$FEEDBACK_CAPTURE_DIR/requests.jsonl" ]; then
        log "ERROR: feedback capture directory already contains request data: $FEEDBACK_CAPTURE_DIR"
        exit 1
    fi
    mkdir -p "$FEEDBACK_CAPTURE_DIR/tracelib"
    if [ "$COMPOSE_MODE" = "php" ]; then
        INSTR_HOST_DIR="$FEEDBACK_CAPTURE_DIR/ast"
        mkdir -p "$INSTR_HOST_DIR"
        if find "$INSTR_HOST_DIR" -maxdepth 1 -name 'map.*' -type f -print -quit | grep -q .; then
            log "ERROR: feedback capture directory already contains AST maps: $INSTR_HOST_DIR"
            exit 1
        fi
        chmod 777 "$INSTR_HOST_DIR"
        log "paired feedback capture enabled: $FEEDBACK_CAPTURE_DIR (reference=php_ast)"
    else
        INSTR_HOST_DIR="$TMPRUN/nonphp-instr-unused"
        mkdir -p "$INSTR_HOST_DIR"
        chmod 777 "$INSTR_HOST_DIR"
        if [ "$NONPHP_REQUEST_FEEDBACK_MODE" = "reset" ]; then
            log "paired feedback capture enabled: $FEEDBACK_CAPTURE_DIR (reference=language_line_set mode=reset)"
        else
            log "paired feedback capture enabled: $FEEDBACK_CAPTURE_DIR (reference=language_line_union mode=cumulative)"
        fi
    fi
else
    INSTR_HOST_DIR="/tmp/campv6-instr-${TS}-${APP_NAME}"
    rm -rf "$INSTR_HOST_DIR"; mkdir -p "$INSTR_HOST_DIR"; chmod 777 "$INSTR_HOST_DIR"
fi
COMPOSE_PROJECT_NAME="campv6-${MODE}-${APP_NAME}"
SERVICE_CONTAINER="${COMPOSE_PROJECT_NAME}-${SERVICE}-1"
printf 'WEBFUZZ_INSTR_DIR=%s\n' "$INSTR_HOST_DIR" > "$ENVFILE"

DC_PROFILES=()
OVERRIDE="$TMPRUN/docker-compose.override.yml"
EBPF_LOG_SVC="$SERVICE"

if [ "$USE_BARE_WUT" = "1" ]; then
    COMPOSE_FILES=( -f "$APP_DIR/docker-compose.bare.yml" )
    if [ "$IS_EBPF" = "1" ]; then
        EBPF_LOG_SVC="tracelib_ebpf"
        {
            echo "services:"
            echo "  tracelib_ebpf:"
            echo "    build:"
            echo "      context: ${ROOT}"
            echo "      dockerfile: ebpf-sidecar/Dockerfile"
            echo "    depends_on:"
            echo "      - ${SERVICE}"
            echo "    network_mode: \"service:${SERVICE}\""
            echo "    pid: \"host\""
            echo "    privileged: true"
            echo "    environment:"
            echo "      - TRACELIB_PORT=${WUT_LISTEN_PORT}"
            echo "      - TRACELIB_HEADER=X-REQUEST-ID"
            echo "      - TRACELIB_BACKEND=ebpf"
            echo "      - TRACELIB_COVERAGE_MODE=${TL_COV_MODE}"
            [ "$TL_FILE_SQL_ONLY" = "1" ] && echo "      - TRACELIB_FILE_SQL_ONLY=1"
            [ "$TL_FILE_SQL_UNFILTERED" = "1" ] && echo "      - TRACELIB_FILE_SQL_UNFILTERED=1"
            [ "$TL_FILE_SQL_FILTERED" = "1" ] && echo "      - TRACELIB_FILE_SQL_FILTERED=1"
            [ "$TL_BIGRAM_SEPARATED" = "1" ] && echo "      - TRACELIB_BIGRAM_FILE_SQL_SEPARATED=1"
            [ "$TL_BIGRAM_SEPARATED" = "1" ] && echo "      - TRACELIB_SEPARATED_MIN_HITS=$TL_SEPARATED_MIN_HITS"
            echo "      - TRACELIB_FILE_PATH_MONITORED=$TL_FILE_PATH_MONITORED"
            [ -n "$TL_EXCLUDED_FILE_PATH" ] && echo "      - TRACELIB_EXCLUDED_FILE_PATH=$TL_EXCLUDED_FILE_PATH"
            echo "      - TRACELIB_END_ON_STATUS_LINE=$TL_END_ON_STATUS_LINE"
            echo "      - TRACELIB_SQL_COMPACT=$TL_SQL_COMPACT"
            [ -n "$TL_FILTER_FILE" ] && echo "      - TRACELIB_SYSCALL_FILTER_FILE=${TL_FILTER_CONTAINER}"
            echo "    volumes:"
            echo "      - /dev/shm:/dev/shm"
            echo "      - /sys/kernel/tracing:/sys/kernel/tracing"
            echo "      - /sys/kernel/debug:/sys/kernel/debug"
            [ -n "$TL_FILTER_FILE" ] && echo "      - ${TL_FILTER_FILE}:${TL_FILTER_CONTAINER}:ro"
        } > "$OVERRIDE"
    else
        {
            echo "services:"
            echo "  ${SERVICE}:"
            echo "    {}"
        } > "$OVERRIDE"
    fi
elif [ "$COMPOSE_MODE" = "php" ]; then
    COMPOSE_FILES=( -f "$APP_DIR/docker-compose.native.yml" )
    {
        echo "services:"
        echo "  ${SERVICE}:"
        if [ "$IS_EBPF" = "1" ]; then
            echo "    entrypoint: [\"/usr/local/bin/ebpf-entrypoint.sh\"]"
            echo "    command: [\"apache2-foreground\"]"
            echo "    privileged: true"
            echo "    pid: \"host\""
            echo "    environment:"
            echo "      - TRACELIB_BACKEND=ebpf"
            echo "      - TRACELIB_PORT=${PORT}"
            echo "      - TRACELIB_HEADER=X-REQUEST-ID"
            echo "      - TRACELIB_COVERAGE_MODE=${TL_COV_MODE}"
            [ "$TL_FILE_SQL_ONLY" = "1" ] && echo "      - TRACELIB_FILE_SQL_ONLY=1"
            [ "$TL_FILE_SQL_UNFILTERED" = "1" ] && echo "      - TRACELIB_FILE_SQL_UNFILTERED=1"
            [ "$TL_FILE_SQL_FILTERED" = "1" ] && echo "      - TRACELIB_FILE_SQL_FILTERED=1"
            [ "$TL_BIGRAM_SEPARATED" = "1" ] && echo "      - TRACELIB_BIGRAM_FILE_SQL_SEPARATED=1"
            [ "$TL_BIGRAM_SEPARATED" = "1" ] && echo "      - TRACELIB_SEPARATED_MIN_HITS=$TL_SEPARATED_MIN_HITS"
            echo "      - TRACELIB_FILE_PATH_MONITORED=$TL_FILE_PATH_MONITORED"
            [ -n "$TL_EXCLUDED_FILE_PATH" ] && echo "      - TRACELIB_EXCLUDED_FILE_PATH=$TL_EXCLUDED_FILE_PATH"
            echo "      - TRACELIB_END_ON_STATUS_LINE=$TL_END_ON_STATUS_LINE"
            echo "      - TRACELIB_SQL_COMPACT=$TL_SQL_COMPACT"
            [ -n "$TL_FILTER_FILE" ] && echo "      - TRACELIB_SYSCALL_FILTER_FILE=${TL_FILTER_CONTAINER}"
            echo "    volumes:"
            echo "      - /dev/shm:/dev/shm"
            echo "      - /sys/kernel/tracing:/sys/kernel/tracing"
            echo "      - /sys/kernel/debug:/sys/kernel/debug"
            [ -n "$TL_FILTER_FILE" ] && echo "      - ${TL_FILTER_FILE}:${TL_FILTER_CONTAINER}:ro"
            [ "$DISABLE_PCOV" = "1" ] && echo "      - ${HERE}/assets/nopcov.ini:/usr/local/etc/php/conf.d/zz-disable-pcov.ini:ro"
        else
            if [ "$DISABLE_PCOV" = "1" ]; then
                echo "    volumes:"
                echo "      - ${HERE}/assets/nopcov.ini:/usr/local/etc/php/conf.d/zz-disable-pcov.ini:ro"
            else
                echo "    {}"
            fi
        fi
    } > "$OVERRIDE"
else
    COMPOSE_FILES=( -f "$APP_DIR/docker-compose.yml" -f "$APP_DIR/docker-compose.ebpf.yml" )
    if [ "$IS_EBPF" = "1" ]; then
        DC_PROFILES=( --profile ebpf )
        EBPF_LOG_SVC="tracelib_ebpf"
    fi
    {
        echo "services:"
        wrote_service=0
        if [ "$RUNTIME" = "node" ] || [ -n "$FEEDBACK_CAPTURE_DIR" ] || [ "$FORCE_PLATFORM_COVERAGE_FLUSH_INTERVALS" = "1" ]; then
            echo "  ${SERVICE}:"
            echo "    environment:"
            case "$RUNTIME" in
                node)
                    echo "      - TRACELIB_COVERAGE_TAKE_ON_RESPONSE=${NODE_COVERAGE_TAKE_ON_RESPONSE}"
                    echo "      - TRACELIB_COVERAGE_INTERVAL_MS=${NODE_COVERAGE_INTERVAL_MS}" ;;
                go)
                    echo "      - GOCOV_FLUSH_INTERVAL_SECONDS=1" ;;
                ruby)
                    echo "      - TRACELIB_COVERAGE_INTERVAL_SECONDS=1" ;;
                python)
                    echo "      - COVERAGE_FLUSH_EVERY=1" ;;
                java)
                    echo "      - JACOCO_AGENT_PORT=6300" ;;
            esac
            wrote_service=1
        fi
        if [ "$IS_EBPF" = "1" ] && { [ "$TL_COV_MODE" = "bigram" ] || [ -n "$TL_FILTER_FILE" ] || [ "$TL_FILE_SQL_ONLY" = "1" ] || [ "$TL_FILE_SQL_UNFILTERED" = "1" ] || [ "$TL_FILE_SQL_FILTERED" = "1" ]; }; then
            echo "  tracelib_ebpf:"
            echo "    environment:"
            echo "      - TRACELIB_COVERAGE_MODE=${TL_COV_MODE}"
            [ "$TL_FILE_SQL_ONLY" = "1" ] && echo "      - TRACELIB_FILE_SQL_ONLY=1"
            [ "$TL_FILE_SQL_UNFILTERED" = "1" ] && echo "      - TRACELIB_FILE_SQL_UNFILTERED=1"
            [ "$TL_FILE_SQL_FILTERED" = "1" ] && echo "      - TRACELIB_FILE_SQL_FILTERED=1"
            [ "$TL_BIGRAM_SEPARATED" = "1" ] && echo "      - TRACELIB_BIGRAM_FILE_SQL_SEPARATED=1"
            [ "$TL_BIGRAM_SEPARATED" = "1" ] && echo "      - TRACELIB_SEPARATED_MIN_HITS=$TL_SEPARATED_MIN_HITS"
            echo "      - TRACELIB_FILE_PATH_MONITORED=$TL_FILE_PATH_MONITORED"
            [ -n "$TL_EXCLUDED_FILE_PATH" ] && echo "      - TRACELIB_EXCLUDED_FILE_PATH=$TL_EXCLUDED_FILE_PATH"
            echo "      - TRACELIB_END_ON_STATUS_LINE=$TL_END_ON_STATUS_LINE"
            echo "      - TRACELIB_SQL_COMPACT=$TL_SQL_COMPACT"
            [ -n "$TL_FILTER_FILE" ] && echo "      - TRACELIB_SYSCALL_FILTER_FILE=${TL_FILTER_CONTAINER}"
            if [ -n "$TL_FILTER_FILE" ]; then
                echo "    volumes:"
                echo "      - ${TL_FILTER_FILE}:${TL_FILTER_CONTAINER}:ro"
            fi
        elif [ "$wrote_service" = "0" ]; then
            echo "  ${SERVICE}:"
            echo "    {}"
        fi
    } > "$OVERRIDE"
fi
COMPOSE_FILES+=( -f "$OVERRIDE" )

dc() { "${DOCKER[@]}" compose -p "$COMPOSE_PROJECT_NAME" --env-file "$ENVFILE" "${COMPOSE_FILES[@]}" ${DC_PROFILES[@]+"${DC_PROFILES[@]}"} "$@"; }
container_exec() { "${DOCKER[@]}" exec "$SERVICE_CONTAINER" "$@"; }

if [ -n "$FEEDBACK_CAPTURE_DIR" ] && [ "$COMPOSE_MODE" = "nonphp" ] && [ "$NONPHP_REQUEST_FEEDBACK_REFERENCE" = "1" ]; then
    FEEDBACK_REFERENCE_KIND="language_line_union"
    if [ "$NONPHP_REQUEST_FEEDBACK_MODE" = "reset" ]; then
        FEEDBACK_REFERENCE_KIND="language_line_set"
    fi
    if [ "$NONPHP_REQUEST_FEEDBACK_MODE" = "reset" ]; then
        FEEDBACK_REFERENCE_RESET="$TMPRUN/feedback_reference_reset.sh"
        {
            printf '#!/bin/bash\n'
            printf 'set -u\n'
            printf 'set -o pipefail\n'
            printf 'DOCKER=(sudo -n /usr/bin/docker)\n'
            printf 'SERVICE_CONTAINER=%q\n' "$SERVICE_CONTAINER"
            printf 'RUNTIME=%q\n' "$RUNTIME"
            cat <<'EOS'
container_exec() { "${DOCKER[@]}" exec "$SERVICE_CONTAINER" "$@"; }

case "$RUNTIME" in
    go)
        container_exec sh -lc 'touch /coverage/reset.request; kill -USR1 1 2>/dev/null || true; for i in $(seq 1 20); do [ ! -e /coverage/reset.request ] && break; sleep 0.05; done; rm -f /coverage/reset.request 2>/dev/null || true; find /coverage -maxdepth 1 -name "covcounters.*" -type f -delete 2>/dev/null || true' >/dev/null 2>&1 || true ;;
    ruby)
        container_exec sh -lc 'touch /coverage/reset.request; rm -f /coverage/coverage.json /coverage/coverage.json.tmp 2>/dev/null || true' >/dev/null 2>&1 || true ;;
    python)
        container_exec sh -lc 'rm -f /coverage/.coverage* 2>/dev/null || true; date +%s%N > /coverage/reset.token' >/dev/null 2>&1 || true ;;
    node)
        container_exec sh -c 'n=0; for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null); case "${e##*/}" in node|nodejs) kill -USR2 "${p#/proc/}" 2>/dev/null && n=$((n+1)) ;; esac; done; [ "$n" -gt 0 ] || pkill -USR2 -x node 2>/dev/null || true' >/dev/null 2>&1 || true
        container_exec sh -lc 'sleep 0.25; find /coverage/v8 -maxdepth 1 -name "*.json" -type f -delete 2>/dev/null || true' >/dev/null 2>&1 || true ;;
    java)
        container_exec sh -lc 'TRACELIB_COVERAGE_RESET=1 sh /tracelib-support/coverage_report.sh >/dev/null 2>&1 || true' >/dev/null 2>&1 || true ;;
    *)
        exit 0 ;;
esac
echo '{"reset":"ok"}'
EOS
        } > "$FEEDBACK_REFERENCE_RESET"
        chmod +x "$FEEDBACK_REFERENCE_RESET"
        FEEDBACK_REFERENCE_RESET_CMD="$FEEDBACK_REFERENCE_RESET"
    fi
    FEEDBACK_REFERENCE_SAMPLER="$TMPRUN/feedback_reference_sample.sh"
    {
        printf '#!/bin/bash\n'
        printf 'set -u\n'
        printf 'set -o pipefail\n'
        printf 'DOCKER=(sudo -n /usr/bin/docker)\n'
        printf 'COMPOSE_PROJECT_NAME=%q\n' "$COMPOSE_PROJECT_NAME"
        printf 'ENVFILE=%q\n' "$ENVFILE"
        printf 'SERVICE=%q\n' "$SERVICE"
        printf 'SERVICE_CONTAINER=%q\n' "$SERVICE_CONTAINER"
        printf 'RUNTIME=%q\n' "$RUNTIME"
        printf 'REFERENCE_KIND=%q\n' "$FEEDBACK_REFERENCE_KIND"
        printf 'REFERENCE_MODE=%q\n' "$NONPHP_REQUEST_FEEDBACK_MODE"
        printf 'COVERAGE_SAMPLE_TIMEOUT=%q\n' "$COVERAGE_SAMPLE_TIMEOUT"
        printf 'COVERAGE_SAMPLE_FAILURE_LOG=%q\n' "$TMPRUN/coverage_sample_failures.log"
        printf 'COMPOSE_FILES=(\n'
        for compose_arg in "${COMPOSE_FILES[@]}"; do
            printf '  %q\n' "$compose_arg"
        done
        printf ')\n'
        printf 'DC_PROFILES=(\n'
        for profile_arg in "${DC_PROFILES[@]+"${DC_PROFILES[@]}"}"; do
            printf '  %q\n' "$profile_arg"
        done
        printf ')\n'
        cat <<'EOS'
dc() { "${DOCKER[@]}" compose -p "$COMPOSE_PROJECT_NAME" --env-file "$ENVFILE" "${COMPOSE_FILES[@]}" ${DC_PROFILES[@]+"${DC_PROFILES[@]}"} "$@"; }
container_exec() { "${DOCKER[@]}" exec "$SERVICE_CONTAINER" "$@"; }
json_error() {
    printf '{"reference_kind":"%s","reference_mode":"%s","error":"%s"}\n' "$REFERENCE_KIND" "$REFERENCE_MODE" "$1"
}

SAMPLE_ERR="$(mktemp)"
trap 'rm -f "$SAMPLE_ERR"' EXIT
sample_once() {
    _t="$1"
    case "$RUNTIME" in
        go|ruby)
            if [ "$RUNTIME" = "ruby" ]; then
                :
            else
                container_exec sh -c 'kill -USR1 1 2>/dev/null || true' >/dev/null 2>&1 || true
            fi
            sleep 0.25
            container_exec sh -lc "timeout --kill-after=3s ${_t}s sh /tracelib-support/coverage_report.sh" 2>"$SAMPLE_ERR" || true ;;
        python)
            container_exec sh -lc "timeout --kill-after=3s ${_t}s python3 /tracelib-support/coverage_report.py" 2>"$SAMPLE_ERR" || true ;;
        node)
            container_exec sh -c 'n=0; for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null); case "${e##*/}" in node|nodejs) kill -USR2 "${p#/proc/}" 2>/dev/null && n=$((n+1)) ;; esac; done; [ "$n" -gt 0 ] || pkill -USR2 -x node 2>/dev/null || true' >/dev/null 2>&1 || true
            sleep 0.25
            container_exec sh -lc "timeout --kill-after=3s ${_t}s sh /tracelib-support/coverage_report.sh" 2>"$SAMPLE_ERR" || true ;;
        java)
            container_exec sh -lc "timeout --kill-after=3s ${_t}s sh /tracelib-support/coverage_report.sh" 2>"$SAMPLE_ERR" || true ;;
        *)
            return 1 ;;
    esac
}

parse_out() {
    echo "$1" | sed -nE 's/.* ([0-9]+) \/ ([0-9]+) lines covered \(([0-9.]+)%\).*/\1 \2 \3/p' | head -n1
}

case "$RUNTIME" in
    go|ruby|python|node|java) ;;
    *) json_error "unsupported_runtime"; exit 0 ;;
esac

out="$(sample_once "$COVERAGE_SAMPLE_TIMEOUT")"
parsed="$(parse_out "$out")"

if [ -z "$parsed" ]; then
    retry_timeout=$(( COVERAGE_SAMPLE_TIMEOUT * 2 ))
    out="$(sample_once "$retry_timeout")"
    parsed="$(parse_out "$out")"
fi

if [ -z "$parsed" ]; then
    detail="$(tr -d '"\\' < "$SAMPLE_ERR" | tr '\n' ' ' | cut -c1-200)"
    [ -n "$out" ] && detail="${detail} stdout:$(echo "$out" | tr -d '"\\' | tr '\n' ' ' | cut -c1-200)"
    [ -z "$detail" ] && detail="${RUNTIME} coverage reporter produced no stdout and no stderr at ${COVERAGE_SAMPLE_TIMEOUT}s and again at $(( COVERAGE_SAMPLE_TIMEOUT * 2 ))s; either the in-container timeout fired or sample_once aborted before running it"
    if [ -n "${COVERAGE_SAMPLE_FAILURE_LOG:-}" ]; then
        printf '%s unparsed runtime=%s timeout=%s detail=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUNTIME" "$COVERAGE_SAMPLE_TIMEOUT" "$detail" \
            >> "$COVERAGE_SAMPLE_FAILURE_LOG" 2>/dev/null || true
    fi
    printf '{"reference_kind":"%s","reference_mode":"%s","error":"unparsed","detail":"%s"}\n' \
        "$REFERENCE_KIND" "$REFERENCE_MODE" "$detail"
    exit 0
fi
coverage_hash="$(echo "$out" | sed -nE 's/^coverage_hash:[[:space:]]*([0-9a-fA-F]{64}).*/\1/p' | head -n1 | tr 'A-F' 'a-f')"
set -- $parsed
if [ -n "$coverage_hash" ]; then
    printf '{"reference_kind":"%s","reference_mode":"%s","covered":%s,"total":%s,"pct":%s,"covered_hash":"%s"}\n' "$REFERENCE_KIND" "$REFERENCE_MODE" "$1" "$2" "$3" "$coverage_hash"
else
    printf '{"reference_kind":"%s","reference_mode":"%s","covered":%s,"total":%s,"pct":%s}\n' "$REFERENCE_KIND" "$REFERENCE_MODE" "$1" "$2" "$3"
fi
EOS
    } > "$FEEDBACK_REFERENCE_SAMPLER"
    chmod +x "$FEEDBACK_REFERENCE_SAMPLER"
    for _leaked in NODE_FLUSH_SIGNAL_SH TL_FILE_PATH_MONITORED MONITOR_ROOT BASE_URL TMPRUN; do
        if grep -q "\$$_leaked" "$FEEDBACK_REFERENCE_SAMPLER"; then
            log "ERROR: generated feedback sampler references \$$_leaked, which it never defines;"
            log "       it is emitted inside a quoted heredoc, so that name will be unbound under set -u"
            exit 1
        fi
    done
    unset _leaked
    bash -n "$FEEDBACK_REFERENCE_SAMPLER" || { log "ERROR: generated feedback sampler has a syntax error"; exit 1; }
    FEEDBACK_REFERENCE_CMD="$FEEDBACK_REFERENCE_SAMPLER"
elif [ -n "$FEEDBACK_CAPTURE_DIR" ] && [ "$COMPOSE_MODE" = "nonphp" ]; then
    log "per-request non-PHP platform reference disabled (set NONPHP_REQUEST_FEEDBACK_REFERENCE=1 to enable); CSV platform coverage follows PLATFORM_COVERAGE_SAMPLE=${PLATFORM_COVERAGE_SAMPLE:-1}"
fi

STATS_PID=""
FEEDBACK_SYNC_PID=""
write_request_feedback_json() {
    [ -n "${REQUEST_FEEDBACK_FILE:-}" ] || return 0
    local context="${1:-final}"
    "$REQUEST_FEEDBACK_PYTHON" "$HERE/export_request_feedback.py" \
        "$FEEDBACK_CAPTURE_DIR" "$REQUEST_FEEDBACK_FILE" --phase "$REQUEST_FEEDBACK_PHASE"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        if [ "$context" = "periodic" ]; then
            log "request feedback JSON updated: $REQUEST_FEEDBACK_FILE"
        else
            log "request feedback JSON: $REQUEST_FEEDBACK_FILE"
        fi
    else
        log "ERROR: request feedback JSON export failed (rc=$rc): $REQUEST_FEEDBACK_FILE"
    fi
    return "$rc"
}

copy_feedback_artifacts() {
    [ -n "${FEEDBACK_CAPTURE_DIR:-}" ] || return 0

    local context="${1:-final}"
    local ids_file request_id bitmap_file bitmap_dest has_ast has_bitmap
    local paired=0 missing=0 missing_ast=0 manifest_requests=0 copied_bitmaps=0 new_bitmaps=0
    mkdir -p "$FEEDBACK_CAPTURE_DIR/tracelib"
    ids_file="$TMPRUN/feedback_request_ids.txt"
    if [ -s "$FEEDBACK_CAPTURE_DIR/requests.jsonl" ]; then
        python3 - "$FEEDBACK_CAPTURE_DIR/requests.jsonl" > "$ids_file" <<'PY' || true
import json
import sys

seen = set()
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as source:
    for raw in source:
        try:
            rid = str(json.loads(raw)["request_id"])
        except Exception:
            continue
        if rid.startswith("wf-") and rid not in seen:
            seen.add(rid)
            print(rid)
PY
    elif [ "$COMPOSE_MODE" = "php" ]; then
        find "$INSTR_HOST_DIR" -maxdepth 1 -name 'map.wf-*' -type f -printf '%f\n' 2>/dev/null \
            | sed 's/^map\.//' > "$ids_file"
    else
        : > "$ids_file"
    fi

    while IFS= read -r request_id; do
        [ -n "$request_id" ] || continue
        manifest_requests=$((manifest_requests + 1))
        has_ast=1
        if [ "$COMPOSE_MODE" = "php" ] && [ ! -f "$INSTR_HOST_DIR/map.$request_id" ]; then
            missing_ast=$((missing_ast + 1))
            has_ast=0
        fi
        has_bitmap=0
        bitmap_file="$BITMAP_DIR/$request_id"
        bitmap_dest="$FEEDBACK_CAPTURE_DIR/tracelib/$request_id"
        if [ -f "$bitmap_dest" ] \
           && [ "$(stat -c %s "$bitmap_dest" 2>/dev/null || echo 0)" -ge 65536 ]; then
            has_bitmap=1
            copied_bitmaps=$((copied_bitmaps + 1))
        elif [ -f "$bitmap_file" ] \
             && [ "$(stat -c %s "$bitmap_file" 2>/dev/null || echo 0)" -ge 65536 ]; then
            if cp -p -- "$bitmap_file" "$bitmap_dest"; then
                has_bitmap=1
                copied_bitmaps=$((copied_bitmaps + 1))
                new_bitmaps=$((new_bitmaps + 1))
            fi
        fi

        if [ "$has_bitmap" = "1" ]; then
            if [ "$COMPOSE_MODE" != "php" ] || [ "$has_ast" = "1" ]; then
                paired=$((paired + 1))
            fi
        else
            missing=$((missing + 1))
        fi
    done < "$ids_file"

    [ -n "${META_FILE:-}" ] && [ -f "$META_FILE" ] \
        && cp -p -- "$META_FILE" "$FEEDBACK_CAPTURE_DIR/instr.meta"
    {
        echo "app=$APP_NAME"
        echo "runtime=$RUNTIME"
        echo "mode=$MODE"
        echo "tracelib_coverage_mode=$TL_COV_MODE"
        echo "tracelib_file_sql_only=$TL_FILE_SQL_ONLY"
        echo "tracelib_file_sql_unfiltered=$TL_FILE_SQL_UNFILTERED"
    echo "tracelib_file_sql_filtered=$TL_FILE_SQL_FILTERED"
        echo "tracelib_file_sql_filtered=$TL_FILE_SQL_FILTERED"
        echo "tracelib_bigram_file_sql_separated=$TL_BIGRAM_SEPARATED"
        echo "tracelib_separated_min_hits=$TL_SEPARATED_MIN_HITS"
    echo "tracelib_file_path_monitored=$TL_FILE_PATH_MONITORED"
    echo "tracelib_excluded_file_path=$TL_EXCLUDED_FILE_PATH"
    echo "tracelib_end_on_status_line=$TL_END_ON_STATUS_LINE"
    echo "tracelib_sql_compact=$TL_SQL_COMPACT"
    if [ "$TL_SQL_COMPACT" != "1" ]; then
        echo "tracelib_sql_encoding=reduced_or_skeleton"
    elif [ "$IS_EBPF" = "1" ] && { [ "$TL_COV_MODE" != "bigram" ] || [ "$TL_BIGRAM_SEPARATED" = "1" ]; }; then
        echo "tracelib_sql_encoding=in_kernel_fold"
    else
        echo "tracelib_sql_encoding=compact_commands_tables"
    fi
        echo "tracelib_file_path_monitored=$TL_FILE_PATH_MONITORED"
    echo "tracelib_excluded_file_path=$TL_EXCLUDED_FILE_PATH"
    echo "tracelib_end_on_status_line=$TL_END_ON_STATUS_LINE"
    echo "tracelib_sql_compact=$TL_SQL_COMPACT"
    if [ "$TL_SQL_COMPACT" != "1" ]; then
        echo "tracelib_sql_encoding=reduced_or_skeleton"
    elif [ "$IS_EBPF" = "1" ] && { [ "$TL_COV_MODE" != "bigram" ] || [ "$TL_BIGRAM_SEPARATED" = "1" ]; }; then
        echo "tracelib_sql_encoding=in_kernel_fold"
    else
        echo "tracelib_sql_encoding=compact_commands_tables"
    fi
        echo "tracelib_excluded_file_path=$TL_EXCLUDED_FILE_PATH"
    echo "tracelib_end_on_status_line=$TL_END_ON_STATUS_LINE"
    echo "tracelib_sql_compact=$TL_SQL_COMPACT"
    if [ "$TL_SQL_COMPACT" != "1" ]; then
        echo "tracelib_sql_encoding=reduced_or_skeleton"
    elif [ "$IS_EBPF" = "1" ] && { [ "$TL_COV_MODE" != "bigram" ] || [ "$TL_BIGRAM_SEPARATED" = "1" ]; }; then
        echo "tracelib_sql_encoding=in_kernel_fold"
    else
        echo "tracelib_sql_encoding=compact_commands_tables"
    fi
        [ -n "$TL_FILTER_FILE" ] && echo "tracelib_syscall_filter_sha256=$TL_FILTER_SHA256"
        if [ "$COMPOSE_MODE" = "php" ]; then
            echo "reference_kind=php_ast"
        else
            if [ "${NONPHP_REQUEST_FEEDBACK_MODE:-cumulative}" = "reset" ]; then
                echo "reference_kind=language_line_set"
            else
                echo "reference_kind=language_line_union"
            fi
            echo "reference_mode=${NONPHP_REQUEST_FEEDBACK_MODE:-cumulative}"
        fi
        echo "coverage_source=$COVERAGE_SOURCE"
        echo "target_url=$TARGET_URL"
        echo "campaign_stem=$STEM"
        echo "manifest_requests=$manifest_requests"
        echo "paired_files=$paired"
        echo "copied_bitmaps=$copied_bitmaps"
        echo "new_bitmaps=$new_bitmaps"
        echo "missing_bitmap=$missing"
        echo "missing_ast=$missing_ast"
    } > "$FEEDBACK_CAPTURE_DIR/metadata.env"
    if [ "$context" = "periodic" ]; then
        log "feedback sync: requests=$manifest_requests paired=$paired new_bitmaps=$new_bitmaps missing_bitmap=$missing missing_ast=$missing_ast dir=$FEEDBACK_CAPTURE_DIR"
    else
        log "feedback artifacts: requests=$manifest_requests paired=$paired copied_bitmaps=$copied_bitmaps missing_bitmap=$missing missing_ast=$missing_ast dir=$FEEDBACK_CAPTURE_DIR"
    fi
    write_request_feedback_json "$context" || true
}

start_feedback_sync_loop() {
    [ -n "${FEEDBACK_CAPTURE_DIR:-}" ] || return 0
    [ "${FEEDBACK_CAPTURE_SYNC_INTERVAL:-0}" -gt 0 ] 2>/dev/null || return 0
    (
        trap 'exit 0' INT TERM
        while :; do
            sleep "$FEEDBACK_CAPTURE_SYNC_INTERVAL"
            copy_feedback_artifacts periodic || true
        done
    ) &
    FEEDBACK_SYNC_PID=$!
    log "feedback sync loop started (pid $FEEDBACK_SYNC_PID): every ${FEEDBACK_CAPTURE_SYNC_INTERVAL}s"
}

stop_feedback_sync_loop() {
    [ -n "${FEEDBACK_SYNC_PID:-}" ] || return 0
    kill "$FEEDBACK_SYNC_PID" 2>/dev/null || true
    wait "$FEEDBACK_SYNC_PID" 2>/dev/null || true
    FEEDBACK_SYNC_PID=""
}

cleanup() {
    log "cleanup"
    [ -n "${STATS_PID:-}" ] && kill "$STATS_PID" 2>/dev/null || true
    stop_feedback_sync_loop || true
    copy_feedback_artifacts || true
    if [ "${NO_TEARDOWN:-0}" = "1" ]; then
        log "NO_TEARDOWN=1 — leaving stack up"
    else
        dc down -v >/dev/null 2>&1 || true
    fi
    if [ -z "${FEEDBACK_CAPTURE_DIR:-}" ]; then
        [ -n "${INSTR_HOST_DIR:-}" ] && rm -rf "$INSTR_HOST_DIR" 2>/dev/null || true
    elif [ "${REQUEST_FEEDBACK_INTERNAL_CAPTURE:-0}" = "1" ]; then
        rm -rf "$FEEDBACK_CAPTURE_DIR" 2>/dev/null || true
    fi
    if [ "$KEEP_CAMPAIGN_TMP" = "1" ]; then
        log "keeping temporary campaign directory: $TMPRUN"
    else
        rm -rf -- "$TMPRUN" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

LEFT="$("${DOCKER[@]}" ps -a --filter "name=campv6-" --format '{{.ID}} {{.Names}}' 2>/dev/null | awk -v a="-${APP_NAME}-" 'index($2,a){print $1}')"
[ -n "$LEFT" ] && { log "clearing leftover campv6 container(s) for $APP_NAME"; "${DOCKER[@]}" rm -f $LEFT >/dev/null 2>&1 || true; }
[ "$RESET_STATE" = "1" ] && dc down -v >/dev/null 2>&1 || true
start_compose_stack() {
    local attempt=1
    while [ "$attempt" -le "$COMPOSE_UP_ATTEMPTS" ]; do
        log "building + starting stack (attempt $attempt/$COMPOSE_UP_ATTEMPTS)"
        if dc up -d --build; then
            return 0
        fi
        if [ "$attempt" -ge "$COMPOSE_UP_ATTEMPTS" ]; then
            break
        fi
        log "compose build/start attempt $attempt failed; retrying in ${COMPOSE_UP_RETRY_DELAY}s"
        dc down -v >/dev/null 2>&1 || true
        sleep "$COMPOSE_UP_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
    return 1
}
start_compose_stack || { log "compose build/start failed after $COMPOSE_UP_ATTEMPTS attempt(s)"; exit 1; }

log "waiting for $APP_NAME on $TARGET_URL"
deadline=$(( $(date +%s) + 900 ))
until curl -fsS -o /dev/null "$TARGET_URL"; do
    [ "$(date +%s)" -ge "$deadline" ] && { log "app did not come up in 900s; aborting"; dc logs --tail=120 "$SERVICE"; exit 1; }
    sleep 3
done
log "port open"

if [ "$IS_EBPF" = "1" ]; then
    log "waiting for tracelib_ebpf to load+attach (eBPF, coverage-mode=$TL_COV_MODE)"
    deadline=$(( $(date +%s) + 600 ))
    until dc logs --no-color "$EBPF_LOG_SVC" 2>/dev/null | grep -qE "tracing\.\.\.|tracking tgid|attaching tracelib_ebpf"; do
        if dc logs --no-color "$EBPF_LOG_SVC" 2>/dev/null | grep -qE "backend 'ebpf' failed|eBPF is unavailable|load/verify failed|tracelib__attach failed"; then
            log "ERROR: eBPF backend failed to start — dumping logs"; dc logs --tail=120 "$EBPF_LOG_SVC"; exit 1
        fi
        [ "$(date +%s)" -ge "$deadline" ] && { log "tracelib_ebpf never attached in 600s; aborting"; dc logs --tail=120 "$EBPF_LOG_SVC"; exit 1; }
        sleep 3
    done
    log "tracelib_ebpf attached"
fi

log "waiting for install to settle"
deadline=$(( $(date +%s) + 600 ))
APP_READY_MARKER="${APP_READY_MARKER:-/tmp/tracelib-app-ready}"
marker_grace_deadline=$(( $(date +%s) + ${APP_READY_MARKER_GRACE:-420} ))
while :; do
    final_url=$(curl -sS -o "$TMPRUN/settle.html" -L -w '%{url_effective}' "$TARGET_URL" 2>/dev/null || echo "")
    body_size=$(wc -c < "$TMPRUN/settle.html" 2>/dev/null || echo 0)
    case "$final_url" in
        *install.php*|*/install|*/install/*|*/installation/*|*/zc_install/*|*/core/install*|"") settled=0 ;;
        *)
            if [ "$COMPOSE_MODE" = "nonphp" ] && [ "${ALLOW_NON_HTML:-0}" = "1" ] && [ "$body_size" -gt 0 ] 2>/dev/null; then
                settled=1
            else
                [ "$body_size" -lt 500 ] && settled=0 || settled=1
            fi ;;
    esac
    if [ "$settled" = "1" ] && [ "$COMPOSE_MODE" = "nonphp" ] && [ "${APP_READY_MARKER_WAIT:-1}" = "1" ]; then
        if container_exec test -f "$APP_READY_MARKER" >/dev/null 2>&1; then
            :
        elif [ "$(date +%s)" -lt "$marker_grace_deadline" ]; then
            settled=0
        fi
    fi
    [ "$settled" = "1" ] && { log "install settled: $final_url (${body_size}B)"; break; }
    [ "$(date +%s)" -ge "$deadline" ] && { log "WARNING: install never settled (last: $final_url) — proceeding"; break; }
    sleep 3
done
rm -f "$TMPRUN/settle.html"

log "post-settle quiesce (${QUIESCE_SECONDS}s)"
qi=$(( QUIESCE_SECONDS / 3 )); [ "$qi" -lt 1 ] && qi=1
for _ in $(seq 1 "$qi"); do
    curl -sS -o /dev/null "$TARGET_URL" 2>/dev/null || true
    sleep 3
done

META_FILE=""
if [ -n "$META_C" ]; then
    HOST_META="$TMPRUN/instr.meta.host"
    dc cp "$SERVICE:$META_C" "$HOST_META" || true
    [ -s "$HOST_META" ] || { log "instr.meta missing/empty; cannot measure coverage"; exit 1; }
    META_FILE="$HOST_META"
fi

if [ "$IS_EBPF" = "1" ]; then
    log "smoke check (eBPF bitmap appears in $BITMAP_DIR)"
    smoke_ok=0
    for attempt in 1 2 3 4 5 6; do
        rid="tl-smoke-${APP_NAME}-$(date +%s)-$attempt"
        curl -fsS --max-time 5 -o /dev/null -H "X-REQUEST-ID: $rid" "$TARGET_URL" || true
        sleep 8
        if [ -f "${BITMAP_DIR}/${rid}" ]; then
            nz=$(SMOKE_F="${BITMAP_DIR}/${rid}" python3 - <<'PY'
import os
p=os.environ["SMOKE_F"]
b=open(p,"rb").read()
print(sum(1 for x in b if x))
PY
)
            log "smoke ok on attempt $attempt: $rid (non-zero cells=$nz)"
            smoke_ok=1; break
        fi
    done
    [ "$smoke_ok" -eq 0 ] && { log "ERROR: no eBPF bitmap produced in 6 tries — aborting"; dc logs --tail=80 "$EBPF_LOG_SVC"; exit 1; }
fi

cd "$ROOT/webfuzz"
unset PYTHONHOME PYTHONPATH

can_create_venv() {
    local py="$1" tmp
    command -v "$py" >/dev/null 2>&1 || return 1
    tmp="$(mktemp -d "$TMPRUN/venv-probe.XXXXXX")" || return 1
    if "$py" -m venv "$tmp" >/dev/null 2>&1 && [ -x "$tmp/bin/python" ]; then
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

select_webfuzz_python() {
    local py
    for py in "${WEBFUZZ_PYTHON:-}" python3 python3.12 python3.13 python3.11; do
        [ -n "$py" ] || continue
        if can_create_venv "$py"; then
            command -v "$py"
            return 0
        fi
    done
    return 1
}

webfuzz_venv_ok() {
    local candidate="$1"
    [ -x "$candidate" ] || return 1
    "$candidate" - <<'PY' >/dev/null 2>&1
import aiohttp.client
import bs4
import html5lib
import jsonschema
import pyfiglet
import tap
import matplotlib

if not callable(getattr(matplotlib, "use", None)):
    raise SystemExit("invalid matplotlib module")
PY
}

WEBFUZZ_PY=""
VENV_DIR="${WEBFUZZ_VENV:-}"
VENV_PY=""
if [ -n "$VENV_DIR" ] && webfuzz_venv_ok "$VENV_DIR/bin/python"; then
    VENV_PY="$VENV_DIR/bin/python"
elif [ -z "$VENV_DIR" ]; then
    for candidate_dir in /var/tmp/webfuzz-venv-*; do
        candidate_py="$candidate_dir/bin/python"
        if webfuzz_venv_ok "$candidate_py"; then
            VENV_DIR="$candidate_dir"
            VENV_PY="$candidate_py"
            break
        fi
    done
fi

if [ -n "$VENV_PY" ]; then
    WEBFUZZ_PY="$VENV_PY"
    log "reusing valid webFuzz venv: $VENV_DIR"
else
    WEBFUZZ_PY="$(select_webfuzz_python)" || {
        log "ERROR: no valid webFuzz venv found and no Python interpreter can create one; install python3-venv or set WEBFUZZ_PYTHON=/path/to/python"
        exit 1
    }
    VENV_TAG="$("$WEBFUZZ_PY" -c 'import sys,platform; print(f"{platform.node()}-py{sys.version_info[0]}{sys.version_info[1]}")')"
    VENV_DIR="${VENV_DIR:-/var/tmp/webfuzz-venv-${USER}-${VENV_TAG}}"
    VENV_PY="$VENV_DIR/bin/python"
    log "using webFuzz base Python at $WEBFUZZ_PY"
    log "using webFuzz venv at $VENV_DIR"
fi

venv_ok() { webfuzz_venv_ok "$VENV_PY"; }
if ! venv_ok; then
    log "webFuzz venv is missing or invalid; rebuilding $VENV_DIR"
    rm -rf "$VENV_DIR"
    "$WEBFUZZ_PY" -m venv "$VENV_DIR"
    "$VENV_PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
    "$VENV_PY" -m pip install --quiet --upgrade pip setuptools wheel
    "$VENV_PY" -m pip install --quiet -r requirements.txt
    "$VENV_PY" -m pip install --quiet matplotlib
    venv_ok || { log "ERROR: webFuzz venv validation failed after rebuild"; exit 1; }
fi

flush_node_coverage() {
    local before after attempt
    before="$(container_exec sh -lc 'find /coverage/v8 -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
    case "$before" in ""|*[!0-9]*) before=0 ;; esac
    container_exec sh -c "$NODE_FLUSH_SIGNAL_SH" >/dev/null 2>&1 || true
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        sleep 0.25
        after="$(container_exec sh -lc 'find /coverage/v8 -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
        case "$after" in ""|*[!0-9]*) after=0 ;; esac
        [ "$after" -gt "$before" ] && return 0
    done
    return 1
}

reset_platform_coverage() {
    if [ "$EFFECTIVE_WUT_IMAGE_PROFILE" = "bare" ]; then
        log "bare WUT: skipping unavailable platform-coverage reset"
        return
    fi

    if [ "$COMPOSE_MODE" = "php" ]; then
        find "$INSTR_HOST_DIR" -maxdepth 1 -name 'map.*' -type f -delete 2>/dev/null || true
        rm -f "$TMPRUN/cum_consumed" 2>/dev/null || true
        return
    fi

    case "$RUNTIME" in
        go)
            container_exec sh -lc 'touch /coverage/reset.request; kill -USR1 1 2>/dev/null || true; for i in $(seq 1 20); do [ ! -e /coverage/reset.request ] && break; sleep 0.05; done; rm -f /coverage/reset.request 2>/dev/null || true; find /coverage -maxdepth 1 -name "covcounters.*" -type f -delete 2>/dev/null || true' >/dev/null 2>&1 || true ;;
        ruby)
            container_exec sh -lc 'touch /coverage/reset.request; rm -f /coverage/coverage.json /coverage/coverage.json.tmp 2>/dev/null || true' >/dev/null 2>&1 || true ;;
        python)
            container_exec sh -lc 'rm -f /coverage/.coverage* 2>/dev/null || true; date +%s%N > /coverage/reset.token' >/dev/null 2>&1 || true ;;
        java)
            container_exec sh -lc 'TRACELIB_COVERAGE_RESET=1 sh /tracelib-support/coverage_report.sh >/dev/null 2>&1 || true' >/dev/null 2>&1 || true ;;
        node)
            flush_node_coverage || true
            container_exec sh -lc 'find /coverage/v8 -maxdepth 1 -name "*.json" -type f -delete 2>/dev/null || true' >/dev/null 2>&1 || true ;;
    esac
}

SINGLE_ENDPOINT_COOKIE_FILE=""
SINGLE_ENDPOINT_VALIDATION_CSV=""
if [ "$SINGLE_ENDPOINT_MODE" = "1" ] && [ "$SINGLE_ENDPOINT_VALIDATE" = "1" ]; then
    SINGLE_ENDPOINT_COOKIE_FILE="$TMPRUN/single_endpoint_cookies.txt"
    SINGLE_ENDPOINT_VALIDATION_CSV="$RESULT_DIR/${STEM}.endpoints.csv"
    log "validating single-endpoint URL set with app auto-login"
    env -u PYTHONHOME -u PYTHONPATH \
        VIRTUAL_ENV="$VENV_DIR" \
        PATH="$VENV_DIR/bin:$PATH" \
        WEBFUZZ_TARGET_URL="$BASE_URL" \
        WEBFUZZ_USER_AGENT="$WEBFUZZ_USER_AGENT" \
        WEBFUZZ_EXTRA_HEADERS="$WEBFUZZ_EXTRA_HEADERS" \
        "$VENV_PY" "$ROOT/single_endpoint_campaign/validate_endpoints.py" \
            --app "$APP_NAME" \
            --base-url "$BASE_URL" \
            --endpoint-file "$SINGLE_ENDPOINT_FILE" \
            --auto-login-dir "$AUTO_LOGIN_DIR" \
            --output-csv "$SINGLE_ENDPOINT_VALIDATION_CSV" \
            --cookie-output "$SINGLE_ENDPOINT_COOKIE_FILE" \
            --timeout "$SINGLE_ENDPOINT_VALIDATE_TIMEOUT" \
        || { log "single-endpoint validation failed; see $SINGLE_ENDPOINT_VALIDATION_CSV"; exit 1; }
    log "endpoint validation CSV: $SINGLE_ENDPOINT_VALIDATION_CSV"
    if [ "$SINGLE_ENDPOINT_VALIDATE_ONLY" = "1" ]; then
        log "single-endpoint validation-only requested; exiting before fuzzing"
        exit 0
    fi
    log "resetting platform coverage after login/endpoint validation"
    reset_platform_coverage
    if ! curl -fsS --max-time 10 -o /dev/null "$TARGET_URL"; then
        log "ERROR: app stopped responding after platform-coverage reset"
        dc logs --tail=120 "$SERVICE"
        exit 1
    fi
fi

sample_coverage() {
    local out consumed cum coverage_status parsed compact_out parsed_covered parsed_total parsed_pct
    [ "${PLATFORM_COVERAGE_SAMPLE:-1}" = "1" ] || return
    if [ "$COMPOSE_MODE" = "php" ]; then
        [ -z "$META_FILE" ] && return
        out="$( "${DOCKER[@]}" run --rm \
                    -e TRACELIB_INSTR_META=/m -e TRACELIB_INSTR_DIR=/instr \
                    -e TRACELIB_INSTR_DELETE_MAPS="$([ -n "$FEEDBACK_CAPTURE_DIR" ] && echo 0 || echo 1)" \
                    -v "$META_FILE":/m:ro \
                    -v "$INSTR_HOST_DIR":/instr \
                    -v "$COVERAGE_COMPACT":/oracle.php:ro \
                    "$PHP_CLI_IMAGE" php /oracle.php 2>/dev/null || true )"
        consumed="$(echo "$out" | sed -nE 's/.*consumed=([0-9]+).*/\1/p' | head -n1)"
        cum=$(cat "$TMPRUN/cum_consumed" 2>/dev/null || echo 0)
        [ -n "$consumed" ] && cum=$(( cum + consumed ))
        echo "$cum" > "$TMPRUN/cum_consumed"
        echo "$out" | sed -nE 's/.* ([0-9]+) \/ ([0-9]+) edges covered \(([0-9.]+)%\).*/\1 \2 \3/p' | head -n1
        return
    fi
    if [ "${PLATFORM_COVERAGE_FINAL_ONLY:-0}" = "1" ] && [ "${FINAL_COVERAGE_SAMPLE:-0}" != "1" ]; then
        return
    fi
    coverage_status=0
    case "$RUNTIME" in
        go|ruby)
            if [ "$RUNTIME" = "ruby" ]; then
                :
            else
                container_exec sh -c 'kill -USR1 1 2>/dev/null || true' >/dev/null 2>&1 || true
            fi
            out="$(container_exec sh -lc "timeout --kill-after=3s ${COVERAGE_SAMPLE_TIMEOUT}s sh /tracelib-support/coverage_report.sh" 2>&1)" || coverage_status=$? ;;
        python)
            out="$(container_exec sh -lc "timeout --kill-after=3s ${COVERAGE_SAMPLE_TIMEOUT}s python3 /tracelib-support/coverage_report.py" 2>&1)" || coverage_status=$? ;;
        node)
            if ! flush_node_coverage; then
                log "WARNING: Node coverage flush did not create a V8 snapshot app=$APP_NAME" >&2
            fi
            out="$(container_exec sh -lc "timeout --kill-after=3s ${COVERAGE_SAMPLE_TIMEOUT}s sh /tracelib-support/coverage_report.sh" 2>&1)" || coverage_status=$? ;;
        java)
            out="$(container_exec sh -lc "timeout --kill-after=3s ${COVERAGE_SAMPLE_TIMEOUT}s sh /tracelib-support/coverage_report.sh" 2>&1)" || coverage_status=$? ;;
        *) return ;;
    esac
    compact_out="$(printf '%s' "$out" | tr '\r\n' ' ' | cut -c1-500)"
    if [ "$coverage_status" -ne 0 ]; then
        log "WARNING: platform coverage report failed app=$APP_NAME runtime=$RUNTIME rc=$coverage_status timeout=${COVERAGE_SAMPLE_TIMEOUT}s output=${compact_out:-<none>}" >&2
        return 1
    fi
    parsed="$(printf '%s\n' "$out" | sed -nE 's/.* ([0-9]+) \/ ([0-9]+) lines covered \(([0-9.]+)%\).*/\1 \2 \3/p' | head -n1)"
    if [ -z "$parsed" ]; then
        log "WARNING: platform coverage report returned no parseable row app=$APP_NAME runtime=$RUNTIME output=${compact_out:-<none>}" >&2
        return 1
    fi
    read -r parsed_covered parsed_total parsed_pct <<< "$parsed"
    if [ "${parsed_total:-0}" -le 0 ] 2>/dev/null; then
        log "WARNING: platform coverage report returned zero total lines app=$APP_NAME runtime=$RUNTIME output=${compact_out:-<none>}" >&2
        return 1
    fi
    printf '%s\n' "$parsed"
}

T0="$(date +%s)"
FINAL_COVERAGE_SAMPLE=0
FINAL_COVERAGE_STATUS="not_applicable"
rm -f "$TMPRUN/fuzz_seen" "$TMPRUN/fuzz_start_elapsed" "$TMPRUN/cum_consumed" 2>/dev/null || true
emit_header() {
    [ -s "$CSV" ] && return
    echo "timestamp,elapsed_s,elapsed_h,host,app,runtime,mode,coverage_source,coverage_pct,coverage_covered,coverage_total,total_requests,throughput_rps,corpus_size,crawler_pending_urls,webfuzz_runtime_min,signal_files,phase,fuzz_requests,fuzz_started,fuzz_elapsed_s,crawl_reqs_at_fuzz_start,login_state,login_calls" > "$CSV"
}
sample_once() {
    local now elapsed elapsed_h ts tail_block req tp corpus pend rt nfiles
    local cov_triplet cov_covered cov_total cov_pct coverage_sample_status
    local fuzz_req fuzz_started crawl_at_fz phase fz_elapsed login_state login_calls
    now="$(date +%s)"; elapsed=$(( now - T0 ))
    elapsed_h=$(awk -v e="$elapsed" 'BEGIN{printf "%.4f", e/3600.0}')
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    req=""; tp=""; corpus=""; pend=""; rt=""; login_state=""; login_calls=""
    fuzz_req="0"; fuzz_started="no"; crawl_at_fz=""
    if [ -s "$WEBFUZZ_LOG" ]; then
        tail_block="$(tail -n 80 "$WEBFUZZ_LOG" 2>/dev/null)"
        req=$(echo    "$tail_block" | awk '/^Total Requests:/        { v=$3 } END{print v}')
        tp=$(echo     "$tail_block" | awk '/^Throughput:/           { v=$2 } END{print v}')
        corpus=$(echo "$tail_block" | awk '/^Corpus size:/          { v=$3 } END{print v}')
        pend=$(echo   "$tail_block" | awk '/^Crawler Pending URLs:/ { v=$4 } END{print v}')
        rt=$(echo     "$tail_block" | awk '/^Runtime:/              { v=$2 } END{print v}')
        fuzz_req=$(echo "$tail_block" | awk '/^Fuzz Requests:/      { v=$3 } END{print v}')
        fuzz_started=$(echo "$tail_block" | awk '/^Fuzz Started:/   { v=$3 } END{print v}')
        crawl_at_fz=$(echo "$tail_block" | awk '/^Crawl Requests At Fuzz Start:/ { v=$6 } END{print v}')
        login_state=$(echo "$tail_block" | awk '/^Crawler Login State:/ { v=$4 } END{print v}')
        login_calls=$(echo "$tail_block" | awk '/^Login Calls:/ { v=$3 } END{print v}')
    fi
    [ -z "$fuzz_req" ] && fuzz_req="0"
    [ -z "$fuzz_started" ] && fuzz_started="no"
    [ -z "$login_state" ] && login_state="unknown"
    [ -z "$login_calls" ] && login_calls="0"
    if [ "$fuzz_started" = "yes" ] || [ "${fuzz_req:-0}" -gt 0 ] 2>/dev/null; then
        phase="fuzz"
    else
        phase="crawl"
    fi

    cov_covered=""; cov_total=""; cov_pct=""
    coverage_sample_status=0
    cov_triplet="$(sample_coverage)" || coverage_sample_status=$?
    if [ -n "$cov_triplet" ]; then
        set -- $cov_triplet
        cov_covered="${1:-}"; cov_total="${2:-}"; cov_pct="${3:-}"
    fi
    if [ "${FINAL_COVERAGE_SAMPLE:-0}" = "1" ] \
       && [ "$COMPOSE_MODE" = "nonphp" ] \
       && [ "${PLATFORM_COVERAGE_SAMPLE:-1}" = "1" ]; then
        if [ "$coverage_sample_status" -eq 0 ] && [ -n "$cov_pct" ] && [ "${cov_total:-0}" -gt 0 ] 2>/dev/null; then
            FINAL_COVERAGE_STATUS="ok"
        else
            FINAL_COVERAGE_STATUS="failed"
        fi
    fi
    [ -n "$cov_pct" ] && { printf '%s\n' "$cov_pct" > "$EXT_COV_FILE.tmp" && mv -f "$EXT_COV_FILE.tmp" "$EXT_COV_FILE"; }

    if [ -n "${FEEDBACK_CAPTURE_DIR:-}" ]; then
        find "$BITMAP_DIR" -maxdepth 1 -name 'wf-*' -type f -mmin +5 -print0 2>/dev/null \
            | while IFS= read -r -d '' _bitmap; do
                _rid="$(basename "$_bitmap")"
                _dest="$FEEDBACK_CAPTURE_DIR/tracelib/$_rid"
                if [ -f "$_dest" ] \
                   && [ "$(stat -c %s "$_dest" 2>/dev/null || echo 0)" -ge 65536 ]; then
                    rm -f -- "$_bitmap"
                fi
            done
    else
        find "$BITMAP_DIR" -maxdepth 1 -name 'wf-*' -type f -mmin +5 -delete 2>/dev/null || true
    fi

    fz_elapsed=""
    if [ "$phase" = "fuzz" ] && [ ! -f "$TMPRUN/fuzz_seen" ]; then
        echo "$elapsed" > "$TMPRUN/fuzz_start_elapsed"
        : > "$TMPRUN/fuzz_seen"
        {
            echo "fuzz_start_iso=$ts"
            echo "campaign_elapsed_s_at_fuzz_start=$elapsed"
            echo "coverage_pct_at_fuzz_start=${cov_pct:-}"
            echo "coverage_covered_at_fuzz_start=${cov_covered:-}"
            echo "fuzz_requests_at_this_sample=${fuzz_req:-0}"
            echo "crawl_requests_at_fuzz_start=${crawl_at_fz:-}"
            echo "total_requests_at_this_sample=${req:-}"
        } > "$FUZZSTART_FILE"
        log "FUZZING STARTED at elapsed=${elapsed}s: crawl_reqs=${crawl_at_fz:-?} coverage=${cov_pct:-?}% (baseline at fuzz_requests=${fuzz_req:-0})"
    fi
    if [ -f "$TMPRUN/fuzz_seen" ]; then
        local fse; fse=$(cat "$TMPRUN/fuzz_start_elapsed" 2>/dev/null || echo "$elapsed")
        fz_elapsed=$(( elapsed - fse ))
    fi

    nfiles=$(cat "$TMPRUN/cum_consumed" 2>/dev/null || echo 0)

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$ts" "$elapsed" "$elapsed_h" "$HOST_NAME" "$APP_NAME" "$RUNTIME" "$MODE" \
        "$COVERAGE_SOURCE" "${cov_pct:-}" "${cov_covered:-}" "${cov_total:-}" \
        "${req:-}" "${tp:-}" "${corpus:-}" "${pend:-}" "${rt:-}" "$nfiles" \
        "$phase" "${fuzz_req:-0}" "$fuzz_started" "${fz_elapsed:-}" "${crawl_at_fz:-}" \
        "${login_state:-unknown}" "${login_calls:-0}" >> "$CSV"
}
emit_header
(
    trap 'exit 0' INT TERM
    last_sample=0
    while :; do
        now=$(date +%s)
        started=$(tail -n 80 "$WEBFUZZ_LOG" 2>/dev/null | awk '/^Fuzz Started:/{v=$3} END{print v}')
        eff="$INTERVAL"; [ -f "$TMPRUN/fuzz_seen" ] && eff="$FUZZ_INTERVAL"
        if { [ "$started" = "yes" ] && [ ! -f "$TMPRUN/fuzz_seen" ]; } \
           || [ $(( now - last_sample )) -ge "$eff" ]; then
            sample_once
            last_sample=$now
        fi
        sleep "$STATS_POLL_INTERVAL"
    done
) &
STATS_PID=$!
log "stats loop started (pid $STATS_PID): crawl every ${INTERVAL}s, fuzz every ${FUZZ_INTERVAL}s, poll every ${STATS_POLL_INTERVAL}s"
start_feedback_sync_loop

if [ "$SINGLE_ENDPOINT_MODE" = "1" ]; then
    WF_SCRIPT="$ROOT/single_endpoint_campaign/run.py"
    if [ "$SINGLE_ENDPOINT_BLEND" = "1" ]; then
        SINGLE_ENDPOINT_SCHEDULE="blend"
    else
        SINGLE_ENDPOINT_SCHEDULE="sequential"
    fi
    WF_ARGS=(
        --feedback_mode "$WF_MODE"
        -w 1
        -r simple
        -vv
        --fuzz_request_budget "$FUZZ_REQUEST_BUDGET"
        --endpoint_time_budget "$SINGLE_ENDPOINT_TIME_BUDGET"
        --endpoint_schedule "$SINGLE_ENDPOINT_SCHEDULE"
        --endpoint_file "$SINGLE_ENDPOINT_FILE"
        --blackbox-corpus-mode "$BLACKBOX_CORPUS_MODE"
    )
    if [ -n "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE" ]; then
        WF_ARGS+=( --request-record-file "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE" )
    elif [ -n "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" ]; then
        WF_ARGS+=( --request-replay-file "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" )
    fi
    if [ -s "$SINGLE_ENDPOINT_COOKIE_FILE" ]; then
        WF_ARGS+=( --cookies_file "$SINGLE_ENDPOINT_COOKIE_FILE" )
    fi
else
    WF_SCRIPT="$ROOT/webfuzz/webFuzz.py"
    WF_ARGS=( --feedback_mode "$WF_MODE" -w 1 -r simple -vv --fuzz_request_budget "$FUZZ_REQUEST_BUDGET" )
    if [ "${CRAWLER_PER_BASE_LIMIT:-0}" -gt 0 ] 2>/dev/null; then
        WF_ARGS+=( --crawler_per_base_limit "$CRAWLER_PER_BASE_LIMIT" )
    fi
    if [ -n "$WEBFUZZ_SEED_FILE" ]; then
        WF_ARGS+=( --seed_file "$WEBFUZZ_SEED_FILE" )
    fi
fi
if [ "${MAX_CORPUS_SIZE:-0}" -gt 0 ] 2>/dev/null; then
    WF_ARGS+=( --max_corpus_size "$MAX_CORPUS_SIZE" )
fi
if [ "${ALLOW_NON_HTML:-0}" = "1" ] || [ "$APP_SEEDS_NEED_NON_HTML" = "1" ]; then
    WF_ARGS+=( --allow_non_html )
fi
if [ "$WF_MODE" = "native" ]; then
    WF_ARGS+=( --meta_file "$META_FILE" )
elif [ "$WF_MODE" = "tracelib" ]; then
    WF_ARGS+=( --tracelib_bitmap_dir "$BITMAP_DIR" --tracelib_header X-REQUEST-ID )
    WF_ARGS+=( --tracelib_novelty "${TRACELIB_NOVELTY:-bucket}" )
fi
if [ -n "$AUTO_LOGIN_DIR" ] && [ "$SINGLE_ENDPOINT_DISABLE_SESSION_CHECKS" != "1" ]; then
    WF_ARGS+=( -s --auto_login_dir "$AUTO_LOGIN_DIR" --wut_name "$APP_NAME" )
    [ -n "$CATCH" ] && WF_ARGS+=( --catch_phrase "$CATCH" )
elif [ -n "$AUTO_LOGIN_DIR" ]; then
    log "periodic session checks disabled; using fresh validation cookies for identical-request timing"
fi
for _br in "${BLOCK_RULES[@]+"${BLOCK_RULES[@]}"}"; do
    WF_ARGS+=( --block "$_br" )
done
[ "${#BLOCK_RULES[@]}" -gt 0 ] && log "logout blocklist (all modes): ${BLOCK_RULES[*]}"
WEBFUZZ_USER_AGENT="${WEBFUZZ_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36}"

WF_CWD="$TMPRUN/wf"; mkdir -p "$WF_CWD/seeds" "$WF_CWD/log"; cd "$WF_CWD"
rm -f fuzzer.log
if [ "${MAX_SECONDS:-0}" -gt 0 ] 2>/dev/null; then
    RUNNER=( timeout --preserve-status "${MAX_SECONDS}s" )
    CAP_DESC="${MAX_SECONDS}s wall-clock cap"
else
    RUNNER=()
    CAP_DESC="no wall-clock cap (stop at fuzz budget / empty queue)"
fi
if [ "$SINGLE_ENDPOINT_MODE" = "1" ]; then
    WF_CMD=( "${RUNNER[@]}" "$VENV_PY" "$WF_SCRIPT" "${WF_ARGS[@]}" )
else
    WF_CMD=( "${RUNNER[@]}" "$VENV_PY" "$WF_SCRIPT" "${WF_ARGS[@]}" "$TARGET_URL" )
fi

if [ "$SINGLE_ENDPOINT_MODE" = "1" ]; then
    log "running single_endpoint_campaign: ${CAP_DESC}; cwd=$WF_CWD endpoints=$SINGLE_ENDPOINT_FILE schedule=$SINGLE_ENDPOINT_SCHEDULE catch_phrase=${CATCH:-<none>}"
else
    log "running webFuzz: ${CAP_DESC}; cwd=$WF_CWD crawl=$TARGET_URL catch_phrase=${CATCH:-<none>} per_base_limit=${CRAWLER_PER_BASE_LIMIT:-default}"
fi
WF_START=$(date +%s)
env -u PYTHONHOME -u PYTHONPATH \
    VIRTUAL_ENV="$VENV_DIR" \
    PATH="$VENV_DIR/bin:$PATH" \
    WEBFUZZ_INSTR_DIR="$INSTR_HOST_DIR" \
    WEBFUZZ_FEEDBACK_MANIFEST="${FEEDBACK_CAPTURE_DIR:+$FEEDBACK_CAPTURE_DIR/requests.jsonl}" \
    WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_RESET_CMD="$FEEDBACK_REFERENCE_RESET_CMD" \
    WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_CMD="$FEEDBACK_REFERENCE_CMD" \
    WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT="$WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT" \
    WEBFUZZ_FEEDBACK_HASH_FILE="$WEBFUZZ_FEEDBACK_HASH_FILE" \
    WEBFUZZ_FEEDBACK_TREATMENT_MODE="$WEBFUZZ_FEEDBACK_TREATMENT_MODE" \
    WEBFUZZ_TARGET_URL="$BASE_URL" \
    WEBFUZZ_USER_AGENT="$WEBFUZZ_USER_AGENT" \
    WEBFUZZ_EXTRA_HEADERS="$WEBFUZZ_EXTRA_HEADERS" \
    WEBFUZZ_EXTERNAL_COVERAGE_FILE="$EXT_COV_FILE" \
    WEBFUZZ_EXTERNAL_COVERAGE_LABEL="$COVERAGE_LABEL" \
    "${WF_CMD[@]}" 2>&1 | tee "$WEBFUZZ_LOG"
WF_RC=${PIPESTATUS[0]}
WF_END=$(date +%s)

if [ "$SINGLE_ENDPOINT_MODE" = "1" ]; then
    log "single_endpoint_campaign finished (rc=$WF_RC, wall=$((WF_END-WF_START))s); final sample"
else
    log "webFuzz finished (rc=$WF_RC, wall=$((WF_END-WF_START))s); final sample"
fi
kill "$STATS_PID" 2>/dev/null || true; STATS_PID=""
stop_feedback_sync_loop || true
FINAL_COVERAGE_SAMPLE=1
sample_once
FINAL_COVERAGE_SAMPLE=0

if [ -n "$FEEDBACK_CAPTURE_DIR" ]; then
    flush_id="fq-flush-${APP_NAME}-$(date +%s)"
    curl -sS --max-time 10 -o /dev/null -H "X-REQUEST-ID: $flush_id" "$TARGET_URL" 2>/dev/null || true
    sleep "$FEEDBACK_CAPTURE_SETTLE_SECONDS"
    copy_feedback_artifacts
fi

[ -f "$WF_CWD/fuzzer.log" ] && cp -fL "$WF_CWD/fuzzer.log" "$FUZZER_LOG_OUT" 2>/dev/null || true

REASON="unknown"
if [ "${MAX_SECONDS:-0}" -gt 0 ] 2>/dev/null; then
    TIME_CAP_FLOOR="$MAX_SECONDS"
    [ "$TIME_CAP_FLOOR" -gt 60 ] && TIME_CAP_FLOOR=$((MAX_SECONDS - 60))
fi
if [ "${MAX_SECONDS:-0}" -gt 0 ] 2>/dev/null && [ "$((WF_END-WF_START))" -ge "$TIME_CAP_FLOOR" ]; then
    REASON="max_time_cap"
elif grep -qa "Aborting due to lack of fuzz targets" "$FUZZER_LOG_OUT" 2>/dev/null; then
    REASON="empty_queue"
elif grep -qa "FUZZ REQUEST BUDGET reached" "$FUZZER_LOG_OUT" 2>/dev/null; then
    REASON="budget_reached"
elif [ "$SINGLE_ENDPOINT_MODE" = "1" ] \
     && { grep -qa "Completed endpoint ${SINGLE_ENDPOINT_COUNT}/${SINGLE_ENDPOINT_COUNT}" "$FUZZER_LOG_OUT" 2>/dev/null \
          || grep -qa "Completed endpoint ${SINGLE_ENDPOINT_COUNT}/${SINGLE_ENDPOINT_COUNT}" "$WEBFUZZ_LOG" 2>/dev/null; }; then
    REASON="endpoint_time_budget"
fi
FINAL_ROW="$(tail -1 "$CSV")"
{
    echo "stem=$STEM"
    if [ "$SINGLE_ENDPOINT_MODE" = "1" ]; then
        echo "app=$APP_NAME mode=$MODE webfuzz_mode=$WF_MODE schema=single-endpoint-time-budget"
        echo "single_endpoint_file=$SINGLE_ENDPOINT_FILE"
        echo "single_endpoint_count=$SINGLE_ENDPOINT_COUNT"
        echo "single_endpoint_time_budget=$SINGLE_ENDPOINT_TIME_BUDGET"
        echo "single_endpoint_schedule=$([ "$SINGLE_ENDPOINT_BLEND" = "1" ] && echo blend || echo sequential)"
        echo "blackbox_corpus_mode=$BLACKBOX_CORPUS_MODE"
        [ -n "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE" ] && echo "request_record_file=$SINGLE_ENDPOINT_REQUEST_RECORD_FILE"
        [ -n "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" ] && echo "request_replay_file=$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE"
        if [ -n "$SINGLE_ENDPOINT_REQUEST_RECORD_FILE" ] || [ -n "$SINGLE_ENDPOINT_REQUEST_REPLAY_FILE" ]; then
            echo "request_cookie_policy=fresh_per_treatment_validation_cookies"
            echo "periodic_session_checks=disabled"
        fi
        [ -n "$SINGLE_ENDPOINT_VALIDATION_CSV" ] && echo "single_endpoint_validation_csv=$SINGLE_ENDPOINT_VALIDATION_CSV"
    else
        echo "app=$APP_NAME mode=$MODE webfuzz_mode=$WF_MODE schema=time-budget"
    fi
    echo "max_corpus_size=$MAX_CORPUS_SIZE"
    echo "wut_image_profile=$EFFECTIVE_WUT_IMAGE_PROFILE"
    if [ "$EFFECTIVE_WUT_IMAGE_PROFILE" = "bare" ]; then
        echo "wut_source_instrumentation=none"
    else
        echo "wut_source_instrumentation=ast"
    fi
    echo "max_hours=$MAX_HOURS crawler_per_base_limit=$CRAWLER_PER_BASE_LIMIT"
    [ -n "$TL_FILTER_FILE" ] && echo "tracelib_syscall_filter_file=$TL_FILTER_FILE"
    [ -n "$TL_FILTER_FILE" ] && echo "tracelib_syscall_filter_sha256=$TL_FILTER_SHA256"
    echo "tracelib_file_sql_only=$TL_FILE_SQL_ONLY"
    echo "tracelib_file_sql_unfiltered=$TL_FILE_SQL_UNFILTERED"
    echo "tracelib_file_sql_filtered=$TL_FILE_SQL_FILTERED"
    echo "tracelib_bigram_file_sql_separated=$TL_BIGRAM_SEPARATED"
    echo "tracelib_separated_min_hits=$TL_SEPARATED_MIN_HITS"
    echo "tracelib_file_path_monitored=$TL_FILE_PATH_MONITORED"
    echo "tracelib_excluded_file_path=$TL_EXCLUDED_FILE_PATH"
    echo "tracelib_end_on_status_line=$TL_END_ON_STATUS_LINE"
    echo "tracelib_sql_compact=$TL_SQL_COMPACT"
    if [ "$TL_SQL_COMPACT" != "1" ]; then
        echo "tracelib_sql_encoding=reduced_or_skeleton"
    elif [ "$IS_EBPF" = "1" ] && { [ "$TL_COV_MODE" != "bigram" ] || [ "$TL_BIGRAM_SEPARATED" = "1" ]; }; then
        echo "tracelib_sql_encoding=in_kernel_fold"
    else
        echo "tracelib_sql_encoding=compact_commands_tables"
    fi
    echo "completion_reason=$REASON"
    if [ -s "$TMPRUN/coverage_sample_failures.log" ]; then
        echo "coverage_sample_failures=$(wc -l < "$TMPRUN/coverage_sample_failures.log" | tr -d ' ')"
        echo "coverage_sample_failure_example=$(head -n1 "$TMPRUN/coverage_sample_failures.log" | cut -c1-300)"
    else
        echo "coverage_sample_failures=0"
    fi
    echo "coverage_status=$FINAL_COVERAGE_STATUS"
    echo "webfuzz_rc=$WF_RC"
    echo "wall_seconds=$((WF_END-WF_START))"
    echo "final_csv_row=$FINAL_ROW"
    [ -f "$FUZZSTART_FILE" ] && { echo "--- fuzzstart ---"; cat "$FUZZSTART_FILE"; }
} > "$SUMMARY_FILE"
log "completion_reason=$REASON  summary=$SUMMARY_FILE"

if "$VENV_PY" - <<'PY' >/dev/null 2>&1
import matplotlib
if not callable(getattr(matplotlib, "use", None)):
    raise SystemExit(1)
PY
then
    "$VENV_PY" "$HERE/plot_campaign.py" "$CSV" "$RESULT_DIR" || log "plotting failed (CSV intact at $CSV)"
fi

log "done — stats: $CSV"
log "  fuzzstart: $FUZZSTART_FILE"
log "  summary:   $SUMMARY_FILE"
log "  fuzzer.log:$FUZZER_LOG_OUT"
if [ "$FINAL_COVERAGE_STATUS" = "failed" ]; then
    log "ERROR: final platform coverage collection failed; treating campaign cell as failed"
    exit 1
fi
if [ "$REASON" = "max_time_cap" ]; then
    log "treating max_time_cap as successful planned campaign completion (webfuzz_rc=$WF_RC)"
    exit 0
fi
exit "$WF_RC"
