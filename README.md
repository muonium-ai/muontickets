# muontickets
file based ticketing system for agents, resides under the tickets folder

## Install

Recommended for product/application repos: install MuonTickets as a git submodule.

```bash
curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash
```

If you need a custom source repo for the submodule:

```bash
curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash -s -- --repo https://github.com/muonium-ai/muontickets.git
```

Template form for your own fork:

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/install.sh | bash -s -- --repo https://github.com/<org>/<repo>.git
```

Use direct checkout (this repository itself) only when developing MuonTickets core.

## Quickstart (uv)

For repos where MuonTickets is installed as submodule:

```bash
uv sync
uv run python3 tickets/mt/muontickets/muontickets/mt.py init
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

If you are in a direct MuonTickets checkout, use the root entrypoint:

```bash
uv run python3 mt.py --help
uv run python3 mt.py report --summary
```

## For Agents: Ticket Workflow

Agent quick-reference guide: see [skills.md](skills.md) for install modes, command workflows, and best practices.

Run these from the project root where MuonTickets is installed.

```bash
# 1) Pull latest board state
git pull

# 2) Pick the best ready ticket and claim it
uv run python3 tickets/mt/muontickets/muontickets/mt.py pick --owner agent-1

# 3) Inspect your claimed ticket(s)
uv run python3 tickets/mt/muontickets/muontickets/mt.py ls --status claimed --owner agent-1

# 4) Add progress updates while implementing
uv run python3 tickets/mt/muontickets/muontickets/mt.py comment T-000001 "Implemented parser and added tests"

# 5) Move ticket to review when done coding
uv run python3 tickets/mt/muontickets/muontickets/mt.py set-status T-000001 needs_review

# 6) Validate board consistency before commit/push
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

After merge, mark the ticket complete:

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py done T-000001
```

## Archive, Backlogs, and Ticket IDs

- Active tickets live in `tickets/`.
- Completed tickets can be moved to `tickets/archive/` using `mt archive`.
- `mt archive` refuses to move a ticket if active tickets still reference it in `depends_on` (unless `--force`).
- `mt validate` reports `depends_on archived ticket ...` when an active ticket depends on an archived ticket.
- Future/planned work can live in `tickets/backlogs/`.
- Ticket numbering is tracked in `tickets/last_ticket_id`.
- If `tickets/last_ticket_id` is missing, `mt` automatically rebuilds the next number by scanning ticket IDs across `tickets/`, `tickets/archive/`, and `tickets/backlogs/`.

## Ticket Template (`tickets/ticket.template`)

- On first install and on `mt init`, MuonTickets creates `tickets/ticket.template` if it does not already exist.
- Users can edit this file to set default ticket metadata/body preferences.
- `mt new "Title"` uses template defaults when available.
- CLI args override template values when provided (for example: `--priority`, `--type`, `--effort`, `--label`, `--tag`, `--depends-on`, `--goal`).
- Existing `tickets/ticket.template` files are never overwritten by installer/init.

Examples:

```bash
# Create ticket with sequence from tickets/last_ticket_id
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Implement feature X"

# Override template defaults for one ticket
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Hotfix auth" --priority p0 --type code --effort xs --label urgent --goal "Fix login regression"

# Archive a completed ticket
uv run python3 tickets/mt/muontickets/muontickets/mt.py archive T-000001
```

## Reporting (SQLite)

Generate a local SQLite report database (not committed):

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py report --summary
```

Run with search:

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py report --search auth --limit 20
```

By default this creates `tickets/tickets_report.sqlite3` and indexes ticket data from `tickets/`, `tickets/archive/`, and `tickets/backlogs/`.

## Changelog Process

- User-visible changes must include an entry in `CHANGELOG.md`.
- Use this format per entry: `YYYY-MM-DD | Type | Summary | Ticket: T-000123`.
- Ticket reference is required for traceability from feature/fix to planning artifact.
- Add changelog updates in the same PR/commit as the code/docs change.
