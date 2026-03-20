import subprocess
import unittest
import shutil
import os
import tempfile
import textwrap
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYTHON = ROOT / ".venv" / "bin" / "python"
MT_CLI = ROOT / "mt.py"
RUNNER = ROOT / "tests" / "conformance" / "runner.py"
FIXTURES = ROOT / "tests" / "conformance" / "fixtures"


class ConformanceRunnerTests(unittest.TestCase):
    def get_c_bin(self) -> str:
        c_bin = os.environ.get("C_MT_BIN", "").strip()
        if c_bin:
            return c_bin

        default_bin = ROOT / "ports" / "c-mt" / "build" / "mt-c"
        if default_bin.exists():
            return str(default_bin)

        if shutil.which("make"):
            build = subprocess.run(
                ["make"],
                cwd=str(ROOT / "ports" / "c-mt"),
                capture_output=True,
                text=True,
            )
            if build.returncode != 0:
                self.skipTest(f"c build failed in test environment; skipping c conformance tests\nstdout:\n{build.stdout}\nstderr:\n{build.stderr}")
            if default_bin.exists():
                return str(default_bin)

        self.skipTest("c binary not available; set C_MT_BIN or install make + C compiler")

    def get_rust_bin(self) -> str:
        rust_bin = os.environ.get("RUST_MT_BIN", "").strip()
        if rust_bin:
            return rust_bin

        default_bin = ROOT / "ports" / "rust-mt" / "target" / "debug" / "mt-port"
        if default_bin.exists():
            return str(default_bin)

        if shutil.which("cargo"):
            build = subprocess.run(
                ["cargo", "build"],
                cwd=str(ROOT / "ports" / "rust-mt"),
                capture_output=True,
                text=True,
            )
            if build.returncode != 0:
                self.skipTest(f"rust build failed in test environment; skipping rust conformance tests\nstdout:\n{build.stdout}\nstderr:\n{build.stderr}")
            if default_bin.exists():
                return str(default_bin)

        self.skipTest("rust binary not available; set RUST_MT_BIN or install cargo")

    def get_zig_bin(self) -> str:
        zig_bin = os.environ.get("ZIG_MT_BIN", "").strip()
        if zig_bin:
            return zig_bin

        default_bin = ROOT / "ports" / "zig-mt" / "zig-out" / "bin" / "mt-zig"
        if default_bin.exists():
            return str(default_bin)

        if shutil.which("zig"):
            build = subprocess.run(
                ["zig", "build"],
                cwd=str(ROOT / "ports" / "zig-mt"),
                capture_output=True,
                text=True,
            )
            if build.returncode != 0:
                self.skipTest(f"zig build failed in test environment; skipping zig conformance tests\nstdout:\n{build.stdout}\nstderr:\n{build.stderr}")
            if default_bin.exists():
                return str(default_bin)

        self.skipTest("zig binary not available; set ZIG_MT_BIN or install zig")

    def run_fixture(self, fixture_name: str) -> subprocess.CompletedProcess[str]:
        fixture = FIXTURES / fixture_name
        env = dict(**__import__("os").environ)
        env["MT_CMD"] = f"{PYTHON} {MT_CLI}"
        return subprocess.run(
            [str(PYTHON), str(RUNNER), "--fixture", str(fixture)],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
        )

    def run_fixture_with_cmd(self, fixture_name: str, mt_cmd: str) -> subprocess.CompletedProcess[str]:
        fixture = FIXTURES / fixture_name
        env = dict(**__import__("os").environ)
        env["MT_CMD"] = mt_cmd
        return subprocess.run(
            [str(PYTHON), str(RUNNER), "--fixture", str(fixture)],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
        )

    def test_core_workflow_fixture(self) -> None:
        proc = self.run_fixture("core_workflow.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_reporting_graph_pick_fixture(self) -> None:
        proc = self.run_fixture("reporting_graph_pick.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_options_parity_fixture(self) -> None:
        proc = self.run_fixture("options_parity.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_pick_scoring_fixture(self) -> None:
        proc = self.run_fixture("pick_scoring.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_queue_allocate_fail_fixture(self) -> None:
        proc = self.run_fixture("queue_allocate_fail.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_core_workflow_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

        proc = self.run_fixture_with_cmd("core_workflow.json", zig_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_reporting_graph_pick_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

        proc = self.run_fixture_with_cmd("zig_reporting_graph_pick.json", zig_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_options_parity_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

        proc = self.run_fixture_with_cmd("options_parity.json", zig_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_pick_scoring_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

        proc = self.run_fixture_with_cmd("pick_scoring.json", zig_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_queue_allocate_fail_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

        proc = self.run_fixture_with_cmd("queue_allocate_fail.json", zig_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_rust_core_workflow_fixture(self) -> None:
        rust_bin = self.get_rust_bin()

        proc = self.run_fixture_with_cmd("core_workflow.json", rust_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_rust_reporting_graph_pick_fixture(self) -> None:
        rust_bin = self.get_rust_bin()

        proc = self.run_fixture_with_cmd("reporting_graph_pick.json", rust_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_rust_options_parity_fixture(self) -> None:
        rust_bin = self.get_rust_bin()

        proc = self.run_fixture_with_cmd("options_parity.json", rust_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_rust_pick_scoring_fixture(self) -> None:
        rust_bin = self.get_rust_bin()

        proc = self.run_fixture_with_cmd("pick_scoring.json", rust_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_rust_queue_allocate_fail_fixture(self) -> None:
        rust_bin = self.get_rust_bin()

        proc = self.run_fixture_with_cmd("queue_allocate_fail.json", rust_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_c_core_workflow_fixture(self) -> None:
        c_bin = self.get_c_bin()

        proc = self.run_fixture_with_cmd("core_workflow.json", c_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_c_reporting_graph_pick_fixture(self) -> None:
        c_bin = self.get_c_bin()

        proc = self.run_fixture_with_cmd("reporting_graph_pick.json", c_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_c_options_parity_fixture(self) -> None:
        c_bin = self.get_c_bin()

        proc = self.run_fixture_with_cmd("options_parity.json", c_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_c_pick_scoring_fixture(self) -> None:
        c_bin = self.get_c_bin()

        proc = self.run_fixture_with_cmd("pick_scoring.json", c_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_c_queue_allocate_fail_fixture(self) -> None:
        c_bin = self.get_c_bin()

        proc = self.run_fixture_with_cmd("queue_allocate_fail.json", c_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    # --- maintain_parity fixture tests ---

    def test_maintain_parity_fixture(self) -> None:
        proc = self.run_fixture("maintain_parity.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_maintain_parity_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

        proc = self.run_fixture_with_cmd("maintain_parity.json", zig_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_rust_maintain_parity_fixture(self) -> None:
        rust_bin = self.get_rust_bin()

        proc = self.run_fixture_with_cmd("maintain_parity.json", rust_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_c_maintain_parity_fixture(self) -> None:
        c_bin = self.get_c_bin()

        proc = self.run_fixture_with_cmd("maintain_parity.json", c_bin)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_c_native_init_bootstrap_and_state_sync(self) -> None:
        c_bin = self.get_c_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)

            init_first = subprocess.run([c_bin, "init"], cwd=str(root), capture_output=True, text=True)
            self.assertEqual(init_first.returncode, 0, msg=f"stdout:\n{init_first.stdout}\nstderr:\n{init_first.stderr}")
            out1 = init_first.stdout + init_first.stderr
            self.assertIn("created", out1)
            self.assertTrue((root / "tickets" / "ticket.template").exists())
            self.assertTrue((root / "tickets" / "T-000001.md").exists())
            self.assertIn("T-000001", (root / "tickets" / "last_ticket_id").read_text(encoding="utf-8"))

            archive = root / "tickets" / "archive"
            archive.mkdir(parents=True, exist_ok=True)
            (archive / "T-000123.md").write_text("---\nid: T-000123\n---\n", encoding="utf-8")

            init_second = subprocess.run([c_bin, "init"], cwd=str(root), capture_output=True, text=True)
            self.assertEqual(init_second.returncode, 0, msg=f"stdout:\n{init_second.stdout}\nstderr:\n{init_second.stderr}")
            self.assertIn("updated", init_second.stdout + init_second.stderr)
            self.assertIn("T-000123", (root / "tickets" / "last_ticket_id").read_text(encoding="utf-8"))

    def test_c_native_new_template_defaults_and_overrides(self) -> None:
        c_bin = self.get_c_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)
            subprocess.run([c_bin, "init"], cwd=str(root), check=True, capture_output=True, text=True)

            template = textwrap.dedent(
                """\
                ---
                id: T-000000
                title: Template: replace title
                status: blocked
                priority: p0
                type: docs
                effort: l
                labels: [alpha, beta]
                tags: [tmpl]
                owner: agent-x
                created: 1970-01-01T00:00:00Z
                updated: 1970-01-01T00:00:00Z
                depends_on: [T-000123]
                branch: feat/template-defaults
                retry_count: 0
                retry_limit: 3
                allocated_to: null
                allocated_at: null
                lease_expires_at: null
                last_error: null
                last_attempted_at: null
                ---

                ## Goal
                Template goal body.

                ## Acceptance Criteria
                - [ ] Template AC

                ## Notes
                """
            )
            (root / "tickets" / "ticket.template").write_text(template, encoding="utf-8")

            created = subprocess.run(
                [c_bin, "new", "From Template", "--label", "cli", "--depends-on", "T-000001", "--goal", "Goal override"],
                cwd=str(root),
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("T-000002.md", created.stdout + created.stderr)

            shown = subprocess.run([c_bin, "show", "T-000002"], cwd=str(root), check=True, capture_output=True, text=True)
            text = shown.stdout + shown.stderr
            self.assertIn("status: blocked", text)
            self.assertIn("priority: p0", text)
            self.assertIn("type: docs", text)
            self.assertIn("effort: l", text)
            self.assertTrue("labels: [cli]" in text or "- cli" in text)
            self.assertTrue("tags: [tmpl]" in text or "- tmpl" in text)
            self.assertTrue("depends_on: [T-000001]" in text or "- T-000001" in text)
            self.assertIn("owner: agent-x", text)
            self.assertIn("branch: feat/template-defaults", text)
            self.assertIn("Goal override", text)

    def test_c_native_show_without_python_entrypoint(self) -> None:
        c_bin = self.get_c_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)

            env = dict(os.environ)
            env["MT_PY_ENTRY"] = str(root / "missing-mt.py")

            init_proc = subprocess.run([c_bin, "init"], cwd=str(root), env=env, capture_output=True, text=True)
            self.assertEqual(init_proc.returncode, 0, msg=f"stdout:\n{init_proc.stdout}\nstderr:\n{init_proc.stderr}")

            new_proc = subprocess.run([c_bin, "new", "Native Show Ticket"], cwd=str(root), env=env, capture_output=True, text=True)
            self.assertEqual(new_proc.returncode, 0, msg=f"stdout:\n{new_proc.stdout}\nstderr:\n{new_proc.stderr}")
            self.assertIn("T-000002.md", new_proc.stdout + new_proc.stderr)

            show_proc = subprocess.run([c_bin, "show", "T-000002"], cwd=str(root), env=env, capture_output=True, text=True)
            self.assertEqual(show_proc.returncode, 0, msg=f"stdout:\n{show_proc.stdout}\nstderr:\n{show_proc.stderr}")
            text = show_proc.stdout + show_proc.stderr
            self.assertIn("id: T-000002", text)
            self.assertIn("title: Native Show Ticket", text)

    def test_c_show_output_matches_python_exact(self) -> None:
        c_bin = self.get_c_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)

            subprocess.run([c_bin, "init"], cwd=str(root), check=True, capture_output=True, text=True)
            subprocess.run([c_bin, "new", "Parity Show"], cwd=str(root), check=True, capture_output=True, text=True)

            py_show = subprocess.run(
                [str(PYTHON), str(MT_CLI), "show", "T-000002"],
                cwd=str(root),
                check=True,
                capture_output=True,
                text=True,
            )
            c_show = subprocess.run(
                [c_bin, "show", "T-000002"],
                cwd=str(root),
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(c_show.stdout.rstrip("\n"), py_show.stdout.rstrip("\n"))
            self.assertEqual(c_show.stderr, py_show.stderr)

    def test_c_no_args_outside_repo_matches_python(self) -> None:
        c_bin = self.get_c_bin()
        env = dict(os.environ)
        env["MT_PYTHON"] = str(PYTHON)

        with tempfile.TemporaryDirectory() as td:
            temp_root = Path(td)

            py_proc = subprocess.run(
                [str(PYTHON), str(MT_CLI)],
                cwd=str(temp_root),
                capture_output=True,
                text=True,
            )
            c_proc = subprocess.run(
                [c_bin],
                cwd=str(temp_root),
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertEqual(c_proc.returncode, py_proc.returncode)
            self.assertEqual(c_proc.stderr, py_proc.stderr)
            self.assertEqual(c_proc.stdout, py_proc.stdout)

    def test_c_native_perf_commands_without_python_entrypoint(self) -> None:
        c_bin = self.get_c_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)

            env = dict(os.environ)
            env["MT_PY_ENTRY"] = str(root / "missing-mt.py")

            self.assertEqual(subprocess.run([c_bin, "init"], cwd=str(root), env=env, capture_output=True, text=True).returncode, 0)
            self.assertEqual(subprocess.run([c_bin, "new", "Perf Native"], cwd=str(root), env=env, capture_output=True, text=True).returncode, 0)

            commented = subprocess.run([c_bin, "comment", "T-000002", "perf-update"], cwd=str(root), env=env, capture_output=True, text=True)
            self.assertEqual(commented.returncode, 0, msg=f"stdout:\n{commented.stdout}\nstderr:\n{commented.stderr}")
            self.assertIn("commented on T-000002", commented.stdout + commented.stderr)

            done = subprocess.run([c_bin, "done", "T-000002", "--force"], cwd=str(root), env=env, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, msg=f"stdout:\n{done.stdout}\nstderr:\n{done.stderr}")
            self.assertIn("done T-000002", done.stdout + done.stderr)

            archived = subprocess.run([c_bin, "archive", "T-000002", "--force"], cwd=str(root), env=env, capture_output=True, text=True)
            self.assertEqual(archived.returncode, 0, msg=f"stdout:\n{archived.stdout}\nstderr:\n{archived.stderr}")
            self.assertIn("archived T-000002 -> tickets/archive/T-000002.md", archived.stdout + archived.stderr)
            self.assertTrue((root / "tickets" / "archive" / "T-000002.md").exists())

    def test_zig_new_uses_template_defaults(self) -> None:
        zig_bin = self.get_zig_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)
            subprocess.run([zig_bin, "init"], cwd=str(root), check=True, capture_output=True, text=True)

            template = textwrap.dedent(
                """\
                ---
                id: T-000000
                title: Template: replace title
                status: blocked
                priority: p0
                type: docs
                effort: l
                labels: [alpha, beta]
                tags: [zig, template]
                owner: agent-x
                created: 1970-01-01
                updated: 1970-01-01
                depends_on: [T-000123]
                branch: feat/template-defaults
                ---

                ## Goal
                Template goal body.

                ## Acceptance Criteria
                - [ ] Template AC

                ## Notes
                Template notes.
                """
            )
            (root / "tickets" / "ticket.template").write_text(template, encoding="utf-8")

            subprocess.run([zig_bin, "new", "From Template"], cwd=str(root), check=True, capture_output=True, text=True)
            shown = subprocess.run([zig_bin, "show", "T-000002"], cwd=str(root), check=True, capture_output=True, text=True)
            text = shown.stdout + shown.stderr

            self.assertIn("status: blocked", text)
            self.assertIn("priority: p0", text)
            self.assertIn("type: docs", text)
            self.assertIn("effort: l", text)
            self.assertIn("labels: [alpha, beta]", text)
            self.assertIn("tags: [zig, template]", text)
            self.assertIn("owner: agent-x", text)
            self.assertIn("depends_on: [T-000123]", text)
            self.assertIn("branch: feat/template-defaults", text)
            self.assertIn("Template goal body.", text)

    def test_zig_ls_show_invalid_and_validate_parse_error(self) -> None:
        zig_bin = self.get_zig_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)
            subprocess.run([zig_bin, "init"], cwd=str(root), check=True, capture_output=True, text=True)

            bad_ticket = root / "tickets" / "T-999999.md"
            bad_ticket.write_text("id: T-999999\ntitle: bad\n", encoding="utf-8")

            shown = subprocess.run([zig_bin, "ls", "--show-invalid"], cwd=str(root), check=True, capture_output=True, text=True)
            out = shown.stdout + shown.stderr
            self.assertIn("T-999999.md", out)
            self.assertIn("PARSE_ERROR", out)

            validated = subprocess.run([zig_bin, "validate"], cwd=str(root), capture_output=True, text=True)
            self.assertEqual(validated.returncode, 1, msg=f"stdout:\n{validated.stdout}\nstderr:\n{validated.stderr}")
            vout = validated.stdout + validated.stderr
            self.assertIn("Missing YAML frontmatter", vout)

    def test_zig_export_payload_shape(self) -> None:
        zig_bin = self.get_zig_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)
            subprocess.run([zig_bin, "init"], cwd=str(root), check=True, capture_output=True, text=True)
            subprocess.run(
                [
                    zig_bin,
                    "new",
                    "Payload Ticket",
                    "--label",
                    "alpha",
                    "--tag",
                    "beta",
                    "--depends-on",
                    "T-000001",
                ],
                cwd=str(root),
                check=True,
                capture_output=True,
                text=True,
            )

            exported = subprocess.run([zig_bin, "export", "--format", "json"], cwd=str(root), check=True, capture_output=True, text=True)
            payload_text = (exported.stdout + exported.stderr).strip()
            rows = json.loads(payload_text)
            row = next(r for r in rows if r.get("id") == "T-000002")
            for key in ["labels", "tags", "owner", "created", "updated", "depends_on", "branch", "excerpt", "path"]:
                self.assertIn(key, row)
            self.assertEqual(row["labels"], ["alpha"])
            self.assertEqual(row["tags"], ["beta"])
            self.assertEqual(row["depends_on"], ["T-000001"])
            self.assertEqual(row["path"], "tickets/T-000002.md")

    def test_zig_validate_updated_before_created(self) -> None:
        zig_bin = self.get_zig_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)
            subprocess.run([zig_bin, "init"], cwd=str(root), check=True, capture_output=True, text=True)

            t1 = root / "tickets" / "T-000001.md"
            lines = t1.read_text(encoding="utf-8").splitlines()
            rewritten = []
            for line in lines:
                if line.startswith("created:"):
                    rewritten.append("created: 1970-01-02")
                elif line.startswith("updated:"):
                    rewritten.append("updated: 1970-01-01")
                else:
                    rewritten.append(line)
            t1.write_text("\n".join(rewritten) + "\n", encoding="utf-8")

            validated = subprocess.run([zig_bin, "validate"], cwd=str(root), capture_output=True, text=True)
            self.assertEqual(validated.returncode, 1, msg=f"stdout:\n{validated.stdout}\nstderr:\n{validated.stderr}")
            vout = validated.stdout + validated.stderr
            self.assertIn("updated (1970-01-01) is earlier than created (1970-01-02)", vout)


if __name__ == "__main__":
    unittest.main()
