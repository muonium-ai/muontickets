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

------------------------------------------------------------------------

# 6. Agent Swarm Workflow

Agent loop:

1.  `git pull`
2.  `mt pick --owner agent-X`
3.  Create branch from ticket branch name
4.  Implement feature
5.  Run project checks/tests as applicable
6.  `mt set-status T-xxxx needs_review`
7.  After merge → `mt done T-xxxx`

In submodule-based repos, command path is typically:

  uv run python3 tickets/mt/muontickets/muontickets/mt.py <command>

In a direct MuonTickets checkout:

  uv run python3 mt.py <command>

This enables:

-   Parallel development
-   Self-scheduling agents
-   Minimal conflict zones
-   Automatic prioritization

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
