SHELL := /bin/sh

CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Wpedantic
LDFLAGS ?=

SRC := src/main.c
OUT_DIR := build
OUT_BIN := $(OUT_DIR)/mt-c

.PHONY: all clean run

all: $(OUT_BIN)

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(OUT_BIN): $(SRC) | $(OUT_DIR)
	$(CC) $(CFLAGS) -o $(OUT_BIN) $(SRC) $(LDFLAGS)

run: $(OUT_BIN)
	$(OUT_BIN) --help

clean:
	rm -rf $(OUT_DIR)
