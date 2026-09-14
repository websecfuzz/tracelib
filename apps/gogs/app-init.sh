#!/bin/sh
set -u

APPINI=/data/gogs/conf/app.ini

gogs admin create-user \
    --config "$APPINI" \
    --name "${GOGS_ADMIN_USER:-gogsadmin}" \
    --password "${GOGS_ADMIN_PASSWORD:-admin123}" \
    --email "${GOGS_ADMIN_EMAIL:-admin@example.com}" \
    --admin 2>&1 | sed 's/^/[gogs-init] /' || true
