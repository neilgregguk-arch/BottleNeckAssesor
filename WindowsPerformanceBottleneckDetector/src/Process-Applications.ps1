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
    $serviceCutoff = [datetime]::UtcNow
    $services = @(Get-WpbdCim 'Win32_Service' $Errors 'ProcessId > 0' -TimeoutSeconds 2)
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
            Services = @(if ($row.CreationDate.ToUniversalTime() -le $serviceCutoff) {
                $services | Where-Object { $_.ProcessId -eq $row.ProcessId } | Select-Object -ExpandProperty Name
            })
        }
    }
}

function Set-WpbdProcessIdentities {
    param($Samples)
    $previous = @{}
    foreach ($sample in $Samples) {
        $current = @{}
        foreach ($row in $sample.Processes) {
            $old = $previous[$row.Id]
            $key = Get-WpbdProcessIdentity $row.Id $row.StartUtc
            $status = 'Verified'
            if (-not $key) {
                $status = 'Provisional'
                $continuous = $old -and -not $old.StartUtc -and $old.Name -eq $row.Name
                if ($continuous -and $old.Path -and $row.Path -and $old.Path -ine $row.Path) { $continuous = $false }
                if ($continuous -and $null -ne $old.TotalCpuSeconds -and $null -ne $row.TotalCpuSeconds -and
                    $row.TotalCpuSeconds -lt $old.TotalCpuSeconds) { $continuous = $false }
                $key = if ($continuous) { $old.InstanceKey } else { "provisional/$($row.Id)/$($sample.Slot)" }
            }
            $row | Add-Member -NotePropertyName InstanceKey -NotePropertyValue $key -Force
            $row | Add-Member -NotePropertyName IdentityStatus -NotePropertyValue $status -Force
            $current[$row.Id] = $row
        }
        $previous = $current
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
            if ($previous.Services) { $row.Services = @($row.Services + $previous.Services | Select-Object -Unique) }
            $metadata[$row.Identity] = $row
        } else {
            if (-not $previous.Path -and $row.Path) { $previous.Path = $row.Path }
            if ($row.Services) { $previous.Services = @($previous.Services + $row.Services | Select-Object -Unique) }
        }
    }
    $owners = @{}
    $groups = @{}
    foreach ($process in $Processes) {
        $identity = Get-WpbdProcessIdentity $process.Id $process.StartUtc
        $details = $null
        if ($identity) { $details = $metadata[$identity] }
        if ($details.Path) { $process.Path = $details.Path }
        $services = @($details.Services | Where-Object { $_ })
        $systemRoot = [Environment]::GetFolderPath('Windows')
        $systemPath = $false
        if ($systemRoot -and $process.Path) {
            $systemPath = $process.Path.StartsWith((Join-Path $systemRoot 'System32') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $process.Path.StartsWith((Join-Path $systemRoot 'SysWOW64') + '\', [StringComparison]::OrdinalIgnoreCase)
        }
        $systemFile = [IO.Path]::GetFileName($process.Path)
        $windowsComponent = $systemPath -and
            $systemFile -match '^(svchost|lsass|csrss|smss|wininit|winlogon|services|dwm|fontdrvhost|sihost|taskhostw|dllhost|conhost)\.exe$'
        $owner = Get-WpbdApplicationOwner $metadata $identity
        $category = 'Identified application'
        $confidence = 'High'
        $type = 'Application process'
        if ($windowsComponent) {
            $category = 'Windows system process'
            $type = 'Windows component or service'
            $owner = [pscustomobject]@{
                Name = $(if ($services.Count) { "Windows service host ($systemFile)" } else { "Windows component ($systemFile)" })
                Key = "windows/$($process.Path.ToLowerInvariant())"
                Evidence = 'Windows system directory and component filename or running service mapping'
            }
        } elseif ($services.Count -gt 0) {
            $type = 'Service process'
        }
        if ($owner.Key -eq 'unattributed') {
            $confidence = 'Low'
            $category = 'Unknown process ownership'
            if ($process.MetadataAccess -eq 'Restricted') { $category = 'Protected or restricted process' }
            elseif ($process.Path) { $category = 'Unattributed application process' }
            $owner = [pscustomobject]@{ Name = $category; Key = "category/$category"; Evidence = $owner.Evidence }
        }
        if ($process.IdentityStatus -eq 'Provisional') { $confidence = 'Low' }
        $packageDirectory = $null
        if ($process.Path -match '(?i)\\WindowsApps\\([^\\]+)\\') { $packageDirectory = $Matches[1] }
        foreach ($field in @{
            AttributionCategory = $category; AttributionConfidence = $confidence; ProcessType = $type
            ParentId = $details.ParentId; ParentStartUtc = $details.ParentStartUtc
            Services = $services; PackageDirectory = $packageDirectory
        }.GetEnumerator()) {
            $process | Add-Member -NotePropertyName $field.Key -NotePropertyValue $field.Value -Force
        }
        $owners[$process.InstanceKey] = $owner
        $process | Add-Member -NotePropertyName Application -NotePropertyValue $owner.Name -Force
        $process | Add-Member -NotePropertyName OwnershipEvidence -NotePropertyValue $owner.Evidence -Force
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
            $owner = $owners[$row.InstanceKey]
            if (-not $owner) { continue }
            if (-not $atTime.ContainsKey($owner.Key)) { $atTime[$owner.Key] = New-Object 'System.Collections.Generic.List[object]' }
            $atTime[$owner.Key].Add($row)
        }
        foreach ($key in $atTime.Keys) {
            $rows = $atTime[$key]
            $privateCount = @($rows | Where-Object { $null -ne $_.PrivateBytes }).Count
            $workingCount = @($rows | Where-Object { $null -ne $_.WorkingSetBytes }).Count
            $cpuCount = @($rows | Where-Object { $null -ne $_.CpuPercent }).Count
            $groups[$key].Samples.Add([pscustomobject]@{
                Slot = $sample.Slot; TimestampUtc = $sample.TimestampUtc; ProcessCount = $rows.Count
                PrivateMeasured = $privateCount; WorkingSetMeasured = $workingCount
                PrivateBytes = $(if ($privateCount -eq $rows.Count) { ($rows | Measure-Object PrivateBytes -Sum).Sum } else { $null })
                WorkingSetBytes = $(if ($workingCount -eq $rows.Count) { ($rows | Measure-Object WorkingSetBytes -Sum).Sum } else { $null })
                CpuPercent = $(if ($cpuCount -eq $rows.Count) { ($rows | Measure-Object CpuPercent -Sum).Sum } else { $null })
            })
        }
    }
    foreach ($group in ($groups.Values | Sort-Object Name, Key)) {
        [pscustomobject]@{
            Name = $group.Name; Key = $group.Key; Processes = $group.Processes.ToArray()
            Samples = $group.Samples.ToArray()
            PrivateBytes = Get-WpbdStatistics $group.Samples 'PrivateBytes'
            WorkingSetBytes = Get-WpbdStatistics $group.Samples 'WorkingSetBytes'
            CpuPercent = Get-WpbdStatistics $group.Samples 'CpuPercent'
            ConcurrentProcesses = Get-WpbdStatistics $group.Samples 'ProcessCount'
            UniqueIdentities = $group.Processes.Count
            Observations = [int] ($group.Processes | Measure-Object Observations -Sum).Sum
            AttributionConfidence = $(if (@($group.Processes | Where-Object AttributionConfidence -eq 'Low').Count) { 'Low' } else { 'High' })
            AttributionCategory = $group.Processes[0].AttributionCategory
        }
    }
}

function Get-WpbdAttributionQuality {
    param($Samples, $Processes)
    $total = @($Processes).Count
    $identified = @($Processes | Where-Object AttributionCategory -eq 'Identified application').Count
    $system = @($Processes | Where-Object AttributionCategory -eq 'Windows system process').Count
    $unowned = @{}
    foreach ($process in $Processes) {
        if ($process.AttributionCategory -notin @('Identified application', 'Windows system process')) { $unowned[$process.InstanceKey] = $true }
    }
    $memory = @(foreach ($sample in $Samples) {
        $rows = @($sample.Processes | Where-Object { $unowned.ContainsKey($_.InstanceKey) })
        [pscustomobject]@{
            TimestampUtc = $sample.TimestampUtc; Slot = $sample.Slot; ProcessCount = $rows.Count
            PrivateBytes = $(if (@($sample.Processes).Count -gt 0 -and
                @($rows | Where-Object { $null -eq $_.PrivateBytes }).Count -eq 0) {
                if ($rows.Count) { ($rows | Measure-Object PrivateBytes -Sum).Sum } else { 0 }
            } else { $null })
        }
    })
    [pscustomobject]@{
        UniqueIdentities = $total
        UniquePids = @($Processes | Select-Object -ExpandProperty Id -Unique).Count
        VerifiedIdentities = @($Processes | Where-Object IdentityStatus -eq 'Verified').Count
        ProvisionalIdentities = @($Processes | Where-Object IdentityStatus -eq 'Provisional').Count
        Observations = [int] ($Processes | Measure-Object Observations -Sum).Sum
        IdentifiedApplications = $identified; WindowsSystemProcesses = $system
        RestrictedProcesses = @($Processes | Where-Object MetadataAccess -eq 'Restricted').Count
        UnattributedApplications = @($Processes | Where-Object AttributionCategory -eq 'Unattributed application process').Count
        UnknownOwnership = @($Processes | Where-Object AttributionCategory -eq 'Unknown process ownership').Count
        RestrictedOwnership = @($Processes | Where-Object AttributionCategory -eq 'Protected or restricted process').Count
        AttributedPercent = Get-WpbdRatio ($identified + $system) $total 100
        ConcurrentProcesses = Get-WpbdStatistics @($Samples | ForEach-Object { [pscustomobject]@{ Count = @($_.Processes).Count } }) 'Count'
        UnattributedPrivateBytes = Get-WpbdStatistics $memory 'PrivateBytes'
        UnattributedSamples = $memory
    }
}
