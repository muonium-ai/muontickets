# C `mt` Port (Compatibility Launcher)

This directory contains the C implementation track for MuonTickets.

Current implementation strategy is compatibility-first:

- `mt-c` is a small native launcher written in C.
- It locates the repository root and delegates to the canonical Python CLI (`mt.py`).
- This guarantees behavior parity with `muontickets/mt.py` while still providing a cross-platform native binary entrypoint.

## Build

```bash
cd ports/c-mt
make
./build/mt-c --help
```

## Environment knobs

- `MT_PYTHON`: explicit Python executable to use.
- `MT_PY_ENTRY`: explicit path to Python entrypoint script (`mt.py`).

Default search order for Python executable:

1. `MT_PYTHON`
2. `python3`
3. `python`

Default search order for script path:

1. `MT_PY_ENTRY`
2. `<repo_root>/mt.py` (detected by walking up from current directory)
3. `mt.py` in current working directory

## Release artifacts

```bash
cd ports/c-mt
./scripts/release.sh
```

The release script follows the same artifact convention as other ports:

- `mt-c-<target>.tar.gz` for macOS/Linux
- `mt-c-<target>.zip` for Windows
- `SHA256SUMS`

Cross-target builds use `zig cc` when available.
