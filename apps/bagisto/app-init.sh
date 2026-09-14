#!/bin/sh
set -u

cd /var/www/bagisto

ADMIN_NAME="${BAGISTO_ADMIN_NAME:-Admin}"
ADMIN_EMAIL="${BAGISTO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASS="${BAGISTO_ADMIN_PASSWORD:-admin123}"
DB_HOST="${BAGISTO_DB_HOST:-db}"
DB_NAME="${BAGISTO_DB_NAME:-bagisto}"
DB_USER="${BAGISTO_DB_USER:-bagisto}"
DB_PASSWORD="${BAGISTO_DB_PASSWORD:-bagisto}"

if [ -f /var/www/bagisto/.installed ]; then
    echo "Bagisto already installed (.installed marker present)"
    exit 0
fi

for i in $(seq 1 60); do
    if php -r '$m=@new mysqli(getenv("BAGISTO_DB_HOST"),getenv("BAGISTO_DB_USER"),getenv("BAGISTO_DB_PASSWORD"),getenv("BAGISTO_DB_NAME")); exit($m && !$m->connect_error ? 0 : 1);' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if [ ! -f .env ]; then cp .env.example .env; fi
sed -i \
    -e "s|^APP_URL=.*|APP_URL=http://localhost:8093|" \
    -e "s|^DB_HOST=.*|DB_HOST=${DB_HOST}|" \
    -e "s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" \
    -e "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" \
    -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" \
    .env

php artisan key:generate --force 2>&1 | sed 's/^/[bagisto] /'
printf '%s\n%s\n%s\n%s\nyes\n' \
    "$ADMIN_NAME" "$ADMIN_EMAIL" "$ADMIN_PASS" "$ADMIN_PASS" | \
    php artisan bagisto:install --skip-env-check 2>&1 | sed 's/^/[bagisto] /' \
    || echo "bagisto:install returned nonzero (continuing)"

touch .installed
chown -R www-data:www-data storage bootstrap/cache .installed
