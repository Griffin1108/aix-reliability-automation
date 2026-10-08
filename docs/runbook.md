# Health collection and change validation

## Repository inspection

The inspected branch was `feature/aix-health-comparison`, at `dfe97a1`.
History contains the initial structure, baseline checker (`b57db0d`), complete
engine (`ccee7d3`), comprehensive engine upgrade (`3a18c7e`), merge to main
(`eaa6ca0`), and the comparison commit (`dfe97a1`). That final commit created an
empty comparison script. README and this runbook were also empty; inventory and
playbooks were placeholders, and no automated tests were tracked.

The engine is preserved with localized changes: stable mock identity and mock
configuration validation, consistent identity in LPAR/PowerHA mock evidence,
UNKNOWN statuses for all unexecuted checks when real mode is rejected on
non-AIX, and protection against report/summary overwrites.

## Phase 1: existing report contract

The engine writes two files under the repository's `reports/` directory:

* `<HOST>_<YYYYMMDD_HHMMSS>_<CHECK_TYPE>.txt`: human-readable command evidence,
  detailed findings and reliability summary; also printed to stdout.
* The same basename with `.summary`: 31 unquoted `KEY=value` lines.

There is no schema-version field in the engine's summary. Values are literal
data, not shell syntax. Never source a summary file. The engine exit codes are
0 OK, 1 WARNING, 2 CRITICAL, and 3 UNKNOWN/unsupported execution.

| Fields | Existing representation |
| --- | --- |
| `HOST` | Short hostname |
| `CHECK_TYPE` | Label; defaults to `healthcheck`, commonly `precheck` or `postcheck` |
| `TIMESTAMP` | Local wall-clock time, `YYYYMMDD_HHMMSS`; no timezone |
| `AIX_LEVEL` | `oslevel -s`, e.g. `7200-05-11-2546`; may be blank if unavailable |
| `OS_STATUS`, `PERFORMANCE_STATUS`, `PAGING_STATUS`, `FILESYSTEM_STATUS`, `VG_LV_STATUS`, `PV_STATUS`, `DEVICE_STATUS`, `MPIO_STATUS`, `DISK_IO_STATUS`, `ERRPT_STATUS`, `NETWORK_STATUS`, `SERVICE_STATUS`, `NTP_STATUS`, `DUMP_STATUS`, `POWERHA_STATUS` | `OK`, `WARNING`, `CRITICAL`, `UNKNOWN` |
| `POWERHA_STATE` | State token; mocks use `STABLE`/`ERROR`; also `NOT_INSTALLED`, `N/A`, `UNKNOWN` |
| `VCPU` | Positive integer virtual CPU count, or blank |
| `RUN_QUEUE`, `PAGE_IN`, `PAGE_OUT` | Nonnegative numeric interval observations, or blank |
| `CPU_BUSY_PERCENT`, `IOWAIT_PERCENT`, `PAGING_USED_PERCENT`, `MAX_DISK_BUSY_PERCENT` | Numbers from 0 to 100 without a percent sign, or blank |
| `FAILED_MPIO_PATHS` | Nonnegative integer count of Failed/Missing paths, or blank |
| `OVERALL_STATUS`, `OVERALL_CODE` | Maximum component status and corresponding code (0–3) |

Blank metric values represent unavailable observations, never zero. The summary
does not include individual filesystem utilization, resource inventories,
threshold settings, optional-check configuration, mock/real provenance, or
collector success indicators. Detailed evidence stays in the text report.

## Phase 2: stable mock identity

`MOCK_HOSTNAME` defaults to `mock-aix01` for both healthy and degraded profiles.
Changing `MOCK_PROFILE` changes health, not identity. The hostname appears in
filenames, summaries, LPAR node information and the simulated local PowerHA node.
The separate PowerHA peer and partition metadata remain fixed fixtures.

Supported profiles are exactly `healthy` and `degraded`; typos exit 3 before
report creation. Mock hostnames allow 1–63 ASCII letters/digits/internal hyphens.
Use the same hostname in both runs. Legacy summaries named `mock-healthy` and
`mock-degraded` will fail identity validation: regenerate them with the updated
engine instead of silently overriding mismatched host identities.

Use `CHECK_TYPE=precheck` and `CHECK_TYPE=postcheck` to distinguish captures.
`MOCK_MODE` must be exactly 0 or 1. `CHECK_TYPE` must start with an ASCII letter
or digit and contain only letters, digits, underscores, periods or hyphens
(at most 128 characters); unsafe path/summary content is rejected before capture.

An existing text report OR summary at the target basename makes collection exit
3 without overwriting either file. An exclusive (shell noclobber) report open
arbitrates concurrent captures of the same name, and summary creation is also
exclusive. A same-second collision is an explicit failure, not an automatic
rename; retry later or choose another label. Summary creation failures exit 3
and report an incomplete capture. Preserve the exact paths and collection exit
code. Collect into a trusted writable directory; interrupted captures can leave
partial evidence, which must not be used as successful collection results.

## Phase 3: comparison policy and operation

```sh
# On the AIX host, using the same collection settings for both snapshots:
CHECK_TYPE=precheck /usr/bin/ksh scripts/aix_healthcheck.sh
# Perform the separately authorized change, then collect:
CHECK_TYPE=postcheck /usr/bin/ksh scripts/aix_healthcheck.sh

# On any host with Python 3.8+; substitute the actual paths printed above:
python3 scripts/compare_aix_health.py /path/to/pre.summary /path/to/post.summary
python3 scripts/compare_aix_health.py /path/to/pre.summary /path/to/post.summary --format json > comparison.json
rc=$?
printf 'Comparison exit code: %s\n' "$rc"
```

Treat nonzero health-check and comparison results as data to inspect. Automation
using `set -e` must explicitly capture these exit codes to avoid aborting before
evidence is retained. Do not discard errors with an unconditional success code.

Comparison rules:

* Rank known statuses `OK < WARNING < CRITICAL` for each of the 15 checks.
  Any worsening is a regression, even if overall health was already CRITICAL
  or other checks improve.
  `OVERALL_STATUS` validates and summarizes those checks; it is never evaluated
  a second time as an individual component.
* `unresolved_baseline` lists previously WARNING/CRITICAL components that have
  not returned to OK, and failed MPIO path counts that remain positive or become
  unavailable. Text reports separate these from new or worsened degradation.
  A baseline issue may also have worsened, in which case both facts are reported.
  UNKNOWN means its resolution is unverified. Unchanged degraded→degraded
  remains exit 1 and explicitly states that no new degradation was detected.
* An increase in failed MPIO paths is a regression even within the same status.
  A decrease is an improvement. Other numeric deltas are informational because
  workload and collection thresholds are absent from this schema.
  Decimal source values are subtracted before conversion to JSON numbers to
  avoid ordinary binary floating-point subtraction artifacts; count fields
  retain integer precision. JSON fractional values use standard float encoding.
* AIX level and vCPU changes require review rather than being automatically
  classified as improvements/regressions. PowerHA state changes require review
  unless a restoration to STABLE is explained by improved PowerHA status.
* Unknown check statuses, blank metrics/AIX levels, or UNKNOWN PowerHA state
  make the comparison INCONCLUSIVE (exit 3). Known regressions remain listed.
* Otherwise regressions take priority (exit 2), followed by improvements or
  unchanged health. Residual non-OK health or configuration review exits 1;
  healthy results without pending review exit 0.

Validation rejects missing/extra/duplicate fields, malformed lines, invalid
UTF-8/control characters, invalid numbers/ranges/dates/statuses, inconsistent
overall status/code, host mismatches, post timestamps earlier than pre, use of
the same file (including aliases), unreadable inputs, and incorrect CLI usage.
Inputs are capped at 1 MiB. UTF-8 BOM, LF/CRLF, blank lines and full-line comments
are accepted. Numeric tokens are capped at 64 characters and percentage bounds
are checked with decimal precision. Future schema extensions require an explicit
comparator update.
`precheck`/`postcheck` labels in the wrong position are rejected; `healthcheck`
and custom labels are supported. Equal timestamps are allowed for independent
captures within one second. Captures must use the same local clock convention.

Text is the default output. `--format json` emits a single JSON object with
`schema_version=1`, outcome, exit code, host, timestamps, overall health, all
component transitions, all numeric deltas, metadata changes, regressions,
improvements, unresolved baseline problems, review reasons and unavailable
evidence. Invalid input emits an
`INVALID_INPUT` JSON object and a diagnostic to stderr. Argument syntax errors
use argparse usage/diagnostics on stderr and exit 3. Help exits 0.

## Phase 4: verification and operational boundaries

```sh
python3 -m unittest discover -s tests -v
```

Tests cover healthy→healthy, degraded→degraded, degraded→healthy and
healthy→degraded; every known per-component status transition; mixed outcomes;
residual faults; failed path counts; metadata drift; unavailable data; parser
and CLI errors; JSON output; mock identity; optional mock collectors; and
non-AIX rejection, pre-existing evidence and concurrent/same-second filename
collisions. Integration tests execute the existing engine in temporary
projects and validate its generated summaries, avoiding writes to retained
project evidence. No third-party Python dependencies or network are required.

The comparator evaluates the evidence it is given. It cannot prove that two
captures used identical thresholds, settings, workload, or collection mode.
Keep those settings controlled externally and retain the text reports and
collection return codes. Some existing collectors substitute zero/defaults or
lack explicit collection-failure statuses; the comparator cannot recover
missing evidence hidden by those defaults. Optional checks may report OK when
not required. A zero comparison exit code is not a guarantee of application
readiness or approval to deploy. Validate real AIX command output, permissions,
KornShell execution and representative workloads before production use.

## Optional boot-readiness profile

The agreed design keeps one deployable shell script with named collector and
check functions. `HEALTH_PROFILE=standard` is the default and runs the existing
15 categories. `HEALTH_PROFILE=boot-readiness` runs those same checks and adds
boot evidence. No checks are skipped or assigned an artificial OK to make room
for the profile. Invalid profile names or copy policies exit 3 before reports
are created.

For a mock demonstration from Bash:

```sh
MOCK_MODE=1 MOCK_PROFILE=healthy HEALTH_PROFILE=boot-readiness BOOT_MIN_COPIES=2 CHECK_TYPE=boot-precheck bash scripts/aix_healthcheck.sh
MOCK_MODE=1 MOCK_PROFILE=degraded HEALTH_PROFILE=boot-readiness BOOT_MIN_COPIES=2 CHECK_TYPE=boot-postcheck bash scripts/aix_healthcheck.sh
```

The first exits 0; the second intentionally exits 2. The simulated hostname
remains `mock-aix01` for both. Retain the printed report/summary paths and exit
codes. On a future authorized global AIX LPAR, the corresponding invocation is:

```sh
HEALTH_PROFILE=boot-readiness BOOT_MIN_COPIES=2 CHECK_TYPE=boot-precheck /usr/bin/ksh scripts/aix_healthcheck.sh
```

This real-mode invocation has not been tested on AIX. The profile reads
`uname -W`, checks for the VIOS CLI, and reads `lsvg -p rootvg`, `lsvg -l rootvg`,
`lslv -m hd5`, `bootlist -m normal -o`, `lsdev -l <disk> -F status` and
`bootinfo -B <disk>`. It never rebuilds a boot image, changes the bootlist,
repairs mirrors, varies volume groups or reboots. WPARs, detected VIOS systems
and unknown execution scope return UNKNOWN for the boot assessment.

| Evidence | Assessment |
| --- | --- |
| Rootvg PV/LV inventory | Missing/removed PVs and stale LVs are CRITICAL. `closed/syncd` is a normal LV state. LP/PP counts are shown as allocation evidence. |
| hd5 map | Validate LP/PP/PV counts against LV metadata. Each candidate disk must contain every hd5 LP in contiguous physical partitions. Split/noncontiguous copies require review; no complete copy is CRITICAL. |
| Normal bootlist | Assess local hdisk entries for the current rootvg and hd5. Unresolved `-` entries, inactive devices, missing complete copies or reported boot capability 0 are CRITICAL. |
| Candidate policy | `BOOT_MIN_COPIES=1`, `2` or `3` counts distinct qualifying disks. Repeated path entries count once. A nonzero count below the requested minimum is WARNING; no candidates with otherwise conclusive evidence is CRITICAL. |
| Incomplete evidence | Command failure, stderr diagnostics, empty/whitespace-only output, malformed/inconsistent inventories or maps, unsupported attributes/devices and alternate-OS disks are UNKNOWN. Known critical findings remain visible in the report. |

The text report records the selected profile, policy, raw command evidence,
findings and suggested next actions. Numeric severity uses the existing order
OK < WARNING < CRITICAL < UNKNOWN. The boot result can raise, but never lower,
the existing `VG_LV_STATUS` and overall status. It adds no summary field or
sixteenth comparison component. Read the text report to distinguish a boot
finding from another VG/LV issue, particularly when the aggregate was already
CRITICAL.

The 31-field summary does not record the profile or policy. The comparator
cannot detect mismatched settings or distinguish different faults within the
same VG/LV category. Use the same `HEALTH_PROFILE`, `BOOT_MIN_COPIES` and other
collection settings for both captures, and retain their text reports. This is
a deliberate compatibility tradeoff; detailed inventory comparison needs a
separately designed schema extension.

An hd5 candidate is a disk with the assessed placement, availability and
firmware boot capability; it is not a verified boot image. These checks do not
prove boot-image contents or freshness, per-path reachability, firmware boot
success, whole-rootvg mirroring or independence of storage failure domains.
The default minimum of one avoids assuming that every LPAR must be mirrored.
`bootinfo -B` returning 0 calls for investigation; adapter/IPL history can
affect the result, so it alone does not prove a disk has failed. Network,
removable-media and alternate boot-LV policies need manual assessment.

Implementation is original and based on IBM command semantics; no vendor UHC
code is incorporated. Engineering references:

* [IBM bootlist command](https://www.ibm.com/docs/en/aix/7.2.0?topic=b-bootlist-command)
* [IBM lslv command](https://www.ibm.com/docs/en/aix/7.2.0?topic=l-lslv-command)
* [IBM preparation checks and hd5 map examples](https://www.ibm.com/support/pages/preparing-migrate-aix)
* [IBM bootinfo capability and adapter/boot history](https://www.ibm.com/support/pages/node/631755)
* [IBM WPAR identification](https://www.ibm.com/support/pages/am-i-wpar-workload-partition-or-regular-aix-vm-virtual-machine)

Tests use deterministic collectors and additional malformed/failure fixtures
inside temporary projects. Bash mock success does not validate native AIX
output variants, permissions, KornShell or actual boot behavior. Complete
those checks on an authorized test LPAR before production use.
