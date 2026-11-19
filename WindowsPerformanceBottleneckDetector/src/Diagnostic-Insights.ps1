function Get-WpbdInsightContributors {
    param($Diagnostic, $Slots, [ValidateSet('CpuPercent','PrivateBytes')] $Resource)
    $byIdentity = @{}
    foreach ($sample in $Diagnostic.Samples) {
        if ($sample.Slot -notin $Slots) { continue }
        foreach ($row in $sample.Processes) {
            if (-not $byIdentity.ContainsKey($row.InstanceKey)) { $byIdentity[$row.InstanceKey] = New-Object 'System.Collections.Generic.List[object]' }
            $byIdentity[$row.InstanceKey].Add([pscustomobject]@{Slot=$sample.Slot; Row=$row})
        }
    }
    $ranked = @(foreach ($app in $Diagnostic.Applications) {
        $rows = @($app.Samples | Where-Object { $_.Slot -in $Slots })
        $usage = Get-WpbdStatistics $rows $Resource
        if (-not $usage.Count -or $usage.Maximum -le 0) { continue }
        if ($Resource -eq 'CpuPercent' -and $usage.Average -lt 5 -and $usage.Maximum -lt 10) { continue }
        if ($Resource -eq 'PrivateBytes' -and $usage.Maximum -lt 256MB) { continue }
        # Unknown/restricted groups are accounting buckets, not applications.
        if ($app.AttributionCategory -notin @('Identified application','Windows system process','Identified service process')) { continue }
        [pscustomobject]@{
            Name = $app.Name; ApplicationKey = $app.Key
            ProcessIdentities = @(foreach ($process in $app.Processes) {
                $observed = @($byIdentity[$process.InstanceKey] | Where-Object { $null -ne $_ })
                if (-not $observed.Count) { continue }
                [pscustomobject]@{
                    InstanceKey=$process.InstanceKey; Id=$process.Id; Name=$process.Name; IdentityStatus=$process.IdentityStatus
                    Usage=Get-WpbdStatistics $observed.Row $Resource
                    WorkingSetBytes=Get-WpbdStatistics $observed.Row WorkingSetBytes
                }
            })
            Resource = $Resource; Usage = $usage
            WorkingSetBytes = Get-WpbdStatistics $rows 'WorkingSetBytes'
            AttributionConfidence = $app.AttributionConfidence
            MeasurementCoverage = [pscustomobject]@{ ValidSamples = $usage.Count; SelectedSamples = @($Slots).Count; PresentSamples = $rows.Count }
            SampleSlots = @($rows | Where-Object { $null -ne $_.$Resource } | Select-Object -ExpandProperty Slot)
            Reason = 'Measured activity in the selected observation samples; an investigation candidate, not established causation.'
        }
    })
    # Keep unresolved processes as individual identities, never as an invented application.
    $ranked += @(foreach ($process in $Diagnostic.Statistics.Processes.All) {
        if ($process.AttributionCategory -in @('Identified application','Windows system process','Identified service process')) { continue }
        $observed = @($byIdentity[$process.InstanceKey] | Where-Object { $null -ne $_ })
        $rows = @($observed.Row)
        $usage = Get-WpbdStatistics $rows $Resource
        if (-not $usage.Count -or $usage.Maximum -le 0) { continue }
        if ($Resource -eq 'CpuPercent' -and $usage.Average -lt 5 -and $usage.Maximum -lt 10) { continue }
        if ($Resource -eq 'PrivateBytes' -and $usage.Maximum -lt 256MB) { continue }
        [pscustomobject]@{
            Name = "$($process.Name) (PID $($process.Id); ownership unresolved)"; ApplicationKey = $null
            ProcessIdentities = @($process | Select-Object InstanceKey, Id, Name, IdentityStatus)
            Resource = $Resource; Usage = $usage; WorkingSetBytes = Get-WpbdStatistics $rows WorkingSetBytes
            AttributionConfidence = $process.AttributionConfidence
            MeasurementCoverage = [pscustomobject]@{ ValidSamples=$usage.Count; SelectedSamples=@($Slots).Count; PresentSamples=$rows.Count }
            SampleSlots = @($observed | Where-Object { $null -ne $_.Row.$Resource } | Select-Object -ExpandProperty Slot)
            Reason = 'Measured process activity in selected samples; ownership is unresolved. This candidate is not an established cause.'
        }
    })
    $ranked | Sort-Object @{Expression={$_.Usage.Average};Descending=$true}, Name, ApplicationKey | Select-Object -First 5
}

function New-WpbdInsight {
    param($Diagnostic, $Id, $Title, $Category, $Priority, $Severity, $Confidence, $Observation,
        $Interpretation, $References, $Evidence, $Slots, $Contributors, $Steps, $Limitations, $Related)
    $details = @(
        "Interpretation: $Interpretation"
        "Observation window: $($Diagnostic.StartedUtc) to $($Diagnostic.CompletedUtc)"
        "Selected sample slots: $(@($Slots) -join ', ')"
        "Measurement references: $(@($References) -join ', ')"
        'Supporting measurements:'
        (ConvertTo-Json -InputObject $Evidence -Depth 12)
        'Potential contributors (average/peak in selected samples; bytes for memory, percent for CPU):'
        $(if (@($Contributors).Count) { foreach ($c in $Contributors) {
            "$($c.Name) | $($c.Resource): average $($c.Usage.Average), peak $($c.Usage.Maximum) | ownership $($c.AttributionConfidence) | valid $($c.MeasurementCoverage.ValidSamples)/$($c.MeasurementCoverage.SelectedSamples) selected samples"
            "Identities: $(($c.ProcessIdentities | ForEach-Object { $_.InstanceKey }) -join ', ') | $($c.Reason)"
            foreach ($p in $c.ProcessIdentities) {
                if ($p.Usage) { "Process $($p.Name), PID $($p.Id), $($p.IdentityStatus): average $($p.Usage.Average), peak $($p.Usage.Maximum), $($p.Usage.Count) measured samples" }
            }
            "Working set (bytes): $(ConvertTo-Json -InputObject $c.WorkingSetBytes -Compress)"
        }} else { 'No application attribution asserted for this insight.' })
        'Suggested investigation:'
        @($Steps)
        'Data limitations:'
        @($Limitations)
    ) -join "`n"
    [pscustomobject]@{
        DetailText = $details
        Id = $Id; Title = $Title; Category = $Category; Priority = $Priority; Severity = $Severity; Confidence = $Confidence
        RelatedFindingCategory = $Related; Observation = $Observation; Interpretation = $Interpretation
        MeasurementReferences = @($References); SupportingEvidence = $Evidence
        SampleSlots = @($Slots); StartedUtc = $Diagnostic.StartedUtc; CompletedUtc = $Diagnostic.CompletedUtc
        PotentialContributors = @($Contributors); SuggestedInvestigation = @($Steps); DataLimitations = @($Limitations)
    }
}

function Get-WpbdDiagnosticInsights {
    param($Diagnostic)
    $d = $Diagnostic; $t = $d.Thresholds
    $allSlots = @($d.Samples | Select-Object -ExpandProperty Slot)
    $cpuSlots = @($d.Samples | Where-Object { $null -ne $_.CpuTotalPercent -and $_.CpuTotalPercent -gt $t.CpuPercent } | Select-Object -ExpandProperty Slot)
    $memorySlots = @(foreach ($s in $d.Samples) {
        $m = Get-WpbdMemoryAssessment @($s.Memory) $d.System.VisibleMemoryBytes $t 1
        if ($m.Statistics.PressureSamples -gt 0) { $s.Slot }
    })
    $diskSlots = @{}
    $windowLimit = 'Results describe this observation window. A short diagnostic cannot rule out intermittent problems.'
    $processLimit = 'Sequential process reads are not atomic. Missing, restricted or short-lived processes limit attribution; ownership confidence is separate from sampling confidence. No percentage of total workload is inferred from captured processes.'
    $memoryLimit = 'Private bytes are committed private allocation, not physical RAM use. Working sets include shared resident pages. Hard page reads can load mapped files and do not establish pagefile activity.'
    foreach ($f in @($d.Findings) + @($d.Advisories)) {
        $slots = $allSlots; $contributors = @(); $refs = @(); $extra = @(); $evidence = $f.Measurements
        $category = $f.Category; $title = if ($f.Classification) { $f.Classification } else { $category }
        $id = switch ($category) {
            'CPU bottleneck' { 'cpu.sustained' }
            'Memory pressure' { 'memory.pressure' }
            'Elevated memory utilisation' { 'memory.elevated' }
            'Disk I/O bottleneck' { 'disk.io/' + $f.Measurements.Name }
            'Low disk capacity' { 'storage.capacity/' + $f.Measurements.Name }
            'Insufficient diagnostic data' { 'quality.insufficient' }
            default { 'operation.normal' }
        }
        $priority = 'Informational'
        if ($f.Severity -in @('Warning','Critical')) {
            $priority = if ($f.Confidence -eq 'Low') { 'Low' } elseif ($f.Severity -eq 'Critical' -and $f.Confidence -eq 'High') { 'High' } else { 'Medium' }
        }
        $confidence = $f.Confidence
        $valid = switch ($category) {
            'CPU bottleneck' { $d.Statistics.Cpu.Count }
            'Memory pressure' { $d.Statistics.Memory.HeadroomSamples }
            'Disk I/O bottleneck' { $f.Measurements.AssessableSamples }
            default { $d.SamplingQuality.ActualSamples }
        }
        if ($d.SamplingQuality.ExpectedSamples -gt 0 -and $valid / $d.SamplingQuality.ExpectedSamples -lt 0.8) {
            if ($confidence -eq 'High') { $confidence = 'Medium' }
            if ($priority -eq 'High') { $priority = 'Medium' }
            $extra += "Partial coverage: $valid valid samples of $($d.SamplingQuality.ExpectedSamples) scheduled; insight confidence or priority is capped."
        }
        $steps = @($f.SuggestedInvestigation)
        switch ($category) {
            'CPU bottleneck' {
                $slots = $cpuSlots; $refs = @('Statistics.Cpu','Thresholds.CpuPercent','Samples[].CpuTotalPercent','Applications[].Samples[].CpuPercent')
                $contributors = @(Get-WpbdInsightContributors $d $slots CpuPercent)
                $extra += $processLimit
                $evidence = [pscustomobject]@{ Utilisation = $d.Statistics.Cpu; ThresholdPercent = $t.CpuPercent; QualifyingSamples = $slots.Count }
                $steps = @('Review the listed applications and their average and peak CPU during qualifying samples. Compare application workload with the reported slowdown.','Repeat during symptoms; inspect per-logical-processor activity when total CPU is not saturated.')
                if (-not $contributors.Count) { $extra += 'No reliably attributed application CPU measurements are available for the qualifying samples.' }
            }
            { $_ -in @('Memory pressure','Elevated memory utilisation') } {
                if ($category -eq 'Memory pressure') { $slots = $memorySlots }
                $refs = @('MemoryAssessment','Statistics.Memory','Applications[].Samples[].PrivateBytes','Applications[].Samples[].WorkingSetBytes')
                $contributors = @(Get-WpbdInsightContributors $d $slots PrivateBytes)
                $extra += @($processLimit,$memoryLimit)
                $steps = @('Review application usage and compare private allocation with working set. Observe sustained growth across repeat diagnostics under a controlled workload.','Correlate available RAM, commit and hard paging with symptoms. Review important services and security processes with their owners.')
                if (-not $contributors.Count) { $extra += 'No reliably attributed application memory measurements are available for the selected samples.' }
            }
            'Disk I/O bottleneck' {
                $name = $f.Measurements.Name
                $slots = @(foreach ($s in $d.Samples) { if (@($s.Disks | Where-Object { $_.Name -eq $name -and
                    (($_.ReadsPerSecond -ge $t.DiskOperationsPerSecond -and $_.ReadLatencyMs -ge $t.DiskLatencyMs) -or
                    ($_.WritesPerSecond -ge $t.DiskOperationsPerSecond -and $_.WriteLatencyMs -ge $t.DiskLatencyMs)) }).Count) { $s.Slot } })
                $diskSlots[$name] = $slots
                $refs = @('Statistics.Disks','Samples[].Disks','Thresholds.DiskLatencyMs','Thresholds.DiskOperationsPerSecond')
                $extra += 'Process-level disk I/O attribution is unavailable; WPBD cannot reliably identify the responsible application. High throughput or active time alone does not establish a bottleneck.'
            }
            'Low disk capacity' {
                $slots = @(); $refs = @('Statistics.Drives','Thresholds.DriveFreePercent','Thresholds.DriveCriticalFreePercent')
                $extra += 'Volume capacity is an inventory measurement. Low free space does not establish an I/O bottleneck or identify an application.'
            }
            'Insufficient diagnostic data' {
                $refs = @('SamplingQuality','Assessment.CoverageGaps','CollectionErrors')
                $evidence = [pscustomobject]@{ SamplingQuality = $d.SamplingQuality; CoverageGaps = $d.Assessment.CoverageGaps }
                $extra += @($d.Assessment.CoverageGaps)
            }
            default {
                $refs = @('Statistics.Cpu','MemoryAssessment','Statistics.Disks','Statistics.Drives','SamplingQuality','Thresholds')
                $evidence = [pscustomobject]@{ Cpu = $d.Statistics.Cpu; Memory = $d.Statistics.Memory; Disks = $d.Statistics.Disks; Drives = $d.Statistics.Drives; SamplingQuality = $d.SamplingQuality }
                $extra += 'No sustained CPU or disk latency finding met the configured thresholds. Memory interpretation is recorded separately in MemoryAssessment; elevated utilisation alone is not established pressure.'
            }
        }
        New-WpbdInsight $d $id $title $category $priority $f.Severity $confidence $f.Observed $f.Explanation $refs $evidence $slots $contributors $steps (@($windowLimit) + $extra) $category
    }
    # Context annotates existing findings and never creates a new bottleneck classification.
    $contexts = @()
    if (@($d.Findings | Where-Object Category -eq 'CPU bottleneck').Count -and @($d.Findings | Where-Object Category -eq 'Memory pressure').Count) {
        $overlap = @($cpuSlots | Where-Object { $_ -in $memorySlots })
        if ($overlap.Count) { $contexts += [pscustomobject]@{ Id='context.cpu-memory'; Title='CPU and memory evidence overlapped'; Slots=$overlap; Refs=@('cpu.sustained','memory.pressure') } }
    }
    foreach ($name in ($diskSlots.Keys | Sort-Object)) {
        if (-not @($d.Findings | Where-Object Category -eq 'CPU bottleneck').Count) { continue }
        $overlap = @($cpuSlots | Where-Object { $_ -in $diskSlots[$name] })
        if ($overlap.Count) { $contexts += [pscustomobject]@{ Id="context.cpu-disk/$name"; Title="CPU and disk latency evidence overlapped ($name)"; Slots=$overlap; Refs=@('cpu.sustained',"disk.io/$name") } }
    }
    foreach ($c in $contexts) {
        New-WpbdInsight $d $c.Id $c.Title 'Cross-resource context' 'Informational' 'Information' 'Medium' `
            "$($c.Slots.Count) samples shared the recorded resource conditions." 'Temporal correlation does not establish causation or an additional independent problem.' `
            @('Samples','DiagnosticInsights') ([pscustomobject]@{ RelatedInsightIds=$c.Refs; OverlappingSampleCount=$c.Slots.Count }) $c.Slots @() `
            @('Compare the linked resource evidence during the slowdown before selecting an investigation.') @($windowLimit,'This context reuses existing evidence; do not count it as another bottleneck.') $null
    }
    if (-not @($d.Findings | Where-Object Category -eq 'CPU bottleneck').Count) {
        foreach ($g in @($d.Samples.LogicalProcessors | Where-Object { $null -ne $_.Percent } | Group-Object Name | Sort-Object Name)) {
            $high = @($g.Group | Where-Object Percent -gt $t.CpuPercent).Count
            if ($g.Count -lt [Math]::Max($t.MinimumSamples,[Math]::Ceiling($d.SamplingQuality.ExpectedSamples*$t.MinimumCoverage)) -or -not (Test-WpbdSustained $high $g.Count $t)) { continue }
            $slots = @($d.Samples | Where-Object { @($_.LogicalProcessors | Where-Object { $_.Name -eq $g.Name -and $_.Percent -gt $t.CpuPercent }).Count } | Select-Object -ExpandProperty Slot)
            New-WpbdInsight $d "cpu.logical/$($g.Name)" "Logical processor $($g.Name) showed sustained activity" 'CPU context' 'Low' 'Information' 'Medium' `
                "$high of $($g.Count) measured samples exceeded $($t.CpuPercent)% on this logical processor." `
                'A workload may be constrained to individual logical processors. This does not establish whole-machine CPU saturation or thread attribution.' `
                @('Samples[].LogicalProcessors','Thresholds.CpuPercent') (Get-WpbdStatistics $g.Group Percent) $slots @() `
                @('Review thread-level workload and per-processor activity during symptoms.') @($windowLimit,'WPBD does not collect thread affinity or thread-level CPU.') $null
        }
    }
}
