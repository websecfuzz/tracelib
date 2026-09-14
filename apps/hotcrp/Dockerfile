FROM php:8.3-apache

ENV DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git unzip default-mysql-client \
        build-essential libc6-dev autoconf pkg-config \
        procps iproute2 ca-certificates curl; \
    docker-php-ext-install mysqli pdo_mysql; \
    pecl install pcov; \
    docker-php-ext-enable pcov; \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/kohler/hotcrp.git /var/www/html \
    && chown -R www-data:www-data /var/www/html

RUN a2enmod rewrite \
    && sed -i 's/^Listen 80$/Listen 8087/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8087>/' /etc/apache2/sites-enabled/*.conf \
    && printf '<Directory /var/www/html>\n  AllowOverride All\n  Require all granted\n</Directory>\n' \
        > /etc/apache2/conf-enabled/hotcrp.conf

RUN { \
        echo "pcov.enabled=1"; \
        echo "pcov.directory=/var/www/html"; \
        echo "auto_prepend_file=/tracelib-support/pcov_hook.php"; \
    } > /usr/local/etc/php/conf.d/99-tracelib-pcov.ini

COPY include /tmp/tracelib/include
COPY src     /tmp/tracelib/src
COPY Makefile /tmp/tracelib/Makefile
RUN cd /tmp/tracelib \
    && make \
    && install -m 0755 build/tracelib /usr/local/bin/tracelib \
    && rm -rf /tmp/tracelib

RUN mkdir -p /tracelib-support /coverage && chmod 777 /coverage
COPY php-common/pcov_hook.php       /tracelib-support/pcov_hook.php
COPY php-common/coverage_report.php /tracelib-support/coverage_report.php
COPY common/entrypoint.sh           /usr/local/bin/tracelib-entrypoint.sh
COPY apps/hotcrp/ensure-admin.php        /var/www/html/ensure-admin.php
COPY apps/hotcrp/app-init.sh             /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh /app-init.sh

EXPOSE 8087
ENV TRACELIB_PORT=8087 \
    TRACELIB_HEADER=X-REQUEST-ID \
    UPSTREAM_ENTRYPOINT=docker-php-entrypoint
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["apache2-foreground"]
