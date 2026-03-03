# Zig `mt` Port Scaffold

This folder contains the Zig implementation track for the MuonTickets non-Python CLI.

## Current status

- Zig project scaffold created.
- Command surface mapped to current `mt.py` commands.
- Command handlers are placeholders and will be implemented in parity slices.

## Build and run

```bash
cd ports/zig-mt
zig build
zig build run -- --help
```

## Next slices

1. Implement board discovery and file model (`tickets/`, frontmatter read/write).
2. Implement core commands: `init`, `new`, `ls`, `show`.
3. Implement workflow enforcement: `claim`, `pick`, `set-status`, `done`, `archive`, `validate`.
4. Hook Zig binary into `tests/conformance` runner via `MT_CMD`.
5. Add cross-compilation artifacts for macOS/Linux/Windows.
