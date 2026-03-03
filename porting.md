# MuonTickets Porting PRD

## 1) Purpose

Define a language-portable Product Requirements Document (PRD) for MuonTickets so teams can reimplement the current Python CLI behavior in their preferred language and distribute it as a **system-wide install** (binary/package) instead of only as a Git submodule workflow.

This PRD is implementation-oriented: it captures feature parity targets from current `mt.py`, explains the file-based ticketing model, and sets compatibility and packaging requirements for cross-platform delivery.

## 2) Background and Problem

Current MuonTickets is implemented in Python and commonly consumed via submodule layout in repositories. Some teams want:

- A single system command (for example, `mt`) installed globally.
- Predictable behavior across repos without submodule bootstrapping friction.
- Native binaries for fast startup and simplified distribution.

The existing model is intentionally file-native and Git-friendly. A successful port must preserve these strengths while making installation and runtime more universal.

## 3) Goals

- Preserve current behavior and CLI semantics of `mt.py`.
- Keep tickets as files in Git, with deterministic, inspectable state transitions.
- Provide portable implementation architecture that can be rebuilt in other languages.
- Define system-wide installation/distribution strategy across macOS, Linux, and Windows.
- Enable cross-compilation-first delivery.

## 4) Non-Goals

- Replacing file storage with a network database as the primary store.
- Adding a GUI in v1 of the port.
- Introducing breaking schema/command changes in the first parity release.
- Removing submodule mode immediately (it remains a supported compatibility mode).

## 5) Why File-Based Ticketing (and Why Keep It)

MuonTickets stores tickets as Markdown files with YAML frontmatter under `tickets/`.

### Core reasons this design exists

- **Git-native auditability**: every change is diffable/reviewable in PRs.
- **Offline-first operation**: no central service required.
- **Tool interoperability**: plain files are grep-able and scriptable.
- **Reproducibility**: board state is versioned with code.
- **Low operational overhead**: no deployment/runtime service to maintain.

### Requirement for ported versions

The port MUST preserve file-backed canonical state. Optional caches/reports (like SQLite) may exist as derived artifacts but must not become the source of truth.

## 6) Ticketing Model

### 6.1 Directory model

- Active tickets: `tickets/T-000123.md`
- Archived tickets: `tickets/archive/T-000123.md`
- Planned backlog tickets: `tickets/backlogs/T-000123.md`
- Template: `tickets/ticket.template`
- ID state: `tickets/last_ticket_id`

### 6.2 Ticket file format

Each ticket file has:

1. YAML frontmatter delimited by `---`
2. Markdown body sections (`Goal`, `Acceptance Criteria`, `Notes`, optional `Progress Log`)

Schema-driven required fields (from current `schema.json`):

- `id`, `title`, `status`, `priority`, `type`, `labels`, `owner`, `created`, `updated`, `depends_on`, `branch`

Key optional/defaulted fields:

- `effort` (`xs|s|m|l`)
- `tags` (string list)
- `score` (number)

### 6.3 Lifecycle and transitions

Canonical statuses:

- `ready`, `claimed`, `blocked`, `needs_review`, `done`

Allowed transitions:

- `ready -> claimed|blocked`
- `claimed -> needs_review|blocked|ready`
- `blocked -> ready|claimed`
- `needs_review -> done|claimed`
- `done ->` no forward transitions

## 7) Current Feature Surface in mt.py (Parity Scope)

Ported implementation MUST support these commands and semantics.

### 7.1 Board/bootstrap

- `mt init`
  - Ensures `tickets/` exists.
  - Creates `tickets/ticket.template` if missing.
  - Creates example ticket if board is empty.
  - Synchronizes `last_ticket_id` state with scanned max.

### 7.2 Ticket creation and inspection

- `mt new "Title"`
  - Assigns next deterministic `T-XXXXXX` ID.
  - Applies template defaults from `tickets/ticket.template`.
  - CLI args override template values (`--priority`, `--type`, `--effort`, `--label`, `--tag`, `--depends-on`, `--goal`).
- `mt ls` with filters (`status`, `owner`, `priority`, `type`, labels).
- `mt show T-000123` prints full ticket content.

### 7.3 Work coordination

- `mt pick --owner ...`
  - Chooses best claimable `ready` ticket based on scoring (priority, effort, age, dependency penalty).
  - Enforces dependency satisfaction unless `--ignore-deps`.
  - Enforces per-owner WIP cap (`--max-claimed-per-owner`, default 2).
  - Claims ticket and sets owner/branch.
- `mt claim T-000123 --owner ...`
  - Claims specific ticket with transition/dependency checks.
- `mt comment T-000123 "..."`
  - Appends to `## Progress Log` and updates metadata timestamp.
- `mt set-status T-000123 <status>`
  - Enforces transition matrix unless `--force`.
- `mt done T-000123`
  - Requires prior `needs_review` unless `--force`.

### 7.4 Archival and dependency safety

- `mt archive T-000123`
  - Moves completed ticket into `tickets/archive/`.
  - Refuses if active tickets depend on it, unless `--force`.
  - Emits warnings about invalid board states when force-archiving with active dependents.

### 7.5 Validation, reporting, export, graphing

- `mt validate`
  - Schema validation.
  - Metadata sanity checks.
  - WIP checks.
  - Dependency checks, including archived dependency detection.
- `mt report`
  - Builds SQLite report DB (`tickets/tickets_report.sqlite3` by default).
  - Supports summary and search.
- `mt export --format json|jsonl`
- `mt graph [--mermaid] [--open-only]`
- `mt stats`

## 8) Functional Requirements for Ported Implementations

### FR-1: CLI parity

The port MUST provide command names and key flags equivalent to current behavior for all commands listed above.

### FR-2: File compatibility

The port MUST read/write existing ticket files and frontmatter with no migration required for parity mode.

### FR-3: Deterministic IDs

The port MUST preserve ID allocation semantics (`last_ticket_id` with full scan fallback across active/archive/backlog trees).

### FR-4: Validation fidelity

Validation errors MUST preserve meaning and remediation intent (exact wording may differ slightly, but behavior must match).

### FR-5: Template semantics

Template defaults must apply on `new`, while explicit CLI args override template values.

### FR-6: Dependency guarantees

No claims/picks should bypass dependency gates unless explicit override flags are used.

### FR-7: Archive safety

Archive must block when active dependents exist (unless forced) and clearly communicate risk.

### FR-8: Derived reporting

SQLite report generation remains optional but supported as a derived reporting feature.

## 9) Non-Functional Requirements

- **Portability**: support macOS, Linux, Windows.
- **Performance**: board operations should be fast on repos with thousands of tickets.
- **Reliability**: atomic writes where feasible; avoid partial/corrupt file writes.
- **Determinism**: stable behavior for pick/score and validation outcomes.
- **Security**: no shell command injection paths from ticket content; strict path handling.

## 10) System-Wide Install and Distribution Requirements

Target installation modes:

1. Native package manager installs (`brew`, `apt`, `dnf`, `winget`, `choco`, etc.)
2. Direct binary release downloads
3. Optional language package ecosystem installs (if needed)

Install outcome requirement:

- `mt` should be runnable globally from shell (`PATH`) without submodule requirement.

Compatibility requirement:

- Must work against any repo containing `tickets/` board structure, regardless of where binary is installed.

Migration requirement:

- Existing submodule users should be able to swap command path usage to global `mt` with no ticket format changes.

## 11) Language Recommendations (Cross-Compilation Focus)

Preferred options for new implementations:

- **Rust**
  - Mature ecosystem, strong correctness tooling, broad target support.
  - Excellent CLI ergonomics and robust packaging workflows.
- **Zig**
  - Strong cross-compilation story and low-dependency static binaries.
  - Good fit for lightweight portable CLI tooling.
- **C**
  - Maximum portability and broad compiler/toolchain availability.
  - Useful when minimal runtime dependencies are mandatory.

Recommendation policy:

- Prioritize Rust or Zig for first modern port due to developer velocity + cross-platform binary distribution.
- Use C for minimal-runtime or constrained-environment variants.

## 12) Proposed Architecture for a Language Port

### 12.1 Core modules

- `cli`: command parsing and dispatch
- `model`: ticket/frontmatter types and normalization
- `io`: file discovery, parse, serialize, atomic write/move
- `rules`: transitions, dependency checks, WIP checks, scoring
- `commands`: implementations (`new`, `pick`, `validate`, etc.)
- `reporting`: SQLite export/search summaries
- `compat`: schema loading and parity adapters

### 12.2 Compatibility-first mode

Provide a strict compatibility mode as default that mirrors Python semantics.

Potential future enhancement:

- opt-in improved mode with extra diagnostics, while retaining compat mode for predictable migration.

## 13) Parity Test Strategy

A shared black-box conformance suite should validate all ports against the same board fixtures.

### Required test categories

- Ticket parsing/serialization round-trip
- ID allocation and `last_ticket_id` behavior
- Transition matrix acceptance/rejection
- Dependency gating for `claim` and `pick`
- Archive blocking and force warning behavior
- Validation errors (missing/archived deps, bad schema fields)
- Template default + CLI override precedence
- Report DB creation and basic query outputs

### Success criteria

A port is parity-complete when conformance tests pass and generated ticket files remain compatible with Python implementation.

## 14) Rollout Plan

### Phase 1: Spec freeze

- Freeze parity behavior against current Python implementation.
- Publish conformance fixtures.

### Phase 2: Reference port

- Build first non-Python implementation with full command parity.
- Ship binaries for macOS/Linux/Windows.

### Phase 3: Adoption

- Update docs to prefer global `mt` while retaining submodule compatibility docs.
- Collect migration feedback from early adopters.

## 15) Risks and Mitigations

- **Risk: behavior drift between implementations**
  - Mitigation: centralized conformance suite + fixture-based tests.
- **Risk: YAML/parser discrepancies**
  - Mitigation: strict frontmatter tests and deterministic serializer rules.
- **Risk: packaging fragmentation**
  - Mitigation: prioritize one official binary channel first, then package managers.
- **Risk: forced archive misuse in automation**
  - Mitigation: retain strong warnings and clear remediation in validation output.

## 16) Open Questions

- Should v1 global install include auto-update support?
- Should `report` remain built-in for all ports or be a plugin/subcommand package?
- Should compatibility mode include a `--strict-python-parity` flag with exact message text matching?

## 17) Acceptance Criteria for This PRD

- Documents all current `mt.py` features and behaviors relevant to parity.
- Clearly explains file-based model and Git-native rationale.
- Defines system-wide installation target state and migration path.
- Recommends Zig, C, Rust explicitly for cross-compilation and distribution.
- Provides architecture + test strategy sufficient for implementation kickoff.
