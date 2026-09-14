#!/bin/bash
set -u

if ! command -v wp >/dev/null 2>&1; then
    echo "wp-cli not installed; skipping"
    exit 0
fi

for i in $(seq 1 60); do
    if wp --allow-root --path=/var/www/html core is-installed 2>/dev/null; then
        echo "WordPress already installed"
        exit 0
    fi
    if wp --allow-root --path=/var/www/html core install \
        --url="http://localhost:8081/" \
        --title="TraceLib Test" \
        --admin_user=admin \
        --admin_password=admin \
        --admin_email=admin@example.com \
        --skip-email 2>/dev/null; then
        echo "WordPress installed successfully on attempt $i"
        exit 0
    fi
    sleep 2
done

echo "wp-cli install failed after 60 attempts (continuing)"
