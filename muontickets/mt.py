#!/usr/bin/env python3
"""
MuonTickets - a Git-native, file-based ticketing system built for agent swarms.

Why this exists:
- Agents scale when coordination is lightweight and deterministic.
- Git is already a distributed, offline-first coordination substrate.
- Tickets as files give you: diff, blame, PR review, grep, reproducibility.

Core concepts:
- tickets/T-000123.md: Markdown with YAML frontmatter
- status is the main "pheromone": ready -> claimed -> needs_review -> done (plus blocked)

Commands (high level):
  mt init
  mt new "Title"
  mt ls [filters]
  mt show T-000123
  mt pick --owner agent-1 [--label wasm]     # choose best ready ticket, claim it
    mt allocate-task --owner agent-1            # queue allocator, returns one ticket id
    mt fail-task T-000123 --error "..."        # record failed attempt and retry/escalate
  mt claim T-000123 --owner agent-1
  mt comment T-000123 "…"
  mt set-status T-000123 needs_review
  mt done T-000123
  mt graph --mermaid
  mt export --format json
  mt stats
  mt validate

Design choices for "best agent ticketing":
- Deterministic schema + validation
- Dependency-aware picking (no starting work when deps not done)
- Lease-based allocation + retry routing (queue mode)
- WIP limit enforcement (per owner)
- A single blessed entrypoint for CI/hooks (`mt validate`)

Note on dependencies:
- A ticket can be claimed only if all `depends_on` tickets are `done` (unless --ignore-deps).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

ID_RE = re.compile(r"^T-\d{6}$")
TICKET_FILE_RE = re.compile(r"^(T-\d{6})\.md$")
VERSION_RE = re.compile(r"^(\d+)\.(\d+)(?:\.(\d+))?$")
FRONTMATTER_BOUNDARY = "---"

DEFAULT_STATES = ["ready", "claimed", "blocked", "needs_review", "done"]
DEFAULT_PRIORITIES = ["p0", "p1", "p2"]
DEFAULT_TYPES = ["spec", "code", "tests", "docs", "refactor", "chore"]
DEFAULT_EFFORTS = ["xs", "s", "m", "l"]
TICKET_TEMPLATE_NAME = "ticket.template"

SKILL_PICK_PROFILES: Dict[str, Dict[str, List[str]]] = {
    "design": {"labels": ["design"], "types": ["spec", "docs"]},
    "database": {"labels": ["database"], "types": ["code", "refactor", "tests"]},
    "review": {"labels": ["review"], "types": ["tests", "docs"]},
}

ROLE_PICK_PROFILES: Dict[str, Dict[str, List[str]]] = {
    "architect": {"labels": ["design"], "types": ["spec", "docs", "refactor"]},
    "devops": {"labels": ["devops"], "types": ["code", "chore", "docs"]},
    "developer": {"labels": ["feature"], "types": ["code", "tests", "refactor"]},
    "reviewer": {"labels": ["review"], "types": ["tests", "docs"]},
}

# Allowed transitions (strict by default)
ALLOWED_TRANSITIONS = {
    "ready": {"claimed", "blocked"},
    "claimed": {"needs_review", "blocked", "ready"},   # allow unclaim -> ready (owner cleared)
    "blocked": {"ready", "claimed"},
    "needs_review": {"done", "claimed"},
    "done": set(),
}

PRIORITY_WEIGHT = {"p0": 300, "p1": 200, "p2": 100}
EFFORT_WEIGHT = {"xs": 40, "s": 30, "m": 20, "l": 10}
UTC = getattr(_dt, "UTC", _dt.timezone.utc)


def utc_now() -> _dt.datetime:
    return _dt.datetime.now(UTC)


def ensure_utc_aware(value: _dt.datetime) -> _dt.datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)

def today_str() -> str:
    return _dt.date.today().isoformat()

def now_compact() -> str:
    return utc_now().strftime("%Y%m%dT%H%M%SZ")

def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)

def load_yaml(text: str) -> Dict[str, Any]:
    """
    Prefer PyYAML if available; otherwise parse a tiny YAML subset.
    Frontmatter is intentionally simple.
    """
    try:
        import yaml  # type: ignore
        obj = yaml.safe_load(text) or {}
        if not isinstance(obj, dict):
            raise ValueError("YAML frontmatter must be a mapping/object.")
        return obj
    except Exception:
        data: Dict[str, Any] = {}
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            k = k.strip()
            v = v.strip()
            if v.lower() in ("null", "none", "~", ""):
                data[k] = None
                continue
            if v.startswith("[") and v.endswith("]"):
                inner = v[1:-1].strip()
                if not inner:
                    data[k] = []
                else:
                    parts = [p.strip().strip('"').strip("'") for p in inner.split(",")]
                    data[k] = [p for p in parts if p]
                continue
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                v = v[1:-1]
            # Try parse numbers
            if re.fullmatch(r"-?\d+(\.\d+)?", v):
                try:
                    data[k] = float(v) if "." in v else int(v)
                    continue
                except Exception:
                    pass
            data[k] = v
        return data

def dump_yaml(data: Dict[str, Any]) -> str:
    try:
        import yaml  # type: ignore
        return yaml.safe_dump(data, sort_keys=False).strip()
    except Exception:
        def fmt(v: Any) -> str:
            if v is None:
                return "null"
            if isinstance(v, bool):
                return "true" if v else "false"
            if isinstance(v, (int, float)):
                return str(v)
            if isinstance(v, list):
                inner = ", ".join(str(x) for x in v)
                return f"[{inner}]"
            s = str(v)
            if ":" in s or s != s.strip():
                return f'"{s}"'
            return s

        return "\n".join([f"{k}: {fmt(v)}" for k, v in data.items()]).strip()

def find_repo_root(start: Optional[str] = None) -> str:
    cur = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isdir(os.path.join(cur, "tickets")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.abspath(start or os.getcwd())
        cur = parent

def tickets_dir(repo_root: str) -> str:
    return os.path.join(repo_root, "tickets")

def archive_dir(repo_root: str) -> str:
    return os.path.join(repo_root, "tickets", "archive")

def errors_dir(repo_root: str) -> str:
    return os.path.join(repo_root, "tickets", "errors")

def backlogs_dir(repo_root: str) -> str:
    return os.path.join(repo_root, "tickets", "backlogs")

def incidents_log_path(repo_root: str) -> str:
    return os.path.join(tickets_dir(repo_root), "incidents.log")

def ticket_template_path(repo_root: str) -> str:
    return os.path.join(tickets_dir(repo_root), TICKET_TEMPLATE_NAME)

def last_ticket_id_path(repo_root: str) -> str:
    return os.path.join(tickets_dir(repo_root), "last_ticket_id")

def schema_path() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.json")

def version_file_path(repo_root: str) -> str:
    return os.path.join(repo_root, "VERSION")

def parse_major_minor_version(raw: str) -> Tuple[int, int]:
    text = (raw or "").strip()
    match = VERSION_RE.fullmatch(text)
    if not match:
        raise ValueError("VERSION must match '<major>.<minor>[.<patch>]' (example: 0.1 or 0.1.1)")
    major = int(match.group(1))
    minor = int(match.group(2))
    return major, minor

def load_repo_version(repo_root: str) -> Tuple[int, int]:
    path = version_file_path(repo_root)
    if not os.path.isfile(path):
        raise ValueError(f"Missing VERSION file at project root: {path}")
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()
    return parse_major_minor_version(raw)

def load_repo_version_text(repo_root: str) -> str:
    path = version_file_path(repo_root)
    if not os.path.isfile(path):
        raise ValueError(f"Missing VERSION file at project root: {path}")
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()
    text = (raw or "").strip()
    # Validate format via shared parser, but preserve optional patch text.
    parse_major_minor_version(text)
    return text

@dataclass
class Ticket:
    path: str
    meta: Dict[str, Any]
    body: str

def split_frontmatter(content: str) -> Tuple[Dict[str, Any], str]:
    lines = content.splitlines()
    if not lines or lines[0].strip() != FRONTMATTER_BOUNDARY:
        raise ValueError("Missing YAML frontmatter. Expected first line to be '---'.")
    try:
        end_idx = next(i for i in range(1, len(lines)) if lines[i].strip() == FRONTMATTER_BOUNDARY)
    except StopIteration:
        raise ValueError("Unterminated YAML frontmatter. Missing closing '---'.")
    fm_text = "\n".join(lines[1:end_idx]).strip() + "\n"
    body = "\n".join(lines[end_idx + 1:]).lstrip("\n")
    meta = load_yaml(fm_text)
    return meta, body

def join_frontmatter(meta: Dict[str, Any], body: str) -> str:
    fm = dump_yaml(meta)
    return f"{FRONTMATTER_BOUNDARY}\n{fm}\n{FRONTMATTER_BOUNDARY}\n\n{body.rstrip()}\n"

def read_ticket(path: str) -> Ticket:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    meta, body = split_frontmatter(content)
    return Ticket(path=path, meta=meta, body=body)

def write_ticket(t: Ticket) -> None:
    content = join_frontmatter(t.meta, t.body)
    directory = os.path.dirname(t.path) or "."
    os.makedirs(directory, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(prefix=".mt-tmp-", suffix=".md", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, t.path)
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except Exception:
                pass

def iter_ticket_files(tdir: str) -> List[str]:
    if not os.path.isdir(tdir):
        return []
    out = []
    for name in os.listdir(tdir):
        if TICKET_FILE_RE.match(name):
            out.append(os.path.join(tdir, name))
    return sorted(out)

def ensure_tickets_dir(tdir: str) -> None:
    os.makedirs(tdir, exist_ok=True)

def iter_ticket_files_recursive(root_dir: str) -> List[str]:
    if not os.path.isdir(root_dir):
        return []
    out: List[str] = []
    for root, _dirs, files in os.walk(root_dir):
        for name in files:
            if TICKET_FILE_RE.match(name):
                out.append(os.path.join(root, name))
    return sorted(out)

def all_ticket_paths(repo_root: str) -> List[str]:
    paths: List[str] = []
    for root in (tickets_dir(repo_root), archive_dir(repo_root), backlogs_dir(repo_root), errors_dir(repo_root)):
        paths.extend(iter_ticket_files_recursive(root))
    # de-duplicate while preserving sorted order
    return sorted(set(paths))

def extract_ticket_number(ticket_id: str) -> int:
    if not ID_RE.match(ticket_id):
        raise ValueError(f"Invalid ticket id: {ticket_id}")
    return int(ticket_id.split("-")[1])

def ticket_id_from_path(path: str) -> Optional[str]:
    m = TICKET_FILE_RE.match(os.path.basename(path))
    if not m:
        return None
    return m.group(1)

def scan_max_ticket_number(repo_root: str) -> int:
    max_n = 0
    for p in all_ticket_paths(repo_root):
        tid = ticket_id_from_path(p)
        if not tid:
            continue
        max_n = max(max_n, extract_ticket_number(tid))
    return max_n

def read_last_ticket_number(repo_root: str) -> Optional[int]:
    state_file = last_ticket_id_path(repo_root)
    if not os.path.exists(state_file):
        return None
    try:
        raw = open(state_file, "r", encoding="utf-8").read().strip()
    except Exception:
        return None
    if not raw:
        return None
    if ID_RE.match(raw):
        return extract_ticket_number(raw)
    if re.fullmatch(r"\d+", raw):
        return int(raw)
    return None

def write_last_ticket_number(repo_root: str, number: int) -> None:
    ensure_tickets_dir(tickets_dir(repo_root))
    with open(last_ticket_id_path(repo_root), "w", encoding="utf-8") as f:
        f.write(f"T-{number:06d}\n")

def next_ticket_id_for_repo(repo_root: str) -> str:
    tracked = read_last_ticket_number(repo_root)
    scanned = scan_max_ticket_number(repo_root)
    base = max(tracked or 0, scanned)
    nxt = base + 1
    write_last_ticket_number(repo_root, nxt)
    return f"T-{nxt:06d}"

def next_ticket_id(tdir: str) -> str:
    max_n = 0
    for p in iter_ticket_files(tdir):
        m = TICKET_FILE_RE.match(os.path.basename(p))
        if not m:
            continue
        tid = m.group(1)
        n = int(tid.split("-")[1])
        max_n = max(max_n, n)
    return f"T-{max_n+1:06d}"

def load_schema() -> Dict[str, Any]:
    with open(schema_path(), "r", encoding="utf-8") as f:
        return json.load(f)

def validate_against_schema(meta: Dict[str, Any], schema: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    required = schema.get("required", [])
    props = schema.get("properties", {})
    for k in required:
        if k not in meta:
            errors.append(f"missing required field '{k}'")

    for k, rule in props.items():
        if k not in meta:
            continue
        v = meta[k]
        if "enum" in rule and v is not None:
            if v not in rule["enum"]:
                errors.append(f"field '{k}' must be one of {rule['enum']}, got {v!r}")
        if "pattern" in rule and isinstance(v, str):
            if not re.match(rule["pattern"], v):
                errors.append(f"field '{k}' does not match pattern {rule['pattern']}, got {v!r}")
        if rule.get("type") == "array" and not isinstance(v, list):
            errors.append(f"field '{k}' must be an array/list")
        if rule.get("type") == "string":
            if not isinstance(v, str):
                errors.append(f"field '{k}' must be a string")
            else:
                if rule.get("minLength") and len(v) < int(rule["minLength"]):
                    errors.append(f"field '{k}' too short (min {rule['minLength']})")
        if rule.get("type") == "number" and not isinstance(v, (int, float)):
            errors.append(f"field '{k}' must be a number")
        if "oneOf" in rule:
            ok = False
            for opt in rule["oneOf"]:
                t = opt.get("type")
                if t == "null" and v is None:
                    ok = True
                elif t == "string" and isinstance(v, str) and (not opt.get("minLength") or len(v) >= int(opt["minLength"])):
                    ok = True
            if not ok:
                errors.append(f"field '{k}' must satisfy oneOf, got {v!r}")
    return errors

def normalize_meta(meta: Dict[str, Any]) -> Dict[str, Any]:
    meta.setdefault("labels", [])
    meta.setdefault("depends_on", [])
    meta.setdefault("owner", None)
    meta.setdefault("branch", None)
    meta.setdefault("effort", "s")
    meta.setdefault("tags", [])
    meta.setdefault("retry_count", 0)
    meta.setdefault("retry_limit", 3)
    meta.setdefault("allocated_to", None)
    meta.setdefault("allocated_at", None)
    meta.setdefault("lease_expires_at", None)
    meta.setdefault("last_error", None)
    meta.setdefault("last_attempted_at", None)
    return meta

def now_utc_iso() -> str:
    return utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")

def parse_utc_iso(ts: Any) -> Optional[_dt.datetime]:
    if isinstance(ts, _dt.datetime):
        return ensure_utc_aware(ts)
    if not isinstance(ts, str) or not ts.strip():
        return None
    t = ts.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(t)
    except Exception:
        return None
    return ensure_utc_aware(parsed)

def lease_expired(meta: Dict[str, Any], now: Optional[_dt.datetime] = None) -> bool:
    lease_raw = meta.get("lease_expires_at")
    lease_dt = parse_utc_iso(lease_raw)
    if lease_dt is None:
        return False
    check_now = ensure_utc_aware(now) if now is not None else utc_now()
    return check_now >= lease_dt

def append_incident(repo_root: str, message: str) -> None:
    ensure_tickets_dir(tickets_dir(repo_root))
    with open(incidents_log_path(repo_root), "a", encoding="utf-8") as f:
        f.write(f"{now_utc_iso()} {message}\n")

def default_ticket_template_text() -> str:
    return """---
id: T-000000
title: Template: replace title
status: ready
priority: p1
type: code
effort: s
labels: []
tags: []
owner: null
created: 1970-01-01T00:00:00Z
updated: 1970-01-01T00:00:00Z
depends_on: []
branch: null
retry_count: 0
retry_limit: 3
allocated_to: null
allocated_at: null
lease_expires_at: null
last_error: null
last_attempted_at: null
---

## Goal
Write a single-sentence goal.

## Acceptance Criteria
- [ ] Define clear, testable checks (2–5 items)

## Notes

## Agent Assignment
- Suggested owner: agent-name
- Suggested branch: feature/short-name

## Implementation Plan
- [ ] Describe 2-4 concrete execution steps
- [ ] List test/validation commands to run
- [ ] Note any dependency handoff requirements

## Queue Lifecycle (if allocated)
- [ ] Add progress with `mt comment <id> "..."`
- [ ] If blocked/failing, run `mt fail-task <id> --error "..."`
- [ ] On completion, move to `needs_review` then `done`
"""

def ensure_ticket_template(repo_root: str) -> bool:
    path = ticket_template_path(repo_root)
    if os.path.exists(path):
        return False
    ensure_tickets_dir(tickets_dir(repo_root))
    with open(path, "w", encoding="utf-8") as f:
        f.write(default_ticket_template_text())
    return True

def validate_transition(old_status: str, new_status: str) -> Optional[str]:
    if old_status not in ALLOWED_TRANSITIONS:
        return f"unknown old status {old_status!r}"
    if new_status not in DEFAULT_STATES:
        return f"unknown new status {new_status!r}"
    if new_status not in ALLOWED_TRANSITIONS[old_status]:
        return f"invalid transition {old_status!r} -> {new_status!r}"
    return None

def ticket_summary(meta: Dict[str, Any]) -> str:
    tid = meta.get("id", "?")
    st = meta.get("status", "?")
    pr = meta.get("priority", "?")
    tp = meta.get("type", "?")
    eff = meta.get("effort", "?")
    owner = meta.get("owner", "") or ""
    title = str(meta.get("title", "")).strip()
    labels = ",".join(meta.get("labels", []) or [])
    return f"{tid}  {st:<12} {pr:<2} {tp:<8} {eff:<2} {owner:<12}  {title}  [{labels}]"

def load_all_tickets(repo: str) -> List[Ticket]:
    tdir = tickets_dir(repo)
    tickets = []
    for p in iter_ticket_files(tdir):
        try:
            tickets.append(read_ticket(p))
        except Exception as ex:
            tickets.append(Ticket(path=p, meta={"_parse_error": str(ex)}, body=""))
    return tickets

def find_ticket_by_id(repo: str, tid: str) -> Ticket:
    if not ID_RE.match(tid):
        raise ValueError(f"Invalid ticket id: {tid}")
    path = os.path.join(tickets_dir(repo), f"{tid}.md")
    if not os.path.exists(path):
        raise FileNotFoundError(f"Ticket not found: {path}")
    return read_ticket(path)

def deps_satisfied(meta: Dict[str, Any], id_to_meta: Dict[str, Dict[str, Any]]) -> Tuple[bool, List[str]]:
    missing = []
    for dep in meta.get("depends_on") or []:
        d = id_to_meta.get(dep)
        if not d:
            missing.append(dep)
        else:
            if d.get("status") != "done":
                missing.append(dep)
    return (len(missing) == 0, missing)

def compute_score(meta: Dict[str, Any], id_to_meta: Dict[str, Dict[str, Any]]) -> float:
    """
    Higher score = more desirable to pick next.
    Factors:
    - priority (p0 highest)
    - smaller effort preferred (xs > s > m > l)
    - fewer dependencies preferred
    - older tickets preferred (created timestamp)
    """
    pr = str(meta.get("priority", "p2"))
    eff = str(meta.get("effort", "s"))
    deps = meta.get("depends_on") or []
    created = str(meta.get("created", "1970-01-01T00:00:00Z"))

    base = PRIORITY_WEIGHT.get(pr, 0) + EFFORT_WEIGHT.get(eff, 0)
    dep_penalty = 5 * len(deps)
    created_dt = parse_utc_iso(created)
    if created_dt is None:
        age_days = 0
    else:
        age_days = (utc_now() - created_dt).days

    # If deps not satisfied, make it unpickable (score very low)
    ok, _ = deps_satisfied(meta, id_to_meta)
    if not ok:
        return -1e9

    return float(base + min(age_days, 365) - dep_penalty)

def cmd_init(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tdir = tickets_dir(repo)
    if not os.path.isdir(tdir):
        os.makedirs(tdir, exist_ok=True)
        print(f"created {tdir}")
    else:
        print(f"tickets dir exists: {tdir}")

    if ensure_ticket_template(repo):
        print(f"created {ticket_template_path(repo)}")

    # Create an example ticket if none exist
    if not iter_ticket_files(tdir):
        tid = next_ticket_id_for_repo(repo)
        meta = normalize_meta({
            "id": tid,
            "title": "Example: replace this ticket",
            "status": "ready",
            "priority": "p2",
            "type": "chore",
            "effort": "xs",
            "labels": ["example"],
            "tags": [],
            "owner": None,
            "created": now_utc_iso(),
            "updated": now_utc_iso(),
            "depends_on": [],
            "branch": None,
        })
        body = """## Goal
Replace this example with a real task.

## Acceptance Criteria
- [ ] Delete or edit this ticket
- [ ] Create at least one real ticket with `mt new`

## Notes
This repository uses MuonTickets for agent-friendly coordination.
"""
        write_ticket(Ticket(path=os.path.join(tdir, f"{tid}.md"), meta=meta, body=body))
        print(f"created example ticket {tid}")
    else:
        # Keep state file in sync even when board already exists.
        tracked = read_last_ticket_number(repo)
        scanned = scan_max_ticket_number(repo)
        if tracked is None or tracked < scanned:
            write_last_ticket_number(repo, scanned)
            print(f"updated {last_ticket_id_path(repo)} to T-{scanned:06d}")
    return 0

def cmd_new(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tdir = tickets_dir(repo)
    ensure_tickets_dir(tdir)

    tid = next_ticket_id_for_repo(repo)
    title = args.title.strip()

    template_meta: Dict[str, Any] = {}
    template_body = ""
    tpath = ticket_template_path(repo)
    if os.path.exists(tpath):
        try:
            tpl = read_ticket(tpath)
        except Exception as ex:
            eprint(f"Invalid ticket template at {tpath}: {ex}")
            return 2
        template_meta = normalize_meta(tpl.meta)
        template_body = tpl.body

    priority = args.priority if args.priority is not None else str(template_meta.get("priority", "p1"))
    ticket_type = args.type if args.type is not None else str(template_meta.get("type", "code"))
    effort = args.effort if args.effort is not None else str(template_meta.get("effort", "s"))

    if priority not in DEFAULT_PRIORITIES:
        eprint(f"Invalid priority {priority!r} from CLI/template. Allowed: {DEFAULT_PRIORITIES}")
        return 2
    if ticket_type not in DEFAULT_TYPES:
        eprint(f"Invalid type {ticket_type!r} from CLI/template. Allowed: {DEFAULT_TYPES}")
        return 2
    if effort not in DEFAULT_EFFORTS:
        eprint(f"Invalid effort {effort!r} from CLI/template. Allowed: {DEFAULT_EFFORTS}")
        return 2

    labels = args.label if args.label else list(template_meta.get("labels") or [])
    tags = args.tag if args.tag else list(template_meta.get("tags") or [])
    depends_on = args.depends_on if args.depends_on else list(template_meta.get("depends_on") or [])

    status = str(template_meta.get("status", "ready"))
    if status not in DEFAULT_STATES:
        status = "ready"
    owner = template_meta.get("owner")
    if not isinstance(owner, str):
        owner = None
    branch = template_meta.get("branch")
    if not isinstance(branch, str):
        branch = None

    meta = normalize_meta({
        "id": tid,
        "title": title,
        "status": status,
        "priority": priority,
        "type": ticket_type,
        "effort": effort,
        "labels": labels,
        "tags": tags,
        "owner": owner,
        "created": now_utc_iso(),
        "updated": now_utc_iso(),
        "depends_on": depends_on,
        "branch": branch,
    })

    if args.goal:
        body = f"""## Goal
{args.goal}

## Acceptance Criteria
- [ ] Define clear, testable checks (2–5 items)

## Notes
"""
    elif template_body.strip():
        body = template_body
    else:
        body = """## Goal
Write a single-sentence goal.

## Acceptance Criteria
- [ ] Define clear, testable checks (2–5 items)

## Notes
"""
    path = os.path.join(tdir, f"{tid}.md")
    write_ticket(Ticket(path=path, meta=meta, body=body))
    print(path)
    return 0

def cmd_ls(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tickets = load_all_tickets(repo)

    rows = []
    for t in tickets:
        meta = t.meta
        if "_parse_error" in meta:
            if args.show_invalid:
                rows.append(f"{os.path.basename(t.path)}  PARSE_ERROR  {meta['_parse_error']}")
            continue
        meta = normalize_meta(meta)
        if args.status and meta.get("status") != args.status:
            continue
        if args.owner is not None:
            # owner filter: '' means unowned
            if args.owner == "":
                if meta.get("owner") is not None:
                    continue
            else:
                if (meta.get("owner") or "") != args.owner:
                    continue
        if args.priority and meta.get("priority") != args.priority:
            continue
        if args.type and meta.get("type") != args.type:
            continue
        if args.label:
            labels = set(meta.get("labels") or [])
            if not set(args.label).issubset(labels):
                continue
        rows.append(ticket_summary(meta))

    if rows:
        print("ID       STATUS        PR TYPE     EF OWNER         TITLE  [LABELS]")
        print("-" * 110)
        for r in rows:
            print(r)
    return 0

def cmd_show(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    t = find_ticket_by_id(repo, args.id)
    print(join_frontmatter(t.meta, t.body))
    return 0

def _default_branch(meta: Dict[str, Any]) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", str(meta.get("title", "")).lower()).strip("-")
    slug = slug[:40] if slug else "task"
    return f"bug/{str(meta.get('id','')).lower()}-{slug}"

def cmd_claim(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    t = find_ticket_by_id(repo, args.id)
    meta = normalize_meta(t.meta)
    old = meta.get("status")

    if old != "ready" and not args.force:
        eprint(f"Refusing to claim: status is {old!r} (expected 'ready'). Use --force to override.")
        return 2

    # dependency gate
    tickets = load_all_tickets(repo)
    id_to_meta = {normalize_meta(x.meta).get("id"): normalize_meta(x.meta) for x in tickets if "_parse_error" not in x.meta}
    ok, missing = deps_satisfied(meta, id_to_meta)
    if not ok and not args.ignore_deps:
        eprint(f"Refusing to claim: dependencies not done: {missing}. Use --ignore-deps to override.")
        return 2

    meta["status"] = "claimed"
    meta["owner"] = args.owner
    meta["branch"] = args.branch.strip() if args.branch else _default_branch(meta)
    meta["updated"] = now_utc_iso()

    t.meta = meta
    write_ticket(t)
    print(f"claimed {args.id} as {args.owner} (branch: {meta['branch']})")
    return 0

def append_progress_log(body: str, line: str) -> str:
    marker = "## Progress Log"
    if marker not in body:
        body = body.rstrip() + "\n\n" + marker + "\n"
    return body.rstrip() + f"\n- {today_str()}: {line}\n"

def cmd_comment(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    t = find_ticket_by_id(repo, args.id)
    meta = normalize_meta(t.meta)
    meta["updated"] = now_utc_iso()
    t.meta = meta
    t.body = append_progress_log(t.body, args.text.strip())
    write_ticket(t)
    print(f"commented on {args.id}")
    return 0

def cmd_set_status(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    t = find_ticket_by_id(repo, args.id)
    meta = normalize_meta(t.meta)
    old = meta.get("status")
    new = args.status

    if old == new:
        print(f"{args.id} already {new}")
        return 0

    if not args.force:
        msg = validate_transition(str(old), str(new))
        if msg:
            eprint(f"Refusing: {msg}. Use --force to override.")
            return 2

    if new == "ready" and args.clear_owner:
        meta["owner"] = None
        meta["branch"] = None

    meta["status"] = new
    meta["updated"] = now_utc_iso()
    t.meta = meta
    write_ticket(t)
    print(f"{args.id}: {old} -> {new}")
    return 0

def cmd_done(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    t = find_ticket_by_id(repo, args.id)
    meta = normalize_meta(t.meta)
    old = meta.get("status")

    if old != "needs_review" and not args.force:
        eprint(f"Refusing to mark done: status is {old!r} (expected 'needs_review'). Use set-status first or --force.")
        return 2

    meta["status"] = "done"
    meta["updated"] = now_utc_iso()
    t.meta = meta
    write_ticket(t)
    print(f"done {args.id}")
    return 0

def _is_active_status(status: Any) -> bool:
    return isinstance(status, str) and status in DEFAULT_STATES and status != "done"

def _collect_active_dependents(repo: str, ticket_id: str) -> List[str]:
    dependents: List[str] = []
    for candidate in load_all_tickets(repo):
        cmeta = candidate.meta
        if "_parse_error" in cmeta:
            continue
        cmeta = normalize_meta(cmeta)
        cid = cmeta.get("id")
        if cid == ticket_id:
            continue
        if not _is_active_status(cmeta.get("status")):
            continue
        deps = cmeta.get("depends_on") or []
        if ticket_id in deps:
            dependents.append(str(cid))
    return sorted(dependents)

def _compute_archive_safe_leaf_set(repo: str, exclude_id: Optional[str] = None) -> List[str]:
    done_ids: List[str] = []
    active_dep_targets: set[str] = set()

    for candidate in load_all_tickets(repo):
        cmeta = candidate.meta
        if "_parse_error" in cmeta:
            continue
        cmeta = normalize_meta(cmeta)
        cid = cmeta.get("id")
        if not isinstance(cid, str):
            continue
        if exclude_id and cid == exclude_id:
            continue

        if cmeta.get("status") == "done":
            done_ids.append(cid)

        if _is_active_status(cmeta.get("status")):
            for dep in cmeta.get("depends_on") or []:
                if isinstance(dep, str):
                    active_dep_targets.add(dep)

    return sorted([tid for tid in done_ids if tid not in active_dep_targets])

def cmd_archive(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    t = find_ticket_by_id(repo, args.id)
    meta = normalize_meta(t.meta)

    if meta.get("status") != "done" and not args.force:
        eprint(f"Refusing to archive: status is {meta.get('status')!r} (expected 'done'). Use --force to override.")
        return 2

    dependents = _collect_active_dependents(repo, args.id)

    if dependents and not args.force:
        dep_list = ", ".join(dependents)
        safe_leaf_set = _compute_archive_safe_leaf_set(repo, exclude_id=args.id)
        eprint(
            "Refusing to archive: active tickets depend on this ticket: "
            f"{dep_list}. Resolve/update their depends_on first. "
            "Warning: using --force can leave invalid active references to archived tickets."
        )
        if safe_leaf_set:
            eprint(
                "archive-safe leaf set (done tickets with no active dependents): "
                + ", ".join(safe_leaf_set)
            )
            eprint("You can archive these now:")
            for tid in safe_leaf_set:
                eprint(f"  mt archive {tid}")
        else:
            eprint("No completed tickets are currently archive-safe.")
            eprint("Hint: run mt graph to inspect dependency structure.")
        return 2

    if dependents and args.force:
        dep_list = ", ".join(dependents)
        eprint(
            "Warning: force-archiving with active dependents: "
            f"{dep_list}. This can create invalid board state where active tickets depend_on archived tickets."
        )

    target_dir = archive_dir(repo)
    os.makedirs(target_dir, exist_ok=True)
    dst = os.path.join(target_dir, os.path.basename(t.path))
    if os.path.exists(dst):
        eprint(f"Refusing to archive: destination already exists: {dst}")
        return 2

    shutil.move(t.path, dst)
    print(f"archived {args.id} -> {os.path.relpath(dst, repo)}")
    return 0

def validate_wip_limit(tickets: List[Ticket], max_claimed_per_owner: int) -> List[str]:
    counts: Dict[str, int] = {}
    for t in tickets:
        meta = t.meta
        if "_parse_error" in meta:
            continue
        if meta.get("status") == "claimed":
            owner = meta.get("owner")
            if owner:
                counts[owner] = counts.get(owner, 0) + 1
    errs = []
    for owner, c in counts.items():
        if c > max_claimed_per_owner:
            errs.append(f"owner {owner!r} has {c} claimed tickets (max {max_claimed_per_owner})")
    return errs

def validate_depends(tickets: List[Ticket], archived_ids: Optional[set[str]] = None) -> List[str]:
    existing = set()
    id_to_meta: Dict[str, Dict[str, Any]] = {}
    archived = archived_ids or set()
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        m = normalize_meta(t.meta)
        tid = m.get("id")
        existing.add(tid)
        id_to_meta[tid] = m

    errs = []
    for t in tickets:
        meta = t.meta
        if "_parse_error" in meta:
            continue
        meta = normalize_meta(meta)
        tid = meta.get("id")
        for dep in meta.get("depends_on") or []:
            if dep not in existing:
                if dep in archived:
                    errs.append(
                        f"{tid} depends_on archived ticket {dep} "
                        f"(fix by unarchiving {dep} or removing/updating {tid}.depends_on; avoid mt archive --force when active dependents exist)"
                    )
                else:
                    errs.append(f"{tid} depends_on missing ticket {dep}")
    return errs

def validate_claimable_deps(tickets: List[Ticket]) -> List[str]:
    """
    Stronger rule: if a ticket is claimed/needs_review/done, all dependencies must exist.
    If status is claimed/needs_review/done, dependencies should be done (unless explicitly allowed by team).
    """
    id_to_meta: Dict[str, Dict[str, Any]] = {}
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        m = normalize_meta(t.meta)
        id_to_meta[m.get("id")] = m

    errs = []
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        meta = normalize_meta(t.meta)
        st = meta.get("status")
        if st in ("claimed", "needs_review", "done"):
            ok, missing = deps_satisfied(meta, id_to_meta)
            if not ok and meta.get("depends_on"):
                errs.append(f"{meta.get('id')} status {st} but deps not done: {missing}")
    return errs

def cmd_validate(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tickets = load_all_tickets(repo)
    archived_ids = set()
    for p in iter_ticket_files_recursive(archive_dir(repo)):
        try:
            archived_ticket = read_ticket(p)
            archived_meta = normalize_meta(archived_ticket.meta)
            archived_tid = archived_meta.get("id")
            if isinstance(archived_tid, str):
                archived_ids.add(archived_tid)
        except Exception:
            continue
    schema = load_schema()

    errors: List[str] = []

    for t in tickets:
        meta = t.meta
        if "_parse_error" in meta:
            errors.append(f"{os.path.basename(t.path)}: {meta['_parse_error']}")
            continue
        meta = normalize_meta(meta)

        errs = validate_against_schema(meta, schema)
        for e in errs:
            errors.append(f"{os.path.basename(t.path)}: {e}")

        if meta.get("status") == "claimed" and not meta.get("owner"):
            errors.append(f"{os.path.basename(t.path)}: claimed ticket must have owner")
        if meta.get("status") in ("needs_review", "done") and not meta.get("branch"):
            errors.append(f"{os.path.basename(t.path)}: status {meta.get('status')} should have branch set")

        created = meta.get("created")
        updated = meta.get("updated")
        if isinstance(created, str) and isinstance(updated, str) and updated < created:
            errors.append(f"{os.path.basename(t.path)}: updated ({updated}) is earlier than created ({created})")

        # effort sanity
        eff = meta.get("effort", "s")
        if eff not in DEFAULT_EFFORTS:
            errors.append(f"{os.path.basename(t.path)}: effort must be one of {DEFAULT_EFFORTS}, got {eff!r}")

    errors += validate_wip_limit(tickets, args.max_claimed_per_owner)
    errors += validate_depends(tickets, archived_ids)
    if args.enforce_done_deps:
        errors += validate_claimable_deps(tickets)

    if errors:
        eprint("MuonTickets validation FAILED:")
        for e in errors:
            eprint(f" - {e}")
        return 1

    print("MuonTickets validation OK.")
    return 0

def cmd_stats(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tickets = load_all_tickets(repo)
    by_status: Dict[str, int] = {}
    by_owner: Dict[str, int] = {}
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        meta = normalize_meta(t.meta)
        st = meta.get("status")
        by_status[st] = by_status.get(st, 0) + 1
        if st == "claimed":
            owner = meta.get("owner") or "<unowned>"
            by_owner[owner] = by_owner.get(owner, 0) + 1

    print("Status counts:")
    for st in DEFAULT_STATES:
        print(f"  {st:<12} {by_status.get(st, 0)}")
    if by_owner:
        print("\nClaimed by owner:")
        for owner, c in sorted(by_owner.items(), key=lambda x: (-x[1], x[0])):
            print(f"  {owner:<20} {c}")
    return 0

def cmd_export(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tickets = load_all_tickets(repo)
    out = []
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        meta = normalize_meta(t.meta)
        body = t.body.strip()
        excerpt = body.splitlines()[0:20]
        out.append({
            "id": meta.get("id"),
            "title": meta.get("title"),
            "status": meta.get("status"),
            "priority": meta.get("priority"),
            "type": meta.get("type"),
            "effort": meta.get("effort"),
            "labels": meta.get("labels"),
            "tags": meta.get("tags", []),
            "owner": meta.get("owner"),
            "created": meta.get("created"),
            "updated": meta.get("updated"),
            "depends_on": meta.get("depends_on"),
            "branch": meta.get("branch"),
            "excerpt": "\n".join(excerpt).strip(),
            "path": os.path.relpath(t.path, repo),
        })

    if args.format == "json":
        print(json.dumps(out, indent=2))
    elif args.format == "jsonl":
        for row in out:
            print(json.dumps(row))
    else:
        eprint("Unsupported format:", args.format)
        return 2
    return 0

def cmd_graph(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tickets = load_all_tickets(repo)
    id_to_meta: Dict[str, Dict[str, Any]] = {}
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        m = normalize_meta(t.meta)
        id_to_meta[m.get("id")] = m

    # Edges dep -> ticket
    edges = []
    for tid, m in id_to_meta.items():
        if args.open_only and m.get("status") == "done":
            continue
        for dep in m.get("depends_on") or []:
            edges.append((dep, tid))

    if args.mermaid:
        print("```mermaid")
        print("graph TD")
        for dep, tid in edges:
            print(f'  {dep} --> {tid}')
        print("```")
    else:
        # simple text
        for dep, tid in edges:
            print(f"{dep} -> {tid}")
    return 0

def cmd_pick(args: argparse.Namespace) -> int:
    """
    Pick the best ready ticket for this agent and claim it.
    This is the main swarm primitive.
    """
    repo = find_repo_root()
    tickets = load_all_tickets(repo)
    schema = load_schema()  # ensure schema exists

    # Validate quickly before acting (avoid claiming into a broken board)
    # (We don't run full validate here to keep pick fast; but ensure parses ok.)
    id_to_meta: Dict[str, Dict[str, Any]] = {}
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        m = normalize_meta(t.meta)
        # minimal schema check for required fields
        if validate_against_schema(m, schema):
            continue
        id_to_meta[m.get("id")] = m

    # Enforce WIP max
    claimed_count = 0
    for m in id_to_meta.values():
        if m.get("status") == "claimed" and (m.get("owner") or "") == args.owner:
            claimed_count += 1
    if claimed_count >= args.max_claimed_per_owner:
        eprint(f"owner {args.owner!r} already has {claimed_count} claimed tickets (max {args.max_claimed_per_owner}).")
        return 2

    required_labels: List[str] = list(args.label)
    avoid_labels: List[str] = list(args.avoid_label)
    type_candidates: Optional[set[str]] = {args.type} if args.type else None

    if args.skill:
        prof = SKILL_PICK_PROFILES[args.skill]
        for label in prof.get("labels", []):
            if label not in required_labels:
                required_labels.append(label)
        skill_types = set(prof.get("types", []))
        type_candidates = skill_types if type_candidates is None else type_candidates & skill_types

    if args.role:
        prof = ROLE_PICK_PROFILES[args.role]
        for label in prof.get("labels", []):
            if label not in required_labels:
                required_labels.append(label)
        role_types = set(prof.get("types", []))
        type_candidates = role_types if type_candidates is None else type_candidates & role_types

    if type_candidates is not None and not type_candidates:
        eprint("no compatible type filter remains after combining --type/--skill/--role")
        return 2

    candidates = []
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        meta = normalize_meta(t.meta)

        if meta.get("status") != "ready":
            continue
        if args.priority and meta.get("priority") != args.priority:
            continue
        if type_candidates is not None and meta.get("type") not in type_candidates:
            continue
        if required_labels:
            labels = set(meta.get("labels") or [])
            if not set(required_labels).issubset(labels):
                continue
        if avoid_labels:
            labels = set(meta.get("labels") or [])
            if set(avoid_labels) & labels:
                continue

        # deps gate
        ok, missing = deps_satisfied(meta, id_to_meta)
        if not ok and not args.ignore_deps:
            continue

        score = compute_score(meta, id_to_meta)
        candidates.append((score, meta.get("updated", ""), meta.get("id"), t.path))

    if not candidates:
        eprint("no claimable tickets found (ready + deps satisfied + filters).")
        return 3

    # Highest score; tie-break on older updated (prefer stale), then id
    candidates.sort(key=lambda x: (-x[0], x[1], x[2]))
    score, _, tid, path = candidates[0]

    # Claim by editing the ticket file
    ticket = read_ticket(path)
    meta = normalize_meta(ticket.meta)

    meta["status"] = "claimed"
    meta["owner"] = args.owner
    meta["branch"] = args.branch.strip() if args.branch else _default_branch(meta)
    meta["updated"] = now_utc_iso()
    meta["score"] = float(score)

    ticket.meta = meta
    write_ticket(ticket)

    # Emit machine-readable line if requested
    if args.json:
        print(json.dumps({"picked": tid, "owner": args.owner, "branch": meta["branch"], "score": score}))
    else:
        print(f"picked {tid} (score {score:.1f}) -> claimed as {args.owner} (branch: {meta['branch']})")
    return 0

def cmd_allocate_task(args: argparse.Namespace) -> int:
    """
    Queue-style allocation primitive.
    Allocates one task (ticket id), applies a lease, and supports stale lease re-allocation.
    """
    repo = find_repo_root()
    tickets = load_all_tickets(repo)
    schema = load_schema()

    id_to_meta: Dict[str, Dict[str, Any]] = {}
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        m = normalize_meta(t.meta)
        if validate_against_schema(m, schema):
            continue
        id_to_meta[m.get("id")] = m

    claimed_count = 0
    now = utc_now()
    for m in id_to_meta.values():
        if m.get("status") == "claimed" and (m.get("owner") or "") == args.owner:
            if not lease_expired(m, now=now):
                claimed_count += 1
    if claimed_count >= args.max_claimed_per_owner:
        eprint(f"owner {args.owner!r} already has {claimed_count} active leases (max {args.max_claimed_per_owner}).")
        return 2

    required_labels: List[str] = list(args.label)
    avoid_labels: List[str] = list(args.avoid_label)
    type_candidates: Optional[set[str]] = {args.type} if args.type else None

    if args.skill:
        prof = SKILL_PICK_PROFILES[args.skill]
        for label in prof.get("labels", []):
            if label not in required_labels:
                required_labels.append(label)
        skill_types = set(prof.get("types", []))
        type_candidates = skill_types if type_candidates is None else type_candidates & skill_types

    if args.role:
        prof = ROLE_PICK_PROFILES[args.role]
        for label in prof.get("labels", []):
            if label not in required_labels:
                required_labels.append(label)
        role_types = set(prof.get("types", []))
        type_candidates = role_types if type_candidates is None else type_candidates & role_types

    if type_candidates is not None and not type_candidates:
        eprint("no compatible type filter remains after combining --type/--skill/--role")
        return 2

    candidates = []
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        meta = normalize_meta(t.meta)
        status = meta.get("status")
        if status == "ready":
            pass
        elif status == "claimed":
            if not lease_expired(meta, now=now):
                continue
        else:
            continue

        if args.priority and meta.get("priority") != args.priority:
            continue
        if type_candidates is not None and meta.get("type") not in type_candidates:
            continue
        if required_labels:
            labels = set(meta.get("labels") or [])
            if not set(required_labels).issubset(labels):
                continue
        if avoid_labels:
            labels = set(meta.get("labels") or [])
            if set(avoid_labels) & labels:
                continue

        ok, _missing = deps_satisfied(meta, id_to_meta)
        if not ok and not args.ignore_deps:
            continue

        score = compute_score(meta, id_to_meta)
        candidates.append((score, meta.get("updated", ""), meta.get("id"), t.path))

    if not candidates:
        eprint("no allocatable tickets found (ready or lease-expired claimed + deps satisfied + filters).")
        return 3

    candidates.sort(key=lambda x: (-x[0], x[1], x[2]))
    score, _updated, tid, path = candidates[0]

    ticket = read_ticket(path)
    meta = normalize_meta(ticket.meta)

    previous_owner = meta.get("owner")
    previous_lease = meta.get("lease_expires_at")
    was_stale_reallocation = meta.get("status") == "claimed" and lease_expired(meta, now=now)

    lease_minutes = max(1, int(args.lease_minutes))
    lease_until = now + _dt.timedelta(minutes=lease_minutes)

    meta["status"] = "claimed"
    meta["owner"] = args.owner
    meta["allocated_to"] = args.owner
    meta["allocated_at"] = now_utc_iso()
    meta["lease_expires_at"] = lease_until.replace(microsecond=0).isoformat() + "Z"
    meta["last_attempted_at"] = now_utc_iso()
    meta["updated"] = now_utc_iso()
    meta["score"] = float(score)
    meta["branch"] = args.branch.strip() if args.branch else _default_branch(meta)

    ticket.meta = meta
    write_ticket(ticket)

    if was_stale_reallocation:
        append_incident(
            repo,
            f"stale-lease-reallocation id={tid} from_owner={previous_owner} to_owner={args.owner} prior_lease_expires_at={previous_lease}",
        )

    if args.json:
        print(json.dumps({
            "ticket_id": tid,
            "owner": args.owner,
            "branch": meta["branch"],
            "lease_expires_at": meta["lease_expires_at"],
            "score": score,
        }))
    else:
        print(tid)
    return 0

def cmd_fail_task(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    t = find_ticket_by_id(repo, args.id)
    meta = normalize_meta(t.meta)

    if meta.get("status") != "claimed" and not args.force:
        eprint(f"Refusing to fail task: status is {meta.get('status')!r} (expected 'claimed'). Use --force to override.")
        return 2

    retry_count = int(meta.get("retry_count") or 0) + 1
    retry_limit_raw = args.retry_limit if args.retry_limit is not None else meta.get("retry_limit")
    retry_limit = int(retry_limit_raw or 3)
    retry_limit = max(1, retry_limit)

    meta["retry_count"] = retry_count
    meta["retry_limit"] = retry_limit
    meta["last_error"] = args.error.strip()
    meta["last_attempted_at"] = now_utc_iso()
    meta["updated"] = now_utc_iso()

    exhausted = retry_count >= retry_limit
    if exhausted:
        meta["status"] = "blocked"
        meta["owner"] = None
        meta["branch"] = None
        meta["allocated_to"] = None
        meta["allocated_at"] = None
        meta["lease_expires_at"] = None
        t.meta = meta

        target_dir = errors_dir(repo)
        os.makedirs(target_dir, exist_ok=True)
        dst = os.path.join(target_dir, os.path.basename(t.path))
        if os.path.exists(dst):
            eprint(f"Refusing to move to errors: destination already exists: {dst}")
            return 2
        write_ticket(t)
        shutil.move(t.path, dst)
        append_incident(repo, f"retry-limit-exhausted id={args.id} retries={retry_count} moved_to=tickets/errors")
        print(f"{args.id} exceeded retry_limit ({retry_limit}) -> moved to tickets/errors/{args.id}.md")
        return 0

    meta["status"] = "ready"
    meta["owner"] = None
    meta["branch"] = None
    meta["allocated_to"] = None
    meta["allocated_at"] = None
    meta["lease_expires_at"] = None
    t.meta = meta
    t.body = append_progress_log(t.body, f"attempt failed (retry {retry_count}/{retry_limit}): {args.error.strip()}")
    write_ticket(t)
    print(f"{args.id} re-queued for retry ({retry_count}/{retry_limit})")
    return 0

def ticket_bucket(repo: str, path: str) -> str:
    rel = os.path.relpath(path, repo)
    if rel.startswith("tickets/archive/"):
        return "archive"
    if rel.startswith("tickets/errors/"):
        return "errors"
    if rel.startswith("tickets/backlogs/"):
        return "backlogs"
    if rel.startswith("tickets/"):
        return "tickets"
    return "other"

def cmd_report(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    db_path = args.db if os.path.isabs(args.db) else os.path.join(repo, args.db)
    os.makedirs(os.path.dirname(db_path) or repo, exist_ok=True)

    rows: List[Tuple[Any, ...]] = []
    parse_errors: List[Tuple[str, str]] = []
    for path in all_ticket_paths(repo):
        rel = os.path.relpath(path, repo)
        try:
            t = read_ticket(path)
        except Exception as ex:
            parse_errors.append((rel, str(ex)))
            continue

        meta = normalize_meta(t.meta)
        rows.append(
            (
                meta.get("id"),
                meta.get("title"),
                meta.get("status"),
                meta.get("priority"),
                meta.get("type"),
                meta.get("effort"),
                meta.get("owner"),
                meta.get("created"),
                meta.get("updated"),
                meta.get("branch"),
                json.dumps(meta.get("labels") or []),
                json.dumps(meta.get("tags") or []),
                json.dumps(meta.get("depends_on") or []),
                rel,
                ticket_bucket(repo, path),
                1 if ticket_bucket(repo, path) == "archive" else 0,
                t.body,
            )
        )

    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.execute("DROP TABLE IF EXISTS tickets")
        cur.execute("DROP TABLE IF EXISTS parse_errors")
        cur.execute(
            """
            CREATE TABLE tickets (
              id TEXT,
              title TEXT,
              status TEXT,
              priority TEXT,
              type TEXT,
              effort TEXT,
              owner TEXT,
              created TEXT,
              updated TEXT,
              branch TEXT,
              labels_json TEXT,
              tags_json TEXT,
              depends_on_json TEXT,
              path TEXT PRIMARY KEY,
              bucket TEXT,
              is_archived INTEGER,
              body TEXT
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE parse_errors (
              path TEXT PRIMARY KEY,
              error TEXT
            )
            """
        )
        cur.executemany(
            """
            INSERT INTO tickets (
              id, title, status, priority, type, effort, owner, created, updated, branch,
              labels_json, tags_json, depends_on_json, path, bucket, is_archived, body
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        cur.executemany("INSERT INTO parse_errors (path, error) VALUES (?, ?)", parse_errors)
        cur.execute("CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_tickets_priority ON tickets(priority)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_tickets_owner ON tickets(owner)")
        conn.commit()

        print(f"report db: {db_path}")
        print(f"indexed tickets: {len(rows)}")
        if parse_errors:
            print(f"parse errors: {len(parse_errors)}")

        if args.summary:
            print("\nBy status:")
            for status, count in cur.execute(
                "SELECT COALESCE(status, '<none>'), COUNT(*) FROM tickets GROUP BY status ORDER BY COUNT(*) DESC"
            ):
                print(f"  {status:<12} {count}")

            print("\nBy priority:")
            for priority, count in cur.execute(
                "SELECT COALESCE(priority, '<none>'), COUNT(*) FROM tickets GROUP BY priority ORDER BY COUNT(*) DESC"
            ):
                print(f"  {priority:<8} {count}")

            print("\nCompleted by owner:")
            for owner, count in cur.execute(
                """
                SELECT COALESCE(NULLIF(owner, ''), '<unowned>'), COUNT(*)
                FROM tickets
                WHERE status = 'done'
                GROUP BY owner
                ORDER BY COUNT(*) DESC
                """
            ):
                print(f"  {owner:<20} {count}")

        if args.search:
            print(f"\nSearch results for: {args.search!r}")
            q = f"%{args.search}%"
            for tid, title, status, owner, path in cur.execute(
                """
                SELECT COALESCE(id, '<no-id>'), COALESCE(title, ''), COALESCE(status, ''),
                       COALESCE(owner, ''), path
                FROM tickets
                WHERE id LIKE ? OR title LIKE ? OR body LIKE ? OR labels_json LIKE ? OR tags_json LIKE ?
                ORDER BY updated DESC, id ASC
                LIMIT ?
                """,
                (q, q, q, q, q, args.limit),
            ):
                print(f"  {tid}  {status:<12} {owner:<12} {title}  ({path})")
    finally:
        conn.close()
    return 0

def cmd_version(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    major, minor = load_repo_version(repo)
    version_text = load_repo_version_text(repo)
    payload = {
        "implementation": "mt.py",
        "version": version_text,
        "version_major": major,
        "version_minor": minor,
        "build_tools": {
            "python": sys.version.split()[0],
        },
        "runtime": {
            "python_executable": sys.executable,
            "platform": sys.platform,
        },
    }

    if args.json:
        print(json.dumps(payload, sort_keys=True))
    else:
        print(f"mt.py {version_text}")
        print(f"python={payload['build_tools']['python']}")
        print(f"python_executable={payload['runtime']['python_executable']}")
        print(f"platform={payload['runtime']['platform']}")
    return 0

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mt", description="MuonTickets CLI (file-based agent tickets).")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="Ensure tickets/ exists and create an example ticket.")
    p_init.set_defaults(func=cmd_init)

    p_new = sub.add_parser("new", help="Create a new ticket.")
    p_new.add_argument("title", help="Ticket title")
    p_new.add_argument("--priority", default=None, choices=DEFAULT_PRIORITIES)
    p_new.add_argument("--type", default=None, choices=DEFAULT_TYPES)
    p_new.add_argument("--effort", default=None, choices=DEFAULT_EFFORTS)
    p_new.add_argument("--label", action="append", default=[], help="Label (repeatable)")
    p_new.add_argument("--tag", action="append", default=[], help="Tag (repeatable, optional)")
    p_new.add_argument("--depends-on", action="append", default=[], dest="depends_on", help="Dependency ticket id (repeatable)")
    p_new.add_argument("--goal", default="", help="One-sentence goal")
    p_new.set_defaults(func=cmd_new)

    p_ls = sub.add_parser("ls", help="List tickets.")
    p_ls.add_argument("--status", choices=DEFAULT_STATES, help="Filter by status")
    p_ls.add_argument("--label", action="append", default=[], help="Filter by label (repeatable, ANDed)")
    p_ls.add_argument("--owner", default=None, help="Filter by owner (exact match). Use '' for unowned.")
    p_ls.add_argument("--priority", choices=DEFAULT_PRIORITIES, help="Filter by priority")
    p_ls.add_argument("--type", choices=DEFAULT_TYPES, help="Filter by type")
    p_ls.add_argument("--show-invalid", action="store_true", help="Show parse errors")
    p_ls.set_defaults(func=cmd_ls)

    p_show = sub.add_parser("show", help="Print a ticket.")
    p_show.add_argument("id")
    p_show.set_defaults(func=cmd_show)

    p_pick = sub.add_parser("pick", help="Pick best claimable ticket and claim it (swarm primitive).")
    p_pick.add_argument("--owner", required=True, help="Owner / agent id")
    p_pick.add_argument("--label", action="append", default=[], help="Required label (repeatable, ANDed)")
    p_pick.add_argument("--avoid-label", action="append", default=[], help="Avoid label (repeatable)")
    p_pick.add_argument("--priority", choices=DEFAULT_PRIORITIES, help="Filter by priority")
    p_pick.add_argument("--type", choices=DEFAULT_TYPES, help="Filter by type")
    p_pick.add_argument("--skill", choices=sorted(SKILL_PICK_PROFILES.keys()), help="Skill profile (adds label/type filters)")
    p_pick.add_argument("--role", choices=sorted(ROLE_PICK_PROFILES.keys()), help="Role profile (adds label/type filters)")
    p_pick.add_argument("--branch", default="", help="Branch name to write into ticket")
    p_pick.add_argument("--ignore-deps", action="store_true", help="Ignore dependency gating")
    p_pick.add_argument("--max-claimed-per-owner", type=int, default=2)
    p_pick.add_argument("--json", action="store_true", help="Emit JSON result")
    p_pick.set_defaults(func=cmd_pick)

    p_alloc = sub.add_parser("allocate-task", help="Queue-style allocator with lease semantics (returns ticket id).")
    p_alloc.add_argument("--owner", required=True, help="Owner / agent id")
    p_alloc.add_argument("--label", action="append", default=[], help="Required label (repeatable, ANDed)")
    p_alloc.add_argument("--avoid-label", action="append", default=[], help="Avoid label (repeatable)")
    p_alloc.add_argument("--priority", choices=DEFAULT_PRIORITIES, help="Filter by priority")
    p_alloc.add_argument("--type", choices=DEFAULT_TYPES, help="Filter by type")
    p_alloc.add_argument("--skill", choices=sorted(SKILL_PICK_PROFILES.keys()), help="Skill profile (adds label/type filters)")
    p_alloc.add_argument("--role", choices=sorted(ROLE_PICK_PROFILES.keys()), help="Role profile (adds label/type filters)")
    p_alloc.add_argument("--lease-minutes", type=int, default=5, help="Lease validity in minutes (default: 5)")
    p_alloc.add_argument("--branch", default="", help="Branch name to write into ticket")
    p_alloc.add_argument("--ignore-deps", action="store_true", help="Ignore dependency gating")
    p_alloc.add_argument("--max-claimed-per-owner", type=int, default=2)
    p_alloc.add_argument("--json", action="store_true", help="Emit JSON result")
    p_alloc.set_defaults(func=cmd_allocate_task)

    p_fail = sub.add_parser("fail-task", help="Record failed attempt, increment retry counter, and re-queue or escalate to errors.")
    p_fail.add_argument("id")
    p_fail.add_argument("--error", required=True, help="Error summary for retry incident log")
    p_fail.add_argument("--retry-limit", type=int, default=None, help="Override retry limit for this ticket")
    p_fail.add_argument("--force", action="store_true", help="Allow fail-task even when status is not claimed")
    p_fail.set_defaults(func=cmd_fail_task)

    p_claim = sub.add_parser("claim", help="Claim a specific ticket.")
    p_claim.add_argument("id")
    p_claim.add_argument("--owner", required=True)
    p_claim.add_argument("--branch", default="", help="Branch name")
    p_claim.add_argument("--ignore-deps", action="store_true")
    p_claim.add_argument("--force", action="store_true")
    p_claim.set_defaults(func=cmd_claim)

    p_comment = sub.add_parser("comment", help="Append a progress log entry.")
    p_comment.add_argument("id")
    p_comment.add_argument("text")
    p_comment.set_defaults(func=cmd_comment)

    p_ss = sub.add_parser("set-status", help="Change status with transition rules.")
    p_ss.add_argument("id")
    p_ss.add_argument("status", choices=DEFAULT_STATES)
    p_ss.add_argument("--force", action="store_true")
    p_ss.add_argument("--clear-owner", action="store_true", help="When setting to ready, clear owner/branch")
    p_ss.set_defaults(func=cmd_set_status)

    p_done = sub.add_parser("done", help="Mark ticket done (expects needs_review).")
    p_done.add_argument("id")
    p_done.add_argument("--force", action="store_true")
    p_done.set_defaults(func=cmd_done)

    p_archive = sub.add_parser("archive", help="Move a ticket from tickets/ to archive/ (expects done).")
    p_archive.add_argument("id")
    p_archive.add_argument("--force", action="store_true", help="Archive even if status is not done")
    p_archive.set_defaults(func=cmd_archive)

    p_graph = sub.add_parser("graph", help="Show dependency graph.")
    p_graph.add_argument("--mermaid", action="store_true", help="Output Mermaid graph")
    p_graph.add_argument("--open-only", action="store_true", help="Hide done tickets")
    p_graph.set_defaults(func=cmd_graph)

    p_export = sub.add_parser("export", help="Export tickets for tools/LLMs.")
    p_export.add_argument("--format", default="json", choices=["json", "jsonl"])
    p_export.set_defaults(func=cmd_export)

    p_stats = sub.add_parser("stats", help="Show board stats.")
    p_stats.set_defaults(func=cmd_stats)

    p_val = sub.add_parser("validate", help="Validate all tickets.")
    p_val.add_argument("--max-claimed-per-owner", type=int, default=2)
    p_val.add_argument("--enforce-done-deps", action="store_true", help="Enforce that claimed/needs_review/done tickets have deps done")
    p_val.set_defaults(func=cmd_validate)

    p_report = sub.add_parser("report", help="Build SQLite report DB from tickets/archive/backlogs and print summaries.")
    p_report.add_argument("--db", default="tickets/tickets_report.sqlite3", help="SQLite output path (default: tickets/tickets_report.sqlite3)")
    p_report.add_argument("--summary", action="store_true", default=True, help="Print summary tables")
    p_report.add_argument("--search", default="", help="Search string for id/title/body/labels/tags")
    p_report.add_argument("--limit", type=int, default=30, help="Max rows for search output")
    p_report.set_defaults(func=cmd_report)

    p_version = sub.add_parser("version", help="Show CLI version and build/runtime tool metadata.")
    p_version.add_argument("--json", action="store_true", help="Emit machine-readable JSON output")
    p_version.set_defaults(func=cmd_version)

    return p

def main(argv: Optional[List[str]] = None) -> int:
    args_list = list(argv) if argv is not None else sys.argv[1:]
    if len(args_list) == 0:
        return cmd_version(argparse.Namespace(json=False))
    if args_list[0] in ("-v", "--version"):
        return cmd_version(argparse.Namespace(json=False))

    parser = build_parser()
    args = parser.parse_args(args_list)
    return int(args.func(args))

if __name__ == "__main__":
    raise SystemExit(main())
