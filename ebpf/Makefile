CC      ?= gcc
CLANG   ?= clang
BPFTOOL ?= bpftool

CSTD     := -std=gnu99
WARN     := -Wall -Wextra
OPT      := -O2 -g
CPPFLAGS := -D_GNU_SOURCE -Iinclude
CFLAGS   := $(CSTD) $(WARN) $(OPT) $(CPPFLAGS)
LDFLAGS  :=
LDLIBS   :=

CORE_SRC := src/util.c src/config.c src/bitmap.c src/sql_detect.c \
            src/procmem.c src/arghash.c src/ngram.c src/demux.c \
            src/pid_discovery.c src/tracer.c
CORE_OBJ := $(CORE_SRC:.c=.o)

BACKEND_OBJ := src/backend_ptrace.o src/backend_ebpf.o
MAIN_OBJ    := src/main.o

BIN      := tracelib
TEST_BIN := test/test_basic

BPF_OBJ := tracelib.bpf.o
SKEL    := tracelib.skel.h

EBPF ?= 0
ifeq ($(EBPF),1)
  CFLAGS += -DTRACELIB_EBPF -I.
  LDLIBS += -lbpf -lelf -lz
endif

.PHONY: all test clean help tools
all: $(BIN)

$(BIN): $(CORE_OBJ) $(BACKEND_OBJ) $(MAIN_OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@ $(LDLIBS)

HEADERS := $(wildcard include/*.h)

src/%.o: src/%.c $(HEADERS)
	$(CC) $(CFLAGS) -c $< -o $@

ifeq ($(EBPF),1)
bpf/vmlinux.h:
	@command -v $(BPFTOOL) >/dev/null 2>&1 || { echo "ERROR: bpftool required for EBPF=1"; exit 1; }
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $@

$(BPF_OBJ): bpf/tracelib.bpf.c bpf/vmlinux.h include/cov_shared.h
	@command -v $(CLANG) >/dev/null 2>&1 || { echo "ERROR: clang required for EBPF=1"; exit 1; }
	$(CLANG) -g -O2 -target bpf -D__TARGET_ARCH_x86 -Ibpf -Iinclude -c bpf/tracelib.bpf.c -o $@

$(SKEL): $(BPF_OBJ)
	$(BPFTOOL) gen skeleton $(BPF_OBJ) name tracelib > $@

src/backend_ebpf.o: src/backend_ebpf.c include/backend_ebpf_impl.h $(SKEL)
	$(CC) $(CFLAGS) -c $< -o $@
endif

TOOLS := tools/path_policy tools/sql_reduce tools/sql_mode_hash
tools: $(TOOLS)

tools/path_policy: tools/path_policy.c $(CORE_OBJ)
	$(CC) $(CFLAGS) $< $(CORE_OBJ) -o $@ $(LDFLAGS)

tools/sql_reduce: tools/sql_reduce.c $(CORE_OBJ)
	$(CC) $(CFLAGS) $< $(CORE_OBJ) -o $@ $(LDFLAGS)

tools/sql_mode_hash: tools/sql_mode_hash.c $(CORE_OBJ)
	$(CC) $(CFLAGS) $< $(CORE_OBJ) -o $@ $(LDFLAGS)

test: $(TEST_BIN)
	@echo "== running determinism self-test =="
	@./$(TEST_BIN)

$(TEST_BIN): test/test_basic.c $(CORE_OBJ)
	$(CC) $(CFLAGS) test/test_basic.c $(CORE_OBJ) -o $@ $(LDFLAGS)

clean:
	rm -f src/*.o $(BIN) $(TEST_BIN) $(TOOLS) $(BPF_OBJ) $(SKEL) bpf/vmlinux.h

help:
	@echo "make          - ptrace-only, libc-only tracelib (default)"
	@echo "make EBPF=1    - also build the eBPF backend (needs clang+libbpf+BTF)"
	@echo "make test      - build & run the determinism self-test"
	@echo "make clean     - remove build artifacts"
