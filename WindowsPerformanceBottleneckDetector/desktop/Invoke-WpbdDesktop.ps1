#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 3600)][int] $DurationSeconds,
    [Parameter(Mandatory)][ValidateRange(1, 3600)][int] $SampleIntervalSeconds,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^Local\\WPBD-[a-f0-9]{32}$')][string] $CancellationEvent
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$signal = $null

function Write-DesktopEvent {
    param([string] $Type, [object] $Data)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject @{ Protocol = 1; Type = $Type; Data = $Data } -Compress -Depth 8))
    [Console]::Out.Flush()
}

try {
    $signal = [Threading.EventWaitHandle]::OpenExisting($CancellationEvent)
    Import-Module (Join-Path $PSScriptRoot 'src/WPBD.psm1') -Force
    Write-DesktopEvent 'phase' 'Preparing baseline'
    $metrics = Get-WpbdMetrics -DurationSeconds $DurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds `
        -CancellationSignal $signal -OnSample {
        param($sample, $collected, $expected)
        Write-DesktopEvent 'sample' @{
            Slot = $sample.Slot; TimestampUtc = $sample.TimestampUtc; ElapsedSeconds = $sample.ElapsedSeconds
            CpuTotalPercent = $sample.CpuTotalPercent; Memory = $sample.Memory
            Disks = $sample.Disks
            Collected = $collected; Expected = $expected
        }
    }
    Write-DesktopEvent 'phase' 'Analysing measurements'
    $diagnostic = Get-WpbdAnalysis -Metrics $metrics
    if ($signal.WaitOne(0)) { throw [OperationCanceledException]::new() }
    Write-DesktopEvent 'phase' 'Writing reports'
    if ($signal.WaitOne(0)) { throw [OperationCanceledException]::new() }
    $paths = Export-WpbdReport -Diagnostic $diagnostic -OutputPath $OutputPath
    Write-DesktopEvent 'completed' $paths
    exit 0
} catch [OperationCanceledException] {
    Write-DesktopEvent 'cancelled' 'Diagnostic cancelled'
    exit 2
} catch {
    Write-DesktopEvent 'error' @{
        Message = $_.Exception.Message; Code = $_.FullyQualifiedErrorId; Details = $_.ScriptStackTrace
    }
    exit 1
} finally {
    if ($null -ne $signal) { $signal.Dispose() }
}
