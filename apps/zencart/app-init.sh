#!/bin/sh
set -u

DB_HOST="${ZENCART_DB_HOST:-db}"
DB_USER="${ZENCART_DB_USER:-user}"
DB_PASSWORD="${ZENCART_DB_PASSWORD:-password}"

echo "[zc-init] waiting for db at $DB_HOST"
for i in $(seq 1 60); do
    if mysqladmin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" --skip-ssl --silent 2>/dev/null; then
        echo "[zc-init] db reachable"
        break
    fi
    sleep 2
done

mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" db <<'SQL' \
    || echo "[zc-init] WARN: pwd_last_change_date refresh failed"
UPDATE admin SET pwd_last_change_date = NOW(), failed_logins = 0,
                 lockout_expires = 0, last_failed_attempt = '0001-01-01 00:00:00';
SQL
echo "[zc-init] admin password expiry reset"

for d in cache logs images media pub adminzcfuzz/backups adminzcfuzz/images; do
    [ -d "/var/www/html/$d" ] && chown -R www-data:www-data "/var/www/html/$d" 2>/dev/null || true
done
chmod 777 /coverage 2>/dev/null || true

echo "[zc-init] done"
