FROM php:8.3-apache

ENV DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential libc6-dev procps iproute2 \
        autoconf pkg-config ca-certificates curl unzip \
        libzip-dev libpng-dev libonig-dev libicu-dev libxml2-dev \
        libwebp-dev libjpeg62-turbo-dev libfreetype6-dev \
        default-mysql-client; \
    docker-php-ext-configure gd --with-jpeg --with-freetype --with-webp; \
    docker-php-ext-install mysqli pdo_mysql gd zip mbstring intl opcache; \
    pecl install pcov apcu; \
    docker-php-ext-enable pcov apcu; \
    rm -rf /var/lib/apt/lists/*

COPY include /tmp/tracelib/include
COPY src     /tmp/tracelib/src
COPY Makefile /tmp/tracelib/Makefile
RUN cd /tmp/tracelib \
    && make \
    && install -m 0755 build/tracelib /usr/local/bin/tracelib \
    && rm -rf /tmp/tracelib

RUN a2enmod rewrite \
    && sed -i 's/^Listen 80$/Listen 8095/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8095>/' /etc/apache2/sites-enabled/*.conf \
    && sed -i 's|/var/www/html|/var/www/html/web|g' /etc/apache2/sites-enabled/*.conf \
    && printf '<Directory /var/www/html/web>\n  AllowOverride All\n  Require all granted\n</Directory>\n' \
        > /etc/apache2/conf-available/drupal.conf \
    && a2enconf drupal

RUN { \
        echo "memory_limit=512M"; \
        echo "max_execution_time=300"; \
        echo "post_max_size=64M"; \
        echo "upload_max_filesize=64M"; \
    } > /usr/local/etc/php/conf.d/99-drupal.ini

RUN { \
        echo "pcov.enabled=1"; \
        echo "pcov.directory=/var/www/html/web"; \
        echo "auto_prepend_file=/tracelib-support/pcov_hook.php"; \
    } > /usr/local/etc/php/conf.d/99-tracelib-pcov.ini

RUN rm -rf /var/www/html
COPY apps/drupal/app /var/www/html
RUN chown -R www-data:www-data /var/www/html

RUN mkdir -p /tracelib-support /coverage && chmod 777 /coverage
COPY php-common/pcov_hook.php       /tracelib-support/pcov_hook.php
COPY php-common/coverage_report.php /tracelib-support/coverage_report.php
COPY common/entrypoint.sh           /usr/local/bin/tracelib-entrypoint.sh
COPY apps/drupal/app-init.sh             /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh /app-init.sh

EXPOSE 8095
ENV TRACELIB_PORT=8095 \
    TRACELIB_HEADER=X-REQUEST-ID

ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["apache2-foreground"]
