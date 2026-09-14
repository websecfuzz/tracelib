#!/bin/bash
set -u

DB_HOST="${HUGINN_DATABASE_HOST:-db}"
DB_PORT="${HUGINN_DATABASE_PORT:-3306}"
DB_USER="${HUGINN_DATABASE_USERNAME:-huginn}"
DB_PASS="${HUGINN_DATABASE_PASSWORD:-huginn}"
WAIT_FOR_DB="${WAIT_FOR_DB:-1}"

if [ "$WAIT_FOR_DB" = "1" ]; then
    echo "[huginn-start] waiting for mysql at ${DB_HOST}:${DB_PORT}"
    until mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; do
        sleep 1
    done
fi

rm -f /app/tmp/pids/puma.pid /app/tmp/pids/delayed_job.pid 2>/dev/null || true

export DATABASE_SSL_MODE="${DB_SSL_MODE:-disabled}"
DB_YML=/app/config/database.yml
if [ -f "$DB_YML" ] && ! grep -q '^  ssl_mode:' "$DB_YML"; then
    awk '
        { print }
        /^(development|test|production):[[:space:]]*$/ {
            print "  ssl_mode: <%= ENV[\"DATABASE_SSL_MODE\"].presence || \"disabled\" %>"
        }
    ' "$DB_YML" > "$DB_YML.tracelib" && mv "$DB_YML.tracelib" "$DB_YML"
    echo "[huginn-start] database.yml: ssl_mode=${DATABASE_SSL_MODE} (TraceLib SQL channel)"
else
    echo "[huginn-start] database.yml already carries ssl_mode; leaving it alone"
fi

export HOME=/app
cd /app

exec /scripts/init
