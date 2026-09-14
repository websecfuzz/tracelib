#!/bin/bash
set -u

DB_HOST="${PETCLINIC_DB_HOST:-db}"
DB_PORT="${PETCLINIC_DB_PORT:-3306}"
DB_NAME="${PETCLINIC_DB_NAME:-petclinic}"
DB_USER="${PETCLINIC_DB_USER:-petclinic}"
DB_PASS="${PETCLINIC_DB_PASSWORD:-petclinic}"
WAIT_FOR_DB="${WAIT_FOR_DB:-1}"
PORT="${TRACELIB_PORT:-8098}"

DB_SSL_MODE="${DB_SSL_MODE:-DISABLED}"

if [ "$WAIT_FOR_DB" = "1" ]; then
    echo "[petclinic-start] waiting for mysql at ${DB_HOST}:${DB_PORT}"
    until mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; do
        sleep 1
    done
fi

exec java ${JACOCO_AGENT_OPTS:-} \
    -jar /app/petclinic.jar \
    --spring.profiles.active=mysql \
    --server.port="${PORT}" \
    --spring.datasource.url="jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?sslMode=${DB_SSL_MODE}" \
    --spring.datasource.username="${DB_USER}" \
    --spring.datasource.password="${DB_PASS}"
