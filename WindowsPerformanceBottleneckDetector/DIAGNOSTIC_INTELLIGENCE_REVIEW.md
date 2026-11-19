# WPBD 0.6.0 — Diagnostic intelligence implementation and validation

Validated on 19 November 2026. Baseline: `e3cf0c5` (0.5.1), fetched and matched against origin/master before implementation.

## Changes and architecture

Added `src/Diagnostic-Insights.ps1` as a deterministic post-analysis layer. `Get-WpbdAnalysis` still owns measured statistics, findings, advisories, sustained thresholds, memory classification and application attribution. The insight generator consumes those outputs and existing sample measurements. C# parses the recorded insight payload and presents it without resource reclassification.

Each insight includes a stable ID, category/title, priority, severity, confidence, related finding category, observation/interpretation, structured evidence, report-field references, selected sample slots and report UTC window, potential contributors, investigation steps and limitations. Derived DetailText is recorded once and displayed identically by WPF and HTML; HTML encodes all user/provider text. Insights sort High, Medium, Low, Informational, then stable ID. Findings and attribution remain available unchanged.

The dark-theme Findings tab gains an expandable Diagnostic Insights section. The offline HTML has the same section. The stale HTML version header now distinguishes application, engine and report schema versions. Collection, installer AppId, preference storage, history and log handling are unchanged. No remediation, elevation, cloud processing or extra provider queries were added.

## Rules and investigations

- CPU: use the original sustained total-CPU finding. Rank up to five candidates by average measured CPU in above-threshold samples; display average and peak. Exclude cumulative historical CPU-time rankings from insight evidence. Supported per-logical-processor activity is informational context, never a new total-CPU finding or thread attribution.
- Memory: preserve normal, elevated, potential pressure, severe pressure and insufficient-data assessments. Reuse the existing per-sample pressure counts to select contributor windows. Evidence includes physical use, available bytes/percentage, commit, hard page reads, pages input/output and sustained counts. Private allocation and working set remain separate; neither identifies a proven cause. Hard page reads do not establish pagefile I/O.
- Applications: reuse same-sample application totals, never sums of individual peaks. Record member identities and their window CPU/memory statistics. Unknown/restricted groups are never invented applications; individual measured processes can appear with unresolved ownership. Ownership confidence and captured-sample coverage remain separate.
- Candidate display filters: average CPU >=5% or peak >=10% of machine capacity, or peak private allocation >=256 MiB. These do not change resource finding thresholds. Sort by measured average, name and application key, taking at most five. Do not infer a share of total system work from partial process coverage.
- Disk: preserve the original latency-plus-directional-workload finding, including latency, IOPS, throughput, activity and queue evidence. High throughput/active time alone is insufficient. State that process-level disk attribution is unavailable. Capacity is separate inventory evidence and has no invented timed sample slots.
- Cross-resource: require actual shared qualifying slots and existing findings for CPU/memory or CPU/disk context. Context is informational correlation, not an independent problem or causal claim. Memory/paging corroboration stays within memory evidence. Elevated use and low capacity do not create unsupported pressure findings.
- Normal/insufficient data: retain concise normal output and repeat-during-symptoms guidance. Coverage gaps receive explicit evidence and limitations; missing measurements remain null. Old reports are not retrospectively diagnosed.

Priority is investigation urgency/usefulness; severity describes the condition; confidence describes evidence strength. High requires existing Critical severity, High resource evidence confidence and >=80% scheduled coverage. Warning/Critical with Medium/High confidence gets Medium otherwise. Warning/Critical with Low confidence gets Low. Logical-processor context is Low. Normal, elevated-use advisories, gaps and overlapping-resource context are Informational. Below 80% valid scheduled coverage, High insight confidence is capped at Medium and High priority is capped at Medium. Established engine findings retain their original confidence.

Investigations ask the technician to review workloads and listed candidates, observe growth, compare controlled repeat runs, inspect storage/controller events and correlate with symptoms. They do not terminate services or security processes or offer executable remediation.

## Controlled fixture examples

These examples are synthetic, not observations about the development workstation.

| Fixture | Recorded insight |
| --- | --- |
| CPU 95% in 5/5 samples | CPU bottleneck; Medium priority, Warning severity, High resource confidence. Candidate process CPU averages 9.375%, peaks 15.625%; without executable evidence it stays ownership unresolved. |
| Same CPU fixture with matching executable identity | A verified application candidate retains High attribution confidence, with individual and group window averages/peaks and 5/5 measured coverage. |
| 256 MiB available, 94% commit, 40 hard reads/s and 200 pages input/s in 5/5 | Severe memory pressure; High priority, Critical severity, High confidence; available RAM 0.25 GiB and physical use approximately 96.9%. |
| 700 MiB available with paging on 8 GiB | Potential memory pressure; Medium priority. |
| 70% physical use with 4.8 GiB available on 16 GiB | Normal memory operation; no memory-pressure warning. |
| Two application members peaking at different times | Aligned peak private allocation 1,100 MiB, not the sum of their unrelated 800 MiB individual peaks. |
| 45 ms read latency and 10 reads/s in 5/5 | Disk I/O insight; Medium priority, with no claimed responsible application. |
| High throughput/100% active time with 1 ms latency | No disk-I/O bottleneck insight. |
| Volume at 1% free, normal I/O latency | Capacity insight only. |
| CPU missing | Low-confidence insufficient-data insight; no healthy CPU conclusion. |

## Validation results

- **PowerShell:** 100/100 Pester 3.4.0 regressions passed under Windows PowerShell 5.1. Existing expectations were retained. Twenty-five new insight regressions cover the requested resource, attribution, quality, consistency, priority and compatibility cases.
- **.NET:** 13/13 regression checks passed, plus the missing-engine error check. New coverage verifies structured insight evidence survives JSON document disposal, preserves nulls and leaves schemas 0.1–0.3 without recorded insights empty.
- **Build/package:** self-contained Windows x64 WPF publish and Inno Setup build succeeded. Release build had zero warnings/errors. Packaging requires the new insight script in the engine payload. Installer AppId and upgrade code are unchanged.
- **Windows integration:** final live run collected 15/15 samples, produced a JSON/HTML pair, verified desktop/report insight text consistency and retained consistent process/application identities. Cancellation after a real sample exported no partial report. Live diagnostics were run through the existing explicitly requested process-only policy override; machine policy was unchanged.
- **WPF layout:** a temporary STA harness instantiated the actual application/resources and Findings view, loaded a controlled report, checked bindings and rendered layouts equivalent to 1366x768 at 100%, 125% and 150%, plus expanded details. Rendered images were inspected for wrapping and scroll access. This is not a claim of physical monitor DPI or interactive accessibility validation.
- **Compatibility/classification:** replay of the same live capture through original 0.5.1 and current analysis produced identical findings, advisories, memory assessment, overall assessment, statistics, applications and attribution. Tests also verify historical export does not invent insight fields and every recorded insight text is HTML-encoded in the report.

## Timing

On the same 15-sample live capture, after one warm-up per version and six measured runs:

| Analysis | Mean seconds | Minimum | Maximum |
| --- | ---: | ---: | ---: |
| Original 0.5.1 | 4.5545 | 4.3928 | 4.8505 |
| With insights | 4.7348 | 4.6261 | 4.8624 |

Mean added post-processing was 0.1803 seconds (approximately 4%). This small replay experiment is not a general benchmark. The timed collection source is byte-for-byte unchanged. Final live collection averaged 0.1806 seconds of work per sample at a 2-second interval; final insight analysis took 0.4543 seconds after sampling. An earlier live run averaged 0.1642 seconds with 0.3392 seconds insight processing. These separate runs demonstrate host variation and are not a matched before/after collection comparison.

## JSON compatibility

Application release: **0.6.0**. Diagnostic engine: **0.6.0**. JSON schema: **0.3**, retained with additive optional fields `DiagnosticInsights`, `ApplicationVersion`, `EngineVersion`, and `CollectionTiming.InsightAnalysisSeconds`. Existing fields and classifications are preserved. The desktop continues reading historical schemas 0.1, 0.2 and 0.3 without generating new historical evidence. Unknown optional fields can be ignored by older schema-0.3 readers.

## Installer

- Filename: `WPBD-Setup-0.6.0-x64.exe`
- Build path: `installer/artifacts/WPBD-Setup-0.6.0-x64.exe` under the project directory.
- Absolute build path: `C:\Users\NGregg\OneDrive - ARK-H Handling Ltd\Documents\ChatGPT\Windows Performance Bottleneck Detector\WindowsPerformanceBottleneckDetector\installer\artifacts\WPBD-Setup-0.6.0-x64.exe`
- Size: **46,488,384 bytes** (44.33 MiB).
- SHA-256: `09831a13f17e5e58083ca6c94a53d4569bc7d27851bfb5bb64d3c71823480715`
- Unsigned self-contained Windows x64 installer; adjacent `.sha256` file provided.

## Known limitations

The Windows computer-use helper repeatedly rejected the new application window binding with a window-ownership error; direct interactive UI review could not be completed. The WPF rendering harness checked binding/layout as described above. Full keyboard/screen-reader testing, physical Windows display scaling, clean-machine and Windows 10 testing remain unverified. The installer was compiled and its payload checked, but the full install/upgrade/uninstall lifecycle was not repeated for 0.6; prior lifecycle results remain documented in installer/VALIDATION.md.

There is no process-level disk attribution, thread/affinity evidence, proven causal application assignment, or private-resident-memory measurement. Process reads are sequential, metadata can be restricted and short-lived processes can be missed. Candidate thresholds are transparent display heuristics, and coverage counts cannot establish complete process workload coverage. Insight-to-process navigation was not added; existing All Processes search and Applications remain available. Short observations cannot rule out intermittent problems. Raw live reports/logs with workstation information were kept outside source control.

## All Processes layout follow-up

The All Processes grid now always shows its bottom horizontal scrollbar. The executable-path column uses a fixed 320-pixel width instead of filling remaining space. A Release build passed with zero warnings/errors, and the actual WPF grid was exercised at 1320-, 1040- and 870-pixel content widths: the scrollbar stayed visible, column widths remained readable and scrolling reached the rightmost columns. Diagnostic logic is unchanged. The installer metadata above reflects the rebuilt package containing this adjustment.
