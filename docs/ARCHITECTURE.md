# MuonTickets Architecture

## Overview

MuonTickets is a Git-native, file-based ticketing system designed for coordinating agent swarms. Rather than relying on external databases or centralized servers, it uses Git as the coordination substrate — storing tickets as Markdown files with YAML frontmatter in the `tickets/` directory.

**Core philosophy:**
- Git is already a distributed, offline-first coordination substrate with rich history, diff, and blame capabilities
- Tickets as files provide diff visibility, PR review integration, grep searchability, and full reproducibility
- Agents scale when coordination is lightweight and deterministic

---

## Directory Structure

```
muontickets/
├── muontickets/             # Core Python CLI implementation
│   ├── mt.py                # Main CLI (~3900 lines, single file)
│   ├── schema.json          # JSON Schema for ticket validation
│   ├── ticket.template      # Default ticket template
│   └── hooks/
│       └── pre-commit       # Git hook for ticket validation
├── ports/                   # Non-Python language ports
│   ├── rust-mt/             # Rust port
│   ├── zig-mt/              # Zig port
│   └── c-mt/                # C port
├── tests/                   # Test suite
├── tools/                   # Benchmarks and stress test utilities
├── docs/                    # Documentation
├── tickets/                 # Active board (Git-tracked)
│   ├── .mt.lock             # Inter-process file lock
│   ├── incidents.log        # Append-only event log
│   ├── last_ticket_id       # Sequential ID counter
│   ├── ticket.template      # Project-specific ticket defaults
│   ├── archive/             # Completed tickets (moved here after done)
│   ├── backlogs/            # Planned/future work not yet active
│   └── errors/              # Dead-letter queue for exhausted retries
├── mt.py                    # Root CLI entry point (delegates to muontickets/mt.py)
├── VERSION                  # Semantic version (major.minor.patch)
├── pyproject.toml           # Python project metadata
└── Makefile                 # Build and test targets
```

---

## Ticket Format

Each ticket is a Markdown file named `T-XXXXXX.md` (zero-padded 6-digit ID) stored in `tickets/`.

**YAML frontmatter + Markdown body:**

```yaml
---
id: T-000001
title: "Feature: implement X"
status: ready                      # ready|claimed|blocked|needs_review|done
priority: p1                       # p0|p1|p2
type: code                         # spec|code|tests|docs|refactor|chore
effort: m                          # xs|s|m|l|xl|xxl
labels: [backend, urgent]
owner: null                        # agent ID or null
branch: null
created: 2026-03-01T12:00:00Z
updated: 2026-03-01T12:00:00Z
depends_on: []
# Queue-mode fields (optional):
retry_count: 0
retry_limit: 3
allocated_to: null
lease_expires_at: null
last_error: null
---

## Goal
...

## Acceptance Criteria
- [ ] ...
```

Ticket IDs are auto-incremented from `tickets/last_ticket_id`. The JSON Schema at `muontickets/schema.json` enforces required fields, enums, and patterns (e.g., ID must match `^T-\d{6}$`).

---

## CLI Commands

The CLI entry point is `mt.py` at the repo root, which delegates to `muontickets/mt.py main()`.

### Board Management
| Command | Purpose |
|---------|---------|
| `init` | Create `tickets/` dir, template, and example ticket |
| `ls` | List tickets with filtering (status, label, owner, priority, type) |
| `show` | Print full ticket metadata and body |
| `validate` | Verify board consistency (schema, transitions, deps, WIP limits, cycles) |
| `stats` | Summary counts by status and owner |
| `export` | Export tickets as JSON/JSONL |
| `graph` | Dependency graph (text or Mermaid) |
| `report` | SQLite reporting DB with search capability |
| `version` | Show CLI version |

### Ticket Lifecycle
| Command | Purpose |
|---------|---------|
| `new` | Create a new ticket with auto-incremented ID |
| `claim` | Manually claim a specific ticket |
| `pick` | Find and claim best ready ticket (scored, dependency-aware) |
| `comment` | Append progress log entry |
| `set-status` | Change ticket status (with transition validation) |
| `done` | Mark ticket done (terminal state) |
| `archive` | Move done ticket to `tickets/archive/` |

### Queue Allocation (Lease-Based)
| Command | Purpose |
|---------|---------|
| `allocate-task` | Claim a ticket with a time-bound lease |
| `fail-task` | Record a failed attempt, increment retry counter |

### Maintenance (Autonomous Scanning)
| Command | Purpose |
|---------|---------|
| `maintain init-config` | Generate `tickets/maintain.yaml` |
| `maintain doctor` | Verify external tools are installed |
| `maintain list` | Browse 150 maintenance rule taxonomy |
| `maintain scan` | Scan codebase for issues (no tickets created) |
| `maintain create` | Create tickets for verified issues |

---

## Ticket Lifecycle (State Machine)

### Allowed Status Transitions

```
ready          → claimed, blocked
claimed        → needs_review, blocked, ready  (unclaim back to ready)
blocked        → ready, claimed
needs_review   → done, claimed                 (back to claimed if review fails)
done           → (terminal)
```

### Typical Workflow

```
mt new "Feature X"              # status=ready, owner=null
mt pick --owner agent-1         # status=claimed, owner=agent-1
mt comment T-000001 "Done X"    # progress log appended to ticket body
mt set-status T-000001 needs_review
mt done T-000001                # status=done (terminal)
mt archive T-000001             # moved to tickets/archive/
```

**Dependency enforcement:** `pick` and `claim` refuse to claim a ticket if any ticket in `depends_on` is not yet `done`, unless `--ignore-deps` is passed.

**WIP limits:** Each owner can hold at most N claimed tickets simultaneously (default: 2, configurable via `--max-claimed-per-owner`).

---

## Queue Allocation and Lease System

`allocate-task` is a queue-style allocator designed for multi-agent swarms where agents may fail or be slow.

### How It Works

```bash
mt allocate-task --owner agent-1 --lease-minutes 5
```

1. Find the highest-scoring `ready` ticket (or a `claimed` ticket with an expired lease)
2. Set `status=claimed`, `allocated_to=agent-1`, `lease_expires_at=now+5m`
3. Return the ticket ID

If the agent fails, it calls:

```bash
mt fail-task T-000001 --owner agent-1 --error "timeout"
```

This increments `retry_count`. When `retry_count >= retry_limit`, the ticket is moved to `tickets/errors/` for manual triage.

### Stale Lease Reallocation

If an agent holds a lease that expires (e.g., the agent crashed), the next call to `allocate-task` from any agent will detect the expired lease and reallocate the ticket. The previous owner's work is considered lost.

---

## `.mt.lock` — Inter-Process File Lock

**Location:** `tickets/.mt.lock`

**Created by:** `repo_lock()` context manager in `muontickets/mt.py:226`

```python
LOCK_FILENAME = ".mt.lock"

@contextlib.contextmanager
def repo_lock(repo: str):
    lock_path = os.path.join(tickets_dir(repo), LOCK_FILENAME)
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
```

The `with_repo_lock` decorator wraps all writer commands so they automatically acquire this lock before executing.

### When It Is Created

The file is created on the **first write command** that runs (e.g., `mt new`, `mt claim`, `mt pick`). It is created once and persists permanently — only the POSIX `flock` on it is acquired and released, not the file itself.

### Why It Exists

When multiple agents run on the same machine (or same NFS mount), they may call `mt pick` or `mt allocate-task` simultaneously. Without a lock, two agents could both read the same `ready` ticket, both decide to claim it, and write conflicting state. The lock ensures each writer command is an atomic read-modify-write.

**Scope:** Inter-process on a single machine (via `fcntl`). For distributed machines, Git push/pull provides the coordination boundary.

**Crash safety:** If a process dies while holding the lock, the OS automatically releases it when the file descriptor is closed — no stale lock files.

**Applied to:** `new`, `claim`, `pick`, `set-status`, `comment`, `done`, `archive`, `allocate-task`, `fail-task`

---

## `incidents.log` — Append-Only Event Log

**Location:** `tickets/incidents.log`

**Created by:** `append_incident()` in `muontickets/mt.py:1182`

```python
def append_incident(repo_root: str, message: str) -> None:
    ensure_tickets_dir(tickets_dir(repo_root))
    with open(incidents_log_path(repo_root), "a", encoding="utf-8") as f:
        f.write(f"{now_utc_iso()} {message}\n")
```

### When It Is Created

The file is created lazily on the **first incident event**. It only exists once one of the two triggering events has occurred.

### What Gets Logged

**1. Stale lease reallocation** (triggered by `allocate-task`):

```
2026-03-03T17:31:50Z stale-lease-reallocation id=T-000032 from_owner=codex to_owner=codex prior_lease_expires_at=2026-03-03T17:31:33Z
```

Logged when `allocate-task` detects that the current holder's lease has expired and reallocates the ticket to a new owner.

**2. Retry limit exhausted** (triggered by `fail-task`):

```
2026-03-03T17:45:48Z retry-limit-exhausted id=T-000042 retries=3 moved_to=tickets/errors
```

Logged when `fail-task` increments `retry_count` to or past `retry_limit`, causing the ticket to be moved to `tickets/errors/`.

### Why It Exists

The incidents log provides **observability into the queue system**:

- **Debugging:** Diagnose which agents are failing, which tickets are flaky, and whether leases are too short.
- **Auditing:** Full event trail of system-level state changes that are not visible in the ticket file history alone (e.g., a stale reallocation overwrites previous owner — the log records who held it before).
- **Operations:** When investigating `tickets/errors/`, the log shows the full retry history leading to escalation.

Normal ticket state transitions (claim, set-status, done) are visible in the ticket file's YAML and Git history. Incidents are for **queue-system anomalies** — stale leases and retry exhaustion — that warrant separate tracking.

---

## Language Ports

MuonTickets has three non-Python ports targeting identical command behavior:

| Port | Location | Build |
|------|----------|-------|
| Rust | `ports/rust-mt/` | `cargo build --release` |
| Zig | `ports/zig-mt/` | `zig build -Doptimize=ReleaseFast` |
| C | `ports/c-mt/` | `make` |

All ports implement the same ticket format, state machine, lock semantics (`fcntl`), and CLI flags as the Python reference. They are validated for parity via `tests/test_conformance_runner.py`, which runs the same command sequences against all implementations and compares output.

**Why multiple languages:**
- Single-file binary distribution with no Python runtime requirement
- Higher throughput for large boards
- Language ecosystem diversity for embedding in other toolchains

---

## Backlogs and Errors Directories

**`tickets/backlogs/`** — Future or speculative work not yet active. Tickets here are excluded from `pick` and `allocate-task`. Move a ticket to `tickets/` when it is ready to be worked.

**`tickets/errors/`** — Dead-letter queue. When `fail-task` exhausts the retry limit, the ticket is moved here for manual triage. To restart work, reset `retry_count`, update `retry_limit`, and move the ticket back to `tickets/`.

---

## Validation

`mt validate` checks board consistency:

- All ticket files parse against `muontickets/schema.json`
- No invalid status transitions in history
- `depends_on` references point to existing tickets
- No circular dependencies
- WIP limits not exceeded
- Filenames match the `id` field in frontmatter

The Git pre-commit hook at `muontickets/hooks/pre-commit` runs `mt validate` automatically before each commit.

---

## Scoring and Ticket Selection

`pick` and `allocate-task` score candidate tickets to select the best one:

| Factor | Weight |
|--------|--------|
| Priority (p0 > p1 > p2) | High |
| Effort (smaller preferred) | Medium |
| Age (older tickets preferred) | Low |
| Dependency count (fewer blocking others = higher score) | Low |

Filters narrow candidates before scoring: `--label`, `--avoid-label`, `--priority`, `--type`, `--skill` (predefined label+type profile), `--role` (predefined profile).

---

## Key Design Principles

1. **File-first** — Tickets are files, enabling standard Git workflows (diff, blame, PR review, revert).
2. **Stateless CLI** — Each command re-reads board state from disk. No daemon, no in-memory state.
3. **Lock-free on read** — Only writer commands acquire the lock; readers (`ls`, `show`, `validate`) can run in parallel.
4. **Deterministic** — No external state; full reproducibility from the Git commit history.
5. **Dependency-aware** — Tickets cannot be claimed until their `depends_on` prerequisites are done.
6. **Lease-based queue** — Time-bound allocations enable automatic retry and load rebalancing across agents.
7. **Observable** — Incidents log provides an event trail for queue-system anomalies not visible in ticket diffs alone.
8. **Language-agnostic storage** — All ports share the identical Markdown+YAML ticket format; implementations are interchangeable.
