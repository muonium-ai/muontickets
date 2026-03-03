#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Verify mt-zig release artifacts using checksums + Sigstore certificate identity.

Usage:
  scripts/verify-release.sh --dist <dir>

Expected files in <dir>:
  - SHA256SUMS
  - SHA256SUMS.sig
  - SHA256SUMS.pem
  - one or more mt-zig-*.tar.gz / mt-zig-*.zip artifacts

Example:
  scripts/verify-release.sh --dist dist
EOF
}

DIST_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist)
      [[ $# -ge 2 ]] || { echo "--dist requires a value" >&2; exit 2; }
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

[[ -n "$DIST_DIR" ]] || { usage >&2; exit 2; }
[[ -d "$DIST_DIR" ]] || { echo "dist directory not found: $DIST_DIR" >&2; exit 2; }

command -v cosign >/dev/null 2>&1 || {
  echo "cosign is required for Sigstore verification: https://docs.sigstore.dev/cosign/system_config/installation/" >&2
  exit 2
}

for required in SHA256SUMS SHA256SUMS.sig SHA256SUMS.pem; do
  [[ -f "$DIST_DIR/$required" ]] || { echo "missing required file: $DIST_DIR/$required" >&2; exit 2; }
done

(
  cd "$DIST_DIR"
  shopt -s nullglob
  artifacts=(mt-zig-*.tar.gz mt-zig-*.zip)
  if [[ ${#artifacts[@]} -eq 0 ]]; then
    echo "no mt-zig artifacts found in $DIST_DIR" >&2
    exit 2
  fi

  echo "==> Verifying archive checksums"
  shasum -a 256 -c SHA256SUMS

  echo "==> Verifying Sigstore signature identity"
  cosign verify-blob \
    --signature SHA256SUMS.sig \
    --certificate SHA256SUMS.pem \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github.com/muonium-ai/muontickets/.github/workflows/zig-release.yml@refs/(tags/zig-v.*|heads/main)$' \
    SHA256SUMS
)

echo "Release verification OK"
