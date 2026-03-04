# Release Checklist (Unified Rust + Zig)

This checklist is for publishing a combined multi-platform release from this repository.

## Scope

Trigger: push a tag matching `v*` (example `v0.9.0`).

Workflow: `.github/workflows/combined-release.yml`

Outputs (GitHub Release assets):

- `mt-rust-<arch>-<os>.tar.gz` (Linux/macOS)
- `mt-rust-<arch>-windows.zip` (Windows)
- `mt-zig-<arch>-<os>.tar.gz` (Linux/macOS)
- `mt-zig-<arch>-windows.zip` (Windows)
- `SHA256SUMS`, `SHA256SUMS.sig`, `SHA256SUMS.pem`

## 1) Pre-release checks

Run from repo root:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
.venv/bin/python mt.py validate
```

Optional parity smoke matrix:

```bash
.venv/bin/python -m unittest tests.test_conformance_runner
```

Confirm working tree is clean:

```bash
git status --short
```

## 2) Create and push release tag

```bash
git pull --ff-only
git tag v0.9.0
git push origin v0.9.0
```

## 3) Monitor release workflow

In GitHub Actions:

- Wait for `.github/workflows/combined-release.yml` jobs:
  - `build-rust` matrix (Linux/macOS/Windows)
  - `build-zig` matrix (Linux/macOS/Windows)
  - `publish`

Release should appear under GitHub Releases for tag `v0.9.0`.

## 4) Verify release assets locally

Download release assets into a directory and run:

```bash
shasum -a 256 -c SHA256SUMS
cosign verify-blob \
  --signature SHA256SUMS.sig \
  --certificate SHA256SUMS.pem \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/muonium-ai/muontickets/.github/workflows/combined-release.yml@refs/tags/v.*$' \
  SHA256SUMS
```

## 5) Quick binary smoke checks

### macOS/Linux

```bash
tar -xzf mt-rust-<arch>-<os>.tar.gz
./mt-rust-<arch>-<os>/mt --version

tar -xzf mt-zig-<arch>-<os>.tar.gz
./mt-zig-<arch>-<os>/mt-zig --version
```

### Windows (PowerShell)

```powershell
Expand-Archive -Path mt-rust-<arch>-windows.zip -DestinationPath .
.\mt-rust-<arch>-windows\mt.exe --version

Expand-Archive -Path mt-zig-<arch>-windows.zip -DestinationPath .
.\mt-zig-<arch>-windows\mt-zig.exe --version
```

## 6) Roll-forward/rollback notes

- If a release is wrong, prefer publishing a new patch tag (`v0.9.1`) rather than replacing assets.
- If absolutely required, delete the GitHub Release and tag, then recreate with a new run.
