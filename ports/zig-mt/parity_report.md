# Zig vs Python Parity Report

Date: 2026-03-03

## Scope

Comparison between:
- Python reference CLI: `muontickets/mt.py`
- Zig port CLI: `ports/zig-mt/src/main.zig`

## Command Surface

Both CLIs expose the same top-level command set:
- `init`, `new`, `ls`, `show`, `pick`, `claim`, `comment`, `set-status`, `done`, `archive`, `graph`, `export`, `stats`, `validate`, `report`

## Implemented Parity (Current)

- `new`: template inheritance/default fallback and CLI override precedence implemented.
- `ls`: core filters (`--status`, `--label`, `--owner`, `--priority`, `--type`) implemented.
- `pick`: scoring + deterministic tie-break behavior aligned with Python model (priority, effort, deps, age).
- `claim`: owner/branch/force/dependency flags implemented.
- `set-status`: transition checks + `--clear-owner` behavior implemented.
- `done` / `archive`: workflow and safety checks implemented.
- `graph`: plain output plus `--mermaid` and `--open-only` implemented.
- `export`: `--format json|jsonl` implemented.
- `stats`: status count reporting implemented.
- `validate`: `--max-claimed-per-owner` and `--enforce-done-deps` implemented.
- `report`: SQLite report output, summary, and search implemented.

## Remaining Deltas

None currently identified in the covered command/fixture scope.

## Recently Closed

- **`export` payload shape parity**
  - Zig export now includes Python-aligned fields: `labels`, `tags`, `owner`, `created`, `updated`, `depends_on`, `branch`, `excerpt`, and `path`.

- **`ls --show-invalid` parity**
  - Zig now supports `--show-invalid` and reports parse-error rows.

- **`validate` strictness parity (major checks)**
  - Zig now fails parse-error files, checks required fields, validates key enums/patterns, and enforces date consistency (`updated >= created`).

## Conformance Coverage

Current conformance fixtures include:
- `core_workflow.json`
- `reporting_graph_pick.json`
- `zig_reporting_graph_pick.json`
- `options_parity.json`
- `pick_scoring.json`

These now cover the recently closed option/scoring gaps.

## Recommendation

Continue expanding fixtures for any newly added command options to preserve strict parity over time.
