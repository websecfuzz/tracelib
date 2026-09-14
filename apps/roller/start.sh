#!/bin/bash
set -u

DB_HOST="${ROLLER_DB_HOST:-db}"
DB_PORT="${ROLLER_DB_PORT:-3306}"
DB_USER="${ROLLER_DB_USER:-roller}"
DB_PASS="${ROLLER_DB_PASSWORD:-roller}"
WAIT_FOR_DB="${WAIT_FOR_DB:-1}"

if [ "$WAIT_FOR_DB" = "1" ]; then
    echo "[roller-start] waiting for mysql at ${DB_HOST}:${DB_PORT}"
    until mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; do
        sleep 1
    done
fi

DB_NAME="${ROLLER_DB_NAME:-roller}"
ROLLER_DB_VERSION="${ROLLER_DB_VERSION:-615}"
CREATEDB_SQL="${ROLLER_CREATEDB_SQL:-/usr/local/tomcat/webapps/roller/WEB-INF/classes/dbscripts/mysql/createdb.sql}"

roller_mysql() { mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" "$@" 2>/dev/null; }
roller_table_count() {
    roller_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" || echo 0
}

if [ "$WAIT_FOR_DB" = "1" ]; then
    tables="$(roller_table_count)"
    case "$tables" in ''|*[!0-9]*) tables=0 ;; esac
    if [ "$tables" -le 10 ] && [ -r "$CREATEDB_SQL" ]; then
        echo "[roller-start] seeding schema from $CREATEDB_SQL"
        roller_mysql < "$CREATEDB_SQL"
        roller_mysql -e "INSERT INTO roller_properties (name, value) VALUES ('roller.database.version','${ROLLER_DB_VERSION}') ON DUPLICATE KEY UPDATE value='${ROLLER_DB_VERSION}'"
        echo "[roller-start] schema tables: $(roller_table_count) (version ${ROLLER_DB_VERSION})"
    else
        echo "[roller-start] schema already present (${tables} tables)"
    fi
    roller_mysql -e "INSERT INTO roller_properties (name, value) VALUES ('users.registration.enabled','true') ON DUPLICATE KEY UPDATE value='true'"
    echo "[roller-start] users.registration.enabled=$(roller_mysql -N -B -e "SELECT value FROM roller_properties WHERE name='users.registration.enabled'")"
fi

export CATALINA_OPTS="${CATALINA_OPTS:-} ${JACOCO_AGENT_OPTS:-}"
echo "[roller-start] CATALINA_OPTS=${CATALINA_OPTS}"

exec /usr/local/tomcat/bin/catalina.sh run
