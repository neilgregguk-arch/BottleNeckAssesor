# WPBD 0.6.2 — Standard-only foundation; elevated feature incomplete

**Optional elevated diagnostics are not implemented or production-ready. They are disabled in the UI and rejected before worker launch. This package supports Standard diagnostics only.** This follows the prompt's instruction to stop elevation rather than weaken security. It is not a completed implementation of the requested elevated feature.

Baseline: `e1be336` (0.6.1), verified against origin/master. Reviewed 19 November 2026.

## Architecture and trust-boundary finding

The existing installer uses a per-user LocalAppData directory and `PrivilegesRequired=lowest`. The desktop manifest is asInvoker. Its Standard worker is Windows PowerShell launched without ShellExecute, loading external scripts/modules from that installation.

A read-only ACL inspection confirmed that the installed desktop executable is owned by the current user and has a direct current-user write grant. Consequently, a privileged worker cannot simply trust neighbouring scripts, DLLs or a writable checksum manifest. A fixed path or unpredictable pipe name alone does not establish payload integrity or peer authentication. Signing alone would not secure mutable dependencies.

No protected privileged deployment, anchored payload-integrity scheme or authenticated cross-account transport was completed. The release gate is unconditional: Elevated requests fail before engine discovery, event creation, process launch or report output. A worker-looking file cannot activate it. No privileged executable, runas launcher, service, scheduled task, credential form, credential cache or privileged IPC endpoint is shipped. There is no automatic fallback to Standard.

The desktop checks its token on startup and refuses an elevated/high-integrity or unverifiable desktop context. Start it normally. Ordinary installation, report access and removal request no administrator credentials. The existing Standard lifecycle, progress, cancellation and saving remain in use.

## Implemented Standard-mode foundation

- Standard is selected at each startup. Elevated appears as unavailable; the mode is not persisted as a privilege preference.
- Shared `src/WorkerToken.cs` reads the current token's elevation, integrity and administrator-group presence/enabled state. It reads no account names and persists no account SIDs. It does not adjust privileges or enable SeDebugPrivilege. Native buffers and the WindowsIdentity wrapper are disposed.
- Verified high-integrity administrator evidence requires successful inspection, TokenIsElevated, an enabled administrator group and at least High integrity. Missing, partial, coercible-string or fractional-integrity evidence cannot establish this state. A high token observed in a separately launched CLI session is not a successful WPBD UAC request.
- Optional JSON `Permissions` records requested mode, inspection availability/error code, actual token facts, outcome, coverage and limitations. The Standard collector records NotRequested; forged or incomplete evidence cannot become a successful UAC outcome.
- Coverage includes captured/verified identities, executable paths, service associations, existing attribution, restricted metadata, error groups and sampling counts. Percentages use captured identities, not every process on the machine. Zero-denominator percentages remain null. Service coverage means captured identities with a recorded association, not all services discovered.
- WPF/HTML show mode and expandable coverage. History reads at most 8 KiB from the header, avoiding large sample arrays. Legacy reports without permission evidence say not recorded. HTML encodes the displayed evidence.
- Token inspection/helper initialisation occurs before the existing sampling baseline, with separate `CollectionTiming.TokenInspectionSeconds`. No additional CIM queries were added; metadata enrichment, classification thresholds, provisional identities and Teams/WebView2 attribution remain unchanged.

Microsoft defines token elevation in [TOKEN_ELEVATION](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-token_elevation), separately from group membership, and describes medium/high integrity in [Mandatory Integrity Control](https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control). These are native token facts, not administrator-name checks.

## Release gates before enabling elevation

The following are outstanding requirements, not implemented or validated security guarantees:

1. Establish trusted worker deployment and dependency integrity, including every module/runtime dependency it can load. Require anchored trust, canonical/reparse-safe paths and substitution/TOCTOU protection. Resolve protected-component installation/removal against the requirement for ordinary non-elevated UI/uninstall.
2. Implement a fixed, narrowly scoped worker accepting only validated WPBD configuration/session arguments. No script path, command text or privileged output-path argument may be accepted. Avoid sensitive command-line collection and process-memory access.
3. Authenticate both IPC endpoints against Windows-backed identity and the exact launched process lifetime. Do not trust a client-supplied PID or random name. Require session binding, local-only restricted access and bounded schemas, frames, sequences and total results.
4. Validate cross-account/cross-integrity ACLs and impersonation/SQOS. The non-elevated UI must not acquire executable high-token authority. CurrentUserOnly is not a solution for a different administrator account. See [Named Pipe Security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights) and [Client impersonation/SQOS](https://learn.microsoft.com/en-us/windows/win32/ipc/impersonating-a-named-pipe-client).
5. Return validated results to the original UI for saving. Do not accept general privileged output paths. Avoid privileged temporary files, or require restrictive permissions, reparse-safe creation and safe cleanup.
6. Implement bounded startup/IPC/collection timeouts and handling for UAC denial/cancellation, crashes, connection loss, cancellation and UI close. Validate real same-account and separate-account scenarios before enabling the feature.

No UAC, named-pipe, PID-authentication or cross-account security claim is inferred from mocked tests. There is no privileged transport in this build. A future design must also state its boundary for a compromised same-user UI process.

## Visibility and limitations

Current metadata can be unavailable because of access denial, provider failure, exits or lookup budgets. Reason codes preserve these distinctions. A future elevated worker may improve paths, creation/parent evidence and service associations where Windows allows it, but cannot promise access to every protected/PPL process. No elevated coverage improvement was measured. No identity is upgraded solely because an administrator might have better visibility.

## Validation

- **124/124 PowerShell regressions passed:** all 115 previous checks plus nine permission-evidence checks. Original diagnostic, identity, Teams/WebView2, aggregation, presentation and null-handling expectations remain.
- **21/21 .NET checks passed**, plus the existing missing-engine check. Negative tests cover default/invalid modes, the unavailable gate despite a worker-looking file, partial/forged token proof, fractional integrity, the high-token desktop guard and bounded/legacy/malformed history headers.
- **Real Standard Windows test:** non-administrator, medium-integrity context; 15/15 samples, 15 valid CPU samples, zero missed. Actual worker elevation and administrator-group presence were false. Report ownership matched the original user. WPF/HTML permission summaries and every coverage label/value matched. Cancellation after a real sample produced no partial report.
- **WPF layout:** actual controls/resources rendered in an STA harness at sizes corresponding to 1366x768 at 100%, 125% and 150%, with expanded evidence. Standard selection, unavailable Elevated and the harness's actual unprivileged token were checked. Physical OS scaling, accessibility and a live high-token GUI launch were not tested.
- **Compatibility:** schemas 0.1–0.3 load without invented permission evidence. Same-input 0.6.1/current replay retained identical original findings, advisories, assessments, statistics, applications, attribution and DiagnosticInsights. The added version/permission/timing fields are intentional.
- **Packaging:** self-contained Release x64 publish and Inno Setup build succeeded with the existing AppId/per-user locations. Final payload files are checked against source/build. No privileged executable is packaged. The full upgrade/uninstall lifecycle was not repeated.

### Requested scenario matrix

| Scenario | Actual status |
| --- | --- |
| Standard default / no UAC | Implemented; unit and real Standard run |
| Trusted privileged worker / strict arguments | Not implemented; Elevated always rejected before launch |
| Arbitrary scripts through elevation | No elevation execution endpoint; gate tested, privileged parser not implemented |
| IPC sessions, unauthorised peers and bounds | Not implemented; no privileged IPC endpoint |
| UAC cancellation, incorrect credentials or policy denial | Not executed; UAC is not requested |
| Elevated crash, timeout or connection loss | Not implemented/tested |
| Token inspection | Real Standard token and synthetic malformed/partial proof tested; real high token not tested |
| Original-user saving / sampling cancellation | Real Standard run passed |
| Privileged temporary paths | Not introduced; protected privileged storage not implemented |
| Identity/enrichment safeguards | Standard regressions passed; elevated enrichment not implemented |
| Historical compatibility / mode reporting | Unit and real Standard checks passed |
| Admin-account elevated run / separate admin credentials | Not executed |
| UI close during elevated scan | Not implemented; Standard close/cancel path retained |
| Installer upgrade / existing reports | Configuration identity preserved, historical loading tested; full lifecycle not repeated |

This matrix does not satisfy the optional-elevation acceptance criteria.

## Coverage and performance

The recorded Standard run captured 320 identities: 157 verified (49.1%), 157 with paths (49.1%), 133 with service associations (41.6%), attribution coverage 87.5%, and 163 restricted-metadata identities. One error group was recorded. These describe that captured population. There is no elevated comparison and no attribution-improvement claim.

Token inspection/initialisation took 0.1280 seconds before sampling. Collection work averaged 0.3849 seconds per sample at a 2-second interval; insight analysis took 1.2869 seconds afterward. These are one host/run, not matched Standard/elevated benchmarks. The timed sampling loop is unchanged.

Controlled five-sample combined-resource replay, after one warm-up and six measured iterations per version: mean post-analysis 0.0475 s (0.6.1) versus 0.0551 s (0.6.2); HTML formatting 0.0492 s versus 0.0519 s. The small added coverage work is outside sampling. No extra enrichment query is performed because Elevated appears as unavailable.

## Versioning and package

Release **0.6.2**; classification engine **0.6.0**, unchanged; schema **0.3** with additive optional Permissions/token-inspection timing. Historical evidence is never synthesized on load.

- `WPBD-Setup-0.6.2-x64.exe` — **Standard-only; elevation incomplete**.
- Usual directory: `C:\Users\NGregg\OneDrive - ARK-H Handling Ltd\Documents\ChatGPT\Windows Performance Bottleneck Detector\WindowsPerformanceBottleneckDetector\installer\artifacts`
- Size: **46,510,996 bytes** (44.36 MiB)
- SHA-256: `7ebe52c49d4e00a224e3af3cb3038a5df95aead89456f943708208b373714527`
- Adjacent checksum supplied; installer remains unsigned. Application-control policies may block PowerShell/helper compilation; permission evidence then remains unavailable.

The privileged worker, protected deployment, authenticated IPC and real elevation tests remain outstanding. Do not deploy this as completed elevated diagnostics. No administrator credentials were collected, no security policy was changed and no privileged process was started by the new feature. Generated live reports/test artifacts stay outside source control.
