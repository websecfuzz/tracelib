#!/bin/bash
set -u

/tmp/wp-install.sh

if [ -f /var/www/html/instr.meta ]; then
    echo "instr.meta present at /var/www/html/instr.meta"
else
    echo "WARNING: /var/www/html/instr.meta is missing"
fi
