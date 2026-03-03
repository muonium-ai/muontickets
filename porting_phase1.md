# MuonTickets Porting Phase 1 Execution Plan

## Objective

Execute Phase 1 of the MuonTickets portability roadmap with clear sequencing, owner tracks, parity gates, and delivery criteria that feed directly into implementation tickets.

This plan operationalizes the PRD in [porting.md](porting.md).

## Scope and Sequencing

### Stream A — Planning & Gate Definition

- Define milestone boundaries and ownership model.
- Define parity gates and release blockers.
- Freeze language decision criteria and target choice.
- Publish delivery checklist and signoff workflow.

### Stream B — Conformance Harness

- Build black-box fixtures and expected outcomes from Python reference.
- Implement reusable runner to execute fixture commands against candidates.
- Establish baseline artifact snapshots and pass/fail report format.

### Stream C — First CLI Port

- Implement command parity for high-priority workflows.
- Ensure ticket file format compatibility with no migrations.
- Run full conformance suite and close parity gaps.

### Stream D — Packaging Pipeline

- Produce cross-platform release binaries from tags.
- Add install paths (package manager + direct binary).
- Add smoke tests for installed global `mt` usage.

## Milestones

### M1 — Phase 1 Plan Frozen

- Stream: Planning & Gate Definition
- Exit criteria:
  - Sequenced stream plan approved.
  - Gate checklist approved.
  - Language decision rubric approved.

### M2 — Conformance Baseline Published

- Stream: Conformance Baseline
- Exit criteria:
  - Fixture repos created.
  - Baseline outputs generated from Python reference.
  - CI/pass-fail report generated for fixture run.

### M3 — CLI Port Parity Candidate

- Stream: CLI Port Parity
- Exit criteria:
  - Required command set implemented.
  - Fixture suite green on mandatory scenarios.
  - No ticket format compatibility regressions.

### M4 — Packaging Readiness

- Stream: Packaging Readiness
- Exit criteria:
  - macOS/Linux/Windows binaries generated.
  - Install instructions published and smoke-tested.
  - Checksums + release manifest produced.

## Owner Model

- **Planning Owner** (`agent-plan-*`): maintains milestones, dependencies, and gate criteria.
- **Conformance Owner** (`agent-test-*`): owns fixture design, runner, and parity reports.
- **Port Owner** (`agent-port-*`): owns non-Python CLI implementation and compatibility fixes.
- **Packaging Owner** (`agent-release-*`): owns build/release automation and install verification.

Parallelization rule:

- Streams B/C/D can run with multiple agents in parallel only when dependency gates are satisfied and shared artifact ownership is explicit.
- Work is isolated by ticket and branch; each ticket change ships as a separate commit and PR.

## Parity Gates (Must Pass Before Packaging)

### Gate G1 — Schema & File Compatibility

- Reads existing `tickets/*.md` without conversion.
- Writes frontmatter fields with compatible semantics.
- Preserves required keys and expected defaults.

### Gate G2 — Workflow Command Parity

Mandatory commands: `init`, `new`, `ls`, `show`, `claim`, `pick`, `set-status`, `done`, `archive`, `validate`.

### Gate G3 — Dependency & Transition Enforcement

- Dependency blocking for claim/pick behaves correctly.
- Invalid status transitions are rejected unless explicit override.
- Archive blocking with active dependents behaves correctly (with warnings on force).

### Gate G4 — Deterministic Board Semantics

- ID generation is deterministic with `last_ticket_id` + scan fallback.
- Pick scoring behavior and tie-break ordering are stable.
- Validation error categories match reference expectations.

### Gate G5 — Report/Export/Graph Baseline

- `report`, `export`, `graph`, `stats` produce structurally valid outputs.
- Output differences from Python are documented and non-breaking.

## Language Decision Criteria

Primary recommendation candidates: **Rust**, **Zig**, **C**.

Evaluate on:

1. Cross-compilation maturity and release tooling.
2. Filesystem + YAML/frontmatter ecosystem quality.
3. CLI ergonomics and maintainability for long-term contributors.
4. Binary size/startup characteristics.
5. CI complexity and reproducibility.

### Initial target recommendation

- **Rust** for first reference port due to balance of maintainability, safety, and cross-platform release tooling.
- Keep **Zig** and **C** as follow-on or alternate implementations where runtime footprint or toolchain constraints dominate.

## Delivery Checklist and Signoff

### Per-stream deliverables

- Design/update notes attached to the workstream artifact.
- Command examples and usage docs updated.
- Tests/conformance evidence attached.
- Changelog entry included with a clear summary.

### Signoff criteria

- Stream acceptance criteria fully checked.
- `mt validate` passes on working board.
- No unresolved dependency blockers.
- Reviewer confirms parity gate evidence where applicable.

## Dependencies (Stream-Level)

- Planning & Gate Definition -> Conformance Harness -> First CLI Port -> Packaging Pipeline

## Risks and Controls

- **Risk:** hidden behavior drift from Python implementation.
  - **Control:** fixture-driven conformance before packaging.
- **Risk:** packaging starts before parity maturity.
  - **Control:** enforce G1–G4 gates before D-stream release work.
- **Risk:** parallel agents collide in shared files.
  - **Control:** isolate by ticket + branch; per-ticket PR discipline.
