FROM ghost:5

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        libc6-dev \
        procps \
        iproute2 \
        default-mysql-client \
        ca-certificates \
        curl; \
    npm install -g c8@9; \
    rm -rf /var/lib/apt/lists/*

COPY include /tmp/tracelib/include
COPY src     /tmp/tracelib/src
COPY Makefile /tmp/tracelib/Makefile
RUN cd /tmp/tracelib \
    && make \
    && install -m 0755 build/tracelib /usr/local/bin/tracelib \
    && rm -rf /tmp/tracelib

RUN mkdir -p /tracelib-support /coverage /coverage/v8 \
    && chmod 777 /coverage /coverage/v8
COPY node-common/node_hook.js       /tracelib-support/node_hook.js
COPY node-common/coverage_report.sh /tracelib-support/coverage_report.sh
COPY common/entrypoint.sh           /usr/local/bin/tracelib-entrypoint.sh
COPY apps/ghost/ghost-start.sh           /usr/local/bin/ghost-start.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh
RUN chmod +x /usr/local/bin/ghost-start.sh
RUN chmod +x /tracelib-support/coverage_report.sh

ENV TRACELIB_PORT=2368 \
    TRACELIB_HEADER=X-REQUEST-ID \
    NODE_OPTIONS="--require /tracelib-support/node_hook.js" \
    NODE_V8_COVERAGE=/coverage/v8 \
    UPSTREAM_ENTRYPOINT=docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["ghost-start.sh"]
