# Changelog

All notable user-visible changes to this project are documented in this file.

## Entry Format

Each entry must include:

- Date (`YYYY-MM-DD`)
- Change type (`Added`, `Changed`, `Fixed`, `Docs`, `Removed`)
- Short summary

Example:

- 2026-02-23 | Added | Introduced configurable ticket template defaults

## Unreleased

- 2026-03-03 | Added | Added Zig cross-compilation release script producing macOS/Linux/Windows archives and `SHA256SUMS` under `ports/zig-mt/dist`, with per-target failure reporting when sysroots/libs are unavailable
- 2026-03-03 | Changed | Added Zig `new` template-ingestion parity so `tickets/ticket.template` defaults/body are applied when CLI overrides are absent (including labels/tags/depends/status/owner/branch)
- 2026-03-03 | Changed | Upgraded Zig `report` to generate real SQLite output (`tickets` and `parse_errors` tables with indexes) and run SQL-based summary/search queries
- 2026-03-03 | Changed | Implemented Zig `report` command stub output and expanded `new`/`ls`/`pick`/`claim` option parity (`--depends-on`, label filters, branch override, WIP/dependency controls)
- 2026-03-03 | Added | Added Zig conformance fixture and runner support for stream-agnostic output assertions to validate non-Python port behavior
- 2026-03-03 | Changed | Implemented Zig commands `pick`, `comment`, `graph`, `export`, and `stats` with basic parity behavior
- 2026-03-03 | Changed | Implemented Zig workflow commands `claim`, `set-status`, `done`, `archive`, and `validate` with transition and archive safety checks
- 2026-03-03 | Changed | Implemented `init`, `new`, `ls`, and `show` command flow in Zig port with ticket file creation and listing/show support
- 2026-03-03 | Added | Bootstrapped initial Zig `mt` port scaffold under `ports/zig-mt` with mapped command surface and buildable CLI entrypoint
- 2026-03-03 | Added | Bootstrapped initial Rust `mt` port scaffold under `ports/rust-mt` with mapped command surface and buildable CLI entrypoint
- 2026-03-03 | Added | Added cross-language conformance fixtures and reusable runner for validating command parity against Python reference behavior
- 2026-03-03 | Docs | Added `ports/porting_phase1.md` with milestone sequencing, parity gates, owner model, and delivery signoff checklist for portability execution
- 2026-03-03 | Docs | Recommended one ticket fix per commit/PR and parallel multi-agent execution for isolated tickets
- 2026-03-03 | Docs | Added `ports/porting.md` PRD covering full `mt.py` feature parity, file-based model rationale, and system-wide porting guidance with Zig/C/Rust recommendations
- 2026-03-03 | Docs | Standardized submodule command path to `tickets/mt/muontickets/muontickets/mt.py` and added explicit wrong-vs-right install/run examples for agents
- 2026-03-03 | Docs | Added explicit CLI-first guidance to use `mt.py` for claim/status/comment/archive flows and avoid direct edits under `tickets/`
- 2026-03-03 | Docs | Expanded `ticket.template` guidance with customization, inheritance examples, and `mt init` non-overwrite behavior
- 2026-03-03 | Changed | Improved archive/validation guidance for archived dependencies and force-archive risk messaging
- 2026-02-23 | Fixed | Prevent archiving tickets that are still referenced by active `depends_on` and improved validation messaging for archived dependencies
- 2026-02-23 | Docs | Prioritized submodule-based installation guidance and clarified direct-checkout usage for core development
- 2026-02-23 | Docs | Added agent quick-reference guide with install modes, workflow commands, and best practices
