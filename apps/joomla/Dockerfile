FROM joomla:5.1-php8.2-apache

ENV DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential libc6-dev procps iproute2 \
        autoconf pkg-config ca-certificates curl \
        default-mysql-client; \
    pecl install pcov; \
    docker-php-ext-enable pcov; \
    rm -rf /var/lib/apt/lists/*

RUN sed -i 's/^Listen 80$/Listen 8090/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8090>/' /etc/apache2/sites-enabled/*.conf

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
COPY apps/joomla/app-init.sh             /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh /app-init.sh

RUN { \
        echo "pcov.enabled=1"; \
        echo "pcov.directory=/var/www/html"; \
        echo "auto_prepend_file=/tracelib-support/pcov_hook.php"; \
    } > /usr/local/etc/php/conf.d/99-tracelib-pcov.ini

EXPOSE 8090
ENV TRACELIB_PORT=8090 \
    TRACELIB_HEADER=X-REQUEST-ID \
    UPSTREAM_ENTRYPOINT=/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["apache2-foreground"]
