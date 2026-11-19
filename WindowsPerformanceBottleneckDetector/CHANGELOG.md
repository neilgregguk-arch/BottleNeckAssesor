# Changelog

## 0.6.4 — 2026-11-19 — Experimental partial proof of concept (B)

- Added isolated native primary-token/process/known-folder observations and real separate-process Medium named-pipe tests, reusing the unchanged 0.6.3 protocol validator.
- Added refusal-stage worker/relay entry points and executable negative tests; deployment/publish remain blocked. No successful elevated operation, native UAC launch or protected installer is implemented.
- Updated all five security documents, scenario-by-scenario test evidence and the 0.6.4 report. Protected deployment, native tooling, disposable multi-account lab, High endpoint and cross-account testing remain open blockers.
- Preserved production 0.6.2, its unconditional elevation gate, diagnostics, report formats and normal installer. No experimental binary is shipped or committed.

## 0.6.3 — 2026-11-19 — Security architecture milestone, not an application release

- Revalidated the 0.6.2 deployment/trust-boundary findings and retained the unconditional elevation gate.
- Added threat model, deployment alternatives/conditional hybrid recommendation, one-way IPC/worker/UAC design, repeatable security test plan and blocking release gates.
- Added an isolated memory-stream protocol-conformance lab with strict inputs, bounds, sequencing and result-completeness tests. It performs no UAC, native IPC, process launching or privileged operations; it is not a security-boundary proof.
- Recorded original regression/build/Standard Windows evidence separately from experimental tests. Protected installation, genuine authentication and cross-account elevation remain untested blockers.
- Kept VERSION at 0.6.2 and production/installer source unchanged. No new installer or experimental production component is shipped.

## 0.6.2 — 2026-11-19 — Standard-only foundation; elevated feature incomplete

- Stopped privileged execution at the release gate: the current user-writable deployment has not been replaced by a verified protected-worker/IPC architecture. Elevated is unavailable in the UI and rejected by the runner before process launch. No UAC request or privileged worker is shipped.
- Added read-only worker token elevation, integrity and administrator-group evidence without account names/SIDs; the WPF desktop refuses a high/elevated token.
- Added structured metadata/sampling coverage to JSON, expandable permission reporting in WPF/HTML and bounded mode-header reading in history. Retained schema 0.3, original identity/attribution safeguards and diagnostic thresholds.
- Preserved Standard execution, per-user installer AppId, preferences, reports and logs; documented the outstanding security design and unexecuted elevation test scenarios.


## 0.6.1 — 2026-11-19

- Added a compact diagnostic overview and grouped matching insights, findings and advisories without removing original report data.
- Replaced raw DetailText/JSON rendering with readable measurements, contributor tables, ordered investigations and expandable technical evidence in WPF and offline HTML.
- Added a shared field-label/unit specification and cross-runtime presentation parity fixtures. Retained all diagnostic classifications, contributor rankings, same-sample aggregation and schema 0.3.
- Added mobile table scrolling, semantic/keyboard-accessible HTML and print styles; preserved the All Processes bottom scrollbar.
- Kept engine version 0.6.0, updated the application/installer to 0.6.1, and added formatting, grouping, null handling, compatibility and large-report regressions.


## 0.6.0 — 2026-11-19

- Kept the All Processes horizontal scrollbar visible at the bottom and gave executable paths a fixed width so wide results remain readable.

- Added deterministic, evidence-linked diagnostic insights after the existing PowerShell analysis, without changing collection or bottleneck thresholds.
- Added aligned CPU/memory application and unresolved-process candidates, conservative priorities, logical-processor context and bounded overlapping-resource context.
- Added expandable Diagnostic Insights in Findings and offline HTML using the same recorded content; corrected the stale HTML version header.
- Retained schema 0.3 with additive optional insights, release/engine versions and post-processing timing; historical reports remain readable without invented evidence.
- Added synthetic insight, attribution, priority, compatibility and report-consistency regressions; updated the self-contained x64 installer to 0.6.0 with its existing AppId.


## 0.5.1

- Retained provisional identities while allowing conservative metadata matches through matching before/after PID, name and CIM creation evidence.
- Added a separate medium-confidence service category, intersecting shared service names across boundaries without inferring publishers or applications.
- Added cached read-only limited-information image queries for missing CIM paths, with native creation validation and a two-second inventory lookup budget outside timed sampling.
- Recognised additional Windows components only at actual Windows system directory paths.
- Added reason codes, metadata match and path-source evidence, separate service/application coverage and enrichment/analysis timing to optional schema 0.3 fields, HTML and existing process views.
- Preserved historical readers, identity reuse safeguards, aligned memory, diagnostic classifications, installer AppId and per-user settings.
- Added focused PowerShell and .NET regressions; actual coverage and timing measurements are documented in the attribution refinement review.

## 0.5.0

- Corrected per-slot identity inflation for inaccessible process start times by tracking explicitly provisional consecutive PID/name observations.
- Added independent ownership categories, identity status and metadata-access evidence, plus service names and parent metadata outside timed sampling.
- Added attribution quality, same-sample unattributed memory, group CPU and distinct identity/observation/concurrent counts to JSON schema 0.3 and HTML.
- Added category filters, searchable service names, application ordering and expanded process evidence in the existing desktop views.
- Preserved readers for schemas 0.1 and 0.2 without reclassifying historical ownership. Existing diagnostic thresholds are retained.
- Updated tests that intentionally expected one identity per missing-start-time sighting to require provisional continuity. Updated the report serialization assertion for schema 0.3 and legacy Unattributed assertions for the more informative categories. Added gap, reuse, restricted metadata, service/type, CPU and count regressions.

## 0.4.2

- Added All Processes browsing, search and attribution filters, plus expandable Applications with process membership.
- Added process inventory outside timed sampling, parent identity validation and conservative WebView2 attribution to verified host executables.
- Added complete per-sample application memory totals and all-process statistics to schema 0.2 as optional additive fields.
- Older reports reconstruct full process lists from raw samples and show unavailable ownership explicitly.

## 0.4.0

- Added a single-file, self-contained x64 Inno Setup installer with per-user installation, Start menu and optional desktop shortcuts, and standard Windows uninstall registration.
- Added an installer build script with dependency and publish-output checks plus SHA-256 generation.
- Added a shared WPBD icon, a single release version source and a guard that requires WPBD to close before an upgrade or uninstall.
- Kept reports, logs and desktop preferences outside the program directory and preserved them across upgrade and uninstall.

## 0.3.0

- Added a .NET 10 WPF application with live CPU, memory and disk charts, a sample inspector, structured findings and a sortable processes table.
- Added local report history, JSON report loading for schemas 0.1 and 0.2, paired HTML opening and separate application logs.
- Added a versioned JSON progress stream and cooperative cancellation for a private Windows PowerShell worker. The existing CLI and report schema remain compatible.
- Packaged the diagnostic engine beside the desktop executable for development and self-contained Windows x64 deployment.
- Added .NET regression and live Windows integration checks for report parsing, streaming, completion and cancellation.

## 0.2.0

- Added graduated memory assessments with separate advisories, OS-visible headroom thresholds and same-sample corroboration. Added page-out and page-list context using the existing memory query.
- Reused the baseline for processor provider selection, cached successful providers and added bounded fallback probes and CPU sample status. Added per-provider timings, missed-slot reasons and valid-measurement coverage.
- Isolated process sampling failures and kept observations with unknown process start times separate to guard against PID reuse.
- Expanded the offline HTML summary and timeline. JSON schema 0.2 retains the 0.1 fields and adds memory assessment, advisories, sampling quality and collection timing.
- Retained the existing Pester coverage and expanded it for the new behaviour. Updated the former high-memory test to expect an advisory alongside the same overall result. Updated the missing-provider fixture for cached selection and the JSON assertion for schema 0.2.

## 0.1.0

- Added a local Windows PowerShell 5.1 diagnostic CLI and a module for collection, analysis and report export.
- Added interval-based CPU, paging, disk I/O and process measurements, plus system inventory, volume capacity and recent critical System events.
- Added configurable sustained-evidence rules, concurrent findings, metric coverage checks and structured provider errors.
- Added timestamped JSON and offline HTML reports with exclusive file creation.
- Added Pester coverage for calculations, classifications, missing measurements, parameter validation and report export.
