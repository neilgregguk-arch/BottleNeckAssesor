Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/WPBD.psm1') -Force

Describe '0.5.1 conservative metadata enrichment' {
    InModuleScope WPBD {
        function New-BracketFixture {
            $start='2026-01-01T00:00:00Z'
            $samples=@(foreach ($slot in 1..2) { [pscustomobject]@{
                Slot=$slot;TimestampUtc="2026-01-02T00:00:0${slot}Z";Processes=@(
                    [pscustomobject]@{Id=55;Name='agent';StartUtc=$null;MetadataAccess='Restricted';PrivateBytes=10MB;WorkingSetBytes=9MB}
                )
            }})
            $metadata=@(foreach ($phase in @('Before','After')) { [pscustomobject]@{
                Id=55;Identity=(Get-WpbdProcessIdentity 55 $start);StartUtc=$start;Name='agent.exe';Path=$null
                ParentId=0;ParentStartUtc=$null;Services=@('ServiceA','ServiceB');Phase=$phase
                CapturedUtc=$(if($phase -eq 'Before'){'2026-01-02T00:00:00Z'}else{'2026-01-02T00:00:03Z'})
                PathStatus='AccessDenied';PathSource='LimitedInformation';ServiceLookupStatus='Available'
            }})
            [pscustomobject]@{Samples=$samples;Metadata=$metadata}
        }
        It 'identifies shared services at both boundaries without upgrading provisional identity or inventing an application' {
            $f=New-BracketFixture
            $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
            $groups=@(Get-WpbdApplications $f.Samples $stats.All $f.Metadata)
            $p=$stats.All[0]
            $p.AttributionCategory | Should Be 'Identified service process'
            $p.Services.Count | Should Be 2
            $p.IdentityStatus | Should Be 'Provisional'
            $p.MetadataIdentityMatch | Should Be 'BracketedInventories'
            $p.AttributionConfidence | Should Be 'Medium'
            ($p.AttributionReasons -contains 'AccessDenied') | Should Be $true
            $groups[0].PrivateBytes.Maximum | Should Be 10MB
            $q=Get-WpbdAttributionQuality $f.Samples $stats.All
            $q.IdentifiedApplications | Should Be 0
            $q.IdentifiedServices | Should Be 1
            $q.AttributedPercent | Should Be 100
            $q.ApplicationAndWindowsPercent | Should Be 0
        }
        It 'rejects reused PIDs even with the same service and executable name' {
            $f=New-BracketFixture
            $f.Metadata[1].StartUtc='2026-01-02T00:00:02Z'
            $f.Metadata[1].Identity=Get-WpbdProcessIdentity 55 $f.Metadata[1].StartUtc
            $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
            Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
            $stats.All[0].AttributionCategory | Should Be 'Protected or restricted process'
            $stats.All[0].MetadataIdentityMatch | Should Be 'Unavailable'
        }
        It 'does not use a single inventory or historical rows to infer provisional ownership' {
            $f=New-BracketFixture
            $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
            Get-WpbdApplications $f.Samples $stats.All @($f.Metadata[0]) | Out-Null
            $stats.All[0].Services.Count | Should Be 0
            foreach($row in $f.Metadata) { $row.Phase=$null }
            Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
            $stats.All[0].MetadataIdentityMatch | Should Be 'Unavailable'
        }
        It 'intersects shared services and does not mutate original boundary inventories' {
            $f=New-BracketFixture
            $f.Metadata[1].Services=@('ServiceB','ServiceC')
            $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
            Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
            $stats.All[0].Services.Count | Should Be 1
            $stats.All[0].Services[0] | Should Be 'ServiceB'
            $f.Metadata[0].Services.Count | Should Be 2
            $f.Metadata[1].Services.Count | Should Be 2
        }
        It 'reports absent optional paths without access denial and explains unavailable service metadata' {
            $f=New-BracketFixture
            foreach($sample in $f.Samples) { $sample.Processes[0].MetadataAccess='Unavailable' }
            foreach($row in $f.Metadata) { $row.Services=@(); $row.PathStatus='PathUnavailable'; $row.ServiceLookupStatus='Unavailable' }
            $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
            Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
            ($stats.All[0].AttributionReasons -contains 'AccessDenied') | Should Be $false
            ($stats.All[0].AttributionReasons -contains 'ServiceMetadataUnavailable') | Should Be $true
            ($stats.All[0].AttributionReasons -contains 'PathUnavailable') | Should Be $true
            ($stats.All[0].AttributionReasons -contains 'OwnershipUnresolved') | Should Be $true
        }
        It 'retains termination and lookup-budget reasons without fabricating ownership' {
            foreach($reason in @('ProcessExited','LookupBudgetExceeded','IdentityMismatch','LookupUnavailable')) {
                $f=New-BracketFixture
                foreach($row in $f.Metadata) { $row.Services=@(); $row.PathStatus=$reason }
                $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
                Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
                ($stats.All[0].AttributionReasons -contains $reason) | Should Be $true
            }
        }
        It 'retains after-inventory failures even when the earlier inventory succeeded' {
            $f=New-BracketFixture
            $f.Metadata[1].PathStatus='ProcessExited'
            $f.Metadata[1].ServiceLookupStatus='Unavailable'
            $f.Metadata[1].Services=@()
            $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
            Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
            ($stats.All[0].AttributionReasons -contains 'ProcessExited') | Should Be $true
            ($stats.All[0].AttributionReasons -contains 'ServiceMetadataUnavailable') | Should Be $true
            $stats.All[0].Services.Count | Should Be 0
        }
        It 'requires the actual Windows directory for newly recognised component names' {
            foreach($name in @('SearchIndexer','spoolsv','RuntimeBroker','SecurityHealthService')) {
                $f=New-BracketFixture
                foreach($sample in $f.Samples) { $sample.Processes[0].Name=$name }
                foreach($row in $f.Metadata) { $row.Name="$name.exe"; $row.Path=Join-Path ([Environment]::GetFolderPath('Windows')) "System32\$name.exe" }
                $stats=Get-WpbdProcessStatistics $f.Samples @{} 4
                Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
                $stats.All[0].AttributionCategory | Should Be 'Windows system process'
                foreach($row in $f.Metadata) { $row.Path="C:\ThirdParty\$name.exe" }
                Get-WpbdApplications $f.Samples $stats.All $f.Metadata | Out-Null
                $stats.All[0].AttributionCategory | Should Be 'Identified application'
            }
        }
        It 'records CIM lookup failure independently from process image access' {
            Mock Get-CimInstance { throw [UnauthorizedAccessException]::new('Access is denied') }
            $status=$null; $errors=[ordered]@{}
            Get-WpbdCim Win32_Service $errors -Status ([ref]$status) | Out-Null
            $status | Should Be 'AccessDenied'
            Mock Get-CimInstance { throw [Exception]::new('Provider unavailable') }
            Get-WpbdCim Win32_Service $errors -Status ([ref]$status) | Out-Null
            $status | Should Be 'Unavailable'
        }
        It 'keeps collecting metadata when an individual image lookup throws' {
            Mock Initialize-WpbdImageQuery {}
            Mock Get-WpbdImageEvidence { throw 'Process vanished during native enrichment' }
            Mock Get-WpbdCim {
                param($Class)
                if($Class -eq 'Win32_Service') { [pscustomobject]@{ProcessId=55;Name='ServiceA'} }
                else { [pscustomobject]@{ProcessId=55;Name='agent.exe';CreationDate=[datetime]::UtcNow.AddMinutes(-1);ParentProcessId=0} }
            }
            $timing=$null
            $rows=@(Get-WpbdProcessMetadata ([ordered]@{}) -Phase Before -Timing ([ref]$timing))
            $rows.Count | Should Be 1
            $rows[0].PathStatus | Should Be 'LookupUnavailable'
            $rows[0].Services[0] | Should Be 'ServiceA'
            $timing.ImageLookups | Should Be 1
        }
        It 'bounds enrichment work and still returns skipped process rows' {
            Mock Initialize-WpbdImageQuery { Start-Sleep -Milliseconds 2100 }
            Mock Get-WpbdImageEvidence { throw 'Must not be called after the budget' }
            Mock Get-WpbdCim {
                param($Class)
                if($Class -eq 'Win32_Process') { [pscustomobject]@{ProcessId=55;Name='agent.exe';CreationDate=[datetime]::UtcNow.AddMinutes(-1);ParentProcessId=0} }
            }
            $timing=$null
            $rows=@(Get-WpbdProcessMetadata ([ordered]@{}) -Timing ([ref]$timing))
            $rows.Count | Should Be 1
            $rows[0].PathStatus | Should Be 'LookupBudgetExceeded'
            $timing.ImageLookups | Should Be 0
            Assert-MockCalled Get-WpbdImageEvidence -Times 0 -Exactly -Scope It
        }
    }
}

Describe 'WPBD diagnostic engine' {
    BeforeAll {
        $script:entry = Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-WPBD.ps1'

        function New-TestMetrics {
            param(
                [switch] $Cpu, [switch] $CpuSpike, [switch] $HighMemory, [switch] $Paging,
                [switch] $Disk, [switch] $DiskBusy, [switch] $LowSpace, [switch] $Incomplete
            )
            $samples = @(foreach ($slot in 1..5) {
                [pscustomobject]@{
                    Slot = $slot; ElapsedSeconds = $slot * 2
                    TimestampUtc = ('2025-01-02T10:10:{0:00}.0000000+00:00' -f ($slot * 2))
                    CpuTotalPercent = $(if ($Cpu -or ($CpuSpike -and $slot -eq 1)) { 95 } elseif (-not $Incomplete) { $slot * 10 } else { $null })
                    LogicalProcessors = @()
                    Memory = [pscustomobject]@{
                        AvailableBytes = $(if ($HighMemory -or $Paging) { 256MB } else { (2GB + $slot * 1MB) })
                        UsedPercent = $(if ($HighMemory -or $Paging) { 96.875 } else { 100 * (1 - (2GB + $slot * 1MB) / 8GB) })
                        CommitPercent = $(if ($Paging) { 94 } else { 60 })
                        CommittedBytes = 8GB; CommitLimitBytes = 16GB
                        PageReadsPerSecond = $(if ($Paging) { 40 } else { 0 })
                        PagesInputPerSecond = $(if ($Paging) { 200 } else { 0 })
                    }
                    Disks = @(if (-not $Incomplete) {
                        [pscustomobject]@{
                            Name = '0 C:'; ActivePercent = $(if ($Disk -or $DiskBusy) { 100 } else { 5 })
                            ReadsPerSecond = 10; WritesPerSecond = 0; ReadBytesPerSecond = 4KB
                            WriteBytesPerSecond = 0; ReadOperationsWithLatency = 20
                            ReadLatencyMs = $(if ($Disk) { 45 } else { 1 })
                            WriteOperationsWithLatency = $null; WriteLatencyMs = $null
                            QueueLength = $(if ($Disk -or $DiskBusy) { 5 } else { 0 })
                        }
                    })
                    Processes = @([pscustomobject]@{
                        Id = 42; Name = 'worker<script>'; StartUtc = '2025-01-02T10:00:00.0000000Z'
                        CpuSeconds = ($slot * 0.25); CpuIntervalSeconds = 2
                        CpuPercent = ($slot * 3.125); PrivateBytes = (500MB + $slot * 1MB); WorkingSetBytes = 300MB
                    })
                }
            })
            [pscustomobject]@{
                Configuration = [pscustomobject]@{ DurationSeconds = 10; SampleIntervalSeconds = 2; ExpectedSamples = 5 }
                System = [pscustomobject]@{
                    ComputerName = 'TEST<PC>'; LogicalProcessorCount = 4; InstalledMemoryBytes = 8GB; VisibleMemoryBytes = 8GB
                }
                StartedUtc = '2025-01-02T10:10:00.0000000+00:00'
                CompletedUtc = '2025-01-02T10:10:10.0000000+00:00'; ActualDurationSeconds = 10
                Samples = $samples; CriticalSystemEvents = @(); CollectionErrors = @()
                Drives = @([pscustomobject]@{
                    Name = 'C:'; CapacityBytes = 100GB
                    FreeBytes = $(if ($LowSpace) { 1GB } else { 60GB })
                    FreePercent = $(if ($LowSpace) { 1 } else { 60 })
                })
            }
        }

        function Set-TestMemory {
            param($Metrics, $VisibleBytes, $AvailableBytes, $PageReads = 0, $Commit = 60)
            $Metrics.System.VisibleMemoryBytes = $VisibleBytes
            foreach ($sample in $Metrics.Samples) {
                $sample.Memory.AvailableBytes = $AvailableBytes
                $sample.Memory.UsedPercent = 100 * (1 - $AvailableBytes / $VisibleBytes)
                $sample.Memory.PageReadsPerSecond = $PageReads
                $sample.Memory.CommitPercent = $Commit
            }
        }
    }

    Context 'parameter validation' {
        It 'rejects a non-positive duration' {
            { & $script:entry -DurationSeconds 0 } | Should Throw
        }
        It 'rejects a non-positive interval' {
            { & $script:entry -SampleIntervalSeconds 0 } | Should Throw
        }
        It 'rejects an interval longer than the duration' {
            { & $script:entry -DurationSeconds 3 -SampleIntervalSeconds 4 } | Should Throw
        }
        It 'rejects a non-filesystem report provider' {
            { & $script:entry -OutputPath Env:PATH } | Should Throw
        }
        It 'rejects invalid threshold overrides' {
            { Get-WpbdAnalysis (New-TestMetrics) -ThresholdOverrides @{ SustainedFraction = 1.1 } } | Should Throw
        }
    }

    Context 'raw counter conversion' {
        InModuleScope WPBD {
            It 'subtracts large timestamps exactly and derives fractional CPU utilisation' {
                $a = [pscustomobject]@{ Timestamp_Sys100NS = [uint64] 134000000000000001; PercentProcessorTime = 400 }
                $b = [pscustomobject]@{ Timestamp_Sys100NS = [uint64] 134000000000000101; PercentProcessorTime = 475 }
                (Convert-WpbdCpu $a $b) | Should Be 25
            }
            It 'normalises process CPU time by elapsed time and logical processors' {
                $a = [pscustomobject]@{ StartUtc = 'same'; ElapsedSeconds = 1; TotalCpuSeconds = 100 }
                $b = [pscustomobject]@{ StartUtc = 'same'; ElapsedSeconds = 3.5; TotalCpuSeconds = 102 }
                $process = Convert-WpbdProcess $a $b 4
                $process.CpuPercent | Should Be 20
                $process.CpuSeconds | Should Be 2
            }
            It 'discards CPU deltas across process identity changes' {
                $a = [pscustomobject]@{ Id = 42; StartUtc = 'old'; ElapsedSeconds = 1; TotalCpuSeconds = 1 }
                $b = [pscustomobject]@{ Id = 42; StartUtc = 'new'; ElapsedSeconds = 2; TotalCpuSeconds = 3 }
                (Convert-WpbdProcess $a $b 4).CpuPercent | Should BeNullOrEmpty
            }
            It 'calculates physical use, commit usage and paging rates from their own denominators' {
                $a = [pscustomobject]@{ Frequency_PerfTime = 1000; Timestamp_PerfTime = 1000; PageReadsPersec = 10; PagesInputPersec = 20 }
                $b = [pscustomobject]@{ Frequency_PerfTime = 1000; Timestamp_PerfTime = 3000
                    AvailableBytes = 1GB; CommittedBytes = 9GB; CommitLimit = 12GB; PageReadsPersec = 18; PagesInputPersec = 60
                    FreeAndZeroPageListBytes = 256MB; ModifiedPageListBytes = 300MB; PagesOutputPersec = 8 }
                $memory = Convert-WpbdMemory $a $b 4GB
                $memory.UsedPercent | Should Be 75
                $memory.AvailablePercent | Should Be 25
                $memory.CommitPercent | Should Be 75
                $memory.PageReadsPerSecond | Should Be 4
                $memory.PagesInputPerSecond | Should Be 20
                $memory.FreeAndZeroPageListBytes | Should Be 256MB
                $memory.ModifiedPageListBytes | Should Be 300MB
                $memory.PagesOutputPerSecond | Should BeNullOrEmpty
            }
            It 'converts fractional disk active time, IOPS, throughput and operation latency' {
                $a = [pscustomobject]@{
                    Frequency_PerfTime = 1000; Timestamp_PerfTime = 1000; PercentIdleTime = 1000; PercentIdleTime_Base = 10000
                    DiskReadsPersec = 12; DiskReadBytesPersec = 4096; AvgDisksecPerRead = 100; AvgDisksecPerRead_Base = 12
                    DiskWritesPersec = 0; AvgDisksecPerWrite = 0; AvgDisksecPerWrite_Base = 0
                }
                $b = [pscustomobject]@{
                    Name = '0 C:'; Frequency_PerfTime = 1000; Timestamp_PerfTime = 3000
                    PercentIdleTime = 8500; PercentIdleTime_Base = 20000; CurrentDiskQueueLength = 3
                    DiskReadsPersec = 20; DiskReadBytesPersec = 12288; AvgDisksecPerRead = 132; AvgDisksecPerRead_Base = 20
                    DiskWritesPersec = 0; AvgDisksecPerWrite = 0; AvgDisksecPerWrite_Base = 0
                }
                $disk = Convert-WpbdDisk $a $b
                $disk.ActivePercent | Should Be 25
                $disk.ReadsPerSecond | Should Be 4
                $disk.ReadBytesPerSecond | Should Be 4096
                $disk.ReadLatencyMs | Should Be 4
                $disk.WriteLatencyMs | Should BeNullOrEmpty
                ($disk | ConvertTo-Json -Compress) | Should Match '"WriteLatencyMs":null'
                $disk.WritesPerSecond | Should Be 0
                $disk.QueueLength | Should Be 3
            }
            It 'keeps a missing or reset counter unavailable' {
                (Get-WpbdDelta 100 23) | Should BeNullOrEmpty
                (Get-WpbdDelta $null 23) | Should BeNullOrEmpty
                (Get-WpbdDelta 0 0) | Should Be 0
            }
            It 'records a query failure and continues to collect independent metrics' {
                Mock Get-CimInstance {
                    if ($ClassName -like '*PhysicalDisk') { throw 'Synthetic provider failure' }
                    [pscustomobject]@{ Name = '_Total'; AvailableBytes = 123; Timestamp_Sys100NS = 100; PercentProcessorTime = 25 }
                }
                Mock Get-Process {}
                $errors = [ordered]@{}
                $state = @{ PreferredClass = 'Fast'; FallbackClass = 'Backup'; NextClass = 'Fast'; SelectedClass = $null; ConsecutiveFailures = 0 }
                $first = Get-WpbdSnapshot ([Diagnostics.Stopwatch]::StartNew()) $errors $state -Baseline
                Get-WpbdSnapshot ([Diagnostics.Stopwatch]::StartNew()) $errors $state | Out-Null
                $first.Memory.AvailableBytes | Should Be 123
                $first.Cpu.Count | Should Be 1
                $first.Disks.Count | Should Be 0
                @($errors.Values)[0].Code | Should Be 'QueryFailed'
                @($errors.Values)[0].Count | Should Be 2
            }
            It 'chooses the processor provider with one successful baseline query' {
                Mock Get-CimInstance { [pscustomobject]@{ Name = '_Total'; Timestamp_Sys100NS = 100; PercentProcessorTime = 25 } }
                $state = @{ PreferredClass = 'Fast'; FallbackClass = 'Backup'; NextClass = 'Fast'; SelectedClass = $null; ConsecutiveFailures = 0 }
                (Get-WpbdProcessorSnapshot $state ([ordered]@{}) -Baseline).Class | Should Be 'Fast'
                $state.SelectedClass | Should Be 'Fast'
                Assert-MockCalled Get-CimInstance -Exactly -Times 1 -Scope It
            }
            It 'caches the fallback selected when the initial processor query times out' {
                Mock Get-CimInstance {
                    if ($ClassName -eq 'Fast') { throw [TimeoutException]::new('Synthetic processor timeout') }
                    [pscustomobject]@{ Name = '_Total'; Timestamp_Sys100NS = 100; PercentProcessorTime = 25 }
                }
                $state = @{ PreferredClass = 'Fast'; FallbackClass = 'Backup'; NextClass = 'Fast'; SelectedClass = $null; ConsecutiveFailures = 0 }
                $errors = [ordered]@{}
                (Get-WpbdProcessorSnapshot $state $errors -Baseline).Class | Should Be 'Backup'
                (Get-WpbdProcessorSnapshot $state $errors).Class | Should Be 'Backup'
                $state.SelectedClass | Should Be 'Backup'
                $errors['Fast/Timeout'].Count | Should Be 1
                Assert-MockCalled Get-CimInstance -Exactly -Times 1 -Scope It -ParameterFilter { $ClassName -eq 'Fast' }
                Assert-MockCalled Get-CimInstance -Exactly -Times 2 -Scope It -ParameterFilter { $ClassName -eq 'Backup' }
            }
            It 'retries a temporarily unavailable processor provider and only measures valid pairs' {
                $script:wpbdAttempt = 0
                Mock Get-CimInstance {
                    $script:wpbdAttempt++
                    if ($script:wpbdAttempt -eq 2) { throw 'Transient error' }
                    [pscustomobject]@{ Name = '_Total'; Timestamp_Sys100NS = $script:wpbdAttempt * 100; PercentProcessorTime = $script:wpbdAttempt * 25 }
                }
                $state = @{ PreferredClass = 'Fast'; FallbackClass = 'Backup'; NextClass = 'Fast'; SelectedClass = $null; ConsecutiveFailures = 0 }
                $errors = [ordered]@{}
                $snapshots = foreach ($attempt in 1..4) {
                    $reading = Get-WpbdProcessorSnapshot $state $errors -Baseline:($attempt -eq 1)
                    [pscustomobject]@{ ProcessorCounterClass = $reading.Class; Cpu = $reading.Rows }
                }
                (Get-WpbdCpuMeasurement $snapshots[0] $snapshots[1]).Status | Should Be 'ProviderUnavailable'
                (Get-WpbdCpuMeasurement $snapshots[1] $snapshots[2]).Status | Should Be 'BaselineUnavailable'
                (Get-WpbdCpuMeasurement $snapshots[2] $snapshots[3]).Percent | Should Be 75
                $state.SelectedClass | Should Be 'Fast'
                Assert-MockCalled Get-CimInstance -Exactly -Times 0 -Scope It -ParameterFilter { $ClassName -eq 'Backup' }
            }
            It 'switches after repeated failures without calculating cross-provider CPU deltas' {
                Mock Get-CimInstance {
                    if ($ClassName -eq 'Fast') { throw 'Synthetic failure' }
                    [pscustomobject]@{ Name = '_Total'; Timestamp_Sys100NS = 500; PercentProcessorTime = 70 }
                }
                $state = @{ PreferredClass = 'Fast'; FallbackClass = 'Backup'; NextClass = 'Fast'; SelectedClass = 'Fast'; ConsecutiveFailures = 0 }
                $errors = [ordered]@{}
                (Get-WpbdProcessorSnapshot $state $errors).Class | Should Be 'Fast'
                $previous = Get-WpbdProcessorSnapshot $state $errors
                $fallback = Get-WpbdProcessorSnapshot $state $errors
                $state.SelectedClass | Should Be 'Backup'
                $a = [pscustomobject]@{ ProcessorCounterClass = $previous.Class; Cpu = @{ _Total = @{ Timestamp_Sys100NS = 400; PercentProcessorTime = 30 } } }
                $b = [pscustomobject]@{ ProcessorCounterClass = $fallback.Class; Cpu = $fallback.Rows }
                $result = Get-WpbdCpuMeasurement $a $b
                $result.Percent | Should BeNullOrEmpty
                $result.Status | Should Be 'ProviderChanged'
            }
            It 'keeps invalid idle deltas missing and accepts a measured zero' {
                $a = @{ Timestamp_Sys100NS = 100; PercentProcessorTime = 500 }
                $b = @{ Timestamp_Sys100NS = 200; PercentProcessorTime = 610 }
                (Convert-WpbdCpu $a $b) | Should BeNullOrEmpty
                $b.PercentProcessorTime = 600
                (Convert-WpbdCpu $a $b) | Should Be 0
                $b.Timestamp_Sys100NS = 100
                (Convert-WpbdCpu $a $b) | Should BeNullOrEmpty
            }
            It 'records collection overrun, delayed scheduling and the final partial slot' {
                $decision = Get-WpbdSamplingSlot 2 5 6.1 2 9 6
                $decision.Slot | Should Be 3
                $decision.Missed.FirstSlot | Should Be 2
                $decision.Missed.Count | Should Be 1
                $decision.Missed.Reason | Should Be 'PreviousCaptureOverran'
                (Get-WpbdSamplingSlot 2 5 6.1 2 9 3.9).Missed.Reason | Should Be 'SchedulerDelay'
                (Get-WpbdSamplingSlot 5 5 9.1 2 9 8.3).Slot | Should Be 5
            }
            It 'continues after a process exits while its identity is being read' {
                Mock Get-Process {
                    $exited = [pscustomobject]@{ Id = 40 }
                    $exited | Add-Member ScriptProperty ProcessName { throw 'Process exited' }
                    $exited | Add-Member ScriptMethod Dispose {}
                    $active = [pscustomobject]@{
                        Id = 41; ProcessName = 'active'; StartTime = [datetime] '2025-01-02'
                        TotalProcessorTime = [timespan]::FromSeconds(2); PrivateMemorySize64 = 123; WorkingSet64 = 456
                    }
                    $active | Add-Member ScriptMethod Dispose {}
                    $active | Add-Member ScriptMethod get_StartTime { $this.StartTime }
                    $exited
                    $active
                }
                $errors = [ordered]@{}
                $observed = @(Get-WpbdProcessSnapshot ([Diagnostics.Stopwatch]::StartNew()) $errors)
                $observed.Count | Should Be 1
                $observed[0].Id | Should Be 41
                $observed[0].PrivateBytes | Should Be 123
                $errors['Processes/InstanceUnavailable'].Count | Should Be 1
            }
        }
    }

    Context 'diagnostic analysis' {
        It 'summarises normal CPU, memory, disk and process statistics' {
            $report = Get-WpbdAnalysis (New-TestMetrics)
            $report.Assessment.Category | Should Be 'No clear bottleneck detected'
            $report.MemoryAssessment.Category | Should Be 'Normal memory operation'
            $report.Advisories.Count | Should Be 0
            $report.Statistics.Cpu.Average | Should Be 30
            $report.Statistics.Cpu.Maximum | Should Be 50
            $report.Statistics.Memory.AvailableBytes.Average | Should Be (2GB + 3MB)
            $report.Statistics.Memory.AvailableBytes.Minimum | Should Be (2GB + 1MB)
            $report.Statistics.Memory.PageReadsPerSecond.Average | Should Be 0
            $report.Statistics.Disks[0].ReadLatencyMs.Average | Should Be 1
            $report.Statistics.Disks[0].WriteLatencyMs.Average | Should BeNullOrEmpty
            $report.Statistics.Processes.Leaders.AverageCpuPercent[0].AverageCpuPercent | Should Be 9.375
            $report.Statistics.Processes.Leaders.PeakCpuPercent[0].PeakCpuPercent | Should Be 15.625
            $report.Statistics.Processes.Leaders.CumulativeCpuSeconds[0].CumulativeCpuSeconds | Should Be 3.75
            $report.Statistics.Processes.Leaders.PeakPrivateBytes[0].PeakPrivateBytes | Should Be 505MB
            $report.Statistics.Processes.Leaders.PeakWorkingSetBytes[0].PeakWorkingSetBytes | Should Be 300MB
        }
        It 'weights latency by completed operations' {
            $metrics = New-TestMetrics
            $metrics.Samples[0].Disks[0].ReadOperationsWithLatency = 80
            $metrics.Samples[0].Disks[0].ReadLatencyMs = 5
            (Get-WpbdAnalysis $metrics).Statistics.Disks[0].ReadLatencyMs.Average | Should Be 3
        }
        It 'identifies sustained CPU saturation' {
            $report = Get-WpbdAnalysis (New-TestMetrics -Cpu)
            $report.Assessment.Category | Should Be 'CPU bottleneck'
            $report.Statistics.Cpu.PercentAboveThreshold | Should Be 100
        }
        It 'does not classify a CPU spike as saturation' {
            $report = Get-WpbdAnalysis (New-TestMetrics -CpuSpike)
            $report.Assessment.Category | Should Be 'No clear bottleneck detected'
            $report.Statistics.Cpu.PercentAboveThreshold | Should Be 20
        }
        It 'supports threshold overrides' {
            (Get-WpbdAnalysis (New-TestMetrics -Cpu) -ThresholdOverrides @{ CpuPercent = 97 }).Assessment.Category |
                Should Be 'No clear bottleneck detected'
        }
        It 'requires corroboration for high physical memory usage' {
            $result = Get-WpbdAnalysis (New-TestMetrics -HighMemory)
            $result.Assessment.Category | Should Be 'No clear bottleneck detected'
            $result.MemoryAssessment.Category | Should Be 'Elevated memory utilisation'
            $result.Advisories[0].Category | Should Be 'Elevated memory utilisation'
            @($result.Findings | Where-Object Category -eq 'Memory pressure').Count | Should Be 0
        }
        It 'advises on elevated utilisation with substantial available RAM' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 64GB 8GB
            (Get-WpbdAnalysis $metrics).MemoryAssessment.Category | Should Be 'Elevated memory utilisation'
        }
        It 'advises on reduced headroom and paging at the reported workstation scale' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 15.5GB 1538MB 86
            $report = Get-WpbdAnalysis $metrics
            $report.Assessment.Category | Should Be 'No clear bottleneck detected'
            $report.Advisories[0].Category | Should Be 'Elevated memory utilisation'
            $report.Advisories[0].Observed | Should Match ('{0:N2} GiB' -f (1538MB / 1GB))
        }
        It 'does not infer pressure from hard paging with adequate physical memory' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 16GB 6GB 120
            $report = Get-WpbdAnalysis $metrics
            $report.MemoryAssessment.Category | Should Be 'Normal memory operation'
            $report.Statistics.Memory.PageReadsPerSecond.Average | Should Be 120
        }
        It 'requires headroom and corroboration to occur together' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 16GB 1GB
            foreach ($sample in $metrics.Samples[3..4]) {
                $sample.Memory.AvailableBytes = 6GB
                $sample.Memory.PageReadsPerSecond = 120
                $sample.Memory.CommitPercent = 95
            }
            $report = Get-WpbdAnalysis $metrics
            $report.Statistics.Memory.PressureSamples | Should Be 0
            $report.MemoryAssessment.Category | Should Be 'Elevated memory utilisation'
        }
        It 'recognises potential memory pressure when reduced headroom and paging persist' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 16GB 1GB 25
            $report = Get-WpbdAnalysis $metrics
            $report.Assessment.Category | Should Be 'Memory pressure'
            $report.MemoryAssessment.Category | Should Be 'Potential memory pressure'
            $report.Findings[0].Severity | Should Be 'Warning'
            $report.Findings[0].Confidence | Should Be 'Medium'
            $report.Findings[0].Measurements.PressureWithPagingSamples | Should Be 5
            $report.Advisories.Count | Should Be 0
        }
        It 'identifies severe memory pressure with paging' {
            $report = Get-WpbdAnalysis (New-TestMetrics -Paging)
            $report.Assessment.Category | Should Be 'Memory pressure'
            $report.Findings[0].Severity | Should Be 'Critical'
            $report.Findings[0].Classification | Should Be 'Severe memory pressure'
            $report.MemoryAssessment.Confidence | Should Be 'High'
        }
        It 'uses both absolute and bounded relative headroom rules across RAM capacities' {
            $metrics = New-TestMetrics
            $metrics.System.InstalledMemoryBytes = 64GB
            Set-TestMemory $metrics 8GB 700MB 10
            (Get-WpbdAnalysis $metrics).MemoryAssessment.Category | Should Be 'Potential memory pressure'
            Set-TestMemory $metrics 16GB 1GB 10
            (Get-WpbdAnalysis $metrics).Statistics.Memory.AvailablePercent.Average | Should Be 6.25
            Set-TestMemory $metrics 32GB 1850MB 10
            (Get-WpbdAnalysis $metrics).MemoryAssessment.Category | Should Be 'Potential memory pressure'
            Set-TestMemory $metrics 64GB 3GB 10
            (Get-WpbdAnalysis $metrics).MemoryAssessment.Category | Should Be 'Elevated memory utilisation'
            Set-TestMemory $metrics 64GB 600MB 0 95
            (Get-WpbdAnalysis $metrics).MemoryAssessment.Category | Should Be 'Severe memory pressure'
        }
        It 'never uses installed RAM to supply a missing OS-visible denominator' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 64GB 1GB 120
            $metrics.System.VisibleMemoryBytes = $null
            $report = Get-WpbdAnalysis $metrics
            $report.Statistics.Memory.AvailablePercent.Average | Should BeNullOrEmpty
            $report.MemoryAssessment.Category | Should Be 'Elevated memory utilisation'
        }
        It 'lowers confidence when paging is available and commit is missing' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 16GB 1GB 25 $null
            $report = Get-WpbdAnalysis $metrics
            $report.MemoryAssessment.Category | Should Be 'Potential memory pressure'
            $report.MemoryAssessment.Confidence | Should Be 'Low'
            $report.Statistics.Memory.CommitPercent.Average | Should BeNullOrEmpty
        }
        It 'reports an advisory and an evidence gap when low headroom has unavailable corroboration' {
            $metrics = New-TestMetrics
            Set-TestMemory $metrics 16GB 1GB $null $null
            foreach ($sample in $metrics.Samples) { $sample.Memory.PagesInputPerSecond = $null }
            $report = Get-WpbdAnalysis $metrics
            $report.MemoryAssessment.Category | Should Be 'Elevated memory utilisation'
            $report.Advisories[0].Confidence | Should Be 'Low'
            $report.Assessment.Category | Should Be 'Insufficient diagnostic data'
        }
        It 'reports insufficient memory data when all memory counters are unavailable' {
            $metrics = New-TestMetrics
            foreach ($sample in $metrics.Samples) { $sample.Memory = $null }
            $report = Get-WpbdAnalysis $metrics
            $report.MemoryAssessment.Category | Should Be 'Insufficient memory data'
            $report.SamplingQuality.ValidSamples.MemoryAvailable | Should Be 0
            $report.Statistics.Memory.UsedPercent.Average | Should BeNullOrEmpty
        }
        It 'retains separate rankings for verified identities that reuse a PID' {
            $metrics = New-TestMetrics
            $metrics.Samples[1].Processes[0].StartUtc = '2025-01-02T10:10:02.0000000Z'
            $rank = (Get-WpbdAnalysis $metrics).Statistics.Processes.Leaders.CumulativeCpuSeconds
            $rank.Count | Should Be 2
            $rank[0].CumulativeCpuSeconds | Should Be 3.25
            $rank[1].CumulativeCpuSeconds | Should Be 0.5
        }
        It 'keeps consecutive unverified sightings in a labelled provisional identity' {
            $metrics = New-TestMetrics
            foreach ($sample in $metrics.Samples) {
                $sample.Processes[0].StartUtc = $null
                $sample.Processes[0].CpuSeconds = $null
                $sample.Processes[0].CpuPercent = $null
            }
            $statistics = (Get-WpbdAnalysis $metrics).Statistics.Processes
            $statistics.ObservedInstances | Should Be 1
            $statistics.Leaders.PeakPrivateBytes.Count | Should Be 1
            $statistics.Leaders.PeakPrivateBytes[0].Observations | Should Be 5
            $statistics.All[0].IdentityStatus | Should Be 'Provisional'
            $statistics.Leaders.PeakPrivateBytes[0].PeakPrivateBytes | Should Be 505MB
        }
        It 'reports actual slots, valid counts and measured sampling overhead independently' {
            $metrics = New-TestMetrics
            $metrics.Samples = $metrics.Samples[0, 2, 3, 4]
            $metrics.Samples[1].CpuTotalPercent = $null
            $metrics.Samples[0] | Add-Member -NotePropertyName CollectionTiming -NotePropertyValue ([pscustomobject]@{
                TotalSeconds = 2.5; StartDelaySeconds = 0.25; ProviderSeconds = [pscustomobject]@{ Cpu = 2.2 }
            })
            $metrics | Add-Member -NotePropertyName MissedSlots -NotePropertyValue @([pscustomobject]@{
                FirstSlot = 2; LastSlot = 2; Count = 1; Reason = 'PreviousCaptureOverran'
            })
            $report = Get-WpbdAnalysis $metrics
            $report.SamplingQuality.ExpectedSamples | Should Be 5
            $report.SamplingQuality.ActualSamples | Should Be 4
            $report.SamplingQuality.MissedSampleCount | Should Be 1
            $report.SamplingQuality.MissedSlots[0].Reason | Should Be 'PreviousCaptureOverran'
            $report.SamplingQuality.ValidSamples.CpuTotal | Should Be 3
            $report.SamplingQuality.SamplesOverInterval | Should Be 1
            $report.CollectionTiming.SampleWorkSeconds.Average | Should Be 2.5
            $report.CollectionTiming.ProviderSeconds.Cpu.Maximum | Should Be 2.2
        }
        It 'requires latency evidence even with a busy disk and high queue' {
            (Get-WpbdAnalysis (New-TestMetrics -DiskBusy)).Assessment.Category | Should Be 'No clear bottleneck detected'
        }
        It 'identifies sustained disk latency with matching I/O' {
            (Get-WpbdAnalysis (New-TestMetrics -Disk)).Assessment.Category | Should Be 'Disk I/O bottleneck'
        }
        It 'identifies low volume capacity independently from disk I/O' {
            (Get-WpbdAnalysis (New-TestMetrics -LowSpace)).Assessment.Category | Should Be 'Low disk capacity'
        }
        It 'reports concurrent CPU, memory, latency and capacity problems' {
            $report = Get-WpbdAnalysis (New-TestMetrics -Cpu -Paging -Disk -LowSpace)
            $report.Assessment.Category | Should Be 'Multiple potential bottlenecks'
            $report.Findings.Count | Should Be 4
        }
        It 'retains findings when other measurement categories are incomplete' {
            $report = Get-WpbdAnalysis (New-TestMetrics -Incomplete -LowSpace)
            $report.Assessment.Category | Should Be 'Low disk capacity'
            $report.Findings[1].Category | Should Be 'Insufficient diagnostic data'
            $report.Statistics.Cpu.Average | Should BeNullOrEmpty
        }
        It 'distinguishes empty input from normal system performance' {
            $report = Get-WpbdAnalysis ([pscustomobject]@{ Samples = @() })
            $report.Assessment.Category | Should Be 'Insufficient diagnostic data'
            $report.Statistics.Cpu.Count | Should Be 0
            $report.Statistics.Cpu.PercentAboveThreshold | Should BeNullOrEmpty
        }
    }

    Context '0.6 deterministic diagnostic intelligence' {
        It 'ranks measured CPU contributors and excludes cumulative historical CPU from evidence' {
            $m=New-TestMetrics -Cpu
            $r=Get-WpbdAnalysis $m
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'cpu.sustained'
            $i.SampleSlots.Count | Should Be 5
            $i.PotentialContributors[0].Usage.Average | Should Be 9.375
            $i.PotentialContributors[0].Usage.Maximum | Should Be 15.625
            $i.SupportingEvidence.PSObject.Properties.Name -contains 'LeadingProcesses' | Should Be $false
        }
        It 'links sustained CPU to a verified application using executable evidence' {
            $m=New-TestMetrics -Cpu
            $m | Add-Member ProcessMetadata @([pscustomobject]@{
                Id=42; Identity=("42/" + ([DateTimeOffset]'2025-01-02T10:00:00Z').UtcTicks)
                StartUtc='2025-01-02T10:00:00Z'; Path='C:\Apps\worker.exe'
            })
            $i=(Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -eq 'cpu.sustained'
            $c=$i.PotentialContributors[0]
            $c.ApplicationKey | Should Not BeNullOrEmpty
            $c.AttributionConfidence | Should Be 'High'
            $c.ProcessIdentities[0].Usage.Average | Should Be 9.375
            $c.ProcessIdentities[0].Usage.Maximum | Should Be 15.625
            $c.MeasurementCoverage.ValidSamples | Should Be 5
        }
        It 'caps critical investigation priority on incomplete scheduled evidence' {
            $m=New-TestMetrics -Paging; $m.Configuration.ExpectedSamples=8
            $i=(Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -eq 'memory.pressure'
            $i.Severity | Should Be 'Critical'
            $i.Priority | Should Be 'Medium'
            $i.Confidence | Should Be 'Medium'
        }
        It 'keeps high CPU without process observations and explains missing attribution' {
            $m=New-TestMetrics -Cpu; foreach($s in $m.Samples){$s.Processes=@()}
            $i=(Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -eq 'cpu.sustained'
            $i.PotentialContributors.Count | Should Be 0
            ($i.DataLimitations -join ' ') | Should Match 'No reliably attributed'
            $i.Severity | Should Be 'Warning'
        }
        It 'uses only CPU threshold samples for contributor averages' {
            $m=New-TestMetrics -Cpu
            $m.Samples[3].CpuTotalPercent=10; $m.Samples[4].CpuTotalPercent=10
            $m.Samples[4].Processes[0].CpuPercent=99
            $i=(Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -eq 'cpu.sustained'
            $i.PotentialContributors[0].Usage.Average | Should Be 6.25
            $i.PotentialContributors[0].Usage.Maximum | Should Be 9.375
        }
        It 'distinguishes a logical processor from total CPU saturation' {
            $m=New-TestMetrics
            foreach($s in $m.Samples){$s.LogicalProcessors=@([pscustomobject]@{Name='0,0';Percent=95})}
            $r=Get-WpbdAnalysis $m
            @($r.DiagnosticInsights | Where-Object Id -eq 'cpu.logical/0,0').Count | Should Be 1
            @($r.Findings | Where-Object Category -eq 'CPU bottleneck').Count | Should Be 0
        }
        It 'preserves corroborated severe memory pressure and all memory measurements' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Paging)
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'memory.pressure'
            $i.Title | Should Be 'Severe memory pressure'
            $i.Priority | Should Be 'High'
            $i.SupportingEvidence.PressureWithPagingSamples | Should Be 5
            $i.SupportingEvidence.AvailableBytes.Minimum | Should Be 256MB
            $i.SampleSlots.Count | Should Be 5
            ($i.DataLimitations -join ' ') | Should Match 'not physical RAM'
        }
        It 'keeps potential memory pressure distinct from severe pressure' {
            $m=New-TestMetrics; Set-TestMemory $m 8GB 700MB 40 60
            $i=(Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -eq 'memory.pressure'
            $i.Title | Should Be 'Potential memory pressure'
            $i.Priority | Should Be 'Medium'
        }
        It 'does not promote elevated memory without corroboration to pressure' {
            $r=Get-WpbdAnalysis (New-TestMetrics -HighMemory)
            @($r.DiagnosticInsights | Where-Object Id -eq 'memory.pressure').Count | Should Be 0
            ($r.DiagnosticInsights | Where-Object Id -eq 'memory.elevated').Priority | Should Be 'Informational'
        }
        It 'does not warn for seventy percent physical use and several GiB headroom' {
            $m=New-TestMetrics; Set-TestMemory $m 16GB (4.8GB)
            $r=Get-WpbdAnalysis $m
            $r.MemoryAssessment.Category | Should Be 'Normal memory operation'
            @($r.DiagnosticInsights | Where-Object Category -match 'Memory').Count | Should Be 0
        }
        It 'does not turn large private allocations into a healthy-system bottleneck' {
            $m=New-TestMetrics; foreach($s in $m.Samples){$s.Processes[0].PrivateBytes=20GB}
            $r=Get-WpbdAnalysis $m
            $r.Assessment.Category | Should Be 'No clear bottleneck detected'
            $r.DiagnosticInsights.Count | Should Be 1
            $r.DiagnosticInsights[0].Priority | Should Be 'Informational'
        }
        It 'requires latency and meaningful workload and disclaims disk application ownership' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Disk)
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'disk.io/0 C:'
            $i.SampleSlots.Count | Should Be 5
            $i.SupportingEvidence.ReadsPerSecond.Average | Should Be 10
            $i.PotentialContributors.Count | Should Be 0
            ($i.DataLimitations -join ' ') | Should Match 'cannot reliably identify'
        }
        It 'does not treat throughput or active time as a disk bottleneck' {
            $m=New-TestMetrics -DiskBusy; foreach($s in $m.Samples){$s.Disks[0].ReadBytesPerSecond=1GB}
            @((Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -like 'disk.io/*').Count | Should Be 0
        }
        It 'distinguishes low capacity from I/O pressure with no fabricated timed slots' {
            $r=Get-WpbdAnalysis (New-TestMetrics -LowSpace)
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'storage.capacity/C:'
            $i.SampleSlots.Count | Should Be 0
            @($r.DiagnosticInsights | Where-Object Id -like 'disk.io/*').Count | Should Be 0
        }
        It 'adds bounded context to simultaneous CPU and memory findings' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu -Paging)
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'context.cpu-memory'
            $i.SampleSlots.Count | Should Be 5
            $i.Priority | Should Be 'Informational'
            $i.Interpretation | Should Match 'does not establish causation'
        }
        It 'reports CPU and disk overlap only when actual sample slots overlap' {
            $m=New-TestMetrics -Cpu -Disk
            $r=Get-WpbdAnalysis $m
            ($r.DiagnosticInsights | Where-Object Id -eq 'context.cpu-disk/0 C:').SampleSlots.Count | Should Be 5
            foreach($s in $m.Samples){$s.CpuTotalPercent=0}
            @((Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -like 'context.cpu-disk/*').Count | Should Be 0
        }
        It 'never describes missing CPU as normal and preserves nulls' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Incomplete)
            @($r.DiagnosticInsights | Where-Object Id -eq 'operation.normal').Count | Should Be 0
            $r.Statistics.Cpu.Average | Should BeNullOrEmpty
            ($r.DiagnosticInsights | Where-Object Id -eq 'quality.insufficient').Confidence | Should Be 'Low'
        }
        It 'retains unresolved process identities without assigning an application' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu)
            $c=($r.DiagnosticInsights | Where-Object Id -eq 'cpu.sustained').PotentialContributors[0]
            $c.ApplicationKey | Should BeNullOrEmpty
            $c.Name | Should Match 'ownership unresolved'
            $c.ProcessIdentities.Count | Should Be 1
        }
        It 'keeps restricted attribution separate from resource confidence' {
            $m=New-TestMetrics -Cpu
            foreach($s in $m.Samples){$s.Processes[0] | Add-Member MetadataAccess Restricted}
            $r=Get-WpbdAnalysis $m
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'cpu.sustained'
            $i.Confidence | Should Be 'High'
            $i.PotentialContributors[0].AttributionConfidence | Should Be 'Low'
            $i.PotentialContributors[0].ApplicationKey | Should BeNullOrEmpty
        }
        It 'caps high confidence when scheduled sampling is incomplete' {
            $m=New-TestMetrics -Cpu; $m.Configuration.ExpectedSamples=8
            $i=(Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -eq 'cpu.sustained'
            $i.Confidence | Should Be 'Medium'
            ($i.DataLimitations -join ' ') | Should Match 'Partial coverage'
        }
        It 'keeps normal operation concise and acknowledges intermittent symptoms' {
            $r=Get-WpbdAnalysis (New-TestMetrics)
            $r.DiagnosticInsights.Count | Should Be 1
            $r.DiagnosticInsights[0].SuggestedInvestigation.Count | Should Be 1
            ($r.DiagnosticInsights[0].DataLimitations -join ' ') | Should Match 'intermittent'
        }
        It 'uses same-sample application totals rather than sums of process peaks' {
            $m=New-TestMetrics -Paging
            foreach($s in $m.Samples){
                $s.Processes=@(
                    [pscustomobject]@{Id=41;Name='app';StartUtc='2025-01-02T10:00:00Z';Path='C:\Apps\app.exe';PrivateBytes=$(if($s.Slot -eq 1){800MB}else{300MB});WorkingSetBytes=200MB},
                    [pscustomobject]@{Id=42;Name='app';StartUtc='2025-01-02T10:00:01Z';Path='C:\Apps\app.exe';PrivateBytes=$(if($s.Slot -eq 2){800MB}else{300MB});WorkingSetBytes=200MB})
            }
            $m | Add-Member ProcessMetadata @(
                [pscustomobject]@{Id=41;Identity=("41/" + ([DateTimeOffset]'2025-01-02T10:00:00Z').UtcTicks);StartUtc='2025-01-02T10:00:00Z';Path='C:\Apps\app.exe'},
                [pscustomobject]@{Id=42;Identity=("42/" + ([DateTimeOffset]'2025-01-02T10:00:01Z').UtcTicks);StartUtc='2025-01-02T10:00:01Z';Path='C:\Apps\app.exe'})
            $c=((Get-WpbdAnalysis $m).DiagnosticInsights | Where-Object Id -eq 'memory.pressure').PotentialContributors[0]
            $c.Usage.Maximum | Should Be 1100MB
            $c.ProcessIdentities.Count | Should Be 2
        }
        It 'renders structured recorded insight evidence and escapes HTML without raw detail JSON' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu -Paging -Disk)
            $paths=Export-WpbdReport $r $TestDrive
            $j=Get-Content $paths.JsonPath -Raw | ConvertFrom-Json
            $h=Get-Content $paths.HtmlPath -Raw
            foreach($i in $j.DiagnosticInsights){
                $p=& (Get-Module WPBD) {param($x) Get-WpbdInsightPresentation $x} $i
                $h.Contains([Net.WebUtility]::HtmlEncode($p.Observation)) | Should Be $true
                $h.Contains([Net.WebUtility]::HtmlEncode($i.DetailText)) | Should Be $false
                $h.Contains([Net.WebUtility]::HtmlEncode($i.Title)) | Should Be $true
            }
            $h | Should Match 'Application 0.6.2'
            $h | Should Not Match 'Version 0.2|worker<script>'
        }
        It 'does not invent historical insights when exporting an older report' {
            $r=Get-WpbdAnalysis (New-TestMetrics)
            $r.PSObject.Properties.Remove('DiagnosticInsights'); $r.PSObject.Properties.Remove('ApplicationVersion'); $r.PSObject.Properties.Remove('EngineVersion')
            $paths=Export-WpbdReport $r $TestDrive
            $h=Get-Content $paths.HtmlPath -Raw
            $h | Should Not Match '<h2>Diagnostic Insights</h2>'
            $h | Should Match 'Application not recorded'
        }
        It 'assigns stable IDs and reproducible insight payloads' {
            $m=New-TestMetrics -Cpu -Paging -Disk -LowSpace
            $a=(Get-WpbdAnalysis $m).DiagnosticInsights | ConvertTo-Json -Depth 16
            $b=(Get-WpbdAnalysis $m).DiagnosticInsights | ConvertTo-Json -Depth 16
            $a | Should Be $b
        }
    }

    Context '0.6.1 presentation formatting and grouping' {
        It 'formats memory in GiB and MiB without changing values' {
            & (Get-Module WPBD) { Format-WpbdDisplayValue 1790373888 bytes } | Should Be '1.67 GiB'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 1520488448 bytes } | Should Be '1.42 GiB'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 663MB bytes } | Should Be '663 MiB'
        }
        It 'formats utilisation latency paging throughput and unavailable values consistently' {
            & (Get-Module WPBD) { Format-WpbdDisplayValue 90.7432911177168 percent } | Should Be '90.7%'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 22.25 percent } | Should Be '22.3%'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 0.005 ms } | Should Be '0.01 ms'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 0.450677637 ms } | Should Be '0.45 ms'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 1MB 'bytes/s' } | Should Be '1 MiB/s'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 40 'reads/s' } | Should Be '40 reads/s'
            & (Get-Module WPBD) { Format-WpbdDisplayValue $null bytes } | Should Be 'Unavailable'
            & (Get-Module WPBD) { Format-WpbdDisplayValue 0 percent } | Should Be '0.0%'
        }
        It 'uses human labels and retains unavailable paging evidence' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Paging)
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'memory.pressure'
            $p=& (Get-Module WPBD) {param($x) Get-WpbdInsightPresentation $x} $i
            ($p.Measurements | Where-Object Key -eq 'AvailableBytes').Minimum | Should Be '256 MiB'
            ($p.Measurements | Where-Object Key -eq 'PagesOutputPerSecond').Average | Should Be 'Unavailable'
            $p.Observation | Should Match '96.9%'
            $i.SupportingEvidence.AvailableBytes.Minimum | Should Be 256MB
        }
        It 'preserves contributor ranking limits the initial view and keeps full member identities' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu)
            $i=$r.DiagnosticInsights | Where-Object Id -eq 'cpu.sustained'
            $c=$i.PotentialContributors[0]
            $i.PotentialContributors=@(foreach($n in 1..7){$clone=$c | ConvertTo-Json -Depth 10 | ConvertFrom-Json;$clone.Name="Candidate $n";$clone})
            $p=& (Get-Module WPBD) {param($x) Get-WpbdInsightPresentation $x} $i
            $p.Contributors.Count | Should Be 5
            $p.AllContributors.Count | Should Be 7
            $p.Contributors[0].Name | Should Be 'Candidate 1'
            $p.Contributors[4].Name | Should Be 'Candidate 5'
            $p.AllContributors[6].Details | Should Match 'identity:'
            $p.Contributors[0].Attribution | Should Be 'Ownership unresolved'
            $p.Contributors[0].Kind | Should Be 'Individual process'
        }
        It 'shows identified application ownership separately from unresolved processes' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu)
            $c=($r.DiagnosticInsights | Where-Object Id -eq 'cpu.sustained').PotentialContributors[0]
            $c.ApplicationKey='application/example';$c.AttributionConfidence='Medium'
            $p=& (Get-Module WPBD) {param($x) Get-WpbdContributorPresentation $x} $c
            $p.Kind | Should Be 'Application group'
            $p.Attribution | Should Be 'Ownership evidence: Medium confidence'
            $c.ApplicationKey='service/example'
            (& (Get-Module WPBD) {param($x) Get-WpbdContributorPresentation $x} $c).Kind | Should Be 'Process group'
        }
        It 'limits initial steps without reordering or discarding recorded recommendations' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu);$i=$r.DiagnosticInsights[0]
            $i.SuggestedInvestigation=@('First','Second','Third','Fourth')
            $p=& (Get-Module WPBD) {param($x) Get-WpbdInsightPresentation $x} $i
            $p.Steps.Count | Should Be 3
            $p.Steps[0] | Should Be '1. First'
            $p.AllSteps[3] | Should Be '4. Fourth'
        }
        It 'groups advisory-only reports without duplicating normal cards or memory advisories' {
            $r=Get-WpbdAnalysis (New-TestMetrics -HighMemory)
            $paths=Export-WpbdReport $r $TestDrive;$h=Get-Content $paths.HtmlPath -Raw
            $h | Should Match 'No clear bottleneck detected. Elevated memory utilisation.'
            ([regex]::Matches($h,'<h3>Elevated memory utilisation</h3>')).Count | Should Be 1
            $h | Should Not Match '<h3>No clear bottleneck detected</h3>|<h2>Advisories</h2>'
            $r.DiagnosticInsights.Count | Should Be 2
            $r.Advisories.Count | Should Be 1
        }
        It 'keeps normal operation short with the original detailed resource sections available' {
            $paths=Export-WpbdReport (Get-WpbdAnalysis (New-TestMetrics)) $TestDrive
            $h=Get-Content $paths.HtmlPath -Raw
            $h | Should Not Match '<article class="finding insight">|<h2>Diagnostic Insights</h2>'
            $h | Should Match '0 significant findings; 0 advisories|<h2>CPU</h2>|<h2>Memory</h2>'
        }
        It 'counts original significant findings and advisories without adding context as problems' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu -Paging -Disk -LowSpace)
            $p=& (Get-Module WPBD) {param($x) Get-WpbdOverview $x} $r
            $p.Counts | Should Be '4 significant findings; 0 advisories.'
            $p.Focus | Should Match 'Severe memory pressure'
        }
        It 'retains incomplete evidence and does not format missing CPU as healthy zero' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Incomplete)
            $paths=Export-WpbdReport $r $TestDrive;$h=Get-Content $paths.HtmlPath -Raw
            $h | Should Match 'Insufficient diagnostic data|Unavailable'
            $h | Should Not Match '<h3>No clear bottleneck detected</h3>'
            $r.Statistics.Cpu.Average | Should BeNullOrEmpty
        }
        It 'encodes names references and process identities inside semantic tables and details' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu)
            $r.DiagnosticInsights[0].PotentialContributors[0].Name='<script>alert(1)</script>'
            $r.DiagnosticInsights[0].MeasurementReferences=@('<img src=x onerror=alert(1)>')
            $paths=Export-WpbdReport $r $TestDrive;$h=Get-Content $paths.HtmlPath -Raw
            $h | Should Match '&lt;script&gt;alert|&lt;img'
            $h | Should Not Match '<script|<img|<pre|"SupportingEvidence"|"AvailableBytes"\s*:'
            $h | Should Match '<summary>Technical evidence|<ol>|scope=''col''|tabindex="0"'
        }
        It 'keeps historical findings when insights are absent' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Cpu -HighMemory)
            $r.PSObject.Properties.Remove('DiagnosticInsights')
            $paths=Export-WpbdReport $r $TestDrive;$h=Get-Content $paths.HtmlPath -Raw
            $h | Should Match '<h2>Significant findings</h2>|<h2>Advisories</h2>'
            $h | Should Not Match '<h2>Diagnostic Insights</h2>'
        }
        It 'displays application engine and schema versions independently' {
            $paths=Export-WpbdReport (Get-WpbdAnalysis (New-TestMetrics)) $TestDrive
            $h=Get-Content $paths.HtmlPath -Raw
            $h | Should Match 'Application 0.6.2 &middot; Engine 0.6.0 &middot; Schema 0.3'
        }
        It 'preserves full precision and the original structured insight payload during export' {
            $r=Get-WpbdAnalysis (New-TestMetrics -Paging);$i=$r.DiagnosticInsights[0]
            $i.SupportingEvidence.UsedPercent.Average=90.7432911177168
            $before=$i | ConvertTo-Json -Depth 16 -Compress
            $paths=Export-WpbdReport $r $TestDrive
            ($i | ConvertTo-Json -Depth 16 -Compress) | Should Be $before
            $j=Get-Content $paths.JsonPath -Raw | ConvertFrom-Json
            $j.DiagnosticInsights[0].SupportingEvidence.UsedPercent.Average | Should Be 90.7432911177168
        }
        It 'renders a large captured timeline without embedding raw insight JSON' {
            $m=New-TestMetrics -Cpu
            $m.Samples=@(foreach($n in 1..100){foreach($s in $m.Samples){$s}})
            $m.Configuration.ExpectedSamples=500
            $r=Get-WpbdAnalysis $m
            $paths=Export-WpbdReport $r $TestDrive
            $r.Samples.Count | Should Be 500
            (Get-Content $paths.HtmlPath -Raw) | Should Not Match '"SupportingEvidence"|"Average"\s*:'
        }
    }

    Context '0.6.2 incomplete elevation gate and permission evidence' {
        It 'does not invent a worker token or standard mode for synthetic inputs' {
            $r=Get-WpbdAnalysis (New-TestMetrics)
            $r.Permissions.RequestedMode | Should Be 'NotRecorded'
            $r.Permissions.ActualWorkerIsElevated | Should BeNullOrEmpty
            $r.Permissions.TokenInspectionStatus | Should Be 'NotRecorded'
            $r.Permissions.ElevationOutcome | Should Be 'NotVerified'
        }
        It 'reports captured Standard token evidence without account identity' {
            $m=New-TestMetrics
            $m | Add-Member Permissions ([pscustomobject]@{RequestedMode='Standard';ElevationOutcome='NotRequested';TokenInspectionStatus='Available';ActualWorkerIsElevated=$false;AdministratorGroupPresent=$true;AdministratorGroupEnabled=$false;IntegrityRid=8192;IntegrityLevel='Medium'})
            $r=Get-WpbdAnalysis $m
            $r.Permissions.RequestedMode | Should Be 'Standard'
            $r.Permissions.ElevationOutcome | Should Be 'NotRequested'
            $r.Permissions.ActualWorkerIsElevated | Should Be $false
            $r.Permissions.VerifiedHighIntegrityAdministrator | Should Be $false
            ($r.Permissions | ConvertTo-Json -Depth 8) | Should Not Match 'Username|Password|Credential|UserSid|AccountName'
        }
        It 'does not equate administrator membership with an elevated token' {
            $m=New-TestMetrics
            $m | Add-Member Permissions ([pscustomobject]@{RequestedMode='Elevated';ElevationOutcome='Succeeded';TokenInspectionStatus='Available';ActualWorkerIsElevated=$false;AdministratorGroupPresent=$true;AdministratorGroupEnabled=$true;IntegrityRid=12288;IntegrityLevel='High'})
            $r=Get-WpbdAnalysis $m
            $r.Permissions.ElevationOutcome | Should Be 'NotVerified'
            $r.Permissions.VerifiedHighIntegrityAdministrator | Should Be $false
            (& (Get-Module WPBD) {param($x) Get-WpbdPermissionPresentation $x} $r.Permissions).Summary | Should Not Match 'Succeeded|success'
        }
        It 'does not accept a claimed verified flag when token proof is absent' {
            $m=New-TestMetrics
            $m | Add-Member Permissions ([pscustomobject]@{RequestedMode='Elevated';ElevationOutcome='Succeeded';TokenInspectionStatus='Unavailable';ActualWorkerIsElevated=$true;AdministratorGroupEnabled=$true;IntegrityRid=12288;VerifiedHighIntegrityAdministrator=$true})
            $r=Get-WpbdAnalysis $m
            $r.Permissions.VerifiedHighIntegrityAdministrator | Should Be $false
            $r.Permissions.ElevationOutcome | Should Be 'NotVerified'
        }
        It 'reports captured high token evidence independently of any elevation request outcome' {
            $m=New-TestMetrics
            $m | Add-Member Permissions ([pscustomobject]@{RequestedMode='Standard';ElevationOutcome='NotRequested';TokenInspectionStatus='Available';ActualWorkerIsElevated=$true;AdministratorGroupEnabled=$true;IntegrityRid=12288;IntegrityLevel='High'})
            $r=Get-WpbdAnalysis $m
            $r.Permissions.VerifiedHighIntegrityAdministrator | Should Be $true
            $r.Permissions.ElevationOutcome | Should Be 'NotRequested'
        }
        It 'rejects coercible strings and fractional integrity evidence' {
            $m=New-TestMetrics
            $m | Add-Member Permissions ([pscustomobject]@{RequestedMode='Elevated';ElevationOutcome='Succeeded';TokenInspectionStatus='Available';ActualWorkerIsElevated='true';AdministratorGroupEnabled=$true;IntegrityRid=12288.5})
            $r=Get-WpbdAnalysis $m
            $r.Permissions.VerifiedHighIntegrityAdministrator | Should Be $false
        }
        It 'counts metadata coverage by identities without claiming complete machine coverage' {
            $m=New-TestMetrics -Cpu
            $m | Add-Member ProcessMetadata @([pscustomobject]@{Id=42;Identity=("42/"+([DateTimeOffset]'2025-01-02T10:00:00Z').UtcTicks);StartUtc='2025-01-02T10:00:00Z';Path='C:\Example\worker.exe';Services=@('ExampleService')})
            $r=Get-WpbdAnalysis $m
            $r.Permissions.Coverage.CapturedIdentities | Should Be 1
            $r.Permissions.Coverage.VerifiedIdentityPercent | Should Be 100
            $r.Permissions.Coverage.ExecutablePathPercent | Should Be 100
            $r.Permissions.Coverage.ServiceAssociationPercent | Should Be 100
            ($r.Permissions.Limitations -join ' ') | Should Match 'different process populations'
        }
        It 'keeps empty coverage percentages unavailable' {
            $m=New-TestMetrics;foreach($sample in $m.Samples){$sample.Processes=@()}
            $r=Get-WpbdAnalysis $m
            $r.Permissions.Coverage.CapturedIdentities | Should Be 0
            $r.Permissions.Coverage.VerifiedIdentityPercent | Should BeNullOrEmpty
            $r.Permissions.Coverage.ExecutablePathPercent | Should BeNullOrEmpty
        }
        It 'renders permission mode evidence consistently while retaining legacy unknown status' {
            $m=New-TestMetrics
            $m | Add-Member Permissions ([pscustomobject]@{RequestedMode='Standard';ElevationOutcome='NotRequested';TokenInspectionStatus='Available';ActualWorkerIsElevated=$false;AdministratorGroupPresent=$false;AdministratorGroupEnabled=$false;IntegrityRid=8192;IntegrityLevel='Medium'})
            $r=Get-WpbdAnalysis $m
            $p=& (Get-Module WPBD) {param($x) Get-WpbdPermissionPresentation $x} $r.Permissions
            $paths=Export-WpbdReport $r $TestDrive;$h=Get-Content $paths.HtmlPath -Raw
            $h.Contains([Net.WebUtility]::HtmlEncode($p.Summary)) | Should Be $true
            $h.Contains([Net.WebUtility]::HtmlEncode($p.TokenSummary)) | Should Be $true
            foreach($row in $p.Coverage){$h.Contains([Net.WebUtility]::HtmlEncode($row.Measurement)) | Should Be $true}
            $r.PSObject.Properties.Remove('Permissions')
            $old=Export-WpbdReport $r $TestDrive
            (Get-Content $old.HtmlPath -Raw) | Should Match 'Diagnostic permissions were not recorded'
        }
    }

    Context 'report export' {
        It 'round-trips report structure and preserves nulls, zero values and sample arrays' {
            $metrics = New-TestMetrics -Incomplete
            $metrics.CollectionErrors = @([pscustomobject]@{ Source = 'CPU'; Code = 'QueryFailed'; Count = 5; Message = 'Unavailable' })
            $report = Get-WpbdAnalysis $metrics
            $paths = Export-WpbdReport $report (Join-Path $TestDrive 'nested')
            $json = Get-Content -LiteralPath $paths.JsonPath -Raw | ConvertFrom-Json
            $json.SchemaVersion | Should Be '0.3'
            $json.Samples.Count | Should Be 5
            $json.Samples[0].CpuTotalPercent | Should BeNullOrEmpty
            $json.Samples[0].Memory.PageReadsPerSecond | Should Be 0
            $json.Statistics.Processes.Leaders.AverageCpuPercent[0].Id | Should Be 42
            $json.CollectionErrors[0].Count | Should Be 5
            $json.Findings[0].Measurements.CoverageGaps.Count | Should Be 2
            $json.SamplingQuality.ValidSamples.CpuTotal | Should Be 0
            $json.SamplingQuality.ActualSamples | Should Be 5
            $json.MemoryAssessment.Category | Should Be 'Normal memory operation'
            $json.Advisories.Count | Should Be 0
        }
        It 'renders readable, escaped and offline HTML with measurement sections' {
            $paths = Export-WpbdReport (Get-WpbdAnalysis (New-TestMetrics -Cpu)) $TestDrive
            $html = Get-Content -LiteralPath $paths.HtmlPath -Raw
            $html | Should Match '<h2>CPU</h2>'
            $html | Should Match '<td>Total CPU utilisation \(%\)</td>'
            $html | Should Match 'Suggested investigation'
            $html | Should Match 'Sampling quality'
            $html | Should Match 'Disk latency \(ms\)'
            $html | Should Match 'worker&lt;script&gt;'
            $html | Should Match 'TEST&lt;PC&gt;'
            $html | Should Not Match 'https?://|<script\b|<link\b'
        }
        It 'shows elevated memory as an advisory and escapes disk names in the timeline' {
            $metrics = New-TestMetrics -HighMemory
            foreach ($sample in $metrics.Samples) { $sample.Disks[0].Name = 'Disk<&>' }
            $report = Get-WpbdAnalysis $metrics
            $paths = Export-WpbdReport $report $TestDrive
            $html = Get-Content -LiteralPath $paths.HtmlPath -Raw
            $html | Should Match '<h3>Elevated memory utilisation</h3>'
            ([regex]::Matches($html,'<h3>Elevated memory utilisation</h3>')).Count | Should Be 1
            $html | Should Match 'Disk&lt;&amp;&gt; \(read'
            $html | Should Not Match 'Severe memory pressure|Disk<&>'
        }
        It 'does not overwrite a report even when exporting the same diagnostic again' {
            $report = Get-WpbdAnalysis (New-TestMetrics)
            $first = Export-WpbdReport $report $TestDrive
            $second = Export-WpbdReport $report $TestDrive
            $first.JsonPath | Should Not Be $second.JsonPath
            ([IO.FileInfo] $first.JsonPath).Name | Should Match '^WPBD-TEST_PC_-20250102T101000'
            Test-Path -LiteralPath $first.JsonPath | Should Be $true
            Test-Path -LiteralPath $second.HtmlPath | Should Be $true
        }
    }
}
Describe 'Application attribution and aligned memory' {
    InModuleScope WPBD {
        function New-ApplicationFixture {
            $start = '2026-01-02T00:00:00.1234560Z'
            $child = '2026-01-02T00:00:01.1234560Z'
            $other = '2026-01-02T00:00:02.1234560Z'
            $metadata = @(
                [pscustomobject]@{ Identity = Get-WpbdProcessIdentity 10 $start; Id=10; StartUtc=$start; Path='C:\Program Files\WindowsApps\MSTeams_1\ms-teams.exe'; ParentId=1; ParentStartUtc=$null; WebViewHostExecutable=$null }
                [pscustomobject]@{ Identity = Get-WpbdProcessIdentity 11 $child; Id=11; StartUtc=$child; Path='C:\WebView\msedgewebview2.exe'; ParentId=10; ParentStartUtc=$start; WebViewHostExecutable='ms-teams.exe' }
                [pscustomobject]@{ Identity = Get-WpbdProcessIdentity 20 $start; Id=20; StartUtc=$start; Path='C:\Other\other.exe'; ParentId=1; ParentStartUtc=$null; WebViewHostExecutable=$null }
                [pscustomobject]@{ Identity = Get-WpbdProcessIdentity 21 $other; Id=21; StartUtc=$other; Path='C:\WebView\msedgewebview2.exe'; ParentId=20; ParentStartUtc=$start; WebViewHostExecutable='other.exe' }
            )
            $samples = @(foreach($slot in 1..3) {
                $rows = @(
                    [pscustomobject]@{ Id=10; Name='ms-teams'; StartUtc=$start; PrivateBytes=$(if($slot -eq 1){900}else{100}); WorkingSetBytes=200 }
                    $(if($slot -lt 3){[pscustomobject]@{ Id=11; Name='msedgewebview2'; StartUtc=$child; PrivateBytes=$(if($slot -eq 2){900}else{100}); WorkingSetBytes=300 }})
                    [pscustomobject]@{ Id=20; Name='other'; StartUtc=$start; PrivateBytes=70; WorkingSetBytes=80 }
                    [pscustomobject]@{ Id=21; Name='msedgewebview2'; StartUtc=$other; PrivateBytes=90; WorkingSetBytes=100 }
                    [pscustomobject]@{ Id=30; Name='msedgewebview2'; StartUtc=$null; PrivateBytes=50; WorkingSetBytes=$null }
                ) | Where-Object {$null -ne $_}
                [pscustomobject]@{ Slot=$slot; TimestampUtc="2026-01-02T00:00:0$($slot+2)Z"; Processes=@($rows) }
            })
            [pscustomobject]@{ Samples=$samples; Metadata=$metadata }
        }
        It 'groups Teams WebView2 through identity and retains other hosts separately' {
            $fixture=New-ApplicationFixture
            $process=Get-WpbdProcessStatistics $fixture.Samples @{} 4
            $groups=@(Get-WpbdApplications $fixture.Samples $process.All $fixture.Metadata)
            $teams=$groups | Where-Object Name -eq 'Microsoft Teams'
            $teams.Processes.Count | Should Be 2
            $teams.Processes[1].Application | Should Be 'Microsoft Teams'
            ($groups | Where-Object Name -eq 'other').Processes.Count | Should Be 2
            ($groups | Where-Object Name -eq 'Unknown process ownership').Processes.Count | Should Be 1
        }
        It 'takes peaks from aligned sums and drops terminated members from later samples' {
            $fixture=New-ApplicationFixture
            $process=Get-WpbdProcessStatistics $fixture.Samples @{} 4
            $teams=@(Get-WpbdApplications $fixture.Samples $process.All $fixture.Metadata) | Where-Object Name -eq 'Microsoft Teams'
            $teams.PrivateBytes.Maximum | Should Be 1000
            ($teams.Processes | Measure-Object PeakPrivateBytes -Sum).Sum | Should Be 1800
            $teams.Samples[2].PrivateBytes | Should Be 100
            $teams.Samples[2].ProcessCount | Should Be 1
        }
        It 'keeps missing member memory unknown rather than summing a partial total' {
            $fixture=New-ApplicationFixture
            $fixture.Samples[0].Processes[1].PrivateBytes=$null
            $process=Get-WpbdProcessStatistics $fixture.Samples @{} 4
            $groups=@(Get-WpbdApplications $fixture.Samples $process.All $fixture.Metadata)
            ($groups | Where-Object Name -eq 'Microsoft Teams').Samples[0].PrivateBytes | Should BeNullOrEmpty
        }
        It 'does not assign a reused parent PID or an inconsistent command-line host' {
            $fixture=New-ApplicationFixture
            $fixture.Metadata[1].ParentStartUtc='2026-01-02T00:00:09Z'
            $fixture.Metadata[3].WebViewHostExecutable='ms-teams.exe'
            $process=Get-WpbdProcessStatistics $fixture.Samples @{} 4
            $groups=@(Get-WpbdApplications $fixture.Samples $process.All $fixture.Metadata)
            ($groups | Where-Object Name -eq 'Microsoft Teams').Processes.Count | Should Be 1
            ($groups | Where-Object Name -eq 'Unattributed application process').Processes.Count | Should Be 2
            ($groups | Where-Object Name -eq 'Unknown process ownership').Processes.Count | Should Be 1
        }
        It 'matches CIM and Get-Process timestamps at microsecond precision' {
            (Get-WpbdProcessIdentity 10 '2026-01-02T00:00:00.1234567Z') |
                Should Be (Get-WpbdProcessIdentity 10 '2026-01-02T00:00:00.1234560Z')
            (Get-WpbdProcessIdentity 10 '2026-01-02T00:00:01.1234560Z') |
                Should Not Be (Get-WpbdProcessIdentity 10 '2026-01-02T00:00:00.1234560Z')
        }
        It 'retains every captured process outside the top ten' {
            $sample=[pscustomobject]@{ Slot=1; Processes=@(foreach($id in 1..45){
                [pscustomobject]@{ Id=$id; Name="process$id"; StartUtc='2026-01-02T00:00:00Z'; PrivateBytes=$id; WorkingSetBytes=$id }
            })}
            $process=Get-WpbdProcessStatistics @($sample) @{} 4
            $process.All.Count | Should Be 45
            $process.Leaders.PeakPrivateBytes.Count | Should Be 10
        }
    }
}
Describe 'Session identity quality and attribution categories' {
    InModuleScope WPBD {
        function New-IdentitySamples {
            param([int] $Count=15)
            @(foreach($slot in 1..$Count) {
                [pscustomobject]@{
                    Slot=$slot; TimestampUtc=([datetime]'2026-01-02Z').AddSeconds($slot).ToString('o')
                    Processes=@(
                        [pscustomobject]@{Id=10;Name='restricted-a';StartUtc=$null;MetadataAccess='Restricted';PrivateBytes=10MB;WorkingSetBytes=5MB}
                        [pscustomobject]@{Id=11;Name='restricted-b';StartUtc=$null;MetadataAccess='Restricted';PrivateBytes=20MB;WorkingSetBytes=10MB}
                        [pscustomobject]@{Id=20;Name='verified-a';StartUtc='2026-01-01T00:00:00Z';PrivateBytes=30MB;WorkingSetBytes=15MB;CpuPercent=10}
                        [pscustomobject]@{Id=21;Name='verified-b';StartUtc='2026-01-01T00:00:00Z';PrivateBytes=40MB;WorkingSetBytes=20MB;CpuPercent=20}
                    )
                }
            })
        }
        It 'reproduces the old inflation and tracks four identities across sixty observations' {
            $samples=New-IdentitySamples
            $oldUnknownCount=@($samples.Processes | Where-Object {-not $_.StartUtc}).Count
            $oldUnknownCount | Should Be 30
            ($oldUnknownCount + 2) | Should Be 32
            $statistics=Get-WpbdProcessStatistics $samples @{} 4
            $groups=@(Get-WpbdApplications $samples $statistics.All @())
            $quality=Get-WpbdAttributionQuality $samples $statistics.All
            $statistics.All.Count | Should Be 4
            $quality.UniqueIdentities | Should Be 4
            $quality.VerifiedIdentities | Should Be 2
            $quality.ProvisionalIdentities | Should Be 2
            $quality.Observations | Should Be 60
            $quality.UnattributedPrivateBytes.Maximum | Should Be 100MB
            $quality.ConcurrentProcesses.Maximum | Should Be 4
            $quality.RestrictedProcesses | Should Be 2
            ($groups | Where-Object Name -eq 'Protected or restricted process').UniqueIdentities | Should Be 2
            ($groups | Where-Object Name -eq 'Protected or restricted process').Observations | Should Be 30
            ($groups | Where-Object Name -eq 'Protected or restricted process').ConcurrentProcesses.Maximum | Should Be 2
            ($groups | Where-Object Name -eq 'Protected or restricted process').PrivateBytes.Maximum | Should Be 30MB
            ($groups | Where-Object Name -eq 'Protected or restricted process').CpuPercent.Maximum | Should BeNullOrEmpty
        }
        It 'ends a provisional identity on observed absence and restarts it on reappearance' {
            $samples=New-IdentitySamples -Count 3
            $samples[1].Processes=@($samples[1].Processes | Where-Object Id -ne 10)
            $statistics=Get-WpbdProcessStatistics $samples @{} 4
            @($statistics.All | Where-Object Id -eq 10).Count | Should Be 2
            @($statistics.All | Where-Object Id -eq 11).Count | Should Be 1
            $samples[0].Processes[0].InstanceKey | Should Not Be $samples[2].Processes[0].InstanceKey
        }
        It 'splits provisional continuity on name changes and cumulative CPU regression' {
            $samples=New-IdentitySamples -Count 3
            $samples[1].Processes[0].Name='replacement'
            $samples[0].Processes[1] | Add-Member TotalCpuSeconds 20
            $samples[1].Processes[1] | Add-Member TotalCpuSeconds 10
            $samples[2].Processes[1] | Add-Member TotalCpuSeconds 11
            $statistics=Get-WpbdProcessStatistics $samples @{} 4
            @($statistics.All | Where-Object Id -eq 10).Count | Should Be 3
            @($statistics.All | Where-Object Id -eq 11).Count | Should Be 2
        }
        It 'never silently upgrades a provisional identity to verified on a later sighting' {
            $samples=New-IdentitySamples -Count 3
            $samples[1].Processes[0].StartUtc='2026-01-02T00:00:01Z'
            $samples[2].Processes[0].StartUtc='2026-01-02T00:00:01Z'
            $statistics=Get-WpbdProcessStatistics $samples @{} 4
            @($statistics.All | Where-Object Id -eq 10).Count | Should Be 2
            @($statistics.All | Where-Object { $_.Id -eq 10 -and $_.IdentityStatus -eq 'Verified' }).Count | Should Be 1
        }
        It 'keeps Windows type independent from restrictions and rejects a system-like name at an unrelated path' {
            $start='2026-01-01T00:00:00Z'
            $sample=[pscustomobject]@{Slot=1;TimestampUtc='2026-01-02T00:00:00Z';Processes=@(
                [pscustomobject]@{Id=10;Name='svchost';StartUtc=$start;MetadataAccess='Restricted';PrivateBytes=10MB;WorkingSetBytes=9MB}
                [pscustomobject]@{Id=11;Name='svchost';StartUtc=$start;MetadataAccess='Available';PrivateBytes=20MB;WorkingSetBytes=18MB}
                [pscustomobject]@{Id=12;Name='agent';StartUtc=$start;MetadataAccess='Available';PrivateBytes=30MB;WorkingSetBytes=28MB}
            )}
            $metadata=@(
                [pscustomobject]@{Identity=Get-WpbdProcessIdentity 10 $start;Id=10;StartUtc=$start;Path=(Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\svchost.exe');Services=@('ExampleService')}
                [pscustomobject]@{Identity=Get-WpbdProcessIdentity 11 $start;Id=11;StartUtc=$start;Path='C:\ThirdParty\svchost.exe'}
            )
            $statistics=Get-WpbdProcessStatistics @($sample) @{} 4
            $groups=@(Get-WpbdApplications @($sample) $statistics.All $metadata)
            ($statistics.All | Where-Object Id -eq 10).AttributionCategory | Should Be 'Windows system process'
            ($statistics.All | Where-Object Id -eq 10).MetadataAccess | Should Be 'Restricted'
            ($statistics.All | Where-Object Id -eq 10).Services[0] | Should Be 'ExampleService'
            ($statistics.All | Where-Object Id -eq 11).AttributionCategory | Should Be 'Identified application'
            ($statistics.All | Where-Object Id -eq 12).AttributionCategory | Should Be 'Unknown process ownership'
            $quality=Get-WpbdAttributionQuality @($sample) $statistics.All
            $quality.WindowsSystemProcesses | Should Be 1
            $quality.RestrictedProcesses | Should Be 1
            [Math]::Round($quality.AttributedPercent) | Should Be 67
        }
        It 'uses aligned totals for unattributed memory and complete group CPU values' {
            $samples=New-IdentitySamples -Count 2
            $samples[0].Processes[0].PrivateBytes=100MB
            $samples[0].Processes[1].PrivateBytes=1MB
            $samples[1].Processes[0].PrivateBytes=1MB
            $samples[1].Processes[1].PrivateBytes=100MB
            $start='2026-01-01T00:00:00Z'
            $metadata=@(foreach($id in @(20,21)){[pscustomobject]@{
                Identity=Get-WpbdProcessIdentity $id $start;Id=$id;StartUtc=$start;Path='C:\Apps\app.exe'
            }})
            $statistics=Get-WpbdProcessStatistics $samples @{} 4
            $groups=@(Get-WpbdApplications $samples $statistics.All $metadata)
            (Get-WpbdAttributionQuality $samples $statistics.All).UnattributedPrivateBytes.Maximum | Should Be 101MB
            $group=$groups | Where-Object Name -eq 'app'
            $group.CpuPercent.Average | Should Be 30
            $group.CpuPercent.Maximum | Should Be 30
            $group.UniqueIdentities | Should Be 2
            $samples[1].Processes[3].CpuPercent=$null
            $statistics=Get-WpbdProcessStatistics $samples @{} 4
            $group=@(Get-WpbdApplications $samples $statistics.All $metadata) | Where-Object Name -eq 'app'
            $group.Samples[1].CpuPercent | Should BeNullOrEmpty
        }
        It 'preserves unavailable unattributed memory and independent measurement confidence' {
            $samples=New-IdentitySamples -Count 2
            $samples[0].Processes[0].PrivateBytes=$null
            $statistics=Get-WpbdProcessStatistics $samples @{} 4
            Get-WpbdApplications $samples $statistics.All @() | Out-Null
            $quality=Get-WpbdAttributionQuality $samples $statistics.All
            $quality.UnattributedSamples[0].PrivateBytes | Should BeNullOrEmpty
            $quality.UnattributedPrivateBytes.Count | Should Be 1
            ($statistics.All | Where-Object Id -eq 11).PeakPrivateBytes | Should Be 20MB
            ($statistics.All | Where-Object Id -eq 11).AttributionConfidence | Should Be 'Low'
        }
        It 'records an explicit access-denied start time as restricted without dropping measurements' {
            Mock Get-Process {
                $restricted=[pscustomobject]@{Id=10;ProcessName='restricted';TotalProcessorTime=[timespan]::FromSeconds(2);PrivateMemorySize64=1MB;WorkingSet64=2MB}
                $restricted | Add-Member ScriptMethod get_StartTime {throw [ComponentModel.Win32Exception]::new(5)}
                $restricted | Add-Member ScriptMethod Dispose {}
                $restricted
            }
            $rows=@(Get-WpbdProcessSnapshot ([Diagnostics.Stopwatch]::StartNew()) ([ordered]@{}))
            $rows.Count | Should Be 1
            $rows[0].MetadataAccess | Should Be 'Restricted'
            $rows[0].PrivateBytes | Should Be 1MB
            $rows[0].StartUtc | Should BeNullOrEmpty
        }
        It 'keeps the unattributed footprint unavailable when process collection has no measurements' {
            $sample=[pscustomobject]@{Slot=1;TimestampUtc='2026-01-02T00:00:00Z';Processes=@()}
            $quality=Get-WpbdAttributionQuality @($sample) @()
            $quality.UnattributedSamples[0].PrivateBytes | Should BeNullOrEmpty
            $quality.UnattributedPrivateBytes.Maximum | Should BeNullOrEmpty
        }
    }
}
