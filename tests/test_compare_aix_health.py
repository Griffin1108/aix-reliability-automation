"""Standard-library unit and CLI contract tests; no AIX host required."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import compare_aix_health as compare


def snapshot(**changes):
    data = {key: "OK" for key in compare.STATUS_KEYS}
    data.update({key: "0" for key in compare.METRIC_KEYS})
    data.update(HOST="mock-aix01", CHECK_TYPE="healthcheck", TIMESTAMP="20260926_120000",
                AIX_LEVEL="7200-05-11-2546", POWERHA_STATE="STABLE", VCPU="4",
                OVERALL_STATUS="OK", OVERALL_CODE="0")
    data.update(changes)
    worst = max(compare.SEVERITY[data[key]] for key in compare.STATUS_KEYS)
    data["OVERALL_STATUS"] = tuple(compare.SEVERITY)[worst]
    data["OVERALL_CODE"] = str(worst)
    return data


def write_summary(path, data):
    path.write_text("".join("{}={}\n".format(key, value) for key, value in data.items()), encoding="utf-8")


class ComparisonTests(unittest.TestCase):
    def test_healthy_unchanged(self):
        report = compare.compare_summaries(snapshot(), snapshot())
        self.assertEqual((report["outcome"], report["exit_code"]), ("UNCHANGED", 0))

    def test_degraded_unchanged_requires_review(self):
        data = snapshot(SERVICE_STATUS="CRITICAL")
        report = compare.compare_summaries(data, data)
        self.assertEqual((report["outcome"], report["exit_code"]), ("UNCHANGED", 1))
        self.assertEqual(report["regressions"], [])
        self.assertEqual(report["unresolved_baseline"], [
            {"key": "SERVICE_STATUS", "before": "CRITICAL", "after": "CRITICAL", "change": "UNCHANGED"}])
        text = compare.render_text(report)
        self.assertIn("New or worsened degradation: none detected", text)
        self.assertIn("Unresolved baseline problems: 1", text)
        self.assertIn("SERVICE_STATUS: CRITICAL -> CRITICAL", text)

    def test_regressed(self):
        report = compare.compare_summaries(snapshot(), snapshot(SERVICE_STATUS="CRITICAL"))
        self.assertEqual((report["outcome"], report["exit_code"]), ("REGRESSED", 2))
        self.assertEqual(report["regressions"], ["SERVICE_STATUS"])

    def test_improved_to_healthy(self):
        report = compare.compare_summaries(snapshot(POWERHA_STATUS="CRITICAL", POWERHA_STATE="ERROR"), snapshot())
        self.assertEqual((report["outcome"], report["exit_code"]), ("IMPROVED", 0))

    def test_improved_with_residual_warning(self):
        report = compare.compare_summaries(snapshot(SERVICE_STATUS="CRITICAL"), snapshot(SERVICE_STATUS="WARNING"))
        self.assertEqual((report["outcome"], report["exit_code"]), ("IMPROVED", 1))

    def test_mixed_changes_and_unchanged_overall_do_not_mask_regression(self):
        report = compare.compare_summaries(snapshot(SERVICE_STATUS="CRITICAL", OS_STATUS="CRITICAL"),
                                           snapshot(SERVICE_STATUS="OK", OS_STATUS="CRITICAL", PAGING_STATUS="WARNING"))
        self.assertEqual(report["before_overall"], report["after_overall"])
        self.assertEqual(report["exit_code"], 2)
        self.assertIn("SERVICE_STATUS", report["improvements"])
        self.assertIn("PAGING_STATUS", report["regressions"])
        self.assertEqual([row["key"] for row in report["unresolved_baseline"]], ["OS_STATUS"])

    def test_overall_is_not_evaluated_as_an_individual_component(self):
        report = compare.compare_summaries(snapshot(), snapshot(SERVICE_STATUS="CRITICAL"))
        self.assertEqual(len(report["statuses"]), 15)
        self.assertEqual(len({row["key"] for row in report["statuses"]}), 15)
        self.assertNotIn("OVERALL_STATUS", [row["key"] for row in report["statuses"]])
        self.assertEqual(report["regressions"], ["SERVICE_STATUS"])

    def test_baseline_faults_remain_visible_when_improved_worsened_or_unknown(self):
        for old, new, change in (("CRITICAL", "WARNING", "IMPROVED"), ("WARNING", "CRITICAL", "REGRESSED"),
                                  ("CRITICAL", "UNKNOWN", "UNKNOWN")):
            with self.subTest(old=old, new=new):
                report = compare.compare_summaries(snapshot(SERVICE_STATUS=old), snapshot(SERVICE_STATUS=new))
                self.assertEqual(report["unresolved_baseline"][0]["change"], change)
        report = compare.compare_summaries(snapshot(SERVICE_STATUS="CRITICAL"), snapshot())
        self.assertEqual(report["unresolved_baseline"], [])

    def test_unresolved_failed_paths_are_visible(self):
        for after in ("3", "2", "4", ""):
            with self.subTest(after=after):
                report = compare.compare_summaries(snapshot(MPIO_STATUS="CRITICAL", FAILED_MPIO_PATHS="3"),
                                                   snapshot(MPIO_STATUS="CRITICAL", FAILED_MPIO_PATHS=after))
                self.assertIn("FAILED_MPIO_PATHS", [row["key"] for row in report["unresolved_baseline"]])

    def test_all_status_transitions(self):
        for key in compare.STATUS_KEYS:
            for old in ("OK", "WARNING", "CRITICAL"):
                for new in ("OK", "WARNING", "CRITICAL"):
                    with self.subTest(key=key, old=old, new=new):
                        report = compare.compare_summaries(snapshot(**{key: old}), snapshot(**{key: new}))
                        expected = 2 if compare.SEVERITY[new] > compare.SEVERITY[old] else (1 if new != "OK" else 0)
                        self.assertEqual(report["exit_code"], expected)

    def test_failed_paths_regress_with_same_status(self):
        report = compare.compare_summaries(snapshot(MPIO_STATUS="CRITICAL", FAILED_MPIO_PATHS="2"),
                                           snapshot(MPIO_STATUS="CRITICAL", FAILED_MPIO_PATHS="3"))
        self.assertEqual(report["regressions"], ["FAILED_MPIO_PATHS"])
        self.assertEqual(report["exit_code"], 2)

    def test_performance_deltas_are_informational(self):
        report = compare.compare_summaries(snapshot(CPU_BUSY_PERCENT="20.5"), snapshot(CPU_BUSY_PERCENT="30.5"))
        self.assertEqual(report["exit_code"], 0)
        self.assertEqual(next(row["delta"] for row in report["metrics"] if row["key"] == "CPU_BUSY_PERCENT"), 10)

    def test_integer_counts_keep_precision(self):
        report = compare.compare_summaries(snapshot(FAILED_MPIO_PATHS="9007199254740992"),
                                           snapshot(FAILED_MPIO_PATHS="9007199254740993"))
        self.assertEqual(report["exit_code"], 2)
        self.assertEqual(report["metrics"][-1]["delta"], 1)

    def test_all_metric_deltas_and_fractional_precision(self):
        for key in compare.METRIC_KEYS:
            with self.subTest(key=key):
                report = compare.compare_summaries(snapshot(**{key: "2"}), snapshot(**{key: "1"}))
                row = next(row for row in report["metrics"] if row["key"] == key)
                self.assertEqual((row["before"], row["after"], row["delta"]), (2, 1, -1))
        report = compare.compare_summaries(snapshot(CPU_BUSY_PERCENT="0.1"), snapshot(CPU_BUSY_PERCENT="0.3"))
        row = next(row for row in report["metrics"] if row["key"] == "CPU_BUSY_PERCENT")
        self.assertEqual(row["delta"], 0.2)

    def test_aix_version_upgrade_and_downgrade_require_review(self):
        for version in ("7300-03-00-0000", "7200-04-00-0000"):
            with self.subTest(version=version):
                report = compare.compare_summaries(snapshot(), snapshot(AIX_LEVEL=version))
                self.assertEqual(report["exit_code"], 1)
                self.assertEqual(report["metadata_changes"], [
                    {"key": "AIX_LEVEL", "before": "7200-05-11-2546", "after": version}])
                self.assertIn("7200-05-11-2546 -> " + version, compare.render_text(report))

    def test_configuration_changes_require_review(self):
        for changes in ({"VCPU": "8"}, {"AIX_LEVEL": "7300-03-00-0000"}, {"POWERHA_STATE": "NOT_INSTALLED"}):
            with self.subTest(changes=changes):
                report = compare.compare_summaries(snapshot(), snapshot(**changes))
                self.assertEqual(report["exit_code"], 1)
                self.assertTrue(report["review_reasons"])

    def test_unavailable_evidence_is_inconclusive(self):
        for changes in ({"RUN_QUEUE": ""}, {"OS_STATUS": "UNKNOWN"}, {"AIX_LEVEL": ""}, {"POWERHA_STATE": "UNKNOWN"}):
            for reverse in (False, True):
                with self.subTest(changes=changes, reverse=reverse):
                    pair = [snapshot(), snapshot(**changes)]
                    report = compare.compare_summaries(*pair[::(-1 if reverse else 1)])
                    self.assertEqual((report["outcome"], report["exit_code"]), ("INCONCLUSIVE", 3))

    def test_unknown_does_not_hide_known_regressions(self):
        report = compare.compare_summaries(snapshot(), snapshot(OS_STATUS="UNKNOWN", SERVICE_STATUS="CRITICAL"))
        self.assertEqual(report["exit_code"], 3)
        self.assertIn("SERVICE_STATUS", report["regressions"])

    def test_invalid_pairs(self):
        for changes in ({"HOST": "another-lpar"}, {"TIMESTAMP": "20260925_120000"}, {"CHECK_TYPE": "precheck"}):
            with self.subTest(changes=changes), self.assertRaises(compare.ValidationError):
                compare.compare_summaries(snapshot(), snapshot(**changes))
        with self.assertRaises(compare.ValidationError):
            compare.compare_summaries(snapshot(CHECK_TYPE="postcheck"), snapshot())


class ParserAndCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.before = Path(self.temp.name) / "before.summary"
        self.after = Path(self.temp.name) / "after.summary"
        write_summary(self.before, snapshot())
        write_summary(self.after, snapshot())

    def cli(self, *args):
        return subprocess.run([sys.executable, str(ROOT / "scripts/compare_aix_health.py"), *map(str, args)],
                              capture_output=True, text=True, timeout=20)

    def test_utf8_bom_crlf_comments_and_blank_lines(self):
        content = self.before.read_text(encoding="utf-8")
        self.before.write_bytes(("\ufeff# evidence\r\n\r\n" + content.replace("\n", "\r\n")).encode("utf-8"))
        self.assertEqual(compare.read_summary(self.before), snapshot())

    def test_rejects_bad_lines_duplicates_encoding_and_oversize(self):
        valid = self.before.read_bytes()
        for content in (b"not a summary", valid + b"HOST=other\n", valid + b"EXTRA=1\n",
                        valid + b"bad-key=value\n", b"\xff", b"\x00", b"x" * (compare.MAX_INPUT_BYTES + 1)):
            with self.subTest(content=content[:50]), self.assertRaises(compare.ValidationError):
                self.before.write_bytes(content)
                compare.read_summary(self.before)

    def test_all_required_fields(self):
        for key in compare.REQUIRED_KEYS:
            with self.subTest(key=key), self.assertRaises(compare.ValidationError):
                data = snapshot()
                del data[key]
                write_summary(self.before, data)
                compare.read_summary(self.before)

    def test_invalid_values(self):
        for key, value in (("CPU_BUSY_PERCENT", "101"), ("PAGE_OUT", "-1"), ("RUN_QUEUE", "nan"),
                           ("PAGE_IN", "inf"), ("PAGE_IN", "9" * 400), ("VCPU", "0"),
                           ("FAILED_MPIO_PATHS", "1.5"), ("VCPU", "2.0"), ("CHECK_TYPE", ""),
                           ("HOST", "../host"), ("HOST", "x" * 64), ("TIMESTAMP", "20260230_120000"),
                           ("TIMESTAMP", "20260926_250000"), ("TIMESTAMP", "2026926_120000"),
                           ("AIX_LEVEL", "not-a-level"), ("OS_STATUS", "BAD"),
                           ("OVERALL_CODE", "2"), ("OVERALL_STATUS", "CRITICAL"),
                           ("POWERHA_STATE", ""), ("RUN_QUEUE", "$(touch injected)"),
                           ("CPU_BUSY_PERCENT", "100.00000000000000000001"), ("VCPU", "0" * 5000 + "1")):
            with self.subTest(key=key, value=value), self.assertRaises(compare.ValidationError):
                data = snapshot()
                data[key] = value
                write_summary(self.before, data)
                compare.read_summary(self.before)

    def test_inconsistent_overall_even_when_code_matches(self):
        data = snapshot()
        data.update(OVERALL_STATUS="CRITICAL", OVERALL_CODE="2")
        write_summary(self.before, data)
        with self.assertRaises(compare.ValidationError):
            compare.read_summary(self.before)

    def test_cli_scenario_exit_codes_and_json(self):
        for old, new, code in (("OK", "OK", 0), ("CRITICAL", "CRITICAL", 1),
                               ("OK", "CRITICAL", 2), ("CRITICAL", "OK", 0), ("OK", "UNKNOWN", 3)):
            with self.subTest(old=old, new=new):
                write_summary(self.before, snapshot(SERVICE_STATUS=old))
                write_summary(self.after, snapshot(SERVICE_STATUS=new))
                result = self.cli(self.before, self.after, "--format", "json")
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(json.loads(result.stdout)["exit_code"], code)
                self.assertEqual(result.stderr, "")

    def test_cli_text(self):
        result = self.cli(self.before, self.after)
        self.assertEqual(result.returncode, 0)
        self.assertIn("UNCHANGED", result.stdout)
        self.assertIn("SERVICE_STATUS: OK -> OK", result.stdout)

    def test_cli_baseline_faults_are_explicit_in_json(self):
        for path in (self.before, self.after):
            write_summary(path, snapshot(SERVICE_STATUS="CRITICAL"))
        result = self.cli(self.before, self.after, "--format", "json")
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["regressions"], [])
        self.assertEqual(report["unresolved_baseline"][0]["key"], "SERVICE_STATUS")

    def test_cli_rejects_same_file_alias(self):
        alias = self.before.parent / "alias.summary"
        os.link(self.before, alias)
        result = self.cli(self.before, alias)
        self.assertEqual(result.returncode, 3)
        self.assertIn("must be different files", result.stderr)

    def test_cli_rejects_oversized_numeric_token_without_traceback(self):
        data = snapshot()
        data["VCPU"] = "0" * 5000 + "1"
        write_summary(self.after, data)
        result = self.cli(self.before, self.after, "--format", "json")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["outcome"], "INVALID_INPUT")
        self.assertNotIn("Traceback", result.stderr)

    def test_cli_invalid_files_and_arguments(self):
        for args in ((), (self.before,), (self.before, self.after, "--bogus"),
                     (self.before, self.after, "--format", "xml"),
                     (self.before, self.before), (self.before, self.before.parent),
                     (self.before, self.before.parent / "missing.summary")):
            with self.subTest(args=args):
                result = self.cli(*args)
                self.assertEqual(result.returncode, 3)
                self.assertIn("error:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_invalid_input_json(self):
        self.after.write_text("HOST=wrong\n", encoding="utf-8")
        result = self.cli(self.before, self.after, "--format", "json")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["outcome"], "INVALID_INPUT")

    def test_help(self):
        result = self.cli("--help")
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
