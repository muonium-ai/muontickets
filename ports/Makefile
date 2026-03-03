SHELL := /bin/sh

RUST_DIR := rust-mt
ZIG_DIR := zig-mt
DIST_DIR := dist

RUST_SRC_BIN := $(RUST_DIR)/target/release/mt-port
RUST_OUT_BIN := $(DIST_DIR)/rust-mt

ZIG_SRC_BIN := $(ZIG_DIR)/zig-out/bin/mt-zig
ZIG_OUT_BIN := $(DIST_DIR)/zig-mt

.PHONY: all release rust zig clean rebuild

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

clean:
	-rm -rf $(DIST_DIR)
	cd $(RUST_DIR) && cargo clean
	rm -rf $(ZIG_DIR)/.zig-cache $(ZIG_DIR)/zig-out
	@echo "Cleaned release outputs and build artifacts"

rebuild: clean release
