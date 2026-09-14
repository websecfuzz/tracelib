#!/bin/bash
set -u

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-wiki}"
DB_PASS="${DB_PASS:-wiki}"
DB_NAME="${DB_NAME:-wiki}"
WAIT_FOR_DB="${WAIT_FOR_DB:-1}"

SETUP_PORT="${WIKIJS_SETUP_PORT:-3999}"
ADMIN_EMAIL="${WIKIJS_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${WIKIJS_ADMIN_PASSWORD:-admin123456}"
SITE_URL="${WIKIJS_SITE_URL:-http://localhost:8097}"

mysql_args=( -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" --skip-ssl )

if [ "$WAIT_FOR_DB" = "1" ]; then
    echo "[wikijs-start] waiting for mysql at ${DB_HOST}:${DB_PORT}"
    until mysqladmin "${mysql_args[@]}" ping --silent >/dev/null 2>&1; do
        sleep 1
    done
fi

user_count="$(mysql "${mysql_args[@]}" -N -B -e "SELECT COUNT(*) FROM users" "$DB_NAME" 2>/dev/null || echo 0)"
case "$user_count" in ''|*[!0-9]*) user_count=0 ;; esac

if [ "$user_count" -eq 0 ]; then
    echo "[wikijs-start] empty database — running the setup wizard on :${SETUP_PORT}"
    sed "s/^port: .*/port: ${SETUP_PORT}/" /wiki/config.yml > /tmp/wiki-setup.yml

    cd /wiki
    CONFIG_FILE=/tmp/wiki-setup.yml node --no-deprecation server &
    setup_pid=$!

    setup_base="http://127.0.0.1:${SETUP_PORT}"
    for _ in $(seq 1 120); do
        curl -fsS -o /dev/null "${setup_base}/" 2>/dev/null && break
        kill -0 "$setup_pid" 2>/dev/null || break
        sleep 1
    done

    echo "[wikijs-start] finalizing setup"
    curl -sS -X POST "${setup_base}/finalize" \
        -H 'Content-Type: application/json' \
        -d "{\"adminEmail\":\"${ADMIN_EMAIL}\",\"adminPassword\":\"${ADMIN_PASSWORD}\",\"adminPasswordConfirm\":\"${ADMIN_PASSWORD}\",\"siteUrl\":\"${SITE_URL}\",\"telemetry\":false}" \
        2>&1 | head -c 200 | sed 's/^/[wikijs-start] /'
    echo

    for _ in $(seq 1 120); do
        if curl -fsS -o /dev/null -X POST "${setup_base}/graphql" \
            -H 'Content-Type: application/json' \
            -d '{"query":"{ site { config { host } } }"}' 2>/dev/null; then
            echo "[wikijs-start] setup complete"
            break
        fi
        sleep 1
    done

    kill "$setup_pid" 2>/dev/null || true
    wait "$setup_pid" 2>/dev/null || true
    sleep 2
else
    echo "[wikijs-start] database already configured (${user_count} user rows)"
fi

rm -f /coverage/v8/*.json 2>/dev/null || true

cd /wiki
exec node --no-deprecation server
