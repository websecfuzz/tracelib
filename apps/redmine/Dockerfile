FROM redmine:5.1

USER root

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential libc6-dev procps iproute2 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY include /tmp/tracelib/include
COPY src     /tmp/tracelib/src
COPY Makefile /tmp/tracelib/Makefile
RUN cd /tmp/tracelib \
    && make \
    && install -m 0755 build/tracelib /usr/local/bin/tracelib \
    && rm -rf /tmp/tracelib

COPY ruby-common/coverage_hook.rb /usr/src/redmine/config/initializers/00_tracelib_coverage.rb

RUN mkdir -p /tracelib-support /coverage \
    && chown -R redmine:redmine /coverage \
    && chmod 777 /coverage
COPY common/entrypoint.sh           /usr/local/bin/tracelib-entrypoint.sh
COPY ruby-common/coverage_report.sh /tracelib-support/coverage_report.sh
COPY apps/redmine/start.sh               /app/start.sh
COPY apps/redmine/app-init.sh            /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh \
              /tracelib-support/coverage_report.sh \
              /app/start.sh \
              /app-init.sh

ENV TRACELIB_PORT=8088 \
    TRACELIB_HEADER=X-REQUEST-ID \
    TRACELIB_COVERAGE_DIR=/coverage \
    TRACELIB_COVERAGE_INTERVAL_SECONDS=15 \
    REDMINE_DB_SQLITE=/usr/src/redmine/sqlite/redmine.db

EXPOSE 8088
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["/app/start.sh"]
