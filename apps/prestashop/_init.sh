apt-get install -y libfreetype6-dev

a2enmod rewrite
chown -R www-data:www-data /var/www/html/var
chmod -R 775 /var/www/html/var
chown -R www-data:www-data /var/www/html/var /var/www/html/app/config /var/www/html/img /var/www/html/mails /var/www/html/modules /var/www/html/themes /var/www/html/translations /var/www/html/upload /var/www/html/download
rm -rf /var/www/html/var/cache/*

