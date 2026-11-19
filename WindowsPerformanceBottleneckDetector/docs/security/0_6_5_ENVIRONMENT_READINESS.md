# 0.6.5 environment readiness — privileged environment gate CLOSED

19 November 2026; source baseline `b3afc6e`. Read-only observations on the existing workstation, **not an approved disposable administrator lab**. No development tools, accounts, VM, policy or protected software were installed/configured. This record contains only redacted capability facts, not a workstation/configuration export or administrator identifiers.

| Prerequisite | Observed / available | Unavailable or unverified |
| --- | --- | --- |
| Windows | NT version **10.0.26300**, x64 process | Supported test-build matrix not established |
| .NET SDK | **8.0.428, 10.0.303**; managed experimental builds run | SDK presence does not establish Native AOT native prerequisites |
| MSVC / linker | vswhere C++ component query returned **zero instances**; cl/link/lld-link/clang/clang-cl not on PATH | Native toolchain unavailable in inspected installation/PATH locations; no exhaustive disk search or installation attempted |
| Windows SDK | Expected Windows Kits 10 Include/Lib directories absent | Windows headers/libraries/SDK linker not established |
| Native AOT | .NET SDK supports the workflow | No cached AOT runtime pack detected in inspected dotnet packs; no native publish attempted or native executable produced |
| Build/signing tools | Ordinary .NET builds available | cmake and signtool not on PATH; no native toolchain build/loader evidence |
| Signing capability | Read-only CurrentUser/LocalMachine My-store metadata found **zero code-signing EKU certificates**, zero key associations | No approved signer, timestamp/offline revocation policy, package-authorisation anchor or authorised unsigned-lab exception; private keys were not opened/exported |
| Test-process authority | Native primary token: inspection succeeded, elevation **false**, integrity RID **8192 (Medium)**, administrator group present **false**, enabled **false** | No administrator token available to this test process. No credentials requested; separate administrator authority not established |
| UAC | Existing EnableLUA and secure-desktop observations enabled | Actual consent, credentials, cancellation, policy denial and late approval untested |
| VM | No Get-VM command or vmms service detected | This does not prove no VM exists elsewhere; no approved disposable VM/snapshot/recovery or authority to configure one established |
| Distinct accounts | Only the current non-elevated process was inspected | No authorised separate support administrator/second standard-user test session established; no account names/SIDs enumerated or retained |
| Application control | DeviceGuard query returned kernel CI status 2, user-mode status 0; AppIDSvc stopped and local SrpV2 key absent at inspection | These coarse signals do **not** prove WDAC/AppLocker/endpoint controls absent or permit unsigned software. Effective policies, enforcement exceptions and enterprise deployment rules unverified |
| Independent review | Review brief/source prepared | No independent reviewer or security acceptance obtained |

## Methods and reproducibility

Windows version/build from Win32_OperatingSystem; SDK versions from `dotnet --list-sdks`; MSVC from vswhere requiring `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`; command availability with Get-Command; expected Windows Kits/dotnet pack locations checked read-only. Certificate metadata queries were limited to code-signing EKU/count and HasPrivateKey association, never certificate identities/private material or a signing operation. DeviceGuard/status and relevant UAC/service/registry presence were read, with no policy export or modification. An absent inspected component is reported as undetected, not proof it cannot exist in a custom location.

The redacted own-token/known-folder probe is repeatable **without elevation**:

```powershell
dotnet run --project .\experiments\elevation-worker\Readiness\Readiness.csproj -c Release -- --inspect
```

It requires an actual non-elevated Medium primary token. It serialises only token booleans/integrity and known-folder success; transient account/logon/image details remain in memory. `authorisesElevation=false` is explicit. Machine/lab approval cannot be established by a JSON flag, SID claim or administrator-group membership.

## Environment decision

**No approved administrator-controlled test environment is available for this milestone.** Continue only non-privileged source development, review and safe tests. Do not launch UAC, install/copy protected components, create accounts, configure a VM, install tools or weaken policy. Genuine protected-file modification attempts, native privileged execution, cross-account IPC and admin-controlled removal remain unexecuted release blockers. The managed publish/deployment gates remain closed.

Native C++ source added in this milestone is **uncompiled and undeployed**. A reviewer must supply approved tooling in a disposable lab, build and inspect the actual PE/import/load configuration and validate the complete dependency inventory before any elevated execution. Microsoft's [Native AOT prerequisites](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/) require the Windows C++ toolchain; an installed .NET SDK alone is insufficient. The [review brief](0_6_5_INDEPENDENT_REVIEW_BRIEF.md) lists the missing evidence. No environment approval can close production G01–G12 by itself.
