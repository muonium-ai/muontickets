import builtins
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from muontickets import mt


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class FrontmatterParseErrorTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self, workdir: Path) -> None:
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)

    def _write_bad_ticket(self, workdir: Path) -> Path:
        ticket = workdir / "tickets" / "T-000002.md"
        ticket.write_text(
            """---
id: T-000002
title: Bad YAML
status: ready
priority: p1
type: code
effort: s
labels: [alpha, beta
tags: []
owner: null
created: 2026-05-07T00:00:00Z
updated: 2026-05-07T00:00:00Z
depends_on: []
branch: null
---

## Goal
Bad frontmatter should be reported.
""",
            encoding="utf-8",
        )
        return ticket

    def test_load_yaml_reports_pyyaml_parse_error(self) -> None:
        with self.assertRaisesRegex(ValueError, "YAML frontmatter parse error"):
            mt.load_yaml('id: T-000002\ntitle: "unterminated\n')

    def test_load_yaml_uses_tiny_parser_only_when_pyyaml_is_unavailable(self) -> None:
        real_import = builtins.__import__

        def fake_import(name: str, *args, **kwargs):
            if name == "yaml":
                raise ImportError("No module named yaml")
            return real_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=fake_import):
            parsed = mt.load_yaml("id: T-000002\nlabels: [alpha, beta]\nowner: null\n")

        self.assertEqual(parsed["labels"], ["alpha", "beta"])
        self.assertIsNone(parsed["owner"])

    def test_validate_reports_malformed_frontmatter_with_path_and_detail(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self._write_bad_ticket(workdir)

            result = self.run_cli(workdir, "validate")

            self.assertEqual(result.returncode, 1)
            self.assertIn("tickets/T-000002.md", result.stderr)
            self.assertIn("YAML frontmatter parse error", result.stderr)
            self.assertIn("line", result.stderr)
            self.assertIn("column", result.stderr)
            self.assertNotIn("field 'labels' must be an array/list", result.stderr)

    def test_ls_show_invalid_reports_malformed_frontmatter(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self._write_bad_ticket(workdir)

            result = self.run_cli(workdir, "ls", "--show-invalid")

            self.assertEqual(result.returncode, 0)
            self.assertIn("tickets/T-000002.md", result.stdout)
            self.assertIn("PARSE_ERROR", result.stdout)
            self.assertIn("YAML frontmatter parse error", result.stdout)


if __name__ == "__main__":
    unittest.main()
