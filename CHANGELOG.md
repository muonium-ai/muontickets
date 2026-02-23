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

- 2026-02-23 | Fixed | Prevent archiving tickets that are still referenced by active `depends_on` and improved validation messaging for archived dependencies | Ticket: T-000005
- 2026-02-23 | Docs | Prioritized submodule-based installation guidance and clarified direct-checkout usage for core development | Ticket: T-000007
- 2026-02-23 | Docs | Added agent quick-reference guide with install modes, workflow commands, and best practices | Ticket: T-000008
