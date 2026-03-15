# Autonomous Software Maintenance Rules

### Agent‑Detectable Maintenance Taxonomy for Muon Stack

Designed for: - MuonTickets - HiggsAgent - Muonium Stack CI agents -
Local + cloud LLM agents

Each rule includes: - Ticket Type - Detection Heuristic - Agent Action

------------------------------------------------------------------------

# Category 1 --- Security Maintenance (20)

1.  CVE Dependency Vulnerability\
    Detection: dependency version \< secure version from CVE DB\
    Action: upgrade dependency and run tests

2.  Exposed Secrets in Repo\
    Detection: regex patterns (AKIA..., private_key)\
    Action: remove secret and move to vault

3.  Expired SSL Certificate\
    Detection: ssl_expiry_date \< now + 14 days\
    Action: renew certificate

4.  Missing Security Headers\
    Detection: missing CSP, X‑Frame‑Options, X‑XSS‑Protection\
    Action: add headers

5.  Insecure Hashing Algorithm\
    Detection: md5 or sha1 usage\
    Action: migrate to argon2/bcrypt

6.  Hardcoded Password\
    Detection: password="..." pattern\
    Action: move to environment variable

7.  Open Debug Ports\
    Detection: container exposing debug ports (9229, 3000)\
    Action: disable in production

8.  Unauthenticated Admin Endpoint\
    Detection: /admin route without auth middleware\
    Action: enforce auth guard

9.  Excessive IAM Privileges\
    Detection: policy contains "\*"\
    Action: restrict permissions

10. Unencrypted DB Connection\
    Detection: connection string missing TLS flag\
    Action: enforce encrypted connections

11--20 additional security rules\
- weak JWT secret\
- missing rate limiting\
- disabled CSRF protection\
- dependency signature mismatch\
- container running as root\
- outdated OpenSSL\
- public cloud bucket\
- exposed .env file\
- missing MFA for admin\
- suspicious login activity

------------------------------------------------------------------------

# Category 2 --- Dependency Maintenance (20)

21. Outdated dependency\
    Detection: npm/pip/cargo outdated\
    Action: upgrade version

22. Deprecated library\
    Detection: upstream marked deprecated\
    Action: migrate replacement

23. Unmaintained dependency\
    Detection: last commit \> 3 years\
    Action: replace library

24. Duplicate libraries\
    Detection: multiple versions installed\
    Action: consolidate version

25. Vulnerable transitive dependency\
    Detection: nested CVE scan\
    Action: update dependency tree

26. Lockfile drift\
    Detection: mismatch with installed packages\
    Action: rebuild lockfile

27. Outdated build toolchain\
    Detection: compiler older than LTS\
    Action: upgrade

28. Runtime EOL\
    Detection: runtime end‑of‑life version\
    Action: upgrade runtime

29. Dependency size explosion\
    Detection: bundle size threshold exceeded\
    Action: audit dependency

30. Unused dependency\
    Detection: static import analysis\
    Action: remove package

31--40 additional dependency rules\
- license change detection\
- conflicting version ranges\
- unused peer dependencies\
- broken registry references\
- checksum mismatch\
- incompatible binary architecture\
- outdated wasm runtime\
- outdated GPU drivers\
- mirror outage fallback\
- corrupted dependency cache

------------------------------------------------------------------------

# Category 3 --- Code Health (20)

41. High cyclomatic complexity (\>15)\
42. File too large (\>1000 lines)\
43. Duplicate code blocks\
44. Dead code detection\
45. Deprecated API usage\
46. Missing error handling\
47. Logging inconsistency\
48. Excessive TODO comments\
49. Long parameter lists (\>6)\
50. Circular imports

51--60 additional rules\
- missing type hints\
- unused imports\
- inconsistent formatting\
- poor naming patterns\
- missing docstrings\
- nested loops\
- unsafe pointer ops\
- unbounded recursion\
- magic numbers\
- mutable global state

------------------------------------------------------------------------

# Category 4 --- Performance (20)

61. Slow database query (\>500ms)\
62. N+1 query pattern\
63. Memory leak detection\
64. High API latency (p95 threshold)\
65. Cache miss ratio \> 0.6\
66. Large response payloads\
67. O(n²) algorithms\
68. Unbounded job queue\
69. Excessive logging overhead\
70. Slow cold start

71--80 additional performance rules\
- thread starvation\
- lock contention\
- blocking IO in async code\
- oversized images\
- redundant network calls\
- inefficient serialization\
- slow WASM execution path\
- GPU underutilization\
- excessive disk writes\
- poor pagination

------------------------------------------------------------------------

# Category 5 --- Database Maintenance (20)

81. Missing index\
82. Unused index\
83. Table bloat\
84. Fragmented index\
85. Orphan records\
86. Duplicate rows\
87. Data format drift\
88. Backup failure\
89. Failed migration\
90. Slow join queries

91--100 additional rules\
- oversized JSON columns\
- unused tables\
- table scan alerts\
- encoding mismatch\
- unbounded table growth\
- missing partitioning\
- outdated statistics\
- corrupted index pages\
- replication lag\
- foreign key inconsistencies

------------------------------------------------------------------------

# Category 6 --- Infrastructure (20)

101. Container image outdated\
102. Missing OS security patches\
103. Low disk space\
104. CPU saturation\
105. Memory pressure\
106. CrashLoop pods\
107. Orphan containers\
108. Stale storage volumes\
109. Expired DNS records\
110. Misconfigured load balancer\
111. High network latency\
112. Unused cloud resources\
113. Broken CI runners\
114. Container restart loops\
115. Unused security groups\
116. Expired API gateway cert\
117. Infrastructure drift\
118. Registry cleanup required\
119. Log storage overflow\
120. Node version drift

------------------------------------------------------------------------

# Category 7 --- Observability (10)

121. Missing metrics\
122. Broken alerts\
123. Missing distributed tracing\
124. Log retention overflow\
125. Missing uptime checks\
126. Alert fatigue detection\
127. Missing error classification\
128. Inconsistent log schema\
129. Missing service map\
130. Outdated dashboards

------------------------------------------------------------------------

# Category 8 --- Test Maintenance (10)

131. Failing tests\
132. Flaky tests\
133. Missing regression tests\
134. Low coverage modules\
135. Outdated snapshot tests\
136. Slow test suite\
137. Missing integration tests\
138. Broken CI pipeline\
139. Missing edge case tests\
140. Inconsistent test data

------------------------------------------------------------------------

# Category 9 --- Documentation (10)

141. Outdated API docs\
142. Broken documentation links\
143. Outdated onboarding docs\
144. Missing architecture diagram\
145. Missing CLI examples\
146. Outdated deployment guide\
147. Undocumented endpoints\
148. Stale README\
149. Outdated SDK docs\
150. Missing changelog

------------------------------------------------------------------------

# Autonomous Maintenance Loop

monitor → detect rule violation → generate MuonTicket → assign agent →
fix → PR → CI verify → merge

This model enables **continuous autonomous self‑healing software
systems**.

## Using `mt maintain`

All 150 rules are encoded in the CLI. Five subcommands: `init-config`, `doctor`, `list`, `scan`, `create`.

### `mt maintain init-config` -- setup

```bash
mt maintain init-config                       # generate default config (all tools disabled)
mt maintain init-config --detect              # auto-detect stack and pre-enable tools
mt maintain init-config --detect --force      # overwrite existing config
```

`--detect` scans for `pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, `Dockerfile` and generates `tickets/maintain.yaml` with tools pre-enabled for the detected stack.

### `mt maintain doctor` -- verify tools

```bash
mt maintain doctor                            # check all enabled tools are on PATH
```

Reports `[OK]` or `[MISS]` per tool. Run before scanning to catch missing tools early.

### `mt maintain list` -- browse rules

```bash
mt maintain list                              # all 150 rules with detection heuristics
mt maintain list --category security          # one category
mt maintain list --rule 2 --rule 48           # specific rules
```

### `mt maintain scan` -- verify issues exist

Scan the codebase against rules. Reports PASS/FAIL/SKIP per rule. No tickets created. Invokes both built-in scanners and external tools configured in `tickets/maintain.yaml`.

```bash
mt maintain scan --category security          # scan security rules
mt maintain scan --all                        # scan all 150 rules
mt maintain scan --profile ci                 # preset: security+code-health+testing
mt maintain scan --profile nightly            # preset: all categories
mt maintain scan --rule 2 --rule 42 --rule 48 # specific rules
mt maintain scan --category code-health --format json  # JSON for agent consumption
mt maintain scan --all --diff                 # show only new findings since last scan
mt maintain scan --category code-health --fix # auto-fix where tools support it
```

Built-in scanners: exposed secrets (rules 2, 6), container-as-root (15), .env tracking (18), large files (42), TODO density (48), broken doc links (142), stale README (148). External tools from `maintain.yaml` are invoked for configured rules. Unconfigured rules without built-in scanners report SKIP.

Exit codes: `0` = all pass, `1` = findings detected, `2` = config/argument error.

### `mt maintain create` -- create tickets for verified issues

Scans first, creates tickets only for rules with findings. Rules that pass scanning are skipped. Ticket bodies include file paths, line numbers, and tool output.

```bash
mt maintain create --category security                # scan + create for failures
mt maintain create --all                              # all categories
mt maintain create --category docs --dry-run          # preview
mt maintain create --rule 1 --rule 2 --priority p0    # specific rules
mt maintain create --category testing --skip-scan     # create without scanning (suggestion tickets)
mt maintain create --category deps --owner agent-maint  # pre-assign
```

### Categories

| Slug | Rules | Description |
|------|------:|-------------|
| `security` | 1-20 | CVE, secrets, SSL, headers, auth |
| `deps` | 21-40 | Outdated, deprecated, unused dependencies |
| `code-health` | 41-60 | Complexity, dead code, formatting |
| `performance` | 61-80 | Slow queries, memory leaks, latency |
| `database` | 81-100 | Indexes, bloat, migrations |
| `infrastructure` | 101-120 | Containers, CI, cloud resources |
| `observability` | 121-130 | Metrics, alerts, tracing |
| `testing` | 131-140 | Flaky tests, coverage, CI pipeline |
| `docs` | 141-150 | API docs, README, changelog |

### Scan profiles

| Profile | Categories | Use case |
|---------|-----------|----------|
| `ci` | security, code-health, testing | Fast CI pipeline checks |
| `nightly` | all 9 categories | Comprehensive nightly scans |

### Configuration (`tickets/maintain.yaml`)

Each tool entry in `maintain.yaml` supports:
- `enabled: true/false` — whether to invoke during scan
- `command:` — shell command (`{repo}` replaced with repo root)
- `timeout:` — per-tool timeout in seconds (overrides global `settings.timeout`)
- `fix_command:` — auto-fix command for `--fix` flag (e.g. `cargo fmt`, `black {repo}`)

Tool invocations are logged to `tickets/maintain.log`. See [maintenance_tools_setup.md](maintenance_tools_setup.md) for install guides and starter configs.

### Deduplication

Each ticket is tagged `maint-rule-{id}`. Repeated `create` runs skip rules with existing open tickets.

### Scan diffing

`--diff` compares against `tickets/maintain.last.json` and shows only new findings. The last scan is saved automatically after each run.

### Agent workflow

```bash
# 1) One-time setup
mt maintain init-config --detect
mt maintain doctor

# 2) Scan for issues (lightweight agent or cron job)
mt maintain scan --all --format json

# 3) Create tickets only for verified failures
mt maintain create --all

# 4) Agents claim maintenance work
mt pick --owner agent-maint-1 --label auto-maintenance

# 5) Agent reads findings from ticket body, implements fix

# 6) After merge
mt done T-NNNNNN

# 7) Next scan shows only new findings (dedup + diff)
mt maintain scan --all --diff
mt maintain create --all
```
