#!/bin/sh
set -eu

cd /var/www/html
mkdir -p conf

need_createdb=0
if [ ! -f conf/options.php ]; then
    need_createdb=1
elif ! mysql --protocol=tcp \
        -h "${HOTCRP_DB_HOST:-db}" \
        -u "${HOTCRP_DB_USER:-hotcrp}" \
        -p"${HOTCRP_DB_PASSWORD:-hotcrp}" \
        -e "SELECT 1" "${HOTCRP_DB_NAME:-hotcrp}" >/dev/null 2>&1; then
    echo "[hotcrp-start] dbuser cannot connect to ${HOTCRP_DB_NAME:-hotcrp}; rerunning createdb" >&2
    rm -f conf/options.php
    need_createdb=1
fi

if [ "$need_createdb" = "1" ]; then
    php batch/createdb.php --batch --quiet --replace --replace-user \
        --user="${HOTCRP_DB_ADMIN_USER:-root}" \
        --password="${HOTCRP_DB_ADMIN_PASSWORD:-}" \
        --name="${HOTCRP_DB_NAME:-hotcrp}" \
        --dbuser="${HOTCRP_DB_USER:-hotcrp},${HOTCRP_DB_PASSWORD:-hotcrp}" \
        --host="${HOTCRP_DB_HOST:-db}" \
        --grant-host=%
fi

php batch/saveusers.php --quiet \
    -u "${HOTCRP_ADMIN_EMAIL:-admin@example.com}" \
    --roles sysadmin \
    --user-name "${HOTCRP_ADMIN_NAME:-Admin}"

php /var/www/html/ensure-admin.php

exec php -S 0.0.0.0:8087 -t /var/www/html
