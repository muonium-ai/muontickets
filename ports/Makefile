SHELL := /bin/sh

RUST_DIR := rust-mt
ZIG_DIR := zig-mt
DIST_DIR := dist
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

RUST_SRC_BIN := $(RUST_DIR)/target/release/mt-port
RUST_OUT_BIN := $(DIST_DIR)/rust-mt

ZIG_SRC_BIN := $(ZIG_DIR)/zig-out/bin/mt-zig
ZIG_OUT_BIN := $(DIST_DIR)/zig-mt

.PHONY: all release rust zig install clean rebuild

all: release

release: rust zig

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

install: release
	mkdir -p $(BINDIR)
	cp $(RUST_OUT_BIN) $(BINDIR)/rust-mt
	cp $(ZIG_OUT_BIN) $(BINDIR)/zig-mt
	chmod +x $(BINDIR)/rust-mt $(BINDIR)/zig-mt
	@echo "Installed rust-mt and zig-mt to $(BINDIR)"

clean:
	-rm -rf $(DIST_DIR)
	cd $(RUST_DIR) && cargo clean
	rm -rf $(ZIG_DIR)/.zig-cache $(ZIG_DIR)/zig-out
	@echo "Cleaned release outputs and build artifacts"

rebuild: clean release
