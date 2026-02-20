# muontickets
file based ticketing system for agents, resides under the tickets folder

## Install

Use this repository directly:

```bash
curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash -s -- --repo https://github.com/muonium-ai/muontickets.git
```

Template form:

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/install.sh | bash -s -- --repo https://github.com/<org>/<repo>.git
```

## Quickstart (uv)

```bash
uv sync
uv run python3 tickets/mt/muontickets/muontickets/mt.py init
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

## For Agents: Ticket Workflow

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
- Completed tickets can be moved to `archive/` using `mt archive`.
- Future/planned work can live in `backlogs/`.
- Ticket numbering is tracked in `tickets/last_ticket_id`.
- If `tickets/last_ticket_id` is missing, `mt` automatically rebuilds the next number by scanning ticket IDs across `tickets/`, `archive/`, and `backlogs/`.

Examples:

```bash
# Create ticket with sequence from tickets/last_ticket_id
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Implement feature X"

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

By default this creates `tickets/tickets_report.sqlite3` and indexes ticket data from `tickets/`, `archive/`, and `backlogs/`.
