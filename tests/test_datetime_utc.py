import datetime as dt
import re
import subprocess
import tempfile
import unittest
import warnings
from pathlib import Path
from unittest import mock

from muontickets import mt


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class DateTimeUtcTests(unittest.TestCase):
    def test_now_helpers_keep_legacy_wire_format_without_deprecation(self) -> None:
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always", DeprecationWarning)
            compact = mt.now_compact()
            iso = mt.now_utc_iso()

        self.assertEqual([], [warning for warning in caught if issubclass(warning.category, DeprecationWarning)])
        self.assertRegex(compact, r"^\d{8}T\d{6}Z$")
        self.assertRegex(iso, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_parse_utc_iso_returns_aware_utc_datetimes(self) -> None:
        parsed_z = mt.parse_utc_iso("2026-03-07T10:11:12Z")
        parsed_offset = mt.parse_utc_iso("2026-03-07T15:41:12+05:30")
        parsed_naive = mt.parse_utc_iso(dt.datetime(2026, 3, 7, 10, 11, 12))

        self.assertEqual(dt.timezone.utc, parsed_z.tzinfo)
        self.assertEqual(dt.datetime(2026, 3, 7, 10, 11, 12, tzinfo=dt.timezone.utc), parsed_z)
        self.assertEqual(dt.datetime(2026, 3, 7, 10, 11, 12, tzinfo=dt.timezone.utc), parsed_offset)
        self.assertEqual(dt.datetime(2026, 3, 7, 10, 11, 12, tzinfo=dt.timezone.utc), parsed_naive)

    def test_lease_expired_normalizes_now_to_aware_utc(self) -> None:
        meta = {"lease_expires_at": "2026-03-07T10:00:00Z"}

        self.assertFalse(mt.lease_expired(meta, now=dt.datetime(2026, 3, 7, 9, 59, 59)))
        self.assertTrue(mt.lease_expired(meta, now=dt.datetime(2026, 3, 7, 10, 0, 1, tzinfo=dt.timezone.utc)))

    def test_compute_score_uses_aware_created_timestamp_age(self) -> None:
        meta = {
            "priority": "p1",
            "effort": "s",
            "depends_on": [],
            "created": "2026-03-05T00:00:00+02:00",
        }

        frozen_now = dt.datetime(2026, 3, 7, 0, 0, 0, tzinfo=dt.timezone.utc)
        with mock.patch.object(mt, "utc_now", return_value=frozen_now):
            score = mt.compute_score(meta, {})

        self.assertEqual(232.0, score)

    def test_cli_workflow_has_no_datetime_deprecation_warning(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)

            for args in (("init",), ("new", "Aware UTC Ticket"), ("allocate-task", "--owner", "agent-a")):
                completed = subprocess.run(
                    [str(PYTHON), "-W", "error::DeprecationWarning", str(CLI), *args],
                    cwd=str(workdir),
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    0,
                    completed.returncode,
                    msg=f"command failed: {args}\nstdout={completed.stdout}\nstderr={completed.stderr}",
                )
                self.assertNotRegex(completed.stderr, re.compile(r"utcnow\(\) is deprecated", re.I))


if __name__ == "__main__":
    unittest.main()