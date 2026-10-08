# Project context

Last updated: 2026-10-08. This is the durable project handover; update it as work
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
* No actual AIX LPAR is currently available. Current Windows validation uses
  standalone Python 3.14.8 and Git Bash with Unix utilities; earlier tests used
  bundled Python 3.12. KornShell/AIX testing is pending.

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
An opt-in `HEALTH_PROFILE=boot-readiness` adds rootvg/hd5/normal bootlist checks
as named functions in the same script. It runs all baseline checks and raises
the existing VG/LV category for additional findings. `standard` is the default.
The 31-field `KEY=value` summary contains metadata, component statuses, nine
metrics, PowerHA state and overall status/code. The comparator consumes these
summaries without executing their contents. Inventory and playbooks remain
placeholders; Ansible and Terraform integration is not implemented yet. A local
Windows Jenkins Pipeline checks out the repository, runs the mock test suite,
and archives its test log. The root `Jenkinsfile` is published and the Jenkins
job loads it from Git; SCM-backed build #6 passed the then-current 41 tests. See
`jenkins-windows-lab.md` for setup, job configuration and limitations.

## Decisions and current behavior

* Preserve the existing collection engine; use localized fixes and regression
  tests rather than an unnecessary rewrite.
* The user chose a middle ground for expansion: one shell script, named
  functions and optional assessment profiles. No module loader or plugin system
  is introduced. Boot readiness is the first opt-in addition, implemented from
  IBM command semantics without copying the vendor UHC scripts supplied for
  comparison.
* `BOOT_MIN_COPIES` (1 by default; 1/2/3 accepted) applies to distinct hd5 boot
  candidates, not whole-rootvg mirror coverage. Boot findings raise the existing
  `VG_LV_STATUS`; they cannot erase earlier faults. New collectors treat failed,
  empty, malformed or unsupported evidence as UNKNOWN and retain raw output.
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
6. Phases 1–4 were committed as `173f07f`, merged into main as `cdcd576`, and both
   branches were pushed and verified. The user then approved exploring Jenkins
   on Windows first, with a separate RHEL installation to follow. Jenkins LTS
   2.568.3 and a dedicated Java 21.0.12.1 runtime have been installed locally.
   Browser setup is complete and the user is learning through guided builds.
7. User-supplied Jenkins logs confirm all 41 tests passed without skips in the
   Windows Freestyle job (169.811 seconds), then in the inline Pipeline. Pipeline
   build #4 passed in 154.242 seconds and archived `all-tests-4.txt`, confirmed
   by the user's screenshot. These were mock tests, not real AIX validation.
8. The user authorized preparing the root `Jenkinsfile`. It uses `checkout scm`,
   validates Windows/Python/Bash, preserves test failure exit codes, and archives
   the current build's test log in the Tests stage's `post always` block. It
   disables concurrent builds and applies a ten-minute timeout. Publication and
   the SCM switch were subsequently completed in milestone 10 below.
9. Local validation of the prepared Jenkinsfile: the running Jenkins Declarative
   validator accepted it. Its exact batch blocks passed in a temporary project:
   41 tests in 104.409 seconds, no skips, with the expected report file. A
   separate intentional failing test returned batch exit 1 and retained its
   failure log. Python compilation, Bash syntax and Git whitespace checks
   passed. Failed-build artifact archiving remains unverified in Jenkins itself.
10. On 2026-10-07, the user approved finishing the Jenkins milestone. Commit
    `7df4b88` published the Jenkinsfile and lab documentation to main. The local
    controller was started, the previous inline job configuration backed up,
    and `aix-reliability-pipeline` switched to Pipeline script from SCM, using
    `*/main` and `Jenkinsfile`. Build #5 completed SUCCESS: 41 tests passed in
    53.367 seconds with no skips, and `all-tests-5.txt` was retrieved from the
    build's archived artifacts and verified. Python compilation and Bash syntax
    checks also passed. This completes the Windows mock CI milestone.
11. Standalone Python 3.14.8 was installed by the user and verified locally on
    2026-10-07. All 41 tests passed with this runtime in 52.267 seconds, without
    skips. Commit `275e42a` updated the Jenkinsfile and lab guide; the user
    approved its push and Jenkins execution. Build #6 checked out that commit,
    reported Python 3.14.8, and passed all 41 tests in 50.457 seconds without
    skips. Its archived `all-tests-6.txt` was retrieved and verified.
12. On 2026-10-08, the user authorized the single-script/profile design. The
    optional boot-readiness profile and isolated fixture tests are implemented
    locally. It assesses rootvg PV/LV state, complete contiguous hd5 copies,
    normal bootlist membership, device availability and reported boot capability.
    Detailed findings and suggested actions remain in the text report; the
    summary retains 31 fields and 15 component statuses. Final local validation
    passed all 65 tests (24 new) in 147.436 seconds using Python 3.14.8 and Git
    Bash, without skips. Python compilation, Bash syntax and tracked/untracked
    whitespace checks passed. Default healthy/degraded runs matched published
    HEAD's exit codes and all 30 non-timestamp summary fields. Review also found
    and fixed acceptance of hd5 partition numbers beyond a disk's capacity,
    with regression coverage. The user approved committing and pushing this
    reviewed addition on 2026-10-08; consult Git history for the publication
    state. Verification through the SCM-backed Jenkins job remains pending.

## Remaining limitations

* No real AIX, KornShell, HMC, VIOS, storage or PowerHA platform validation yet.
* Boot readiness does not verify boot-image contents/freshness, individual path
  reachability, firmware boot success, whole-rootvg redundancy or storage
  failure-domain independence. WPAR/VIOS, alternate-OS disks and unsupported
  boot policies are inconclusive. Profiles and copy policies are text-report
  metadata only; keep them identical for comparison. Different faults inside
  an already degraded VG/LV category cannot be distinguished by the comparator.
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
  to deploy. Jenkins currently orchestrates mock tests and archives their logs;
  it does not yet retain the temporary mock health reports or perform live
  change orchestration. No automated approval gate, HTML/PDF reporting or
  observability integration exists yet.
* Windows Jenkins builds run on the built-in node in a local learning lab.
  The user installed standalone Python 3.14.8 on 2026-10-07; the published
  Jenkinsfile uses it, verified by successful Jenkins build #6.
  A separate execution agent remains future work. Archiving after a failed
  test has been configured but not yet demonstrated by a failing Pipeline run.

## Agreed next steps (not authorization to implement)

1. Commit/push approval for the reviewed boot-readiness addition was received
   on 2026-10-08. Next verify it through SCM-backed Jenkins when authorized.
   Validate native command output, permissions and KornShell on a test AIX LPAR
   when available.
   Additional profiles require separate scope; the vendor UHC breadth is not
   a commitment to implement every check.
2. Windows mock CI and the standalone Python migration are complete. Discuss a
   separate execution agent, fail-on-skip/empty-suite protection, build retention
   and a controlled failed-build archiving demonstration. Keep teaching one
   step at a time; production readiness is not established by mock CI.
3. Set up the separate RHEL Jenkins lab when authorized and VM access is
   supplied. Later extend CI to retain mock health
   reports and comparisons as well as test logs. A correctly detected degraded
   mock must pass its test rather than fail the entire pipeline unexpectedly.
4. Introduce Ansible, prepare the RHEL automation controller and add inventories
   and playbooks. Evaluate the IBM Power AIX collection for later real targets.
5. Introduce Terraform for an appropriate provisioning lab, then investigate
   IBM PowerVS and suitable on-premises automation. Verify provider support;
   do not assume PowerVS tooling manages an existing HMC.
6. Integrate approved components into a complete workflow and progressively add
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
without the user's approval. Commit/push/merge approval for Phases 1–4 was
fulfilled. The user subsequently approved installing Jenkins on this Windows
computer for learning. On 2026-10-07 the user approved publication and completion
of the Jenkins milestone; its Jenkinsfile and documentation were committed and
pushed. This does not authorize unrelated infrastructure changes.
