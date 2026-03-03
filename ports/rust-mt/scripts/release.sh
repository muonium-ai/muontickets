#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

TARGETS=("native")

usage() {
  cat <<'EOF'
Build Rust mt release artifacts across targets.

Usage:
  scripts/release.sh [--targets target1,target2,...]

Examples:
  scripts/release.sh
  scripts/release.sh --targets native
  scripts/release.sh --targets x86_64-unknown-linux-gnu,aarch64-apple-darwin
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)
      [[ $# -ge 2 ]] || { echo "--targets requires value" >&2; exit 2; }
      IFS=',' read -r -a TARGETS <<< "$2"
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

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR"/mt-rust-* "$DIST_DIR"/SHA256SUMS

native_label() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m | tr '[:upper:]' '[:lower:]')"

  case "$os" in
    darwin) os="macos" ;;
    mingw*|msys*|cygwin*) os="windows" ;;
  esac

  case "$arch" in
    arm64) arch="aarch64" ;;
    amd64) arch="x86_64" ;;
  esac

  echo "${arch}-${os}"
}

SUCCESS=()
FAILED=()

for target in "${TARGETS[@]}"; do
  echo "==> Building $target"
  if [[ "$target" == "native" ]]; then
    if ! (cd "$ROOT_DIR" && cargo build --release); then
      echo "WARN: build failed for target '$target'" >&2
      FAILED+=("$target")
      continue
    fi
  else
    if ! (cd "$ROOT_DIR" && cargo build --release --target "$target"); then
      echo "WARN: build failed for target '$target'" >&2
      FAILED+=("$target")
      continue
    fi
  fi

  SUCCESS+=("$target")

  pkg_target="$target"
  ext=""
  bin_path=""

  if [[ "$target" == "native" ]]; then
    pkg_target="$(native_label)"
    case "$pkg_target" in
      *-windows) ext=".exe" ;;
    esac
    bin_path="$ROOT_DIR/target/release/mt-port$ext"
  else
    case "$target" in
      *windows*) ext=".exe" ;;
    esac
    bin_path="$ROOT_DIR/target/$target/release/mt-port$ext"
  fi

  if [[ ! -f "$bin_path" ]]; then
    echo "expected binary not found: $bin_path" >&2
    exit 1
  fi

  pkg_name="mt-rust-${pkg_target}"
  pkg_dir="$DIST_DIR/$pkg_name"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"

  cp "$bin_path" "$pkg_dir/mt$ext"
  cp "$ROOT_DIR/README.md" "$pkg_dir/README.md"

  (
    cd "$DIST_DIR"
    rm -f "$pkg_name.tar.gz"
    tar -czf "$pkg_name.tar.gz" "$pkg_name"
  )
done

(
  cd "$DIST_DIR"
  rm -f SHA256SUMS
  for artifact in *.tar.gz; do
    [[ -e "$artifact" ]] || continue
    shasum -a 256 "$artifact" >> SHA256SUMS
  done
)

echo "Artifacts written to: $DIST_DIR"
ls -1 "$DIST_DIR"

echo

echo "Successful targets: ${SUCCESS[*]:-none}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Failed targets: ${FAILED[*]}"
fi

if [[ ${#SUCCESS[@]} -eq 0 ]]; then
  echo "No artifacts were produced." >&2
  exit 1
fi
