# 0.6.4 partial proof of concept — not a protected worker package

0.6.5 remains **B — partial implementation/validation**. Added `Readiness --inspect`, 21 `PolicyTests` checks and a shared descriptor validator now used by actual Medium read-back. The High candidate is parsed in memory only, never created as an endpoint. Added [native C++ refusal source](native/README.md), which is **uncompiled and undeployed**; 17 native compile-time assertions are pending, not passing tests. See [environment readiness](../../docs/security/0_6_5_ENVIRONMENT_READINESS.md), [independent review brief](../../docs/security/0_6_5_INDEPENDENT_REVIEW_BRIEF.md) and [0.6.5 report](../../docs/security/MILESTONE_0_6_5_REPORT.md). The approved admin environment gate remains closed; nothing here authorises elevation or installs tools/accounts/VMs/policies. The test script now builds five managed projects; native build settings are separate and untested.

**Classification B: partial proof of concept.** Real Windows transport and refusal tests run under an ordinary Medium token. No protected installation, elevated token, UAC, high-owned endpoint or cross-account security boundary has been demonstrated. Production remains 0.6.2 Standard-only. Do not install, elevate or distribute these managed build outputs as a privileged worker.

## Implemented

- Native primary-token queries, limited-query/synchronisation-only retained process handles, creation time/session/image observations and kernel pipe endpoint PID/session checks. Account and logon identities are used only in memory, never returned/logged.
- Windows known-folder resolution independent of the caller's `ProgramFiles` environment variable.
- Medium-only outbound overlapped byte pipe with first-instance/local-only flags, one instance, explicit logon read rights, Medium no-write-up label and native descriptor read-back. Client opens only read rights with Identification SQOS. No impersonation API is used.
- Separate-process ordinary-user transport lab; reuses `../elevation-protocol/Protocol.cs` unchanged for exact schemas/state validation. Native PID correlation, protocol validity and session authorisation are checked separately. These are user-writable lab images, not approved protected images.
- Refusal-stage worker: canonical TokenProbeV1 request parser, own primary elevated/admin/high check and unconditional protected-deployment gate. It has **no active token-result endpoint**. Relay `--probe` verifies its own Medium context/known folder and refuses before any UAC/launch. These entry points do not implement the successful elevated path.

## Build and run, without elevation

Requires Windows x64 and .NET 10 SDK. From the project directory in an ordinary-user PowerShell:

```powershell
& .\experiments\elevation-worker\Test-Experiment.ps1
dotnet run --project .\experiments\elevation-protocol\Elevation.ProtocolLab.csproj -c Release -- --self-test
```

Do not change machine execution policy to run tests. Build outputs stay under the five managed experimental projects' ignored `bin/obj` directories, outside production. `Worker` and `Relay` deliberately block `dotnet publish`; no publish/config/environment option opens the deployment gate. Removing that gate requires a reviewed implementation, not a switch. The fixtures can start **only their own fixed lab executable**, non-elevated, with fixed test-mode arguments; the worker/relay contain no process launch, arbitrary command execution or administrative control.

Each transport fixture has a five-second read deadline (400 ms for the idle test); the supervisor has an eight-second deadline. It does not kill arbitrary PIDs. Child disconnect/EOF and `using` release process/pipe/token handles. The protocol caps frames at 64 KiB, token result at 4 KiB, chunks at 32 KiB and sessions at 4096 frames. Tests require terminal completion and EOF; incomplete/error/cancelled/malformed transcripts never succeed. These fixture deadlines do not implement the future high worker's supervision or late-UAC cleanup.

## Installation, inspection and removal

There is **no deployable installer or approved protected inventory**. No protected files, service, scheduled task, registry registration or privileged endpoint are installed by these commands. Inspection consists of reviewing source and running the Medium test suite; descriptor tests inspect their own transient kernel objects. There is therefore no protected installation to uninstall. Ordinary build outputs can be removed with `dotnet clean` per project or by deleting only their `bin/obj` folders after the processes exit.

Future protected installation/removal is limited to a disposable multi-account Windows VM: build a native/AOT token-only package with an approved toolchain; independently review/sign the complete inventory; resolve Program Files via the Windows known-folder API; use administrator-controlled immutable staging and fixed version root; validate effective file/ancestor ownership, deletion/reparse rights and loader paths as both standard accounts. Install/remove only through a fixed, reviewed admin deployment package, never an elevated script receiving caller paths. Record inventory before installation and prove complete authorised removal and no leftovers. **No such installer, signing anchor, update floor or removal proof is implemented here.** Do not copy the current managed prototype to Program Files and treat that as validated deployment.

The current host has no detected Visual C++/Windows SDK native toolchain and no established disposable multi-account admin lab. Native UAC `ShellExecuteExW(runas)` integration is deliberately deferred rather than launched against a user-writable managed build. Separate administrator-account access, High owner/DACL/MIC, loader substitution, protected update/uninstall and genuine process-supervision scenarios remain blocking. No standard-user ACL weakening or PowerShell privileged shortcut exists.

See `../../docs/security/MILESTONE_0_6_4_REPORT.md` and the five security documents for the exact evidence and open gates. Medium results cannot be promoted into privileged authentication evidence.
