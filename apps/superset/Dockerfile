FROM apache/superset:4.0.2

USER root

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

RUN pip install --no-cache-dir "coverage==7.6.1"

RUN mkdir -p /tracelib-support /coverage \
    && chmod 777 /coverage
COPY common/entrypoint.sh                  /usr/local/bin/tracelib-entrypoint.sh
COPY python-common/coverage_init.py        /tracelib-support/tracelib_coverage_init.py
COPY python-common/coverage_report.py      /tracelib-support/coverage_report.py
COPY apps/superset/wsgi_cov.py             /tracelib-support/wsgi_cov.py
COPY apps/superset/superset_config.py      /app/pythonpath/superset_config.py
COPY apps/superset/start.sh                /app/start.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh \
             /tracelib-support/coverage_report.py \
             /app/start.sh

ENV PYTHONPATH=/tracelib-support:/app/pythonpath \
    SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py \
    FLASK_APP=superset \
    SUPERSET_HOME=/app/superset_home \
    COVERAGE_SOURCE=/app/superset \
    COVERAGE_FLUSH_EVERY=50 \
    TRACELIB_PORT=8096 \
    TRACELIB_HEADER=X-REQUEST-ID \
    UPSTREAM_ENTRYPOINT=docker-entrypoint.sh

EXPOSE 8096
WORKDIR /tracelib-support
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["/app/start.sh"]
