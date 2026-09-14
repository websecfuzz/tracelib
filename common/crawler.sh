#!/bin/sh
set -u

TARGET="${TARGET:-http://wordpress}"
INTERVAL="${INTERVAL:-2}"
URLS="${URLS:-/}"
HEADER="${HEADER:-X-REQUEST-ID}"

echo "[crawler] target=$TARGET header=$HEADER interval=${INTERVAL}s"
echo "[crawler] waiting for $TARGET to respond"
for _ in $(seq 1 120); do
    if curl -sS -o /dev/null -w '%{http_code}\n' --max-time 3 "$TARGET/" \
            | grep -qE '^(200|301|302|401|403|404)$'; then
        echo "[crawler] target is up"
        break
    fi
    sleep 2
done

i=0
while true; do
    for u in $URLS; do
        i=$((i + 1))
        rid="req-$(date +%s)-$i"
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
                -H "$HEADER: $rid" "$TARGET$u" || echo ERR)
        echo "[crawler] $rid  $code  GET $u"
        sleep "$INTERVAL"
    done
done
