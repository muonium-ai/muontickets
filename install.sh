#!/usr/bin/env bash
set -euo pipefail

# MuonTickets installer (Homebrew-style)
# Installs MuonTickets as a git submodule under:
#   tickets/mt/muontickets
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash
#
# Options:
#   bash -s -- --ref <branch_or_tag> --no-hooks --no-makefile
#
# Env vars (optional):
#   MUONTICKETS_REPO  - submodule repo URL
#   MUONTICKETS_REF   - branch/tag to checkout after add
#   INSTALL_HOOKS     - "1" (default) or "0"
#   PATCH_MAKEFILE    - "1" (default) or "0"

# ---------- defaults ----------
DEFAULT_REPO="${MUONTICKETS_REPO:-https://github.com/muonium-ai/muontickets.git}"
DEFAULT_REF="${MUONTICKETS_REF:-}"
INSTALL_HOOKS="${INSTALL_HOOKS:-1}"
PATCH_MAKEFILE="${PATCH_MAKEFILE:-1}"

REPO="$DEFAULT_REPO"
REF="$DEFAULT_REF"

TARGET_DIR="tickets/mt"
SUBMODULE_PATH="${TARGET_DIR}/muontickets"
MT_REL_PATH=""
HOOK_REL_PATH=""
SNIPPET_REL_PATH=""

# ---------- helpers ----------
say() { printf "\033[1;32m[muontickets]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[muontickets]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[muontickets]\033[0m %s\n" "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

in_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

resolve_layout_paths() {
  if [[ -f "${SUBMODULE_PATH}/mt.py" && -f "${SUBMODULE_PATH}/Makefile.snippet" && -f "${SUBMODULE_PATH}/hooks/pre-commit" ]]; then
    MT_REL_PATH="${SUBMODULE_PATH}/mt.py"
    HOOK_REL_PATH="${SUBMODULE_PATH}/hooks/pre-commit"
    SNIPPET_REL_PATH="${SUBMODULE_PATH}/Makefile.snippet"
    return 0
  fi

  if [[ -f "${SUBMODULE_PATH}/muontickets/mt.py" ]]; then
    MT_REL_PATH="${SUBMODULE_PATH}/muontickets/mt.py"
    HOOK_REL_PATH="${SUBMODULE_PATH}/muontickets/hooks/pre-commit"
    SNIPPET_REL_PATH="${SUBMODULE_PATH}/muontickets/Makefile.snippet"
    return 0
  fi

  warn "Could not detect MuonTickets layout under ${SUBMODULE_PATH}; expected mt.py in root or muontickets/"
  MT_REL_PATH="${SUBMODULE_PATH}/mt.py"
  HOOK_REL_PATH="${SUBMODULE_PATH}/hooks/pre-commit"
  SNIPPET_REL_PATH="${SUBMODULE_PATH}/Makefile.snippet"
  return 1
}

append_makefile_include() {
  local makefile="Makefile"
  if [[ ! -f "$makefile" ]]; then
    warn "No Makefile found. Skipping Makefile patch."
    return 0
  fi

  local inc_line="include ${SNIPPET_REL_PATH}"

  if grep -qF "$inc_line" "$makefile"; then
    say "Makefile already includes MuonTickets snippet."
    return 0
  fi

  cat >> "$makefile" <<EOF

# MuonTickets (agent ticketing)
$inc_line
EOF
  say "Patched Makefile to include MuonTickets snippet."
}

install_precommit_hook() {
  local hook_src="${HOOK_REL_PATH}"
  local hook_dst=".git/hooks/pre-commit"

  if [[ ! -f "$hook_src" ]]; then
    warn "Hook not found at $hook_src (maybe submodule not initialized yet). Skipping."
    return 0
  fi

  mkdir -p ".git/hooks"
  cp "$hook_src" "$hook_dst"
  chmod +x "$hook_dst"
  say "Installed pre-commit hook."
}

print_next_steps() {
  cat <<EOF

✅ MuonTickets installed.

Next steps:
  0) Create a virtual environment (uv):
    uv venv .venv

  1) Create/initialize ticket board:
    uv run python3 ${MT_REL_PATH} init

  2) Create a ticket:
    uv run python3 ${MT_REL_PATH} new "My first task" --type code --priority p1 --effort s --label core

  3) Agent picks work:
    uv run python3 ${MT_REL_PATH} pick --owner agent-1

  4) Validate anytime:
    uv run python3 ${MT_REL_PATH} validate

Make targets (if Makefile patched):
  make tickets-ready
  make tickets-pick OWNER=agent-1 LABEL=wasm
  make tickets-validate

EOF
}

# ---------- arg parsing ----------
NO_HOOKS=0
NO_MAKEFILE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:-}"; shift 2;;
    --ref)
      REF="${2:-}"; shift 2;;
    --no-hooks)
      NO_HOOKS=1; shift;;
    --no-makefile)
      NO_MAKEFILE=1; shift;;
    -h|--help)
      cat <<EOF
MuonTickets installer

Options:
  --repo <git_url>        MuonTickets git repo URL (default: https://github.com/muonium-ai/muontickets.git)
  --ref <branch_or_tag>   Checkout this ref after submodule add
  --no-hooks              Do not install pre-commit hook
  --no-makefile           Do not patch Makefile

Environment:
  MUONTICKETS_REPO, MUONTICKETS_REF, INSTALL_HOOKS, PATCH_MAKEFILE
EOF
      exit 0;;
    *)
      die "Unknown argument: $1";;
  esac
done

# ---------- checks ----------
need_cmd git
need_cmd mkdir

in_git_repo || die "Run this inside a Git repository (git init, or cd into one)."

if [[ -z "$REPO" ]]; then
  die "MuonTickets repo URL not set. Pass --repo <git_url> or set MUONTICKETS_REPO."
fi

# ---------- install ----------
say "Creating ${TARGET_DIR}/ ..."
mkdir -p "$TARGET_DIR"

if [[ -d "$SUBMODULE_PATH/.git" || -f "$SUBMODULE_PATH/.git" ]]; then
  warn "Submodule path already exists at $SUBMODULE_PATH"
else
  say "Adding MuonTickets as submodule at $SUBMODULE_PATH"
  git submodule add "$REPO" "$SUBMODULE_PATH"
fi

say "Initializing/updating submodules..."
git submodule update --init --recursive

if [[ -n "$REF" ]]; then
  say "Checking out ref '$REF' in submodule..."
  (
    cd "$SUBMODULE_PATH"
    git fetch --all --tags >/dev/null 2>&1 || true
    git checkout "$REF"
  )
fi

resolve_layout_paths || true

# Optional Makefile patch
if [[ "$NO_MAKEFILE" -eq 0 && "${PATCH_MAKEFILE}" != "0" ]]; then
  append_makefile_include
else
  warn "Skipping Makefile patch."
fi

# Optional hook install
if [[ "$NO_HOOKS" -eq 0 && "${INSTALL_HOOKS}" != "0" ]]; then
  install_precommit_hook
else
  warn "Skipping pre-commit hook install."
fi

print_next_steps
