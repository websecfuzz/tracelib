#!/bin/sh
set -eu

WORK=/data/gogs
APPINI=$WORK/conf/app.ini
mkdir -p "$WORK/conf" "$WORK/log" "$WORK/data" /data/repos

DB_HOST="${GOGS_DB_HOST:-db}"
DB_PORT="${GOGS_DB_PORT:-3306}"
DB_NAME="${GOGS_DB_NAME:-gogs}"
DB_USER="${GOGS_DB_USER:-gogs}"
DB_PASS="${GOGS_DB_PASSWORD:-gogs}"
WAIT_FOR_DB="${WAIT_FOR_DB:-1}"

if [ "$WAIT_FOR_DB" = "1" ]; then
    echo "[gogs-start] waiting for mysql at ${DB_HOST}:${DB_PORT}"
    until mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; do
        sleep 1
    done
fi

if [ ! -f "$APPINI" ]; then
    cat > "$APPINI" <<INI
BRAND_NAME = Gogs
RUN_USER = root
RUN_MODE = prod

[server]
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 8091
DOMAIN = localhost
EXTERNAL_URL = http://localhost:8091/
APP_DATA_PATH = $WORK/data
DISABLE_SSH = true
START_SSH_SERVER = false
OFFLINE_MODE = true
ENABLE_GZIP = false

[database]
TYPE = mysql
HOST = ${DB_HOST}:${DB_PORT}
NAME = ${DB_NAME}
USER = ${DB_USER}
PASSWORD = ${DB_PASS}
SSL_MODE = disable

[repository]
ROOT = /data/repos

[security]
INSTALL_LOCK = true
SECRET_KEY = tracelib-secret-key-not-for-prod

[auth]
REQUIRE_EMAIL_CONFIRMATION = false
DISABLE_REGISTRATION = false
ENABLE_REGISTRATION_CAPTCHA = false

[session]
PROVIDER = memory

[log]
ROOT_PATH = $WORK/log
LEVEL = Warn

[other]
SHOW_FOOTER_VERSION = false
INI
fi

chmod -R 777 /data /coverage 2>/dev/null || true

exec gogs web -c "$APPINI"
