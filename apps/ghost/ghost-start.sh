#!/bin/bash
set -u

DB_HOST="${database__connection__host:-db}"
DB_USER="${database__connection__user:-ghost}"
DB_PASS="${database__connection__password:-ghost}"
DB_NAME="${database__connection__database:-ghost}"
WAIT_FOR_DB="${WAIT_FOR_DB:-1}"

if [ "$WAIT_FOR_DB" = "1" ]; then
    echo "[ghost-start] waiting for mysql at ${DB_HOST}:3306"
    until mysqladmin ping -h "$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; do
        sleep 1
    done
fi

echo "[ghost-start] clearing stale migration locks (if any)"
mysql -h "$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "UPDATE migrations_lock SET locked = 0 WHERE locked = 1;" >/dev/null 2>&1 || true
mysql -h "$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "UPDATE knex_migrations_lock SET is_locked = 0 WHERE is_locked = 1;" >/dev/null 2>&1 || true

mkdir -p \
    /var/lib/ghost/content/logs \
    /var/lib/ghost/content/themes \
    /var/lib/ghost/content/adapters \
    /var/lib/ghost/content/data \
    /var/lib/ghost/content/images \
    /var/lib/ghost/content/media

if [ ! -d /var/lib/ghost/content/themes/source ] || [ ! -d /var/lib/ghost/content/themes/casper ]; then
    cp -a /var/lib/ghost/current/content/themes/. /var/lib/ghost/content/themes/ 2>/dev/null || true
fi

rm -f /coverage/v8/*.json 2>/dev/null || true

exec node current/index.js