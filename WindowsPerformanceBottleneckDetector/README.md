# Windows Performance Bottleneck Detector

WPBD 0.1 is a local, read-only diagnostic engine for Windows 10 and Windows 11. It samples CPU, physical memory, paging, physical disk I/O and processes, then reports evidence that may explain a workstation slowdown. It runs in Windows PowerShell 5.1 with the Windows CIM and Event Log providers. The engine requires no agent, external PowerShell module or internet connection.

## Run a diagnostic

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

The default sustained rules require three qualifying samples and at least 60% of usable samples. Each assessed metric needs at least three usable samples and 60% of the scheduled samples. Very short runs can return useful measurements with insufficient coverage for classification.

| Finding | Starting rule |
| --- | --- |
| CPU bottleneck | Total CPU utilisation exceeds 85% in sustained samples. |
| Memory pressure | Available RAM is below 500 MiB and physical use is at least 90% in the same samples as either commit use of at least 90%, 10 page reads/s or more, or 50 pages input/s or more. Sustained pressure with elevated paging is critical. |
| Disk I/O bottleneck | For a physical disk, average latency is at least 25 ms and the same direction records at least 5 operations/s in sustained samples. Active time and queue length provide context. |
| Low disk capacity | A fixed volume has less than 10% free space. Less than 2% is critical. Free space and I/O latency are assessed independently. |
| Multiple potential bottlenecks | Findings in two or more of the four categories above. Each finding retains its own evidence. |
| No clear bottleneck detected | All four assessment areas had sufficient coverage and their finding criteria were not met. |
| Insufficient diagnostic data | A metric or volume lacked enough evidence. This can accompany findings in areas where coverage was sufficient. |

Thresholds are starting values and can be overridden when calling the analysis function. A threshold override affects only that call and the applied values are included in the report.

```powershell
Import-Module .\src\WPBD.psm1
Get-WpbdThresholds
$measurements = Get-WpbdMetrics -DurationSeconds 60 -SampleIntervalSeconds 2
$diagnostic = Get-WpbdAnalysis -Metrics $measurements -ThresholdOverrides @{ DiskLatencyMs = 40 }
Export-WpbdReport -Diagnostic $diagnostic -OutputPath .\reports
```

## Measurements and reports

The CLI writes two UTF-8 files with the same filename stem containing the computer name, UTC start timestamp and a unique suffix. Existing reports are preserved. Open the HTML file directly in a browser. It contains no external resources. The JSON includes the configuration, thresholds, system information, timestamped samples, statistics, findings and structured collection errors. It uses `null` for unavailable numeric measurements and zero for measured zero activity. Reports can contain computer and process identifiers and executable paths.

- **CPU** uses successive raw processor counter readings to measure busy time. The JSON includes per-logical-processor samples where supported. System averages are arithmetic means of available samples. The percentage above threshold uses available total CPU samples as its denominator. [Windows processor counter guidance](https://learn.microsoft.com/en-us/windows/win32/perfctrs/collecting-performance-data)
- **Process CPU** is the difference in cumulative CPU seconds across consecutive observations of the same PID and start time, divided by elapsed sampling time and logical processor count. One fully utilised logical processor on a four-logical-processor workstation accounts for 25% of machine capacity. Process average CPU is weighted by the length of its observed intervals. Cumulative CPU in the diagnostic sums observed deltas only.
- **Memory** uses bytes in JSON and binary units (MiB and GiB) in HTML. Physical utilisation uses the OS-visible memory denominator, while installed memory comes from the hardware inventory. Commit utilisation uses the sampled commit limit. Page reads/s measures read operations made to resolve hard page faults. Pages input/s measures the number of pages read. File-backed pages can contribute to paging activity.
- **Process memory** reports peak private bytes and peak working set separately. Private bytes measure private allocation, which may be paged out. Working set measures resident pages and can include shared pages. When start time is inaccessible, consecutive observations with the same PID and name are grouped for memory ranking only.
- **Storage** measures read and write rates as operations/s and bytes/s. Latency is reported in milliseconds and each average is weighted by the number of completed operations. An idle interval can have zero IOPS with unavailable latency. Active time is calculated from the idle-time counter and queue length is a count of outstanding requests at the sample. Drive sizes and free bytes are queried for fixed logical drives after sampling. [Physical disk raw counter reference](https://learn.microsoft.com/en-us/previous-versions/aa394308(v=vs.85))
- **Timing and errors** use UTC timestamps and a monotonic clock for process intervals and scheduling. The first capture establishes a baseline. Sampling ends on the first capture begun at or after the duration, so the last provider calls can extend the measured window. WPBD skips missed slots rather than issuing bursts of catch-up queries. For optional providers, error records group repeated failures by source and code. Critical System event queries for the previous 24 hours run after performance sampling.

## Limitations

- Results describe the selected window. A short or unrepresentative run can miss intermittent problems. Total CPU saturation can miss a workload constrained to one logical processor. Check the per-processor time series for that case.
- Process CPU requires two valid observations. Protected processes and processes that start or exit between samples can have incomplete measurements. Executable paths are resolved after sampling for matching processes still running.
- Physical disk data uses Windows provider instances. Virtual machines and storage controllers expose the counters visible to Windows. Ideal latency varies by device, workload and storage stack.
- A short interval and long window can produce a large JSON file on machines with many processes. The engine retains samples in memory until analysis and export finish.
- The engine runs locally. Version 0.1 covers CPU, memory, storage and processes. The module returns structured objects for a future frontend.

## Run the tests

From Windows PowerShell 5.1 in the project directory, check for Pester and run the suite. Pester 3.4.0 is the verified version.

```powershell
Get-Module -ListAvailable Pester
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Script .\tests\WPBD.Tests.ps1
```

If Pester is absent, obtain Pester 3.4.0 through your approved PowerShell module source and rerun the commands. Test setup uses synthetic inputs. The diagnostic engine uses live providers for collection.
