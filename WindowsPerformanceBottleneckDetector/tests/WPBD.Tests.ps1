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
                        UsedPercent = $(if ($HighMemory -or $Paging) { 97 } else { 75 })
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
                System = [pscustomobject]@{ ComputerName = 'TEST<PC>'; LogicalProcessorCount = 4; InstalledMemoryBytes = 8GB }
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
                $a = [pscustomobject]@{ StartUtc = 'old'; ElapsedSeconds = 1; TotalCpuSeconds = 1 }
                $b = [pscustomobject]@{ StartUtc = 'new'; ElapsedSeconds = 2; TotalCpuSeconds = 3 }
                (Convert-WpbdProcess $a $b 4).CpuPercent | Should BeNullOrEmpty
            }
            It 'calculates physical use, commit usage and paging rates from their own denominators' {
                $a = [pscustomobject]@{ Frequency_PerfTime = 1000; Timestamp_PerfTime = 1000; PageReadsPersec = 10; PagesInputPersec = 20 }
                $b = [pscustomobject]@{ Frequency_PerfTime = 1000; Timestamp_PerfTime = 3000
                    AvailableBytes = 1GB; CommittedBytes = 9GB; CommitLimit = 12GB; PageReadsPersec = 18; PagesInputPersec = 60 }
                $memory = Convert-WpbdMemory $a $b 4GB
                $memory.UsedPercent | Should Be 75
                $memory.CommitPercent | Should Be 75
                $memory.PageReadsPerSecond | Should Be 4
                $memory.PagesInputPerSecond | Should Be 20
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
                    [pscustomobject]@{ Name = '_Total'; AvailableBytes = 123 }
                }
                Mock Get-WpbdProcessSnapshot {}
                $errors = [ordered]@{}
                $first = Get-WpbdSnapshot ([Diagnostics.Stopwatch]::StartNew()) $errors 'SyntheticProcessor'
                Get-WpbdSnapshot ([Diagnostics.Stopwatch]::StartNew()) $errors 'SyntheticProcessor' | Out-Null
                $first.Memory.AvailableBytes | Should Be 123
                $first.Cpu.Count | Should Be 1
                $first.Disks.Count | Should Be 0
                @($errors.Values)[0].Code | Should Be 'QueryFailed'
                @($errors.Values)[0].Count | Should Be 2
            }
        }
    }

    Context 'diagnostic analysis' {
        It 'summarises normal CPU, memory, disk and process statistics' {
            $report = Get-WpbdAnalysis (New-TestMetrics)
            $report.Assessment.Category | Should Be 'No clear bottleneck detected'
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
            (Get-WpbdAnalysis (New-TestMetrics -HighMemory)).Assessment.Category | Should Be 'No clear bottleneck detected'
        }
        It 'identifies severe memory pressure with paging' {
            $report = Get-WpbdAnalysis (New-TestMetrics -Paging)
            $report.Assessment.Category | Should Be 'Memory pressure'
            $report.Findings[0].Severity | Should Be 'Critical'
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
            $json.SchemaVersion | Should Be '0.1'
            $json.Samples.Count | Should Be 5
            $json.Samples[0].CpuTotalPercent | Should BeNullOrEmpty
            $json.Samples[0].Memory.PageReadsPerSecond | Should Be 0
            $json.Statistics.Processes.Leaders.AverageCpuPercent[0].Id | Should Be 42
            $json.CollectionErrors[0].Count | Should Be 5
            $json.Findings[0].Measurements.CoverageGaps.Count | Should Be 2
        }
        It 'renders readable, escaped and offline HTML with measurement sections' {
            $paths = Export-WpbdReport (Get-WpbdAnalysis (New-TestMetrics -Cpu)) $TestDrive
            $html = Get-Content -LiteralPath $paths.HtmlPath -Raw
            $html | Should Match '<h2>CPU</h2>'
            $html | Should Match '<td>Total CPU utilisation \(%\)</td>'
            $html | Should Match 'Suggested investigation'
            $html | Should Match 'worker&lt;script&gt;'
            $html | Should Match 'TEST&lt;PC&gt;'
            $html | Should Not Match 'https?://|<script\b|<link\b'
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
