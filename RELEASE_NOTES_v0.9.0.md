# MuonTickets v0.9.0 Release Notes

Release date: 2026-03-04

## Highlights

- Unified multi-platform release pipeline for Rust + Zig under a single `v*` tag.
- Cross-implementation versioning contract from root `VERSION` (`0.9`) now surfaced consistently across CLIs.
- Global version UX parity across Python, Rust, and Zig (`no-command`, `-v`, `--version`).
- Stronger Python-driven parity testing against Rust and Zig binaries.
- Release runbook and verification guidance added for maintainers.

## New Features

### Unified release workflow

- Added `.github/workflows/platform-release.yml`.
- Triggered by tags matching `v*`.
- Builds native artifacts for Linux, macOS, and Windows for both Rust and Zig.
- Publishes signed release metadata (`SHA256SUMS`, `SHA256SUMS.sig`, `SHA256SUMS.pem`).

### Cross-CLI version/build metadata

- Added shared version source via root `VERSION` (`major.minor`).
- Added version/build info outputs:
  - `mt.py version --json`
  - `mt-port version --json`
  - `mt-zig version --json`
- Added global version shortcuts on all CLIs:
  - `<cli>`
  - `<cli> -v`
  - `<cli> --version`

### Test parity improvements

- Expanded Python conformance tests to validate queue and core behavior across Python, Rust, and Zig binaries.
- Added/updated fixture expectations to remove stream-format fragility and improve cross-target consistency.
- Recorded cross-target parity snapshot and regeneration commands for future agents.

### Release packaging improvements

- Rust packaging now emits:
  - `.tar.gz` for Linux/macOS
  - `.zip` for Windows
- Zig packaging emits:
  - `.tar.gz` for Linux/macOS
  - `.zip` for Windows
- Verification scripts updated to accept signatures from per-port workflows and unified platform workflow.

## Documentation updates

- Added `RELEASE_CHECKLIST.md` for end-to-end release operations.
- Updated root and port READMEs for:
  - unified `v*` release flow,
  - expected artifact names,
  - verification commands and identity patterns.
- Added tools usage and parity/test guidance for future agents.

## Expected release assets

- `mt-rust-<arch>-<os>.tar.gz` (Linux/macOS)
- `mt-rust-<arch>-windows.zip` (Windows)
- `mt-zig-<arch>-<os>.tar.gz` (Linux/macOS)
- `mt-zig-<arch>-windows.zip` (Windows)
- `SHA256SUMS`
- `SHA256SUMS.sig`
- `SHA256SUMS.pem`

## Verification

```bash
shasum -a 256 -c SHA256SUMS
cosign verify-blob \
  --signature SHA256SUMS.sig \
  --certificate SHA256SUMS.pem \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/muonium-ai/muontickets/.github/workflows/(platform-release|rust-release|zig-release).yml@refs/(tags/(v.*|rust-v.*|zig-v.*)|heads/main)$' \
  SHA256SUMS
```
