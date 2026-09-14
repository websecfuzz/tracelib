FROM golang:1.22-bookworm

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential libc6-dev procps iproute2 ca-certificates curl \
        git default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

COPY include /tmp/tracelib/include
COPY src     /tmp/tracelib/src
COPY Makefile /tmp/tracelib/Makefile
RUN cd /tmp/tracelib \
    && make \
    && install -m 0755 build/tracelib /usr/local/bin/tracelib \
    && rm -rf /tmp/tracelib

ARG GOGS_VERSION=v0.13.2
RUN git clone --depth 1 --branch ${GOGS_VERSION} https://github.com/gogs/gogs.git /src/gogs
WORKDIR /src/gogs
COPY go-common/cov_flush.go /src/gogs/cov_flush.go
RUN go build -cover -covermode=atomic -coverpkg=./... \
        -tags "cov_flush" \
        -o /usr/local/bin/gogs . \
    && cd / && rm -rf /src /root/.cache

RUN mkdir -p /tracelib-support /coverage /data/gogs/conf /data/gogs/log /data/gogs/data /data/repos \
    && chmod -R 777 /coverage /data
COPY common/entrypoint.sh           /usr/local/bin/tracelib-entrypoint.sh
COPY go-common/coverage_report.sh   /tracelib-support/coverage_report.sh
COPY apps/gogs/start.sh                  /app/start.sh
COPY apps/gogs/app-init.sh               /app-init.sh
RUN chmod +x /usr/local/bin/tracelib-entrypoint.sh \
              /tracelib-support/coverage_report.sh \
              /app/start.sh \
              /app-init.sh

ENV TRACELIB_PORT=8091 \
    TRACELIB_HEADER=X-REQUEST-ID \
    GOCOVERDIR=/coverage \
    GOCOV_FLUSH_INTERVAL_SECONDS=15 \
    GOGS_CUSTOM=/data/gogs

EXPOSE 8091
ENTRYPOINT ["/usr/local/bin/tracelib-entrypoint.sh"]
CMD ["/app/start.sh"]
