# Zig `mt` Port Scaffold

This folder contains the Zig implementation track for the MuonTickets non-Python CLI.

## Current status

- Zig project scaffold created.
- Command surface mapped to current `mt.py` commands.
- Implemented commands: `init`, `new`, `ls`, `show`, `pick`, `claim`, `comment`, `set-status`, `done`, `archive`, `graph`, `export`, `stats`, `validate`.
- Remaining command handlers are placeholders and will be implemented in parity slices.

## Build and run

```bash
cd ports/zig-mt
zig build
zig build run -- --help
```

## Next slices

1. Implement remaining command: `report`.
2. Expand `new`/`pick`/`claim` parity with full option support and template/default behavior.
3. Hook Zig binary into `tests/conformance` runner via `MT_CMD`.
4. Add cross-compilation artifacts for macOS/Linux/Windows.
