# AIX Infrastructure Reliability Automation

Read-only AIX health assessment and automated pre/post-change validation.
The existing KornShell health engine collects detailed evidence; the Python
comparison tool evaluates its machine-readable summaries. Python 3.8+ and the
standard library are sufficient for comparison. The comparator can run off-host.

Mock development does not require an AIX LPAR. From a Bash shell:

```sh
MOCK_MODE=1 MOCK_HOSTNAME=mock-aix01 MOCK_PROFILE=healthy CHECK_TYPE=precheck bash scripts/aix_healthcheck.sh
MOCK_MODE=1 MOCK_HOSTNAME=mock-aix01 MOCK_PROFILE=degraded CHECK_TYPE=postcheck bash scripts/aix_healthcheck.sh
```

The degraded run intentionally exits 2. Each run prints the paths of its report
and summary. Existing report or summary filenames are never silently replaced:
a collision exits 3; retry later or use another `CHECK_TYPE` label.
Supply those exact summary paths to the comparator:

```sh
python3 scripts/compare_aix_health.py reports/<precheck>.summary reports/<postcheck>.summary
python3 scripts/compare_aix_health.py reports/<precheck>.summary reports/<postcheck>.summary --format json
```

Comparison exit codes:

| Code | Meaning |
| --- | --- |
| 0 | No detected regression; post-change health is OK and no configuration review remains |
| 1 | No detected regression, but post-change health remains degraded or configuration changed |
| 2 | At least one component worsened or the failed MPIO path count increased |
| 3 | Invalid inputs/CLI usage, or insufficient evidence for comparison |

The report separately classifies the outcome as `UNCHANGED`, `IMPROVED`,
`REGRESSED`, or `INCONCLUSIVE`. An unchanged degraded system therefore exits 1.
Unresolved baseline problems are listed separately from new or worsened
degradation, including baseline conditions whose resolution is UNKNOWN.
Invalid input is reported as `INVALID_INPUT` in JSON. See the
[runbook](docs/runbook.md) for schema, policies, operational examples and limits.

Run the automated tests:

```sh
python3 -m unittest discover -s tests -v
```

Unit tests run on Windows or Unix. Integration tests require Bash, awk and the
usual Unix utilities, and run only mock collectors (plus the non-AIX rejection
check). They use isolated temporary projects. On Windows, Git Bash is detected
at its standard installation path; `AIX_TEST_BASH` can override the executable.
If Bash is unavailable, integration tests explicitly report a skip.

Real AIX/KornShell and hardware validation remain required before production
deployment. No actual AIX LPAR was used for the development tests.

Read [project context](docs/PROJECT_CONTEXT.md) for objectives, architecture,
verified milestones and the roadmap, and [AGENTS.md](AGENTS.md) for repository
development instructions and approval boundaries.
