#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

TARGETS=(
  "native"
  "aarch64-macos"
  "x86_64-macos"
  "x86_64-linux"
  "aarch64-linux"
  "x86_64-windows"
)

usage() {
  cat <<'EOF'
Build release artifacts for mt-zig across common targets.

Usage:
  scripts/release.sh [--targets target1,target2,...] [--optimize ReleaseSafe|ReleaseFast|ReleaseSmall]

Default optimize mode is ReleaseSafe.

Examples:
  scripts/release.sh
  scripts/release.sh --targets aarch64-macos,x86_64-linux
  scripts/release.sh --optimize ReleaseFast
EOF
}

OPTIMIZE="ReleaseSafe"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)
      [[ $# -ge 2 ]] || { echo "--targets requires value" >&2; exit 2; }
      IFS=',' read -r -a TARGETS <<< "$2"
      shift 2
      ;;
    --optimize)
      [[ $# -ge 2 ]] || { echo "--optimize requires value" >&2; exit 2; }
      OPTIMIZE="$2"
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
rm -rf "$DIST_DIR"/mt-zig-* "$DIST_DIR"/mt-zig-*.tar.gz "$DIST_DIR"/mt-zig-*.zip "$DIST_DIR"/SHA256SUMS

SUCCESS=()
FAILED=()

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

for target in "${TARGETS[@]}"; do
  echo "==> Building $target ($OPTIMIZE)"
  if (
    cd "$ROOT_DIR"
    if [[ "$target" == "native" ]]; then
      zig build -Doptimize="$OPTIMIZE"
    else
      zig build -Dtarget="$target" -Doptimize="$OPTIMIZE"
    fi
  ); then
    SUCCESS+=("$target")
  else
    echo "WARN: build failed for target '$target' (often due to missing target sqlite3/libc sysroot)."
    FAILED+=("$target")
    continue
  fi

  ext=""
  case "$target" in
    *-windows) ext=".exe" ;;
  esac

  src_bin="$ROOT_DIR/zig-out/bin/mt-zig$ext"
  if [[ ! -f "$src_bin" ]]; then
    echo "expected binary not found: $src_bin" >&2
    exit 1
  fi

  pkg_target="$target"
  if [[ "$target" == "native" ]]; then
    pkg_target="$(native_label)"
  fi

  pkg_name="mt-zig-${pkg_target}"
  pkg_dir="$DIST_DIR/$pkg_name"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"

  cp "$src_bin" "$pkg_dir/mt-zig$ext"
  cp "$ROOT_DIR/README.md" "$pkg_dir/README.md"

  if [[ "$target" == *-windows ]]; then
    (
      cd "$DIST_DIR"
      rm -f "$pkg_name.zip"
      zip -q -r "$pkg_name.zip" "$pkg_name"
    )
  else
    (
      cd "$DIST_DIR"
      rm -f "$pkg_name.tar.gz"
      tar -czf "$pkg_name.tar.gz" "$pkg_name"
    )
  fi

done

(
  cd "$DIST_DIR"
  rm -f SHA256SUMS
  for artifact in *.tar.gz *.zip; do
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
