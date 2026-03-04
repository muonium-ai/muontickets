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
rm -rf "$DIST_DIR"/mt-rust-* "$DIST_DIR"/mt-rust-*.tar.gz "$DIST_DIR"/mt-rust-*.zip "$DIST_DIR"/SHA256SUMS

create_zip() {
  local src_dir="$1"
  local out_zip="$2"

  if command -v zip >/dev/null 2>&1; then
    zip -q -r "$out_zip" "$src_dir"
    return 0
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Compress-Archive -Path '$src_dir' -DestinationPath '$out_zip' -Force" >/dev/null
    return 0
  fi

  local py_cmd=""
  if command -v python3 >/dev/null 2>&1; then
    py_cmd="python3"
  elif command -v python >/dev/null 2>&1; then
    py_cmd="python"
  fi

  if [[ -n "$py_cmd" ]]; then
    "$py_cmd" - <<PY
import os
import zipfile

src_dir = ${src_dir@Q}
out_zip = ${out_zip@Q}

with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(src_dir):
        for name in files:
            abs_path = os.path.join(root, name)
            arc_name = os.path.relpath(abs_path, start=os.path.dirname(src_dir))
            zf.write(abs_path, arcname=arc_name)
PY
    return 0
  fi

  echo "no zip-capable tool found (zip, powershell.exe, python3/python)" >&2
  return 1
}

append_sha256sum() {
  local artifact="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$artifact" >> SHA256SUMS
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$artifact" >> SHA256SUMS
    return 0
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "$h=(Get-FileHash -Algorithm SHA256 -Path '${artifact}').Hash.ToLower(); Write-Output \"$h  ${artifact}\"" >> SHA256SUMS
    return 0
  fi

  echo "no SHA256 tool found (shasum, sha256sum, powershell.exe)" >&2
  return 1
}

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

  if [[ "$target" == *windows* || "$pkg_target" == *-windows ]]; then
    (
      cd "$DIST_DIR"
      rm -f "$pkg_name.zip"
      create_zip "$pkg_name" "$pkg_name.zip"
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
    append_sha256sum "$artifact"
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
