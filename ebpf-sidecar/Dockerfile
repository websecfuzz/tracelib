FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang libbpf-dev libelf-dev zlib1g-dev bpftool \
        ca-certificates iproute2 procps curl \
    && rm -rf /var/lib/apt/lists/*

COPY ebpf/Makefile /src/ebpf/Makefile
COPY ebpf/include  /src/ebpf/include
COPY ebpf/src      /src/ebpf/src
COPY ebpf/bpf      /src/ebpf/bpf
COPY ebpf/config   /src/ebpf/config
RUN cd /src/ebpf \
    && make EBPF=1 \
    && test -x ./tracelib \
    && install -m 0755 ./tracelib /usr/local/bin/tracelib_ebpf \
    && install -d -m 0755 /etc/tracelib \
    && install -m 0644 ./config/web_related_syscalls.txt /etc/tracelib/web-related-syscalls.txt \
    && rm -rf /src

COPY common/ebpf-sidecar-entrypoint.sh /usr/local/bin/ebpf-sidecar-entrypoint.sh
RUN chmod +x /usr/local/bin/ebpf-sidecar-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/ebpf-sidecar-entrypoint.sh"]
