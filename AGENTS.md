# Repository development instructions

## Start here

Read `docs/PROJECT_CONTEXT.md`, `README.md` and `docs/runbook.md` before making
changes. Inspect the current branch, working-tree diff and relevant Git history;
the repository and verified test results take precedence over stale handovers.
Preserve uncommitted user work. Keep project context current when implementation,
decisions, milestones, limitations or agreed next steps change.

## Engineering approach

This project combines AIX/IBM Power engineering with infrastructure reliability
and change automation. Explain decisions practically and connect new tooling to
infrastructure operations. Discuss tradeoffs and challenge unsupported
assumptions. Do not implement roadmap components merely because documentation
mentions them; work within the user's current authorized task.

Preserve existing health checks and the 31-field summary contract unless a
schema change is explicitly in scope. Keep health collection read-only. Prefer
Python's standard library and AIX-compatible KornShell constructs. Bash mock
success does not establish real AIX/KornShell compatibility. No actual AIX LPAR
is currently available; distinguish simulations, prior user-reported results,
and tests actually run in the current environment.

Keep simulated host identity independent of health profile. Never source input
summary files as shell code. Validate evidence and preserve UNKNOWN as
inconclusive. Evaluate only the 15 individual check statuses; overall status is
a derived aggregate. Keep unresolved baseline faults visible separately from
new or worsened degradation. Degraded-to-degraded requires review (exit 1).
Never silently overwrite retained reports or summaries.

## Validation

For changes to comparison or collection, run:

```sh
python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/compare_aix_health.py tests/test_compare_aix_health.py tests/test_mock_integration.py
bash -n scripts/aix_healthcheck.sh
git diff --check
```

Use the available Python executable and Bash path on Windows. Integration tests
use temporary projects and must not touch real infrastructure. Inspect test
skips and failures rather than treating them as passes. Whitespace-check new
untracked files too. Validate KornShell on a suitable host when one becomes
available. Add meaningful regression coverage for behavior changes and report
what was actually tested and what remains unverified.

Health engine exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN/error.
Comparator exit codes: 0 healthy/no regression, 1 review required, 2 regression,
3 invalid/inconclusive/error. Tests and future pipelines must assert expected
nonzero outcomes (e.g. degraded mocks exit 2); never hide all failures with an
unconditional success fallback.

## Approval boundaries

Do not commit, push, merge, delete branches, install services, provision paid
resources, or make infrastructure changes without the user's approval. Local
inspection, implementation, documentation and mock testing requested by the
user may proceed. Finish authorized work and present concrete results for
review before any approval-dependent action.

## Technology responsibilities

Git/GitHub manage source and review; Jenkins will orchestrate CI, approvals and
evidence archiving; Ansible will handle configuration and operational execution;
Terraform will provision suitable provider-supported infrastructure. Do not
force provisioning tooling into configuration tasks or assume a PowerVS
provider manages an existing HMC. Verify actual provider/platform capabilities
when that future work is authorized.
