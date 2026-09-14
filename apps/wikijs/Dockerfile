FROM ghcr.io/requarks/wiki:2

USER root

RUN apk add --no-cache \
        build-base bash coreutils procps iproute2 ca-certificates curl mysql-client \
    && npm install -g c8@9 \
    && npm cache clean --force

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
COPY apps/wikijs/start.sh                /app/start.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh \
             /tracelib-support/coverage_report.sh \
             /app/start.sh

ENV TRACELIB_PORT=3000 \
    TRACELIB_HEADER=X-REQUEST-ID \
    NODE_OPTIONS="--require /tracelib-support/node_hook.js" \
    NODE_V8_COVERAGE=/coverage/v8 \
    UPSTREAM_ENTRYPOINT=docker-entrypoint.sh

EXPOSE 3000
WORKDIR /wiki
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["/app/start.sh"]
