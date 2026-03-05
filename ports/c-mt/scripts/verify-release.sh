#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

usage() {
  cat <<'EOF'
Verify release artifacts and SHA256SUMS for mt-c.

Usage:
  scripts/verify-release.sh [--dist PATH]
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

if [[ ! -f "$DIST_DIR/SHA256SUMS" ]]; then
  echo "missing checksum file: $DIST_DIR/SHA256SUMS" >&2
  exit 1
fi

cd "$DIST_DIR"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 -c SHA256SUMS
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c SHA256SUMS
else
  echo "no checksum verifier found (need shasum or sha256sum)" >&2
  exit 1
fi

echo "Checksum verification complete."
