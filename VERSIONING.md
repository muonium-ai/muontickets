# Versioning Contract

This document defines the shared version/build-info contract for `mt.py`, `rust-mt`, and `zig-mt`.

## VERSION source of truth

- The project root `VERSION` file is the canonical source of semantic version.
- Current format is **major.minor** (for example: `0.1`).
- Whitespace around the value is ignored when parsing.

## Parsing and validation semantics

All implementations should apply the same validation rules:

1. Read the root `VERSION` file.
2. Trim leading/trailing whitespace.
3. Accept only `^([0-9]+)\.([0-9]+)$`.
4. Parse captured values as non-negative integers (`major`, `minor`).
5. Reject missing or malformed content with a clear error.

## Build-info reporting contract

When `--version` / `version` output is implemented for each CLI, output should include:

- product name (`mt.py`, `rust-mt`, `zig-mt`)
- semantic version from root `VERSION`
- implementation/runtime details
- build-tool versions relevant for bug reports

Required tool metadata by implementation:

- Python: `python` version
- Rust binary: `rustc` and `cargo` versions used to build
- Zig binary: `zig` compiler version used to build

## Rationale

A shared, parseable version/build-info contract makes field bug reports reproducible and comparable across implementations.
