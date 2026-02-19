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
import sys
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

ID_RE = re.compile(r"^T-\d{6}$")
TICKET_FILE_RE = re.compile(r"^(T-\d{6})\.md$")
FRONTMATTER_BOUNDARY = "---"

DEFAULT_STATES = ["ready", "claimed", "blocked", "needs_review", "done"]
DEFAULT_PRIORITIES = ["p0", "p1", "p2"]
DEFAULT_TYPES = ["spec", "code", "tests", "docs", "refactor", "chore"]
DEFAULT_EFFORTS = ["xs", "s", "m", "l"]

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

def today_str() -> str:
    return _dt.date.today().isoformat()

def now_compact() -> str:
    return _dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")

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

def schema_path() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.json")

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
    with open(t.path, "w", encoding="utf-8") as f:
        f.write(join_frontmatter(t.meta, t.body))

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
    return meta

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
    - older tickets preferred (created date)
    """
    pr = str(meta.get("priority", "p2"))
    eff = str(meta.get("effort", "s"))
    deps = meta.get("depends_on") or []
    created = str(meta.get("created", "1970-01-01"))

    base = PRIORITY_WEIGHT.get(pr, 0) + EFFORT_WEIGHT.get(eff, 0)
    dep_penalty = 5 * len(deps)
    # Older = slightly higher (invert date lexicographically)
    try:
        dt = _dt.date.fromisoformat(created)
        age_days = (_dt.date.today() - dt).days
    except Exception:
        age_days = 0

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
    # Create an example ticket if none exist
    if not iter_ticket_files(tdir):
        tid = "T-000001"
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
            "created": today_str(),
            "updated": today_str(),
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
    return 0

def cmd_new(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tdir = tickets_dir(repo)
    ensure_tickets_dir(tdir)

    tid = next_ticket_id(tdir)
    title = args.title.strip()

    meta = normalize_meta({
        "id": tid,
        "title": title,
        "status": "ready",
        "priority": args.priority,
        "type": args.type,
        "effort": args.effort,
        "labels": args.label or [],
        "tags": args.tag or [],
        "owner": None,
        "created": today_str(),
        "updated": today_str(),
        "depends_on": args.depends_on or [],
        "branch": None,
    })

    body = f"""## Goal
{args.goal or "Write a single-sentence goal."}

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
    meta["updated"] = today_str()

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
    meta["updated"] = today_str()
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
    meta["updated"] = today_str()
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
    meta["updated"] = today_str()
    t.meta = meta
    write_ticket(t)
    print(f"done {args.id}")
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

def validate_depends(tickets: List[Ticket]) -> List[str]:
    existing = set()
    id_to_meta: Dict[str, Dict[str, Any]] = {}
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
    errors += validate_depends(tickets)
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

    candidates = []
    for t in tickets:
        if "_parse_error" in t.meta:
            continue
        meta = normalize_meta(t.meta)

        if meta.get("status") != "ready":
            continue
        if args.priority and meta.get("priority") != args.priority:
            continue
        if args.type and meta.get("type") != args.type:
            continue
        if args.label:
            labels = set(meta.get("labels") or [])
            if not set(args.label).issubset(labels):
                continue
        if args.avoid_label:
            labels = set(meta.get("labels") or [])
            if set(args.avoid_label) & labels:
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
    meta["updated"] = today_str()
    meta["score"] = float(score)

    ticket.meta = meta
    write_ticket(ticket)

    # Emit machine-readable line if requested
    if args.json:
        print(json.dumps({"picked": tid, "owner": args.owner, "branch": meta["branch"], "score": score}))
    else:
        print(f"picked {tid} (score {score:.1f}) -> claimed as {args.owner} (branch: {meta['branch']})")
    return 0

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mt", description="MuonTickets CLI (file-based agent tickets).")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="Ensure tickets/ exists and create an example ticket.")
    p_init.set_defaults(func=cmd_init)

    p_new = sub.add_parser("new", help="Create a new ticket.")
    p_new.add_argument("title", help="Ticket title")
    p_new.add_argument("--priority", default="p1", choices=DEFAULT_PRIORITIES)
    p_new.add_argument("--type", default="code", choices=DEFAULT_TYPES)
    p_new.add_argument("--effort", default="s", choices=DEFAULT_EFFORTS)
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
    p_pick.add_argument("--branch", default="", help="Branch name to write into ticket")
    p_pick.add_argument("--ignore-deps", action="store_true", help="Ignore dependency gating")
    p_pick.add_argument("--max-claimed-per-owner", type=int, default=2)
    p_pick.add_argument("--json", action="store_true", help="Emit JSON result")
    p_pick.set_defaults(func=cmd_pick)

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

    return p

def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))

if __name__ == "__main__":
    raise SystemExit(main())
