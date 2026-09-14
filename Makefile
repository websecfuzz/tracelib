CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -g
CSTD     := -std=c99
CPPFLAGS := -D_GNU_SOURCE -Iinclude
LDFLAGS  :=

BUILD    := build
SRC_DIR  := src
INC_DIR  := include
TEST_DIR := test

LIB_SRCS := \
    $(SRC_DIR)/pid_discovery.c \
    $(SRC_DIR)/bitmap.c \
    $(SRC_DIR)/sql_detect.c \
    $(SRC_DIR)/demux.c \
    $(SRC_DIR)/tracer.c

LIB_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD)/%.o,$(LIB_SRCS))

BIN       := $(BUILD)/tracelib
TEST_BIN  := $(BUILD)/test_basic
TEST2_BIN := $(BUILD)/test_signals
TEST3_BIN := $(BUILD)/test_ebpf_replay

CLANG    ?= $(shell command -v clang 2>/dev/null || command -v clang-14 2>/dev/null || echo clang)
ASM_INCLUDE := $(firstword $(wildcard /usr/include/$(shell uname -m 2>/dev/null)-linux-gnu))
BPF_CFLAGS  := -O2 -g -Wall -ffreestanding -target bpf -D__TARGET_ARCH_x86 \
               $(if $(ASM_INCLUDE),-I$(ASM_INCLUDE),) -Ibpf -Iinclude
LIBBPF_LIBS   ?= $(shell pkg-config --libs libbpf 2>/dev/null || echo -lbpf -lelf -lz)
LIBBPF_CFLAGS ?= $(shell pkg-config --cflags libbpf 2>/dev/null)

BPF_OBJ      := $(BUILD)/tracelib.bpf.o
EBPF_BIN     := $(BUILD)/tracelib_ebpf
REPLAY_OBJ   := $(BUILD)/ebpf_replay.o
LOADER_OBJ   := $(BUILD)/ebpf_loader.o

.PHONY: all clean test ebpf ebpf-bpf test-ebpf-replay
all: $(BIN)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: $(SRC_DIR)/%.c | $(BUILD)
	$(CC) $(CSTD) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(BUILD)/main.o: $(SRC_DIR)/main.c | $(BUILD)
	$(CC) $(CSTD) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(BIN): $(LIB_OBJS) $(BUILD)/main.o
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

$(BUILD)/test_basic.o: $(TEST_DIR)/test_basic.c | $(BUILD)
	$(CC) $(CSTD) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(TEST_BIN): $(LIB_OBJS) $(BUILD)/test_basic.o
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

$(BUILD)/test_signals.o: $(TEST_DIR)/test_signals.c | $(BUILD)
	$(CC) $(CSTD) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(TEST2_BIN): $(LIB_OBJS) $(BUILD)/test_signals.o
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

$(BPF_OBJ): bpf/tracelib.bpf.c bpf/tl_ebpf.h bpf/bpf_helpers_min.h | $(BUILD)
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

$(REPLAY_OBJ): $(SRC_DIR)/ebpf_replay.c | $(BUILD)
	$(CC) $(CSTD) $(CFLAGS) $(CPPFLAGS) -Ibpf -c $< -o $@

$(LOADER_OBJ): $(SRC_DIR)/ebpf_loader.c | $(BUILD)
	$(CC) $(CSTD) $(CFLAGS) $(CPPFLAGS) -Ibpf $(LIBBPF_CFLAGS) -c $< -o $@

$(EBPF_BIN): $(LIB_OBJS) $(REPLAY_OBJ) $(LOADER_OBJ) $(BPF_OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) $(LIB_OBJS) $(REPLAY_OBJ) $(LOADER_OBJ) -o $@ $(LIBBPF_LIBS)

ebpf-bpf: $(BPF_OBJ)
ebpf: $(EBPF_BIN)

$(BUILD)/test_ebpf_replay.o: $(TEST_DIR)/test_ebpf_replay.c | $(BUILD)
	$(CC) $(CSTD) $(CFLAGS) $(CPPFLAGS) -Ibpf -c $< -o $@

$(TEST3_BIN): $(LIB_OBJS) $(REPLAY_OBJ) $(BUILD)/test_ebpf_replay.o
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

test-ebpf-replay: $(TEST3_BIN)
	$(TEST3_BIN)

test: $(TEST_BIN) $(TEST2_BIN) $(TEST3_BIN)
	$(TEST_BIN)
	$(TEST2_BIN)
	$(TEST3_BIN)

clean:
	rm -rf $(BUILD)
