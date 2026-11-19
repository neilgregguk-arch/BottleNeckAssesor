# Ordinary-user laboratory only. No install, elevation, signing or security-policy change.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    foreach ($project in @('TransportLab', 'Worker', 'Relay')) {
        & dotnet build "$project/$project.csproj" -c Release --nologo
        if ($LASTEXITCODE -ne 0) { throw "Experimental $project build failed." }
    }
    # The native primary-token guard must pass before starting any refusal fixture.
    & ./TransportLab/bin/Release/net10.0-windows/TransportLab.exe --self-test
    if ($LASTEXITCODE -ne 0) { throw 'Medium Windows transport tests failed.' }
    $script:refusalPassed = 0
    function Test-Refusal([string]$Executable, [string[]]$Arguments, [int]$Expected, [string]$Label) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $output = & $Executable @Arguments 2>&1; $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous }
        if ($code -ne $Expected) { throw "Refusal case failed: $Label (exit $code)." }
        if (($output | Out-String) -notmatch 'refused|only action') { throw "No explicit refusal: $Label." }
        $script:refusalPassed++
        Write-Output "PASS refusal: $Label"
    }
    $worker = './Worker/bin/Release/net10.0-windows/Worker.exe'
    $valid = @('--session','1234567890abcdef1234567890abcdef','--relay-pid','42','--relay-start','133000000000000000','--duration','30','--interval','2','--operation','token-probe-v1')
    Test-Refusal $worker $valid 3 'canonical request cannot substitute for a high primary token'
    foreach ($flag in @('--command','--script','--shell','--executable','--output','--privilege','--kill','--service')) {
        $bad = [string[]]$valid.Clone(); $bad[0] = $flag
        Test-Refusal $worker $bad 2 "unsupported $flag"
    }
    $bad = [string[]]$valid.Clone(); $bad[2] = '--session'
    Test-Refusal $worker $bad 2 'duplicate argument'
    Test-Refusal $worker ($valid + @('--output','arbitrary')) 2 'extra output destination'
    foreach ($value in @('0','042','+42','4294967296','42;command')) {
        $bad = [string[]]$valid.Clone(); $bad[3] = $value
        Test-Refusal $worker $bad 2 'noncanonical/overflow/injected process identifier'
    }
    $bad = [string[]]$valid.Clone(); $bad[11] = 'diagnose-v1'
    Test-Refusal $worker $bad 2 'full diagnostic operation'
    $bad = [string[]]$valid.Clone(); $bad[7] = '31'
    Test-Refusal $worker $bad 2 'unsupported duration'
    $bad = [string[]]$valid.Clone(); $bad[9] = '3'
    Test-Refusal $worker $bad 2 'unsupported interval'
    Test-Refusal './Relay/bin/Release/net10.0-windows/Relay.exe' @('--probe') 4 'relay blocks before UAC when deployment is unavailable'
    Test-Refusal './Relay/bin/Release/net10.0-windows/Relay.exe' @('--command','anything') 2 'relay has no command interface'
    Write-Output "$script:refusalPassed real non-elevated executable refusal checks passed. No privileged boundary tested."
    foreach ($project in @('Worker', 'Relay')) {
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $publishOutput = & dotnet publish "$project/$project.csproj" -c Release --no-restore -o "artifacts/blocked-$project" 2>&1
            $publishCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previous }
        if ($publishCode -eq 0 -or ($publishOutput | Out-String) -notmatch 'No deployable worker|No deployable relay') {
            throw "Unreviewed $project publish was not explicitly blocked."
        }
        if (Test-Path -LiteralPath "artifacts/blocked-$project/$project.exe") { throw "Unexpected published $project executable." }
        Write-Output "PASS publish guard: $project cannot produce a deployment package."
    }
    # The two native publish failures above are expected test results.
    $global:LASTEXITCODE = 0
}
finally { Pop-Location }
