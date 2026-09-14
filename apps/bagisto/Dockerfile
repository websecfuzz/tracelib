FROM php:8.2-apache

ENV DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential libc6-dev procps iproute2 \
        autoconf pkg-config ca-certificates curl \
        libzip-dev libpng-dev libonig-dev libxml2-dev libcurl4-openssl-dev \
        libfreetype6-dev libjpeg62-turbo-dev libwebp-dev \
        libpq-dev libicu-dev unzip git default-mysql-client; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install mysqli pdo_mysql gd zip mbstring intl bcmath xml calendar exif; \
    pecl install pcov; \
    docker-php-ext-enable pcov; \
    curl -fsSL https://getcomposer.org/installer | php -- \
        --install-dir=/usr/local/bin --filename=composer; \
    rm -rf /var/lib/apt/lists/*

ARG BAGISTO_VERSION=v2.2.4
RUN git clone --depth 1 --branch ${BAGISTO_VERSION} https://github.com/bagisto/bagisto.git /var/www/bagisto \
    && cd /var/www/bagisto \
    && composer install --no-interaction --no-progress --optimize-autoloader \
    && rm -rf /var/www/html \
    && ln -s /var/www/bagisto /var/www/html \
    && chown -R www-data:www-data /var/www/bagisto

RUN a2enmod rewrite \
    && sed -i 's/^Listen 80$/Listen 8093/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8093>/' /etc/apache2/sites-enabled/*.conf \
    && sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/bagisto/public|' /etc/apache2/sites-enabled/*.conf \
    && printf '<Directory /var/www/bagisto/public>\n  AllowOverride All\n  Require all granted\n</Directory>\n' \
        > /etc/apache2/conf-enabled/bagisto.conf

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
COPY apps/bagisto/app-init.sh            /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh /app-init.sh

RUN { \
        echo "pcov.enabled=1"; \
        echo "pcov.directory=/var/www/bagisto"; \
        echo "auto_prepend_file=/tracelib-support/pcov_hook.php"; \
    } > /usr/local/etc/php/conf.d/99-tracelib-pcov.ini

EXPOSE 8093
ENV TRACELIB_PORT=8093 \
    TRACELIB_HEADER=X-REQUEST-ID \
    UPSTREAM_ENTRYPOINT=docker-php-entrypoint
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["apache2-foreground"]
