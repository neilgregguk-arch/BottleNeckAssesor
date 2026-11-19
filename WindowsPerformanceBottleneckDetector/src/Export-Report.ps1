function ConvertTo-WpbdHtmlText {
    param($Value)
    [Net.WebUtility]::HtmlEncode([string] $Value)
}

function Format-WpbdNumber {
    param($Value, [double] $Divisor = 1)
    if ($null -eq $Value) { return 'Unavailable' }
    '{0:N2}' -f ([double] $Value / $Divisor)
}

function New-WpbdHtmlTable {
    param([string[]] $Headers, $Rows)
    $html = New-Object Text.StringBuilder
    [void] $html.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($header in $Headers) { [void] $html.Append("<th scope='col'>$(ConvertTo-WpbdHtmlText $header)</th>") }
    [void] $html.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        [void] $html.Append('<tr>')
        foreach ($cell in $row) { [void] $html.Append("<td>$(ConvertTo-WpbdHtmlText $cell)</td>") }
        [void] $html.Append('</tr>')
    }
    [void] $html.Append('</tbody></table></div>')
    $html.ToString()
}

function New-WpbdStatisticsTable {
    param($Statistics, $Fields)
    $rows = @(foreach ($field in $Fields) {
        $stat = $Statistics.($field[0])
        $divisor = $field[2]
        ,@($field[1], (Format-WpbdNumber $stat.Average $divisor), (Format-WpbdNumber $stat.Minimum $divisor),
            (Format-WpbdNumber $stat.Maximum $divisor), $stat.Count)
    })
    New-WpbdHtmlTable @('Measurement', 'Average', 'Minimum', 'Maximum', 'Samples') $rows
}

function New-WpbdHtmlFindings {
    param($Findings)
    foreach ($finding in $Findings) {
        $title = if ($finding.Classification) { $finding.Classification } else { $finding.Category }
        $category = ConvertTo-WpbdHtmlText $title
        $severity = ConvertTo-WpbdHtmlText $finding.Severity
        $confidence = ConvertTo-WpbdHtmlText $finding.Confidence
        $observed = ConvertTo-WpbdHtmlText $finding.Observed
        $explanation = ConvertTo-WpbdHtmlText $finding.Explanation
        $next = ConvertTo-WpbdHtmlText $finding.SuggestedInvestigation
        @"
<article class="finding"><h3>$category</h3><p class="meta">$severity &middot; $confidence confidence</p>
<dl><dt>Observed</dt><dd>$observed</dd><dt>Interpretation</dt><dd>$explanation</dd>
<dt>Suggested investigation</dt><dd>$next</dd></dl></article>
"@
    }
}

function ConvertTo-WpbdHtmlReport {
    param($Diagnostic)
    $system = $Diagnostic.System
    $stats = $Diagnostic.Statistics
    $computer = ConvertTo-WpbdHtmlText $system.ComputerName
    $assessment = ConvertTo-WpbdHtmlText $Diagnostic.Assessment.Summary
    $start = ConvertTo-WpbdHtmlText $Diagnostic.StartedUtc
    $end = ConvertTo-WpbdHtmlText $Diagnostic.CompletedUtc
    $duration = Format-WpbdNumber $Diagnostic.ActualDurationSeconds
    $quality = $Diagnostic.SamplingQuality
    $timing = $Diagnostic.CollectionTiming
    $sampleCount = ConvertTo-WpbdHtmlText $quality.ActualSamples
    $expected = ConvertTo-WpbdHtmlText $quality.ExpectedSamples
    $missed = ConvertTo-WpbdHtmlText $quality.MissedSampleCount
    $slow = ConvertTo-WpbdHtmlText $quality.SamplesOverInterval
    $interval = Format-WpbdNumber $Diagnostic.Configuration.SampleIntervalSeconds
    $maxWork = Format-WpbdNumber $timing.SampleWorkSeconds.Maximum
    $averageWork = Format-WpbdNumber $timing.SampleWorkSeconds.Average
    $maxDelay = Format-WpbdNumber $timing.SampleStartDelaySeconds.Maximum
    $baselineSeconds = Format-WpbdNumber $timing.Baseline.CaptureSeconds
    $samplingNote = if ($quality.SamplesOverInterval -gt 0) {
        '<p>Collection exceeded the selected interval in some samples. Provider times and missed slot details show where the schedule was affected.</p>'
    }
    $validRows = @(
        ,@('Total CPU', $quality.ValidSamples.CpuTotal)
        ,@('Per-logical-processor CPU', $quality.ValidSamples.LogicalCpu)
        ,@('Available memory', $quality.ValidSamples.MemoryAvailable)
        ,@('Physical memory utilisation', $quality.ValidSamples.MemoryUtilisation)
        ,@('Commit utilisation', $quality.ValidSamples.MemoryCommit)
        ,@('Page reads/s', $quality.ValidSamples.PageReads)
        ,@('Pages input/s', $quality.ValidSamples.PagesInput)
        ,@('Disk I/O rates', $quality.ValidSamples.DiskIo)
        ,@('Disk latency', $quality.ValidSamples.DiskLatency)
        ,@('Process observations', $quality.ValidSamples.Processes)
        ,@('Process CPU utilisation', $quality.ValidSamples.ProcessCpu)
    )
    $validTable = New-WpbdHtmlTable @('Measurement', 'Valid samples') $validRows
    $providerTable = New-WpbdStatisticsTable $timing.ProviderSeconds @(
        @('Cpu', 'CPU (s)', 1), @('Memory', 'Memory (s)', 1),
        @('Disk', 'Physical disk (s)', 1), @('Processes', 'Processes (s)', 1)
    )
    $missedRows = @(foreach ($range in $quality.MissedSlots) {
        $reason = switch ($range.Reason) {
            'PreviousCaptureOverran' { 'Previous collection ran past the deadline' }
            'SchedulerDelay' { 'Sampling resumed after the scheduled deadline' }
            default { $range.Reason }
        }
        ,@($range.FirstSlot, $range.LastSlot, $range.Count, $reason, (Format-WpbdNumber $range.PreviousWorkEndSeconds),
            (Format-WpbdNumber $range.ObservedElapsedSeconds))
    })
    $missedDetails = if ($missedRows.Count) {
        New-WpbdHtmlTable @('First missed slot', 'Last missed slot', 'Count', 'Reason', 'Previous work ended (s)', 'Schedule resumed (s)') $missedRows
    }
    $systemRows = @(
        ,@('Windows', ("$($system.WindowsCaption) $($system.WindowsVersion) (build $($system.WindowsBuild))").Trim())
        ,@('Hardware', ("$($system.Manufacturer) $($system.Model)").Trim())
        ,@('Processor', (($system.Processors | ForEach-Object { $_.Name }) -join ', '))
        ,@('Logical processors', $system.LogicalProcessorCount)
        ,@('Installed RAM (GiB)', (Format-WpbdNumber $system.InstalledMemoryBytes 1GB))
        ,@('OS-visible RAM (GiB)', (Format-WpbdNumber $system.VisibleMemoryBytes 1GB))
        ,@('Last boot (UTC)', $system.LastBootUtc)
        ,@('Uptime (hours)', (Format-WpbdNumber $system.UptimeSeconds 3600))
        ,@('PowerShell', $system.PowerShellVersion)
    )
    foreach ($row in $systemRows) {
        if ([string]::IsNullOrWhiteSpace([string] $row[1]) -or $row[1] -eq '(build )') { $row[1] = 'Unavailable' }
    }
    $systemTable = New-WpbdHtmlTable @('System information', 'Value') $systemRows
    $findings = New-WpbdHtmlFindings ($Diagnostic.Findings | Where-Object {
        $_.Category -notin @('No clear bottleneck detected', 'Insufficient diagnostic data')
    })
    if (-not $findings) { $findings = '<p>No significant findings met the diagnostic rules.</p>' }
    $advisories = New-WpbdHtmlFindings $Diagnostic.Advisories
    if (-not $advisories) { $advisories = '<p>No advisories recorded.</p>' }
    $insufficient = New-WpbdHtmlFindings ($Diagnostic.Findings | Where-Object { $_.Category -eq 'Insufficient diagnostic data' })
    $evidenceSection = if ($insufficient) { '<section><h2>Insufficient evidence</h2>' + ($insufficient -join '') + '</section>' }
    $normal = $Diagnostic.Findings | Where-Object { $_.Category -eq 'No clear bottleneck detected' }
    $repeatGuidance = if ($normal -and -not $Diagnostic.Advisories.Count) {
        '<p>' + (ConvertTo-WpbdHtmlText $normal.SuggestedInvestigation) + '</p>'
    }
    $cpu = New-WpbdStatisticsTable $stats (,@('Cpu', 'Total CPU utilisation (%)', 1))
    $cpuThreshold = ConvertTo-WpbdHtmlText $Diagnostic.Thresholds.CpuPercent
    $highCpu = Format-WpbdNumber $stats.Cpu.PercentAboveThreshold
    $memory = New-WpbdStatisticsTable $stats.Memory @(
        @('AvailableBytes', 'Available physical memory (MiB)', 1MB),
        @('AvailablePercent', 'Available OS-visible memory (%)', 1),
        @('UsedPercent', 'Physical memory utilisation (%)', 1),
        @('CommittedBytes', 'Committed memory (GiB)', 1GB),
        @('CommitLimitBytes', 'Commit limit (GiB)', 1GB),
        @('CommitPercent', 'Commit utilisation (%)', 1),
        @('PageReadsPerSecond', 'Page reads/s', 1),
        @('PagesInputPerSecond', 'Pages input/s', 1),
        @('PagesOutputPerSecond', 'Pages output/s', 1),
        @('FreeAndZeroPageListBytes', 'Free and zero page lists (MiB)', 1MB),
        @('ModifiedPageListBytes', 'Modified page list (MiB)', 1MB)
    )
    $memoryCategory = ConvertTo-WpbdHtmlText $Diagnostic.MemoryAssessment.Category
    $disks = foreach ($disk in $stats.Disks) {
        "<h3>$(ConvertTo-WpbdHtmlText $disk.Name)</h3>"
        New-WpbdStatisticsTable $disk @(
            @('ActivePercent', 'Active time (%)', 1),
            @('ReadsPerSecond', 'Reads/s', 1),
            @('WritesPerSecond', 'Writes/s', 1),
            @('ReadBytesPerSecond', 'Read throughput (MiB/s)', 1MB),
            @('WriteBytesPerSecond', 'Write throughput (MiB/s)', 1MB),
            @('ReadLatencyMs', 'Read latency (ms)', 1),
            @('WriteLatencyMs', 'Write latency (ms)', 1),
            @('QueueLength', 'Current queue length (requests)', 1)
        )
    }
    if (-not $disks) { $disks = '<p>Physical disk measurements unavailable.</p>' }
    $driveRows = @(foreach ($drive in $stats.Drives) {
        ,@($drive.Name, $drive.Label, (Format-WpbdNumber $drive.CapacityBytes 1GB),
            (Format-WpbdNumber $drive.FreeBytes 1GB), (Format-WpbdNumber $drive.FreePercent))
    })
    $drives = if ($driveRows.Count) {
        New-WpbdHtmlTable @('Volume', 'Label', 'Capacity (GiB)', 'Free (GiB)', 'Free (%)') $driveRows
    } else { '<p>Fixed-volume capacity unavailable.</p>' }
    $processTables = foreach ($ranking in @(
        @('AverageCpuPercent', 'Average CPU'),
        @('PeakCpuPercent', 'Peak CPU'),
        @('CumulativeCpuSeconds', 'CPU time during sampling'),
        @('PeakPrivateBytes', 'Peak private memory'),
        @('PeakWorkingSetBytes', 'Peak working set')
    )) {
        $rows = @(foreach ($process in $stats.Processes.Leaders.($ranking[0])) {
            $path = if ($process.Path) { $process.Path } else { 'Unavailable' }
            $identity = if ($process.StartUtc) { $process.StartUtc } else { 'Unavailable' }
            ,@($process.Name, $process.Id, $identity, (Format-WpbdNumber $process.AverageCpuPercent),
                (Format-WpbdNumber $process.PeakCpuPercent), (Format-WpbdNumber $process.CumulativeCpuSeconds),
                (Format-WpbdNumber $process.PeakPrivateBytes 1MB), (Format-WpbdNumber $process.PeakWorkingSetBytes 1MB), $path)
        })
        "<h3>$($ranking[1])</h3>"
        if ($rows.Count -eq 0) { '<p>Measurements unavailable.</p>'; continue }
        New-WpbdHtmlTable @('Process', 'PID', 'Start (UTC)', 'Average CPU (%)', 'Peak CPU (%)', 'CPU time (s)',
            'Private peak (MiB)', 'Working set peak (MiB)', 'Executable path') $rows
    }
    $applicationRows = @(foreach ($application in $Diagnostic.Applications) {
        ,@($application.Name, $application.UniqueIdentities, $application.ConcurrentProcesses.Maximum, $application.Observations,
            (Format-WpbdNumber $application.PrivateBytes.Maximum 1MB),
            (Format-WpbdNumber $application.WorkingSetBytes.Maximum 1MB),
            (Format-WpbdNumber $application.CpuPercent.Average), (Format-WpbdNumber $application.CpuPercent.Maximum),
            $application.AttributionConfidence, $application.PrivateBytes.Count, $application.WorkingSetBytes.Count, $application.Key)
    })
    $applicationTable = if ($applicationRows.Count) {
        New-WpbdHtmlTable @('Application or category', 'Unique identities', 'Peak concurrent', 'Observations',
            'Private peak (MiB)', 'Working set peak (MiB)', 'Average CPU (%)', 'Peak CPU (%)', 'Attribution confidence',
            'Complete private samples', 'Complete working set samples', 'Ownership key') $applicationRows
    } else { '<p>Application ownership measurements unavailable.</p>' }
    $attribution = $Diagnostic.AttributionQuality
    $attributionRows = @(
        ,@('Unique identities', $attribution.UniqueIdentities)
        ,@('Distinct PIDs', $attribution.UniquePids)
        ,@('Verified identities', $attribution.VerifiedIdentities)
        ,@('Provisional identities', $attribution.ProvisionalIdentities)
        ,@('Total observations', $attribution.Observations)
        ,@('Peak concurrently captured', $attribution.ConcurrentProcesses.Maximum)
        ,@('Identified application processes', $attribution.IdentifiedApplications)
        ,@('Windows system processes', $attribution.WindowsSystemProcesses)
        ,@('Identified service processes (application/publisher unverified)', $attribution.IdentifiedServices)
        ,@('Restricted metadata (can overlap a known process type)', $attribution.RestrictedProcesses)
        ,@('Protected or restricted ownership', $attribution.RestrictedOwnership)
        ,@('Unattributed application processes', $attribution.UnattributedApplications)
        ,@('Unknown process ownership', $attribution.UnknownOwnership)
        ,@('Successfully attributed identities (%)', (Format-WpbdNumber $attribution.AttributedPercent))
        ,@('Application and Windows coverage (%)', (Format-WpbdNumber $attribution.ApplicationAndWindowsPercent))
        ,@('Unattributed private memory peak (MiB)', (Format-WpbdNumber $attribution.UnattributedPrivateBytes.Maximum 1MB))
        ,@('Complete unattributed memory samples', $attribution.UnattributedPrivateBytes.Count)
    )
    $attributionTable = New-WpbdHtmlTable @('Attribution quality', 'Value') $attributionRows
    $identityRows = @(foreach ($process in $stats.Processes.All) {
        ,@($process.Name, $process.Id, $process.ParentId, $process.StartUtc, $process.IdentityStatus, $process.Observations,
            $process.AttributionCategory, $process.AttributionConfidence, $process.MetadataAccess,
            ($process.Services -join ', '), $process.Path, $process.OwnershipEvidence,
            ($process.AttributionReasons -join ', '), $process.MetadataIdentityMatch, $process.ImagePathSource)
    })
    $identityTable = New-WpbdHtmlTable @('Process', 'PID', 'Parent PID', 'Start UTC', 'Identity status', 'Observations',
        'Attribution category', 'Attribution confidence', 'Metadata access', 'Services', 'Path', 'Evidence',
        'Reason codes', 'Metadata identity match', 'Image path source') $identityRows
    $enrichmentRows = @(
        ,@('Before-sampling metadata (s)', (Format-WpbdNumber $timing.ProcessMetadataBefore.TotalSeconds))
        ,@('Before-sampling image lookups (s)', (Format-WpbdNumber $timing.ProcessMetadataBefore.ImageLookupSeconds))
        ,@('After-sampling metadata (s)', (Format-WpbdNumber $timing.ProcessMetadataAfter.TotalSeconds))
        ,@('After-sampling image lookups (s)', (Format-WpbdNumber $timing.ProcessMetadataAfter.ImageLookupSeconds))
        ,@('Identity statistics and attribution analysis (s)', (Format-WpbdNumber $timing.AttributionAnalysisSeconds))
    )
    $enrichmentTable = New-WpbdHtmlTable @('Outside-sampling attribution timing', 'Seconds') $enrichmentRows
    $eventRows = @(foreach ($event in $Diagnostic.CriticalSystemEvents) {
        ,@($event.TimestampUtc, $event.Provider, $event.EventId, $event.RecordId)
    })
    $eventError = @($Diagnostic.CollectionErrors | Where-Object { $_.Source -eq 'System event log' }).Count -gt 0
    $events = if ($eventError) { '<p>The System event log was unavailable.</p>' }
    elseif ($eventRows.Count) { New-WpbdHtmlTable @('Time (UTC)', 'Provider', 'Event ID', 'Record ID') $eventRows }
    else { '<p>No critical System events were returned.</p>' }
    $gaps = if ($Diagnostic.Assessment.CoverageGaps.Count) {
        '<ul>' + (($Diagnostic.Assessment.CoverageGaps | ForEach-Object {
            "<li>$(ConvertTo-WpbdHtmlText $_)</li>"
        }) -join '') + '</ul>'
    } else { '<p>All assessment categories met the minimum coverage rules.</p>' }
    $errorRows = @(foreach ($errorRecord in $Diagnostic.CollectionErrors) {
        ,@($errorRecord.Source, $errorRecord.Code, $errorRecord.Count, $errorRecord.FirstSeenUtc,
            $errorRecord.LastSeenUtc, $errorRecord.Message)
    })
    $collectionErrors = if ($errorRows.Count) {
        New-WpbdHtmlTable @('Source', 'Code', 'Occurrences', 'First seen (UTC)', 'Last seen (UTC)', 'Details') $errorRows
    } else { '<p>No collection errors recorded.</p>' }
    $processCpuCount = $stats.Processes.InstancesWithCpuIntervals
    $processCount = $stats.Processes.ObservedInstances
    $missingPaths = $stats.Processes.InstancesWithMissingPath
    $logicalCpuCount = @($Diagnostic.Samples.LogicalProcessors | Where-Object { $null -ne $_.Percent } |
        Group-Object Name).Count
    $logicalCpu = if ($logicalCpuCount) { "$logicalCpuCount logical processor counter instances with measurements in JSON." }
    else { 'Per-logical-processor utilisation unavailable.' }
    $trendRows = @(foreach ($sample in $Diagnostic.Samples) {
        $latencies = foreach ($disk in $sample.Disks) {
            if ($null -ne $disk.ReadLatencyMs -or $null -ne $disk.WriteLatencyMs) {
                '{0} (read {1}, write {2})' -f $disk.Name, (Format-WpbdNumber $disk.ReadLatencyMs),
                    (Format-WpbdNumber $disk.WriteLatencyMs)
            }
        }
        $diskLatency = if ($latencies) { $latencies -join ' | ' } else { 'Unavailable' }
        ,@($sample.Slot, $sample.TimestampUtc, (Format-WpbdNumber $sample.ElapsedSeconds),
            (Format-WpbdNumber $sample.CpuTotalPercent), (Format-WpbdNumber $sample.Memory.UsedPercent),
            (Format-WpbdNumber $sample.Memory.AvailableBytes 1MB), (Format-WpbdNumber $sample.Memory.PageReadsPerSecond), $diskLatency)
    })
    $trend = if ($trendRows.Count) {
        New-WpbdHtmlTable @('Slot', 'Sample start (UTC)', 'Elapsed (s)', 'Total CPU (%)', 'Physical memory (%)',
            'Available RAM (MiB)', 'Page reads/s', 'Disk latency (ms)') $trendRows
    } else { '<p>Time series unavailable.</p>' }
    @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WPBD report | $computer</title>
<style>
:root{color-scheme:light;font-family:system-ui,sans-serif;color:#152636;background:#eef2f5}
body{max-width:76rem;margin:auto;padding:clamp(1rem,4vw,3rem);line-height:1.5}
header,section{background:white;padding:clamp(1rem,3vw,2rem);margin-bottom:1rem;border:1px solid #d0dce5;border-radius:.6rem}
h1,h2,h3,p{margin:0 0 .65rem} h1{font-size:clamp(1.5rem,4vw,2.25rem)}
h2,h3{color:#193c58} h3{margin-top:1rem} .meta{color:#44596b}
.assessment{font-size:1.2rem;font-weight:650} .finding{border-left:.25rem solid #277286;padding:.1rem 0 .1rem 1rem;margin:1rem 0}
dl{margin:.5rem 0} dt{font-weight:650} dd{margin:0 0 .6rem}
.table-wrap{overflow-x:auto;margin:.65rem 0 1rem} table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{text-align:left;vertical-align:top;padding:.45rem .65rem;border-bottom:1px solid #d0dce5;overflow-wrap:anywhere}
th{background:#e9f1f6} tbody tr:nth-child(even){background:#f5f8fa} summary{cursor:pointer;font-weight:650}
@media print{body{padding:0;background:white} section,header{padding:.5rem;border:0} tr,.finding{break-inside:avoid}}
</style>
</head>
<body>
<header>
<h1>Windows Performance Bottleneck Detector</h1>
<p><strong>$computer</strong> &middot; Version 0.2</p>
<p class="meta">$start to $end &middot; $duration s elapsed</p>
<p class="assessment">$assessment</p>
<p>$sampleCount of $expected scheduled samples collected &middot; $missed missed</p>
$repeatGuidance
</header>
<main>
<section><h2>Significant findings</h2>$($findings -join "`n")</section>
<section><h2>Advisories</h2>$($advisories -join "`n")</section>
$evidenceSection
<section><h2>Sampling quality</h2><p>The configured interval was $interval s. Sample collection and conversion averaged $averageWork s and peaked at $maxWork s. $slow samples exceeded the interval.</p>
<p>The baseline took $baselineSeconds s. The maximum sample start delay was $maxDelay s.</p>
$samplingNote
$missedDetails
$validTable
<details><summary>Provider timing</summary>$providerTable</details></section>
<section><h2>Computer</h2>$systemTable</section>
<section><h2>CPU</h2>$cpu<p>Samples above $cpuThreshold% utilisation as a percentage of usable samples &middot; $highCpu</p><p>$logicalCpu</p></section>
<section><h2>Memory</h2><p>$memoryCategory</p><p>Hard page reads and page input can include file-backed data. Page output and page-list measurements provide context.</p>$memory</section>
<section><h2>Storage</h2><p>Latency averages are weighted by completed operations. Latency can be unavailable when no operations complete in the interval.</p>
$($disks -join "`n")<h3>Fixed-volume capacity</h3>$drives</section>
<section><h2>Attribution quality</h2><p>Verified identities use PID and creation time. Provisional identities track matching consecutive PID/name sightings. An undetected replacement between captures can share a provisional identity. Ownership confidence is independent of the quality of memory measurements. Overall coverage includes application, Windows and separately identified service identities. Service evidence does not establish an application or publisher. Application and Windows coverage retains the earlier numerator. Unattributed memory combines the remaining ownership categories in each sample. Reason codes describe evidence gaps even for an identified service.</p>$attributionTable$enrichmentTable
<details><summary>All process identities and ownership evidence</summary>$identityTable</details></section>
<section><h2>Applications</h2><p>Application peaks are maxima of per-sample sums. Average CPU is the mean of complete measured sample totals. Counts distinguish identities across the diagnostic, captured observations and peak concurrent membership. Working set sums include shared pages. Private bytes and working set use different accounting from Task Manager private resident memory.</p>$applicationTable</section>
<section><h2>Top processes</h2><p>CPU percentages are relative to total machine capacity. Average CPU uses observed intervals for each process. Private bytes measure process-private allocation. Working set measures pages resident at the sample time and can include shared pages. All captured process instances are available in JSON Statistics.Processes.All and the desktop All Processes view.</p>
$($processTables -join "`n")</section>
<section><h2>Recent critical System events</h2><p class="meta">Up to 10 events from the last 24 hours.</p>$events</section>
<section><h2>Measurement availability</h2>$gaps<p>Statistics tables show how many samples contributed to each measurement.</p>
<p>Process CPU intervals were measured for $processCpuCount of $processCount observed entries. Executable paths were unavailable for $missingPaths entries.</p>
<h3>Collection errors</h3>$collectionErrors</section>
<section><details><summary>Sample timeline</summary>$trend</details></section>
</main>
</body>
</html>
"@
}

function Export-WpbdReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Diagnostic,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OutputPath
    )
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'OutputPath must be a directory path.' }
    $provider = $null
    $drive = $null
    $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPath, [ref] $provider, [ref] $drive
    )
    if ($provider.Name -ne 'FileSystem') { throw 'OutputPath must be a filesystem directory path.' }
    $computer = ([string] $Diagnostic.System.ComputerName) -replace '[^A-Za-z0-9_-]', '_'
    if (-not $computer) { $computer = 'computer' }
    $start = [DateTimeOffset]::Parse($Diagnostic.StartedUtc, [Globalization.CultureInfo]::InvariantCulture)
    $stamp = $start.ToUniversalTime().ToString("yyyyMMdd'T'HHmmssfffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $unique = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $base = Join-Path $directory "WPBD-$computer-$stamp-$unique"
    $paths = [pscustomobject]@{ JsonPath = "$base.json"; HtmlPath = "$base.html" }
    $json = ConvertTo-Json -InputObject $Diagnostic -Depth 16 -ErrorAction Stop
    $html = ConvertTo-WpbdHtmlReport $Diagnostic
    $encoding = New-Object Text.UTF8Encoding($false)
    [void] [IO.Directory]::CreateDirectory($directory)
    $created = New-Object 'System.Collections.Generic.List[string]'
    $success = $false
    try {
        foreach ($report in @(@($paths.JsonPath, $json), @($paths.HtmlPath, $html))) {
            $stream = [IO.File]::Open($report[0], [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $created.Add($report[0])
            try {
                $bytes = $encoding.GetBytes($report[1])
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
        $success = $true
        $paths
    } finally {
        if (-not $success) {
            foreach ($file in $created) { [IO.File]::Delete($file) }
        }
    }
}
