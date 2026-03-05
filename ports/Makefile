SHELL := /bin/sh

RUST_DIR := rust-mt
ZIG_DIR := zig-mt
C_DIR := c-mt
DIST_DIR := dist
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

RUST_SRC_BIN := $(RUST_DIR)/target/release/mt-port
RUST_OUT_BIN := $(DIST_DIR)/rust-mt

ZIG_SRC_BIN := $(ZIG_DIR)/zig-out/bin/mt-zig
ZIG_OUT_BIN := $(DIST_DIR)/zig-mt

C_SRC_BIN := $(C_DIR)/build/mt-c
C_OUT_BIN := $(DIST_DIR)/c-mt

.PHONY: all release rust zig c install clean rebuild

all: release

release: rust zig c

$(DIST_DIR):
	mkdir -p $(DIST_DIR)

rust: $(DIST_DIR)
	cd $(RUST_DIR) && cargo build --release
	cp $(RUST_SRC_BIN) $(RUST_OUT_BIN)
	chmod +x $(RUST_OUT_BIN)
	@echo "Built $(RUST_OUT_BIN)"

zig: $(DIST_DIR)
	cd $(ZIG_DIR) && zig build -Doptimize=ReleaseSafe
	cp $(ZIG_SRC_BIN) $(ZIG_OUT_BIN)
	chmod +x $(ZIG_OUT_BIN)
	@echo "Built $(ZIG_OUT_BIN)"

c: $(DIST_DIR)
	cd $(C_DIR) && $(MAKE)
	cp $(C_SRC_BIN) $(C_OUT_BIN)
	chmod +x $(C_OUT_BIN)
	@echo "Built $(C_OUT_BIN)"

install: release
	mkdir -p $(BINDIR)
	cp $(RUST_OUT_BIN) $(BINDIR)/rust-mt
	cp $(ZIG_OUT_BIN) $(BINDIR)/zig-mt
	cp $(C_OUT_BIN) $(BINDIR)/c-mt
	chmod +x $(BINDIR)/rust-mt $(BINDIR)/zig-mt $(BINDIR)/c-mt
	@echo "Installed rust-mt, zig-mt, and c-mt to $(BINDIR)"

clean:
	-rm -rf $(DIST_DIR)
	cd $(RUST_DIR) && cargo clean
	rm -rf $(ZIG_DIR)/.zig-cache $(ZIG_DIR)/zig-out
	cd $(C_DIR) && $(MAKE) clean
	@echo "Cleaned release outputs and build artifacts"

rebuild: clean release
