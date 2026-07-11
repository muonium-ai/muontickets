import unittest
from pathlib import Path
import json
import subprocess
import shutil
import os
import tarfile
import tempfile
import tomllib
import zipfile

from muontickets.mt import load_repo_version, parse_major_minor_version


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class VersioningTests(unittest.TestCase):
    def _assert_plain_version_output(self, output: str, implementation_label: str) -> None:
        text = output.strip()
        major, minor = load_repo_version(str(ROOT))
        expected_version = f"{major}.{minor}"
        self.assertIn(implementation_label, text)
        self.assertIn(expected_version, text)

    def _get_rust_bin(self) -> str:
        rust_bin = os.environ.get("RUST_MT_BIN", "").strip()
        if rust_bin:
            return rust_bin

        default_bin = ROOT / "ports" / "rust-mt" / "target" / "release" / "mt-port"
        if default_bin.exists():
            return str(default_bin)

        if shutil.which("cargo"):
            build = subprocess.run(["cargo", "build", "--release"], cwd=str(ROOT / "ports" / "rust-mt"), capture_output=True, text=True)
            if build.returncode != 0:
                self.skipTest(f"rust build failed in test environment; skipping rust version tests\nstdout:\n{build.stdout}\nstderr:\n{build.stderr}")
            if default_bin.exists():
                return str(default_bin)

        self.skipTest("rust binary not available; set RUST_MT_BIN or install cargo")

    def _get_zig_bin(self) -> str:
        def _is_usable_zig_bin(path: str) -> bool:
            probe = subprocess.run([path, "version", "--json"], cwd=str(ROOT), capture_output=True, text=True)
            return probe.returncode == 0

        zig_bin = os.environ.get("ZIG_MT_BIN", "").strip()
        if zig_bin:
            if not _is_usable_zig_bin(zig_bin):
                self.skipTest(f"configured ZIG_MT_BIN is not usable for version command: {zig_bin}")
            return zig_bin

        default_bin = ROOT / "ports" / "zig-mt" / "zig-out" / "bin" / "mt-zig"
        if default_bin.exists() and _is_usable_zig_bin(str(default_bin)):
            return str(default_bin)

        if shutil.which("zig"):
            build = subprocess.run(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=str(ROOT / "ports" / "zig-mt"), capture_output=True, text=True)
            if build.returncode != 0:
                self.skipTest(f"zig build failed in test environment; skipping zig version tests\nstdout:\n{build.stdout}\nstderr:\n{build.stderr}")
            if default_bin.exists() and _is_usable_zig_bin(str(default_bin)):
                return str(default_bin)

        self.skipTest("zig binary not available/usable; set ZIG_MT_BIN to a compatible binary or install zig")

    def _get_c_bin(self) -> str:
        c_bin = os.environ.get("C_MT_BIN", "").strip()
        if c_bin:
            return c_bin

        default_bin = ROOT / "ports" / "c-mt" / "build" / "mt-c"
        if default_bin.exists():
            return str(default_bin)

        if shutil.which("make"):
            build = subprocess.run(["make"], cwd=str(ROOT / "ports" / "c-mt"), capture_output=True, text=True)
            if build.returncode != 0:
                self.skipTest(f"c build failed in test environment; skipping c version tests\nstdout:\n{build.stdout}\nstderr:\n{build.stderr}")
            if default_bin.exists():
                return str(default_bin)

        self.skipTest("c binary not available; set C_MT_BIN or install make + C compiler")

    def test_version_file_exists_and_is_parseable(self) -> None:
        major, minor = load_repo_version(str(ROOT))
        self.assertIsInstance(major, int)
        self.assertIsInstance(minor, int)
        self.assertGreaterEqual(major, 0)
        self.assertGreaterEqual(minor, 0)

    def test_python_package_version_is_dynamic_from_version_file(self) -> None:
        config = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
        self.assertNotIn("version", config["project"])
        self.assertIn("version", config["project"]["dynamic"])
        self.assertEqual("VERSION", config["tool"]["hatch"]["version"]["path"])

    def test_built_python_artifacts_use_repo_version(self) -> None:
        uv = shutil.which("uv")
        if not uv:
            self.skipTest("uv is required to verify Python distribution metadata")

        expected = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        with tempfile.TemporaryDirectory() as td:
            build = subprocess.run(
                [uv, "build", "--out-dir", td],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, build.returncode, f"uv build failed\nstdout:\n{build.stdout}\nstderr:\n{build.stderr}")

            wheel = next(Path(td).glob("*.whl"))
            sdist = next(Path(td).glob("*.tar.gz"))
            self.assertIn(f"-{expected}-", wheel.name)
            self.assertIn(f"-{expected}.", sdist.name)

            with zipfile.ZipFile(wheel) as archive:
                metadata_name = next(name for name in archive.namelist() if name.endswith(".dist-info/METADATA"))
                wheel_metadata = archive.read(metadata_name).decode("utf-8")
            self.assertIn(f"Version: {expected}\n", wheel_metadata)

            with tarfile.open(sdist) as archive:
                pkg_info = next(member for member in archive.getmembers() if member.name.endswith("/PKG-INFO"))
                extracted = archive.extractfile(pkg_info)
                self.assertIsNotNone(extracted)
                sdist_metadata = extracted.read().decode("utf-8")
            self.assertIn(f"Version: {expected}\n", sdist_metadata)

    def test_parse_major_minor_version_accepts_valid(self) -> None:
        self.assertEqual(parse_major_minor_version("0.1"), (0, 1))
        self.assertEqual(parse_major_minor_version("12.34\n"), (12, 34))
        self.assertEqual(parse_major_minor_version("1.2.3"), (1, 2))

    def test_parse_major_minor_version_rejects_invalid(self) -> None:
        invalid = ["", "1", "1.2.3.4", "v1.2", "1.-2", "x.y"]
        for value in invalid:
            with self.assertRaises(ValueError):
                parse_major_minor_version(value)

    def test_mt_version_json_output(self) -> None:
        proc = subprocess.run(
            [str(PYTHON), str(CLI), "version", "--json"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0)
        payload = json.loads(proc.stdout)
        self.assertEqual(payload.get("implementation"), "mt.py")
        self.assertIn("version", payload)
        self.assertIn("version_major", payload)
        self.assertIn("version_minor", payload)
        self.assertIn("build_tools", payload)
        self.assertIn("python", payload["build_tools"])

    def test_mt_global_version_invocations(self) -> None:
        for args in [[], ["-v"], ["--version"]]:
            proc = subprocess.run([str(PYTHON), str(CLI), *args], cwd=str(ROOT), capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, msg=f"args={args} stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
            self._assert_plain_version_output(proc.stdout + proc.stderr, "mt.py")

    def test_rust_version_json_output(self) -> None:
        rust_bin = self._get_rust_bin()
        proc = subprocess.run([rust_bin, "version", "--json"], cwd=str(ROOT), capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        payload = json.loads(proc.stdout)
        self.assertEqual(payload.get("implementation"), "rust-mt")
        self.assertIn("version", payload)
        self.assertIn("version_major", payload)
        self.assertIn("version_minor", payload)
        self.assertIn("build_tools", payload)
        self.assertIn("rustc", payload["build_tools"])
        self.assertIn("cargo", payload["build_tools"])

    def test_rust_global_version_invocations(self) -> None:
        rust_bin = self._get_rust_bin()
        for args in [[], ["-v"], ["--version"]]:
            proc = subprocess.run([rust_bin, *args], cwd=str(ROOT), capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, msg=f"args={args} stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
            self._assert_plain_version_output(proc.stdout + proc.stderr, "rust-mt")

    def test_zig_version_json_output(self) -> None:
        zig_bin = self._get_zig_bin()
        proc = subprocess.run([zig_bin, "version", "--json"], cwd=str(ROOT), capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        payload = json.loads(proc.stdout)
        self.assertEqual(payload.get("implementation"), "zig-mt")
        self.assertIn("version", payload)
        self.assertIn("version_major", payload)
        self.assertIn("version_minor", payload)
        self.assertIn("build_tools", payload)
        self.assertIn("zig", payload["build_tools"])

    def test_zig_global_version_invocations(self) -> None:
        zig_bin = self._get_zig_bin()
        for args in [[], ["-v"], ["--version"]]:
            proc = subprocess.run([zig_bin, *args], cwd=str(ROOT), capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, msg=f"args={args} stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
            self._assert_plain_version_output(proc.stdout + proc.stderr, "zig-mt")

    def test_c_version_json_output(self) -> None:
        c_bin = self._get_c_bin()
        proc = subprocess.run([c_bin, "version", "--json"], cwd=str(ROOT), capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        payload = json.loads(proc.stdout)
        self.assertEqual(payload.get("implementation"), "c-mt")
        self.assertIn("version", payload)
        self.assertIn("version_major", payload)
        self.assertIn("version_minor", payload)
        self.assertIn("build_tools", payload)
        self.assertIn("c_compiler", payload["build_tools"])

    def test_c_global_version_invocations(self) -> None:
        c_bin = self._get_c_bin()
        for args in [[], ["-v"], ["--version"]]:
            proc = subprocess.run([c_bin, *args], cwd=str(ROOT), capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, msg=f"args={args} stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
            self._assert_plain_version_output(proc.stdout + proc.stderr, "c-mt")


if __name__ == "__main__":
    unittest.main()
