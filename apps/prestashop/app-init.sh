#!/bin/sh
set -u

DB_HOST="${PRESTASHOP_DB_HOST:-db}"
DB_USER="${PRESTASHOP_DB_USER:-user}"
DB_PASSWORD="${PRESTASHOP_DB_PASSWORD:-password}"

echo "[ps-init] waiting for db at $DB_HOST"
for i in $(seq 1 60); do
    if mysqladmin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" --skip-ssl --silent 2>/dev/null; then
        echo "[ps-init] db reachable"
        break
    fi
    sleep 2
done

WWW_OWNER="$(id -u www-data):$(id -g www-data)"
for d in var img upload modules themes cache; do
    path="/var/www/html/$d"
    [ -d "$path" ] || continue
    [ "$(stat -c '%u:%g' "$path" 2>/dev/null || echo unknown)" = "$WWW_OWNER" ] \
        || chown -R www-data:www-data "$path" 2>/dev/null \
        || true
done
chmod 777 /coverage 2>/dev/null || true

echo "[ps-init] done"
