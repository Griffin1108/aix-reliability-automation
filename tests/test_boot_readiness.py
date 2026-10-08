"""Boot-readiness policy tests using isolated shell fixtures, never real AIX."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

from test_compare_aix_health import ROOT, compare
from test_mock_integration import find_bash


PVS = """rootvg:
PV_NAME           PV STATE          TOTAL PPs   FREE PPs    FREE DISTRIBUTION
hdisk0            active            1000        500         100..100..100..100..100
hdisk1            active            1000        500         100..100..100..100..100
"""
LVS = """rootvg:
LV NAME             TYPE       LPs     PPs     PVs  LV STATE      MOUNT POINT
hd5                 boot       1       2       2    closed/syncd  N/A
hd4                 jfs2       4       8       2    open/syncd    /
"""
HD5_MAP = """hd5:N/A
LP    PP1  PV1               PP2  PV2               PP3  PV3
0001  0001 hdisk0            0001 hdisk1
"""
BOOTLIST = "hdisk0 blv=hd5 pathid=0\nhdisk1 blv=hd5 pathid=0\n"
FIXTURES = {
    "collect_boot_wpar": "0\n",
    "collect_boot_vios": "0\n",
    "collect_boot_rootvg_pvs": PVS,
    "collect_boot_rootvg_lvs": LVS,
    "collect_boot_hd5_map": HD5_MAP,
    "collect_bootlist": BOOTLIST,
    "collect_boot_device_status": "Available\n",
    "collect_boot_capability": "1\n",
}
EXECUTION_MARKER = "# EXECUTION / REPORT GENERATION"


class BootReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = find_bash()
        if not cls.bash:
            raise unittest.SkipTest("Bash unavailable; set AIX_TEST_BASH to run boot-readiness tests")
        cls.source = (ROOT / "scripts/aix_healthcheck.sh").read_text(encoding="utf-8")
        cls.env = os.environ.copy()
        for name in re.findall(r'^([A-Z_]+)="\$\{', cls.source, re.MULTILINE):
            cls.env.pop(name, None)
        cls.env.update(LC_ALL="C", MOCK_MODE="1", MOCK_PROFILE="healthy")
        if os.name == "nt":
            cls.env["PATH"] = str(Path(cls.bash).parent.parent / "usr/bin") + os.pathsep + cls.env.get("PATH", "")

    def run_engine(self, source=None, **overrides):
        temp = tempfile.TemporaryDirectory(prefix="aix-boot-tests-")
        self.addCleanup(temp.cleanup)
        project = Path(temp.name)
        (project / "scripts").mkdir()
        script = project / "scripts/aix_healthcheck.sh"
        with script.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(self.source if source is None else source)
        result = subprocess.run([self.bash, "scripts/aix_healthcheck.sh"], cwd=project,
                                env=dict(self.env, **overrides), capture_output=True, text=True, timeout=90)
        return result, project

    def fixture_run(self, fixtures=None, policy="1", baseline=0):
        # Cut off only top-level execution; use the actual production functions.
        # Every boot collector is replaced so this cannot contact infrastructure.
        source = self.source[:self.source.index(EXECUTION_MARKER)]
        values = dict(FIXTURES)
        values.update(fixtures or {})
        for name, value in values.items():
            data, code, error = value if isinstance(value, tuple) else (value, 0, "")
            source += "\n{}() {{\n    printf '%s' {}\n    printf '%s' {} >&2\n    return {}\n}}\n".format(
                name, shlex.quote(data), shlex.quote(error), code)
        source += '\nVG_STATUS={0}\nOVERALL_STATUS={0}\ncheck_boot_readiness\n'.format(baseline)
        source += 'printf "BOOT_TEST_RESULT=%s %s %s %s %s %s\\n" "$BOOT_STATUS" "$BOOT_ROOTVG_STATUS" "$BOOT_HD5_STATUS" "$BOOT_LIST_STATUS" "$VG_STATUS" "$OVERALL_STATUS"\n'
        source += 'exit "$BOOT_STATUS"\n'
        result, project = self.run_engine(source, HEALTH_PROFILE="boot-readiness", BOOT_MIN_COPIES=policy)
        match = re.search(r"^BOOT_TEST_RESULT=(\d) (\d) (\d) (\d) (\d) (\d)$", result.stdout, re.MULTILINE)
        self.assertIsNotNone(match, result.stdout + result.stderr)
        states = tuple(int(value) for value in match.groups())
        self.assertEqual(result.returncode, states[0], result.stdout + result.stderr)
        self.assertEqual(states[4], max(baseline, states[0]), result.stdout)
        self.assertEqual(states[5], max(baseline, states[0]), result.stdout)
        self.assertFalse(list((project / "reports").glob("*.summary")))
        return result, states

    def assert_boot_status(self, expected, **kwargs):
        result, states = self.fixture_run(**kwargs)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result, states

    def test_standard_default_and_opt_in_keep_summary_contract(self):
        snapshots = []
        for profile in (None, "standard", "boot-readiness"):
            with self.subTest(profile=profile):
                settings = {} if profile is None else {"HEALTH_PROFILE": profile}
                result, project = self.run_engine(**settings)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                summaries = list((project / "reports").glob("*.summary"))
                self.assertEqual(len(summaries), 1)
                summary = compare.read_summary(summaries[0])
                self.assertEqual(set(summary), compare.REQUIRED_KEYS)
                self.assertEqual(len(summary), 31)
                self.assertEqual(summary["VG_LV_STATUS"], "OK")
                self.assertEqual(summary["OVERALL_CODE"], "0")
                snapshots.append({key: value for key, value in summary.items() if key != "TIMESTAMP"})
        self.assertEqual(snapshots[0], snapshots[1])
        self.assertEqual(snapshots[1], snapshots[2])

    def test_degraded_boot_profile_remains_critical(self):
        result, project = self.run_engine(HEALTH_PROFILE="boot-readiness", MOCK_PROFILE="degraded")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        summary = compare.read_summary(next((project / "reports").glob("*.summary")))
        self.assertEqual(set(summary), compare.REQUIRED_KEYS)
        self.assertEqual(summary["VG_LV_STATUS"], "CRITICAL")
        self.assertEqual(summary["OVERALL_CODE"], "2")

    @unittest.skipIf(os.uname().sysname == "AIX" if hasattr(os, "uname") else False, "requires non-AIX host")
    def test_boot_profile_does_not_bypass_platform_guard(self):
        result, project = self.run_engine(HEALTH_PROFILE="boot-readiness", MOCK_MODE="0")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        summary = compare.read_summary(next((project / "reports").glob("*.summary")))
        self.assertTrue(all(summary[key] == "UNKNOWN" for key in compare.STATUS_KEYS))
        self.assertEqual(summary["OVERALL_CODE"], "3")
        self.assertIn("UNKNOWN - no checks executed", result.stdout)

    def test_invalid_profile_or_mirror_policy_creates_no_reports(self):
        for settings in ({"HEALTH_PROFILE": "typo"}, {"HEALTH_PROFILE": "../escape"},
                         {"BOOT_MIN_COPIES": "0"}, {"BOOT_MIN_COPIES": "4"},
                         {"BOOT_MIN_COPIES": "1.5"}, {"BOOT_MIN_COPIES": "two"}):
            with self.subTest(settings=settings):
                result, project = self.run_engine(**settings)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("ERROR:", result.stderr)
                self.assertFalse(list((project / "reports").glob("*.txt")))
                self.assertFalse(list((project / "reports").glob("*.summary")))

    def test_healthy_mirrored_fixture_and_existing_baseline_fault(self):
        self.assert_boot_status(0, policy="2")
        self.assert_boot_status(0, policy="2", baseline=2)
        self.assert_boot_status(1, policy="3")

    def test_single_disk_warning_depends_on_requested_copies(self):
        single = {
            "collect_boot_rootvg_pvs": "\n".join(PVS.splitlines()[:-1]) + "\n",
            "collect_boot_rootvg_lvs": LVS.replace("1       2       2", "1       1       1").replace("4       8       2", "4       4       1"),
            "collect_boot_hd5_map": HD5_MAP.replace("            0001 hdisk1", ""),
            "collect_bootlist": "hdisk0 blv=hd5 pathid=0\n",
        }
        self.assert_boot_status(0, fixtures=single, policy="1")
        self.assert_boot_status(1, fixtures=single, policy="2")

    def test_stale_lv_and_unavailable_rootvg_pv_are_critical(self):
        for fixtures in ({"collect_boot_rootvg_lvs": LVS.replace("open/syncd", "open/stale")},
                         {"collect_boot_rootvg_pvs": PVS.replace("hdisk1            active", "hdisk1            missing")}):
            with self.subTest(fixtures=fixtures):
                self.assert_boot_status(2, fixtures=fixtures)

    def test_collector_failures_and_empty_evidence_are_unknown(self):
        for name in FIXTURES:
            for value in ((FIXTURES[name], 7, ""), "", " \t\n",
                          (FIXTURES[name], 0, "collector diagnostic\n")):
                with self.subTest(collector=name, value=value):
                    self.assert_boot_status(3, fixtures={name: value})

    def test_malformed_evidence_is_unknown(self):
        for name, data in (("collect_boot_wpar", "unexpected\n"),
                           ("collect_boot_rootvg_pvs", "unrecognized rootvg output\n"),
                           ("collect_boot_rootvg_lvs", LVS.replace("1       2       2", "x       2       2")),
                           ("collect_boot_hd5_map", HD5_MAP.replace("0001  0001", "xxxx  0001")),
                           ("collect_boot_device_status", "unrecognized\n"),
                           ("collect_boot_capability", "maybe\n")):
            with self.subTest(collector=name):
                self.assert_boot_status(3, fixtures={name: data})

    def test_wpar_is_inconclusive(self):
        self.assert_boot_status(3, fixtures={"collect_boot_wpar": "1\n"})

    def test_vios_is_inconclusive(self):
        self.assert_boot_status(3, fixtures={"collect_boot_vios": "1\n"})

    def test_bootlist_outside_rootvg_and_unsupported_entries(self):
        # An alternate OS disk can be intentional; absent inventory is inconclusive.
        self.assert_boot_status(3, fixtures={"collect_bootlist": "hdisk2 blv=hd5\n"})
        self.assert_boot_status(3, fixtures={"collect_bootlist": "cd0\n"})
        self.assert_boot_status(2, fixtures={"collect_bootlist": "-\n"})

    def test_unavailable_or_non_bootable_device_is_critical(self):
        self.assert_boot_status(2, fixtures={"collect_boot_device_status": "Defined\n"})
        self.assert_boot_status(2, fixtures={"collect_boot_capability": "0\n"})

    def test_partial_hd5_map_is_unknown(self):
        # hd5 has two LPs in metadata but only one LP has map evidence.
        lvs = LVS.replace("1       2       2", "2       4       2")
        self.assert_boot_status(3, fixtures={"collect_boot_rootvg_lvs": lvs})

    def test_split_boot_lv_without_complete_disk_is_critical(self):
        lvs = LVS.replace("1       2       2", "2       2       2")
        mapping = "hd5:N/A\nLP PP1 PV1 PP2 PV2 PP3 PV3\n0001 0001 hdisk0\n0002 0002 hdisk1\n"
        self.assert_boot_status(2, fixtures={"collect_boot_rootvg_lvs": lvs, "collect_boot_hd5_map": mapping})

    def test_noncontiguous_boot_lv_is_critical(self):
        lvs = LVS.replace("1       2       2", "2       4       2")
        mapping = HD5_MAP + "0002 0003 hdisk0 0003 hdisk1\n"
        self.assert_boot_status(2, fixtures={"collect_boot_rootvg_lvs": lvs, "collect_boot_hd5_map": mapping})

    def test_split_additional_copy_with_complete_boot_disk_requires_review(self):
        lvs = LVS.replace("1       2       2", "2       4       3")
        mapping = HD5_MAP + "0002 0002 hdisk0 0002 hdisk2\n"
        pvs = PVS + "hdisk2 active 1000 500 100..100..100..100..100\n"
        self.assert_boot_status(1, fixtures={"collect_boot_rootvg_lvs": lvs,
                                             "collect_boot_rootvg_pvs": pvs,
                                             "collect_boot_hd5_map": mapping,
                                             "collect_bootlist": "hdisk0 blv=hd5\n"})

    def test_duplicate_boot_paths_do_not_count_as_another_boot_disk(self):
        bootlist = "hdisk0 blv=hd5 pathid=0\nhdisk0 blv=hd5 pathid=1\n"
        self.assert_boot_status(1, fixtures={"collect_bootlist": bootlist}, policy="2")

    def test_hd5_disk_outside_rootvg_is_inconclusive(self):
        self.assert_boot_status(3, fixtures={"collect_boot_hd5_map": HD5_MAP.replace("hdisk1", "hdisk2")})

    def test_complete_multi_partition_boot_copies(self):
        self.assert_boot_status(0, policy="2", fixtures={
            "collect_boot_rootvg_lvs": LVS.replace("1       2       2", "2       4       2"),
            "collect_boot_hd5_map": HD5_MAP + "0002 0002 hdisk0 0002 hdisk1\n",
        })

    def test_mapping_beyond_physical_disk_capacity_is_unknown(self):
        self.assert_boot_status(3, fixtures={
            "collect_boot_hd5_map": HD5_MAP.replace("0001  0001", "0001  1001"),
        })

    def test_duplicate_map_allocations_are_unknown(self):
        lvs = LVS.replace("1       2       2", "2       4       2")
        for extra in ("0001 0002 hdisk0 0002 hdisk1\n",
                      "0002 0001 hdisk0 0002 hdisk1\n",
                      "0002 0002 hdisk0 0003 hdisk0\n"):
            with self.subTest(extra=extra):
                self.assert_boot_status(3, fixtures={"collect_boot_rootvg_lvs": lvs,
                                                      "collect_boot_hd5_map": HD5_MAP + extra})

    def test_unknown_or_duplicate_bootlist_attributes_are_inconclusive(self):
        for attributes in ("blv=mb_hd5", "blv=hd5 blv=hd5", "pathid=0 pathid=1",
                           "pathid=", "pathid=abc", "unknown=value", "blv=*"):
            with self.subTest(attributes=attributes):
                self.assert_boot_status(3, fixtures={"collect_bootlist": "hdisk0 " + attributes + "\n"})

    def test_known_critical_evidence_remains_visible_with_unknown(self):
        result, states = self.assert_boot_status(3, fixtures={
            "collect_boot_rootvg_lvs": LVS.replace("open/syncd", "open/stale"),
            "collect_bootlist": "unrecognized-device\n",
        })
        self.assertEqual(states[1], 2)
        self.assertIn("CRITICAL [rootvg]: hd4 has stale partitions", result.stdout)
        self.assertIn("UNKNOWN [bootlist]", result.stdout)


if __name__ == "__main__":
    unittest.main()
