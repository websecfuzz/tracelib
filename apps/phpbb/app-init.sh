#!/bin/sh

set -u

if [ -f /var/www/html/config.php ] && grep -q dbms /var/www/html/config.php; then
    echo "phpBB already installed (config.php present)"
    exit 0
fi

rm -f /var/www/html/config.php

ADMIN_USER="${PHPBB_ADMIN_USER:-admin}"
ADMIN_PASS="${PHPBB_ADMIN_PASSWORD:-admin12345678}"
ADMIN_EMAIL="${PHPBB_ADMIN_EMAIL:-admin@example.com}"
DB_HOST="${PHPBB_DB_HOST:-db}"
DB_NAME="${PHPBB_DB_NAME:-phpbb}"
DB_USER="${PHPBB_DB_USER:-phpbb}"
DB_PASSWORD="${PHPBB_DB_PASSWORD:-phpbb}"

cd /var/www/html

for i in $(seq 1 60); do
    if php -r '$m=@new mysqli(getenv("PHPBB_DB_HOST"),getenv("PHPBB_DB_USER"),getenv("PHPBB_DB_PASSWORD"),getenv("PHPBB_DB_NAME")); exit($m && !$m->connect_error ? 0 : 1);' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

cat > /tmp/phpbb-install.yml <<EOF
installer:
    admin:
        name: ${ADMIN_USER}
        password: ${ADMIN_PASS}
        email: ${ADMIN_EMAIL}
    board:
        lang: en
        name: TraceLib phpBB
        description: Fuzz target
    database:
        dbms: mysqli
        dbhost: ${DB_HOST}
        dbport: ''
        dbuser: ${DB_USER}
        dbpasswd: ${DB_PASSWORD}
        dbname: ${DB_NAME}
        table_prefix: phpbb_
    email:
        enabled: false
        smtp_delivery: false
        smtp_host: ''
        smtp_auth: ''
        smtp_user: ''
        smtp_pass: ''
    server:
        cookie_secure: false
        server_protocol: 'http://'
        force_server_vars: true
        server_name: localhost
        server_port: 8089
        script_path: /
    extensions: []
EOF

chown -R www-data:www-data /var/www/html/cache /var/www/html/store /var/www/html/files /var/www/html/images/avatars /var/www/html 2>/dev/null || true
chmod -R u+w /var/www/html/cache /var/www/html/store /var/www/html/files 2>/dev/null || true

runuser -u www-data -- php /var/www/html/install/phpbbcli.php install /tmp/phpbb-install.yml 2>&1 \
    | sed 's/^/[phpbbcli] /' \
    || echo "phpbbcli returned nonzero (continuing)"

[ -d /var/www/html/install ] && mv /var/www/html/install /var/www/html/install.disabled

if [ -f /var/www/html/config.php ]; then
    echo "phpBB install OK"
else
    echo "WARNING: phpBB config.php missing — install likely failed"
fi
