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
Build release artifacts for mt-c across common targets.

Usage:
  scripts/release.sh [--targets target1,target2,...]

Examples:
  scripts/release.sh
  scripts/release.sh --targets native
  scripts/release.sh --targets aarch64-macos,x86_64-linux
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
rm -rf "$DIST_DIR"/mt-c-* "$DIST_DIR"/mt-c-*.tar.gz "$DIST_DIR"/mt-c-*.zip "$DIST_DIR"/SHA256SUMS

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

zig_target_for() {
  case "$1" in
    aarch64-macos) echo "aarch64-macos" ;;
    x86_64-macos) echo "x86_64-macos" ;;
    x86_64-linux) echo "x86_64-linux-gnu" ;;
    aarch64-linux) echo "aarch64-linux-gnu" ;;
    x86_64-windows) echo "x86_64-windows-gnu" ;;
    *) return 1 ;;
  esac
}

compile_native() {
  local out_bin="$1"
  cc -O2 -std=c11 -Wall -Wextra -Wpedantic -o "$out_bin" "$ROOT_DIR/src/main.c"
}

compile_cross() {
  local target="$1"
  local out_bin="$2"

  if ! command -v zig >/dev/null 2>&1; then
    echo "zig not found; cannot cross-compile $target" >&2
    return 1
  fi

  local zig_target
  zig_target="$(zig_target_for "$target")" || {
    echo "unsupported target: $target" >&2
    return 1
  }

  zig cc -O2 -std=c11 -Wall -Wextra -Wpedantic -target "$zig_target" -o "$out_bin" "$ROOT_DIR/src/main.c"
}

SUCCESS=()
FAILED=()

for target in "${TARGETS[@]}"; do
  echo "==> Building $target"

  pkg_target="$target"
  if [[ "$target" == "native" ]]; then
    pkg_target="$(native_label)"
  fi

  ext=""
  case "$target" in
    *windows*) ext=".exe" ;;
  esac

  pkg_name="mt-c-${pkg_target}"
  pkg_dir="$DIST_DIR/$pkg_name"
  out_bin="$pkg_dir/mt-c$ext"

  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"

  if [[ "$target" == "native" ]]; then
    if ! compile_native "$out_bin"; then
      echo "WARN: build failed for target '$target'" >&2
      FAILED+=("$target")
      continue
    fi
  else
    if ! compile_cross "$target" "$out_bin"; then
      echo "WARN: build failed for target '$target'" >&2
      FAILED+=("$target")
      continue
    fi
  fi

  chmod +x "$out_bin"
  cp "$ROOT_DIR/README.md" "$pkg_dir/README.md"

  if [[ "$target" == *windows* ]]; then
    (
      cd "$DIST_DIR"
      rm -f "$pkg_name.zip"
      if command -v zip >/dev/null 2>&1; then
        zip -q -r "$pkg_name.zip" "$pkg_name"
      else
        python3 - <<PY
import os
import zipfile
src = ${pkg_name@Q}
out = ${pkg_name@Q} + '.zip'
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(src):
        for name in files:
            abs_path = os.path.join(root, name)
            arc_name = os.path.relpath(abs_path, start=os.path.dirname(src))
            zf.write(abs_path, arcname=arc_name)
PY
      fi
    )
  else
    (
      cd "$DIST_DIR"
      rm -f "$pkg_name.tar.gz"
      tar -czf "$pkg_name.tar.gz" "$pkg_name"
    )
  fi

  SUCCESS+=("$target")
done

(
  cd "$DIST_DIR"
  rm -f SHA256SUMS

  checksum_file() {
    local artifact="$1"
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$artifact"
    elif command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$artifact"
    else
      local digest
      digest="$(openssl dgst -sha256 -r "$artifact" | awk '{print $1}')"
      printf '%s  %s\n' "$digest" "$artifact"
    fi
  }

  for artifact in *.tar.gz *.zip; do
    [[ -e "$artifact" ]] || continue
    checksum_file "$artifact" >> SHA256SUMS
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
