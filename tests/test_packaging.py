import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PackagingConfigTests(unittest.TestCase):
    def _pyproject_text(self) -> str:
        return (ROOT / "pyproject.toml").read_text(encoding="utf-8")

    def _version_text(self) -> str:
        return (ROOT / "VERSION").read_text(encoding="utf-8").strip()

    def _copy_packaging_project(self, target: Path) -> None:
        for filename in ("pyproject.toml", "VERSION", "mt.py", "LICENSE"):
            shutil.copy2(ROOT / filename, target / filename)
        shutil.copytree(ROOT / "muontickets", target / "muontickets")

        docs = target / "docs"
        docs.mkdir()
        shutil.copy2(ROOT / "docs" / "README.md", docs / "README.md")

    def _clean_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.pop("UV_PROJECT_ENVIRONMENT", None)
        env["UV_NO_PROGRESS"] = "1"
        return env

    def test_hatch_wheel_declares_muontickets_package(self) -> None:
        text = self._pyproject_text()
        self.assertIn("[tool.hatch.build.targets.wheel]", text)
        self.assertIn('packages = ["muontickets"]', text)

    def test_hatch_sdist_includes_runtime_package_files(self) -> None:
        text = self._pyproject_text()
        self.assertIn("[tool.hatch.build.targets.sdist]", text)
        self.assertIn('"/muontickets"', text)
        self.assertIn('"/mt.py"', text)
        self.assertIn('"/docs/README.md"', text)

    def test_project_declares_mt_console_script_entrypoint(self) -> None:
        text = self._pyproject_text()
        self.assertIn("[project.scripts]", text)
        self.assertIn('mt = "muontickets.mt:main"', text)

    def test_installed_package_metadata_version_matches_version_file(self) -> None:
        uv = shutil.which("uv")
        if uv is None:
            self.skipTest("uv is required to verify installed package metadata")

        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            self._copy_packaging_project(project)
            proc = subprocess.run(
                [
                    uv,
                    "run",
                    "python",
                    "-c",
                    (
                        "from importlib.metadata import version; "
                        "print(version('muontickets'))"
                    ),
                ],
                cwd=str(project),
                env=self._clean_env(),
                capture_output=True,
                text=True,
            )

        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertEqual(proc.stdout.strip(), self._version_text())

    def test_uv_mt_entrypoint_reports_same_version_as_python_cli(self) -> None:
        uv = shutil.which("uv")
        python = shutil.which("python3")
        if uv is None:
            self.skipTest("uv is required to verify the console entrypoint")
        if python is None:
            self.skipTest("python3 is required to verify CLI parity")

        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            self._copy_packaging_project(project)
            env = self._clean_env()
            uv_proc = subprocess.run(
                [uv, "run", "mt", "version"],
                cwd=str(project),
                env=env,
                capture_output=True,
                text=True,
            )
            python_proc = subprocess.run(
                [python, "mt.py", "version"],
                cwd=str(project),
                env=env,
                capture_output=True,
                text=True,
            )

        self.assertEqual(uv_proc.returncode, 0, msg=f"stdout:\n{uv_proc.stdout}\nstderr:\n{uv_proc.stderr}")
        self.assertEqual(
            python_proc.returncode,
            0,
            msg=f"stdout:\n{python_proc.stdout}\nstderr:\n{python_proc.stderr}",
        )
        self.assertEqual(uv_proc.stdout.splitlines()[0], python_proc.stdout.splitlines()[0])
        self.assertEqual(uv_proc.stdout.splitlines()[0], f"mt.py {self._version_text()}")


if __name__ == "__main__":
    unittest.main()
