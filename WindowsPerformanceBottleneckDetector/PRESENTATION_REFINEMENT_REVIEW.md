# WPBD 0.6.1 — Diagnostic Insights presentation refinement

Validated 19 November 2026 against baseline `d6bcc9c` on master (WPBD 0.6.0 including the All Processes scrollbar adjustment).

## Result

The Findings view and offline HTML now have three levels: a compact diagnostic overview, actionable insight cards and expandable technical evidence. Existing resource classifications, prioritisation, candidate selection, contributor ranking and same-sample aggregation are unchanged. All original findings, advisories, measurements and insight fields remain in JSON.

The overview includes the recorded result, highest-priority insight with its recorded confidence, significant-finding/advisory counts and scheduled-sample completeness. Normal operation stays in this summary. Matching findings and advisories are presented with their insight once; unmatched and historical findings still display. Cross-resource context is not counted as an additional significant finding.

Cards show the recorded interpretation, a short observation, relevant measurement tables, up to five application/process candidates and up to three engine-supplied investigation steps in their original order. When the engine supplies fewer steps, that count is preserved. Expanded evidence includes full measurement tables, selected sample slots and UTC window, report references, all supplied candidates, identity/member statistics, attribution evidence, all recommendations and limitations. Extra supplied candidates are supported even though the current engine itself caps its candidate list at five. No process-navigation links were added; existing search and application/process views remain available.

## Architecture and data preservation

`src/Presentation.ps1` formats HTML display values and projects insight data. `desktop/WPBD.Core/InsightPresenter.cs` provides the corresponding cached WPF display projections. Both use `src/Presentation-Format.json` for labels, units and relevant primary measurements. Both explicitly round display midpoints away from zero, avoiding .NET Framework/modern .NET formatting differences. The specification is embedded in the Core assembly and bundled with the PowerShell engine. There are no new runtime modules, provider queries, network requests or background polling.

The interfaces consume structured evidence instead of rendering the legacy `DetailText` block. That field is retained in JSON for compatibility. JSON values retain full precision. Presentation does not sum process peaks, recalculate measurements, reorder contributors, change confidence or create new recommendations. Service/Windows accounting groups are labelled process groups; unresolved processes remain individual processes with unresolved ownership.

Application release **0.6.1**, diagnostic engine **0.6.0**, JSON schema **0.3**. The engine version is unchanged because this is a presentation release. Historical report identifiers remain their recorded values; missing versions are not recorded. No JSON schema change was introduced.

## Before and after

| Before | After |
| --- | --- |
| Raw `1790373888` bytes in a serialized object | `1.67 GiB`, explicitly labelled private allocation |
| `90.7432911177168` in statistics | `90.7%` in the display; the original number remains in JSON |
| `0.450677637` disk latency | `0.45 ms` |
| Raw property names such as AvailableBytes in the primary block | Available RAM, with average/minimum/maximum and sample coverage |
| Lists of instance keys mixed with advice | Compact contributor table; identities and attribution evidence beneath Technical evidence |
| Normal-operation insight, memory insight and duplicated memory advisory panels | One overall no-bottleneck summary, one elevated-memory card, original records still in JSON |
| Missing paging values shown among raw nulls | Unavailable, with zero usable samples; genuine measured zero remains zero |

A controlled advisory-only example now reads:

> No clear bottleneck detected. Elevated memory utilisation.
>
> Average physical memory use was 96.9%; minimum available RAM was 256 MiB.
>
> The measurements establish elevated use or reduced headroom. Evidence for sustained memory pressure is limited.

Its contributor table lists the measured application, its average/peak private allocation, ownership confidence and captured coverage. The original two memory investigation steps are numbered below it. Full commit, paging, process identity and limitation evidence remains expandable. The example is synthetic and does not describe the development workstation.

## Verification

- **PowerShell:** 115/115 Pester 3.4.0 regressions passed in Windows PowerShell 5.1. The 100 existing checks are retained, with 15 presentation checks covering units, nulls, ownership, limits/order, grouping, normal/advisory/incomplete reports, encoding, versions, full precision and a 500-sample report. Rendering expectations were updated to assert formatted structured evidence instead of raw DetailText; diagnostic expectations were not weakened.
- **.NET:** 17/17 regression checks passed, plus the existing missing-engine check. New checks cover formatting, contributor/member expansion, grouping, original metadata/version preservation and large-report loading. A 300-insight fixture loaded in approximately 46.1 ms on the final recorded run; display projections are cached instead of recomputed by bindings.
- **WPF/HTML parity:** complete formatted projections matched across eight controlled report fixtures: normal, advisory-only, CPU, memory pressure, disk latency, capacity, incomplete and combined findings. This compares observations, interpretations, primary/full measurement tables, contributor order/usage/ownership/coverage/details, recommendation order and limitations, as well as overview counts/completeness. Parity includes the original normal insight retained in data even though it is grouped into the overview in the interface.
- **HTML/browser:** headless Edge checked 1440-pixel desktop and 390-pixel mobile viewports. Neither had page-level horizontal overflow; narrow tables scroll inside their container. Advisory-only output contained one advisory card. Native technical details expanded using a keyboard Enter event. No external report requests were observed. All interpolated provider/process text goes through HTML encoding; synthetic script/tag payloads are covered by regression tests. Print styles were applied in-browser; full cross-browser printing remains a manual check.
- **WPF layout:** a temporary STA rendering harness instantiated the real application resources and Findings view with a controlled report. Bindings and rendered layouts passed at content sizes corresponding to 1366x768 at 100%, 125% and 150%, including technical expansion. Rendered tables and wrapping were inspected. This is layout rendering, not physical OS DPI or screen-reader testing. The All Processes scrollbar adjustment is preserved.
- **Windows integration:** live Windows collection through the published self-contained application engine produced a JSON/HTML report pair with 15/15 scheduled samples. The runner verified formatted report/desktop content consistency. Cancellation after a real sample exported no partial report. The existing process-only policy override was passed explicitly for the test; machine policy was unchanged.
- **Packaging:** Release/self-contained Windows x64 publishing and Inno Setup compilation succeeded, with zero build warnings/errors. The build requires both presentation files in its engine payload. Extracted installer engine files were checked against the verified source, and its desktop assembly version was checked. Installer AppId, upgrade code and preference/report/log paths are unchanged.

## Performance and engine comparison

Timed collection code and the insight-generation implementation are unchanged. The new transformations run after collection or when opening a report. Expanding an insight does not rerun the diagnostic engine.

The final live run averaged **0.1722 seconds** of collection work per sample at the configured 2-second interval; existing insight analysis took **1.4771 seconds** after sampling. These values describe this host/run, not a matched before/after collection benchmark.

On the same controlled combined-resource capture, after one warm-up and six measured iterations per version:

| Version | Mean analysis | Mean HTML formatting |
| --- | ---: | ---: |
| 0.6.0 | 0.0604 s | 0.0179 s |
| 0.6.1 | 0.0519 s | 0.0532 s |

The approximately 0.0353-second increase in HTML work is outside the sampling window. The lower measured analysis time is normal run-to-run variation; no engine speed-up is claimed. Findings, advisories, memory assessment, overall assessment, statistics, applications, attribution and the complete original DiagnosticInsights payload were identical across replay. The application version field is the intended release change.

## Historical compatibility

Schemas 0.1, 0.2 and 0.3 continue loading. Reports without DiagnosticInsights keep their original findings; no insights, identities, confidence or measurements are fabricated. Existing 0.6.0 structured insights are formatted on load without altering their stored evidence. Missing measurements stay null in JSON and display as Unavailable. Missing optional metadata stays unavailable. The release, engine and schema identifiers remain separate.

## Installer

- Filename: `WPBD-Setup-0.6.1-x64.exe`
- Usual project artifact directory: `C:\Users\NGregg\OneDrive - ARK-H Handling Ltd\Documents\ChatGPT\Windows Performance Bottleneck Detector\WindowsPerformanceBottleneckDetector\installer\artifacts`
- Size: **46,501,441 bytes** (44.35 MiB).
- SHA-256: `eb8ce19f69e743e1178dd56dfbb11956c3c5a559398a14604905b3f10ee0a030`
- Adjacent `.sha256` file supplied. The installer is unsigned.

## Known limitations

Physical Windows display scaling, keyboard/screen-reader use in the desktop app, Windows 10, clean-machine deployment and the complete install/upgrade/uninstall lifecycle were not repeated in this presentation pass. WPF evidence is based on the rendering harness; browser evidence is based on headless Edge. Cross-browser printing and assistive technology need manual acceptance. Existing diagnostic limitations remain: no process-level disk attribution, no proven causal application assignment, sequential process reads, restricted/missing metadata, incomplete coverage and potentially missed intermittent problems. No executable remediation was added.

Generated live workstation reports and temporary test/browser artifacts remain outside source control. The included HTML example uses controlled synthetic data.
