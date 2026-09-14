FROM ghcr.io/huginn/huginn-single-process:latest

USER root

RUN chown root:root /app/.env.example && chmod 0644 /app/.env.example

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential libc6-dev procps iproute2 ca-certificates curl \
        default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

COPY include /tmp/tracelib/include
COPY src     /tmp/tracelib/src
COPY Makefile /tmp/tracelib/Makefile
RUN cd /tmp/tracelib \
    && make \
    && install -m 0755 build/tracelib /usr/local/bin/tracelib \
    && rm -rf /tmp/tracelib

COPY ruby-common/coverage_hook.rb /app/config/initializers/00_tracelib_coverage.rb

RUN mkdir -p /tracelib-support /coverage \
    && chmod 777 /coverage
COPY common/entrypoint.sh           /usr/local/bin/tracelib-entrypoint.sh
COPY ruby-common/coverage_report.sh /tracelib-support/coverage_report.sh
COPY apps/huginn/start.sh                /app/start.sh
COPY apps/huginn/app-init.sh             /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh \
              /tracelib-support/coverage_report.sh \
              /app/start.sh \
              /app-init.sh

ENV TRACELIB_PORT=8092 \
    TRACELIB_HEADER=X-REQUEST-ID \
    TRACELIB_COVERAGE_DIR=/coverage \
    TRACELIB_COVERAGE_INTERVAL_SECONDS=15 \
    HOME=/app \
    RAILS_ENV=production \
    PORT=8092 \
    IP=0.0.0.0

WORKDIR /app
EXPOSE 8092
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["/app/start.sh"]
