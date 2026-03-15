# Maintenance Tools Setup Guide

This guide covers installing and configuring external tools used by `mt maintain scan` for automated preventive maintenance. Each category lists the tools needed, how to install them, and how to configure `tickets/maintain.yaml` so the scanner can invoke them automatically.

## Quick Start

```bash
# 1) Auto-detect your project stack and generate config
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain init-config --detect

# Or generate a blank config (all tools disabled) for manual setup
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain init-config

# 2) Verify all enabled tools are installed
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain doctor

# 3) Edit tickets/maintain.yaml to adjust tools as needed
$EDITOR tickets/maintain.yaml

# 4) Scan with external tools enabled
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all

# Or use a profile preset
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --profile ci

# 5) Review scan log
cat tickets/maintain.log

# 6) On subsequent runs, show only new findings
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all --diff
```

### Stack Auto-Detection

`mt maintain init-config --detect` inspects your repo for project files and generates a config with matching tools pre-enabled:

| Detected File | Stack | Tools Enabled |
|--------------|-------|---------------|
| `pyproject.toml` / `setup.py` / `requirements.txt` | Python | pip-audit, pylint, black, mypy, pytest, coverage |
| `package.json` | Node.js | npm audit, eslint, prettier, depcheck, nyc |
| `Cargo.toml` | Rust | cargo audit, cargo outdated, cargo fmt, cargo test |
| `go.mod` | Go | govulncheck, go test |
| `Dockerfile` | Docker | trivy container scan |
| `main.tf` | Terraform | terraform plan drift detection |

### Pre-Flight Check (`mt maintain doctor`)

Before scanning, run `doctor` to verify all enabled tools are installed:

```bash
$ uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain doctor
[OK]    cve_scanner          pip-audit -> /usr/local/bin/pip-audit
[OK]    secret_scanner       gitleaks -> /usr/local/bin/gitleaks
[MISS]  linter               pylint -- not found on PATH
[OK]    formatter_check      black -> /usr/local/bin/black

4 tool(s) checked: 3 available, 1 missing
```

Install missing tools before scanning to avoid mid-scan failures.

## Configuration File (`tickets/maintain.yaml`)

The config file lives at `tickets/maintain.yaml` in your project root. It controls which external tools the scanner invokes and how.

```yaml
# tickets/maintain.yaml
# Enable/disable categories and configure external tools for mt maintain scan.

# Global settings
settings:
  log_file: tickets/maintain.log   # where to log tool invocations
  timeout: 60                      # default timeout per tool (seconds)
  enabled: true                    # master switch

# Per-category tool configuration
# Set enabled: true and provide the command for your stack.
# Use {repo} as placeholder for the repository root path.
# Optional per-tool fields:
#   timeout: 120          # per-tool timeout in seconds (overrides global)
#   fix_command: ...      # auto-fix command (used with mt maintain scan --fix)

security:
  cve_scanner:
    enabled: false
    # Uncomment ONE command matching your stack:
    # command: npm audit --json
    # command: pip-audit --format=json
    # command: cargo audit --json
    # command: osv-scanner --format=json -r {repo}
    # command: trivy fs --format=json {repo}
    # command: grype dir:{repo} -o json
  ssl_check:
    enabled: false
    # command: openssl s_client -connect example.com:443 2>/dev/null | openssl x509 -noout -enddate
  secret_scanner:
    enabled: false
    # command: gitleaks detect --source={repo} --report-format=json
    # command: trufflehog filesystem {repo} --json
  iam_audit:
    enabled: false
    # command: aws iam get-account-authorization-details --output json

deps:
  outdated_check:
    enabled: false
    # command: npm outdated --json
    # command: pip list --outdated --format=json
    # command: cargo outdated --format=json
    # command: uv pip list --outdated --format=json
  license_check:
    enabled: false
    # command: license-checker --json
    # command: pip-licenses --format=json
    # command: cargo-license --json
  unused_deps:
    enabled: false
    # command: depcheck --json
    # command: vulture {repo}
    # command: cargo-udeps --output json

code_health:
  complexity:
    enabled: false
    # command: radon cc {repo} -a -j
    # command: eslint {repo}/src --rule 'complexity: [error, 15]' --format=json
  linter:
    enabled: false
    # command: pylint {repo} --output-format=json
    # command: eslint {repo}/src --format=json
    # command: clippy-driver --edition 2021
  formatter_check:
    enabled: false
    # command: black --check {repo} --quiet
    # command: prettier --check '{repo}/src/**/*.{ts,tsx,js}'
    # command: rustfmt --check {repo}/src/**/*.rs
  type_check:
    enabled: false
    # command: mypy {repo} --no-error-summary --json
    # command: pyright {repo} --outputjson

performance:
  profiler:
    enabled: false
    # command: py-spy record -o /dev/null --nonblocking -- python {repo}/app.py
  bundle_size:
    enabled: false
    # command: npm pack --dry-run --json
    # command: du -sb {repo}/dist

database:
  migration_check:
    enabled: false
    # command: alembic current
    # command: rails db:migrate:status
  query_analyzer:
    enabled: false
    # Requires database connection; configure DB_URL in environment
    # command: pgbadger --format json /var/log/postgresql/*.log

infrastructure:
  container_scan:
    enabled: false
    # command: trivy image --format=json <image_name>
    # command: docker scout cves --format=json <image_name>
  k8s_health:
    enabled: false
    # command: kubectl get pods --all-namespaces -o json
  terraform_drift:
    enabled: false
    # command: terraform plan -detailed-exitcode -json

observability:
  prometheus_check:
    enabled: false
    # command: promtool check rules /path/to/rules/*.yml
  alert_check:
    enabled: false
    # command: promtool check rules {repo}/monitoring/alerts/*.yml

testing:
  coverage:
    enabled: false
    # command: coverage run -m pytest {repo} && coverage json -o /dev/stdout
    # command: nyc --reporter=json npm test
    # command: go test -coverprofile=coverage.out ./...
  test_runner:
    enabled: false
    # command: pytest {repo} --tb=short -q
    # command: npm test -- --json
    # command: cargo test --message-format=json

documentation:
  link_checker:
    enabled: false
    # command: markdown-link-check {repo}/docs/**/*.md --json
  openapi_diff:
    enabled: false
    # command: oasdiff diff {repo}/docs/openapi.yaml {repo}/src/routes --format=json
```

## Tool Installation by Category

### Security

| Tool | Install | Purpose |
|------|---------|---------|
| **osv-scanner** | `go install github.com/google/osv-scanner/cmd/osv-scanner@latest` | CVE scanning (multi-ecosystem) |
| **trivy** | `brew install trivy` or `apt install trivy` | CVE + container + IaC scanning |
| **grype** | `brew install grype` or `curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \| sh` | Vulnerability scanner |
| **pip-audit** | `pip install pip-audit` | Python CVE scanning |
| **cargo audit** | `cargo install cargo-audit` | Rust CVE scanning |
| **gitleaks** | `brew install gitleaks` or `go install github.com/gitleaks/gitleaks/v8@latest` | Secret detection in git history |
| **trufflehog** | `brew install trufflehog` | Secret detection |
| **openssl** | Pre-installed on most systems | SSL certificate checking |

### Dependencies

| Tool | Install | Purpose |
|------|---------|---------|
| **npm** | Bundled with Node.js | `npm audit`, `npm outdated` |
| **pip-audit** | `pip install pip-audit` | Python dependency auditing |
| **cargo-outdated** | `cargo install cargo-outdated` | Rust dependency freshness |
| **cargo-udeps** | `cargo install cargo-udeps` | Unused Rust dependencies |
| **depcheck** | `npm install -g depcheck` | Unused Node.js dependencies |
| **vulture** | `pip install vulture` | Unused Python code/imports |
| **license-checker** | `npm install -g license-checker` | Node.js license auditing |
| **pip-licenses** | `pip install pip-licenses` | Python license auditing |
| **cargo-license** | `cargo install cargo-license` | Rust license auditing |

### Code Health

| Tool | Install | Purpose |
|------|---------|---------|
| **radon** | `pip install radon` | Python cyclomatic complexity |
| **pylint** | `pip install pylint` | Python linting |
| **mypy** | `pip install mypy` | Python type checking |
| **pyright** | `pip install pyright` or `npm install -g pyright` | Python type checking |
| **black** | `pip install black` | Python formatting check |
| **autoflake** | `pip install autoflake` | Python unused import removal |
| **pydocstyle** | `pip install pydocstyle` | Python docstring checking |
| **eslint** | `npm install -g eslint` | JavaScript/TypeScript linting |
| **prettier** | `npm install -g prettier` | JS/TS formatting check |
| **jscpd** | `npm install -g jscpd` | Copy-paste detection |
| **semgrep** | `pip install semgrep` or `brew install semgrep` | Multi-language pattern matching |
| **clippy** | Bundled with Rust toolchain | Rust linting |
| **rustfmt** | Bundled with Rust toolchain | Rust formatting |
| **gocyclo** | `go install github.com/fzipp/gocyclo/cmd/gocyclo@latest` | Go cyclomatic complexity |

### Performance

| Tool | Install | Purpose |
|------|---------|---------|
| **py-spy** | `pip install py-spy` | Python profiling |
| **valgrind** | `apt install valgrind` or `brew install valgrind` | Memory leak detection (C/C++) |
| **heaptrack** | `apt install heaptrack` | Heap profiling (Linux) |
| **cargo-bloat** | `cargo install cargo-bloat` | Rust binary size analysis |

### Database

| Tool | Install | Purpose |
|------|---------|---------|
| **pgbadger** | `apt install pgbadger` or `brew install pgbadger` | PostgreSQL log analysis |
| **psql** | Bundled with PostgreSQL | Query analysis, EXPLAIN |
| **alembic** | `pip install alembic` | Python migration status |

### Infrastructure

| Tool | Install | Purpose |
|------|---------|---------|
| **trivy** | `brew install trivy` | Container image scanning |
| **docker scout** | Docker Desktop (bundled) | Container CVE scanning |
| **kubectl** | `brew install kubectl` or `curl -LO https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/$(uname -s | tr A-Z a-z)/amd64/kubectl` | Kubernetes health checks |
| **terraform** | `brew install terraform` | Infrastructure drift detection |
| **pulumi** | `brew install pulumi` | Infrastructure drift detection |
| **skopeo** | `brew install skopeo` or `apt install skopeo` | Container registry inspection |

### Observability

| Tool | Install | Purpose |
|------|---------|---------|
| **promtool** | Bundled with Prometheus | Alert rule validation |

### Testing

| Tool | Install | Purpose |
|------|---------|---------|
| **pytest** | `pip install pytest` | Python test runner |
| **coverage** | `pip install coverage` | Python coverage |
| **nyc** | `npm install -g nyc` | Node.js coverage |

### Documentation

| Tool | Install | Purpose |
|------|---------|---------|
| **markdown-link-check** | `npm install -g markdown-link-check` | Broken link detection |
| **oasdiff** | `go install github.com/tufin/oasdiff@latest` | OpenAPI diff |

## Recommended Starter Configs

These can be generated automatically with `mt maintain init-config --detect`.

### Python project

```yaml
settings:
  log_file: tickets/maintain.log
  timeout: 60
  enabled: true

security:
  cve_scanner:
    enabled: true
    command: pip-audit --format=json
  secret_scanner:
    enabled: true
    command: gitleaks detect --source={repo} --report-format=json --no-git
deps:
  outdated_check:
    enabled: true
    command: pip list --outdated --format=json
    timeout: 120  # fetches from PyPI, may be slow
  license_check:
    enabled: true
    command: pip-licenses --format=json
code_health:
  linter:
    enabled: true
    command: pylint {repo} --output-format=json --exit-zero
  formatter_check:
    enabled: true
    command: black --check {repo} --quiet
    fix_command: black {repo}
  type_check:
    enabled: true
    command: mypy {repo} --no-error-summary
testing:
  coverage:
    enabled: true
    command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout
```

### Node.js project

```yaml
settings:
  log_file: tickets/maintain.log
  timeout: 60
  enabled: true

security:
  cve_scanner:
    enabled: true
    command: npm audit --json
deps:
  outdated_check:
    enabled: true
    command: npm outdated --json
    timeout: 120
  license_check:
    enabled: true
    command: license-checker --json
  unused_deps:
    enabled: true
    command: depcheck --json
code_health:
  linter:
    enabled: true
    command: eslint src --format=json
    fix_command: eslint src --fix
  formatter_check:
    enabled: true
    command: prettier --check 'src/**/*.{ts,tsx,js}'
    fix_command: prettier --write 'src/**/*.{ts,tsx,js}'
testing:
  test_runner:
    enabled: true
    command: npm test -- --json
  coverage:
    enabled: true
    command: nyc --reporter=json npm test
```

### Rust project

```yaml
settings:
  log_file: tickets/maintain.log
  timeout: 60
  enabled: true

security:
  cve_scanner:
    enabled: true
    command: cargo audit --json
deps:
  outdated_check:
    enabled: true
    command: cargo outdated --format=json
    timeout: 180  # fetches crate registry
  unused_deps:
    enabled: true
    command: cargo-udeps --output json
code_health:
  linter:
    enabled: true
    command: cargo clippy --message-format=json
    fix_command: cargo clippy --fix --allow-dirty
  formatter_check:
    enabled: true
    command: cargo fmt --check
    fix_command: cargo fmt
testing:
  test_runner:
    enabled: true
    command: cargo test --message-format=json
```

## Scan Log (`tickets/maintain.log`)

Every tool invocation is logged to `tickets/maintain.log` with:

```
2026-03-15T14:30:00Z  SCAN  rule=1   tool=pip-audit  status=pass  duration=2.3s
2026-03-15T14:30:02Z  SCAN  rule=21  tool=pip-list    status=fail  duration=1.1s  findings=3
2026-03-15T14:30:04Z  SCAN  rule=42  tool=built-in    status=fail  duration=0.1s  findings=6
2026-03-15T14:30:04Z  SCAN  rule=1   tool=none        status=skip  reason=no_config
```

Fields: timestamp, action, rule ID, tool name, result status, duration, finding count or skip reason.

The log file is append-only and can be used for:
- Auditing which tools ran and when
- Tracking scan duration trends
- Debugging tool failures
- Compliance reporting

## Scan Profiles

Use `--profile` for preset category groupings:

| Profile | Categories | Use case |
|---------|-----------|----------|
| `ci` | security, code-health, testing | Fast checks in CI pipelines |
| `nightly` | all 9 categories | Comprehensive nightly/weekly scans |

```bash
# CI pipeline: fast checks only
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --profile ci

# Nightly: full scan
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --profile nightly
```

## Scan Diffing

Use `--diff` to show only new findings compared to the last scan. Previous results are stored in `tickets/maintain.last.json` automatically.

```bash
# First scan (establishes baseline)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all

# Subsequent scans show only new findings
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --all --diff
```

## Auto-Fix

Tools that support automatic remediation can declare a `fix_command` in `maintain.yaml`. Use `--fix` to run them:

```bash
# Check and auto-fix formatting issues
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan --category code-health --fix
```

The fix command only runs for rules that **failed** the scan. Common `fix_command` examples:
- `black {repo}` (Python formatting)
- `cargo fmt` (Rust formatting)
- `cargo clippy --fix --allow-dirty` (Rust linting)
- `eslint src --fix` (JavaScript linting)
- `prettier --write 'src/**/*.{ts,tsx,js}'` (JavaScript formatting)

## Agent Integration

### Lightweight maintenance agent (cron)

```bash
#!/bin/bash
# Run as cron job: 0 6 * * 1  (every Monday at 6am)
cd /path/to/project
git pull

# Verify tools are available
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain doctor

# Scan all categories with configured tools (show only new findings)
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain scan \
  --all --diff --format json > /tmp/scan-results.json

# Create tickets only for verified failures
uv run python3 tickets/mt/muontickets/muontickets/mt.py maintain create --all

# Commit and push new tickets
git add tickets/
git commit -m "chore: automated maintenance scan $(date -u +%Y-%m-%d)"
git push
```

### HiggsAgent integration

```yaml
# higgsagent task definition
task: preventive-maintenance
schedule: weekly
agent_model: haiku  # use smaller model for cost efficiency
steps:
  - run: mt maintain doctor
    on_failure: notify
  - run: mt maintain scan --all --diff --format json
    save_as: scan_results
  - condition: scan_results contains "fail"
    run: mt maintain create --all
  - run: mt maintain scan --profile ci --fix
    save_as: fix_results
```
