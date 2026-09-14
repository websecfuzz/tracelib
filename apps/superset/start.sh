#!/bin/bash
set -u

DB_HOST="${SUPERSET_DB_HOST:-db}"
DB_PORT="${SUPERSET_DB_PORT:-3306}"
DB_USER="${SUPERSET_DB_USER:-superset}"
DB_PASS="${SUPERSET_DB_PASSWORD:-superset}"
WAIT_FOR_DB="${WAIT_FOR_DB:-1}"

ADMIN_USER="${SUPERSET_ADMIN_USER:-admin}"
ADMIN_PASS="${SUPERSET_ADMIN_PASSWORD:-admin123}"
ADMIN_EMAIL="${SUPERSET_ADMIN_EMAIL:-admin@example.com}"
PORT="${TRACELIB_PORT:-8096}"
WORKERS="${SUPERSET_WORKERS:-2}"
WSGI_MODULE="${SUPERSET_WSGI_MODULE:-wsgi_cov:application}"

if [ "$WAIT_FOR_DB" = "1" ]; then
    echo "[superset-start] waiting for mysql at ${DB_HOST}:${DB_PORT}"
    until mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; do
        sleep 1
    done
fi

echo "[superset-start] applying metadata database migrations"
superset db upgrade 2>&1 | sed 's/^/[superset-start] /'

echo "[superset-start] ensuring admin account"
superset fab create-admin \
    --username "$ADMIN_USER" \
    --firstname Fuzz \
    --lastname Admin \
    --email "$ADMIN_EMAIL" \
    --password "$ADMIN_PASS" 2>&1 | sed 's/^/[superset-start] /' || true

echo "[superset-start] initialising roles and permissions"
superset init 2>&1 | sed 's/^/[superset-start] /'

export TRACELIB_COVERAGE=1
exec gunicorn \
    --bind "0.0.0.0:${PORT}" \
    --workers "$WORKERS" \
    --timeout 120 \
    --access-logfile - \
    "$WSGI_MODULE"
