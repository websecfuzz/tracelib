#!/bin/sh
set -eu

exec /docker-entrypoint.sh rails server -b 0.0.0.0 -p 8088
