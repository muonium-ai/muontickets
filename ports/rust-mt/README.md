# Rust `mt` Port Scaffold

This directory hosts the first non-Python implementation track for MuonTickets (`T-000009`).

## Current status

- Rust crate scaffold created.
- CLI command surface mapped to Python `mt.py` command names.
- Command handlers are placeholders and will be implemented incrementally with parity tests.

## Build and run

```bash
cd ports/rust-mt
cargo run -- --help
```

## Next implementation slices

1. Implement board discovery + `init`/`new`/`ls`/`show`.
2. Implement state transitions and dependency validation (`claim`, `pick`, `set-status`, `done`, `archive`, `validate`).
3. Implement reporting/export/graph/stats and close parity gaps using `tests/conformance` fixtures.
