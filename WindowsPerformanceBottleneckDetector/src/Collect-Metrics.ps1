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
    param([string] $Class, $Errors, [string] $Filter)
    try {
        $options = @{ ClassName = $Class; OperationTimeoutSec = 3; ErrorAction = 'Stop' }
        if ($Filter) { $options.Filter = $Filter }
        $rows = @(Get-CimInstance @options)
        if ($rows.Count -eq 0) {
            Add-WpbdCollectionError $Errors $Class 'NoInstances' 'The provider returned no instances.'
        }
        $rows
    } catch {
        Add-WpbdCollectionError $Errors $Class 'QueryFailed' $_.Exception.Message
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
    if ($null -ne $idle) { return (100 * (1 - [Math]::Min(1.0, $idle))) }
    return $null
}

function Convert-WpbdMemory {
    param($Before, $After, $VisibleBytes)
    $seconds = Get-WpbdCounterSeconds $Before $After
    $available = $After.AvailableBytes
    $usedPercent = $null
    if ($null -ne $available -and $VisibleBytes -gt 0 -and $available -le $VisibleBytes) {
        $usedPercent = 100 * (1 - [double] $available / $VisibleBytes)
    }
    [pscustomobject]@{
        AvailableBytes = $available
        UsedPercent = $usedPercent
        CommittedBytes = $After.CommittedBytes
        CommitLimitBytes = $After.CommitLimit
        CommitPercent = Get-WpbdRatio $After.CommittedBytes $After.CommitLimit 100
        PageReadsPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.PageReadsPersec $After.PageReadsPersec) $seconds
        PagesInputPerSecond = Get-WpbdRatio (Get-WpbdDelta $Before.PagesInputPersec $After.PagesInputPersec) $seconds
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
    try {
        $processes = @(Get-Process -ErrorAction Stop)
    } catch {
        Add-WpbdCollectionError $Errors 'Processes' 'QueryFailed' $_.Exception.Message
        return
    }
    foreach ($process in $processes) {
        try {
            if ($process.Id -eq 0) { continue }
            $started = $null
            $cpu = $null
            $private = $null
            $workingSet = $null
            try { $started = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
            try {
                $cpuTime = $process.TotalProcessorTime
                if ($null -ne $cpuTime) { $cpu = $cpuTime.TotalSeconds }
            } catch {}
            $elapsed = $Clock.Elapsed.TotalSeconds
            try { $private = $process.PrivateMemorySize64 } catch {}
            try { $workingSet = $process.WorkingSet64 } catch {}
            [pscustomobject]@{
                Id = $process.Id; Name = $process.ProcessName; StartUtc = $started
                ElapsedSeconds = $elapsed; TotalCpuSeconds = $cpu
                PrivateBytes = $private; WorkingSetBytes = $workingSet
            }
        } finally {
            $process.Dispose()
        }
    }
}

function Convert-WpbdProcess {
    param($Before, $After, $LogicalProcessorCount)
    $cpu = $null
    $elapsed = $null
    if ($After.StartUtc -and $After.StartUtc -eq $Before.StartUtc) {
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

function Get-WpbdSnapshot {
    param($Clock, $Errors, [string] $ProcessorClass)
    $cpu = @{}
    foreach ($row in (Get-WpbdCim $ProcessorClass $Errors)) {
        if ($row.Name) { $cpu[$row.Name] = $row }
    }
    $memory = Get-WpbdCim 'Win32_PerfRawData_PerfOS_Memory' $Errors | Select-Object -First 1
    $disks = @{}
    foreach ($row in (Get-WpbdCim 'Win32_PerfRawData_PerfDisk_PhysicalDisk' $Errors)) {
        if ($row.Name -and $row.Name -ne '_Total') { $disks[$row.Name] = $row }
    }
    $processes = @{}
    foreach ($row in (Get-WpbdProcessSnapshot $Clock $Errors)) { $processes[$row.Id] = $row }
    [pscustomobject]@{ Cpu = $cpu; Memory = $memory; Disks = $disks; Processes = $processes }
}

function Get-WpbdMetrics {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3600)][int] $DurationSeconds = 60,
        [ValidateRange(1, 3600)][int] $SampleIntervalSeconds = 2
    )
    if ($SampleIntervalSeconds -gt $DurationSeconds) {
        throw 'SampleIntervalSeconds must be less than or equal to DurationSeconds.'
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Live WPBD collection requires Windows.'
    }

    $errors = [ordered]@{}
    $system = Get-WpbdSystem $errors
    $processorClass = 'Win32_PerfRawData_Counters_ProcessorInformation'
    if (-not (Get-WpbdCim $processorClass $errors | Select-Object -First 1)) {
        $processorClass = 'Win32_PerfRawData_PerfOS_Processor'
    }
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $started = [DateTimeOffset]::UtcNow
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $sampleCount = [int] [Math]::Ceiling($DurationSeconds / $SampleIntervalSeconds)
    $activity = 'Windows performance diagnostic'
    try {
        Write-Progress -Activity $activity -Status 'Collecting baseline' -PercentComplete 0
        $before = Get-WpbdSnapshot $clock $errors $processorClass
        for ($slot = 1; $slot -le $sampleCount; $slot++) {
            $target = [Math]::Min($slot * $SampleIntervalSeconds, $DurationSeconds)
            $remaining = $target - $clock.Elapsed.TotalSeconds
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int] [Math]::Ceiling($remaining * 1000)) }
            $elapsed = $clock.Elapsed.TotalSeconds
            $dueSlot = [Math]::Min($sampleCount, [int] [Math]::Floor($elapsed / $SampleIntervalSeconds))
            if ($elapsed -ge $DurationSeconds) { $dueSlot = $sampleCount }
            if ($dueSlot -gt $slot) {
                Add-WpbdCollectionError $errors 'Sampling' 'MissedSlots' 'Collection overran one or more scheduled sample slots.'
                $slot = $dueSlot
            }
            $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            Write-Progress -Activity $activity -Status "Sampling ($slot of $sampleCount)" `
                -PercentComplete ([int] [Math]::Min(100, 100 * $elapsed / $DurationSeconds))
            $after = Get-WpbdSnapshot $clock $errors $processorClass
            $total = Convert-WpbdCpu $before.Cpu['_Total'] $after.Cpu['_Total']
            if ($null -eq $total) {
                Add-WpbdCollectionError $errors 'CPU utilisation' 'Unavailable' 'No valid total CPU counter pair for this sample.'
            }
            if ($after.Disks.Count -eq 0) {
                Add-WpbdCollectionError $errors 'Physical disks' 'Unavailable' 'No individual physical disk counters were available.'
            }
            $samples.Add([pscustomobject]@{
                Slot = $slot; TimestampUtc = $timestamp; ElapsedSeconds = $elapsed
                CpuTotalPercent = $total
                LogicalProcessors = @(foreach ($name in ($after.Cpu.Keys | Sort-Object)) {
                    if ($name -notmatch '_Total$') {
                        [pscustomobject]@{ Name = $name; Percent = Convert-WpbdCpu $before.Cpu[$name] $after.Cpu[$name] }
                    }
                })
                Memory = Convert-WpbdMemory $before.Memory $after.Memory $system.VisibleMemoryBytes
                Disks = @(foreach ($name in ($after.Disks.Keys | Sort-Object)) {
                    Convert-WpbdDisk $before.Disks[$name] $after.Disks[$name]
                })
                Processes = @(foreach ($row in $after.Processes.Values) {
                    Convert-WpbdProcess $before.Processes[$row.Id] $row $system.LogicalProcessorCount
                })
            })
            $before = $after
        }
    } finally {
        $clock.Stop()
        Write-Progress -Activity $activity -Completed
    }
    $completed = [DateTimeOffset]::UtcNow
    Write-Verbose 'Reading drive capacity and recent critical events after performance sampling.'
    $paths = Get-WpbdProcessPaths $before.Processes $errors
    $drives = @(Get-WpbdDrives $errors)
    $events = @(Get-WpbdCriticalEvents $errors)

    [pscustomobject]@{
        SchemaVersion = '0.1'
        Configuration = [pscustomobject]@{
            DurationSeconds = $DurationSeconds; SampleIntervalSeconds = $SampleIntervalSeconds
            ExpectedSamples = $sampleCount; ProcessorCounterClass = $processorClass
        }
        System = $system
        StartedUtc = $started.ToString('o'); CompletedUtc = $completed.ToString('o')
        ActualDurationSeconds = $clock.Elapsed.TotalSeconds
        Samples = $samples.ToArray(); Drives = $drives; CriticalSystemEvents = $events; ProcessPaths = $paths
        CollectionErrors = @($errors.Values)
    }
}
