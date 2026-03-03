# Changelog

All notable user-visible changes to this project are documented in this file.

## Entry Format

Each entry must include:

- Date (`YYYY-MM-DD`)
- Change type (`Added`, `Changed`, `Fixed`, `Docs`, `Removed`)
- Short summary
- Ticket reference in the form `T-000123`

Example:

- 2026-02-23 | Added | Introduced configurable ticket template defaults | Ticket: T-000006

## Unreleased

- 2026-03-03 | Added | Bootstrapped initial Rust `mt` port scaffold under `ports/rust-mt` with mapped command surface and buildable CLI entrypoint | Ticket: T-000009
- 2026-03-03 | Added | Added cross-language conformance fixtures and reusable runner for validating command parity against Python reference behavior | Ticket: T-000008
- 2026-03-03 | Docs | Added `porting_phase1.md` with milestone sequencing, parity gates, owner model, and delivery signoff checklist for portability execution | Ticket: T-000007
- 2026-03-03 | Docs | Recommended one ticket fix per commit/PR and parallel multi-agent execution for isolated tickets | Ticket: T-000011
- 2026-03-03 | Docs | Added root-level `porting.md` PRD covering full `mt.py` feature parity, file-based model rationale, and system-wide porting guidance with Zig/C/Rust recommendations | Ticket: T-000006
- 2026-03-03 | Docs | Standardized submodule command path to `tickets/mt/muontickets/muontickets/mt.py` and added explicit wrong-vs-right install/run examples for agents | Ticket: T-000002
- 2026-03-03 | Docs | Added explicit CLI-first guidance to use `mt.py` for claim/status/comment/archive flows and avoid direct edits under `tickets/` | Ticket: T-000003
- 2026-03-03 | Docs | Expanded `ticket.template` guidance with customization, inheritance examples, and `mt init` non-overwrite behavior | Ticket: T-000004
- 2026-03-03 | Changed | Improved archive/validation guidance for archived dependencies and force-archive risk messaging | Ticket: T-000005
- 2026-02-23 | Fixed | Prevent archiving tickets that are still referenced by active `depends_on` and improved validation messaging for archived dependencies | Ticket: T-000005
- 2026-02-23 | Docs | Prioritized submodule-based installation guidance and clarified direct-checkout usage for core development | Ticket: T-000007
- 2026-02-23 | Docs | Added agent quick-reference guide with install modes, workflow commands, and best practices | Ticket: T-000008
