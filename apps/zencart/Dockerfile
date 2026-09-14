FROM php:8.2-apache

ENV DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential libc6-dev procps iproute2 \
        autoconf pkg-config ca-certificates curl \
        libzip-dev libpng-dev libonig-dev \
        libwebp-dev libjpeg62-turbo-dev libfreetype6-dev \
        default-mysql-client; \
    docker-php-ext-configure gd --with-jpeg --with-freetype --with-webp; \
    docker-php-ext-install mysqli pdo_mysql gd zip mbstring; \
    pecl install pcov; \
    docker-php-ext-enable pcov; \
    rm -rf /var/lib/apt/lists/*

COPY include /tmp/tracelib/include
COPY src     /tmp/tracelib/src
COPY Makefile /tmp/tracelib/Makefile
RUN cd /tmp/tracelib \
    && make \
    && install -m 0755 build/tracelib /usr/local/bin/tracelib \
    && rm -rf /tmp/tracelib

RUN a2enmod rewrite \
    && sed -i 's/^Listen 80$/Listen 8094/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8094>/' /etc/apache2/sites-enabled/*.conf

RUN { \
        echo "memory_limit=512M"; \
        echo "max_execution_time=300"; \
    } > /usr/local/etc/php/conf.d/99-zencart.ini

RUN { \
        echo "pcov.enabled=1"; \
        echo "pcov.directory=/var/www/html"; \
        echo "auto_prepend_file=/tracelib-support/pcov_hook.php"; \
    } > /usr/local/etc/php/conf.d/99-tracelib-pcov.ini

RUN rm -rf /var/www/html
COPY apps/zencart /var/www/html
RUN rm -rf /var/www/html/_resources /var/www/html/docker-compose.yaml \
           /var/www/html/temp /var/www/html/_init.sh \
    && sed -i 's|localhost:8081|localhost:8094|g' \
         /var/www/html/includes/configure.php \
         /var/www/html/adminzcfuzz/includes/configure.php \
    && chown -R www-data:www-data /var/www/html

RUN mkdir -p /tracelib-support /coverage && chmod 777 /coverage
COPY php-common/pcov_hook.php       /tracelib-support/pcov_hook.php
COPY php-common/coverage_report.php /tracelib-support/coverage_report.php
COPY common/entrypoint.sh           /usr/local/bin/tracelib-entrypoint.sh
COPY apps/zencart/app-init.sh            /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh /app-init.sh

EXPOSE 8094
ENV TRACELIB_PORT=8094 \
    TRACELIB_HEADER=X-REQUEST-ID

ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["apache2-foreground"]
