#!/bin/bash

set -u

PORT="${TRACELIB_PORT:-8099}"
BASE="http://127.0.0.1:${PORT}/roller"
DB_HOST="${ROLLER_DB_HOST:-db}"
DB_PORT="${ROLLER_DB_PORT:-3306}"
DB_USER="${ROLLER_DB_USER:-roller}"
DB_PASS="${ROLLER_DB_PASSWORD:-roller}"
DB_NAME="${ROLLER_DB_NAME:-roller}"
USER_NAME="${ROLLER_ADMIN_USER:-rolleradmin}"
USER_PASS="${ROLLER_ADMIN_PASSWORD:-admin123}"
USER_MAIL="${ROLLER_ADMIN_EMAIL:-admin@example.com}"
READY_MARKER="${APP_INIT_READY_MARKER:-/tmp/tracelib-app-ready}"
REGISTER_ATTEMPTS="${ROLLER_REGISTER_ATTEMPTS:-3}"
INSTALL_WAIT_TICKS="${ROLLER_INSTALL_WAIT_TICKS:-150}"

mysql_do() { mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -B -e "$1" 2>/dev/null; }

verify_login() {
    local jar body
    jar="$(mktemp)"
    curl -fsS -c "$jar" -o /dev/null "${BASE}/roller-ui/login.rol" 2>/dev/null || { rm -f "$jar"; return 1; }
    curl -fsS -b "$jar" -c "$jar" -o /dev/null \
        --data-urlencode "j_username=${USER_NAME}" \
        --data-urlencode "j_password=${USER_PASS}" \
        "${BASE}/roller_j_security_check" 2>/dev/null || { rm -f "$jar"; return 1; }
    body="$(curl -fsS -b "$jar" "${BASE}/roller-ui/profile.rol" 2>/dev/null)"
    rm -f "$jar"
    case "$body" in
        *"$USER_NAME"*) return 0 ;;
        *) return 1 ;;
    esac
}

enable_registration() {
    mysql_do "INSERT INTO roller_properties (name, value) VALUES ('users.registration.enabled','true') ON DUPLICATE KEY UPDATE value='true'" >/dev/null 2>&1 || true
}

register_account() {
    local jar salt
    jar="$(mktemp)"
    salt="$(curl -fsS -c "$jar" "${BASE}/roller-ui/register.rol" 2>/dev/null \
        | grep -oE 'name="salt"[^>]*value="[^"]*"' | head -n 1 | sed 's/.*value="//;s/"$//')"
    curl -fsS -b "$jar" -c "$jar" -o /dev/null \
        --data-urlencode "salt=${salt}" \
        --data-urlencode "bean.userName=${USER_NAME}" \
        --data-urlencode "bean.passwordText=${USER_PASS}" \
        --data-urlencode "bean.passwordConfirm=${USER_PASS}" \
        --data-urlencode "bean.screenName=${USER_NAME}" \
        --data-urlencode "bean.fullName=Fuzz Admin" \
        --data-urlencode "bean.emailAddress=${USER_MAIL}" \
        --data-urlencode "bean.locale=en_US" \
        --data-urlencode "bean.timeZone=UTC" \
        --data-urlencode "userRegister.button.save=Save" \
        "${BASE}/roller-ui/register!save.rol" 2>/dev/null || true
    rm -f "$jar"
}

rm -f "$READY_MARKER" 2>/dev/null || true

for _ in $(seq 1 120); do
    curl -fsS -o /dev/null "${BASE}/roller-ui/login.rol" 2>/dev/null && break
    sleep 2
done

user_rows="$(mysql_do "SELECT COUNT(*) FROM roller_user" || echo 0)"
case "$user_rows" in ''|*[!0-9]*) user_rows=0 ;; esac
if [ "$user_rows" -gt 0 ] && verify_login; then
    echo "[roller-init] already installed and ${USER_NAME} logs in (${user_rows} user row(s))"
    : > "$READY_MARKER"
    exit 0
fi

table_count() {
    mysql_do "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" || echo 0
}

schema_ready() {
    [ "$(table_count)" -gt 10 ] 2>/dev/null
}

form_ready() {
    curl -fsS "${BASE}/roller-ui/register.rol" 2>/dev/null \
        | grep -qE 'name="salt"'
}

registerable() {
    schema_ready && form_ready
}

echo "[roller-init] waiting for Roller to finish bootstrapping"
curl -fsS -o /dev/null "${BASE}/roller-ui/login.rol" 2>/dev/null || true
installed=0
for _ in $(seq 1 "$INSTALL_WAIT_TICKS"); do
    if registerable; then installed=1; break; fi
    sleep 2
done
echo "[roller-init] schema tables: $(table_count)"

if [ "$installed" != "1" ]; then
    echo "[roller-init] Roller did not come up installed; falling back to the web installer"
    if [ "$(table_count)" -le 10 ] 2>/dev/null; then
        curl -fsS -o /dev/null "${BASE}/roller-ui/install/install!create.rol" 2>/dev/null || true
        for _ in $(seq 1 60); do
            [ "$(table_count)" -gt 10 ] 2>/dev/null && break
            sleep 2
        done
    fi
    curl -fsS -o /dev/null "${BASE}/roller-ui/install/install!bootstrap.rol" 2>/dev/null || true
    for _ in $(seq 1 60); do
        registerable && { installed=1; break; }
        sleep 2
    done
    echo "[roller-init] after fallback: schema tables: $(table_count) registerable=${installed}"
fi

echo "[roller-init] enabling self-registration"
enable_registration

attempt=1
while [ "$attempt" -le "$REGISTER_ATTEMPTS" ]; do
    echo "[roller-init] registering ${USER_NAME} through Roller's own form (attempt ${attempt}/${REGISTER_ATTEMPTS})"
    enable_registration
    register_account
    if verify_login; then
        echo "[roller-init] admin account ready and verified by login: ${USER_NAME}"
        : > "$READY_MARKER"
        exit 0
    fi
    echo "[roller-init] ${USER_NAME} cannot log in yet; retrying"
    sleep 5
    attempt=$(( attempt + 1 ))
done

created="$(mysql_do "SELECT COUNT(*) FROM roller_user WHERE username='${USER_NAME}'" || echo 0)"
echo "[roller-init] ERROR: ${USER_NAME} could not be made loggable after ${REGISTER_ATTEMPTS} attempts" \
     "(roller_user rows for the name: ${created:-0}). The cell will fail its auto-login;" \
     "check roller_properties.users.registration.enabled and the register!save.rol response."
exit 1
