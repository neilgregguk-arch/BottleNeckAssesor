Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/WPBD.psm1') -Force

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
        It 'keeps unverified process identities separate when a PID can have been reused' {
            $metrics = New-TestMetrics
            foreach ($sample in $metrics.Samples) {
                $sample.Processes[0].StartUtc = $null
                $sample.Processes[0].CpuSeconds = $null
                $sample.Processes[0].CpuPercent = $null
            }
            $statistics = (Get-WpbdAnalysis $metrics).Statistics.Processes
            $statistics.ObservedInstances | Should Be 5
            $statistics.Leaders.PeakPrivateBytes.Count | Should Be 1
            $statistics.Leaders.PeakPrivateBytes[0].Observations | Should Be 1
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

    Context 'report export' {
        It 'round-trips report structure and preserves nulls, zero values and sample arrays' {
            $metrics = New-TestMetrics -Incomplete
            $metrics.CollectionErrors = @([pscustomobject]@{ Source = 'CPU'; Code = 'QueryFailed'; Count = 5; Message = 'Unavailable' })
            $report = Get-WpbdAnalysis $metrics
            $paths = Export-WpbdReport $report (Join-Path $TestDrive 'nested')
            $json = Get-Content -LiteralPath $paths.JsonPath -Raw | ConvertFrom-Json
            $json.SchemaVersion | Should Be '0.2'
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
            $html | Should Match '<h2>Advisories</h2>\s*<article[^>]*><h3>Elevated memory utilisation</h3>'
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
            ($groups | Where-Object Name -eq 'Unattributed').Processes.Count | Should Be 3
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
            ($groups | Where-Object Name -eq 'Unattributed').Processes.Count | Should Be 5
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
