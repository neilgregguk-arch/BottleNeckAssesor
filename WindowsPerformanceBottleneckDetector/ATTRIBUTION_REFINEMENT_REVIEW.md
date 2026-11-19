# Attribution review for 0.5.1

The retained 19 November baseline contains 375 identities, including 224 provisional identities. All 224 provisional PIDs appear in both CIM process inventories with a consistent creation time, no CIM executable path, and service names for many service hosts. The 0.5 implementation looks up enrichment only using each sampled process's accessible start time. A provisional identity therefore cannot use the service metadata even when the two inventories can establish continuity. Missing CIM paths and the sampled start-time access-denied flag are separate observations.

The Windows component list also omits SearchIndexer, spoolsv and RuntimeBroker. Service paths cannot simply substitute for actual executable paths, and service names alone cannot establish a parent application or publisher. Existing metadata lacks inventory phase, capture timestamp and process name, so historical provisional ownership cannot safely be upgraded from those rows alone.

The refinement records inventory boundaries, queries missing image paths using PROCESS_QUERY_LIMITED_INFORMATION, and checks the native creation time against the CIM identity before accepting a path. Provisional enrichment requires the same PID, name and creation time before and after the entire observation range. Identity status remains provisional. Services present at both boundaries can be identified with medium confidence even when their actual executable remains inaccessible. This is a separate service category and never assigns a vendor or parent application from a service name.

Missing optional paths, access-denied errors, processes that exit during enrichment, unavailable service queries and absent parent evidence have separate reason codes. Native lookup time and application-attribution analysis time are reported separately from timed sampling.

The limited-information lookup confirmed actual access denials for most inaccessible images on this workstation. It is a conservative additional source, not a way to bypass Windows protections. Windows classification additionally recognises the documented component examples at actual System32/SysWOW64 directory paths; unrelated paths and nested third-party directories do not qualify.

## Validation method

The original 09:02 baseline remains historical evidence: 375 identities, 151 verified, 224 provisional, 117 applications, 31 Windows, 39.47% application/Windows coverage and 6,236 MiB unattributed private memory. Its missing boundary timestamps and names are never fabricated to improve historical coverage.

For a comparable evaluation, a fresh 30-second, two-second-interval capture was collected at 09:24 on 19 November 2026. The same captured process samples and CIM inventories were analysed with both the 0.5.0 module from commit `f544358` and 0.5.1. The baseline replay receives the recorded `CimPath`, not the new native image fallback. Each analysis starts from an independent copy; metadata inventories are not mutated by attribution. No process/vendor names were used as expected outcomes. Actual workstation reports and metadata remain local rather than being committed.

An earlier capture encountered transient CPU, memory and disk provider timeouts, collecting 6/15 samples. Those failures are retained in its local report and excluded from the healthy timing comparison. No WMI service, antivirus or machine configuration was changed. Direct provider queries subsequently recovered. A separate unchanged-baseline control then collected 15/15, and the subsequent 0.5.1 capture collected 15/15 with zero missed slots, zero over-interval samples and no collection errors.

| Same captured dataset | 0.5.0 replay | 0.5.1 replay |
| --- | ---: | ---: |
| Unique identities | 391 | 391 |
| Verified / provisional | 161 / 230 | 161 / 230 |
| Observations | 5,754 | 5,754 |
| Identified application identities | 122 | 115 |
| Windows system identities | 33 | 41 |
| Separately identified service identities | 0 | 136 |
| Application + Windows coverage | 39.64% | 39.90% |
| Overall coverage including service-only evidence | 39.64% | 74.68% |
| Restricted metadata identities (overlapping access field) | 229 | 229 |
| Restricted ownership / unknown / unattributed application | 229 / 5 / 2 | 93 / 4 / 2 |
| Peak unattributed private memory, aligned samples | 6,296.16 MiB | 3,772.61 MiB |

Seven application identities move into the stricter Windows component category; one additional Windows identity gains attribution. The principal coverage gain is the explicitly separated 136 service identities. This is not evidence that 136 previously unknown parent applications or vendors have been identified. Physical memory consumption did not decrease: the unattributed footprint changes because measured processes now have established service evidence. Both analyses classify the same workload as memory pressure.

## Performance measurements

The healthy capture reports 2.435 seconds before-sampling metadata and 1.603 seconds after-sampling metadata. Image helper compilation plus lookups account for 0.307 and 0.036 seconds respectively (231 lookups per inventory); these 0.343 seconds are outside the timed loop. Total inventory/post-sampling stages were 3.795/1.983 seconds. The neighbouring unchanged baseline control recorded 5.983/7.762 seconds for those broad stages, but these include other work and provider variability; they are not an isolated enrichment speedup measurement. Version 0.5.0 did not report isolated attribution timing.

Three final same-data process-statistics/grouping/quality replays took 4.038, 3.978 and 3.771 seconds with 0.5.0, versus 5.982, 5.690 and 5.804 seconds with 0.5.1. Median elapsed attribution increased from 3.978 to 5.804 seconds (1.826 seconds), outside sampling. These are indicative workstation timings, not a controlled performance benchmark. The initial live analysis took 14.658 seconds while other validation work was running; warm replay timings must not be mistaken for guaranteed end-to-end completion time.

The baseline control's sample work averaged 0.207 seconds (maximum 0.257); the subsequent current capture averaged 0.414 seconds (maximum 0.532) while validation shared the machine. Both collected 15/15 without overruns or missed slots. No metadata or attribution query was added inside the existing sampling loop. CPU, memory and disk conversion/classification regressions remain covered by the retained tests; timings are load-dependent and do not prove identical runtime overhead on every workstation.

## Limitations

- The service-only category establishes service association, not executable publisher, signature, product family or application ownership. It has medium confidence and its own count. Overall coverage includes it; `ApplicationAndWindowsPercent` preserves the earlier numerator.
- Matching two CIM boundaries establishes lifetime continuity for enrichment but leaves sampled start-time evidence provisional. Processes appearing only between inventories can remain unattributed. Provisional continuity cannot detect every replacement between consecutive captures; no identity is silently upgraded or merged.
- A service may change membership between the boundaries. Provisional service evidence therefore uses their intersection and does not claim exact service membership at every sample.
- Native lookups use a two-second wall-clock budget checked before each local call, including initial helper compilation. This is a cooperative budget, not cancellation of an in-flight Windows API call. CIM operations retain their existing operation timeout. All enrichment and attribution work runs outside timed sampling.
- Path-based Windows classification does not validate an Authenticode signature. Protected processes can still deny all image queries; access reasons remain visible even for identified services.
- Private bytes and total working set remain separate. Task Manager can display private resident memory with different grouping and refresh timing. WPBD does not collect private resident working set; sums of total working sets can count shared pages repeatedly. Application totals use aligned captured samples, not unrelated member peaks, and sequential process reads are not an atomic memory snapshot.
- Installer AppId, per-user directory, preferences and report locations are unchanged. The installer was built and hashed; a fresh upgrade/uninstall cycle and visual desktop acceptance were not performed in this iteration. The currently running installed application was left open.

## Checks

All 75 PowerShell regressions pass, retaining the previous 64 and adding service intersection, PID reuse, missing boundary evidence, explicit denial versus unavailability, Windows path classification, isolated lookup failure, budget exhaustion and retention of after-inventory failures. The .NET suite passes its 12 report/protocol/configuration checks plus the missing-engine check, including optional 0.5.1 evidence and historical loading. Real Windows worker collection produced 15/15 samples and paired reports; cancellation after a real sample exported no partial report. The desktop Release build completes with zero warnings and errors. Installer compilation succeeds using the stable existing AppId and self-contained win-x64 payload.

Installer: `installer/artifacts/WPBD-Setup-0.5.1-x64.exe` (46,483,103 bytes).

SHA-256: `cc7510943687d32cb0c3c224c2e51e38e22306c8b2a8c580e0edf08074ae002c`.
