# Project context

Last updated: 2026-09-26. This is the durable project handover; update it as work
progresses. Use Git status/history and actual implementation to verify details
that can become stale. Development instructions are in `../AGENTS.md` and the
operational contract is in `runbook.md`.

## Objectives

Build an enterprise-oriented Infrastructure Reliability and Change Automation
Framework around AIX and IBM Power: read-only health assessment, pre/post-change
comparison, actionable reporting and retained change evidence. Preserve the
owner's existing infrastructure expertise while building practical skills in
Python, shell, Git, CI/CD, configuration management and infrastructure as code.
The project should be useful operationally and demonstrate engineering judgment
in a professional portfolio.

## Repository and environments

* Repository: `Griffin1108/aix-reliability-automation` on GitHub.
* Phases 1–4 were developed on `feature/aix-health-comparison`, starting from
  `dfe97a1` (comparison placeholder). Engine upgrade `3a18c7e` was merged through
  PR #1 (`eaa6ca0` on main). Consult Git history for the current publication and
  merge state; the user has approved committing, pushing and merging this work.
* Windows checkout: `C:\Users\tkamb\Documents\aix-reliability-automation`.
* User's RHEL lab checkout: `/home/tkambasha/aix-reliability-automation`, in a
  VMware Workstation VM. Earlier healthy/degraded mock success on RHEL was
  reported by the user; current review validation runs locally on Windows.
* No actual AIX LPAR is currently available. Windows validation uses bundled
  Python 3.12 and Git Bash with Unix utilities. KornShell/AIX testing is pending.

## Current architecture

```text
Real AIX collectors OR deterministic healthy/degraded mocks
    -> scripts/aix_healthcheck.sh (KornShell health engine)
    -> reports/<host>_<timestamp>_<label>.txt + .summary
    -> scripts/compare_aix_health.py (standard-library Python)
    -> text/JSON comparison + automation exit code
```

The engine collects system/LPAR evidence and evaluates 15 check categories:
software integrity, performance, paging, filesystems, VG/LV, PV, devices, MPIO,
disk I/O, errpt, network, services, NTP, dump configuration and PowerHA.
The 31-field `KEY=value` summary contains metadata, component statuses, nine
metrics, PowerHA state and overall status/code. The comparator consumes these
summaries without executing their contents. Inventory and playbooks remain
placeholders; no Jenkins, Ansible or Terraform integration is implemented yet.

## Decisions and current behavior

* Preserve the existing collection engine; use localized fixes and regression
  tests rather than an unnecessary rewrite.
* `MOCK_HOSTNAME` defaults to `mock-aix01` independently of healthy/degraded
  profile, and is used consistently for the local node's reported identity.
* Unsafe labels and invalid mock settings are rejected. Existing report OR
  summary filenames cause explicit exit 3. Exclusive creation protects against
  concurrent same-name runs. Retry later or use a different label after a
  collision; evidence is not automatically renamed or silently overwritten.
* Non-AIX real-mode execution exits 3, reports no checks executed, and marks
  every component and overall health UNKNOWN.
* Evaluate each of the 15 statuses once. `OVERALL_STATUS` is validated as an
  aggregate, never added to individual comparison counts.
* A worsened component or increased failed MPIO count is a regression, even if
  overall health was already CRITICAL. Unknown/missing evidence cannot establish
  success. Unresolved baseline faults remain separately visible, including
  faults whose resolution is unverified because a later result is UNKNOWN.
* Raw performance metric deltas are informational. AIX version and vCPU changes
  require review; an AIX version change is not automatically a health regression
  or improvement. Decimal subtraction avoids ordinary rounding artifacts and
  integer counts retain precision.
* The input schema is deliberately strict. Extension/versioning is future work;
  current summaries do not record thresholds, settings or provenance.

| Scenario | Outcome | Comparator exit |
| --- | --- | --- |
| Healthy to healthy | UNCHANGED | 0 |
| Degraded to degraded | UNCHANGED; baseline faults require review | 1 |
| Degraded to healthy | IMPROVED | 0 |
| Healthy to degraded | REGRESSED | 2 |
| Improvement with residual faults/configuration review | IMPROVED; review required | 1 |
| Invalid input or incomplete/UNKNOWN evidence | INVALID_INPUT or INCONCLUSIVE | 3 |

## Milestones and verification

1. Initial lab/Git workflow and AIX health engine developed; health engine merged
   through PR #1.
2. Phases 1–4 implemented: repository/schema inspection, shared mock identity,
   Python comparison CLI, validation, automated tests and runbook.
3. Initial 31-test suite passed locally. Direct original-versus-modified engine
   comparison matched both profile return codes and all 29 fields excluding
   hostname and timestamp.
4. Final engineering review added collision protection, all-UNKNOWN unsupported
   captures, explicit unresolved-baseline reporting, numeric validation fixes,
   and expanded regression tests. All 41 tests passed on Windows/Python 3.12/Git
   Bash in 93.324 seconds, with no skips. Python compilation, Bash syntax, and
   Git whitespace checks (including all new files) passed. Python 3.8 syntax
   was checked, but runtime testing used Python 3.12 only. A fresh comparison of
   the final engine against original HEAD again matched both mock profile exit
   codes and all 29 fields excluding hostname and timestamp.
5. Durable project context and repository development instructions added from
   the user's handover. The user subsequently approved committing, pushing and
   merging the reviewed implementation into main.

## Remaining limitations

* No real AIX, KornShell, HMC, VIOS, storage or PowerHA platform validation yet.
* Existing collectors can substitute defaults or lack collection-failure
  indicators; a comparator cannot recover evidence missing from its inputs.
  Optional checks can report OK when not required. Collector hardening remains
  separate future work; `COLLECT_ENTSTAT` is declared but not implemented.
* Summary data lacks per-resource inventories/details, effective thresholds,
  configuration fingerprint, schema version and mock/real provenance. Equal
  hostnames alone do not prove comparable collection conditions.
* Local timestamps have no timezone; clock changes can affect ordering.
* Captures are not transactional: interruption/write failures may leave partial
  evidence. Retain and check collection exit codes, use a trusted report
  directory and never treat an incomplete capture as successful evidence.
* A healthy comparison is not proof of application readiness or authorization
  to deploy. No orchestration, automated approval gate, HTML/PDF reporting,
  observability integration or evidence archive service exists yet.

## Agreed next steps (not authorization to implement)

1. Final engineering review is complete and publication is approved. Complete
   and verify the commit, push and merge into main; use Git history to establish
   completion before repeating any publication actions.
2. Discuss the first Jenkins pipeline: checkout, automated tests, healthy and
   degraded mock collection, pre/post comparisons, expected exit-code assertions
   and evidence archiving. A correctly detected degraded mock must pass its
   test, rather than make the entire pipeline fail unexpectedly.
3. Introduce Ansible, prepare the RHEL automation controller and add inventories
   and playbooks. Evaluate the IBM Power AIX collection for later real targets.
4. Introduce Terraform for an appropriate provisioning lab, then investigate
   IBM PowerVS and suitable on-premises automation. Verify provider support;
   do not assume PowerVS tooling manages an existing HMC.
5. Integrate approved components into a complete workflow and progressively add
   reporting, evidence retention and observability as separately scoped work.

Git manages source/review; Jenkins orchestrates; Terraform provisions supported
resources; Ansible configures and executes operations; shell/Python assess and
compare health. These are distinct responsibilities, not mandatory stages of
every future job. Do not begin another phase solely because it appears here.

## Collaboration and approval boundaries

Act as an engineering partner and mentor: discuss practical tradeoffs, explain
how new technologies connect to infrastructure work, and distinguish tested
facts from assumptions. Preserve capabilities, avoid unsupported success claims
and keep this documentation synchronized. Do not commit, push, merge, delete
branches, install services, provision paid resources or change infrastructure
without the user's approval. The user has explicitly approved committing,
pushing and merging Phases 1–4. This does not authorize implementing another
phase or making infrastructure changes.
