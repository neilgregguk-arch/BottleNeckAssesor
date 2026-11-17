#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $ISCCPath,
    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string] $VersionOverride,
    [ValidateNotNullOrEmpty()][string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Build the WPBD installer on Windows.'
}

$dotnet = Get-Command dotnet.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dotnet) { throw 'The .NET 10 SDK is required. See the WPBD README.' }
$sdk = & $dotnet.Source --version
if ($LASTEXITCODE -ne 0 -or "$sdk" -notmatch '^(\d+)\.' -or [int] $Matches[1] -lt 10) {
    throw 'Select a .NET 10 or newer SDK before building the WPBD installer.'
}

if (-not $ISCCPath) {
    $compiler = Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($compiler) { $ISCCPath = $compiler.Source }
}
if (-not $ISCCPath) {
    $ISCCPath = foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if (-not $root) { continue }
        foreach ($name in @('Inno Setup 7', 'Inno Setup 6')) {
            $candidate = Join-Path $root "$name\ISCC.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
        }
    }
    $ISCCPath = $ISCCPath | Select-Object -First 1
}
if (-not $ISCCPath -or -not (Test-Path -LiteralPath $ISCCPath -PathType Leaf)) {
    throw 'Inno Setup 6.3 or newer is required. Provide the compiler path with -ISCCPath. See the WPBD README.'
}
$compilerPath = (Resolve-Path -LiteralPath $ISCCPath).ProviderPath
if ([IO.Path]::GetFileName($compilerPath) -ne 'ISCC.exe' -or
    -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $compilerPath) 'ISPP.dll') -PathType Leaf)) {
    throw 'Provide ISCC.exe from a complete Inno Setup installation or compiler directory.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$version = if ($VersionOverride) { $VersionOverride } else { (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim() }
if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
    @($version.Split('.') | Where-Object { [decimal] $_ -gt 65535 }).Count -gt 0) {
    throw 'The installer version must have three numeric components between 0 and 65535.'
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'artifacts' }
$provider = $null
$drive = $null
$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $OutputDirectory, [ref] $provider, [ref] $drive)
if ($provider.Name -ne 'FileSystem') { throw 'OutputDirectory must be a filesystem directory.' }
[void] [IO.Directory]::CreateDirectory($outputPath)

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$work = [IO.Path]::GetFullPath((Join-Path $temporaryRoot "wpbd-package-$([Guid]::NewGuid().ToString('N'))"))
$publish = Join-Path $work 'publish'
$project = Join-Path $projectRoot 'desktop/WPBD.Desktop/WPBD.Desktop.csproj'
$setupName = "WPBD-Setup-$version-x64.exe"
try {
    Write-Host "Publishing WPBD $version (win-x64 self-contained) with .NET SDK $sdk..."
    & $dotnet.Source publish $project -c Release -r win-x64 --self-contained true -o $publish "-p:Version=$version"
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)." }

    $required = @(
        'WPBD.Desktop.exe', 'WPBD.Desktop.dll', 'WPBD.Desktop.deps.json', 'WPBD.Desktop.runtimeconfig.json', 'WPBD.Core.dll',
        'coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'PresentationFramework.dll', 'wpfgfx_cor3.dll',
        'Engine/Invoke-WpbdDesktop.ps1', 'Engine/src/WPBD.psm1', 'Engine/src/Collect-Metrics.ps1',
        'Engine/src/Analyse-Metrics.ps1', 'Engine/src/Export-Report.ps1', 'Engine/src/Process-Applications.ps1'
    )
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $publish $file) -PathType Leaf)) { throw "Publish output is missing $file." }
    }
    $appVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $publish 'WPBD.Desktop.dll')).ProductVersion
    if ($appVersion -ne $version) { throw "Published app version $appVersion does not match installer version $version." }

    Write-Host "Compiling $setupName with Inno Setup..."
    & $compilerPath "/DAppVersion=$version" "/DPublishDir=$publish" "/O$work" (Join-Path $PSScriptRoot 'WPBD.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed (exit $LASTEXITCODE)." }
    $compiled = Get-Item -LiteralPath (Join-Path $work $setupName)
    if ($compiled.Length -le 0) { throw 'Inno Setup produced an empty installer.' }
    $destination = Join-Path $outputPath $setupName
    Copy-Item -LiteralPath $compiled.FullName -Destination $destination -Force
    $item = Get-Item -LiteralPath $destination
    $checksum = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumPath = "$($item.FullName).sha256"
    Set-Content -LiteralPath $checksumPath -Value "$checksum  $setupName" -Encoding Ascii
    Write-Host "Installer: $($item.FullName)"
    Write-Host ("Size: {0} bytes ({1:N2} MiB)" -f $item.Length, ($item.Length / 1MB))
    Write-Host "SHA-256: $checksum"
    [pscustomobject]@{ InstallerPath = $item.FullName; Bytes = $item.Length; SHA256 = $checksum; ChecksumPath = $checksumPath }
} finally {
    if ([IO.Directory]::Exists($work) -and
        $work.StartsWith($temporaryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($work) -match '^wpbd-package-[a-f0-9]{32}$') {
        try { [IO.Directory]::Delete($work, $true) }
        catch { Write-Warning "Could not remove staging directory '$work'. $($_.Exception.Message)" }
    }
}
