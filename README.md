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
