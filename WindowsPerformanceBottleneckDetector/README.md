# Windows Performance Bottleneck Detector

## 0.6.5 experimental milestone — partial implementation/validation (B)

Added [environment readiness](docs/security/0_6_5_ENVIRONMENT_READINESS.md), uncompiled [native token/refusal source](experiments/elevation-worker/native/README.md), a redacted own-token readiness probe, stricter shared descriptor validation and [independent review/install/removal preparation](docs/security/0_6_5_INDEPENDENT_REVIEW_BRIEF.md). The environment gate remains closed: no approved disposable administrator lab, native toolchain or signing authority was established. Work was limited to non-privileged source, inspection and tests; no tools/accounts/VM/policies were installed or configured.

Native compilation, protected deployment, working elevated TokenProbeV1, genuine UAC, High/cross-account IPC and protected removal are **not validated**. Descriptor tests validate content only. Production remains **0.6.2 Standard-only** with unchanged engine, rejection gate and installer. See [the 0.6.5 report](docs/security/MILESTONE_0_6_5_REPORT.md) for exact evidence and open gates.

## 0.6.4 experimental milestone — partial proof of concept (B)

The isolated [worker experiment](experiments/elevation-worker/README.md) adds native Windows token/process observations, real **Medium-to-Medium** named-pipe tests using the unchanged 0.6.3 protocol validator, and fail-closed relay/worker refusal entry points. It does not implement a working elevated token probe, protected package or UAC launch. Native build tooling and a disposable multi-account administrator lab remain prerequisites; protected installation/removal, High endpoint ownership and authenticated cross-account communication are unvalidated blockers.

**Production remains 0.6.2 Standard-only**, with the unconditional elevation gate, installer, sampling/classification and report formats unchanged. Experimental builds stay outside production and cannot be published as protected relay/worker packages. No new installer is built. See [the 0.6.4 report](docs/security/MILESTONE_0_6_4_REPORT.md) for actual tests, limitations and next steps.

## 0.6.3 security architecture milestone

The architecture work is documented in [the threat model](docs/security/ELEVATED_DIAGNOSTICS_THREAT_MODEL.md), [architecture decision](docs/security/ELEVATED_DIAGNOSTICS_ARCHITECTURE.md), [IPC specification](docs/security/ELEVATED_DIAGNOSTICS_IPC_PROTOCOL.md), [test plan](docs/security/ELEVATED_DIAGNOSTICS_TEST_PLAN.md) and [release gates](docs/security/ELEVATED_DIAGNOSTICS_RELEASE_GATES.md). The conditional recommendation is a per-user desktop plus a separately protected relay/one-scan worker package, with native UAC and a worker-owned read-only results pipe.

The isolated [protocol-conformance lab](experiments/elevation-protocol/README.md) tests in-memory bounds, schemas and state transitions only. It creates no pipe, launches no process and demonstrates no privileged boundary. Protected deployment, authenticated native IPC, separate-account UAC and the protected component's installation/removal policy remain release blockers. A compromised same-user desktop session is not assumed trustworthy.

**The shipped application remains 0.6.2 Standard-only.** No production source, sampling/classification rule, rejection gate or installer is changed by this milestone. No 0.6.3 installer is built and experimental code is not shipped. See [the milestone completion report](docs/security/MILESTONE_0_6_3_REPORT.md) for evidence and implementation phases.

**WPBD 0.6.2 is a Standard-only permissions foundation. Optional elevated diagnostics remain incomplete and disabled.** The desktop does not request UAC or ship a privileged worker. The existing user-writable deployment is not being elevated without a completed trust-boundary design.

WPBD presents evidence-based troubleshooting insights in concise summaries and readable tables in the Windows desktop app and offline reports, alongside process identity and attribution quality. WPBD samples CPU, physical memory, paging, physical disk I/O and processes, then reports evidence that may explain a workstation slowdown. The read-only engine runs in Windows PowerShell 5.1 with the Windows CIM and Event Log providers. It requires no agent, external PowerShell module or internet connection.

## Install WPBD

Copy `WPBD-Setup-0.6.2-x64.exe` to a compatible workstation and double-click it. Setup installs the app for the current user under `%LOCALAPPDATA%\Programs\WPBD`, adds a Start menu shortcut and offers an optional desktop shortcut. Select **Launch Windows Performance Bottleneck Detector** at the end of Setup, or open WPBD from Start.

The installer bundles the self-contained .NET 10 desktop runtime and diagnostic scripts. The target needs native x64 Windows 11 or a Windows 10 edition supported by .NET 10, Windows PowerShell 5.1, and write access to the user's local application data. Setup works offline and runs with current-user permissions. Your organisation's application-control and script policies still apply. [Microsoft .NET Windows support](https://learn.microsoft.com/dotnet/core/install/windows#supported-versions)

To upgrade, finish or cancel the active diagnostic, close all WPBD windows, and run the newer installer under the same Windows account. Setup uses the existing app identity and installation directory. Setup and Uninstall ask you to close a running WPBD instance before replacing or removing files.

To remove WPBD, close it and select **Uninstall** in Windows **Settings > Apps > Installed apps**. Reports and logs remain under `%LOCALAPPDATA%\WPBD\Reports` and `%LOCALAPPDATA%\WPBD\Logs`. Custom report folders are also preserved. Duration, interval and report folder preferences are saved separately in `%LOCALAPPDATA%\WPBD\Preferences.json` when WPBD closes. The process-only script policy override must be selected again after reopening WPBD.

The unsigned installer may trigger a Microsoft Defender SmartScreen warning. Verify it against the SHA-256 published by your distributor and follow your organisation's approval process. With the setup file and its checksum file in the current folder, a technician can verify the bytes with:

```powershell
$name = 'WPBD-Setup-0.6.2-x64.exe'
$expected = ((Get-Content -LiteralPath ".\$name.sha256" -Raw).Trim() -split '\s+', 2)[0]
$actual = (Get-FileHash -LiteralPath ".\$name" -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'Installer SHA-256 mismatch.' }
'Installer SHA-256 verified'
```

### Build the installer

Use the .NET 10 SDK and Inno Setup 6.3 or newer on a Windows build machine. From the project directory:

```powershell
.\installer\Build-Installer.ps1
```

Use `-ISCCPath 'C:\path\to\ISCC.exe'` if the compiler is in a custom location. The build publishes into a fresh staging directory, checks the runtime and engine payload, compiles the EXE and writes a `.sha256` file under `installer\artifacts`. An initial build may need NuGet access to restore the x64 runtime packs. Set `VERSION` for each release. For an isolated upgrade test, use `-VersionOverride 0.5.2 -OutputDirectory <test-output-folder>` and keep the installer AppId unchanged. [Inno Setup downloads](https://jrsoftware.org/inno-setup/downloads)

For production signing, use an organisation-issued Authenticode code-signing certificate and the Windows SDK SignTool. Sign the finished installer and regenerate its checksum from the signed bytes. Use the organisation's certificate thumbprint and RFC 3161 timestamp service. [Microsoft SignTool reference](https://learn.microsoft.com/windows/win32/seccrypto/signtool)

```powershell
$setup = '.\installer\artifacts\WPBD-Setup-0.6.2-x64.exe'
signtool sign /sha1 'CERTIFICATE_THUMBPRINT' /fd SHA256 /tr 'RFC3161_TIMESTAMP_URL' /td SHA256 $setup
if ($LASTEXITCODE -ne 0) { throw 'Installer signing failed.' }
signtool verify /pa $setup
if ($LASTEXITCODE -ne 0) { throw 'Installer signature verification failed.' }
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path -Leaf $setup)" | Set-Content -LiteralPath "$setup.sha256" -Encoding Ascii
```

## Permission evidence in 0.6.2 — elevation incomplete

Standard is the default at every startup. Elevated appears as unavailable in the mode selector. An API request for Elevated also fails before any process is launched; placing a worker-looking file beside WPBD cannot enable it. No credentials, UAC policy changes, SeDebugPrivilege changes, elevated service or scheduled task were introduced. The desktop refuses an elevated/high-integrity launch; start it normally to browse and collect diagnostics.

Standard collection records the actual worker token using Windows token APIs, separately from administrator-group presence/enabled state. It captures no account name or account SID. This read and helper initialisation occur before the existing sampling baseline; time is recorded separately as `CollectionTiming.TokenInspectionSeconds`. Unknown values stay unavailable. A high token observed in a separately launched CLI session does not imply that WPBD requested or successfully completed UAC elevation.

Reports add optional `Permissions` evidence under retained schema 0.3. It includes requested mode, token-inspection availability, token elevation, integrity, group state, outcome, metadata coverage and limitations. Coverage includes verified identities, available executable paths, service associations, attribution, restricted identities, errors and sampling counts. Denominators are captured identities, not the entire machine process population. Independently captured scans cannot establish that elevation alone caused a coverage change. Older reports continue opening with permission evidence marked not recorded.

Findings and HTML show the recorded mode and expandable coverage. History reads at most 8 KiB from each report header to label new reports, without scanning their large sample arrays. Existing findings, insights, Teams/WebView2 ownership and identity rules remain unchanged. The installer retains its per-user AppId, upgrade behaviour, reports, preferences and logs. No privileged executable is included or left behind on uninstall.

See `ELEVATION_SECURITY_REVIEW.md` for the concrete deployment finding, trust boundary, incomplete worker/IPC requirements, test matrix and deployment metadata. **This installer does not fulfil the optional-elevation acceptance criteria.**

## Presentation refinement in 0.6.1

Findings now starts with the recorded overall result, highest-priority insight and its confidence, finding/advisory counts and sampling completeness. Normal operation stays in this overview. An advisory such as elevated memory use appears alongside the no-bottleneck result without creating a second normal-operation card. Existing findings represented by an insight are grouped with it; unmatched and historical findings remain visible.

Each actionable insight shows a short observation and interpretation, measurements in GiB/MiB, percentages, milliseconds or rates, up to five contributors, and up to three ordered investigation steps. Technical expansion retains measurement references, sample slots and UTC window, full statistics, all supplied contributors, process identities, ownership evidence, every recorded recommendation and limitations. The engine's existing five-candidate cap is unchanged; the presentation also handles reports supplying more candidates. A report supplying only one or two investigation steps keeps that count and order. No UI recommendations are generated.

PowerShell HTML formatting and the C# WPF presenter use `src/Presentation-Format.json` for field labels, units and relevant measurement selection. Regression fixtures compare the complete formatted projections across both runtimes. All formatting occurs after sampling or when loading a report. Original measurements, full precision, findings, priorities and insight fields remain intact, including legacy `DetailText` in JSON. The interfaces consume structured evidence instead of rendering that raw string. No schema change was needed: schema 0.3, application release 0.6.1, diagnostic engine 0.6.0. Historical reports retain their recorded version identifiers; absent identifiers remain not recorded.

The offline HTML uses semantic tables, ordered recommendations and native keyboard-accessible details. Tables scroll horizontally on narrow screens and use print styling. The All Processes bottom scrollbar from 0.6.0 is preserved. See `PRESENTATION_REFINEMENT_REVIEW.md` for before/after examples, parity checks, timings, packaging and limitations.

## Diagnostic intelligence in 0.6.0

The Findings tab and offline HTML include **Diagnostic Insights**, ordered by investigation priority. Expand an insight for recorded evidence, selected sample slots, contributor measurements, next steps and limitations. Existing findings remain the engine's authoritative classifications. No additional collection, system queries, external processing or remediation was added.

`src/Diagnostic-Insights.ps1` runs after the established analysis and attribution. C# only loads and displays the recorded insights; it does not infer new diagnoses. Evidence references address report fields, and slots identify the relevant samples within the recorded UTC window. CPU candidates use only above-threshold total-CPU samples. Memory candidates use samples counted as pressure by the existing memory assessment, or the full observation window for elevated utilisation advisories. Application totals reuse complete, same-sample member sums. Individual process statistics remain separate from group totals. Unknown/restricted accounting groups are never described as applications; their measured processes may appear individually with unresolved ownership.

Candidates must have average CPU at least 5% of whole-machine capacity or a peak at least 10%, or at least 256 MiB peak private allocation in the selected samples. Up to five candidates are ranked by measured average, then name and key. These display filters do not change diagnostic thresholds. Coverage counts describe captured measurements, not a percentage of total system work. Attribution confidence describes ownership and remains separate from resource evidence confidence.

Priority rules are deterministic:

| Priority | Rule |
| --- | --- |
| High | Existing Critical severity with High evidence confidence and at least 80% scheduled-sample coverage |
| Medium | Existing Warning/Critical severity with Medium/High confidence; High is capped here below 80% coverage |
| Low | Existing Warning/Critical with Low confidence; or supported logical-processor context |
| Informational | Normal operation, elevated use without established pressure, coverage limitations and cross-resource context |

Severity is the existing finding's condition level; priority is investigation urgency/usefulness. High insight confidence is capped at Medium below 80% valid scheduled samples. Minimum assessable coverage and sustained thresholds still come from the original engine. Large allocations do not increase confidence or establish causation. CPU/memory and CPU/disk context requires shared qualifying sample slots and existing resource findings; it never adds a severe finding or changes the bottleneck classification. Memory/paging context is included in the memory evidence, avoiding a duplicate problem. Low capacity remains distinct from disk I/O latency. Throughput and active time alone cannot trigger I/O pressure.

Normal reports contain one concise normal-operation insight unless the existing engine also produced an advisory or supported logical-processor context. Missing counters remain unavailable. The HTML header now reports recorded application, engine and schema versions separately, with absent historical versions labelled not recorded.

Schema **0.3 is retained**: `DiagnosticInsights`, `ApplicationVersion`, `EngineVersion` and `CollectionTiming.InsightAnalysisSeconds` are additive optional fields. Each insight records `Id`, title/category, priority/severity/confidence, related finding category, observation/interpretation, measurement references, structured supporting evidence, selected slots and UTC window, contributors, investigation steps and limitations. `DetailText` is retained as a legacy derived field; current WPF and HTML views format the structured fields instead. Old reports without insights retain their original findings and show no invented historical insight. The current application release is 0.6.2 and the unchanged diagnostic engine is 0.6.0; neither is the schema version.

See `DIAGNOSTIC_INTELLIGENCE_REVIEW.md` for validation, timings, controlled examples and limitations.

## Desktop app

### Attribution refinement in 0.5.1

When sampled creation time is inaccessible, enrichment requires matching PID, CIM creation time and process name in inventories before and after the entire observation range. The sampled identity remains provisional; this does not merge separate observations or upgrade identity verification. Only services present at both boundaries are retained for this match. A service PID with creation evidence can establish **Identified service process** with medium confidence when its executable is inaccessible. Shared hosts list their associated services without inferring a vendor or parent application.

For missing CIM paths, a cached native helper tries `QueryFullProcessImageName` with `PROCESS_QUERY_LIMITED_INFORMATION`, validating native creation time against the CIM identity. Lookups run outside sampling, under a two-second wall-clock budget per inventory, checked before each local call; remaining rows receive `LookupBudgetExceeded`. The helper needs no elevation, performs no process writes and closes every handle. Native compilation occurs once per worker. CIM queries retain their existing two-second operation timeout. [Microsoft process access rights](https://learn.microsoft.com/windows/win32/procthread/process-security-and-access-rights), [QueryFullProcessImageName](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamea)

Actual system directory paths now recognise SearchIndexer, spoolsv, RuntimeBroker, SecurityHealthService and SgrmBroker. Names alone, service configuration paths and paths in unrelated subdirectories cannot establish a Windows component. This is path evidence, not signature verification.

All Processes and HTML show reason codes, metadata matching and image-path sources. `AccessDenied` requires an observed denial; absent optional fields alone produce `PathUnavailable`. Other codes include `CreationTimeUnavailable`, `MetadataIdentityUnavailable`, `ProcessExited`, `IdentityMismatch`, `LookupUnavailable`, `LookupBudgetExceeded`, `ParentUnavailable`, `ServiceMetadataUnavailable` and `OwnershipUnresolved`. Accessibility reasons can remain present on an identified service. Service lookup failure is independent of process image access.

Schema 0.3 is retained with additive optional fields: metadata `Name`, `Phase`, `CapturedUtc`, `CimPath`, `PathSource`, `PathStatus`, `ServiceLookupStatus`; process `MetadataIdentityMatch`, `AttributionReasons`, `ImagePathSource`; quality `IdentifiedServices`, `ApplicationAndWindowsPercent`, aggregated `AttributionReasons`; and collection `ProcessMetadataBefore`, `ProcessMetadataAfter`, `AttributionAnalysisSeconds`. Each inventory reports total seconds, image lookup seconds and lookup count. Image time includes helper compilation; analysis time includes process statistics, grouping and quality calculations. Historical schemas 0.1–0.3 remain readable without invented boundaries, reasons or ownership. Older 0.3 readers can omit the new optional evidence. `AttributedPercent` and unattributed memory now include the separate service category as explained above.

See `ATTRIBUTION_REFINEMENT_REVIEW.md` for the actual failure investigation, comparable replay results and performance measurements. Diagnostic thresholds and the two-second default sampling interval are unchanged.

### Processes and applications

**All Processes** supports search by name, PID, path, service, category or application. Filters select ownership categories, restricted metadata, verified or provisional identity, and available CPU or memory measurements. Numeric columns sort by measured value. Process rows show individual peaks across the observed window.

**Applications** groups identical executable paths and WebView2 descendants whose parent identities establish a chain to a host executable. Microsoft Store Teams is labelled Microsoft Teams when its executable is ms-teams.exe inside an MSTeams package path. Other hosts keep their executable names and paths. A command-line WebView host executable hint can reject inconsistent ownership. A name, PID, WebView2 runtime location or user-data folder alone cannot establish ownership. Expand a group for its processes and evidence.

Process and service metadata are queried before sampling and after it. Enrichment uses PID and creation time with microsecond precision to accommodate CIM timestamps. Parent creation must precede child creation. Service names are associated only where a matching process creation time predates the service inventory. Commands are queried transiently and only the WebView host executable hint is retained. The package directory is recorded where the executable path exposes it, without claiming a separate package API lookup.

Verified identities use PID and process creation time. When creation time is inaccessible, a provisional key tracks the same PID/name over consecutive captured observations. An observed absence, name change, cumulative CPU regression or conflicting accessible path ends continuity. A transition between verified and provisional evidence also starts a separate identity. Missed scheduling slots alone do not prove a process disappeared. Replacement between consecutive captures with identical PID/name and inaccessible lifetime metadata can be undetectable. Provisional CPU deltas remain unavailable, while measured memory is retained.

Ownership category, identity verification and metadata access are separate fields. **Identified application** uses a matching executable path or a verified WebView2 ancestry. **Windows system process** requires an actual Windows system directory path plus a recognised Windows component filename. Associated service names provide additional evidence. A similarly named executable elsewhere remains grouped under its own path. **Protected or restricted process** requires an observed access-denied error and no established owner. **Unattributed application process** has an accessible path but insufficient host ownership, such as orphaned WebView2. **Unknown process ownership** lacks the required evidence. A known Windows component can separately show restricted metadata. These categories convey evidence and access quality.

Application memory totals sum members present in each sample, then calculate the maximum of those aligned totals. A missing measurement from any present member makes that metric's total unavailable for the sample. Complete-sample counts appear in the Applications view. These totals are based on sequential process reads within a capture, so they are not an atomic Windows memory snapshot. Processes that start and exit entirely between captures remain unobserved.

Private bytes are committed private allocation and can include paged-out memory. Working set includes shared and private resident pages, so summing working sets can count shared pages repeatedly. Task Manager commonly displays private resident working-set accounting and can use different grouping and refresh timing. WPBD does not collect private resident working set, so its application totals may differ from Task Manager's memory column. [Microsoft memory accounting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-application-service-memory-leaks), [WebView2 process model](https://learn.microsoft.com/microsoft-edge/webview2/concepts/process-model)

The attribution summary reports verified/provisional identities, distinct PIDs, total observations and maximum concurrent captured processes. Application groups similarly distinguish unique identities, observations and peak concurrent membership. Complete group CPU samples sum member CPU percentages and report their arithmetic mean and maximum. A member with unavailable CPU makes that group's CPU total unavailable for the sample. Attribution confidence describes ownership evidence independently from performance measurements. Restricted metadata counts can overlap known Windows or application categories. Overall attributed coverage is identified application plus Windows system plus identified service identities divided by all identities. Service-only evidence is counted separately and never presented as a known application or publisher. ApplicationAndWindowsPercent retains the original application-plus-Windows numerator for direct comparison with 0.5.0. Unattributed private-memory footprint combines the remaining three categories in each sample before taking its peak.

Report schema 0.3 records the changed identity semantics explicitly. Existing measurements and leader fields remain, with additional identity status, metadata access, parent PID, associated services, package directory, application category and attribution confidence. Raw process samples include the generated instance key. `AttributionQuality` contains counts and same-sample unattributed memory. `Applications` gains CPU statistics, unique identity count, observation count, concurrent membership and confidence. The desktop reads schemas 0.1, 0.2 and 0.3. Historical records retain their recorded identity rules and attribution, with unavailable quality shown explicitly. Older versions need upgrading to read schema 0.3. Diagnostic classification thresholds are unchanged.

The root-cause review is in `PROCESS_IDENTITY_REVIEW.md`. The reproducible Pester dataset `New-IdentitySamples` captures four processes over 15 samples, including two without start times.

| Quantity | Previous per-slot identity rule | Version 0.5 |
| --- | --- | --- |
| Unique identity records | 32 | 4 |
| Unverified/provisional identity records | 30 | 2 |
| Captured observations | 60 | 60 |
| Peak concurrent processes | 4 | 4 |
| Complete combined private memory | 100 MiB | 100 MiB |

These are synthetic regression inputs. The identity count correction preserves same-sample memory accounting. Windows can still restrict metadata, and enrichment can miss short-lived processes between inventories.

### Build and run

From the project directory containing `Start-WPBD.ps1`, use the .NET 10 SDK on Windows.

```powershell
dotnet build .\desktop\WPBD.Desktop\WPBD.Desktop.csproj -c Release
.\desktop\WPBD.Desktop\bin\Release\net10.0-windows\WPBD.Desktop.exe
```

The desktop app targets Windows 11 and Windows 10 editions supported by .NET 10. Framework-dependent builds require the .NET 10 Desktop Runtime. The app runs with the current user's permissions and needs write access to the report directory. [Microsoft .NET Windows support](https://learn.microsoft.com/dotnet/core/install/windows#supported-versions)

### Publish and deploy

```powershell
dotnet publish .\desktop\WPBD.Desktop\WPBD.Desktop.csproj -c Release -r win-x64 --self-contained true -o .\desktop\artifacts\win-x64
.\desktop\artifacts\win-x64\WPBD.Desktop.exe
```

Copy the entire `win-x64` output folder to the target workstation, including its `Engine` subdirectory, then double-click `WPBD.Desktop.exe`. The published folder includes the .NET runtime. The target uses Windows PowerShell 5.1 supplied by Windows. Development output and published output both resolve the engine relative to the executable.

### Diagnostic workflow

1. Choose 30 seconds, 60 seconds, 2 minutes or 5 minutes, and a 1-, 2-, 5- or 10-second interval. Reports default to `%LOCALAPPDATA%\WPBD\Reports`. Use **Choose folder** to direct reports to an existing writable location.
2. Select **Start Diagnostic**. The Dashboard shows completed samples, elapsed sample time, live CPU and memory, available RAM, and disk activity and latency. Graphs use elapsed sample times from the engine. Breaks indicate unavailable measurements or skipped slots. Use the slider or arrow keys on the focused slider to inspect a sample across all four graphs. The storage chart uses the highest measured read or write latency across disks. Expand the activity row for per-disk values.
3. Review **Findings** after collection. Severity, advisory status and confidence are written out. The coverage summary identifies incomplete evidence. Use **Processes** to sort the engine's ranked process rows by CPU, private memory or working set.
4. Use **Reports** to open the paired HTML report, open the selected reports folder, load a history entry or browse to a saved JSON report. History lists WPBD JSON files in the selected folder. The app can load schema 0.1, 0.2 and 0.3 reports. A missing HTML companion leaves JSON review available.
5. Select **Cancel Diagnostic** during collection or analysis. The app retains the partial timeline for inspection and presents a cancelled status. Once report writing begins, export is allowed to finish.

### Integration and troubleshooting

`WPBD.Desktop` contains the WPF views, chart control and view model. `WPBD.Core` handles validated configuration, asynchronous worker execution, report parsing and history. The PowerShell worker imports the packaged module by absolute path into a fresh profile-free process. The desktop app passes arguments directly to the Windows PowerShell executable. The worker emits one UTF-8 JSON object per line with protocol number `1`, a `Type` and `Data`. Event types are `phase`, `sample`, `completed`, `cancelled` and `error`. The sample events contain a projection from the same measurements written to the report. JSON schema 0.3 supplies the completed assessment and attribution quality.

Cancellation signals a private, session-local Windows event checked by the worker. If a worker fails to respond to cancellation within 15 seconds before export, WPBD can stop that specific child process. Report export is handled by the original PowerShell engine. App logs are stored in `%LOCALAPPDATA%\WPBD\Logs` and opened using **Logs**. Errors show a short message and expandable technical details.

- **Scripts blocked**. Check organisational policy. Where allowed, **Allow process-only script policy override** applies `-ExecutionPolicy Bypass` to the worker for that run. Group Policy takes precedence.
- **Engine missing**. Copy the entire publish folder from the same build.
- **Measurement unavailable**. See **Findings** for coverage and collection errors. Protected processes or Windows providers can limit results.
- **Invalid or missing report**. Browse to a complete WPBD JSON file. To open HTML, keep the generated HTML with the matching basename beside it.

The deployment described here targets native x64. Read-only access to counters, process details and logs depends on Windows permissions and provider availability. Windows 10, clean-machine installation and physical display scaling outside the development workstation need deployment validation.

## Run a diagnostic from Windows PowerShell

Open Windows PowerShell, switch to the directory containing `Start-WPBD.ps1`, then run the command while the slowdown is occurring.

```powershell
.\Start-WPBD.ps1 -DurationSeconds 60
```

If the local execution policy blocks the script and your organisation permits it, launch a separate PowerShell process with a process-scoped setting.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-WPBD.ps1 -DurationSeconds 60
```

| Parameter | Default | Behaviour |
| --- | --- | --- |
| `-DurationSeconds` | 60 | Sampling window in whole seconds, from 1 through 3,600. |
| `-SampleIntervalSeconds` | 2 | Nominal interval in whole seconds, from 1 through the selected duration. |
| `-OutputPath` | `reports` beside the script | Report directory. Relative paths resolve from the current PowerShell location. The directory is created at export if needed. |
| `-NoReport` | Off | Returns the diagnostic object without creating any report files or directories. |

Start with a standard user account. Local Windows permissions control access to performance providers, executable paths and the System log. The report records provider failures and indicates unavailable measurements. The destination requires write access when exporting. WPBD makes no registry, service, process, or other system configuration changes. Use Ctrl+C to cancel. Cancellation during sampling exits without exporting the interrupted session.

## Findings and thresholds

Findings contain the observed condition, an interpretation, supporting measurements and investigation steps. Severity describes the condition and confidence reflects the available evidence for the stated interpretation. Several findings can appear in one run.

The default sustained rules require at least three qualifying samples and at least 60% of usable samples. An assessment also needs at least three usable samples and 60% of scheduled samples. Very short runs can return useful measurements with insufficient coverage for classification. Qualifying samples can occur anywhere in the sampled window.

| Finding | Starting rule |
| --- | --- |
| CPU bottleneck | Total CPU utilisation exceeds 85% in sustained samples. |
| Memory pressure | Sustained reduced or critically low headroom and corroborating evidence in the same samples. See the memory rules below. |
| Disk I/O bottleneck | For a physical disk, average latency is at least 25 ms and the same direction records at least 5 operations/s in sustained samples. Active time and queue length provide context. |
| Low disk capacity | A fixed volume has less than 10% free space. Less than 2% is critical. Free space and I/O latency are assessed independently. |
| Multiple potential bottlenecks | Findings in two or more of the four categories above. Each finding retains its own evidence. |
| No clear bottleneck detected | All four assessment areas had sufficient coverage and their finding criteria were not met. An elevated memory advisory can accompany this result. |
| Insufficient diagnostic data | A metric or volume lacked enough evidence. This can accompany findings in areas where coverage was sufficient. |

Thresholds are starting values and can be overridden when calling the analysis function. A threshold override affects only that call and the applied values are included in the report.

```powershell
Import-Module .\src\WPBD.psm1
Get-WpbdThresholds
$measurements = Get-WpbdMetrics -DurationSeconds 60 -SampleIntervalSeconds 2
$diagnostic = Get-WpbdAnalysis -Metrics $measurements -ThresholdOverrides @{ MemoryElevatedUsedPercent = 88; DiskLatencyMs = 40 }
Export-WpbdReport -Diagnostic $diagnostic -OutputPath .\reports
```

### Memory assessments

| Classification | Rule with default thresholds |
| --- | --- |
| Normal memory operation | Sufficient physical memory measurements with no sustained elevated-use or pressure pattern. |
| Elevated memory utilisation | Physical utilisation of at least 85% (`MemoryElevatedUsedPercent`), 1 GiB or less available (`MemoryElevatedAvailableBytes`), or tighter headroom thresholds below. Sustained elevation appears as an informational advisory when the pressure rules do not qualify. |
| Potential memory pressure | At most 768 MiB (`MemoryPressureAvailableBytes`) or 8% (`MemoryPressureAvailablePercent`) available, or critically low headroom, with corroboration in the same sample. The relative rule also requires at most 2 GiB available (`MemoryRelativeHeadroomCapBytes`). Sustained potential pressure is a warning finding. |
| Severe memory pressure | Below 500 MiB available (`AvailableMemoryBytes`) or at most 1% (`MemorySevereAvailablePercent`, subject to the same 2 GiB cap), and at least 90% physical utilisation (`MemoryUsedPercent`), with corroboration in the same sample. Sustained severe pressure is a critical finding. |
| Insufficient memory data | Physical use and available RAM measurements, or the evidence needed during low headroom, lacked sufficient coverage. An independently supported elevated-use advisory can still appear. |

Corroboration means commit at 90% or more (`CommitPercent`), at least 10 page reads/s (`PageReadsPerSecond`), or at least 50 pages input/s (`PagesInputPerSecond`). Both pressure rules count only samples where headroom and corroboration coincide. When the qualifying samples lack either commit or paging coverage, confidence is lower. Severe pressure reaches high confidence when both elevated commit and elevated paging sustain alongside critical headroom. The finding describes the measured pressure and its possible effect on responsiveness.

Use the absolute thresholds to catch tight headroom on smaller systems. Relative thresholds scale with OS-visible RAM, and the 2 GiB cap keeps several GiB of available RAM on larger systems from triggering a pressure finding on percentage alone. The 85% threshold surfaces sustained high utilisation early. The pressure bands are configurable starting points for workstation triage. Installed memory is reported separately and is never used as the headroom denominator. [Microsoft guidance on memory performance counters](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-performance-problems-in-windows)

An example advisory might read:

> **Overall assessment** No clear bottleneck detected.
>
> **Advisory** Elevated memory utilisation. Average physical use was 86% and available RAM dropped to 1.50 GiB. Review private-memory leaders and correlate paging with the reported slowdown.

An example finding might read:

> **Finding** Severe memory pressure, Critical. Available RAM remained below 500 MiB during sustained high physical use with elevated commit and paging in the same samples.

## Measurements and reports

The CLI writes two UTF-8 files with the same filename stem containing the computer name, UTC start timestamp and a unique suffix. Existing reports are preserved. Open the HTML file directly in a browser. It contains no external resources. The JSON includes the configuration, thresholds, system information, timestamped samples, statistics, findings and structured collection errors. It uses `null` for unavailable numeric measurements and zero for measured zero activity. Reports can contain computer and process identifiers and executable paths.

- **CPU** uses successive raw processor counter readings to measure busy time. The JSON includes per-logical-processor samples where supported. System averages are arithmetic means of available samples. The percentage above threshold uses available total CPU samples as its denominator. [Windows processor counter guidance](https://learn.microsoft.com/en-us/windows/win32/perfctrs/collecting-performance-data)
- **Process CPU** is the difference in cumulative CPU seconds across consecutive observations of the same PID and start time, divided by elapsed sampling time and logical processor count. One fully utilised logical processor on a four-logical-processor workstation accounts for 25% of machine capacity. Process average CPU is weighted by the length of its observed intervals. Cumulative CPU in the diagnostic sums observed deltas only.
- **Memory** uses bytes in JSON and binary units (MiB and GiB) in HTML. Commit utilisation uses the sampled commit limit. Page reads/s counts read operations that resolve hard faults and pages input/s counts the pages read. File-backed reads can contribute to both. Page output/s, free and zero page list bytes, and modified page list bytes provide context from the same query where available. These counters do not attribute activity to the pagefile. [Microsoft guidance on hard faults and pagefile counters](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/how-to-determine-the-appropriate-page-file-size-for-64-bit-versions-of-windows)
- **Process memory** reports peak private bytes and peak working set separately. Private bytes measure private allocation, which may be paged out. Working set measures resident pages and can include shared pages. Consecutive provisional identities are grouped using the rules above. Each process ranking uses a distinct verified or provisional identity.
- **Storage** measures read and write rates as operations/s and bytes/s. Latency is reported in milliseconds and each average is weighted by the number of completed operations. An idle interval can have zero IOPS with unavailable latency. Active time is calculated from the idle-time counter and queue length is a count of outstanding requests at the sample. Drive sizes and free bytes are queried for fixed logical drives after sampling. [Physical disk raw counter reference](https://learn.microsoft.com/en-us/previous-versions/aa394308(v=vs.85))

### Sampling and reliability

- The baseline doubles as the initial CPU provider selection. WPBD tries Processor Information first and falls back to Processor if the baseline lacks a usable total counter. It caches a successful source, retries a transient failure, and probes the alternate on the next slot after two consecutive failures. Each timed sample queries one CPU provider. A provider change or missing endpoint requires a new pair before CPU utilisation is available. Non-advancing timestamps, backward idle counters and impossible idle rates leave utilisation unavailable.
- The sampling clock starts after the baseline. The last capture starts at or after the requested duration, so the actual duration can run slightly longer. When several slots become due, WPBD records the skipped slots and captures the latest due slot with its real timestamp. The report distinguishes previous collection exceeding a deadline from delayed scheduling.
- Sampling quality shows scheduled, collected, missed and valid counts. The HTML summary reports sample work against the chosen interval with provider timing below it. Process and disk coverage counts indicate samples with at least one available measurement in the named category. Disk latency can be unavailable in a valid idle I/O sample.
- Timings measure elapsed work, including provider calls and sample conversion. They do not measure WPBD's share of machine CPU usage. The JSON separates inventory, baseline, timed sample work and post-sampling inventory. Performance queries request a two-second CIM timeout. Timeout handling depends on the Windows provider. Optional provider errors are grouped by source and code. Critical System event queries run after sampling.

### JSON compatibility

Schema `0.3` retains the established measurement and diagnostic fields from schema `0.2`, including `Advisories`, `MemoryAssessment`, `SamplingQuality` and `CollectionTiming`. `Assessment.AdvisoryCount` counts advisories. Memory pressure findings retain `Category = 'Memory pressure'` and `Classification` for the potential or severe tier. Process identity and quality changes are described above.

Samples add the scheduled offset, CPU provider, CPU status and measured CPU interval, collection timing and optional memory context. `Configuration.ProcessorCounterClass` is the most recent successfully selected provider. Compare sample-level provider names to see which provider was queried at each point. `StartedUtc` and `ActualDurationSeconds` describe the window after baseline collection. `SamplingQuality.MissedSampleCount` counts skipped slots. A `MissedSlots` collection error counts overrun or scheduling incidents, which can span multiple slots.

`Statistics.Memory.PressureSamples` and `PressureWithPagingSamples` include both potential and severe qualifying samples. The severe subset has its own count. Relative headroom and supporting measurements have individual coverage counts. `Statistics.Processes.ObservedInstances` now counts distinct verified and provisional identities. Observation counts are reported separately. Other measurement keys keep their shapes. Missing measurements remain JSON `null`.

## Limitations

- Results describe the selected window. A short or unrepresentative run can miss intermittent problems. Total CPU saturation can miss a workload constrained to one logical processor. Check the per-processor time series for that case.
- Process CPU requires two valid observations. Protected processes and processes that start or exit between samples can have incomplete measurements. Executable paths are resolved after sampling for matching processes still running.
- Physical disk data uses Windows provider instances. Virtual machines and storage controllers expose the counters visible to Windows. Ideal latency varies by device, workload and storage stack.
- A short interval and long window can produce a large JSON file on machines with many processes. The engine retains samples in memory until analysis and export finish.
- Available paging counters cannot identify the files responsible for hard faults. A slow or unavailable CIM provider can reduce coverage, and a provider timeout may extend a sample.
- The engine runs locally. The module returns structured objects for a future frontend.

## Run the tests

From Windows PowerShell 5.1 in the project directory, check for Pester and run the suite. Pester 3.4.0 is the verified version.

```powershell
Get-Module -ListAvailable Pester
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Script .\tests\WPBD.Tests.ps1
```

If Pester is absent, obtain Pester 3.4.0 through your approved PowerShell module source and rerun the commands. Test setup uses synthetic inputs. The diagnostic engine uses live providers for collection.

The .NET regression runner checks configuration, versioned reports, progress, advisories, missing data, filesystem history and errors without external test packages.

```powershell
dotnet run --project .\desktop\WPBD.Tests\WPBD.Tests.csproj -c Release
```

To verify actual Windows collection and cancellation, publish the app first, then pass the published engine folder to the runner. The live checks write a report pair to a temporary folder.

```powershell
dotnet run --project .\desktop\WPBD.Tests\WPBD.Tests.csproj -c Release -- --live .\desktop\artifacts\win-x64\Engine
```

Where organisational policy permits a process-only script policy override, append `--allow-process-policy-override` to the live test command.
