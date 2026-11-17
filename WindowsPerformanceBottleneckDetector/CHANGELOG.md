# Changelog

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
