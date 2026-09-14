#!/bin/bash

mysql -uroot -ppassword -h db -e "status" > /dev/null 2>&1
RET=$?
while [[ RET -ne 0 ]]; do
    echo "=> Waiting for confirmation of MySQL service startup"
    sleep 2
    mysql -uroot -ppassword -h db -e "status" > /dev/null 2>&1
    RET=$?
done

chmod 777 -R /var/www/html
chown -R www-data:www-data /var/www/html/
