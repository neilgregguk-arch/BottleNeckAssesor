function Get-WpbdThresholds {
    [CmdletBinding()]
    param()
    [ordered]@{
        MinimumSamples = 3
        MinimumCoverage = 0.60
        SustainedFraction = 0.60
        CpuPercent = 85
        AvailableMemoryBytes = 500MB
        MemoryUsedPercent = 90
        CommitPercent = 90
        PageReadsPerSecond = 10
        PagesInputPerSecond = 50
        DiskLatencyMs = 25
        DiskOperationsPerSecond = 5
        DriveFreePercent = 10
        DriveCriticalFreePercent = 2
    }
}

function Get-WpbdStatistics {
    param($Rows, [string] $Property)
    $measure = $Rows | Where-Object { $null -ne $_.$Property } | Measure-Object -Property $Property -Average -Minimum -Maximum
    [pscustomobject]@{
        Count = [int] $measure.Count
        Average = $measure.Average
        Minimum = $measure.Minimum
        Maximum = $measure.Maximum
    }
}

function New-WpbdFinding {
    param($Category, $Severity, $Confidence, $Measurements, $Observed, $Explanation, $Investigation)
    [pscustomobject]@{
        Category = $Category; Severity = $Severity; Confidence = $Confidence
        Measurements = $Measurements; Observed = $Observed
        Explanation = $Explanation; SuggestedInvestigation = $Investigation
    }
}

function Get-WpbdProcessStatistics {
    param($Samples, $Paths, $LogicalProcessorCount)
    $groups = @{}
    $previousUnknown = @{}
    foreach ($sample in $Samples) {
        $currentUnknown = @{}
        foreach ($row in $sample.Processes) {
            $key = "$($row.Id)/$($row.StartUtc)"
            if (-not $row.StartUtc) {
                # Best-effort memory grouping for consecutive sightings of protected processes.
                $identity = "$($row.Id)/$($row.Name)"
                $key = $previousUnknown[$identity]
                if (-not $key) { $key = "unknown/$identity/$($sample.Slot)" }
                $currentUnknown[$identity] = $key
            }
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = [pscustomobject]@{
                    Id = $row.Id; Name = $row.Name; StartUtc = $row.StartUtc
                    Path = $(if ($null -ne $Paths) { $Paths[$key] } else { $null })
                    Observations = 0; CpuIntervals = 0; ObservedCpuIntervalSeconds = 0.0
                    CumulativeCpuSeconds = $null; AverageCpuPercent = $null; PeakCpuPercent = $null
                    PeakPrivateBytes = $null; PeakWorkingSetBytes = $null
                }
            }
            $entry = $groups[$key]
            $entry.Observations++
            if ($null -ne $row.CpuSeconds -and $row.CpuIntervalSeconds -gt 0) {
                $entry.CpuIntervals++
                $entry.ObservedCpuIntervalSeconds += $row.CpuIntervalSeconds
                $entry.CumulativeCpuSeconds = [double] $entry.CumulativeCpuSeconds + $row.CpuSeconds
            }
            foreach ($pair in @(@('CpuPercent', 'PeakCpuPercent'), @('PrivateBytes', 'PeakPrivateBytes'),
                    @('WorkingSetBytes', 'PeakWorkingSetBytes'))) {
                $value = $row.($pair[0])
                $property = $pair[1]
                if ($null -ne $value -and ($null -eq $entry.$property -or $value -gt $entry.$property)) {
                    $entry.$property = $value
                }
            }
        }
        $previousUnknown = $currentUnknown
    }
    foreach ($entry in $groups.Values) {
        $entry.AverageCpuPercent = Get-WpbdRatio $entry.CumulativeCpuSeconds `
            ($entry.ObservedCpuIntervalSeconds * $LogicalProcessorCount) 100
    }
    $leaders = [ordered]@{}
    foreach ($property in @('AverageCpuPercent', 'PeakCpuPercent', 'CumulativeCpuSeconds', 'PeakPrivateBytes', 'PeakWorkingSetBytes')) {
        $leaders[$property] = @($groups.Values | Where-Object { $null -ne $_.$property } |
            Sort-Object @{ Expression = $property; Descending = $true }, Name, Id, StartUtc | Select-Object -First 10)
    }
    [pscustomobject]@{
        ObservedInstances = $groups.Count
        InstancesWithCpuIntervals = @($groups.Values | Where-Object { $_.CpuIntervals -gt 0 }).Count
        InstancesWithMissingPath = @($groups.Values | Where-Object { -not $_.Path }).Count
        Leaders = [pscustomobject] $leaders
    }
}

function Get-WpbdDiskLatencyStatistics {
    param($Rows, [string] $Direction)
    $stats = Get-WpbdStatistics $Rows "${Direction}LatencyMs"
    $operations = 0.0
    $totalMs = 0.0
    foreach ($row in $Rows) {
        $count = $row."${Direction}OperationsWithLatency"
        $latency = $row."${Direction}LatencyMs"
        if ($count -gt 0 -and $null -ne $latency) {
            $operations += $count
            $totalMs += $count * $latency
        }
    }
    [pscustomobject]@{
        Count = $stats.Count; Average = Get-WpbdRatio $totalMs $operations
        Minimum = $stats.Minimum; Maximum = $stats.Maximum; Operations = $operations
    }
}

function Get-WpbdAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Metrics,
        [System.Collections.IDictionary] $ThresholdOverrides = @{}
    )

    $thresholds = Get-WpbdThresholds
    foreach ($name in $ThresholdOverrides.Keys) {
        if (-not $thresholds.Contains($name)) { throw "Unknown threshold '$name'." }
        $value = [double] $ThresholdOverrides[$name]
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0 -or
                ($name -match 'Fraction$|Coverage$' -and $value -gt 1) -or
                ($name -match 'Percent$' -and $value -gt 100) -or
                ($name -eq 'MinimumSamples' -and $value -ne [Math]::Floor($value))) {
            throw "Invalid threshold '$name'."
        }
        $thresholds[$name] = $value
    }
    if ($thresholds.DriveCriticalFreePercent -gt $thresholds.DriveFreePercent) {
        throw 'DriveCriticalFreePercent must be at or below DriveFreePercent.'
    }

    $samples = @($Metrics.Samples | Where-Object { $null -ne $_ })
    $expected = [Math]::Max($samples.Count, [int] $Metrics.Configuration.ExpectedSamples)
    $required = [Math]::Max($thresholds.MinimumSamples, [Math]::Ceiling($expected * $thresholds.MinimumCoverage))
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $gaps = New-Object 'System.Collections.Generic.List[string]'
    $issues = New-Object 'System.Collections.Generic.List[string]'

    $cpu = Get-WpbdStatistics $samples 'CpuTotalPercent'
    $cpuHigh = @($samples | Where-Object { $null -ne $_.CpuTotalPercent -and $_.CpuTotalPercent -gt $thresholds.CpuPercent }).Count
    $cpuFraction = Get-WpbdRatio $cpuHigh $cpu.Count
    $cpu | Add-Member -NotePropertyName SamplesAboveThreshold -NotePropertyValue $cpuHigh
    $cpu | Add-Member -NotePropertyName PercentAboveThreshold -NotePropertyValue (Get-WpbdRatio $cpuHigh $cpu.Count 100)
    $process = Get-WpbdProcessStatistics $samples $Metrics.ProcessPaths $Metrics.System.LogicalProcessorCount
    if ($cpu.Count -lt $required) {
        $gaps.Add("Total CPU ($($cpu.Count) usable samples, $required required)")
    } elseif ($cpuHigh -ge $thresholds.MinimumSamples -and $cpuFraction -ge $thresholds.SustainedFraction) {
        $issues.Add('CPU bottleneck')
        $findings.Add((New-WpbdFinding 'CPU bottleneck' 'Warning' 'High' `
            ([pscustomobject]@{ Utilisation = $cpu; ThresholdPercent = $thresholds.CpuPercent
                LeadingProcesses = @($process.Leaders.CumulativeCpuSeconds | Select-Object -First 3) }) `
            "$cpuHigh of $($cpu.Count) usable samples exceeded $($thresholds.CpuPercent)% total CPU utilisation." `
            'Sustained CPU demand may be limiting responsiveness during the observed workload.' `
            'Review the processes with the highest CPU consumption and correlate their activity with the slowdown.'))
    }

    $memoryRows = @($samples.Memory | Where-Object { $null -ne $_ })
    $memory = [pscustomobject]@{
        AvailableBytes = Get-WpbdStatistics $memoryRows 'AvailableBytes'
        UsedPercent = Get-WpbdStatistics $memoryRows 'UsedPercent'
        CommittedBytes = Get-WpbdStatistics $memoryRows 'CommittedBytes'
        CommitLimitBytes = Get-WpbdStatistics $memoryRows 'CommitLimitBytes'
        CommitPercent = Get-WpbdStatistics $memoryRows 'CommitPercent'
        PageReadsPerSecond = Get-WpbdStatistics $memoryRows 'PageReadsPerSecond'
        PagesInputPerSecond = Get-WpbdStatistics $memoryRows 'PagesInputPerSecond'
        AssessableSamples = 0; PressureSamples = 0; PressureWithPagingSamples = 0
    }
    foreach ($row in $memoryRows) {
        $hasPaging = $null -ne $row.PageReadsPerSecond -or $null -ne $row.PagesInputPerSecond
        if ($null -eq $row.AvailableBytes -or $null -eq $row.UsedPercent -or
                ($null -eq $row.CommitPercent -and -not $hasPaging)) { continue }
        $memory.AssessableSamples++
        $low = $row.AvailableBytes -lt $thresholds.AvailableMemoryBytes
        $used = $row.UsedPercent -ge $thresholds.MemoryUsedPercent
        $commit = $row.CommitPercent -ge $thresholds.CommitPercent
        $paging = $row.PageReadsPerSecond -ge $thresholds.PageReadsPerSecond -or
            $row.PagesInputPerSecond -ge $thresholds.PagesInputPerSecond
        if ($low -and $used -and ($commit -or $paging)) {
            $memory.PressureSamples++
            if ($paging) { $memory.PressureWithPagingSamples++ }
        }
    }
    if ($memory.AssessableSamples -lt $required) {
        $gaps.Add("Memory pressure ($($memory.AssessableSamples) usable samples, $required required)")
    } elseif ($memory.PressureSamples -ge $thresholds.MinimumSamples -and
            $memory.PressureSamples / $memory.AssessableSamples -ge $thresholds.SustainedFraction) {
        $issues.Add('Memory pressure')
        $sustainedPaging = $memory.PressureWithPagingSamples -ge $thresholds.MinimumSamples -and
            $memory.PressureWithPagingSamples / $memory.AssessableSamples -ge $thresholds.SustainedFraction
        $severity = if ($sustainedPaging) { 'Critical' } else { 'Warning' }
        $confidence = if ($sustainedPaging) { 'High' } else { 'Medium' }
        $findings.Add((New-WpbdFinding 'Memory pressure' $severity $confidence $memory `
            "Low available RAM, high physical use and elevated commit or paging occurred together in $($memory.PressureSamples) of $($memory.AssessableSamples) usable samples. Paging was elevated in $($memory.PressureWithPagingSamples) of those pressure samples." `
            'Memory pressure may be contributing to reduced responsiveness.' `
            'Review private-memory leaders and correlate hard paging and commit usage with the affected workload.'))
    }

    $diskGroups = $samples.Disks | Where-Object { $_.Name } | Group-Object Name | Sort-Object Name
    $disks = @(foreach ($group in $diskGroups) {
        $usable = 0
        $slow = 0
        foreach ($row in $group.Group) {
            $hasRead = $null -ne $row.ReadsPerSecond -and
                ($row.ReadsPerSecond -lt $thresholds.DiskOperationsPerSecond -or $null -ne $row.ReadLatencyMs)
            $hasWrite = $null -ne $row.WritesPerSecond -and
                ($row.WritesPerSecond -lt $thresholds.DiskOperationsPerSecond -or $null -ne $row.WriteLatencyMs)
            $slowRead = $row.ReadsPerSecond -ge $thresholds.DiskOperationsPerSecond -and $row.ReadLatencyMs -ge $thresholds.DiskLatencyMs
            $slowWrite = $row.WritesPerSecond -ge $thresholds.DiskOperationsPerSecond -and $row.WriteLatencyMs -ge $thresholds.DiskLatencyMs
            if ($hasRead -and $hasWrite -or $slowRead -or $slowWrite) { $usable++ }
            if ($slowRead -or $slowWrite) { $slow++ }
        }
        $disk = [pscustomobject]@{
            Name = $group.Name; AssessableSamples = $usable; HighLatencySamples = $slow
            ActivePercent = Get-WpbdStatistics $group.Group 'ActivePercent'
            ReadsPerSecond = Get-WpbdStatistics $group.Group 'ReadsPerSecond'
            WritesPerSecond = Get-WpbdStatistics $group.Group 'WritesPerSecond'
            ReadBytesPerSecond = Get-WpbdStatistics $group.Group 'ReadBytesPerSecond'
            WriteBytesPerSecond = Get-WpbdStatistics $group.Group 'WriteBytesPerSecond'
            ReadLatencyMs = Get-WpbdDiskLatencyStatistics $group.Group 'Read'
            WriteLatencyMs = Get-WpbdDiskLatencyStatistics $group.Group 'Write'
            QueueLength = Get-WpbdStatistics $group.Group 'QueueLength'
        }
        if ($usable -lt $required) {
            $gaps.Add("Disk $($group.Name) I/O ($usable usable samples, $required required)")
        } elseif ($slow -ge $thresholds.MinimumSamples -and $slow / $usable -ge $thresholds.SustainedFraction) {
            if (-not $issues.Contains('Disk I/O bottleneck')) { $issues.Add('Disk I/O bottleneck') }
            $findings.Add((New-WpbdFinding 'Disk I/O bottleneck' 'Warning' 'High' $disk `
                "Disk $($group.Name) recorded at least $($thresholds.DiskLatencyMs) ms average latency and $($thresholds.DiskOperationsPerSecond) operations/s in the same direction in $slow of $usable usable samples." `
                'Sustained storage latency may be delaying I/O for active workloads.' `
                'Correlate latency with active workloads and review the storage device, controller and system events.'))
        }
        $disk
    })
    if ($disks.Count -eq 0) { $gaps.Add('Physical disk I/O (no per-disk measurements)') }

    $drives = @($Metrics.Drives | Where-Object { $null -ne $_ })
    if ($drives.Count -eq 0) { $gaps.Add('Fixed-volume capacity (no measurements)') }
    foreach ($drive in $drives) {
        if ($null -eq $drive.FreePercent) { $gaps.Add("Volume $($drive.Name) free space"); continue }
        if ($drive.FreePercent -ge $thresholds.DriveFreePercent) { continue }
        if (-not $issues.Contains('Low disk capacity')) { $issues.Add('Low disk capacity') }
        $severity = if ($drive.FreePercent -lt $thresholds.DriveCriticalFreePercent) { 'Critical' } else { 'Warning' }
        $findings.Add((New-WpbdFinding 'Low disk capacity' $severity 'High' $drive `
            ('Volume {0} has {1:N1}% free space.' -f $drive.Name, $drive.FreePercent) `
            'Limited free space may affect applications and Windows operations that need room to write.' `
            'Review space usage and check whether updates, applications or temporary files are encountering write failures.'))
    }

    if ($gaps.Count -gt 0) {
        $findings.Add((New-WpbdFinding 'Insufficient diagnostic data' 'Information' 'Low' `
            ([pscustomobject]@{ CoverageGaps = $gaps.ToArray(); ExpectedSamples = $expected; RequiredSamples = $required }) `
            ($gaps -join '; ') 'Available measurements cannot support an assessment in these areas.' `
            'Review collection errors and repeat during the slowdown with a longer sampling window if necessary.'))
    }
    if ($issues.Count -gt 1) { $category = 'Multiple potential bottlenecks' }
    elseif ($issues.Count -eq 1) { $category = $issues[0] }
    elseif ($gaps.Count -gt 0) { $category = 'Insufficient diagnostic data' }
    else {
        $category = 'No clear bottleneck detected'
        $findings.Add((New-WpbdFinding $category 'Information' 'Medium' `
            ([pscustomobject]@{ ActualSamples = $samples.Count; RequiredSamples = $required }) `
            'The assessed CPU, memory, storage and capacity measurements did not meet the finding thresholds.' `
            'The sampled workload produced no clear evidence of a bottleneck in the assessed areas.' `
            'If the slowdown persists, repeat the diagnostic while the symptoms are occurring.'))
    }
    $summary = "$category."
    if ($issues.Count -gt 1) { $summary = "$summary $($issues -join ', ')." }
    if ($issues.Count -gt 0 -and $gaps.Count -gt 0) { $summary = "$summary Some areas had insufficient data." }
    [pscustomobject]@{
        SchemaVersion = '0.1'
        Configuration = $Metrics.Configuration; Thresholds = [pscustomobject] $thresholds; System = $Metrics.System
        StartedUtc = $Metrics.StartedUtc; CompletedUtc = $Metrics.CompletedUtc
        ActualDurationSeconds = $Metrics.ActualDurationSeconds; Samples = $samples
        CriticalSystemEvents = @($Metrics.CriticalSystemEvents | Where-Object { $null -ne $_ })
        CollectionErrors = @($Metrics.CollectionErrors | Where-Object { $null -ne $_ })
        Statistics = [pscustomobject]@{
            Cpu = $cpu; Memory = $memory; Disks = $disks; Drives = $drives; Processes = $process
        }
        Assessment = [pscustomobject]@{ Category = $category; Summary = $summary; CoverageGaps = $gaps.ToArray() }
        Findings = $findings.ToArray()
    }
}
