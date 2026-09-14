#!/bin/sh
set -u

DB_HOST="${DRUPAL_DB_HOST:-db}"
DB_USER="${DRUPAL_DB_USER:-user}"
DB_PASSWORD="${DRUPAL_DB_PASSWORD:-password}"

echo "[drupal-init] waiting for db at $DB_HOST"
for i in $(seq 1 60); do
    if mysqladmin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" --silent 2>/dev/null; then
        echo "[drupal-init] db reachable"
        break
    fi
    sleep 2
done

chown -R www-data:www-data /var/www/html/web/sites/default/files 2>/dev/null || true
chmod -R u+w /var/www/html/web/sites/default/files 2>/dev/null || true
chmod 777 /coverage 2>/dev/null || true

echo "[drupal-init] done"
