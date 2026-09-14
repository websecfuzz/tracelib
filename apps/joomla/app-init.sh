#!/bin/sh

set -u

ADMIN_USER="${JOOMLA_ADMIN_USER:-admin}"
ADMIN_PASS="${JOOMLA_ADMIN_PASSWORD:-admin12345678}"
ADMIN_EMAIL="${JOOMLA_ADMIN_EMAIL:-admin@example.com}"
DB_HOST="${JOOMLA_DB_HOST:-db}"
DB_NAME="${JOOMLA_DB_NAME:-joomla}"
DB_USER="${JOOMLA_DB_USER:-joomla}"
DB_PASSWORD="${JOOMLA_DB_PASSWORD:-joomla}"
DB_PREFIX="${JOOMLA_DB_PREFIX:-j_}"

if [ -f /var/www/html/configuration.php ]; then
    echo "Joomla already installed (configuration.php present)"
    exit 0
fi

for i in $(seq 1 60); do
    if php -r '$m=@new mysqli(getenv("JOOMLA_DB_HOST"),getenv("JOOMLA_DB_USER"),getenv("JOOMLA_DB_PASSWORD"),getenv("JOOMLA_DB_NAME")); exit($m && !$m->connect_error ? 0 : 1);' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

cd /var/www/html

SCHEMA_DIR=installation/sql/mysql
if [ ! -f "$SCHEMA_DIR/base.sql" ]; then
    echo "WARNING: $SCHEMA_DIR/base.sql missing — Joomla layout may have changed"
    exit 0
fi

import_sql() {
    local file="$1"
    sed "s/#__/${DB_PREFIX}/g" "$file" | \
        mysql --protocol=tcp -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME"
}

import_sql "$SCHEMA_DIR/base.sql"
[ -f "$SCHEMA_DIR/data.sql" ] && import_sql "$SCHEMA_DIR/data.sql"
[ -f "$SCHEMA_DIR/extensions.sql" ] && import_sql "$SCHEMA_DIR/extensions.sql"
[ -f "$SCHEMA_DIR/supports.sql" ] && import_sql "$SCHEMA_DIR/supports.sql"
[ -f "$SCHEMA_DIR/localise.sql" ] && import_sql "$SCHEMA_DIR/localise.sql"

PASSWORD_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$ADMIN_PASS")
mysql --protocol=tcp -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" <<SQL
INSERT INTO ${DB_PREFIX}users (name, username, email, password, block, sendEmail, registerDate, lastvisitDate, params)
VALUES ('Admin', '${ADMIN_USER}', '${ADMIN_EMAIL}', '${PASSWORD_HASH}', 0, 1, NOW(), NOW(), '{}');
SET @uid := LAST_INSERT_ID();
INSERT INTO ${DB_PREFIX}user_usergroup_map (user_id, group_id) VALUES (@uid, 8);
SQL

SECRET=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > /var/www/html/configuration.php <<EOF
<?php
class JConfig {
    public \$offline = '0';
    public \$offline_message = '';
    public \$display_offline_message = '1';
    public \$offline_image = '';
    public \$sitename = 'TraceLib Joomla';
    public \$editor = 'tinymce';
    public \$captcha = '0';
    public \$list_limit = '20';
    public \$access = '1';
    public \$debug = '0';
    public \$debug_lang = '0';
    public \$debug_lang_const = '1';
    public \$dbtype = 'mysqli';
    public \$host = '${DB_HOST}';
    public \$user = '${DB_USER}';
    public \$password = '${DB_PASSWORD}';
    public \$db = '${DB_NAME}';
    public \$dbprefix = '${DB_PREFIX}';
    public \$dbencryption = '0';
    public \$dbsslca = '';
    public \$dbsslkey = '';
    public \$dbsslcert = '';
    public \$dbsslverifyservercert = '0';
    public \$force_ssl = '0';
    public \$live_site = '';
    public \$secret = '${SECRET}';
    public \$gzip = '0';
    public \$error_reporting = 'default';
    public \$helpurl = 'https://help.joomla.org/proxy?keyref=Help{major}{minor}:{keyref}&lang={langcode}';
    public \$offset = 'UTC';
    public \$mailonline = '1';
    public \$mailer = 'mail';
    public \$mailfrom = '${ADMIN_EMAIL}';
    public \$fromname = 'Joomla';
    public \$sendmail = '/usr/sbin/sendmail';
    public \$smtpauth = '0';
    public \$smtpuser = '';
    public \$smtppass = '';
    public \$smtphost = 'localhost';
    public \$smtpsecure = 'none';
    public \$smtpport = '25';
    public \$caching = '0';
    public \$cache_handler = 'file';
    public \$cachetime = '15';
    public \$cache_platformprefix = '0';
    public \$MetaDesc = '';
    public \$MetaAuthor = '1';
    public \$MetaVersion = '0';
    public \$robots = '';
    public \$sef = '1';
    public \$sef_rewrite = '0';
    public \$sef_suffix = '0';
    public \$unicodeslugs = '0';
    public \$feed_limit = '10';
    public \$feed_email = 'none';
    public \$log_path = '/var/log';
    public \$tmp_path = '/tmp';
    public \$lifetime = '15';
    public \$session_handler = 'database';
    public \$shared_session = '0';
    public \$session_metadata = '1';
}
EOF

chown www-data:www-data /var/www/html/configuration.php

rm -rf /var/www/html/installation

echo "Joomla install OK"
