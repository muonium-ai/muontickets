# MuonTickets Skills Guide

This guide helps agents install and use MuonTickets consistently across repositories.

## Install Modes

### 1) Submodule install (default for most repos)

Use this when a product/application repository consumes MuonTickets:

```bash
curl -fsSL https://raw.githubusercontent.com/muonium-ai/muontickets/main/install.sh | bash
```

Primary command path after install:

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py <command>
```

### 2) Direct checkout (MuonTickets core development)

Use this only when you are working in the MuonTickets repository itself:

```bash
uv run python3 mt.py <command>
```

## Core Workflows

### Initialize board

```bash
# Submodule layout
uv run python3 tickets/mt/muontickets/muontickets/mt.py init

# Direct checkout
uv run python3 mt.py init
```

### Create ticket

```bash
# Submodule layout
uv run python3 tickets/mt/muontickets/muontickets/mt.py new "Implement feature X"

# Direct checkout
uv run python3 mt.py new "Implement feature X"
```

### Pick / claim work

```bash
# Pick best ready ticket for an agent
uv run python3 tickets/mt/muontickets/muontickets/mt.py pick --owner agent-1

# Claim a specific ticket
uv run python3 tickets/mt/muontickets/muontickets/mt.py claim T-000123 --owner agent-1
```

### Comment progress

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py comment T-000123 "Implemented parser and tests"
```

### Status transitions

```bash
# ready -> claimed
uv run python3 tickets/mt/muontickets/muontickets/mt.py claim T-000123 --owner agent-1

# claimed -> needs_review
uv run python3 tickets/mt/muontickets/muontickets/mt.py set-status T-000123 needs_review

# needs_review -> done
uv run python3 tickets/mt/muontickets/muontickets/mt.py done T-000123
```

### Validate board

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py validate
```

### Archive completed ticket

```bash
uv run python3 tickets/mt/muontickets/muontickets/mt.py archive T-000123
```

## Best Practices for Agents

- Dependency handling: respect `depends_on`; do not start dependent work until prerequisites are done unless explicitly instructed.
- Validation cadence: run `mt validate` before commit/push and after ticket metadata updates.
- Ownership hygiene: always set clear owner and branch when claiming; avoid multiple active claims unless team policy allows it.
- Status discipline: use the normal flow (`ready -> claimed -> needs_review -> done`) and avoid force transitions unless a human asks.
- Ticket quality: keep goals and acceptance criteria concrete so another agent can continue with minimal context loss.

## Template-first ticket creation

- MuonTickets supports `tickets/ticket.template` for default ticket shape.
- `mt new` uses template defaults when present.
- CLI arguments override template defaults for one-off needs.
