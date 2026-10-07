# Standalone Jenkins lab on Windows

The user approved a Windows installation to explore Jenkins before setting up
an independent RHEL instance. This is a local learning controller, installed
using the supported standalone WAR distribution, not the Windows MSI service.

## Installation

* Jenkins LTS: 2.568.3.
* Dedicated runtime: Eclipse Temurin Java 21.0.12.1, Windows x64 JRE.
* Installation directory: `%LOCALAPPDATA%\JenkinsLab`.
* Jenkins data: `%LOCALAPPDATA%\JenkinsLab\home`.
* URL: `http://127.0.0.1:8080`.
* Startup: manual, under the current Windows user; no boot-time service.
* JVM heap: initially 256 MiB, maximum 1 GiB.

The official Jenkins WAR and Adoptium runtime downloads were checked against
their published SHA-256 hashes before execution. Existing Java 8 and the global
Java/PATH configuration were preserved. The launcher binds to IPv4 loopback;
other machines cannot access this instance through the LAN. RHEL installation
and integration with this controller have not been performed.

## Start and stop

Double-click `%LOCALAPPDATA%\JenkinsLab\Start-Jenkins.cmd`, or run:

```powershell
& "$env:LOCALAPPDATA\JenkinsLab\Start-Jenkins.cmd"
```

The launcher detects an already running lab process and refuses an occupied
port. Logs are written under `JenkinsLab\logs`. It creates a process record
containing PID and start time, which the stop launcher checks before stopping
anything. Start the instance again after a Windows restart when needed.

For this learning installation, after builds and configuration writes finish:

```powershell
& "$env:LOCALAPPDATA\JenkinsLab\Stop-Jenkins.cmd"
```

This terminates the dedicated Java process, so do not use it during active work.
Production service management and graceful shutdown procedures are outside this
standalone preview's scope.

## First browser setup

1. Open `http://127.0.0.1:8080`.
2. Read the unlock password locally from
   `%LOCALAPPDATA%\JenkinsLab\home\secrets\initialAdminPassword`, then paste it
   into Jenkins. Do not commit or share this file or the bootstrap logs.
3. Choose **Install suggested plugins**.
4. Create your administrator account in the browser and finish setup, keeping
   the instance URL set to `http://127.0.0.1:8080/`.

Browser setup is now complete. The user has run the `windows-first-job`
Freestyle exercise, the `aix-repository-check` Freestyle test job, and the
`aix-reliability-pipeline` Pipeline job. These use the built-in Windows node.
Repository checkout succeeded without configured GitHub credentials.

Verified locally: the unlock page returned HTTP 200 with Jenkins version
2.568.3, the listener was bound to `127.0.0.1:8080`, both launcher scripts passed
PowerShell syntax parsing, and starting again detected the existing process
instead of creating a duplicate. Stop behavior has not been exercised.

## Pipeline learning milestone

On 2026-09-30, user-supplied console logs showed 41 tests passing without skips
in the Freestyle job (169.811 seconds) and inline Pipeline. Pipeline build #4
passed in 154.242 seconds and archived `all-tests-4.txt`; the user opened that
artifact and supplied a screenshot. This validates mock behavior on Windows
with Git Bash, not actual AIX or KornShell compatibility.

The root `Jenkinsfile` prepares the working workflow for source control. It
uses `checkout scm` so source and Pipeline come from the same configured SCM
revision, with automatic checkout disabled to avoid duplicate checkouts.
It adds a Windows/tool check, serializes builds and sets a ten-minute timeout.
The batch step saves the test exit code before displaying the log. The Tests
stage archives the current build's log even after a test failure; a missing
artifact is an error. Failed-test archiving still needs a controlled Pipeline
demonstration. Temporary mock reports are cleaned up by the tests, not archived.

Local validation of this file: the running Jenkins Declarative validator
returned `Jenkinsfile successfully validated.` Its exact batch blocks ran in
an isolated temporary project: 41 tests passed in 104.409 seconds without skips
and created the expected log. An intentional isolated test failure confirmed
exit 1 and a retained failure log. Python compilation, Bash syntax and Git
whitespace checks also passed. This does not yet establish an SCM-backed job
run or actual Jenkins archiving after a failure.

The Python executable is currently the existing Codex-bundled runtime at
`C:\Users\tkamb\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`.
Jenkins reported Python 3.12.14. `python` resolves to a Windows Store shortcut
and `py` was unavailable, so the Pipeline uses an explicit path. A permanent
setup should use a dedicated Python installation; change `PYTHON_EXE` then.
Git Bash is set through `AIX_TEST_BASH` to
`C:\Program Files\Git\bin\bash.exe`. Tests add the required Unix utilities to
their child processes' PATH. This Jenkinsfile targets this Windows lab only.

## Switch to a Jenkinsfile after publication approval

The file is prepared locally; it is not yet published or loaded by Jenkins.
After reviewing, committing and pushing the approved changes:

1. Open `aix-reliability-pipeline` -> Configure -> Pipeline.
2. Set Definition to **Pipeline script from SCM** and SCM to **Git**.
3. Set Repository URL to
   `https://github.com/Griffin1108/aix-reliability-automation.git`.
4. Use Credentials **none** for the currently working public checkout.
5. Set Branch Specifier to `*/main` after the Jenkinsfile is published on main.
6. Set Script Path to `Jenkinsfile`, save, and select **Build Now**.
7. Verify Jenkins loads the Jenkinsfile from SCM, runs all 41 tests without
   skips, and archives `all-tests-<build number>.txt` with SUCCESS.

Do not paste this SCM-based file into the inline script field: `checkout scm`
requires the job's SCM context. The inline job remains usable until the switch.

## Sources

* [Jenkins standalone WAR installation](https://www.jenkins.io/doc/book/installing/war-file/)
* [Jenkins Java support policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/)
* [Jenkins Windows service alternative](https://www.jenkins.io/doc/book/installing/windows/)

The service-based installation can be considered later if automatic startup is
desired. Keep a dedicated service account and controller/agent separation in
mind when moving beyond a single-user lab.
