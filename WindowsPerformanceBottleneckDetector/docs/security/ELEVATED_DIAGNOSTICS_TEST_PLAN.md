# Elevated diagnostics test plan — 0.6.3

This is a repeatable acceptance plan, not a statement that a privileged boundary passed. Production remains 0.6.2 Standard-only. Run unprivileged tests under an ordinary account. Administrator/cross-account/installation tests require a dedicated authorised lab, separate accounts and disposable snapshots; no credentials in scripts, fixtures, logs or source control. Never weaken UAC, antivirus, WDAC/AppLocker or filesystem ACLs to obtain a pass.

Evidence levels: **D** design inspection; **U** deterministic unit/conformance test; **M** mocked failure test (not boundary proof); **W** real non-elevated Windows; **A** real administrator lab; **X** real separate-account/session. Record OS build, protocol/security epoch, binaries' signatures/hashes, token facts, exact test, result and limitations. Redact personal paths/SIDs/account names in published evidence. Keep live diagnostic reports outside git.

## Acceptance matrix

| ID | Repeatable procedure / expected rejection or behaviour | Required evidence |
| --- | --- | --- |
| S01 Protected ACLs | Admin installs proposed broker. Original and second standard users attempt create/write/append/delete/rename, ancestor rename and ACL/owner changes against every executable/dependency/policy. All modifications denied; ordinary read/execute works. Check inherited/group/delete-child access as well as owner. | A/X + effective ACL inventory; not executed |
| S02 Dependency/script substitution | In a disposable test root, substitute each protected DLL, manifest, script/module, runtime/config and active-version pointer using the actual low user. Installer/worker refuse untrusted inventory; never load low-owned content. Do not use harmful payloads. | A/X; not executed |
| S03 Loader integrity | Trace loaded modules/scripts during native token-only and later full scan. Seed harmless marker files in writable CWD/PATH, profile, module paths, startup hooks/profilers and extraction-cache candidates. None loads. Validate sanitised child environment before any privileged managed/PowerShell startup. | A + loader traces; not executed |
| S04 Paths / TOCTOU | Exercise junctions, symlinks, mount points, UNC/device/relative paths, ancestor replacement and concurrent update races. Compare held final file identities. Any unsupported redirection aborts before privilege/data release. | A/X; not executed |
| S05 Pipe rights / integrity | Validate high server ownership, label and exact original-logon read rights; reject network/anonymous/other accounts and other-session same-user clients. Client cannot write data, create instances or alter ACL/owner. Generic-write convenience APIs must not broaden rights. Verify Identifier SQOS and no delegated authority. | A/X + actual security descriptors; not executed |
| S06 Endpoint spoofing | Pre-create the public session name, connect unrelated processes before the relay, supply a fake relay PID, run a same-name EXE elsewhere and inject a false hello/result. No scan/result acceptance without native peer/lifetime/deployment checks. Same-user injection remains a stated compromised-session limit. | A/X; not executed; codec tests are insufficient |
| S07 Process lifetime / PID | Use controlled helper processes that exit/restart; retain original launch/process handles and check creation time/session. A reused numeric PID or stale handle claim must fail. Do not terminate unrelated/system processes. Test actual rights granted by ShellExecute across accounts. | A/X; not executed |
| S08 Replay / state | Replay a full prior transcript; mutate session, request hash, epoch, sequence, progress direction, chunk order and terminal state. Each receiver aborts; no resynchronisation/reconnect or historical report. | U for memory transcript; A/X for real pipe |
| S09 Frame / allocation bounds | Advertise 0, truncated, >64 KiB and UInt32.MaxValue frames; assert oversized lengths rejected before reading a body. Invalid UTF-8, BOM, comments, duplicate/unknown fields, excessive depth, non-integer/coerced types rejected. Fuzz under resource budget. | U; transport I/O deadlines require A |
| S10 Complete result | Wrong declared size/digest, lost/duplicate chunks, >32 KiB decoded chunk, malformed base64, wrong result schema, false elevation fields or missing completion must not save a report. Enforce operation-specific and total budgets without truncation. | U for token probe; A/X for diagnostic reports |
| S11 Arguments | Unknown/duplicate flags, scripts/commands/shell/path/output/privilege/service/kill requests, noncanonical GUID/integers, invalid duration/interval/profile fail before collection. No environment-variable expansion or fallback. | U; real protected launch requires A |
| S12 Output paths | Attempt destination/path/handle injection in CLI and frames; none is accepted. Worker performs no report/temp file writes. UI saves only under its ordinary token with CreateNew and partial-pair rollback. Check original-user ownership. | U/D; Standard W; privileged return path A/X not executed |
| S13 Malicious presentation | Process/provider strings containing markup/control characters, huge strings or invalid report fields remain encoded/bounded; no executable link/action/deserialisation. Historical schemas stay readable without fabricated evidence. | Existing production U; new privileged output A not executed |
| S14 Install/update/removal | Verify publisher/product/inventory and protected staging. Interrupt updates, keep a scan active, roll back, inject low-user files and remove both optional package and desktop in approved order. No permissive repair/custom action; uninstall behaviour explicit. | A/X; existing installer configuration unchanged, lifecycle not repeated |
| S15 Downgrade / offline trust | Older signed insecure epoch, revoked/expired/unapproved publisher, incompatible UI/relay/worker protocol, cold revocation cache and offline deployment must follow approved fail-closed policy. Restore approved versions without lowering the security floor. | A; not executed |
| S16 Native UAC / accounts | Ordinary non-admin; split-token admin; separate local support-admin credentials; domain support-admin if policy permits; wrong credentials; Cancel; policy denial; Administrator protection; multiple sessions. Desktop stays medium, worker checks actual primary token, no stored account identity/secret and no retry mechanism. | W Standard done; A/X elevation not executed |
| S17 Cancellation / exit | Cancel while sampling/analysis/transfer; UI closes; relay self-exits; worker self-exits; lost pipe; late UAC approval. Incomplete data discarded, no orphan continuing beyond deadline. Peer exit is cancellation, never another privileged operation. | U terminal-state subset; Standard W; A/X not executed |
| S18 Timeouts / resources | Stall connect, reads and providers; exceed frame/count/result/heap/time budgets; close job/handles after owned-child failure. Absolute watchdog cannot be extended by chatty progress. Exact owned-child cleanup only, no caller PID termination. | A + fault-injection harness; not executed |
| S19 Production preservation | Build desktop; run all existing PowerShell/.NET tests and a real Standard scan/cancel. Verify unavailable Elevated and launch rejection. Diff src/desktop/installer/VERSION against 9135515; no experimental reference/payload or installer rebuild. | D/U/W; results below |
| S20 Privacy | Inventory every returned field, including embedded usernames in paths/group keys/errors. Approve minimisation/redaction policy before high metadata is returned. No administrator account-name/credential fields. Assume compromised original user can read returned data. | D; actual elevated dataset review A/X not executed |

## Commands for this milestone

From the project directory, using Windows PowerShell 5.1/Pester 3.4.0 and .NET 10:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\WPBD.Tests.ps1 -EnableExit"
dotnet build .\desktop\WPBD.Desktop\WPBD.Desktop.csproj -c Release
dotnet run --project .\desktop\WPBD.Tests\WPBD.Tests.csproj -c Release
dotnet run --project .\experiments\elevation-protocol\Elevation.ProtocolLab.csproj -c Release -- --self-test
```

The process-only policy override is a test-launch choice where already organisationally permitted; it changes no machine policy. Do not apply it to a future privileged worker design. Optional existing Standard live checks:

```powershell
dotnet run --project .\desktop\WPBD.Tests\WPBD.Tests.csproj -c Release -- --live .\desktop\artifacts\win-x64-062\Engine --allow-process-policy-override
```

Use the published engine only after its source hashes match the current production source. Do not reuse an old engine as evidence for changed production code. Live checks write to an original-user temporary folder, not the repository. No native UAC/credential prompt is involved in these commands.

## Recorded 0.6.3 evidence

- Fresh source review/ACL inspection: current installed 0.6.2 payload remains original-user owned/writable; protected-install test S01 therefore remains **not performed**, not passed.
- Existing desktop Release build: passed, zero warnings/errors.
- Existing PowerShell suite: **124 passed**.
- Existing .NET suite: **21 passed**, plus the missing-engine check. Final real Standard run used the freshly built engine after every engine source hash was checked against the repository: **15/15 samples**, 15 valid CPU samples, original-user report ownership and WPF/HTML permission consistency verified; cancellation exported no partial report. Average sample work 0.1948 seconds; post-sampling insight analysis 0.0863 seconds. This is not an elevated benchmark.
- Isolated protocol harness: **34 conformance checks passed** using memory streams only. No UAC/IPC/process launches occurred. The own-token guard observed a non-elevated Medium-integrity Windows process; this is local W evidence only. Parser/state checks are U evidence and do not establish peer authentication.
- No mocked/native PID, protected-path, pipe-ACL, UAC or cross-account security result is represented as passed. No administrator lab was used.

For every future A/X run, attach the precise binary/source revision and evidence to the corresponding gate. An untested blocker is not an exception allowing enablement.
