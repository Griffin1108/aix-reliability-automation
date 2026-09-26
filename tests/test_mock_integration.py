"""Run the real health engine with mocks in an isolated temporary project."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_compare_aix_health import ROOT, compare


def find_bash():
    explicit = os.environ.get("AIX_TEST_BASH")
    if explicit:
        return explicit
    git_bash = Path("C:/Program Files/Git/bin/bash.exe")
    if os.name == "nt" and git_bash.is_file():
        return str(git_bash)
    return shutil.which("bash")


class MockIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = find_bash()
        if not cls.bash:
            raise unittest.SkipTest("Bash unavailable; set AIX_TEST_BASH to run mock integration tests")
        cls.temp = tempfile.TemporaryDirectory(prefix="aix-health-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.project = Path(cls.temp.name)
        (cls.project / "scripts").mkdir()
        source = (ROOT / "scripts/aix_healthcheck.sh").read_text(encoding="utf-8")
        with (cls.project / "scripts/aix_healthcheck.sh").open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(source)
        cls.env = os.environ.copy()
        # Tests must not depend on user-specific threshold or collector overrides.
        for name in re.findall(r'^([A-Z_]+)="\$\{', source, re.MULTILINE):
            cls.env.pop(name, None)
        cls.env["LC_ALL"] = "C"
        if os.name == "nt":
            cls.env["PATH"] = str(Path(cls.bash).parent.parent / "usr/bin") + os.pathsep + cls.env.get("PATH", "")
        cls.captures = {}
        for profile in ("healthy", "degraded"):
            for label in ("precheck", "postcheck"):
                result, data = cls.capture(profile, label)
                expected = 0 if profile == "healthy" else 2
                if result.returncode != expected or data is None:
                    raise AssertionError("{} {}: rc={}\n{}\n{}".format(profile, label, result.returncode, result.stdout, result.stderr))
                cls.captures[profile, label] = data

    @classmethod
    def capture(cls, profile, label, **overrides):
        env = dict(cls.env, MOCK_MODE="1", MOCK_PROFILE=profile, CHECK_TYPE=label)
        env.update(overrides)
        result = subprocess.run([cls.bash, "scripts/aix_healthcheck.sh"], cwd=cls.project,
                                env=env, text=True, capture_output=True, timeout=60)
        files = list((cls.project / "reports").glob("*_{}.summary".format(label)))
        data = compare.read_summary(max(files, key=lambda path: path.stat().st_mtime_ns)) if files else None
        return result, data

    def pair(self, before, after):
        old = dict(self.captures[before, "precheck"])
        new = dict(self.captures[after, "postcheck"])
        # Scenario order is independent of fixture collection order.
        old["TIMESTAMP"] = "20260926_120000"
        new["TIMESTAMP"] = "20260926_120100"
        return compare.compare_summaries(old, new)

    def test_generated_summary_schema_and_metrics(self):
        healthy = self.captures["healthy", "precheck"]
        degraded = self.captures["degraded", "postcheck"]
        self.assertEqual(set(healthy), compare.REQUIRED_KEYS)
        self.assertEqual(healthy["HOST"], "mock-aix01")
        self.assertEqual(healthy["HOST"], degraded["HOST"])
        self.assertEqual(healthy["OVERALL_CODE"], "0")
        self.assertEqual(degraded["OVERALL_CODE"], "2")
        for key, old, new in (("CPU_BUSY_PERCENT", "15", "92"), ("FAILED_MPIO_PATHS", "0", "3"),
                              ("PAGING_USED_PERCENT", "3", "88"), ("MAX_DISK_BUSY_PERCENT", "22.0", "96.0")):
            self.assertEqual(float(healthy[key]), float(old))
            self.assertEqual(float(degraded[key]), float(new))

    def test_all_four_scenarios(self):
        for old, new, outcome, code in (("healthy", "healthy", "UNCHANGED", 0),
                                        ("degraded", "degraded", "UNCHANGED", 1),
                                        ("degraded", "healthy", "IMPROVED", 0),
                                        ("healthy", "degraded", "REGRESSED", 2)):
            with self.subTest(before=old, after=new):
                report = self.pair(old, new)
                self.assertEqual((report["outcome"], report["exit_code"]), (outcome, code))

    def test_custom_hostname_is_consistent_in_report_and_summary(self):
        for profile in ("healthy", "degraded"):
            result, data = self.capture(profile, "custom-" + profile, MOCK_HOSTNAME="aix-test01")
            self.assertEqual(data["HOST"], "aix-test01")
            self.assertIn("Node Name                                  : aix-test01", result.stdout)
            self.assertIn("Node aix-test01: UP", result.stdout)
            self.assertIn("aix-test01_", result.stdout)

    def test_optional_collectors(self):
        for profile, code in (("healthy", 0), ("degraded", 2)):
            result, data = self.capture(profile, "options-" + profile,
                                        REQUIRED_ADAPTERS="fcs0 fcs1", EXPECTED_ACTIVE_VGS="rootvg datavg",
                                        REQUIRE_NTP="1", POWERHA_REQUIRED="1", PING_GATEWAY="1",
                                        DNS_TEST_HOST="example.test", COLLECT_FCSTAT="1", ERRPT_ENFORCE_ALL="1")
            self.assertEqual(result.returncode, code)
            self.assertEqual(data["NETWORK_STATUS"], "OK" if profile == "healthy" else "CRITICAL")
            self.assertEqual(data["ERRPT_STATUS"], "OK" if profile == "healthy" else "CRITICAL")
            self.assertIn("FIBRE CHANNEL STATISTICS REPORT", result.stdout)

    def test_invalid_mock_configuration(self):
        for index, overrides in enumerate(({"MOCK_PROFILE": "typo"}, {"MOCK_HOSTNAME": "../escape"},
                                           {"MOCK_HOSTNAME": "bad host"}, {"MOCK_HOSTNAME": "-bad"},
                                           {"MOCK_HOSTNAME": "bad-"}, {"MOCK_HOSTNAME": "x" * 64},
                                           {"MOCK_MODE": "typo"}, {"MOCK_MODE": "2"},
                                           {"CHECK_TYPE": "../escape"}, {"CHECK_TYPE": "bad label"},
                                           {"CHECK_TYPE": "x" * 129})):
            with self.subTest(overrides=overrides):
                result, data = self.capture("healthy", "invalid-{}".format(index), **overrides)
                self.assertEqual(result.returncode, 3)
                self.assertIsNone(data)
                self.assertIn("ERROR:", result.stderr)

    @unittest.skipIf(os.uname().sysname == "AIX" if hasattr(os, "uname") else False, "requires non-AIX host")
    def test_unsupported_real_mode_cannot_write_ok_summary(self):
        result, data = self.capture("healthy", "unsupported", MOCK_MODE="0")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(data["OVERALL_STATUS"], "UNKNOWN")
        self.assertEqual(data["OVERALL_CODE"], "3")
        self.assertTrue(all(data[key] == "UNKNOWN" for key in compare.STATUS_KEYS))
        self.assertEqual(data["POWERHA_STATE"], "UNKNOWN")
        self.assertEqual(data["AIX_LEVEL"], "")
        self.assertIn("UNKNOWN - no checks executed", result.stdout)
        self.assertNotIn(": OK", result.stdout)
        report = next((self.project / "reports").glob("*_unsupported.txt")).read_text(encoding="utf-8")
        self.assertIn("UNKNOWN - no checks executed", report)
        self.assertNotIn(": OK", report)

    def frozen_command(self):
        # Freeze time only in the test process, without a production timestamp override.
        return [self.bash, "-c", "date() { printf '%s\\n' 20260926_120000; }; export -f date; exec bash scripts/aix_healthcheck.sh"]

    def test_preexisting_report_or_summary_is_never_overwritten(self):
        for suffix in ("txt", "summary"):
            with self.subTest(suffix=suffix):
                label = "collision-" + suffix
                base = self.project / "reports" / ("mock-aix01_20260926_120000_" + label)
                existing = base.with_suffix("." + suffix)
                sentinel = b"Retained evidence: do not overwrite\n"
                existing.write_bytes(sentinel)
                result = subprocess.run(self.frozen_command(), cwd=self.project,
                                        env=dict(self.env, MOCK_MODE="1", CHECK_TYPE=label),
                                        text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("already exists", result.stderr)
                self.assertEqual(existing.read_bytes(), sentinel)
                other = base.with_suffix(".summary" if suffix == "txt" else ".txt")
                self.assertFalse(other.exists())

    def test_concurrent_and_repeated_same_second_captures_preserve_evidence(self):
        env = dict(self.env, MOCK_MODE="1", MOCK_PROFILE="healthy", CHECK_TYPE="concurrent")
        processes = []
        try:
            for _ in range(2):
                processes.append(subprocess.Popen(self.frozen_command(), cwd=self.project, env=env,
                                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            outputs = [process.communicate(timeout=60) for process in processes]
            self.assertEqual(sorted(process.returncode for process in processes), [0, 3], outputs)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        files = list((self.project / "reports").glob("*_concurrent.*"))
        self.assertEqual(len(files), 2)
        evidence = {path: path.read_bytes() for path in files}
        summary = next(path for path in files if path.suffix == ".summary")
        self.assertEqual(compare.read_summary(summary)["OVERALL_STATUS"], "OK")
        repeat = subprocess.run(self.frozen_command(), cwd=self.project, env=env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(repeat.returncode, 3)
        self.assertIn("already exists", repeat.stderr)
        self.assertEqual({path: path.read_bytes() for path in files}, evidence)

    def test_bash_syntax(self):
        result = subprocess.run([self.bash, "-n", "scripts/aix_healthcheck.sh"], cwd=self.project,
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
