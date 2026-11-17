# Changelog

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
