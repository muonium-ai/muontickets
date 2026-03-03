# Rust `mt` Port Scaffold

This directory hosts the first non-Python implementation track for MuonTickets (`T-000009`).

## Current status

- Rust crate scaffold created.
- First executable slice implemented: `init`, `new`, `ls`, `show` (file-backed ticket operations).
- Remaining commands are still placeholder handlers and will be implemented incrementally with parity tests.

## Build and run

```bash
cd ports/rust-mt
cargo run -- --help
```

## Next implementation slices

1. Implement state transitions and dependency validation (`claim`, `pick`, `set-status`, `done`, `archive`, `validate`).
2. Implement reporting/export/graph/stats and close parity gaps using `tests/conformance` fixtures.
