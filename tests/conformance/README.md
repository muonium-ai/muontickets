# Conformance Fixtures

This folder contains black-box fixture scenarios for MuonTickets command parity.

## Purpose

- Provide language-agnostic command scenarios and expected outcomes.
- Run the same fixtures against the Python reference and future non-Python ports.
- Catch behavior drift in status transitions, dependency handling, archive safety, and reporting outputs.

## Runner

Use `tests/conformance/runner.py` to execute fixtures.

```bash
# Run one fixture against Python reference
MT_CMD="/Users/senthil/github/muonium-ai/muontickets/.venv/bin/python /Users/senthil/github/muonium-ai/muontickets/mt.py" \
  /Users/senthil/github/muonium-ai/muontickets/.venv/bin/python tests/conformance/runner.py \
  --fixture tests/conformance/fixtures/core_workflow.json
```

## Fixture Schema (v1)

Top-level keys:

- `name`: fixture name
- `description`: short description
- `steps`: ordered list of command expectations

Step keys:

- `name`: step label
- `args`: array of CLI arguments (after `mt`)
- `expect_exit`: expected process exit code
- `expect_stdout_contains`: optional list of substrings required in stdout
- `expect_stderr_contains`: optional list of substrings required in stderr

## Notes

- Fixtures run in a temporary Git repository initialized by the runner.
- For a candidate port, set `MT_CMD` to the candidate executable command prefix.
- Keep fixture expectations focused on semantic behavior; avoid brittle full-output snapshots.
