# Zig `mt` Port Scaffold

This folder contains the Zig implementation track for the MuonTickets non-Python CLI.

## Current status

- Zig project scaffold created.
- Command surface mapped to current `mt.py` commands.
- Implemented commands: `init`, `new`, `ls`, `show`, `pick`, `claim`, `comment`, `set-status`, `done`, `archive`, `graph`, `export`, `stats`, `validate`, `report`.
- `new`/`ls`/`pick`/`claim` now support a broader parity option set (`--depends-on`, `--label`, filters, branch override, dependency/WIP controls).
- `report` now writes a real SQLite database with `tickets` and `parse_errors` tables plus summary/search SQL queries.
- `new` now ingests `tickets/ticket.template` defaults and body when CLI overrides are not provided (including labels/tags/depends/status/owner/branch).

## Build and run

```bash
cd ports/zig-mt
zig build
zig build run -- --help
```

`zig build` defaults to `ReleaseSafe` optimization for this port. Override with `-Doptimize=Debug` when debugging.

## Cross-compilation artifacts

Build release artifacts for macOS/Linux/Windows (archives + SHA256 sums):

```bash
cd ports/zig-mt
./scripts/release.sh
```

Quick native-only build artifact:

```bash
./scripts/release.sh --targets native
```

Build only selected targets:

```bash
./scripts/release.sh --targets aarch64-macos,x86_64-linux
```

Note: this port links against system `sqlite3` + libc, so cross-target builds require target-compatible sysroots/libraries. The script continues on failed targets and reports a summary.

## CI publishing and signing

- Workflow: `.github/workflows/zig-release.yml`
- Unified workflow: `.github/workflows/combined-release.yml`
- Triggers:
	- Tag push matching `zig-v*` (build + publish)
	- Manual dispatch (`workflow_dispatch`) with optional `publish=true`
- Unified release trigger: tag push matching `v*` (build + publish Rust + Zig together)
- Build output: native release artifacts from Linux/macOS/Windows runners, aggregated into release assets with combined `SHA256SUMS`
- Signing: CI performs keyless Sigstore signing of `SHA256SUMS` and publishes `SHA256SUMS.sig` + `SHA256SUMS.pem`.

## Consumer verification

Manual verification (in a release download directory):

```bash
shasum -a 256 -c SHA256SUMS

cosign verify-blob \
	--signature SHA256SUMS.sig \
	--certificate SHA256SUMS.pem \
	--certificate-oidc-issuer https://token.actions.githubusercontent.com \
	--certificate-identity-regexp '^https://github.com/muonium-ai/muontickets/.github/workflows/(zig-release|combined-release).yml@refs/(tags/(zig-v.*|v.*)|heads/main)$' \
	SHA256SUMS
```

Automated helper:

```bash
cd ports/zig-mt
./scripts/verify-release.sh --dist dist
```

## Conformance runner integration

```bash
MT_CMD="$(pwd)/zig-out/bin/mt-zig" ../../.venv/bin/python ../../tests/conformance/runner.py --fixture ../../tests/conformance/fixtures/zig_reporting_graph_pick.json
```

## Next slices

1. Add CI checks that fail release publication when verification script fails on generated artifacts.
