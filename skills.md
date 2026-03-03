# MuonTickets Skills Guide

This guide helps agents install and use MuonTickets consistently across repositories.

## Install Modes

### 1) Submodule install (default for most repos)

Use this when a product/application repository consumes MuonTickets:

```bash
curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash
```

Primary command path after install:

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py <command>
```

Common mistake in submodule mode:

```bash
# Wrong
uv run python3 muontickets/mt.py <command>

# Right
uv run python3 tickets/mt/muontickets/muontickets/mt.py <command>
```

### 2) Direct checkout (MuonTickets core development)

Use this only when you are working in the MuonTickets repository itself:

```bash
uv run python3 mt.py <command>
```

## Core Workflows

### Initialize board

```bash
# Submodule layout
uv run python3 tickets/mt/muontickets/muontickets/mt.py init

# Direct checkout
uv run python3 mt.py init
```

### Create ticket

```bash
# Submodule layout
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Implement feature X"

# Direct checkout
uv run python3 mt.py new "Implement feature X"
```

### Pick / claim work

```bash
# Pick best ready ticket for an agent
uv run python3 tickets/mt/muontickets/muontickets/mt.py pick --owner agent-1

# Claim a specific ticket
uv run python3 tickets/mt/muontickets/muontickets/mt.py claim T-000123 --owner agent-1
```

### Queue-style allocation (lease + retry)

```bash
# Allocate one task for an agent (default lease: 5 minutes)
uv run python3 tickets/mt/muontickets/muontickets/mt.py allocate-task --owner agent-1

# Allocate with filters
uv run python3 tickets/mt/muontickets/muontickets/mt.py allocate-task --owner agent-1 --priority p0 --type code --label backend

# Report failed attempt (increments retry_count and re-queues)
uv run python3 tickets/mt/muontickets/muontickets/mt.py fail-task T-000123 --error "build failed"

# On retry-limit exhaustion, ticket is moved to tickets/errors/ for manual resolution
```

### Queue operator procedure

```bash
# 1) Allocate work
uv run python3 tickets/mt/muontickets/muontickets/mt.py allocate-task --owner agent-1

# 2) While executing, post progress
uv run python3 tickets/mt/muontickets/muontickets/mt.py comment T-000123 "step completed"

# 3a) Success path
uv run python3 tickets/mt/muontickets/muontickets/mt.py set-status T-000123 needs_review
uv run python3 tickets/mt/muontickets/muontickets/mt.py done T-000123

# 3b) Failure path (retry)
uv run python3 tickets/mt/muontickets/muontickets/mt.py fail-task T-000123 --error "test failure"

# 4) Triage exhausted retries
uv run python3 tickets/mt/muontickets/muontickets/mt.py ls --status blocked
uv run python3 tickets/mt/muontickets/muontickets/mt.py report --search T-000123
```

### Comment progress

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py comment T-000123 "Implemented parser and tests"
```

### Status transitions

```bash
# ready -> claimed
uv run python3 tickets/mt/muontickets/muontickets/mt.py claim T-000123 --owner agent-1

# claimed -> needs_review
uv run python3 tickets/mt/muontickets/muontickets/mt.py set-status T-000123 needs_review

# needs_review -> done
uv run python3 tickets/mt/muontickets/muontickets/mt.py done T-000123
```

### Validate board

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

### Archive completed ticket

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py archive T-000123
```

## Best Practices for Agents

- CLI-first workflow: do not directly edit ticket files for normal operations; use `mt.py` (`claim`, `set-status`, `comment`, `done`, `archive`) so validation and transition rules are enforced.
- PR/commit isolation: keep each ticket fix in a separate git commit and a separate pull request whenever possible.
- Worktree isolation: when available, run parallel agents in separate git worktrees to prevent branch/index/temp-file collisions.
- Branch discipline: use branch-per-agent and avoid direct development on `main`/`master`.
- Integration discipline: prefer pull-request-based merges instead of direct commits to protected/default branches.
- Parallelization rule: if tickets are independent and can be completed by isolated agents without impacting shared system behavior, assign multiple agents to run in parallel.
- Temp artifact hygiene: use project-local `tmp/<agent-name>/` for scratch/build artifacts (avoid global `/tmp` assumptions in sandboxed environments).
- Dependency handling: respect `depends_on`; do not start dependent work until prerequisites are done unless explicitly instructed.
- Queue lease handling: allocated tickets have a lease window (default 5 minutes); expired leases may be reallocated and incident-logged.
- Retry handling: use `fail-task` to record execution errors; when retry limit is reached, investigate `tickets/errors/` and `tickets/incidents.log`.
- Build hygiene: prefer Makefile targets where possible; use `make clean` as the standard cleanup step for project temp state.
- Test order: run a basic smoke test first, then broader suites, to surface breakage early and reduce CI churn.
- Validation cadence: run `mt validate` before commit/push and after ticket metadata updates.
- Ownership hygiene: always set clear owner and branch when claiming; avoid multiple active claims unless team policy allows it.
- Status discipline: use the normal flow (`ready -> claimed -> needs_review -> done`) and avoid force transitions unless a human asks.
- Ticket quality: keep goals and acceptance criteria concrete so another agent can continue with minimal context loss.

## Template-first ticket creation

- MuonTickets supports `tickets/ticket.template` for default ticket shape.
- `mt new` uses template defaults when present.
- CLI arguments override template defaults for one-off needs.
- `mt init` creates `tickets/ticket.template` only if missing; existing templates are preserved.

Example customization flow:

```bash
# 1) Set project defaults in tickets/ticket.template
#    (example: priority: p2, type: docs, effort: xs)

# 2) Create ticket inheriting template defaults
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Write onboarding notes"

# 3) Override defaults for one ticket only
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Hotfix auth" --priority p0 --type code --effort s
```
