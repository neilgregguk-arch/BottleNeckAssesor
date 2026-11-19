function Add-WpbdCollectionError {
    param($Errors, [string] $Source, [string] $Code, [string] $Message)
    $key = "$Source/$Code"
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    if (-not $Errors.Contains($key)) {
        $Errors[$key] = [pscustomobject]@{
            Source = $Source; Code = $Code; Message = $Message
            FirstSeenUtc = $now; LastSeenUtc = $now; Count = 0
        }
    }
    $Errors[$key].Count++
    $Errors[$key].LastSeenUtc = $now
}

function Get-WpbdCim {
    param([string] $Class, $Errors, [string] $Filter, [int] $TimeoutSeconds = 3, [ref] $Status)
    if ($Status) { $Status.Value = 'Available' }
    try {
        $options = @{ ClassName = $Class; OperationTimeoutSec = $TimeoutSeconds; ErrorAction = 'Stop' }
        if ($Filter) { $options.Filter = $Filter }
        $rows = @(Get-CimInstance @options)
        if ($rows.Count -eq 0) {
            Add-WpbdCollectionError $Errors $Class 'NoInstances' 'The provider returned no instances.'
        }
        $rows
    } catch {
        $exception = $_.Exception
        $code = if ($exception -is [TimeoutException] -or $exception.NativeErrorCode -match 'timeout' -or
            $exception.Message -match '\btimed out\b|\btimeout\b') { 'Timeout' } else { 'QueryFailed' }
        Add-WpbdCollectionError $Errors $Class $code $exception.Message
        if ($Status) {
            $Status.Value = 'Unavailable'
            if ($exception.GetBaseException() -is [UnauthorizedAccessException] -or
                $exception.NativeErrorCode -eq 'AccessDenied' -or $exception.HResult -eq -2147024891) {
                $Status.Value = 'AccessDenied'
            }
        }
    }
}

function Get-WpbdDelta {
    param($Before, $After)
    if ($null -ne $Before -and $null -ne $After -and $After -ge $Before) {
        # Decimal subtraction preserves precision in large absolute timestamps.
        return [double] ([decimal] $After - [decimal] $Before)
    }
    return $null
}

function Get-WpbdRatio {
    param($Numerator, $Denominator, [double] $Scale = 1)
    if ($null -ne $Numerator -and $Denominator -gt 0) {
        return ([double] $Numerator / $Denominator * $Scale)
    }
    return $null
}

function Get-WpbdCounterSeconds {
    param($Before, $After)
    if ($After.Frequency_PerfTime -gt 0 -and $Before.Frequency_PerfTime -eq $After.Frequency_PerfTime) {
        return Get-WpbdRatio (Get-WpbdDelta $Before.Timestamp_PerfTime $After.Timestamp_PerfTime) `
            $After.Frequency_PerfTime
    }
    return $null
}

function Convert-WpbdCpu {
    param($Before, $After)
    $interval = Get-WpbdDelta $Before.Timestamp_Sys100NS $After.Timestamp_Sys100NS
    $idle = Get-WpbdRatio (Get-WpbdDelta $Before.PercentProcessorTime $After.PercentProcessorTime) $interval
    if ($null -ne $idle -and $idle -le 1) { return (100 * (1 - $idle)) }
    return $null
}

function Convert-WpbdMemory {
    param($Before, $After, $VisibleBytes)
    $seconds = Get-WpbdCounterSeconds $Before $After
    $available = $After.AvailableBytes
    $usedPercent = $null
    $availablePercent = $null
    if ($null -ne $available -and $VisibleBytes -gt 0 -and $available -le $VisibleBytes) {
        $availablePercent = Get-WpbdRatio $available $VisibleBytes 100
        $usedPercent = 100 - $availablePercent
    }
    [pscustomobject]@{
        AvailableBytes = $available
        AvailablePercent = $availablePercent
        UsedPercent = $usedPercent
        CommittedBytes = $After.CommittedBytes
        CommitLimitBytes = $After.CommitLimit
        CommitPercent = Get-WpbdRatio $After.CommittedBytes $After.CommitLimit 100
        PageReadsPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.PageReadsPersec $After.PageReadsPersec) $seconds
        PagesInputPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.PagesInputPersec $After.PagesInputPersec) $seconds
        FreeAndZeroPageListBytes = $After.FreeAndZeroPageListBytes
        ModifiedPageListBytes = $After.ModifiedPageListBytes
        PagesOutputPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.PagesOutputPersec $After.PagesOutputPersec) $seconds
    }
}

function Convert-WpbdDisk {
    param($Before, $After)
    $seconds = Get-WpbdCounterSeconds $Before $After
    $active = $null
    $readOps = Get-WpbdDelta $Before.AvgDisksecPerRead_Base $After.AvgDisksecPerRead_Base
    $writeOps = Get-WpbdDelta $Before.AvgDisksecPerWrite_Base $After.AvgDisksecPerWrite_Base
    $readMs = $null
    $writeMs = $null
    if ($seconds -gt 0) {
        $idle = Get-WpbdRatio (Get-WpbdDelta $Before.PercentIdleTime $After.PercentIdleTime) `
            (Get-WpbdDelta $Before.PercentIdleTime_Base $After.PercentIdleTime_Base)
        if ($null -ne $idle) { $active = 100 * (1 - [Math]::Min(1.0, $idle)) }
        $readTicks = Get-WpbdDelta $Before.AvgDisksecPerRead $After.AvgDisksecPerRead
        $writeTicks = Get-WpbdDelta $Before.AvgDisksecPerWrite $After.AvgDisksecPerWrite
        $readMs = Get-WpbdRatio $readTicks ($After.Frequency_PerfTime * [double] $readOps) 1000
        $writeMs = Get-WpbdRatio $writeTicks ($After.Frequency_PerfTime * [double] $writeOps) 1000
    }
    [pscustomobject]@{
        Name = $After.Name
        ActivePercent = $active
        ReadsPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.DiskReadsPersec $After.DiskReadsPersec) $seconds
        WritesPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.DiskWritesPersec $After.DiskWritesPersec) $seconds
        ReadBytesPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.DiskReadBytesPersec $After.DiskReadBytesPersec) $seconds
        WriteBytesPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.DiskWriteBytesPersec $After.DiskWriteBytesPersec) $seconds
        ReadOperationsWithLatency = $(if ($null -ne $readMs) { $readOps } else { $null })
        WriteOperationsWithLatency = $(if ($null -ne $writeMs) { $writeOps } else { $null })
        ReadLatencyMs = $readMs
        WriteLatencyMs = $writeMs
        QueueLength = $After.CurrentDiskQueueLength
    }
}

function Get-WpbdProcessSnapshot {
    param($Clock, $Errors)
    $ErrorActionPreference = 'Stop'
    try {
        $processes = @(Get-Process -ErrorAction Stop)
    } catch {
        Add-WpbdCollectionError $Errors 'Processes' 'QueryFailed' $_.Exception.Message
        return
    }
    foreach ($process in $processes) {
        try {
            $id = $process.Id
            if ($id -le 0) { continue }
            $name = $process.ProcessName
            if (-not $name) { throw 'Process name was unavailable.' }
            $started = $null
            $cpu = $null
            $private = $null
            $workingSet = $null
            $metadataAccess = 'Unavailable'
            try {
                # Invoke the CLR accessor so PowerShell does not suppress getter exceptions as null.
                $started = $process.get_StartTime().ToUniversalTime().ToString('o')
                if ($started) { $metadataAccess = 'Available' }
            } catch {
                $failure = $_.Exception.GetBaseException()
                if ($failure -is [UnauthorizedAccessException] -or $failure.NativeErrorCode -eq 5) {
                    $metadataAccess = 'Restricted'
                }
            }
            try {
                $cpuTime = $process.TotalProcessorTime
                if ($null -ne $cpuTime) { $cpu = $cpuTime.TotalSeconds }
            } catch {}
            $elapsed = $Clock.Elapsed.TotalSeconds
            try { $private = $process.PrivateMemorySize64 } catch {}
            try { $workingSet = $process.WorkingSet64 } catch {}
            [pscustomobject]@{
                Id = $id; Name = $name; StartUtc = $started
                ElapsedSeconds = $elapsed; TotalCpuSeconds = $cpu
                PrivateBytes = $private; WorkingSetBytes = $workingSet
                MetadataAccess = $metadataAccess
            }
        } catch {
            Add-WpbdCollectionError $Errors 'Processes' 'InstanceUnavailable' 'An exiting or inaccessible process could not be sampled.'
        } finally {
            $process.Dispose()
        }
    }
}

function Convert-WpbdProcess {
    param($Before, $After, $LogicalProcessorCount)
    $cpu = $null
    $elapsed = $null
    if ($After.StartUtc -and $After.Id -eq $Before.Id -and $After.StartUtc -eq $Before.StartUtc) {
        $elapsed = $After.ElapsedSeconds - $Before.ElapsedSeconds
        if ($elapsed -gt 0 -and $null -ne $After.TotalCpuSeconds -and
                $null -ne $Before.TotalCpuSeconds -and $After.TotalCpuSeconds -ge $Before.TotalCpuSeconds) {
            $cpu = $After.TotalCpuSeconds - $Before.TotalCpuSeconds
        }
    }
    [pscustomobject]@{
        Id = $After.Id; Name = $After.Name; StartUtc = $After.StartUtc
        CpuSeconds = $cpu
        CpuIntervalSeconds = $(if ($null -ne $cpu) { $elapsed } else { $null })
        CpuPercent = Get-WpbdRatio $cpu ($elapsed * $LogicalProcessorCount) 100
        PrivateBytes = $After.PrivateBytes
        WorkingSetBytes = $After.WorkingSetBytes
        TotalCpuSeconds = $After.TotalCpuSeconds
        MetadataAccess = $After.MetadataAccess
    }
}

function Get-WpbdSystem {
    param($Errors)
    $os = Get-WpbdCim 'Win32_OperatingSystem' $Errors | Select-Object -First 1
    $machine = Get-WpbdCim 'Win32_ComputerSystem' $Errors | Select-Object -First 1
    $processors = @(Get-WpbdCim 'Win32_Processor' $Errors | Select-Object Name, Manufacturer,
        NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)
    $modules = @(Get-WpbdCim 'Win32_PhysicalMemory' $Errors)
    $installed = $null
    if ($modules.Count -gt 0 -and @($modules | Where-Object { $_.Capacity -le 0 }).Count -eq 0) {
        $installed = [uint64] ($modules | Measure-Object Capacity -Sum).Sum
    }
    $logical = $machine.NumberOfLogicalProcessors
    if ($logical -le 0 -and $processors.Count -gt 0 -and
            @($processors | Where-Object { $_.NumberOfLogicalProcessors -le 0 }).Count -eq 0) {
        $logical = ($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    }
    [pscustomobject]@{
        ComputerName = [Environment]::MachineName
        WindowsCaption = $os.Caption; WindowsVersion = $os.Version; WindowsBuild = $os.BuildNumber
        Manufacturer = $machine.Manufacturer; Model = $machine.Model
        Processors = $processors
        LogicalProcessorCount = $(if ($logical -gt 0) { $logical } else { $null })
        InstalledMemoryBytes = $installed
        VisibleMemoryBytes = $(if ($os.TotalVisibleMemorySize -gt 0) { [uint64] $os.TotalVisibleMemorySize * 1KB } else { $null })
        LastBootUtc = $(if ($null -ne $os.LastBootUpTime) { $os.LastBootUpTime.ToUniversalTime().ToString('o') } else { $null })
        UptimeSeconds = $(if ($null -ne $os.LastBootUpTime) { ([datetime]::UtcNow - $os.LastBootUpTime.ToUniversalTime()).TotalSeconds } else { $null })
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    }
}

function Get-WpbdDrives {
    param($Errors)
    foreach ($drive in (Get-WpbdCim 'Win32_LogicalDisk' $Errors 'DriveType = 3')) {
        [pscustomobject]@{
            Name = $drive.DeviceID; Label = $drive.VolumeName
            CapacityBytes = $drive.Size; FreeBytes = $drive.FreeSpace
            FreePercent = Get-WpbdRatio $drive.FreeSpace $drive.Size 100
        }
    }
}

function Get-WpbdCriticalEvents {
    param($Errors)
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddHours(-24) } `
            -MaxEvents 10 -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    TimestampUtc = $(if ($null -ne $_.TimeCreated) { $_.TimeCreated.ToUniversalTime().ToString('o') } else { $null })
                    Provider = $_.ProviderName; EventId = $_.Id; RecordId = $_.RecordId
                }
            }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound,*') {
            Add-WpbdCollectionError $Errors 'System event log' 'QueryFailed' $_.Exception.Message
        }
    }
}

function Get-WpbdProcessPaths {
    param($LatestProcesses, $Errors)
    $paths = @{}
    try {
        $processes = @(Get-Process -ErrorAction Stop)
    } catch {
        Add-WpbdCollectionError $Errors 'Process paths' 'QueryFailed' $_.Exception.Message
        return $paths
    }
    foreach ($process in $processes) {
        try {
            $latest = $LatestProcesses[$process.Id]
            if ($latest.StartUtc -and $process.StartTime.ToUniversalTime().ToString('o') -eq $latest.StartUtc) {
                $path = $process.Path
                if ($path) { $paths["$($latest.Id)/$($latest.StartUtc)"] = $path }
            }
        } catch {
            # Protected and exiting processes may not expose their paths.
        } finally {
            $process.Dispose()
        }
    }
    $paths
}

function Get-WpbdProcessorRows {
    param([string] $Class, $Errors)
    $cpu = @{}
    foreach ($row in (Get-WpbdCim $Class $Errors -TimeoutSeconds 2)) {
        if ($row.Name) { $cpu[$row.Name] = $row }
    }
    $total = $cpu['_Total']
    if ($cpu.Count -gt 0 -and (-not ($total.Timestamp_Sys100NS -gt 0) -or
            $null -eq $total.PercentProcessorTime -or $total.PercentProcessorTime -lt 0)) {
        Add-WpbdCollectionError $Errors $Class 'InvalidTotalCounter' 'The provider returned no usable total CPU counter.'
        $cpu.Remove('_Total')
    }
    $cpu
}

function Get-WpbdProcessorSnapshot {
    param($State, $Errors, [switch] $Baseline)
    $class = $State.NextClass
    $alternate = if ($class -eq $State.PreferredClass) { $State.FallbackClass } else { $State.PreferredClass }
    $rows = Get-WpbdProcessorRows $class $Errors
    if ($Baseline -and -not $rows.ContainsKey('_Total')) {
        $class = $alternate
        $alternate = $State.PreferredClass
        $rows = Get-WpbdProcessorRows $class $Errors
    }
    if ($rows.ContainsKey('_Total')) {
        $State.SelectedClass = $class
        $State.NextClass = $class
        $State.ConsecutiveFailures = 0
    } elseif ($class -ne $State.SelectedClass) {
        # An unsuccessful fallback probe gets one slot. Return to the cached source.
        $State.NextClass = $alternate
        $State.ConsecutiveFailures = 0
    } else {
        $State.ConsecutiveFailures++
        if ($State.ConsecutiveFailures -ge 2) { $State.NextClass = $alternate }
    }
    [pscustomobject]@{ Class = $class; Rows = $rows }
}

function Get-WpbdCpuMeasurement {
    param($Before, $After)
    $percent = $null
    $interval = $null
    $status = 'Measured'
    if (-not $After.Cpu['_Total']) { $status = 'ProviderUnavailable' }
    elseif ($Before.ProcessorCounterClass -ne $After.ProcessorCounterClass) { $status = 'ProviderChanged' }
    elseif (-not $Before.Cpu['_Total']) { $status = 'BaselineUnavailable' }
    else {
        $previous = $Before.Cpu['_Total']
        $current = $After.Cpu['_Total']
        $ticks = Get-WpbdDelta $previous.Timestamp_Sys100NS $current.Timestamp_Sys100NS
        if ($ticks -gt 0) { $interval = $ticks / 10000000 }
        $percent = Convert-WpbdCpu $previous $current
        if ($null -eq $percent) { $status = 'InvalidCounterDelta' }
    }
    [pscustomobject]@{ Percent = $percent; Status = $status; IntervalSeconds = $interval }
}

function Get-WpbdSnapshot {
    param($Clock, $Errors, $ProcessorState, [switch] $Baseline)
    $started = $Clock.Elapsed.TotalSeconds
    $processor = Get-WpbdProcessorSnapshot $ProcessorState $Errors -Baseline:$Baseline
    $cpuEnd = $Clock.Elapsed.TotalSeconds
    $memory = Get-WpbdCim 'Win32_PerfRawData_PerfOS_Memory' $Errors -TimeoutSeconds 2 | Select-Object -First 1
    $memoryEnd = $Clock.Elapsed.TotalSeconds
    $disks = @{}
    foreach ($row in (Get-WpbdCim 'Win32_PerfRawData_PerfDisk_PhysicalDisk' $Errors -TimeoutSeconds 2)) {
        if ($row.Name -and $row.Name -ne '_Total') { $disks[$row.Name] = $row }
    }
    $diskEnd = $Clock.Elapsed.TotalSeconds
    $processes = @{}
    foreach ($row in (Get-WpbdProcessSnapshot $Clock $Errors)) { $processes[$row.Id] = $row }
    $finished = $Clock.Elapsed.TotalSeconds
    [pscustomobject]@{
        Cpu = $processor.Rows; ProcessorCounterClass = $processor.Class
        Memory = $memory; Disks = $disks; Processes = $processes
        CaptureSeconds = $finished - $started
        ProviderSeconds = [pscustomobject]@{
            Cpu = $cpuEnd - $started; Memory = $memoryEnd - $cpuEnd
            Disk = $diskEnd - $memoryEnd; Processes = $finished - $diskEnd
        }
    }
}

function Get-WpbdSamplingSlot {
    param($NextSlot, $SampleCount, $Elapsed, $Interval, $Duration, $PreviousWorkEnd)
    $due = [int] [Math]::Floor($Elapsed / $Interval)
    if ($Elapsed -ge $Duration) { $due = $SampleCount }
    $slot = [Math]::Max($NextSlot, $due)
    $missed = $null
    if ($slot -gt $NextSlot) {
        $reason = if ($PreviousWorkEnd -ge $NextSlot * $Interval) { 'PreviousCaptureOverran' } else { 'SchedulerDelay' }
        $missed = [pscustomobject]@{
            FirstSlot = $NextSlot; LastSlot = $slot - 1; Count = $slot - $NextSlot; Reason = $reason
            ObservedElapsedSeconds = $Elapsed; PreviousWorkEndSeconds = $PreviousWorkEnd
        }
    }
    [pscustomobject]@{ Slot = $slot; Missed = $missed }
}

function Get-WpbdMetrics {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3600)][int] $DurationSeconds = 60,
        [ValidateRange(1, 3600)][int] $SampleIntervalSeconds = 2,
        [scriptblock] $OnSample,
        [Threading.WaitHandle] $CancellationSignal
    )
    if ($SampleIntervalSeconds -gt $DurationSeconds) {
        throw 'SampleIntervalSeconds must be less than or equal to DurationSeconds.'
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Live WPBD collection requires Windows.'
    }
    if ($CancellationSignal -and $CancellationSignal.WaitOne(0)) { throw [OperationCanceledException]::new() }

    $errors = [ordered]@{}
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $system = Get-WpbdSystem $errors
    $metadataBefore = $null
    $metadata = @(Get-WpbdProcessMetadata $errors -Phase Before -Timing ([ref] $metadataBefore))
    $inventorySeconds = $clock.Elapsed.TotalSeconds
    $processorState = @{
        PreferredClass = 'Win32_PerfRawData_Counters_ProcessorInformation'
        FallbackClass = 'Win32_PerfRawData_PerfOS_Processor'
        NextClass = 'Win32_PerfRawData_Counters_ProcessorInformation'
        SelectedClass = $null; ConsecutiveFailures = 0
    }
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $missedSlots = New-Object 'System.Collections.Generic.List[object]'
    $sampleCount = [int] [Math]::Ceiling($DurationSeconds / $SampleIntervalSeconds)
    $activity = 'Windows performance diagnostic'
    try {
        if ($CancellationSignal -and $CancellationSignal.WaitOne(0)) { throw [OperationCanceledException]::new() }
        Write-Progress -Activity $activity -Status 'Collecting baseline' -PercentComplete 0
        $before = Get-WpbdSnapshot $clock $errors $processorState -Baseline
        $baselineTiming = [pscustomobject]@{
            CaptureSeconds = $before.CaptureSeconds; ProviderSeconds = $before.ProviderSeconds
            ProcessorCounterClass = $before.ProcessorCounterClass
        }
        $origin = $clock.Elapsed.TotalSeconds
        $started = [DateTimeOffset]::UtcNow
        $previousWorkEnd = 0.0
        for ($slot = 1; $slot -le $sampleCount; $slot++) {
            $target = [Math]::Min($slot * $SampleIntervalSeconds, $DurationSeconds)
            $remaining = $target - ($clock.Elapsed.TotalSeconds - $origin)
            if ($CancellationSignal) {
                $wait = [int] [Math]::Max(0, [Math]::Ceiling($remaining * 1000))
                if ($CancellationSignal.WaitOne($wait)) { throw [OperationCanceledException]::new() }
            } elseif ($remaining -gt 0) {
                Start-Sleep -Milliseconds ([int] [Math]::Ceiling($remaining * 1000))
            }
            $decision = Get-WpbdSamplingSlot $slot $sampleCount ($clock.Elapsed.TotalSeconds - $origin) `
                $SampleIntervalSeconds $DurationSeconds $previousWorkEnd
            if ($null -ne $decision.Missed) {
                $missedSlots.Add($decision.Missed)
                Add-WpbdCollectionError $errors 'Sampling' 'MissedSlots' 'The sampling schedule skipped slots. See SamplingQuality.MissedSlots for reasons and counts.'
                $slot = $decision.Slot
                $target = [Math]::Min($slot * $SampleIntervalSeconds, $DurationSeconds)
            }
            Write-Progress -Activity $activity -Status "Sampling ($slot of $sampleCount)" `
                -PercentComplete ([int] [Math]::Min(100, 100 * $target / $DurationSeconds))
            $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            $elapsed = $clock.Elapsed.TotalSeconds - $origin
            $after = Get-WpbdSnapshot $clock $errors $processorState
            $processingStart = $clock.Elapsed.TotalSeconds
            $previousCpu = if ($before.ProcessorCounterClass -eq $after.ProcessorCounterClass) { $before.Cpu } else { @{} }
            $cpuMeasurement = Get-WpbdCpuMeasurement $before $after
            if ($null -eq $cpuMeasurement.Percent) {
                Add-WpbdCollectionError $errors 'CPU utilisation' 'Unavailable' 'No valid total CPU counter pair for this sample.'
            }
            if ($after.Disks.Count -eq 0) {
                Add-WpbdCollectionError $errors 'Physical disks' 'Unavailable' 'No individual physical disk counters were available.'
            }
            $sample = [pscustomobject]@{
                Slot = $slot; TimestampUtc = $timestamp; ElapsedSeconds = $elapsed
                ScheduledElapsedSeconds = $target
                ProcessorCounterClass = $after.ProcessorCounterClass
                CollectionTiming = $null
                CpuTotalPercent = $cpuMeasurement.Percent
                CpuStatus = $cpuMeasurement.Status
                CpuIntervalSeconds = $cpuMeasurement.IntervalSeconds
                LogicalProcessors = @(foreach ($name in ($after.Cpu.Keys | Sort-Object)) {
                    if ($name -notmatch '_Total$') {
                        [pscustomobject]@{ Name = $name; Percent = Convert-WpbdCpu $previousCpu[$name] $after.Cpu[$name] }
                    }
                })
                Memory = Convert-WpbdMemory $before.Memory $after.Memory $system.VisibleMemoryBytes
                Disks = @(foreach ($name in ($after.Disks.Keys | Sort-Object)) {
                    Convert-WpbdDisk $before.Disks[$name] $after.Disks[$name]
                })
                Processes = @(foreach ($row in $after.Processes.Values) {
                    Convert-WpbdProcess $before.Processes[$row.Id] $row $system.LogicalProcessorCount
                })
            }
            $previousWorkEnd = $clock.Elapsed.TotalSeconds - $origin
            $sample.CollectionTiming = [pscustomobject]@{
                CaptureSeconds = $after.CaptureSeconds
                ProcessingSeconds = $clock.Elapsed.TotalSeconds - $processingStart
                TotalSeconds = $previousWorkEnd - $elapsed
                StartDelaySeconds = [Math]::Max(0.0, $elapsed - $target)
                ProviderSeconds = $after.ProviderSeconds
            }
            $samples.Add($sample)
            if ($OnSample) { $null = & $OnSample $sample $samples.Count $sampleCount }
            if ($CancellationSignal -and $CancellationSignal.WaitOne(0)) { throw [OperationCanceledException]::new() }
            $previousWorkEnd = $clock.Elapsed.TotalSeconds - $origin
            $before = $after
        }
    } finally {
        $clock.Stop()
        Write-Progress -Activity $activity -Completed
    }
    $completed = [DateTimeOffset]::UtcNow
    $postSampling = [Diagnostics.Stopwatch]::StartNew()
    Write-Verbose 'Reading drive capacity and recent critical events after performance sampling.'
    $paths = Get-WpbdProcessPaths $before.Processes $errors
    $metadataAfter = $null
    $metadata += @(Get-WpbdProcessMetadata $errors -Phase After -Timing ([ref] $metadataAfter))
    if ($CancellationSignal -and $CancellationSignal.WaitOne(0)) { throw [OperationCanceledException]::new() }
    $drives = @(Get-WpbdDrives $errors)
    $events = @(Get-WpbdCriticalEvents $errors)
    if ($CancellationSignal -and $CancellationSignal.WaitOne(0)) { throw [OperationCanceledException]::new() }
    $postSampling.Stop()

    [pscustomobject]@{
        SchemaVersion = '0.3'
        Configuration = [pscustomobject]@{
            DurationSeconds = $DurationSeconds; SampleIntervalSeconds = $SampleIntervalSeconds
            ExpectedSamples = $sampleCount; ProcessorCounterClass = $processorState.SelectedClass
        }
        System = $system
        StartedUtc = $started.ToString('o'); CompletedUtc = $completed.ToString('o')
        ActualDurationSeconds = $clock.Elapsed.TotalSeconds - $origin
        MissedSlots = $missedSlots.ToArray()
        CollectionTiming = [pscustomobject]@{
            InventorySeconds = $inventorySeconds; Baseline = $baselineTiming
            PostSamplingSeconds = $postSampling.Elapsed.TotalSeconds
            ProcessMetadataBefore = $metadataBefore; ProcessMetadataAfter = $metadataAfter
        }
        Samples = $samples.ToArray(); Drives = $drives; CriticalSystemEvents = $events; ProcessPaths = $paths
        ProcessMetadata = $metadata
        CollectionErrors = @($errors.Values)
    }
}
