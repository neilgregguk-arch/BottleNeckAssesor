function Get-WpbdProcessIdentity {
    param($Id, $StartUtc)
    if ($StartUtc) {
        $ticks = ([DateTimeOffset] $StartUtc).UtcTicks
        # CIM creation timestamps have microsecond resolution. Get-Process also includes 100 ns ticks.
        return "$Id/$($ticks - ($ticks % 10))"
    }
    return $null
}

function Get-WpbdProcessMetadata {
    param($Errors)
    # Inventory runs outside the sampling window. Never query command lines per sample.
    $rows = @(Get-WpbdCim 'Win32_Process' $Errors -TimeoutSeconds 2)
    $byPid = @{}
    foreach ($row in $rows) { $byPid[[int] $row.ProcessId] = $row }
    foreach ($row in $rows) {
        if (-not $row.CreationDate) { continue }
        $start = $row.CreationDate.ToUniversalTime().ToString('o')
        $parent = $byPid[[int] $row.ParentProcessId]
        $parentStart = $null
        if ($parent.CreationDate -and $parent.CreationDate -le $row.CreationDate -and $parent.ProcessId -ne $row.ProcessId) {
            $parentStart = $parent.CreationDate.ToUniversalTime().ToString('o')
        }
        $hostName = $null
        if ($row.CommandLine -match '(?i)(?:^|\s)--webview-exe-name=(?:"([^"]+)"|([^\s]+))') {
            $hostName = $Matches[1]
            if (-not $hostName) { $hostName = $Matches[2] }
        }
        [pscustomobject]@{
            Identity = Get-WpbdProcessIdentity $row.ProcessId $start
            Id = [int] $row.ProcessId; StartUtc = $start; Path = $row.ExecutablePath
            ParentId = [int] $row.ParentProcessId; ParentStartUtc = $parentStart
            WebViewHostExecutable = $hostName
        }
    }
}

function Get-WpbdApplicationOwner {
    param($Metadata, $Key)
    $visited = @{}
    $current = $null
    if ($Key) { $current = $Metadata[$Key] }
    $hops = 0
    while ($current -and -not $visited.ContainsKey($current.Identity)) {
        $visited[$current.Identity] = $true
        if (-not $current.Path) { break }
        $file = [IO.Path]::GetFileName($current.Path)
        if ($file -ine 'msedgewebview2.exe') {
            if ($hops -gt 0 -and $file -match '^(explorer|svchost|services|wininit|winlogon)\.exe$') { break }
            $name = [IO.Path]::GetFileNameWithoutExtension($file)
            if ($file -ieq 'ms-teams.exe' -and $current.Path -match '(?i)\\WindowsApps\\MSTeams_[^\\]+\\') {
                $name = 'Microsoft Teams'
            }
            return [pscustomobject]@{
                Key = $current.Path.ToLowerInvariant(); Name = $name
                Evidence = $(if ($hops) { 'Verified parent identity chain to executable path' } else { 'Executable path' })
            }
        }
        $parentKey = Get-WpbdProcessIdentity $current.ParentId $current.ParentStartUtc
        if (-not $parentKey) { break }
        $parent = $Metadata[$parentKey]
        if (-not $parent -or ([DateTimeOffset] $parent.StartUtc) -gt ([DateTimeOffset] $current.StartUtc)) { break }
        if ($current.WebViewHostExecutable -and [IO.Path]::GetFileName($parent.Path) -ine 'msedgewebview2.exe' -and
            $current.WebViewHostExecutable -ine [IO.Path]::GetFileName($parent.Path)) { break }
        $current = $parent
        $hops++
    }
    [pscustomobject]@{ Key = 'unattributed'; Name = 'Unattributed'; Evidence = 'Ownership could not be established' }
}

function Get-WpbdApplications {
    param($Samples, $Processes, $MetadataRows)
    $metadata = @{}
    foreach ($row in $MetadataRows) {
        if (-not $row.Identity) { continue }
        $previous = $metadata[$row.Identity]
        if (-not $previous -or (-not $previous.ParentStartUtc -and $row.ParentStartUtc)) {
            $metadata[$row.Identity] = $row
        } elseif (-not $previous.Path -and $row.Path) { $previous.Path = $row.Path }
    }
    $owners = @{}
    $groups = @{}
    foreach ($process in $Processes) {
        $identity = Get-WpbdProcessIdentity $process.Id $process.StartUtc
        $owner = Get-WpbdApplicationOwner $metadata $identity
        $owners[$process.InstanceKey] = $owner
        $process | Add-Member -NotePropertyName Application -NotePropertyValue $owner.Name
        $process | Add-Member -NotePropertyName OwnershipEvidence -NotePropertyValue $owner.Evidence
        if ($identity -and $metadata[$identity]) {
            if ($metadata[$identity].Path) { $process.Path = $metadata[$identity].Path }
        }
        if (-not $groups.ContainsKey($owner.Key)) {
            $groups[$owner.Key] = [pscustomobject]@{
                Name = $owner.Name; Key = $owner.Key
                Processes = New-Object 'System.Collections.Generic.List[object]'
                Samples = New-Object 'System.Collections.Generic.List[object]'
            }
        }
        $groups[$owner.Key].Processes.Add($process)
    }
    foreach ($sample in $Samples) {
        $atTime = @{}
        foreach ($row in $sample.Processes) {
            $key = "$($row.Id)/$($row.StartUtc)"
            if (-not $row.StartUtc) { $key = "unknown/$($row.Id)/$($sample.Slot)" }
            $owner = $owners[$key]
            if (-not $owner) { continue }
            if (-not $atTime.ContainsKey($owner.Key)) { $atTime[$owner.Key] = New-Object 'System.Collections.Generic.List[object]' }
            $atTime[$owner.Key].Add($row)
        }
        foreach ($key in $atTime.Keys) {
            $rows = $atTime[$key]
            $privateCount = @($rows | Where-Object { $null -ne $_.PrivateBytes }).Count
            $workingCount = @($rows | Where-Object { $null -ne $_.WorkingSetBytes }).Count
            $groups[$key].Samples.Add([pscustomobject]@{
                Slot = $sample.Slot; TimestampUtc = $sample.TimestampUtc; ProcessCount = $rows.Count
                PrivateMeasured = $privateCount; WorkingSetMeasured = $workingCount
                PrivateBytes = $(if ($privateCount -eq $rows.Count) { ($rows | Measure-Object PrivateBytes -Sum).Sum } else { $null })
                WorkingSetBytes = $(if ($workingCount -eq $rows.Count) { ($rows | Measure-Object WorkingSetBytes -Sum).Sum } else { $null })
            })
        }
    }
    foreach ($group in ($groups.Values | Sort-Object Name, Key)) {
        [pscustomobject]@{
            Name = $group.Name; Key = $group.Key; Processes = $group.Processes.ToArray()
            Samples = $group.Samples.ToArray()
            PrivateBytes = Get-WpbdStatistics $group.Samples 'PrivateBytes'
            WorkingSetBytes = Get-WpbdStatistics $group.Samples 'WorkingSetBytes'
        }
    }
}
