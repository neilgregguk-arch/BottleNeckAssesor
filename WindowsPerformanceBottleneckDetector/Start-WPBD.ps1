#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int] $DurationSeconds = 60,
    [ValidateRange(1, 3600)][int] $SampleIntervalSeconds = 2,
    [ValidateNotNullOrEmpty()][string] $OutputPath = (Join-Path $PSScriptRoot 'reports'),
    [switch] $NoReport
)

$ErrorActionPreference = 'Stop'
if ($SampleIntervalSeconds -gt $DurationSeconds) {
    throw 'SampleIntervalSeconds must be less than or equal to DurationSeconds.'
}
if (-not $NoReport) {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'OutputPath must be a directory path.' }
    $provider = $null
    $drive = $null
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPath, [ref] $provider, [ref] $drive
    )
    if ($provider.Name -ne 'FileSystem' -or [IO.File]::Exists($OutputPath)) {
        throw 'OutputPath must be a filesystem directory path.'
    }
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
}

Import-Module "$PSScriptRoot/src/WPBD.psm1" -ErrorAction Stop
Write-Host "WPBD 0.1 | Sampling for $DurationSeconds seconds at $SampleIntervalSeconds-second intervals."
$metrics = Get-WpbdMetrics -DurationSeconds $DurationSeconds -SampleIntervalSeconds $SampleIntervalSeconds
Write-Host 'Analysing measurements...'
$diagnostic = Get-WpbdAnalysis -Metrics $metrics
Write-Host $diagnostic.Assessment.Summary
if (-not $NoReport) {
    Write-Host 'Writing reports...'
    $paths = Export-WpbdReport -Diagnostic $diagnostic -OutputPath $OutputPath
    Write-Host "JSON  $($paths.JsonPath)"
    Write-Host "HTML  $($paths.HtmlPath)"
}
$diagnostic
