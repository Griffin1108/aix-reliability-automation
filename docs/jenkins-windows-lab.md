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
whitespace checks also passed. Actual Jenkins archiving after a test failure
still needs a controlled demonstration.

On 2026-10-07 the Jenkinsfile was published to main in commit `7df4b88`. The
existing job was switched to Pipeline script from SCM after backing up its
inline configuration locally. Build #5 completed SUCCESS: all 41 tests passed
in 53.367 seconds without skips. The archived `all-tests-5.txt` was retrieved
and its results verified directly. No actual AIX target was involved.

The published Pipeline initially used Codex-bundled Python 3.12.14. On
2026-10-07 the user installed standalone Python 3.14.8 (64-bit), verified at
`C:\Users\tkamb\AppData\Local\Programs\Python\Python314\python.exe`.
The published Jenkinsfile sets `PYTHON_EXE` to that dedicated installation.
Build #6 checked out commit `275e42a`, reported Python 3.14.8, and passed all
41 tests in 50.457 seconds without skips. Its archived `all-tests-6.txt` was
retrieved and verified. Using an
explicit path avoids relying on the controller's inherited PATH or Store aliases.
Local compatibility validation with Python 3.14.8 passed all 41 tests in
52.267 seconds without skips; this was not a Jenkins build.
Git Bash is set through `AIX_TEST_BASH` to
`C:\Program Files\Git\bin\bash.exe`. Tests add the required Unix utilities to
their child processes' PATH. This Jenkinsfile targets this Windows lab only.

## SCM configuration (completed)

The existing job now loads the published Jenkinsfile. These are its settings
and the steps to reproduce the configuration:

1. Open `aix-reliability-pipeline` -> Configure -> Pipeline.
2. Set Definition to **Pipeline script from SCM** and SCM to **Git**.
3. Set Repository URL to
   `https://github.com/Griffin1108/aix-reliability-automation.git`.
4. Use Credentials **none** for the currently working public checkout.
5. Set Branch Specifier to `*/main`.
6. Set Script Path to `Jenkinsfile`, save, and select **Build Now**.
7. Verify Jenkins loads the Jenkinsfile from SCM, runs all 41 tests without
   skips, and archives `all-tests-<build number>.txt` with SUCCESS.

Do not paste this SCM-based file into the inline script field: `checkout scm`
requires the job's SCM context. The previous inline configuration was retained
in `%TEMP%\aix-reliability-pipeline-before-scm.xml` for local recovery.

## Sources

* [Jenkins standalone WAR installation](https://www.jenkins.io/doc/book/installing/war-file/)
* [Jenkins Java support policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/)
* [Jenkins Windows service alternative](https://www.jenkins.io/doc/book/installing/windows/)

The service-based installation can be considered later if automatic startup is
desired. Keep a dedicated service account and controller/agent separation in
mind when moving beyond a single-user lab.
