# Rust `mt` Port Scaffold

This directory hosts the first non-Python implementation track for MuonTickets (`T-000009`).

## Current status

- Rust crate scaffold created.
- Implemented commands: `init`, `new`, `ls`, `show`, `claim`, `pick`, `comment`, `set-status`, `done`, `archive`, `validate`, `graph`, `export`, `stats`, `report`.
- `report` now builds a SQLite database and prints summary/search sections similar to Python behavior.

## Build and run

```bash
cd ports/rust-mt
cargo run -- --help
```

## Next implementation slices

1. Tighten option-level behavior parity and broaden conformance fixture coverage.
2. Add CI-oriented conformance checks for Rust executable output compatibility.
