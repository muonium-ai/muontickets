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

1. **`export` payload shape is still reduced in Zig**
   - Python includes fields such as `labels`, `tags`, `owner`, `created`, `updated`, `depends_on`, `branch`, `excerpt`, and `path`.
   - Zig currently exports a narrower subset (`id`, `title`, `status`, `priority`, `type`, `effort`).

2. **`ls --show-invalid` parity is missing in Zig**
   - Python can show parse-error rows with `--show-invalid`.
   - Zig currently skips invalid entries silently.

3. **`validate` strictness differences remain**
   - Python performs full schema validation and date consistency checks (`updated >= created`) and some richer semantics.
   - Zig validate currently covers major workflow checks, archive/dependency checks, effort sanity, owner/branch sanity, and the two added policy flags.

4. **Enum/domain differences**
   - Python `DEFAULT_PRIORITIES` and `DEFAULT_TYPES` differ from Zig accepted sets.
   - This is not a runtime blocker but may produce behavior drift in mixed-language environments.

## Conformance Coverage

Current conformance fixtures include:
- `core_workflow.json`
- `reporting_graph_pick.json`
- `zig_reporting_graph_pick.json`
- `options_parity.json`
- `pick_scoring.json`

These now cover the recently closed option/scoring gaps.

## Recommendation

For full practical parity, prioritize next:
1. Expand Zig `export` payload to match Python schema.
2. Add Zig `ls --show-invalid` behavior.
3. Add deeper schema/date checks in Zig `validate`.
