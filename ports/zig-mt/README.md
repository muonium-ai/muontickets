# Zig `mt` Port Scaffold

This folder contains the Zig implementation track for the MuonTickets non-Python CLI.

## Current status

- Zig project scaffold created.
- Command surface mapped to current `mt.py` commands.
- Implemented commands: `init`, `new`, `ls`, `show`, `pick`, `claim`, `comment`, `set-status`, `done`, `archive`, `graph`, `export`, `stats`, `validate`, `report`.
- `new`/`ls`/`pick`/`claim` now support a broader parity option set (`--depends-on`, `--label`, filters, branch override, dependency/WIP controls).

## Build and run

```bash
cd ports/zig-mt
zig build
zig build run -- --help
```

## Conformance runner integration

```bash
MT_CMD="$(pwd)/zig-out/bin/mt-zig" ../../.venv/bin/python ../../tests/conformance/runner.py --fixture ../../tests/conformance/fixtures/zig_reporting_graph_pick.json
```

## Next slices

1. Improve `report` from stubbed artifact to SQLite-compatible schema parity.
2. Expand template/default behavior parity for `new` (including template ingestion).
3. Add cross-compilation artifacts for macOS/Linux/Windows.
