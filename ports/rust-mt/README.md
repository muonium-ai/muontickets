# Rust `mt` Port Scaffold

This directory hosts the first non-Python implementation track for MuonTickets (`T-000009`).

## Current status

- Rust crate scaffold created.
- Implemented commands: `init`, `new`, `ls`, `show`, `claim`, `pick`, `comment`, `set-status`, `done`, `archive`, `validate`.
- Remaining placeholders: `graph`, `export`, `stats`, `report`.

## Build and run

```bash
cd ports/rust-mt
cargo run -- --help
```

## Next implementation slices

1. Implement reporting/export/graph/stats and close parity gaps using `tests/conformance` fixtures.
2. Tighten option-level behavior parity and broaden conformance fixture coverage.
