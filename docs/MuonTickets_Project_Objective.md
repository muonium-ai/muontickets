# MuonTickets

## Project Objective & Detailed Overview

**Version:** 1.0
**Date:** 2026-02-19

------------------------------------------------------------------------

# 1. Project Objective

MuonTickets is a Git-native, file-based ticketing system designed for:

-   AI agent swarms
-   Human + AI hybrid development teams
-   Offline-first coordination
-   Deterministic, reproducible workflows
-   High-parallel development environments

The core objective is to transform a Git repository into a
self-contained, agent-coordination system without requiring:

-   External issue trackers
-   Databases
-   SaaS dependencies
-   Centralized orchestration servers

MuonTickets leverages Git itself as the distributed coordination
backbone.

------------------------------------------------------------------------

# 2. Vision

Modern AI development involves:

-   Multiple parallel agents
-   Automated code generation
-   Rapid PR cycles
-   Frequent branching and merging

Traditional issue trackers introduce:

-   Context switching
-   API dependencies
-   Sync mismatches
-   Fragmented workflows

MuonTickets unifies:

-   Code
-   Tickets
-   State
-   History
-   Review
-   Validation

inside a single Git repository.

------------------------------------------------------------------------

# 3. Core Design Principles

## 3.1 Git-Native

-   Tickets are Markdown files.
-   Every state change is a commit.
-   Every modification is reviewable in a PR.
-   Full offline capability.

## 3.2 Agent-First Design

The system is optimized for autonomous agents:

-   Strict schema validation
-   Deterministic state transitions
-   Dependency-aware task selection
-   WIP enforcement
-   Machine-readable export

## 3.3 Stigmergic Coordination

Agents coordinate via the environment (tickets folder):

-   `status` acts as pheromone
-   `owner` prevents conflicts
-   `depends_on` enforces order
-   `priority` guides scheduling

No central manager required.

## 3.4 Merge Safety

-   One ticket per file
-   Small atomic edits
-   Optimistic locking via Git push
-   Validation via pre-commit + CI

------------------------------------------------------------------------

# 4. Folder Structure

After submodule installation:

    tickets/
      mt/
        muontickets/
          mt.py
          schema.json
          hooks/
          Makefile.snippet
      ticket.template
      T-000123.md
      archive/
      backlog/

Active tickets live in `tickets/`.
Completed tickets can move to `tickets/archive/`.
Future work can be staged in `tickets/backlog/`.
Retry-exhausted tickets can move to `tickets/errors/` for manual triage.

MuonTickets logic lives in `tickets/mt/muontickets/` as a submodule in consumer repositories,
or in the repository root when developing MuonTickets core directly.

This gives:

-   Visibility to users
-   Visibility to agents
-   Explicit ownership of ticket tooling

------------------------------------------------------------------------

# 5. Ticket Lifecycle

Valid states:

-   ready
-   claimed
-   blocked
-   needs_review
-   done

State transitions are validated and enforced.

Dependencies prevent premature claiming.

Queue-mode lifecycle extension:

- `mt allocate-task --owner <agent>` allocates one ticket and returns ticket id.
- Allocation creates a lease (`lease_expires_at`, default 5 minutes).
- Expired leases can be reallocated to another agent.
- Reallocation and retry-limit events are written to `tickets/incidents.log`.
- `mt fail-task <id> --error "..."` increments `retry_count` and re-queues.
- When `retry_count >= retry_limit`, ticket is moved to `tickets/errors/` for manual resolution.

------------------------------------------------------------------------

# 6. Agent Swarm Workflow

Agent loop:

1.  `git pull`
2.  `mt allocate-task --owner agent-X` (queue mode) or `mt pick --owner agent-X` (score mode)
3.  Create branch from ticket branch name
4.  Implement feature
5.  Run project checks/tests as applicable
6.  `mt set-status T-xxxx needs_review`
7.  After merge → `mt done T-xxxx`

Queue operator runbook:

1.  Allocate one ticket with `mt allocate-task --owner agent-X`.
2.  Post progress with `mt comment T-xxxx "..."` while implementing.
3.  On success: `mt set-status T-xxxx needs_review` then `mt done T-xxxx`.
4.  On execution failure: `mt fail-task T-xxxx --error "..."` to increment retries and re-queue.
5.  For retry exhaustion, triage entries moved to `tickets/errors/` and inspect incidents in `tickets/incidents.log`.

In submodule-based repos, command path is typically:

  uv run python3 tickets/mt/muontickets/muontickets/mt.py <command>

In a direct MuonTickets checkout:

  uv run python3 mt.py <command>

This enables:

-   Parallel development
-   Self-scheduling agents
-   Minimal conflict zones
-   Automatic prioritization
-   Lease-aware task allocation
-   Built-in retries and error triage path

------------------------------------------------------------------------

# 7. Installer Strategy

MuonTickets includes a Homebrew-style installer:

    curl -fsSL <url>/install.sh | bash

Installer performs:

-   Git repo validation
-   Creation of `tickets/mt/`
-   Adds MuonTickets as submodule
-   Optional pre-commit hook install
-   Optional Makefile patch

This provides instant setup across projects.

------------------------------------------------------------------------

# 8. Validation Model

`mt validate` enforces:

-   Schema compliance
-   WIP limits
-   Dependency integrity (including archived dependency references)
-   Status transition rules
-   Branch tracking requirements

Pre-commit hook runs validation automatically.

CI must also call:

    mt validate

This ensures `main` always works.

------------------------------------------------------------------------

# 9. Advanced Capabilities

-   Automatic task scoring
-   Dependency-aware picking
-   Mermaid graph output
-   JSON export for LLM consumption
-   Board statistics
-   Effort-based prioritization

### Autonomous Maintenance

`mt maintain` provides a scan-first, create-later workflow for preventive maintenance
across 150 rules in 9 categories (security, deps, code-health, performance, database,
infrastructure, observability, testing, docs).

Five subcommands:

-   `mt maintain init-config` -- generate `tickets/maintain.yaml` config (`--detect` auto-detects stack)
-   `mt maintain doctor` -- verify all configured tools are installed on PATH
-   `mt maintain list` -- browse the 150-rule taxonomy
-   `mt maintain scan` -- scan codebase against rules, report PASS/FAIL/SKIP (no tickets created)
-   `mt maintain create` -- create tickets only for rules with verified findings

This enables the autonomous maintenance loop:

    init-config → doctor → scan → verify issue exists → generate MuonTicket → assign agent → fix → PR → CI verify → merge

Key properties:

-   Scan-first: verify issues exist before creating tickets (avoids wasted CI/CD cycles)
-   Built-in scanners: exposed secrets, large files, TODO density, .env tracking, broken links, stale README
-   External tools: configured in `tickets/maintain.yaml` with per-tool timeout and auto-fix support
-   Stack detection: `--detect` generates config matching Python, Node, Rust, Go, Docker stacks
-   Scan profiles: `--profile ci` (fast checks) and `--profile nightly` (full scan)
-   Scan diffing: `--diff` shows only new findings vs last scan (`tickets/maintain.last.json`)
-   Auto-fix: `--fix` runs `fix_command` for tools that support automatic remediation
-   Lightweight: scan step can run on smaller/cheaper LLM agents or cron jobs
-   Idempotent: repeated `create` runs skip rules with existing open tickets (tag-based dedup)
-   Filterable: `--category`, `--rule`, `--all`, `--profile`, `--priority`, `--owner` flags
-   Logging: all tool invocations logged to `tickets/maintain.log`
-   Exit codes: 0 = pass, 1 = findings, 2 = config/argument error

Reference: [docs/muonium_autonomous_maintenance_rules.md](docs/muonium_autonomous_maintenance_rules.md)
External tools setup: [docs/maintenance_tools_setup.md](docs/maintenance_tools_setup.md)

Future roadmap:

-   Event-sourced tickets (append-only mode)
-   Rust binary installer
-   Go-based lightweight runtime
-   GitHub bridge integration
-   Agent telemetry metrics

------------------------------------------------------------------------

# 10. Non-Goals

MuonTickets does NOT aim to:

-   Replace Git history
-   Provide chat/messaging
-   Replace CI systems
-   Replace deployment tooling

It focuses purely on:

Deterministic agent task coordination.

------------------------------------------------------------------------

# 11. Success Criteria

MuonTickets succeeds if:

-   Multiple agents can operate without collision
-   Tickets remain small and atomic
-   `main` remains stable
-   Developers never leave Git to manage tasks
-   CI failures due to ticket inconsistency are eliminated

------------------------------------------------------------------------

# 12. Conclusion

MuonTickets is a foundational layer for AI-driven development.

It transforms Git from:

"Version control"

into:

"A distributed agent orchestration system"

without introducing new infrastructure.

It is lightweight, deterministic, extensible, and future-ready.
