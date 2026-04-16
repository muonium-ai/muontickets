# muontickets
file based ticketing system for agents, resides under the tickets folder

## Install

Recommended for product/application repos: install MuonTickets as a git submodule.

```bash
curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash
```

If you need a custom source repo for the submodule:

```bash
curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash -s -- --repo https://github.com/muonium-ai/muontickets.git
```

Template form for your own fork:

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/install.sh | bash -s -- --repo https://github.com/<org>/<repo>.git
```

Use direct checkout (this repository itself) only when developing MuonTickets core.

### Install MuonTickets as a git submodule in a new project

From your new project's root:

```bash
git init
git submodule add https://github.com/muonium-ai/muontickets.git tickets/mt/muontickets
git submodule update --init --recursive
uv sync
uv run python3 tickets/mt/muontickets/muontickets/mt.py init
```

Commit submodule onboarding files:

```bash
git add .gitmodules tickets/mt/muontickets tickets/
git commit -m "Add MuonTickets submodule and initialize board"
```

## Quickstart (uv)

For repos where MuonTickets is installed as submodule:

```bash
uv sync
uv run python3 tickets/mt/muontickets/muontickets/mt.py init
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

### Common path mistake (submodule mode)

Wrong (installs/runs from the wrong location):

```bash
uv run python3 muontickets/mt.py init
```

Right (submodule under tickets/mt):

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py init
```

If you are in a direct MuonTickets checkout, use the root entrypoint:

```bash
uv run python3 mt.py --help
uv run python3 mt.py report --summary
```

### Copy-paste: submodule + agent template workflow

Use this path when onboarding a fresh project and creating agent-ready tickets from template defaults:

```bash
# 1) Install as submodule
git submodule add https://github.com/muonium-ai/muontickets.git tickets/mt/muontickets
git submodule update --init --recursive

# 2) Initialize board and template
uv sync
uv run python3 tickets/mt/muontickets/muontickets/mt.py init

# 3) Optional: seed team playbook from shipped snippets
cp tickets/mt/muontickets/muontickets/ticket.template tickets/ticket.template
cp tickets/mt/muontickets/muontickets/agents.snippet docs/AGENTS.md

# 4) Create and assign agent tickets from template defaults
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Implement feature X" --label backend
uv run python3 tickets/mt/muontickets/muontickets/mt.py claim T-000001 --owner agent-a
```

## Version and Build Info (Bug Reports)

MuonTickets now uses the project-root `VERSION` file (`major.minor`) as the source of CLI version output.

Use these commands when filing bug reports from the field:

```bash
# Python reference CLI
uv run python3 mt.py version --json

# Rust port (build from source)
ports/rust-mt/target/release/mt-port version --json

# Zig port (build from source)
ports/zig-mt/zig-out/bin/mt-zig version --json
```

Conventional global shortcuts are also supported:

```bash
uv run python3 mt.py
uv run python3 mt.py -v
uv run python3 mt.py --version

ports/rust-mt/target/release/mt-port
ports/rust-mt/target/release/mt-port -v
ports/rust-mt/target/release/mt-port --version

ports/zig-mt/zig-out/bin/mt-zig
ports/zig-mt/zig-out/bin/mt-zig -v
ports/zig-mt/zig-out/bin/mt-zig --version
```

Each command emits parseable build info (implementation + semantic version + toolchain versions) to make reports reproducible.

## For Agents: Ticket Workflow

Agent quick-reference guide: see [skills.md](skills.md) for install modes, command workflows, and best practices.

Developer utility scripts (benchmarks, conformance compare, ticket seeders): see [tools/USAGE.md](tools/USAGE.md).

Troubleshooting rule: do not edit files under `tickets/` directly for normal workflow actions (claim/status/comments/archive). Always use `mt.py` commands so transition checks, dependency checks, and metadata updates are applied consistently.

Execution guidance:

- Prefer one ticket fix per git commit and one pull request per ticket to keep reviews, rollback, and traceability clean.
- When tickets are isolated (no shared files, no dependency coupling, no system-wide side effects), run multiple agents in parallel. Parallel independent execution is a core MuonTickets use case.
- Prefer git worktrees for parallel agent isolation where available (one worktree per agent) to avoid clobbering local state.
- Use a branch-per-agent workflow and avoid direct development on `main`/`master`.
- Integrate via pull requests instead of direct commits to protected/default branches.

### Sandbox-safe multi-agent workspace

- Keep transient artifacts under project-local `tmp/` (not `/tmp`) to reduce sandbox/path permission issues.
- Use per-agent subfolders such as `tmp/agent-a/`, `tmp/agent-b/` for generated scratch files.
- `tmp/` is ignored in git except `tmp/.gitkeep`, so the convention is available without polluting commits.
- Prefer Makefile targets for build/test workflows where available, and include `make clean` as standard cleanup for project temp state.
- Run a basic smoke test first (before full test suites) to catch breakage early and shorten feedback loops.

Run these from the project root where MuonTickets is installed.

```bash
# 1) Pull latest board state
git pull

# 2) Pick the best ready ticket and claim it
uv run python3 tickets/mt/muontickets/muontickets/mt.py pick --owner agent-1

# 3) Inspect your claimed ticket(s)
uv run python3 tickets/mt/muontickets/muontickets/mt.py ls --status claimed --owner agent-1

# 4) Add progress updates while implementing
uv run python3 tickets/mt/muontickets/muontickets/mt.py comment T-000001 "Implemented parser and added tests"

# 5) Move ticket to review when done coding
uv run python3 tickets/mt/muontickets/muontickets/mt.py set-status T-000001 needs_review

# 6) Validate board consistency before commit/push
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

After merge, mark the ticket complete:

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py done T-000001
```

## Archive, Backlogs, and Ticket IDs

- Active tickets live in `tickets/`.
- Completed tickets can be moved to `tickets/archived/` using `mt archive`.
- `mt archive` refuses to move a ticket if active tickets still reference it in `depends_on` (unless `--force`).
- `mt validate` reports `depends_on archived ticket ...` when an active ticket depends on an archived ticket.
- Future/planned work can live in `tickets/backlogs/`.
- Ticket numbering is tracked in `tickets/last_ticket_id`.
- If `tickets/last_ticket_id` is missing, `mt` automatically rebuilds the next number by scanning ticket IDs across `tickets/`, `tickets/archived/`, and `tickets/backlogs/`.

## Ticket Template (`tickets/ticket.template`)

- On first install and on `mt init`, MuonTickets creates `tickets/ticket.template` if it does not already exist.
- Users can edit this file to set default ticket metadata/body preferences.
- `mt new "Title"` uses template defaults when available.
- CLI args override template values when provided (for example: `--priority`, `--type`, `--effort`, `--label`, `--tag`, `--depends-on`, `--goal`).
- Existing `tickets/ticket.template` files are never overwritten by installer/init.
- `created` and `updated` metadata are timestamp-based (`YYYY-MM-DDTHH:MM:SSZ`).
- Queue/runtime fields are supported in template defaults: `retry_count`, `retry_limit`, `allocated_to`, `allocated_at`, `lease_expires_at`, `last_error`, `last_attempted_at`.

Examples:

```bash
# Edit defaults in tickets/ticket.template (for example: priority: p2, type: docs, effort: xs)

# Create ticket with sequence from tickets/last_ticket_id
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Implement feature X"

# Override template defaults for one ticket
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Hotfix auth" --priority p0 --type code --effort xs --label urgent --goal "Fix login regression"

# Archive a completed ticket
uv run python3 tickets/mt/muontickets/muontickets/mt.py archive T-000001
```

### Agent setup using ticket templates

Use the shipped snippets to standardize agent onboarding in your project:

```bash
# optional: start from MuonTickets defaults
cp tickets/mt/muontickets/muontickets/ticket.template tickets/ticket.template

# optional: copy agent playbook snippet into your team docs
cp tickets/mt/muontickets/muontickets/agents.snippet docs/AGENTS.md
```

Create tickets from template defaults, then assign to agents:

```bash
# create tickets with template defaults
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Implement auth middleware" --label backend --tag sprint-1
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Add API contract tests" --type tests --label qa --depends-on T-000001

# claim tickets for specific agents
uv run python3 tickets/mt/muontickets/muontickets/mt.py claim T-000001 --owner agent-a
uv run python3 tickets/mt/muontickets/muontickets/mt.py claim T-000002 --owner agent-b

# validate board before agents start work
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

## Autonomous Maintenance (`mt maintain`)

MuonTickets includes a built-in maintenance taxonomy of 150 rules across 9 categories (security, deps, code-health, performance, database, infrastructure, observability, testing, docs). The `maintain` command provides a **scan-first, create-later** workflow: verify issues exist before creating tickets that trigger CI/CD cycles.

Reference taxonomy: [docs/muonium_autonomous_maintenance_rules.md](docs/muonium_autonomous_maintenance_rules.md).
External tools setup: [docs/maintenance_tools_setup.md](docs/maintenance_tools_setup.md).

Subcommands: `init-config`, `doctor`, `list`, `scan`, `create`.

### Setup (`mt maintain init-config` / `doctor`)

```bash
# Generate default config (all tools disabled)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain init-config

# Auto-detect project stack and pre-enable matching tools
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain init-config --detect

# Verify all enabled tools are installed and on PATH
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain doctor
```

`init-config --detect` scans for `pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, `Dockerfile`, etc. and generates a `tickets/maintain.yaml` with the right tools pre-enabled for your stack.

`doctor` checks that every tool enabled in `maintain.yaml` is reachable on `$PATH`, reporting `[OK]` or `[MISS]` per tool.

### Browse the taxonomy (`mt maintain list`)

```bash
# List all 150 maintenance rules with detection heuristics
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain list

# Filter by category
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain list --category security

# Filter by specific rule numbers
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain list --rule 2 --rule 48
```

### Scan for issues (`mt maintain scan`)

Scan the codebase against maintenance rules. Reports PASS/FAIL/SKIP per rule. **No tickets created.** Invokes both built-in scanners and external tools configured in `tickets/maintain.yaml`.

```bash
# Scan security rules
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --category security

# Scan all categories at once
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all

# Use a profile preset (ci: security+code-health+testing, nightly: all)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --profile ci

# Scan specific rules
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --rule 2 --rule 42 --rule 48

# JSON output for agent/LLM consumption
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --category code-health --format json

# Show only new findings since last scan
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all --diff

# Auto-fix issues where tools support it (e.g. cargo fmt, black)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --category code-health --fix
```

Built-in scanners detect: exposed secrets, hardcoded passwords, .env tracked in git, large files (>1000 lines), excessive TODOs, container running as root, broken doc links, stale README. Rules without built-in scanners use configured external tools from `maintain.yaml`, or report SKIP if unconfigured.

Exit codes: `0` = all pass, `1` = findings detected, `2` = config/argument error.

### Create tickets for verified issues (`mt maintain create`)

Scans first, then creates tickets **only for rules with findings**. Rules that pass scanning are skipped. Ticket bodies include actual findings (file paths, line numbers) so fixing agents have full context.

```bash
# Scan + create tickets for failures and suggestions
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain create --category security

# Create for all categories
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain create --all

# Preview without creating
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain create --category docs --dry-run

# Override priority, pre-assign to maintenance agent
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain create --category deps --priority p0 --owner agent-maint

# Skip scanning -- create suggestion tickets for all rules (legacy behavior)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain create --category testing --skip-scan
```

### Configuration (`tickets/maintain.yaml`)

External tools are configured in `tickets/maintain.yaml`. Each tool can have:
- `enabled: true/false` — whether to invoke during scan
- `command:` — the shell command to run (`{repo}` is replaced with repo root)
- `timeout:` — per-tool timeout in seconds (overrides the global `settings.timeout`)
- `fix_command:` — auto-fix command used with `mt maintain scan --fix`

### Deduplication

Running `mt maintain create` multiple times is safe. Each ticket is tagged `maint-rule-{id}`. Rules with existing open tickets are skipped.

### Scan profiles

| Profile | Categories | Use case |
|---------|-----------|----------|
| `ci` | security, code-health, testing | Fast checks for CI pipelines |
| `nightly` | all 9 categories | Comprehensive nightly scans |

### Scan diffing

`--diff` compares the current scan against `tickets/maintain.last.json` and shows only new findings. This is stored automatically after each scan.

### Agent maintenance loop

```bash
# 1) Setup: generate config matching your stack
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain init-config --detect

# 2) Verify tools are installed
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain doctor

# 3) Scan for issues (CI cron or lightweight agent)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all --format json

# 4) Create tickets only for verified failures
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain create --all

# 5) Agents pick up maintenance work
uv run python3 tickets/mt/muontickets/muontickets/mt.py pick --owner agent-maint-1 --label auto-maintenance

# 6) After fix + merge
uv run python3 tickets/mt/muontickets/muontickets/mt.py done T-000042

# 7) Next scan shows only new findings (dedup + diff)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all --diff
```

Generated tickets carry:
- Label: `auto-maintenance` (filterable via `mt ls --label auto-maintenance`)
- Tags: `maint-rule-{id}`, `maint-cat-{category}`
- Title prefix: `[MAINT-NNN]`
- Body includes actual findings (file paths, line numbers) when scanner detected the issue
- Logging: all tool invocations are logged to `tickets/maintain.log`

## Reporting (SQLite)

Generate a local SQLite report database (not committed):

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py report --summary
```

Run with search:

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py report --search auth --limit 20
```

By default this creates `tickets/tickets_report.sqlite3` and indexes ticket data from `tickets/`, `tickets/archived/`, `tickets/errors/`, and `tickets/backlogs/`.

## Binary Releases (Preview)

Unified multi-platform release (Rust + Zig + C together):

```bash
# Push a tag like v0.9.0 to build Linux/macOS/Windows native artifacts
git tag v0.9.0
git push origin v0.9.0
```

This triggers `.github/workflows/combined-release.yml` and publishes release assets for all implementations:

- `mt-rust-<arch>-<os>.tar.gz` (Linux/macOS)
- `mt-rust-<arch>-windows.zip` (Windows)
- `mt-zig-<arch>-<os>.tar.gz` (Linux/macOS)
- `mt-zig-<arch>-windows.zip` (Windows)
- `mt-c-<arch>-<os>.tar.gz` (Linux/macOS)
- `mt-c-<arch>-windows.zip` (Windows)
- `SHA256SUMS`, `SHA256SUMS.sig`, `SHA256SUMS.pem`

Detailed operator runbook: see [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

Package-manager path (Cargo):

```bash
# install from source checkout
cd ports/rust-mt
cargo install --path .
```

Direct binary download path (GitHub Releases):

```bash
# macOS/Linux example (replace tag and artifact name as needed)
curl -L -o mt-rust.tar.gz https://github.com/muonium-ai/muontickets/releases/download/vX.Y.Z/mt-rust-<arch>-<os>.tar.gz
tar -xzf mt-rust.tar.gz
```

```powershell
# Windows PowerShell example
Invoke-WebRequest -Uri "https://github.com/muonium-ai/muontickets/releases/download/vX.Y.Z/mt-rust-<arch>-windows.zip" -OutFile "mt-rust.zip"
Expand-Archive -Path "mt-rust.zip" -DestinationPath "."
```

Release integrity verification:

```bash
shasum -a 256 -c SHA256SUMS
cosign verify-blob --signature SHA256SUMS.sig --certificate SHA256SUMS.pem --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp '^https://github.com/muonium-ai/muontickets/.github/workflows/(combined-release|rust-release|zig-release).yml@refs/(tags/(v.*|rust-v.*|zig-v.*)|heads/main)$' SHA256SUMS
```

## Changelog Process

- User-visible changes must include an entry in `CHANGELOG.md`.
- Use this format per entry: `YYYY-MM-DD | Type | Summary`.
- Keep entries descriptive enough to trace feature/fix intent without internal ticket IDs.
- Add changelog updates in the same PR/commit as the code/docs change.
