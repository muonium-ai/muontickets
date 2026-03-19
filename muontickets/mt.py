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
import glob as _glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Tuple

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
        current_list_key: Optional[str] = None
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            # Block-style list item: "- value"
            if line.startswith("- ") and current_list_key is not None:
                item = line[2:].strip().strip('"').strip("'")
                if item:
                    data[current_list_key].append(item)
                continue
            # Any non-list-item line ends the current list context
            current_list_key = None
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            k = k.strip()
            v = v.strip()
            if v.lower() in ("null", "none", "~"):
                data[k] = None
                continue
            if v == "":
                # Could be start of a block-style list or a null value;
                # assume block list and let list-item lines fill it.
                data[k] = []
                current_list_key = k
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
        # Convert any remaining empty block-list placeholders that got
        # no items back to empty list (they already are [])
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
class MaintenanceRule:
    id: int
    title: str
    category: str
    detection: str
    action: str
    default_priority: str
    default_type: str
    default_effort: str
    labels: List[str]
    external_tool: str = ""  # external tool/command hint for rules without built-in scanners

MAINTENANCE_CATEGORIES = [
    "security", "deps", "code-health", "performance",
    "database", "infrastructure", "observability",
    "testing", "docs",
]

MAINTENANCE_RULES: List[MaintenanceRule] = [
    # Category 1: Security Maintenance (rules 1-20)
    MaintenanceRule(1, "CVE Dependency Vulnerability", "security",
        "dependency version < secure version from CVE DB",
        "upgrade dependency and run tests", "p0", "chore", "m", ["maintenance", "security"]),
    MaintenanceRule(2, "Exposed Secrets in Repo", "security",
        "regex patterns (AKIA..., private_key)",
        "remove secret and move to vault", "p0", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(3, "Expired SSL Certificate", "security",
        "ssl_expiry_date < now + 14 days",
        "renew certificate", "p0", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(4, "Missing Security Headers", "security",
        "missing CSP, X-Frame-Options, X-XSS-Protection",
        "add headers", "p1", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(5, "Insecure Hashing Algorithm", "security",
        "md5 or sha1 usage",
        "migrate to argon2/bcrypt", "p0", "chore", "m", ["maintenance", "security"]),
    MaintenanceRule(6, "Hardcoded Password", "security",
        "password=\"...\" pattern",
        "move to environment variable", "p0", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(7, "Open Debug Ports", "security",
        "container exposing debug ports (9229, 3000)",
        "disable in production", "p1", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(8, "Unauthenticated Admin Endpoint", "security",
        "/admin route without auth middleware",
        "enforce auth guard", "p0", "chore", "m", ["maintenance", "security"]),
    MaintenanceRule(9, "Excessive IAM Privileges", "security",
        "policy contains \"*\"",
        "restrict permissions", "p1", "chore", "m", ["maintenance", "security"]),
    MaintenanceRule(10, "Unencrypted DB Connection", "security",
        "connection string missing TLS flag",
        "enforce encrypted connections", "p1", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(11, "Weak JWT Secret", "security",
        "JWT secret length < 32 characters or common value",
        "rotate to strong secret", "p0", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(12, "Missing Rate Limiting", "security",
        "API endpoints without rate limit middleware",
        "add rate limiting", "p1", "chore", "m", ["maintenance", "security"]),
    MaintenanceRule(13, "Disabled CSRF Protection", "security",
        "CSRF middleware disabled or missing",
        "enable CSRF protection", "p1", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(14, "Dependency Signature Mismatch", "security",
        "package checksum does not match registry",
        "verify and re-fetch dependency", "p0", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(15, "Container Running as Root", "security",
        "Dockerfile missing USER directive",
        "add non-root user", "p1", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(16, "Outdated OpenSSL", "security",
        "OpenSSL version < latest stable",
        "upgrade OpenSSL", "p0", "chore", "m", ["maintenance", "security"]),
    MaintenanceRule(17, "Public Cloud Bucket", "security",
        "storage bucket with public access enabled",
        "restrict bucket access", "p0", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(18, "Exposed .env File", "security",
        ".env file tracked in git or publicly accessible",
        "remove from tracking and add to .gitignore", "p0", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(19, "Missing MFA for Admin", "security",
        "admin accounts without MFA enabled",
        "enforce MFA", "p1", "chore", "s", ["maintenance", "security"]),
    MaintenanceRule(20, "Suspicious Login Activity", "security",
        "unusual login patterns or locations",
        "investigate and rotate credentials", "p0", "chore", "m", ["maintenance", "security"]),

    # Category 2: Dependency Maintenance (rules 21-40)
    MaintenanceRule(21, "Outdated Dependency", "deps",
        "npm/pip/cargo outdated",
        "upgrade version", "p1", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(22, "Deprecated Library", "deps",
        "upstream marked deprecated",
        "migrate to replacement", "p1", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(23, "Unmaintained Dependency", "deps",
        "last commit > 3 years",
        "replace library", "p1", "chore", "l", ["maintenance", "deps"]),
    MaintenanceRule(24, "Duplicate Libraries", "deps",
        "multiple versions installed",
        "consolidate version", "p1", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(25, "Vulnerable Transitive Dependency", "deps",
        "nested CVE scan",
        "update dependency tree", "p0", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(26, "Lockfile Drift", "deps",
        "mismatch with installed packages",
        "rebuild lockfile", "p1", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(27, "Outdated Build Toolchain", "deps",
        "compiler older than LTS",
        "upgrade toolchain", "p1", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(28, "Runtime EOL", "deps",
        "runtime end-of-life version",
        "upgrade runtime", "p0", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(29, "Dependency Size Explosion", "deps",
        "bundle size threshold exceeded",
        "audit dependency", "p2", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(30, "Unused Dependency", "deps",
        "static import analysis",
        "remove package", "p2", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(31, "License Change Detection", "deps",
        "dependency license changed in new version",
        "review license compatibility", "p1", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(32, "Conflicting Version Ranges", "deps",
        "dependency resolution conflicts",
        "resolve version conflicts", "p1", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(33, "Unused Peer Dependencies", "deps",
        "peer dependency declared but unused",
        "remove peer dependency", "p2", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(34, "Broken Registry References", "deps",
        "package registry URL unreachable",
        "fix registry reference", "p1", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(35, "Checksum Mismatch", "deps",
        "package checksum mismatch on install",
        "re-fetch and verify package", "p0", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(36, "Incompatible Binary Architecture", "deps",
        "native module built for wrong arch",
        "rebuild for target architecture", "p1", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(37, "Outdated WASM Runtime", "deps",
        "WASM runtime version behind stable",
        "upgrade WASM runtime", "p2", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(38, "Outdated GPU Drivers", "deps",
        "GPU driver version behind stable",
        "upgrade GPU drivers", "p2", "chore", "m", ["maintenance", "deps"]),
    MaintenanceRule(39, "Mirror Outage Fallback", "deps",
        "primary package mirror unreachable",
        "configure fallback mirror", "p1", "chore", "s", ["maintenance", "deps"]),
    MaintenanceRule(40, "Corrupted Dependency Cache", "deps",
        "dependency cache integrity check fails",
        "clear and rebuild cache", "p1", "chore", "s", ["maintenance", "deps"]),

    # Category 3: Code Health (rules 41-60)
    MaintenanceRule(41, "High Cyclomatic Complexity", "code-health",
        "cyclomatic complexity > 15",
        "refactor into smaller functions", "p2", "refactor", "m", ["maintenance", "code-health"]),
    MaintenanceRule(42, "File Too Large", "code-health",
        "file > 1000 lines",
        "split into modules", "p2", "refactor", "l", ["maintenance", "code-health"]),
    MaintenanceRule(43, "Duplicate Code Blocks", "code-health",
        "repeated code blocks detected",
        "extract shared function", "p2", "refactor", "m", ["maintenance", "code-health"]),
    MaintenanceRule(44, "Dead Code Detection", "code-health",
        "unreachable or unused code paths",
        "remove dead code", "p2", "refactor", "s", ["maintenance", "code-health"]),
    MaintenanceRule(45, "Deprecated API Usage", "code-health",
        "calls to deprecated functions/methods",
        "migrate to replacement API", "p1", "refactor", "m", ["maintenance", "code-health"]),
    MaintenanceRule(46, "Missing Error Handling", "code-health",
        "unhandled exceptions or missing error checks",
        "add error handling", "p1", "code", "m", ["maintenance", "code-health"]),
    MaintenanceRule(47, "Logging Inconsistency", "code-health",
        "inconsistent log levels or formats",
        "standardize logging", "p2", "refactor", "s", ["maintenance", "code-health"]),
    MaintenanceRule(48, "Excessive TODO Comments", "code-health",
        "TODO/FIXME/HACK count exceeds threshold",
        "address or create tickets for TODOs", "p2", "chore", "m", ["maintenance", "code-health"]),
    MaintenanceRule(49, "Long Parameter Lists", "code-health",
        "function parameters > 6",
        "refactor to use parameter objects", "p2", "refactor", "m", ["maintenance", "code-health"]),
    MaintenanceRule(50, "Circular Imports", "code-health",
        "circular import dependency detected",
        "restructure module dependencies", "p1", "refactor", "l", ["maintenance", "code-health"]),
    MaintenanceRule(51, "Missing Type Hints", "code-health",
        "functions without type annotations",
        "add type hints", "p2", "refactor", "m", ["maintenance", "code-health"]),
    MaintenanceRule(52, "Unused Imports", "code-health",
        "imported modules never referenced",
        "remove unused imports", "p2", "refactor", "xs", ["maintenance", "code-health"]),
    MaintenanceRule(53, "Inconsistent Formatting", "code-health",
        "code style deviates from project standard",
        "run formatter", "p2", "chore", "xs", ["maintenance", "code-health"]),
    MaintenanceRule(54, "Poor Naming Patterns", "code-health",
        "variable/function names unclear or inconsistent",
        "rename for clarity", "p2", "refactor", "m", ["maintenance", "code-health"]),
    MaintenanceRule(55, "Missing Docstrings", "code-health",
        "public functions without documentation",
        "add docstrings", "p2", "docs", "m", ["maintenance", "code-health"]),
    MaintenanceRule(56, "Nested Loops", "code-health",
        "deeply nested loops (> 3 levels)",
        "refactor to reduce nesting", "p2", "refactor", "m", ["maintenance", "code-health"]),
    MaintenanceRule(57, "Unsafe Pointer Operations", "code-health",
        "raw pointer usage without safety checks",
        "add bounds checking or use safe alternatives", "p1", "code", "m", ["maintenance", "code-health"]),
    MaintenanceRule(58, "Unbounded Recursion", "code-health",
        "recursive function without base case limit",
        "add recursion depth limit", "p1", "code", "s", ["maintenance", "code-health"]),
    MaintenanceRule(59, "Magic Numbers", "code-health",
        "unexplained numeric literals in code",
        "extract to named constants", "p2", "refactor", "s", ["maintenance", "code-health"]),
    MaintenanceRule(60, "Mutable Global State", "code-health",
        "global variables modified at runtime",
        "refactor to local/injected state", "p1", "refactor", "m", ["maintenance", "code-health"]),

    # Category 4: Performance (rules 61-80)
    MaintenanceRule(61, "Slow Database Query", "performance",
        "query execution > 500ms",
        "optimize query or add index", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(62, "N+1 Query Pattern", "performance",
        "repeated queries in loop",
        "batch or join queries", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(63, "Memory Leak Detection", "performance",
        "heap growth without release",
        "fix memory leak", "p0", "code", "l", ["maintenance", "performance"]),
    MaintenanceRule(64, "High API Latency", "performance",
        "p95 latency exceeds threshold",
        "profile and optimize endpoint", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(65, "Cache Miss Ratio", "performance",
        "cache miss ratio > 0.6",
        "tune cache strategy", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(66, "Large Response Payloads", "performance",
        "API response size exceeds threshold",
        "add pagination or compression", "p2", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(67, "O(n^2) Algorithms", "performance",
        "quadratic complexity in hot paths",
        "replace with efficient algorithm", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(68, "Unbounded Job Queue", "performance",
        "job queue grows without limit",
        "add backpressure or queue limits", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(69, "Excessive Logging Overhead", "performance",
        "high-frequency logging in hot paths",
        "reduce log verbosity or sample", "p2", "code", "s", ["maintenance", "performance"]),
    MaintenanceRule(70, "Slow Cold Start", "performance",
        "service startup > threshold",
        "optimize initialization", "p2", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(71, "Thread Starvation", "performance",
        "thread pool exhaustion detected",
        "increase pool size or reduce blocking", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(72, "Lock Contention", "performance",
        "high lock wait times",
        "reduce critical section scope", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(73, "Blocking IO in Async Code", "performance",
        "synchronous IO in async context",
        "convert to async IO", "p1", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(74, "Oversized Images", "performance",
        "image assets exceed size threshold",
        "compress or resize images", "p2", "chore", "s", ["maintenance", "performance"]),
    MaintenanceRule(75, "Redundant Network Calls", "performance",
        "duplicate API calls for same data",
        "deduplicate or cache results", "p2", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(76, "Inefficient Serialization", "performance",
        "slow serialization format in hot path",
        "switch to efficient format", "p2", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(77, "Slow WASM Execution Path", "performance",
        "WASM module performance below threshold",
        "profile and optimize WASM code", "p2", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(78, "GPU Underutilization", "performance",
        "GPU compute usage below capacity",
        "optimize GPU workload distribution", "p2", "code", "l", ["maintenance", "performance"]),
    MaintenanceRule(79, "Excessive Disk Writes", "performance",
        "write IOPS exceeds threshold",
        "batch or buffer writes", "p2", "code", "m", ["maintenance", "performance"]),
    MaintenanceRule(80, "Poor Pagination", "performance",
        "unbounded result sets returned",
        "implement cursor-based pagination", "p1", "code", "m", ["maintenance", "performance"]),

    # Category 5: Database Maintenance (rules 81-100)
    MaintenanceRule(81, "Missing Index", "database",
        "frequent query without supporting index",
        "add database index", "p1", "code", "s", ["maintenance", "database"]),
    MaintenanceRule(82, "Unused Index", "database",
        "index with zero reads",
        "drop unused index", "p2", "chore", "s", ["maintenance", "database"]),
    MaintenanceRule(83, "Table Bloat", "database",
        "dead tuple ratio exceeds threshold",
        "vacuum or repack table", "p1", "chore", "s", ["maintenance", "database"]),
    MaintenanceRule(84, "Fragmented Index", "database",
        "index fragmentation > threshold",
        "rebuild index", "p2", "chore", "s", ["maintenance", "database"]),
    MaintenanceRule(85, "Orphan Records", "database",
        "records referencing deleted parents",
        "clean up orphan records", "p2", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(86, "Duplicate Rows", "database",
        "duplicate records detected",
        "deduplicate data", "p1", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(87, "Data Format Drift", "database",
        "column data deviates from expected format",
        "normalize data format", "p2", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(88, "Backup Failure", "database",
        "last backup older than policy threshold",
        "investigate and fix backup", "p0", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(89, "Failed Migration", "database",
        "migration in failed/partial state",
        "fix and rerun migration", "p0", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(90, "Slow Join Queries", "database",
        "join query exceeding time threshold",
        "optimize join or denormalize", "p1", "code", "m", ["maintenance", "database"]),
    MaintenanceRule(91, "Oversized JSON Columns", "database",
        "JSON column average size exceeds threshold",
        "normalize into relational columns", "p2", "refactor", "l", ["maintenance", "database"]),
    MaintenanceRule(92, "Unused Tables", "database",
        "tables with no recent reads or writes",
        "archive or drop unused tables", "p2", "chore", "s", ["maintenance", "database"]),
    MaintenanceRule(93, "Table Scan Alerts", "database",
        "full table scan on large table",
        "add index or optimize query", "p1", "code", "m", ["maintenance", "database"]),
    MaintenanceRule(94, "Encoding Mismatch", "database",
        "mixed character encodings across tables",
        "standardize encoding", "p2", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(95, "Unbounded Table Growth", "database",
        "table row count growing without retention policy",
        "implement retention or archival", "p1", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(96, "Missing Partitioning", "database",
        "large table without partitioning scheme",
        "add table partitioning", "p2", "chore", "l", ["maintenance", "database"]),
    MaintenanceRule(97, "Outdated Statistics", "database",
        "query planner statistics stale",
        "analyze/update statistics", "p2", "chore", "s", ["maintenance", "database"]),
    MaintenanceRule(98, "Corrupted Index Pages", "database",
        "index corruption detected",
        "rebuild corrupted index", "p0", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(99, "Replication Lag", "database",
        "replica behind primary by threshold",
        "investigate replication lag", "p0", "chore", "m", ["maintenance", "database"]),
    MaintenanceRule(100, "Foreign Key Inconsistencies", "database",
        "orphaned foreign key references",
        "fix referential integrity", "p1", "chore", "m", ["maintenance", "database"]),

    # Category 6: Infrastructure (rules 101-120)
    MaintenanceRule(101, "Container Image Outdated", "infrastructure",
        "base image version behind latest",
        "update container base image", "p1", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(102, "Missing OS Security Patches", "infrastructure",
        "OS packages with available security updates",
        "apply security patches", "p0", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(103, "Low Disk Space", "infrastructure",
        "disk usage > 85%",
        "clean up or expand storage", "p0", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(104, "CPU Saturation", "infrastructure",
        "sustained CPU usage > 90%",
        "scale or optimize workload", "p0", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(105, "Memory Pressure", "infrastructure",
        "memory usage > 90% or OOM events",
        "investigate memory usage and scale", "p0", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(106, "CrashLoop Pods", "infrastructure",
        "pod in CrashLoopBackOff state",
        "diagnose and fix crash loop", "p0", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(107, "Orphan Containers", "infrastructure",
        "stopped containers consuming resources",
        "remove orphan containers", "p2", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(108, "Stale Storage Volumes", "infrastructure",
        "unattached volumes with no recent access",
        "clean up stale volumes", "p2", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(109, "Expired DNS Records", "infrastructure",
        "DNS records pointing to decommissioned resources",
        "update DNS records", "p1", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(110, "Misconfigured Load Balancer", "infrastructure",
        "health check failures or routing errors",
        "fix load balancer configuration", "p0", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(111, "High Network Latency", "infrastructure",
        "inter-service latency exceeds threshold",
        "investigate network path", "p1", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(112, "Unused Cloud Resources", "infrastructure",
        "idle VMs, IPs, or load balancers",
        "decommission unused resources", "p2", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(113, "Broken CI Runners", "infrastructure",
        "CI runner offline or failing jobs",
        "repair or replace CI runner", "p0", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(114, "Container Restart Loops", "infrastructure",
        "container restart count exceeds threshold",
        "diagnose restart cause", "p0", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(115, "Unused Security Groups", "infrastructure",
        "security groups not attached to resources",
        "remove unused security groups", "p2", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(116, "Expired API Gateway Cert", "infrastructure",
        "API gateway certificate expiring soon",
        "renew API gateway certificate", "p0", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(117, "Infrastructure Drift", "infrastructure",
        "live config differs from IaC definitions",
        "reconcile infrastructure state", "p1", "chore", "m", ["maintenance", "infrastructure"]),
    MaintenanceRule(118, "Registry Cleanup Required", "infrastructure",
        "container registry storage exceeds threshold",
        "prune old images from registry", "p2", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(119, "Log Storage Overflow", "infrastructure",
        "log volume approaching storage limit",
        "rotate or archive logs", "p1", "chore", "s", ["maintenance", "infrastructure"]),
    MaintenanceRule(120, "Node Version Drift", "infrastructure",
        "cluster nodes running different versions",
        "align node versions", "p1", "chore", "m", ["maintenance", "infrastructure"]),

    # Category 7: Observability (rules 121-130)
    MaintenanceRule(121, "Missing Metrics", "observability",
        "service endpoints without metrics instrumentation",
        "add metrics collection", "p1", "code", "m", ["maintenance", "observability"]),
    MaintenanceRule(122, "Broken Alerts", "observability",
        "alert rules referencing missing metrics",
        "fix alert configuration", "p1", "chore", "s", ["maintenance", "observability"]),
    MaintenanceRule(123, "Missing Distributed Tracing", "observability",
        "services without trace propagation",
        "add trace instrumentation", "p1", "code", "m", ["maintenance", "observability"]),
    MaintenanceRule(124, "Log Retention Overflow", "observability",
        "log retention exceeding storage policy",
        "adjust retention policy", "p2", "chore", "s", ["maintenance", "observability"]),
    MaintenanceRule(125, "Missing Uptime Checks", "observability",
        "production endpoints without health monitoring",
        "add uptime checks", "p1", "chore", "s", ["maintenance", "observability"]),
    MaintenanceRule(126, "Alert Fatigue Detection", "observability",
        "high volume of non-actionable alerts",
        "tune alert thresholds", "p2", "chore", "m", ["maintenance", "observability"]),
    MaintenanceRule(127, "Missing Error Classification", "observability",
        "errors logged without categorization",
        "add error classification", "p2", "code", "m", ["maintenance", "observability"]),
    MaintenanceRule(128, "Inconsistent Log Schema", "observability",
        "log format varies across services",
        "standardize log schema", "p2", "chore", "m", ["maintenance", "observability"]),
    MaintenanceRule(129, "Missing Service Map", "observability",
        "no service dependency map available",
        "generate service map", "p2", "docs", "m", ["maintenance", "observability"]),
    MaintenanceRule(130, "Outdated Dashboards", "observability",
        "dashboards referencing deprecated metrics",
        "update dashboards", "p2", "chore", "s", ["maintenance", "observability"]),

    # Category 8: Test Maintenance (rules 131-140)
    MaintenanceRule(131, "Failing Tests", "testing",
        "test suite has persistent failures",
        "fix failing tests", "p0", "tests", "m", ["maintenance", "testing"]),
    MaintenanceRule(132, "Flaky Tests", "testing",
        "tests with intermittent pass/fail",
        "stabilize flaky tests", "p1", "tests", "m", ["maintenance", "testing"]),
    MaintenanceRule(133, "Missing Regression Tests", "testing",
        "recent bug fixes without regression tests",
        "add regression tests", "p1", "tests", "m", ["maintenance", "testing"]),
    MaintenanceRule(134, "Low Coverage Modules", "testing",
        "modules below coverage threshold",
        "add tests for low coverage areas", "p2", "tests", "m", ["maintenance", "testing"]),
    MaintenanceRule(135, "Outdated Snapshot Tests", "testing",
        "snapshot tests not updated after code changes",
        "update snapshot tests", "p2", "tests", "s", ["maintenance", "testing"]),
    MaintenanceRule(136, "Slow Test Suite", "testing",
        "test suite execution exceeds threshold",
        "optimize slow tests", "p2", "tests", "m", ["maintenance", "testing"]),
    MaintenanceRule(137, "Missing Integration Tests", "testing",
        "critical paths without integration test coverage",
        "add integration tests", "p1", "tests", "l", ["maintenance", "testing"]),
    MaintenanceRule(138, "Broken CI Pipeline", "testing",
        "CI pipeline failing on main branch",
        "fix CI pipeline", "p0", "tests", "m", ["maintenance", "testing"]),
    MaintenanceRule(139, "Missing Edge Case Tests", "testing",
        "boundary conditions untested",
        "add edge case tests", "p2", "tests", "m", ["maintenance", "testing"]),
    MaintenanceRule(140, "Inconsistent Test Data", "testing",
        "test fixtures with hardcoded or stale data",
        "standardize test data", "p2", "tests", "s", ["maintenance", "testing"]),

    # Category 9: Documentation (rules 141-150)
    MaintenanceRule(141, "Outdated API Docs", "docs",
        "API documentation does not match implementation",
        "update API documentation", "p1", "docs", "m", ["maintenance", "docs"]),
    MaintenanceRule(142, "Broken Documentation Links", "docs",
        "dead links in documentation",
        "fix broken links", "p2", "docs", "s", ["maintenance", "docs"]),
    MaintenanceRule(143, "Outdated Onboarding Docs", "docs",
        "onboarding guide references removed features",
        "update onboarding documentation", "p1", "docs", "m", ["maintenance", "docs"]),
    MaintenanceRule(144, "Missing Architecture Diagram", "docs",
        "no architecture diagram or diagram is outdated",
        "create or update architecture diagram", "p2", "docs", "m", ["maintenance", "docs"]),
    MaintenanceRule(145, "Missing CLI Examples", "docs",
        "CLI commands without usage examples",
        "add CLI usage examples", "p2", "docs", "s", ["maintenance", "docs"]),
    MaintenanceRule(146, "Outdated Deployment Guide", "docs",
        "deployment guide does not match current process",
        "update deployment guide", "p1", "docs", "m", ["maintenance", "docs"]),
    MaintenanceRule(147, "Undocumented Endpoints", "docs",
        "API endpoints without documentation",
        "document undocumented endpoints", "p1", "docs", "m", ["maintenance", "docs"]),
    MaintenanceRule(148, "Stale README", "docs",
        "README last updated significantly before repo activity",
        "update README", "p2", "docs", "s", ["maintenance", "docs"]),
    MaintenanceRule(149, "Outdated SDK Docs", "docs",
        "SDK documentation does not match current API",
        "update SDK documentation", "p1", "docs", "m", ["maintenance", "docs"]),
    MaintenanceRule(150, "Missing Changelog", "docs",
        "no changelog or changelog not updated for recent releases",
        "update changelog", "p2", "docs", "s", ["maintenance", "docs"]),
]

# External tool hints for rules without built-in scanners.
# Tells agents what command or data source to use for detection.
_EXTERNAL_TOOL_HINTS: Dict[int, str] = {
    # Security
    1:  "npm audit | pip-audit | cargo audit | osv-scanner | trivy | grype",
    3:  "openssl s_client -connect host:443 | openssl x509 -noout -dates",
    4:  "curl -I <url> (check response headers for CSP, X-Frame-Options, X-XSS-Protection)",
    5:  "grep -rn 'md5\\|sha1\\|MD5\\|SHA1' --include='*.py' --include='*.js' --include='*.go'",
    7:  "docker inspect <container> | grep -i port; kubectl get svc -o json",
    8:  "review route definitions for /admin paths without auth middleware",
    9:  "aws iam list-policies --only-attached | grep '\"*\"'; gcloud iam policies",
    10: "grep -rn 'sslmode=disable\\|ssl=false\\|useSSL=false' (connection strings)",
    11: "grep -rn 'jwt.sign\\|JWT_SECRET\\|jwt_secret' and check secret length/entropy",
    12: "review API framework middleware config for rate-limit setup",
    13: "review framework config for CSRF middleware (csrf_exempt, disable_csrf)",
    14: "npm audit signatures | pip hash --verify | cargo verify-project",
    16: "openssl version; dpkg -l openssl; brew info openssl",
    17: "aws s3api get-bucket-acl --bucket <name>; gsutil iam get gs://<bucket>",
    19: "aws iam get-login-profile; review admin user MFA status in cloud console",
    20: "review auth/access logs for unusual IPs, times, or geolocations",
    # Dependencies
    21: "npm outdated | pip list --outdated | cargo outdated | uv pip list --outdated",
    22: "npm info <pkg> deprecated; check PyPI/crates.io status page",
    23: "check GitHub last commit date via API; npm info <pkg> time.modified",
    24: "npm ls --all | grep deduped; pip list | sort | uniq -d",
    25: "npm audit | pip-audit | cargo audit | osv-scanner (transitive deps)",
    26: "npm ci --dry-run; pip freeze > /tmp/freeze.txt && diff requirements.txt /tmp/freeze.txt",
    27: "rustc --version; python3 --version; node --version; go version; zig version",
    28: "check endoflife.date API for runtime EOL dates (python, node, ruby, etc.)",
    29: "npm pack --dry-run; du -sh node_modules; cargo bloat",
    30: "depcheck (npm) | vulture (python) | cargo-udeps (rust)",
    31: "license-checker (npm) | pip-licenses | cargo-license; diff against previous",
    32: "npm ls --all 2>&1 | grep 'ERESOLVE\\|peer dep'; pip check",
    33: "npm ls --all | grep 'peer dep'",
    34: "npm ping; pip config list (check index-url reachability)",
    35: "npm cache verify; pip hash --verify; cargo verify-project",
    36: "file node_modules/**/*.node; check platform/arch in native bindings",
    37: "check wasmtime/wasmer version against latest stable release",
    38: "nvidia-smi; check driver version against CUDA compatibility matrix",
    39: "npm ping --registry <mirror>; pip install --dry-run -i <mirror>",
    40: "npm cache clean --force; pip cache purge; cargo clean",
    # Code Health
    41: "radon cc -a (python) | eslint --rule complexity (js) | gocyclo (go)",
    43: "jscpd | flay (ruby) | PMD CPD (java); semgrep --config=p/duplicate-code",
    44: "vulture (python) | ts-prune (typescript) | deadcode (go)",
    45: "grep -rn '@deprecated\\|DeprecationWarning\\|DEPRECATED'",
    46: "pylint --disable=all --enable=W0702,W0703 | eslint no-empty-catch",
    47: "grep -rn 'console.log\\|print(\\|log.Debug' and review log level consistency",
    49: "pylint --disable=all --enable=R0913 | eslint max-params",
    50: "python -c 'import importlib; importlib.import_module(\"pkg\")' | madge --circular (js)",
    51: "mypy --strict | pyright; check function signatures for missing annotations",
    52: "autoflake --check (python) | eslint no-unused-vars (js)",
    53: "black --check (python) | prettier --check (js) | rustfmt --check (rust)",
    54: "pylint naming-convention | eslint camelcase/naming-convention",
    55: "pydocstyle | darglint | interrogate (python)",
    56: "review code for nested for/while loops > 3 levels deep",
    57: "clippy (rust) | cppcheck (c/c++) | review unsafe blocks",
    58: "review recursive functions for missing base case or depth limit",
    59: "pylint --disable=all --enable=W0612 | eslint no-magic-numbers",
    60: "grep -rn 'global ' (python) | review mutable module-level state",
    # Performance
    61: "EXPLAIN ANALYZE <query>; pg_stat_statements; slow query log",
    62: "django-debug-toolbar | bullet gem (rails) | review ORM queries in loops",
    63: "valgrind --leak-check=full | heaptrack | node --inspect + Chrome DevTools",
    64: "check APM dashboards (Datadog, New Relic, Grafana) for p95 latency",
    65: "redis-cli INFO stats | memcached stats; check cache hit/miss metrics",
    66: "curl -s <api> | wc -c; check API response sizes in APM",
    67: "review hot-path code for nested loops; profile with py-spy/perf/flamegraph",
    68: "check job queue metrics (Sidekiq, Celery, Bull) for queue depth trends",
    69: "review logging in hot paths; check log volume metrics",
    70: "time service startup; profile with py-spy/perf during init",
    71: "jstack (java) | py-spy dump | review thread pool configs",
    72: "lock contention profiling; review mutex/lock usage in hot paths",
    73: "review async code for sync IO calls (requests, open, subprocess)",
    74: "find . -name '*.png' -o -name '*.jpg' | xargs identify -format '%f %wx%h %b\\n'",
    75: "review network calls in code; check for duplicate HTTP requests in APM",
    76: "benchmark serialization (json vs msgpack vs protobuf) in hot paths",
    77: "wasm profiling tools; review WASM module execution times",
    78: "nvidia-smi dmon; review GPU utilization metrics",
    79: "iostat; check write IOPS metrics; review fsync/flush patterns",
    80: "review API endpoints for unbounded SELECT/find queries without LIMIT",
    # Database
    81: "EXPLAIN ANALYZE <query>; pg_stat_user_tables (seq_scan count); slow query log",
    82: "pg_stat_user_indexes (idx_scan = 0); MySQL sys.schema_unused_indexes",
    83: "pg_stat_user_tables (n_dead_tup); VACUUM VERBOSE",
    84: "pg_stat_user_indexes; DBCC SHOWCONTIG (SQL Server); OPTIMIZE TABLE (MySQL)",
    85: "SELECT orphans with LEFT JOIN ... WHERE parent.id IS NULL",
    86: "SELECT columns, COUNT(*) GROUP BY columns HAVING COUNT(*) > 1",
    87: "sample column data and check format consistency; pg_typeof()",
    88: "pg_stat_archiver; check backup tool logs (pg_dump, mysqldump, mongodump)",
    89: "check migration status table; rails db:migrate:status | alembic current",
    90: "EXPLAIN ANALYZE for JOIN queries; check pg_stat_statements for slow joins",
    91: "SELECT avg(pg_column_size(json_col)) FROM table; check JSON column sizes",
    92: "pg_stat_user_tables (last_autovacuum, seq_scan, idx_scan for zero-activity tables)",
    93: "pg_stat_user_tables (seq_scan on large tables); MySQL slow query log",
    94: "SELECT table_name, character_set_name FROM information_schema.columns",
    95: "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC",
    96: "check table sizes; review partitioning strategy for tables > 10M rows",
    97: "pg_stat_user_tables (last_analyze); ANALYZE VERBOSE",
    98: "pg_catalog.pg_index (indisvalid = false); REINDEX",
    99: "SELECT * FROM pg_stat_replication; check replica lag metrics",
    100: "check foreign key constraints; SELECT with LEFT JOIN for orphaned references",
    # Infrastructure
    101: "docker pull <image>:latest --dry-run; compare Dockerfile FROM tag to latest",
    102: "apt list --upgradable | yum check-update | apk version -l '<'",
    103: "df -h; kubectl top nodes; cloud console storage metrics",
    104: "top; kubectl top pods; cloud monitoring CPU metrics",
    105: "free -h; kubectl top pods; check OOM events in dmesg/journal",
    106: "kubectl get pods --field-selector=status.phase!=Running; kubectl describe pod",
    107: "docker ps -a --filter status=exited; docker system df",
    108: "kubectl get pv --no-headers | grep Available; aws ec2 describe-volumes --filters Name=status,Values=available",
    109: "dig <hostname>; nslookup; check DNS records against active infrastructure",
    110: "kubectl describe ingress; aws elb describe-target-health; health check logs",
    111: "ping; traceroute; mtr; check network latency metrics in monitoring",
    112: "aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped; cloud cost reports",
    113: "check CI dashboard for offline runners; gitlab-runner verify; gh api /repos/{owner}/{repo}/actions/runners",
    114: "docker inspect --format='{{.RestartCount}}'; kubectl describe pod (restart count)",
    115: "aws ec2 describe-security-groups; check for unattached security groups",
    116: "aws apigateway get-domain-names; check certificate expiry dates",
    117: "terraform plan | pulumi preview | compare live state vs IaC definitions",
    118: "docker system df; cloud registry storage metrics; skopeo list-tags",
    119: "du -sh /var/log; check log rotation config; cloud logging storage metrics",
    120: "kubectl get nodes -o wide; compare node versions across cluster",
    # Observability
    121: "review service endpoints for metrics instrumentation; check Prometheus targets",
    122: "promtool check rules; review alert rule YAML for missing metric references",
    123: "review code for trace context propagation (OpenTelemetry, Jaeger, Zipkin)",
    124: "check log retention policies; du -sh log storage; cloud logging config",
    125: "review uptime monitoring config (Pingdom, UptimeRobot, cloud health checks)",
    126: "review alert history for frequency; check PagerDuty/Opsgenie alert volume",
    127: "review error logging for categorization (error codes, error types)",
    128: "compare log formats across services; check structured logging config",
    129: "review service dependencies; generate from traces or config (Kiali, Jaeger)",
    130: "review Grafana/Datadog dashboards for deprecated metric references",
    # Testing
    131: "run test suite and check exit code; review CI pipeline history for failures",
    132: "run tests multiple times; check CI history for intermittent failures",
    133: "review recent bug-fix commits for associated test additions",
    134: "coverage run -m pytest; nyc; go test -cover; review coverage report",
    135: "jest --updateSnapshot --dry-run; check snapshot diff against code changes",
    136: "time test suite execution; pytest --durations=10; jest --verbose",
    137: "review critical user paths for integration test coverage",
    138: "check CI pipeline status on main branch; review recent CI logs",
    139: "review test cases for boundary values, null inputs, empty collections",
    140: "review test fixtures for hardcoded dates, IDs, or stale data",
    # Documentation
    141: "diff API implementation against API docs; check OpenAPI spec freshness",
    143: "review onboarding docs against current setup/install process",
    144: "check for architecture diagrams in docs/; compare against current system",
    145: "review CLI --help output against documentation examples",
    146: "compare deployment docs against current deploy scripts/CI config",
    147: "list API routes and compare against documented endpoints",
    149: "diff SDK methods against API documentation; check SDK version alignment",
    150: "check CHANGELOG.md last entry date vs latest release tag",
}

MAINTENANCE_RULES_BY_ID = {r.id: r for r in MAINTENANCE_RULES}

# Apply external tool hints to rules
for _rid, _hint in _EXTERNAL_TOOL_HINTS.items():
    if _rid in MAINTENANCE_RULES_BY_ID:
        MAINTENANCE_RULES_BY_ID[_rid].external_tool = _hint

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
    for root, dirs, files in os.walk(root_dir, topdown=True):
        dirs[:] = [
            dirname
            for dirname in dirs
            if not os.path.exists(os.path.join(root, dirname, ".git"))
        ]
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

    # WIP limit gate
    if not args.force:
        claimed_count = 0
        for m in id_to_meta.values():
            if m.get("status") == "claimed" and (m.get("owner") or "") == args.owner:
                claimed_count += 1
        if claimed_count >= args.max_claimed_per_owner:
            eprint(f"owner {args.owner!r} already has {claimed_count} claimed tickets (max {args.max_claimed_per_owner}).")
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

    # Enforce claimed-status invariants (same as claim command)
    if new == "claimed" and not args.force:
        owner = getattr(args, "owner", None) or meta.get("owner")
        if not owner:
            eprint("Refusing: transitioning to 'claimed' requires an owner. "
                   "Use --owner or claim the ticket instead.")
            return 2
        meta["owner"] = owner

        branch = getattr(args, "branch", None) or meta.get("branch")
        if not branch:
            branch = _default_branch(meta)
        meta["branch"] = branch.strip() if branch else _default_branch(meta)

        tickets = load_all_tickets(repo)
        id_to_meta = {normalize_meta(x.meta).get("id"): normalize_meta(x.meta)
                      for x in tickets if "_parse_error" not in x.meta}

        if not getattr(args, "ignore_deps", False):
            ok, missing = deps_satisfied(meta, id_to_meta)
            if not ok:
                eprint(f"Refusing: dependencies not done: {missing}. "
                       "Use --ignore-deps to override.")
                return 2

        # WIP limit gate
        claimed_count = 0
        for m in id_to_meta.values():
            if m.get("status") == "claimed" and (m.get("owner") or "") == owner:
                claimed_count += 1
        max_wip = getattr(args, "max_claimed_per_owner", 2)
        if claimed_count >= max_wip:
            eprint(f"owner {owner!r} already has {claimed_count} claimed tickets (max {max_wip}).")
            return 2

    if new == "ready" and args.clear_owner:
        meta["owner"] = None
        meta["branch"] = None

    # Clear active lease metadata when leaving live queue execution
    if new in ("needs_review", "done"):
        meta["allocated_to"] = None
        meta["allocated_at"] = None
        meta["lease_expires_at"] = None
        meta["last_attempted_at"] = None

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
    # Clear active lease metadata when completing queue execution
    meta["allocated_to"] = None
    meta["allocated_at"] = None
    meta["lease_expires_at"] = None
    meta["last_attempted_at"] = None
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
    meta["lease_expires_at"] = lease_until.replace(microsecond=0).isoformat().replace("+00:00", "Z")
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

def _filter_maintenance_rules(
    categories: List[str], rule_ids: List[int],
) -> List[MaintenanceRule]:
    rules = MAINTENANCE_RULES
    if categories:
        rules = [r for r in rules if r.category in categories]
    if rule_ids:
        rules = [r for r in rules if r.id in rule_ids]
    return rules


# ---------------------------------------------------------------------------
# Scanner registry: maps rule IDs to scanning functions
# Scanner signature: (repo_root: str) -> List[Dict] with keys: file, line, detail
# ---------------------------------------------------------------------------
MAINTENANCE_SCANNERS: Dict[int, Callable[[str], List[Dict[str, Any]]]] = {}

_SOURCE_EXTENSIONS = {
    ".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".c", ".h",
    ".cpp", ".java", ".rb", ".sh", ".bash", ".zsh", ".yaml", ".yml",
    ".toml", ".cfg", ".ini", ".json", ".xml", ".zig",
}

_BINARY_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv",
                "target", "zig-out", "zig-cache", "build", "dist", ".tox"}
_SKIP_SCAN_DIRS = _BINARY_DIRS | {"tests", "test", "spec", "fixtures", "testdata"}


def _source_files(repo: str, skip_dirs: Optional[set] = None) -> List[str]:
    """Walk repo and yield source file paths (relative), skipping specified dirs."""
    exclude = skip_dirs if skip_dirs is not None else _BINARY_DIRS
    results: List[str] = []
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [d for d in dirnames if d not in exclude]
        for fname in filenames:
            if os.path.splitext(fname)[1] in _SOURCE_EXTENSIONS:
                full = os.path.join(dirpath, fname)
                results.append(os.path.relpath(full, repo))
    return results


def _register_scanner(*rule_ids: int):
    def decorator(fn: Callable[[str], List[Dict[str, Any]]]):
        for rid in rule_ids:
            MAINTENANCE_SCANNERS[rid] = fn
        return fn
    return decorator


@_register_scanner(2, 6)
def _scan_exposed_secrets(repo: str) -> List[Dict[str, Any]]:
    patterns = [
        (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key pattern"),
        (re.compile(r"""password\s*=\s*['"][^'"]{3,}['"]"""), "hardcoded password"),
        (re.compile(r"-----BEGIN\s+(RSA|DSA|EC|OPENSSH)?\s*PRIVATE KEY-----"), "private key"),
        (re.compile(r"""secret_key\s*=\s*['"][^'"]{3,}['"]"""), "hardcoded secret_key"),
    ]
    findings: List[Dict[str, Any]] = []
    for fpath in _source_files(repo, skip_dirs=_SKIP_SCAN_DIRS):
        try:
            with open(os.path.join(repo, fpath), "r", encoding="utf-8", errors="ignore") as f:
                for lineno, line in enumerate(f, 1):
                    for pat, desc in patterns:
                        if pat.search(line):
                            findings.append({"file": fpath, "line": lineno, "detail": f"{desc} detected"})
                            break
        except (OSError, UnicodeDecodeError):
            continue
    return findings


@_register_scanner(15)
def _scan_container_root(repo: str) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []
    for fpath in _glob.glob(os.path.join(repo, "**/Dockerfile*"), recursive=True):
        rel = os.path.relpath(fpath, repo)
        try:
            content = open(fpath, "r", encoding="utf-8").read()
            if "FROM " in content and not re.search(r"^\s*USER\s+\S+", content, re.MULTILINE):
                findings.append({"file": rel, "line": 0, "detail": "Dockerfile missing USER directive (runs as root)"})
        except OSError:
            continue
    return findings


@_register_scanner(18)
def _scan_exposed_env(repo: str) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []
    try:
        result = subprocess.run(
            ["git", "ls-files", "--error-unmatch", ".env"],
            cwd=repo, capture_output=True, text=True,
        )
        if result.returncode == 0:
            findings.append({"file": ".env", "line": 0, "detail": ".env file is tracked in git"})
    except OSError:
        pass
    return findings


@_register_scanner(42)
def _scan_large_files(repo: str) -> List[Dict[str, Any]]:
    threshold = 1000
    findings: List[Dict[str, Any]] = []
    for fpath in _source_files(repo):
        try:
            with open(os.path.join(repo, fpath), "r", encoding="utf-8", errors="ignore") as f:
                count = sum(1 for _ in f)
            if count > threshold:
                findings.append({"file": fpath, "line": 0, "detail": f"{count} lines (threshold: {threshold})"})
        except OSError:
            continue
    return findings


@_register_scanner(48)
def _scan_todo_density(repo: str) -> List[Dict[str, Any]]:
    todo_re = re.compile(r"\b(TODO|FIXME|HACK|XXX)\b", re.IGNORECASE)
    threshold = 10
    findings: List[Dict[str, Any]] = []
    for fpath in _source_files(repo):
        try:
            count = 0
            with open(os.path.join(repo, fpath), "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if todo_re.search(line):
                        count += 1
            if count >= threshold:
                findings.append({"file": fpath, "line": 0, "detail": f"{count} TODO/FIXME/HACK comments"})
        except OSError:
            continue
    return findings


@_register_scanner(142)
def _scan_broken_doc_links(repo: str) -> List[Dict[str, Any]]:
    link_re = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
    findings: List[Dict[str, Any]] = []
    for fpath in _glob.glob(os.path.join(repo, "**/*.md"), recursive=True):
        rel = os.path.relpath(fpath, repo)
        fdir = os.path.dirname(fpath)
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                for lineno, line in enumerate(f, 1):
                    for m in link_re.finditer(line):
                        target = m.group(2)
                        if target.startswith(("http://", "https://", "#", "mailto:")):
                            continue
                        target_clean = target.split("#")[0].split("?")[0]
                        if not target_clean:
                            continue
                        full = os.path.normpath(os.path.join(fdir, target_clean))
                        if not os.path.exists(full):
                            findings.append({"file": rel, "line": lineno,
                                             "detail": f"broken link to {target_clean}"})
        except OSError:
            continue
    return findings


@_register_scanner(148)
def _scan_stale_readme(repo: str) -> List[Dict[str, Any]]:
    readme = os.path.join(repo, "README.md")
    if not os.path.exists(readme):
        return [{"file": "README.md", "line": 0, "detail": "README.md does not exist"}]
    readme_mtime = os.path.getmtime(readme)
    latest_source = 0.0
    for fpath in _source_files(repo):
        try:
            mt = os.path.getmtime(os.path.join(repo, fpath))
            if mt > latest_source:
                latest_source = mt
        except OSError:
            continue
    if latest_source <= 0:
        return []
    days_stale = (latest_source - readme_mtime) / 86400
    if days_stale > 90:
        return [{"file": "README.md", "line": 0, "detail": f"README.md is {int(days_stale)} days behind latest source change"}]
    return []


def _scan_rule(repo: str, rule: MaintenanceRule) -> Dict[str, Any]:
    scanner = MAINTENANCE_SCANNERS.get(rule.id)
    if scanner is None:
        reason = "no built-in scanner"
        if rule.external_tool:
            reason += f"; try: {rule.external_tool}"
        return {"rule_id": rule.id, "status": "skip", "title": rule.title,
                "category": rule.category, "reason": reason, "findings": []}
    findings = scanner(repo)
    status = "fail" if findings else "pass"
    return {"rule_id": rule.id, "status": status, "title": rule.title,
            "category": rule.category, "findings": findings}


# ---------------------------------------------------------------------------
# Ticket body formatters
# ---------------------------------------------------------------------------
def _format_suggestion_body(rule: MaintenanceRule) -> str:
    tool_section = ""
    if rule.external_tool:
        tool_section = f"""
## External Tool
```
{rule.external_tool}
```
"""
    return f"""## Goal
Investigate and remediate: {rule.title}

## Detection Heuristic
{rule.detection}
{tool_section}
## Recommended Action
{rule.action}

## Acceptance Criteria
- [ ] Run detection heuristic against codebase
- [ ] Fix any issues found, or close ticket if none exist
- [ ] Verify fix passes CI

## Notes
Auto-generated by `mt maintain create` (rule {rule.id}, category: {rule.category})
"""


def _format_finding_body(rule: MaintenanceRule, findings: List[Dict[str, Any]]) -> str:
    lines = []
    for f in findings:
        loc = f"line {f['line']}" if f.get("line") else "file"
        lines.append(f"- `{f['file']}` ({loc}): {f['detail']}")
    findings_text = "\n".join(lines)
    return f"""## Goal
Fix detected issue: {rule.title}

## Findings
{findings_text}

## Recommended Action
{rule.action}

## Acceptance Criteria
- [ ] Address all findings listed above
- [ ] Verify fix passes CI

## Notes
Auto-detected by `mt maintain scan` (rule {rule.id}, category: {rule.category})
"""


# ---------------------------------------------------------------------------
# Maintain config + external tool invocation + logging
# ---------------------------------------------------------------------------

_DEFAULT_MAINTAIN_CONFIG = """\
# tickets/maintain.yaml
# Enable/disable categories and configure external tools for mt maintain scan.

# Global settings
settings:
  log_file: tickets/maintain.log
  timeout: 60
  enabled: true

# Per-category tool configuration
# Set enabled: true and provide the command for your stack.
# Use {repo} as placeholder for the repository root path.
# Optional per-tool fields:
#   timeout: 120          # per-tool timeout in seconds (overrides global)
#   fix_command: ...      # auto-fix command (used with mt maintain scan --fix)

security:
  cve_scanner:
    enabled: false
    # command: pip-audit --format=json
    # command: npm audit --json
    # command: cargo audit --json
    # command: osv-scanner --format=json -r {repo}
  secret_scanner:
    enabled: false
    # command: gitleaks detect --source={repo} --report-format=json --no-git
  ssl_check:
    enabled: false
    # command: openssl s_client -connect example.com:443 2>/dev/null | openssl x509 -noout -enddate

deps:
  outdated_check:
    enabled: false
    # command: pip list --outdated --format=json
    # command: npm outdated --json
    # command: cargo outdated --format=json
  license_check:
    enabled: false
    # command: pip-licenses --format=json
    # command: license-checker --json
  unused_deps:
    enabled: false
    # command: depcheck --json
    # command: vulture {repo}

code_health:
  complexity:
    enabled: false
    # command: radon cc {repo} -a -j
  linter:
    enabled: false
    # command: pylint {repo} --output-format=json
    # command: eslint {repo}/src --format=json
    # command: cargo clippy --message-format=json
    # fix_command: cargo clippy --fix --allow-dirty
  formatter_check:
    enabled: false
    # command: black --check {repo} --quiet
    # fix_command: black {repo}
    # command: cargo fmt --check
    # fix_command: cargo fmt
  type_check:
    enabled: false
    # command: mypy {repo} --no-error-summary

performance:
  profiler:
    enabled: false
  bundle_size:
    enabled: false

database:
  migration_check:
    enabled: false
  query_analyzer:
    enabled: false

infrastructure:
  container_scan:
    enabled: false
  k8s_health:
    enabled: false
  terraform_drift:
    enabled: false

observability:
  prometheus_check:
    enabled: false
  alert_check:
    enabled: false

testing:
  coverage:
    enabled: false
    # command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout
    # command: nyc --reporter=json npm test
  test_runner:
    enabled: false
    # command: pytest {repo} --tb=short -q

documentation:
  link_checker:
    enabled: false
    # command: markdown-link-check {repo}/docs/**/*.md --json
  openapi_diff:
    enabled: false
"""

# Maps maintain.yaml category keys to MAINTENANCE_CATEGORIES slugs
_CONFIG_CATEGORY_MAP = {
    "security": "security",
    "deps": "deps",
    "code_health": "code-health",
    "performance": "performance",
    "database": "database",
    "infrastructure": "infrastructure",
    "observability": "observability",
    "testing": "testing",
    "documentation": "docs",
}

# Maps maintain.yaml tool keys to rule IDs they cover
_CONFIG_TOOL_RULE_MAP: Dict[str, List[int]] = {
    "cve_scanner": [1, 25],
    "secret_scanner": [2, 6],
    "ssl_check": [3],
    "outdated_check": [21],
    "license_check": [31],
    "unused_deps": [30],
    "complexity": [41],
    "linter": [44, 45, 47],
    "formatter_check": [53],
    "type_check": [55],
    "profiler": [63],
    "bundle_size": [29],
    "migration_check": [89],
    "query_analyzer": [61],
    "container_scan": [101],
    "k8s_health": [106],
    "terraform_drift": [117],
    "prometheus_check": [121],
    "alert_check": [122],
    "coverage": [134],
    "test_runner": [131],
    "link_checker": [142],
    "openapi_diff": [141],
}


def _parse_nested_yaml(text: str) -> Dict[str, Any]:
    """Parse a simple nested YAML config (up to 3 levels of indentation).

    This handles the maintain.yaml format without requiring PyYAML:
        settings:
          log_file: tickets/maintain.log
          timeout: 60
        security:
          cve_scanner:
            enabled: true
            command: echo ok
    """
    root: Dict[str, Any] = {}
    stack: List[tuple] = []  # (indent, dict_ref)

    def _coerce(v: str) -> Any:
        if v.lower() in ("null", "none", "~", ""):
            return None
        if v.lower() == "true":
            return True
        if v.lower() == "false":
            return False
        if re.fullmatch(r"-?\d+", v):
            return int(v)
        if re.fullmatch(r"-?\d+\.\d+", v):
            return float(v)
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            return v[1:-1]
        return v

    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if ":" not in stripped:
            continue

        indent = len(raw) - len(raw.lstrip())
        k, v = stripped.split(":", 1)
        k = k.strip()
        v = v.strip()

        # Pop stack entries at same or deeper indent
        while stack and stack[-1][0] >= indent:
            stack.pop()

        target = stack[-1][1] if stack else root

        if not v:
            # Key with no value -> nested dict
            child: Dict[str, Any] = {}
            target[k] = child
            stack.append((indent, child))
        else:
            target[k] = _coerce(v)

    return root


def _load_maintain_config(repo: str) -> Dict[str, Any]:
    """Load tickets/maintain.yaml if it exists, return empty dict otherwise."""
    config_path = os.path.join(repo, "tickets", "maintain.yaml")
    if not os.path.exists(config_path):
        return {}
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            text = f.read()
        try:
            import yaml  # type: ignore
            return yaml.safe_load(text) or {}
        except ImportError:
            return _parse_nested_yaml(text)
    except OSError:
        return {}


def _get_config_log_path(repo: str, config: Dict[str, Any]) -> Optional[str]:
    """Return the absolute log file path from config, or None."""
    settings = config.get("settings", {})
    if not isinstance(settings, dict):
        return None
    log_file = settings.get("log_file")
    if log_file:
        return os.path.join(repo, log_file)
    return None


def _get_config_timeout(config: Dict[str, Any]) -> int:
    """Return timeout in seconds from config settings."""
    settings = config.get("settings", {})
    if isinstance(settings, dict):
        return int(settings.get("timeout", 60))
    return 60


def _log_tool_run(log_path: str, rule_id: int, tool_name: str, status: str,
                  duration: float, findings: int = 0, reason: str = "") -> None:
    """Append one line to the maintain log file."""
    ts = utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")
    parts = [f"{ts}  SCAN  rule={rule_id:<4d} tool={tool_name:<16s} status={status:<5s} duration={duration:.1f}s"]
    if status == "fail":
        parts.append(f"findings={findings}")
    if status == "skip" and reason:
        parts.append(f"reason={reason}")
    line = "  ".join(parts)
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def _get_enabled_external_tools(config: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """Extract enabled external tools from config, keyed by tool name."""
    tools: Dict[str, Dict[str, Any]] = {}
    for cat_key, cat_slug in _CONFIG_CATEGORY_MAP.items():
        cat_config = config.get(cat_key)
        if not isinstance(cat_config, dict):
            continue
        for tool_name, tool_conf in cat_config.items():
            if not isinstance(tool_conf, dict):
                continue
            if tool_conf.get("enabled") and tool_conf.get("command"):
                tools[tool_name] = {
                    "command": tool_conf["command"],
                    "category": cat_slug,
                    "rule_ids": _CONFIG_TOOL_RULE_MAP.get(tool_name, []),
                }
    return tools


def _run_external_tool(command: str, repo: str, timeout: int) -> Dict[str, Any]:
    """Run an external tool command, return result dict."""
    cmd = command.replace("{repo}", repo)
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=repo, capture_output=True, text=True,
            timeout=timeout,
        )
        return {
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
    except subprocess.TimeoutExpired:
        return {"returncode": -1, "stdout": "", "stderr": f"timeout after {timeout}s"}
    except OSError as e:
        return {"returncode": -1, "stdout": "", "stderr": str(e)}


def _scan_rule_with_config(repo: str, rule: MaintenanceRule,
                           config: Dict[str, Any], log_path: Optional[str]) -> Dict[str, Any]:
    """Scan a rule using built-in scanner or configured external tool, with logging."""
    import time as _time

    # Try built-in scanner first
    scanner = MAINTENANCE_SCANNERS.get(rule.id)
    if scanner is not None:
        start = _time.monotonic()
        findings = scanner(repo)
        duration = _time.monotonic() - start
        status = "fail" if findings else "pass"
        if log_path:
            _log_tool_run(log_path, rule.id, "built-in", status, duration,
                          findings=len(findings))
        return {"rule_id": rule.id, "status": status, "title": rule.title,
                "category": rule.category, "findings": findings}

    # Try external tool from config
    ext_tools = _get_enabled_external_tools(config)
    for tool_name, tool_info in ext_tools.items():
        if rule.id in tool_info.get("rule_ids", []):
            timeout = _get_tool_timeout(config, tool_name)
            start = _time.monotonic()
            result = _run_external_tool(tool_info["command"], repo, timeout)
            duration = _time.monotonic() - start
            if result["returncode"] == 0:
                status = "pass"
                findings_list: List[Dict[str, Any]] = []
            else:
                status = "fail"
                detail = result["stdout"][:500] or result["stderr"][:500]
                findings_list = [{"file": "", "line": 0,
                                  "detail": f"external tool '{tool_name}' reported issue: {detail.strip()[:200]}"}]
            if log_path:
                _log_tool_run(log_path, rule.id, tool_name, status, duration,
                              findings=len(findings_list))
            return {"rule_id": rule.id, "status": status, "title": rule.title,
                    "category": rule.category, "findings": findings_list}

    # No scanner available
    reason = "no built-in scanner"
    if rule.external_tool:
        reason += f"; try: {rule.external_tool}"
    if log_path:
        _log_tool_run(log_path, rule.id, "none", "skip", 0.0, reason="no_config")
    return {"rule_id": rule.id, "status": "skip", "title": rule.title,
            "category": rule.category, "reason": reason, "findings": []}


def _get_tool_timeout(config: Dict[str, Any], tool_name: str) -> int:
    """Return per-tool timeout if configured, else global timeout."""
    for cat_key in _CONFIG_CATEGORY_MAP:
        cat_config = config.get(cat_key)
        if not isinstance(cat_config, dict):
            continue
        tool_conf = cat_config.get(tool_name)
        if isinstance(tool_conf, dict) and "timeout" in tool_conf:
            return int(tool_conf["timeout"])
    return _get_config_timeout(config)


# Scan profiles: presets mapping profile names to category lists
_SCAN_PROFILES: Dict[str, List[str]] = {
    "ci": ["security", "code-health", "testing"],
    "nightly": MAINTENANCE_CATEGORIES[:],
}


def _detect_project_stack(repo: str) -> Dict[str, bool]:
    """Detect which language/tool stacks are present in the repo."""
    checks = {
        "python": ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"],
        "node": ["package.json"],
        "rust": ["Cargo.toml"],
        "go": ["go.mod"],
        "docker": ["Dockerfile"],
        "terraform": ["main.tf"],
        "k8s": ["k8s", "kubernetes"],
    }
    detected: Dict[str, bool] = {}
    for stack, markers in checks.items():
        for marker in markers:
            path = os.path.join(repo, marker)
            if os.path.exists(path):
                detected[stack] = True
                break
    return detected


def _generate_detected_config(repo: str) -> str:
    """Generate a maintain.yaml with tools pre-enabled based on detected stack."""
    stacks = _detect_project_stack(repo)
    lines = [
        "# tickets/maintain.yaml",
        "# Auto-generated by mt maintain init-config --detect",
        f"# Detected stacks: {', '.join(sorted(stacks.keys())) or 'none'}",
        "",
        "settings:",
        "  log_file: tickets/maintain.log",
        "  timeout: 60",
        "  enabled: true",
        "",
    ]

    if stacks.get("python"):
        lines += [
            "security:",
            "  cve_scanner:",
            "    enabled: true",
            "    command: pip-audit --format=json",
            "  secret_scanner:",
            "    enabled: true",
            "    command: gitleaks detect --source={repo} --report-format=json --no-git",
            "",
            "deps:",
            "  outdated_check:",
            "    enabled: true",
            "    command: pip list --outdated --format=json",
            "  license_check:",
            "    enabled: true",
            "    command: pip-licenses --format=json",
            "",
            "code_health:",
            "  linter:",
            "    enabled: true",
            "    command: pylint {repo} --output-format=json --exit-zero",
            "  formatter_check:",
            "    enabled: true",
            "    command: black --check {repo} --quiet",
            "  type_check:",
            "    enabled: true",
            "    command: mypy {repo} --no-error-summary",
            "",
            "testing:",
            "  coverage:",
            "    enabled: true",
            "    command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout",
            "  test_runner:",
            "    enabled: true",
            "    command: pytest {repo} --tb=short -q",
            "",
        ]
    elif stacks.get("node"):
        lines += [
            "security:",
            "  cve_scanner:",
            "    enabled: true",
            "    command: npm audit --json",
            "  secret_scanner:",
            "    enabled: true",
            "    command: gitleaks detect --source={repo} --report-format=json --no-git",
            "",
            "deps:",
            "  outdated_check:",
            "    enabled: true",
            "    command: npm outdated --json",
            "  license_check:",
            "    enabled: true",
            "    command: license-checker --json",
            "  unused_deps:",
            "    enabled: true",
            "    command: depcheck --json",
            "",
            "code_health:",
            "  linter:",
            "    enabled: true",
            "    command: eslint src --format=json",
            "  formatter_check:",
            "    enabled: true",
            "    command: \"prettier --check 'src/**/*.{ts,tsx,js}'\"",
            "",
            "testing:",
            "  test_runner:",
            "    enabled: true",
            "    command: npm test -- --json",
            "  coverage:",
            "    enabled: true",
            "    command: nyc --reporter=json npm test",
            "",
        ]
    elif stacks.get("rust"):
        lines += [
            "security:",
            "  cve_scanner:",
            "    enabled: true",
            "    command: cargo audit --json",
            "  secret_scanner:",
            "    enabled: true",
            "    command: gitleaks detect --source={repo} --report-format=json --no-git",
            "",
            "deps:",
            "  outdated_check:",
            "    enabled: true",
            "    command: cargo outdated --format=json",
            "  unused_deps:",
            "    enabled: true",
            "    command: cargo-udeps --output json",
            "",
            "code_health:",
            "  formatter_check:",
            "    enabled: true",
            "    command: cargo fmt --check",
            "",
            "testing:",
            "  test_runner:",
            "    enabled: true",
            "    command: cargo test --message-format=json",
            "",
        ]
    elif stacks.get("go"):
        lines += [
            "security:",
            "  cve_scanner:",
            "    enabled: true",
            "    command: govulncheck ./...",
            "  secret_scanner:",
            "    enabled: true",
            "    command: gitleaks detect --source={repo} --report-format=json --no-git",
            "",
            "testing:",
            "  test_runner:",
            "    enabled: true",
            "    command: go test ./...",
            "  coverage:",
            "    enabled: true",
            "    command: go test -coverprofile=coverage.out ./...",
            "",
        ]
    else:
        # Fallback: just secrets scanning
        lines += [
            "security:",
            "  secret_scanner:",
            "    enabled: false",
            "    # command: gitleaks detect --source={repo} --report-format=json --no-git",
            "",
        ]

    if stacks.get("docker"):
        lines += [
            "infrastructure:",
            "  container_scan:",
            "    enabled: true",
            "    command: trivy image --format=json",
            "",
        ]

    if stacks.get("terraform"):
        lines += [
            "infrastructure:",
            "  terraform_drift:",
            "    enabled: true",
            "    command: terraform plan -detailed-exitcode -json",
            "",
        ]

    # Documentation checks always useful
    lines += [
        "documentation:",
        "  link_checker:",
        "    enabled: false",
        "    # command: markdown-link-check {repo}/docs/**/*.md --json",
        "",
    ]

    return "\n".join(lines) + "\n"


def cmd_maintain_init_config(args: argparse.Namespace) -> int:
    repo = find_repo_root()
    tdir = tickets_dir(repo)
    ensure_tickets_dir(tdir)
    config_path = os.path.join(tdir, "maintain.yaml")
    if os.path.exists(config_path) and not getattr(args, "force", False):
        eprint(f"config already exists: {config_path}")
        eprint("use --force to overwrite")
        return 1
    if getattr(args, "detect", False):
        content = _generate_detected_config(repo)
        stacks = _detect_project_stack(repo)
        eprint(f"detected stacks: {', '.join(sorted(stacks.keys())) or 'none'}")
    else:
        content = _DEFAULT_MAINTAIN_CONFIG
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(content)
    print(config_path)
    return 0


def _get_fix_commands(config: Dict[str, Any]) -> Dict[str, str]:
    """Extract fix_command entries from config, keyed by tool name."""
    fixes: Dict[str, str] = {}
    for cat_key in _CONFIG_CATEGORY_MAP:
        cat_config = config.get(cat_key)
        if not isinstance(cat_config, dict):
            continue
        for tool_name, tool_conf in cat_config.items():
            if isinstance(tool_conf, dict) and tool_conf.get("fix_command"):
                fixes[tool_name] = tool_conf["fix_command"]
    return fixes


def _run_fix_commands(repo: str, config: Dict[str, Any],
                      results: List[Dict[str, Any]]) -> None:
    """Run fix_command for tools whose rules failed."""
    fixes = _get_fix_commands(config)
    if not fixes:
        return
    failed_rule_ids = {r["rule_id"] for r in results if r["status"] == "fail"}
    ext_tools = _get_enabled_external_tools(config)
    for tool_name, tool_info in ext_tools.items():
        if tool_name not in fixes:
            continue
        if any(rid in failed_rule_ids for rid in tool_info.get("rule_ids", [])):
            fix_cmd = fixes[tool_name].replace("{repo}", repo)
            eprint(f"[FIX]  running: {fix_cmd}")
            try:
                result = subprocess.run(
                    fix_cmd, shell=True, cwd=repo, capture_output=True, text=True,
                    timeout=_get_tool_timeout(config, tool_name),
                )
                if result.returncode == 0:
                    eprint(f"[FIX]  {tool_name}: applied successfully")
                else:
                    eprint(f"[FIX]  {tool_name}: fix command returned {result.returncode}")
                    if result.stderr.strip():
                        eprint(f"       {result.stderr.strip()[:200]}")
            except (subprocess.TimeoutExpired, OSError) as e:
                eprint(f"[FIX]  {tool_name}: {e}")


def cmd_maintain_doctor(args: argparse.Namespace) -> int:
    """Verify all tools enabled in maintain.yaml are installed and reachable."""
    repo = find_repo_root()
    config = _load_maintain_config(repo)
    if not config:
        eprint("no tickets/maintain.yaml found. run: mt maintain init-config")
        return 2

    ext_tools = _get_enabled_external_tools(config)
    if not ext_tools:
        eprint("no external tools enabled in maintain.yaml")
        return 0

    ok_count = 0
    fail_count = 0
    for tool_name, tool_info in ext_tools.items():
        command = tool_info["command"]
        # Extract the binary name (first word before space or {repo})
        binary = command.split()[0].replace("{repo}", "").strip()
        if not binary:
            binary = command.split()[0]
        found = shutil.which(binary)
        if found:
            print(f"[OK]    {tool_name:<20s} {binary} -> {found}")
            ok_count += 1
        else:
            print(f"[MISS]  {tool_name:<20s} {binary} -- not found on PATH")
            fail_count += 1

    eprint(f"\n{ok_count + fail_count} tool(s) checked: {ok_count} available, {fail_count} missing")
    return 1 if fail_count > 0 else 0


# ---------------------------------------------------------------------------
# Subcommands: mt maintain list | scan | create
# ---------------------------------------------------------------------------
def _collect_existing_maint_tags(repo: str) -> set:
    existing = load_all_tickets(repo)
    tags: set = set()
    for t in existing:
        meta = normalize_meta(t.meta)
        if meta.get("status") != "done":
            for tag in (meta.get("tags") or []):
                if tag.startswith("maint-rule-"):
                    tags.add(tag)
    return tags


def cmd_maintain_list(args: argparse.Namespace) -> int:
    rules = _filter_maintenance_rules(args.category, args.rule)
    if not rules:
        eprint("no rules match the given filters.")
        return 1
    for rule in rules:
        has_scanner = rule.id in MAINTENANCE_SCANNERS
        scanner_tag = "built-in" if has_scanner else "external"
        print(f"  {rule.id:3d}  [{rule.category:<16}] {rule.title}  ({scanner_tag})")
        print(f"        detection: {rule.detection}")
        if rule.external_tool:
            print(f"        tool: {rule.external_tool}")
    return 0


def cmd_maintain_scan(args: argparse.Namespace) -> int:
    # Resolve --profile into categories
    if getattr(args, "profile", None):
        profile_cats = _SCAN_PROFILES.get(args.profile, [])
        args.category = list(set(args.category + profile_cats))

    if not args.category and not args.rule and not getattr(args, "all", False):
        eprint("error: --category, --rule, --all, or --profile required for scanning.")
        eprint("hint: mt maintain list  (to browse rules first)")
        return 2

    if getattr(args, "all", False):
        args.category = MAINTENANCE_CATEGORIES[:]

    repo = find_repo_root()
    rules = _filter_maintenance_rules(args.category, args.rule)
    if not rules:
        eprint("no rules match the given filters.")
        return 1

    config = _load_maintain_config(repo)
    log_path = _get_config_log_path(repo, config)

    results = [_scan_rule_with_config(repo, rule, config, log_path) for rule in rules]

    # --diff: compare against last scan and show only new findings
    last_scan_path = os.path.join(repo, "tickets", "maintain.last.json")
    if getattr(args, "diff", False):
        prev_results: List[Dict[str, Any]] = []
        if os.path.exists(last_scan_path):
            try:
                with open(last_scan_path, "r", encoding="utf-8") as f:
                    prev_results = json.load(f)
            except (json.JSONDecodeError, OSError):
                prev_results = []
        prev_by_rule: Dict[int, Dict[str, Any]] = {r["rule_id"]: r for r in prev_results}
        new_results = []
        for r in results:
            prev = prev_by_rule.get(r["rule_id"])
            if prev is None or prev.get("status") != r["status"]:
                new_results.append(r)
            elif r["status"] == "fail" and prev.get("status") == "fail":
                # Show only new findings not in previous scan
                prev_details = {(f.get("file"), f.get("line"), f.get("detail")) for f in prev.get("findings", [])}
                new_findings = [f for f in r.get("findings", [])
                                if (f.get("file"), f.get("line"), f.get("detail")) not in prev_details]
                if new_findings:
                    r_copy = dict(r)
                    r_copy["findings"] = new_findings
                    new_results.append(r_copy)
        results = new_results
        if not results:
            eprint("no new findings since last scan.")

    # Save current scan for future --diff
    try:
        os.makedirs(os.path.dirname(last_scan_path), exist_ok=True)
        full_results = [_scan_rule_with_config(repo, rule, config, None) for rule in rules] if getattr(args, "diff", False) else results
        with open(last_scan_path, "w", encoding="utf-8") as f:
            json.dump(full_results, f, indent=2)
    except OSError:
        pass

    # --fix: run fix commands for tools that support it
    if getattr(args, "fix", False):
        _run_fix_commands(repo, config, results)

    if args.format == "json":
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            status = r["status"].upper()
            tag = {"PASS": "PASS", "FAIL": "FAIL", "SKIP": "SKIP"}[status]
            if status == "FAIL":
                count = len(r["findings"])
                print(f"[{tag}]  rule {r['rule_id']:3d}: {r['title']} -- {count} finding(s)")
                for f in r["findings"]:
                    loc = f":{f['line']}" if f.get("line") else ""
                    print(f"        {f['file']}{loc}: {f['detail']}")
            elif status == "PASS":
                print(f"[{tag}]  rule {r['rule_id']:3d}: {r['title']} -- ok")
            else:
                reason = r.get("reason", "no built-in scanner")
                print(f"[{tag}]  rule {r['rule_id']:3d}: {r['title']} -- {reason}")

    fail_count = sum(1 for r in results if r["status"] == "fail")
    pass_count = sum(1 for r in results if r["status"] == "pass")
    skip_count = sum(1 for r in results if r["status"] == "skip")
    eprint(f"\n{len(results)} rule(s) scanned: {fail_count} failed, {pass_count} passed, {skip_count} skipped")
    return 1 if fail_count > 0 else 0


def cmd_maintain_create(args: argparse.Namespace) -> int:
    if not args.category and not args.rule and not getattr(args, "all", False):
        eprint("error: --category, --rule, or --all required.")
        eprint("hint: mt maintain scan --category <cat>  (to scan first)")
        return 2

    if getattr(args, "all", False):
        args.category = MAINTENANCE_CATEGORIES[:]

    repo = find_repo_root()
    tdir = tickets_dir(repo)
    ensure_tickets_dir(tdir)

    rules = _filter_maintenance_rules(args.category, args.rule)
    if not rules:
        eprint("no rules match the given filters.")
        return 1

    # Scan unless --skip-scan
    config = _load_maintain_config(repo)
    log_path = _get_config_log_path(repo, config)
    scan_results: Dict[int, Dict[str, Any]] = {}
    if not args.skip_scan:
        for rule in rules:
            scan_results[rule.id] = _scan_rule_with_config(repo, rule, config, log_path)

    existing_tags = _collect_existing_maint_tags(repo)

    created = 0
    skipped_dedup = 0
    skipped_pass = 0
    for rule in rules:
        tag = f"maint-rule-{rule.id}"
        if tag in existing_tags:
            skipped_dedup += 1
            continue

        # Determine if we should create a ticket
        scan = scan_results.get(rule.id)
        if scan and scan["status"] == "pass":
            skipped_pass += 1
            continue

        # Build ticket body
        if scan and scan["status"] == "fail" and scan["findings"]:
            body = _format_finding_body(rule, scan["findings"])
        else:
            body = _format_suggestion_body(rule)

        if args.dry_run:
            label = "findings" if (scan and scan["status"] == "fail") else "suggestion"
            print(f"[dry-run] [{label}] [MAINT-{rule.id:03d}] {rule.title}")
            created += 1
            continue

        tid = next_ticket_id_for_repo(repo)
        meta = normalize_meta({
            "id": tid,
            "title": f"[MAINT-{rule.id:03d}] {rule.title}",
            "status": "ready",
            "priority": args.priority if args.priority else rule.default_priority,
            "type": rule.default_type,
            "effort": rule.default_effort,
            "labels": rule.labels + ["auto-maintenance"],
            "tags": [f"maint-rule-{rule.id}", f"maint-cat-{rule.category}"],
            "owner": args.owner,
            "created": now_utc_iso(),
            "updated": now_utc_iso(),
            "depends_on": [],
            "branch": None,
        })

        path = os.path.join(tdir, f"{tid}.md")
        write_ticket(Ticket(path=path, meta=meta, body=body))
        print(path)
        created += 1

    eprint(f"{created} ticket(s) {'would be ' if args.dry_run else ''}created, "
           f"{skipped_dedup} skipped (duplicates), {skipped_pass} skipped (scan passed)")
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
    p_claim.add_argument("--max-claimed-per-owner", type=int, default=2, help="Per-owner WIP limit (default: 2)")
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
    p_ss.add_argument("--owner", default=None, help="Owner (required when transitioning to claimed without existing owner)")
    p_ss.add_argument("--branch", default=None, help="Branch name (auto-generated if omitted)")
    p_ss.add_argument("--ignore-deps", action="store_true", help="Skip dependency check when transitioning to claimed")
    p_ss.add_argument("--max-claimed-per-owner", type=int, default=2, help="Per-owner WIP limit (default: 2)")
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

    p_maint = sub.add_parser("maintain", help="Autonomous maintenance: list rules, scan codebase, create tickets.")
    maint_sub = p_maint.add_subparsers(dest="maintain_cmd", required=True)

    # mt maintain init-config
    p_minit = maint_sub.add_parser("init-config", help="Generate default tickets/maintain.yaml config file.")
    p_minit.add_argument("--force", action="store_true",
                         help="Overwrite existing config file")
    p_minit.add_argument("--detect", action="store_true",
                         help="Auto-detect project stack and pre-enable matching tools")
    p_minit.set_defaults(func=cmd_maintain_init_config)

    # mt maintain doctor
    p_mdoctor = maint_sub.add_parser("doctor", help="Verify all enabled tools in maintain.yaml are installed.")
    p_mdoctor.set_defaults(func=cmd_maintain_doctor)

    # mt maintain list
    p_mlist = maint_sub.add_parser("list", help="Browse the maintenance rules taxonomy.")
    p_mlist.add_argument("--category", action="append", default=[],
                         choices=MAINTENANCE_CATEGORIES,
                         help="Filter by category (repeatable)")
    p_mlist.add_argument("--rule", action="append", default=[], type=int,
                         help="Filter by rule number (repeatable)")
    p_mlist.set_defaults(func=cmd_maintain_list)

    # mt maintain scan
    p_mscan = maint_sub.add_parser("scan", help="Scan codebase against maintenance rules (no tickets created).")
    p_mscan.add_argument("--category", action="append", default=[],
                         choices=MAINTENANCE_CATEGORIES,
                         help="Category to scan (repeatable, required: --category or --rule)")
    p_mscan.add_argument("--rule", action="append", default=[], type=int,
                         help="Specific rule number (repeatable)")
    p_mscan.add_argument("--all", action="store_true",
                         help="Scan all categories")
    p_mscan.add_argument("--diff", action="store_true",
                         help="Show only new findings compared to last scan")
    p_mscan.add_argument("--format", choices=["text", "json"], default="text",
                         help="Output format (default: text)")
    p_mscan.add_argument("--profile", choices=["ci", "nightly"], default=None,
                         help="Use a preset category profile (ci: security+code-health+testing, nightly: all)")
    p_mscan.add_argument("--fix", action="store_true",
                         help="Run fix_command for tools with auto-fix support")
    p_mscan.set_defaults(func=cmd_maintain_scan)

    # mt maintain create
    p_mcreate = maint_sub.add_parser("create", help="Create tickets for maintenance issues (scans first by default).")
    p_mcreate.add_argument("--category", action="append", default=[],
                           choices=MAINTENANCE_CATEGORIES,
                           help="Category to create tickets for (repeatable, required: --category or --rule)")
    p_mcreate.add_argument("--rule", action="append", default=[], type=int,
                           help="Specific rule number (repeatable)")
    p_mcreate.add_argument("--dry-run", action="store_true",
                           help="Preview tickets without creating them")
    p_mcreate.add_argument("--priority", choices=DEFAULT_PRIORITIES, default=None,
                           help="Override default priority for all generated tickets")
    p_mcreate.add_argument("--owner", default=None,
                           help="Pre-assign generated tickets to this owner")
    p_mcreate.add_argument("--all", action="store_true",
                           help="Create for all categories")
    p_mcreate.add_argument("--skip-scan", action="store_true",
                           help="Create suggestion tickets without scanning (legacy behavior)")
    p_mcreate.set_defaults(func=cmd_maintain_create)

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
