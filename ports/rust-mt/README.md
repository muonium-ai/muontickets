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

## Cross-compilation artifacts

Build release artifacts (archives + SHA256 sums):

```bash
cd ports/rust-mt
./scripts/release.sh --targets native
```

Optional explicit targets:

```bash
./scripts/release.sh --targets x86_64-unknown-linux-gnu,aarch64-apple-darwin
```

## CI publishing and signing

- Workflow: `.github/workflows/rust-release.yml`
- Unified workflow: `.github/workflows/combined-release.yml`
- Triggers:
	- Tag push matching `rust-v*` (build + publish)
	- Manual dispatch (`workflow_dispatch`) with optional `publish=true`
- Unified release trigger: tag push matching `v*` (build + publish Rust + Zig together)
- Build output: native release artifacts from Linux/macOS/Windows runners, aggregated into release assets with combined `SHA256SUMS`
- Archive formats: `.tar.gz` for Linux/macOS and `.zip` for Windows
- Signing: CI performs keyless Sigstore signing of `SHA256SUMS` and publishes `SHA256SUMS.sig` + `SHA256SUMS.pem`
- Smoke validation: CI runs conformance fixture `reporting_graph_pick.json` against built binary before publish

## Consumer verification

Manual verification (in a release download directory):

```bash
shasum -a 256 -c SHA256SUMS

cosign verify-blob \
	--signature SHA256SUMS.sig \
	--certificate SHA256SUMS.pem \
	--certificate-oidc-issuer https://token.actions.githubusercontent.com \
	--certificate-identity-regexp '^https://github.com/muonium-ai/muontickets/.github/workflows/(rust-release|combined-release).yml@refs/(tags/(rust-v.*|v.*)|heads/main)$' \
	SHA256SUMS
```

Automated helper:

```bash
cd ports/rust-mt
./scripts/verify-release.sh --dist dist
```

## Next implementation slices

1. Expand explicit parity fixtures for edge-case metadata formatting and invalid ticket parsing behavior.
