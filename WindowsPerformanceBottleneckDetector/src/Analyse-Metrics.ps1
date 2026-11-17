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
        MemoryElevatedUsedPercent = 85
        MemoryElevatedAvailableBytes = 1GB
        MemoryPressureAvailableBytes = 768MB
        MemoryPressureAvailablePercent = 8
        MemorySevereAvailablePercent = 1
        MemoryRelativeHeadroomCapBytes = 2GB
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
    foreach ($sample in $Samples) {
        foreach ($row in $sample.Processes) {
            $key = "$($row.Id)/$($row.StartUtc)"
            if (-not $row.StartUtc) {
                # A PID and name alone do not identify a process across captures.
                $key = "unknown/$($row.Id)/$($sample.Slot)"
            }
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = [pscustomobject]@{
                    InstanceKey = $key
                    Id = $row.Id; Name = $row.Name; StartUtc = $row.StartUtc
                    Path = $(if ($null -ne $Paths) { $Paths[$key] } else { $null })
                    Observations = 0; CpuIntervals = 0; ObservedCpuIntervalSeconds = 0.0
                    CumulativeCpuSeconds = $null; AverageCpuPercent = $null; PeakCpuPercent = $null
                    PeakPrivateBytes = $null; PeakWorkingSetBytes = $null
                }
            }
            $entry = $groups[$key]
            $entry.Observations++
            if ($row.StartUtc -and $null -ne $row.CpuSeconds -and $row.CpuIntervalSeconds -gt 0) {
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
    }
    foreach ($entry in $groups.Values) {
        $entry.AverageCpuPercent = Get-WpbdRatio $entry.CumulativeCpuSeconds `
            ($entry.ObservedCpuIntervalSeconds * $LogicalProcessorCount) 100
    }
    $leaders = [ordered]@{}
    foreach ($property in @('AverageCpuPercent', 'PeakCpuPercent', 'CumulativeCpuSeconds', 'PeakPrivateBytes', 'PeakWorkingSetBytes')) {
        $seenUnknown = @{}
        $leaders[$property] = @($groups.Values | Where-Object { $null -ne $_.$property } |
            Sort-Object @{ Expression = $property; Descending = $true }, Name, Id, StartUtc |
            Where-Object {
                if ($_.StartUtc) { return $true }
                $key = "$($_.Id)/$($_.Name)"
                if ($seenUnknown.ContainsKey($key)) { return $false }
                $seenUnknown[$key] = $true
                $true
            } | Select-Object -First 10)
    }
    [pscustomobject]@{
        ObservedInstances = $groups.Count
        InstancesWithCpuIntervals = @($groups.Values | Where-Object { $_.CpuIntervals -gt 0 }).Count
        InstancesWithMissingPath = @($groups.Values | Where-Object { -not $_.Path }).Count
        Leaders = [pscustomobject] $leaders
        All = @($groups.Values | Sort-Object Name, Id, StartUtc, InstanceKey)
    }
}

function Test-WpbdSustained {
    param($Count, $Usable, $Thresholds)
    $Count -ge $Thresholds.MinimumSamples -and $Count -ge $Usable * $Thresholds.SustainedFraction
}

function Get-WpbdMemoryAssessment {
    param($Rows, $VisibleBytes, $Thresholds, $Required)
    $stats = [ordered]@{}
    foreach ($name in @('AvailableBytes', 'CommittedBytes', 'CommitLimitBytes', 'CommitPercent',
            'PageReadsPerSecond', 'PagesInputPerSecond', 'FreeAndZeroPageListBytes', 'ModifiedPageListBytes',
            'PagesOutputPerSecond')) {
        $stats[$name] = Get-WpbdStatistics $Rows $name
    }
    $physical = New-Object 'System.Collections.Generic.List[object]'
    $counts = [ordered]@{
        HeadroomSamples = 0; CompleteHeadroomSamples = 0; AssessableSamples = 0
        ElevatedSamples = 0; PressureSamples = 0; PressureWithPagingSamples = 0; PressureWithCommitSamples = 0
        PressureWithCompleteEvidenceSamples = 0; SeverePressureSamples = 0
        SevereWithCompleteEvidenceSamples = 0; SevereWithPagingAndCommitSamples = 0
        ReducedHeadroomWithUncertainSupportSamples = 0
    }
    foreach ($row in $Rows) {
        $available = $row.AvailableBytes
        $used = $row.UsedPercent
        $percent = $null
        if ($null -ne $available -and $VisibleBytes -gt 0 -and $available -le $VisibleBytes) {
            $percent = Get-WpbdRatio $available $VisibleBytes 100
            $used = 100 - $percent
        }
        $physical.Add([pscustomobject]@{ AvailablePercent = $percent; UsedPercent = $used })
        if ($null -eq $available -and $null -eq $used) { continue }
        $counts.HeadroomSamples++
        $completeHeadroom = $null -ne $available -and $null -ne $used
        $hasPaging = $null -ne $row.PageReadsPerSecond -or $null -ne $row.PagesInputPerSecond
        $hasCommit = $null -ne $row.CommitPercent
        if ($completeHeadroom) {
            $counts.CompleteHeadroomSamples++
            if ($hasCommit -or $hasPaging) { $counts.AssessableSamples++ }
        }
        $elevated = $used -ge $Thresholds.MemoryElevatedUsedPercent -or
            ($null -ne $available -and $available -le $Thresholds.MemoryElevatedAvailableBytes)
        $useRelative = $null -ne $percent -and $available -le $Thresholds.MemoryRelativeHeadroomCapBytes
        $criticalHeadroom = ($null -ne $available -and $available -lt $Thresholds.AvailableMemoryBytes) -or
            ($useRelative -and $percent -le $Thresholds.MemorySevereAvailablePercent)
        $reduced = $criticalHeadroom -or
            ($null -ne $available -and $available -le $Thresholds.MemoryPressureAvailableBytes) -or
            ($useRelative -and $percent -le $Thresholds.MemoryPressureAvailablePercent)
        if ($elevated -or $reduced) { $counts.ElevatedSamples++ }
        if (-not $reduced) { continue }

        $commit = $row.CommitPercent -ge $Thresholds.CommitPercent
        $paging = $row.PageReadsPerSecond -ge $Thresholds.PageReadsPerSecond -or
            $row.PagesInputPerSecond -ge $Thresholds.PagesInputPerSecond
        if (-not ($commit -or $paging)) {
            if (-not $hasCommit -or -not $hasPaging) { $counts.ReducedHeadroomWithUncertainSupportSamples++ }
            continue
        }
        $counts.PressureSamples++
        if ($paging) { $counts.PressureWithPagingSamples++ }
        if ($commit) { $counts.PressureWithCommitSamples++ }
        $completeEvidence = $completeHeadroom -and $hasCommit -and $hasPaging
        if ($completeEvidence) { $counts.PressureWithCompleteEvidenceSamples++ }
        if ($criticalHeadroom -and $used -ge $Thresholds.MemoryUsedPercent) {
            $counts.SeverePressureSamples++
            if ($completeEvidence) { $counts.SevereWithCompleteEvidenceSamples++ }
            if ($commit -and $paging) { $counts.SevereWithPagingAndCommitSamples++ }
        }
    }
    $stats.AvailablePercent = Get-WpbdStatistics $physical.ToArray() 'AvailablePercent'
    $stats.UsedPercent = Get-WpbdStatistics $physical.ToArray() 'UsedPercent'
    foreach ($name in $counts.Keys) { $stats[$name] = $counts[$name] }
    $stats = [pscustomobject] $stats
    $usable = $stats.HeadroomSamples
    $coverageGap = $null
    $finding = $null
    $advisory = $null
    $classification = 'Insufficient memory data'
    $confidence = 'Low'
    $severity = 'Information'
    $investigation = 'Review the largest private-memory consumers and correlate commit and paging with the reported slowdown.'
    $observed = "$usable samples contained physical memory utilisation or available RAM."
    $summaryParts = @(
        if ($stats.UsedPercent.Count) { 'Average physical memory utilisation was {0:N1}%.' -f $stats.UsedPercent.Average }
        if ($stats.AvailableBytes.Count) { 'Available RAM dropped to {0:N2} GiB.' -f ($stats.AvailableBytes.Minimum / 1GB) }
    )
    $summary = $summaryParts -join ' '
    $interpretation = 'Available measurements cannot support a memory assessment.'
    if ($usable -lt $Required) {
        $coverageGap = "Memory headroom ($usable usable samples, $Required required)"
    } elseif (Test-WpbdSustained $stats.PressureSamples $usable $Thresholds) {
        $classification = 'Potential memory pressure'
        $severity = 'Warning'
        if (Test-WpbdSustained $stats.PressureWithCompleteEvidenceSamples $usable $Thresholds) { $confidence = 'Medium' }
        $observed = "$($stats.PressureSamples) of $usable usable samples showed reduced available RAM with elevated commit or hard paging in the same sample. $summary"
        $interpretation = 'Sustained reduced headroom with corroborating evidence may be contributing to reduced responsiveness.'
        if (Test-WpbdSustained $stats.SeverePressureSamples $usable $Thresholds) {
            $classification = 'Severe memory pressure'
            $severity = 'Critical'
            $confidence = 'Low'
            if (Test-WpbdSustained $stats.SevereWithCompleteEvidenceSamples $usable $Thresholds) { $confidence = 'Medium' }
            if (Test-WpbdSustained $stats.SevereWithPagingAndCommitSamples $usable $Thresholds) { $confidence = 'High' }
            $observed = "$($stats.SeverePressureSamples) of $usable usable samples showed critically low available RAM, high physical use and elevated commit or hard paging together. $summary"
            $interpretation = 'Sustained critically low headroom and supporting measurements indicate severe memory pressure during the diagnostic window.'
        }
        $finding = New-WpbdFinding 'Memory pressure' $severity $confidence $stats $observed $interpretation $investigation
        $finding | Add-Member -NotePropertyName Classification -NotePropertyValue $classification
    } else {
        if ($stats.CompleteHeadroomSamples -lt $Required) {
            $coverageGap = "Memory utilisation and availability ($($stats.CompleteHeadroomSamples) paired samples, $Required required)"
        } elseif (Test-WpbdSustained $stats.ReducedHeadroomWithUncertainSupportSamples $usable $Thresholds) {
            $coverageGap = 'Memory pressure corroboration (commit or paging counters were unavailable during sustained low headroom)'
        }
        if (Test-WpbdSustained $stats.ElevatedSamples $usable $Thresholds) {
            $classification = 'Elevated memory utilisation'
            if (-not $coverageGap -and $stats.AssessableSamples -ge $Required) { $confidence = 'Medium' }
            $observed = "$($stats.ElevatedSamples) of $usable usable samples showed high physical use or reduced available headroom. $summary"
            $interpretation = 'The measurements establish elevated use or reduced headroom. Evidence for sustained memory pressure is limited.'
            $advisory = New-WpbdFinding $classification 'Information' $confidence $stats $observed $interpretation $investigation
        } elseif (-not $coverageGap) {
            $classification = 'Normal memory operation'
            $confidence = 'Medium'
            $observed = $summary
            $interpretation = 'Physical memory headroom was adequate across the sampled workload.'
        }
    }
    [pscustomobject]@{
        Statistics = $stats; Finding = $finding; Advisory = $advisory; CoverageGap = $coverageGap
        Assessment = New-WpbdFinding $classification $severity $confidence $stats $observed $interpretation $investigation
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

function Get-WpbdSamplingSummary {
    param($Metrics, $Samples, $Expected, $Cpu, $Memory)
    $valid = [ordered]@{
        CpuTotal = $Cpu.Count; LogicalCpu = 0; MemoryAvailable = $Memory.AvailableBytes.Count
        MemoryUtilisation = $Memory.UsedPercent.Count; MemoryAssessable = $Memory.AssessableSamples
        MemoryCommit = $Memory.CommitPercent.Count; PageReads = $Memory.PageReadsPerSecond.Count
        PagesInput = $Memory.PagesInputPerSecond.Count
        DiskIo = 0; DiskLatency = 0; Processes = 0; ProcessCpu = 0
    }
    $interval = $Metrics.Configuration.SampleIntervalSeconds
    $timed = New-Object 'System.Collections.Generic.List[object]'
    $overInterval = 0
    foreach ($sample in $Samples) {
        if ($sample.LogicalProcessors | Where-Object { $null -ne $_.Percent } | Select-Object -First 1) { $valid.LogicalCpu++ }
        if ($sample.Disks | Where-Object { $null -ne $_.ReadsPerSecond -or $null -ne $_.WritesPerSecond } | Select-Object -First 1) { $valid.DiskIo++ }
        if ($sample.Disks | Where-Object { $null -ne $_.ReadLatencyMs -or $null -ne $_.WriteLatencyMs } | Select-Object -First 1) { $valid.DiskLatency++ }
        if ($sample.Processes.Count -gt 0) { $valid.Processes++ }
        if ($sample.Processes | Where-Object { $null -ne $_.CpuPercent } | Select-Object -First 1) { $valid.ProcessCpu++ }
        if ($null -ne $sample.CollectionTiming.TotalSeconds) {
            $timed.Add($sample.CollectionTiming)
            if ($interval -gt 0 -and $sample.CollectionTiming.TotalSeconds -gt $interval) { $overInterval++ }
        }
    }
    $timings = $timed.ToArray()
    $providers = [ordered]@{}
    foreach ($source in @('Cpu', 'Memory', 'Disk', 'Processes')) {
        $providers[$source] = Get-WpbdStatistics $timings.ProviderSeconds $source
    }
    [pscustomobject]@{
        Quality = [pscustomobject]@{
            ExpectedSamples = $Expected; ActualSamples = $Samples.Count; MissedSampleCount = $Expected - $Samples.Count
            MissedSlots = @($Metrics.MissedSlots | Where-Object { $null -ne $_ })
            ValidSamples = [pscustomobject] $valid
            SamplesOverInterval = $overInterval
        }
        Timing = [pscustomobject]@{
            InventorySeconds = $Metrics.CollectionTiming.InventorySeconds
            Baseline = $Metrics.CollectionTiming.Baseline
            PostSamplingSeconds = $Metrics.CollectionTiming.PostSamplingSeconds
            SampleWorkSeconds = Get-WpbdStatistics $timings 'TotalSeconds'
            SampleStartDelaySeconds = Get-WpbdStatistics $timings 'StartDelaySeconds'
            ProviderSeconds = [pscustomobject] $providers
        }
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
    $applications = @(Get-WpbdApplications $samples $process.All $Metrics.ProcessMetadata)
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
    $memory = Get-WpbdMemoryAssessment $memoryRows $Metrics.System.VisibleMemoryBytes $thresholds $required
    if ($memory.CoverageGap) { $gaps.Add($memory.CoverageGap) }
    if ($memory.Finding) {
        $issues.Add('Memory pressure')
        $findings.Add($memory.Finding)
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
    $advisories = @()
    if ($memory.Advisory) { $advisories = @($memory.Advisory) }
    $sampling = Get-WpbdSamplingSummary $Metrics $samples $expected $cpu $memory.Statistics
    [pscustomobject]@{
        SchemaVersion = '0.2'
        Configuration = $Metrics.Configuration; Thresholds = [pscustomobject] $thresholds; System = $Metrics.System
        StartedUtc = $Metrics.StartedUtc; CompletedUtc = $Metrics.CompletedUtc
        ActualDurationSeconds = $Metrics.ActualDurationSeconds; Samples = $samples
        SamplingQuality = $sampling.Quality; CollectionTiming = $sampling.Timing
        MemoryAssessment = $memory.Assessment; Advisories = $advisories
        ProcessMetadata = @($Metrics.ProcessMetadata | Where-Object { $null -ne $_ })
        Applications = $applications
        CriticalSystemEvents = @($Metrics.CriticalSystemEvents | Where-Object { $null -ne $_ })
        CollectionErrors = @($Metrics.CollectionErrors | Where-Object { $null -ne $_ })
        Statistics = [pscustomobject]@{
            Cpu = $cpu; Memory = $memory.Statistics; Disks = $disks; Drives = $drives; Processes = $process
        }
        Assessment = [pscustomobject]@{
            Category = $category; Summary = $summary; CoverageGaps = $gaps.ToArray(); AdvisoryCount = $advisories.Count
        }
        Findings = $findings.ToArray()
    }
}
