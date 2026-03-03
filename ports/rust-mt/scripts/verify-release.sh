#!/usr/bin/env bash
set -euo pipefail

DIST_DIR=""

usage() {
  cat <<'EOF'
Verify Rust release artifacts using checksum and Sigstore keyless signatures.

Usage:
  scripts/verify-release.sh --dist <release-dir>

Example:
  scripts/verify-release.sh --dist dist
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist)
      [[ $# -ge 2 ]] || { echo "--dist requires value" >&2; exit 2; }
      DIST_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$DIST_DIR" ]] || { echo "--dist is required" >&2; usage >&2; exit 2; }
[[ -d "$DIST_DIR" ]] || { echo "dist directory not found: $DIST_DIR" >&2; exit 2; }

if ! command -v cosign >/dev/null 2>&1; then
  echo "cosign not found; install from https://docs.sigstore.dev/cosign/system_config/installation/" >&2
  exit 2
fi

(
  cd "$DIST_DIR"

  [[ -f SHA256SUMS ]] || { echo "missing SHA256SUMS" >&2; exit 2; }
  [[ -f SHA256SUMS.sig ]] || { echo "missing SHA256SUMS.sig" >&2; exit 2; }
  [[ -f SHA256SUMS.pem ]] || { echo "missing SHA256SUMS.pem" >&2; exit 2; }

  echo "==> Verifying checksums"
  shasum -a 256 -c SHA256SUMS

  echo "==> Verifying Sigstore signature/certificate identity"
  cosign verify-blob \
    --signature SHA256SUMS.sig \
    --certificate SHA256SUMS.pem \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github.com/muonium-ai/muontickets/.github/workflows/rust-release.yml@refs/(tags/rust-v.*|heads/main)$' \
    SHA256SUMS
)

echo "Release verification OK."
