import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class MaintainListTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self) -> Path:
        td = tempfile.mkdtemp()
        workdir = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
        return workdir

    def test_list_all_rules(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "list")
        self.assertEqual(r.returncode, 0)
        # Each rule produces 2 lines (title + detection)
        self.assertIn("CVE Dependency Vulnerability", r.stdout)
        self.assertIn("Missing Changelog", r.stdout)

    def test_list_category_filter(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "list", "--category", "docs")
        self.assertEqual(r.returncode, 0)
        self.assertIn("Outdated API Docs", r.stdout)
        self.assertNotIn("CVE Dependency", r.stdout)

    def test_list_rule_filter(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "list", "--rule", "2", "--rule", "48")
        self.assertEqual(r.returncode, 0)
        self.assertIn("Exposed Secrets", r.stdout)
        self.assertIn("Excessive TODO", r.stdout)
        self.assertNotIn("CVE Dependency", r.stdout)

    def test_list_shows_detection_heuristic(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "list", "--rule", "42")
        self.assertEqual(r.returncode, 0)
        self.assertIn("detection:", r.stdout)


class MaintainScanTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self) -> Path:
        td = tempfile.mkdtemp()
        workdir = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
        return workdir

    def test_scan_requires_filter(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "scan")
        self.assertEqual(r.returncode, 2)
        self.assertIn("required for scanning", r.stderr)

    def test_scan_pass_result(self) -> None:
        workdir = self._init_repo()
        # Rule 18: exposed .env -- no .env tracked in a fresh repo
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "18")
        self.assertEqual(r.returncode, 0)
        self.assertIn("[PASS]", r.stdout)

    def test_scan_skip_result(self) -> None:
        workdir = self._init_repo()
        # Rule 1: CVE check -- no built-in scanner
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "1")
        self.assertEqual(r.returncode, 0)
        self.assertIn("[SKIP]", r.stdout)
        self.assertIn("no built-in scanner", r.stdout)

    def test_scan_fail_result(self) -> None:
        workdir = self._init_repo()
        # Create a file with a hardcoded password to trigger rule 2/6
        src = workdir / "config.py"
        src.write_text('DB_PASSWORD = password="hunter2secret"\n', encoding="utf-8")
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "2")
        self.assertEqual(r.returncode, 1)  # exit 1 on failures
        self.assertIn("[FAIL]", r.stdout)
        self.assertIn("config.py", r.stdout)

    def test_scan_json_output(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "18", "--format", "json")
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["rule_id"], 18)
        self.assertEqual(data[0]["status"], "pass")

    def test_scan_large_file_detection(self) -> None:
        workdir = self._init_repo()
        # Create a file with >1000 lines
        big = workdir / "bigfile.py"
        big.write_text("\n".join(f"x = {i}" for i in range(1100)), encoding="utf-8")
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "42")
        self.assertEqual(r.returncode, 1)
        self.assertIn("[FAIL]", r.stdout)
        self.assertIn("bigfile.py", r.stdout)

    def test_scan_todo_density(self) -> None:
        workdir = self._init_repo()
        # Create a file with many TODOs
        code = workdir / "messy.py"
        code.write_text("\n".join(f"# TODO: fix item {i}" for i in range(15)), encoding="utf-8")
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "48")
        self.assertEqual(r.returncode, 1)
        self.assertIn("[FAIL]", r.stdout)
        self.assertIn("messy.py", r.stdout)

    def test_scan_exposed_env(self) -> None:
        workdir = self._init_repo()
        # Track a .env file in git
        env_file = workdir / ".env"
        env_file.write_text("SECRET=foo\n", encoding="utf-8")
        subprocess.run(["git", "add", ".env"], cwd=str(workdir), check=True)
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "18")
        self.assertEqual(r.returncode, 1)
        self.assertIn("[FAIL]", r.stdout)
        self.assertIn(".env", r.stdout)

    def test_scan_summary_counts(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "1", "--rule", "18")
        # rule 1: skip (no scanner), rule 18: pass (no .env)
        self.assertIn("rule(s) scanned", r.stderr)


class MaintainCreateTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self) -> Path:
        td = tempfile.mkdtemp()
        workdir = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
        return workdir

    def test_create_requires_filter(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "create")
        self.assertEqual(r.returncode, 2)
        self.assertIn("required", r.stderr)

    def test_create_skips_passing_scan(self) -> None:
        workdir = self._init_repo()
        # Rule 18 (exposed .env) should pass in a clean repo -- no ticket created
        r = self.run_cli(workdir, "maintain", "create", "--rule", "18")
        self.assertEqual(r.returncode, 0)
        self.assertIn("0 ticket(s) created", r.stderr)
        self.assertIn("1 skipped (scan passed)", r.stderr)

    def test_create_with_findings(self) -> None:
        workdir = self._init_repo()
        # Create a file with >1000 lines to trigger rule 42
        big = workdir / "bigfile.py"
        big.write_text("\n".join(f"x = {i}" for i in range(1100)), encoding="utf-8")
        r = self.run_cli(workdir, "maintain", "create", "--rule", "42")
        self.assertEqual(r.returncode, 0)
        self.assertIn("1 ticket(s) created", r.stderr)
        # Verify the ticket has findings in body
        ticket_files = sorted((workdir / "tickets").glob("T-*.md"))
        last = ticket_files[-1]
        content = last.read_text(encoding="utf-8")
        self.assertIn("## Findings", content)
        self.assertIn("bigfile.py", content)

    def test_create_dry_run(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "create", "--category", "testing", "--dry-run", "--skip-scan")
        self.assertEqual(r.returncode, 0)
        self.assertIn("[dry-run]", r.stdout)
        self.assertIn("[MAINT-131]", r.stdout)
        self.assertIn("would be created", r.stderr)

    def test_create_skip_scan(self) -> None:
        workdir = self._init_repo()
        # --skip-scan creates suggestion tickets for all rules regardless of scan
        r = self.run_cli(workdir, "maintain", "create", "--rule", "1", "--skip-scan")
        self.assertEqual(r.returncode, 0)
        self.assertIn("1 ticket(s) created", r.stderr)
        ticket_files = sorted((workdir / "tickets").glob("T-*.md"))
        last = ticket_files[-1]
        content = last.read_text(encoding="utf-8")
        self.assertIn("## Detection Heuristic", content)

    def test_create_deduplication(self) -> None:
        workdir = self._init_repo()
        r1 = self.run_cli(workdir, "maintain", "create", "--rule", "1", "--skip-scan")
        self.assertEqual(r1.returncode, 0)
        self.assertIn("1 ticket(s) created", r1.stderr)

        r2 = self.run_cli(workdir, "maintain", "create", "--rule", "1", "--skip-scan")
        self.assertEqual(r2.returncode, 0)
        self.assertIn("0 ticket(s) created, 1 skipped (duplicates)", r2.stderr)

    def test_create_priority_override(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "create", "--rule", "150", "--priority", "p0", "--skip-scan")
        self.assertEqual(r.returncode, 0)
        ticket_files = sorted((workdir / "tickets").glob("T-*.md"))
        last = ticket_files[-1]
        content = last.read_text(encoding="utf-8")
        self.assertIn("priority: p0", content)

    def test_create_owner_assignment(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "create", "--rule", "150", "--owner", "agent-maint", "--skip-scan")
        self.assertEqual(r.returncode, 0)
        ticket_files = sorted((workdir / "tickets").glob("T-*.md"))
        last = ticket_files[-1]
        content = last.read_text(encoding="utf-8")
        self.assertIn("owner: agent-maint", content)

    def test_create_labels_and_tags(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "create", "--rule", "1", "--skip-scan")
        self.assertEqual(r.returncode, 0)
        ticket_files = sorted((workdir / "tickets").glob("T-*.md"))
        last = ticket_files[-1]
        content = last.read_text(encoding="utf-8")
        self.assertIn("auto-maintenance", content)
        self.assertIn("maint-rule-1", content)
        self.assertIn("maint-cat-security", content)

    def test_validate_after_create(self) -> None:
        workdir = self._init_repo()
        self.run_cli(workdir, "maintain", "create", "--category", "testing", "--skip-scan")
        r = self.run_cli(workdir, "validate")
        self.assertEqual(r.returncode, 0)


class MaintainConfigTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self) -> Path:
        td = tempfile.mkdtemp()
        workdir = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
        return workdir

    def test_init_config_creates_file(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "init-config")
        self.assertEqual(r.returncode, 0)
        config_path = workdir / "tickets" / "maintain.yaml"
        self.assertTrue(config_path.exists())
        content = config_path.read_text(encoding="utf-8")
        self.assertIn("settings:", content)
        self.assertIn("security:", content)
        self.assertIn("enabled: false", content)

    def test_init_config_no_overwrite(self) -> None:
        workdir = self._init_repo()
        config_path = workdir / "tickets" / "maintain.yaml"
        config_path.write_text("custom: true\n", encoding="utf-8")
        r = self.run_cli(workdir, "maintain", "init-config")
        self.assertEqual(r.returncode, 1)
        self.assertIn("already exists", r.stderr)
        # Content should not be overwritten
        self.assertEqual(config_path.read_text(encoding="utf-8"), "custom: true\n")

    def test_init_config_force_overwrite(self) -> None:
        workdir = self._init_repo()
        config_path = workdir / "tickets" / "maintain.yaml"
        config_path.write_text("custom: true\n", encoding="utf-8")
        r = self.run_cli(workdir, "maintain", "init-config", "--force")
        self.assertEqual(r.returncode, 0)
        content = config_path.read_text(encoding="utf-8")
        self.assertIn("settings:", content)

    def test_scan_creates_log(self) -> None:
        workdir = self._init_repo()
        # Create config with logging enabled
        config_path = workdir / "tickets" / "maintain.yaml"
        config_path.write_text(
            "settings:\n  log_file: tickets/maintain.log\n  timeout: 60\n  enabled: true\n",
            encoding="utf-8",
        )
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "18")
        self.assertEqual(r.returncode, 0)
        log_path = workdir / "tickets" / "maintain.log"
        self.assertTrue(log_path.exists())
        log_content = log_path.read_text(encoding="utf-8")
        self.assertIn("SCAN", log_content)
        self.assertIn("rule=18", log_content)
        self.assertIn("built-in", log_content)

    def test_scan_log_appends(self) -> None:
        workdir = self._init_repo()
        config_path = workdir / "tickets" / "maintain.yaml"
        config_path.write_text(
            "settings:\n  log_file: tickets/maintain.log\n  timeout: 60\n  enabled: true\n",
            encoding="utf-8",
        )
        self.run_cli(workdir, "maintain", "scan", "--rule", "18")
        self.run_cli(workdir, "maintain", "scan", "--rule", "42")
        log_path = workdir / "tickets" / "maintain.log"
        lines = log_path.read_text(encoding="utf-8").strip().split("\n")
        self.assertEqual(len(lines), 2)

    def test_scan_external_tool_invocation(self) -> None:
        workdir = self._init_repo()
        config_path = workdir / "tickets" / "maintain.yaml"
        # Configure an external tool that always succeeds (echo)
        config_path.write_text(
            "settings:\n  log_file: tickets/maintain.log\n  timeout: 10\n  enabled: true\n"
            "security:\n  cve_scanner:\n    enabled: true\n    command: echo ok\n",
            encoding="utf-8",
        )
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "1")
        self.assertEqual(r.returncode, 0)
        self.assertIn("[PASS]", r.stdout)
        log_path = workdir / "tickets" / "maintain.log"
        log_content = log_path.read_text(encoding="utf-8")
        self.assertIn("cve_scanner", log_content)

    def test_scan_external_tool_failure(self) -> None:
        workdir = self._init_repo()
        config_path = workdir / "tickets" / "maintain.yaml"
        # Configure an external tool that always fails
        config_path.write_text(
            "settings:\n  log_file: tickets/maintain.log\n  timeout: 10\n  enabled: true\n"
            "security:\n  cve_scanner:\n    enabled: true\n    command: \"false\"\n",
            encoding="utf-8",
        )
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("[FAIL]", r.stdout)

    def test_scan_no_config_still_works(self) -> None:
        workdir = self._init_repo()
        # No maintain.yaml -- built-in scanners still work, no log created
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "18")
        self.assertEqual(r.returncode, 0)
        self.assertIn("[PASS]", r.stdout)
        log_path = workdir / "tickets" / "maintain.log"
        self.assertFalse(log_path.exists())

    def test_scan_all_flag(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "scan", "--all")
        # Should scan all 150 rules without error
        self.assertIn("rule(s) scanned", r.stderr)
        self.assertIn("150", r.stderr)

    def test_scan_profile_ci(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "scan", "--profile", "ci")
        self.assertIn("rule(s) scanned", r.stderr)
        # ci profile = security + code-health + testing = 20+20+10 = 50
        self.assertIn("50", r.stderr)

    def test_scan_profile_nightly(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "scan", "--profile", "nightly")
        self.assertIn("150", r.stderr)

    def test_scan_diff_no_previous(self) -> None:
        workdir = self._init_repo()
        # First scan with --diff should show all results (no previous scan)
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "18", "--diff")
        self.assertEqual(r.returncode, 0)
        last_scan = workdir / "tickets" / "maintain.last.json"
        self.assertTrue(last_scan.exists())

    def test_scan_diff_shows_changes(self) -> None:
        workdir = self._init_repo()
        # First scan
        self.run_cli(workdir, "maintain", "scan", "--rule", "42", "--diff")
        # Create a large file to introduce a new finding
        big = workdir / "huge.py"
        big.write_text("\n".join(f"y = {i}" for i in range(1200)), encoding="utf-8")
        # Second scan with --diff should show the new finding
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "42", "--diff")
        self.assertIn("huge.py", r.stdout)

    def test_doctor_no_config(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "doctor")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no tickets/maintain.yaml found", r.stderr)

    def test_doctor_no_tools_enabled(self) -> None:
        workdir = self._init_repo()
        self.run_cli(workdir, "maintain", "init-config")
        r = self.run_cli(workdir, "maintain", "doctor")
        self.assertEqual(r.returncode, 0)
        self.assertIn("no external tools enabled", r.stderr)

    def test_doctor_checks_tool(self) -> None:
        workdir = self._init_repo()
        config_path = workdir / "tickets" / "maintain.yaml"
        # echo is always available
        config_path.write_text(
            "settings:\n  timeout: 10\n"
            "security:\n  cve_scanner:\n    enabled: true\n    command: echo ok\n",
            encoding="utf-8",
        )
        r = self.run_cli(workdir, "maintain", "doctor")
        self.assertEqual(r.returncode, 0)
        self.assertIn("[OK]", r.stdout)
        self.assertIn("echo", r.stdout)

    def test_init_config_detect(self) -> None:
        workdir = self._init_repo()
        # Create a pyproject.toml to trigger Python detection
        (workdir / "pyproject.toml").write_text("[project]\nname = 'test'\n", encoding="utf-8")
        r = self.run_cli(workdir, "maintain", "init-config", "--detect")
        self.assertEqual(r.returncode, 0)
        config_path = workdir / "tickets" / "maintain.yaml"
        content = config_path.read_text(encoding="utf-8")
        self.assertIn("pip-audit", content)
        self.assertIn("detected stacks: python", r.stderr)

    def test_per_tool_timeout_in_config(self) -> None:
        workdir = self._init_repo()
        config_path = workdir / "tickets" / "maintain.yaml"
        # Configure a tool with a per-tool timeout (short) that will timeout
        config_path.write_text(
            "settings:\n  timeout: 60\n  log_file: tickets/maintain.log\n"
            "security:\n  cve_scanner:\n    enabled: true\n    command: sleep 5\n    timeout: 1\n",
            encoding="utf-8",
        )
        r = self.run_cli(workdir, "maintain", "scan", "--rule", "1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("[FAIL]", r.stdout)
        self.assertIn("timeout", r.stdout.lower())

    def test_create_all_flag(self) -> None:
        workdir = self._init_repo()
        r = self.run_cli(workdir, "maintain", "create", "--all", "--dry-run", "--skip-scan")
        self.assertEqual(r.returncode, 0)
        self.assertIn("150 ticket(s) would be created", r.stderr)


if __name__ == "__main__":
    unittest.main()
