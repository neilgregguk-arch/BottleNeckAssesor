function Get-WpbdProcessIdentity {
    param($Id, $StartUtc)
    if ($StartUtc) {
        $ticks = ([DateTimeOffset] $StartUtc).UtcTicks
        # CIM creation timestamps have microsecond resolution. Get-Process also includes 100 ns ticks.
        return "$Id/$($ticks - ($ticks % 10))"
    }
    return $null
}

function Initialize-WpbdImageQuery {
    if ('Wpbd.NativeImageQuery' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Wpbd {
    public sealed class ImageResult {
        public string Path;
        public DateTime? CreationUtc;
        public int Error;
    }
    public static class NativeImageQuery {
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref int size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public static ImageResult Read(int pid) {
            var result = new ImageResult();
            IntPtr handle = OpenProcess(0x1000, false, pid);
            if (handle == IntPtr.Zero) { result.Error = Marshal.GetLastWin32Error(); return result; }
            try {
                long creation, exit, kernel, user;
                if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user)) {
                    result.Error = Marshal.GetLastWin32Error();
                    return result;
                }
                result.CreationUtc = DateTime.FromFileTimeUtc(creation);
                var name = new StringBuilder(32768);
                int size = name.Capacity;
                if (QueryFullProcessImageNameW(handle, 0, name, ref size)) result.Path = name.ToString();
                else result.Error = Marshal.GetLastWin32Error();
                return result;
            } finally { CloseHandle(handle); }
        }
    }
}
'@
}

function Get-WpbdImageEvidence {
    param($Id, $ExpectedIdentity)
    $result = [Wpbd.NativeImageQuery]::Read([int] $Id)
    $status = 'PathUnavailable'
    $path = $null
    if ($result.Error -eq 5) { $status = 'AccessDenied' }
    elseif ($result.Error -in @(87, 1168)) { $status = 'ProcessExited' }
    elseif ($result.CreationUtc) {
        $identity = Get-WpbdProcessIdentity $Id $result.CreationUtc
        if ($identity -ne $ExpectedIdentity) { $status = 'IdentityMismatch' }
        elseif ($result.Path) { $status = 'Available'; $path = $result.Path }
    }
    [pscustomobject]@{ Path = $path; Status = $status; Error = $result.Error }
}

function Get-WpbdProcessMetadata {
    param($Errors, [ValidateSet('Before', 'After')][string] $Phase = 'After', [ref] $Timing)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # Inventory runs outside the sampling window. Never query command lines per sample.
    $serviceCutoff = [datetime]::UtcNow
    $serviceStatus = 'Unavailable'
    $services = @(Get-WpbdCim 'Win32_Service' $Errors 'ProcessId > 0' -TimeoutSeconds 2 -Status ([ref] $serviceStatus))
    $servicesByPid = @{}
    foreach ($service in $services) {
        $servicePid = [int] $service.ProcessId
        if (-not $servicesByPid.ContainsKey($servicePid)) { $servicesByPid[$servicePid] = @() }
        $servicesByPid[$servicePid] += $service.Name
    }
    $rows = @(Get-WpbdCim 'Win32_Process' $Errors -TimeoutSeconds 2)
    $byPid = @{}
    foreach ($row in $rows) { $byPid[[int] $row.ProcessId] = $row }
    $budget = [Diagnostics.Stopwatch]::StartNew()
    $native = [Diagnostics.Stopwatch]::StartNew()
    $nativeReady = $true
    try { Initialize-WpbdImageQuery } catch {
        $nativeReady = $false
        Add-WpbdCollectionError $Errors 'Process image enrichment' 'Unavailable' $_.Exception.Message
    }
    $native.Stop()
    $lookups = 0
    foreach ($row in $rows) {
        if (-not $row.CreationDate) { continue }
        $start = $row.CreationDate.ToUniversalTime().ToString('o')
        $identity = Get-WpbdProcessIdentity $row.ProcessId $start
        $path = $row.ExecutablePath
        $pathSource = 'CIM'
        $pathStatus = 'Available'
        if (-not $path) {
            $pathStatus = 'LookupBudgetExceeded'
            if (-not $nativeReady) { $pathStatus = 'LookupUnavailable' }
            elseif ($budget.Elapsed.TotalSeconds -lt 2) {
                $native.Start()
                try { $image = Get-WpbdImageEvidence $row.ProcessId $identity }
                catch { $image = [pscustomobject]@{Path=$null;Status='LookupUnavailable'} }
                finally { $native.Stop() }
                $lookups++
                $path = $image.Path; $pathStatus = $image.Status; $pathSource = 'LimitedInformation'
            }
        }
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
            Identity = $identity
            Id = [int] $row.ProcessId; StartUtc = $start; Name = $row.Name
            Path = $path; CimPath = $row.ExecutablePath; PathSource = $pathSource; PathStatus = $pathStatus
            Phase = $Phase; CapturedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            ServiceLookupStatus = $serviceStatus
            ParentId = [int] $row.ParentProcessId; ParentStartUtc = $parentStart
            WebViewHostExecutable = $hostName
            Services = @(if ($row.CreationDate.ToUniversalTime() -le $serviceCutoff) {
                $servicesByPid[[int] $row.ProcessId] | Where-Object { $_ }
            })
        }
    }
    $native.Stop(); $watch.Stop()
    if ($Timing) {
        $Timing.Value = [pscustomobject]@{ TotalSeconds = $watch.Elapsed.TotalSeconds; ImageLookupSeconds = $native.Elapsed.TotalSeconds; ImageLookups = $lookups }
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
    $sampleTimes = @{}
    foreach ($sample in $Samples) { $sampleTimes[[int] $sample.Slot] = $sample.TimestampUtc }
    $byPid = @{}
    foreach ($row in $MetadataRows) {
        if (-not $row.Identity) { continue }
        if (-not $byPid.ContainsKey([int] $row.Id)) { $byPid[[int] $row.Id] = New-Object 'System.Collections.Generic.List[object]' }
        $byPid[[int] $row.Id].Add($row)
    }
    $metadata = @{}
    foreach ($row in $MetadataRows) {
        if (-not $row.Identity) { continue }
        $row = $row | Select-Object *
        $previous = $metadata[$row.Identity]
        if (-not $previous -or (-not $previous.ParentStartUtc -and $row.ParentStartUtc)) {
            if ($previous.Services) { $row.Services = @($row.Services + $previous.Services | Select-Object -Unique) }
            $metadata[$row.Identity] = $row
        } else {
            if (-not $previous.Path -and $row.Path) {
                $previous.Path = $row.Path
                if ($row.PathSource) { $previous.PathSource = $row.PathSource; $previous.PathStatus = $row.PathStatus }
            }
            if ($row.Services) { $previous.Services = @($previous.Services + $row.Services | Select-Object -Unique) }
        }
    }
    $owners = @{}
    $groups = @{}
    foreach ($process in $Processes) {
        $identity = Get-WpbdProcessIdentity $process.Id $process.StartUtc
        $details = $null
        $match = 'Unavailable'
        if ($identity) { $details = $metadata[$identity] }
        if ($details) { $match = 'VerifiedStart' }
        $stableServices = $null
        if (-not $identity -and $sampleTimes[[int] $process.FirstSlot] -and $sampleTimes[[int] $process.LastSlot]) {
            $rows = @($byPid[[int] $process.Id] | Where-Object {
                $_.Name -and [IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $process.Name
            })
            $before = @($rows | Where-Object {
                $_.Phase -eq 'Before' -and $_.CapturedUtc -and
                ([DateTimeOffset] $_.CapturedUtc) -le ([DateTimeOffset] $sampleTimes[[int] $process.FirstSlot])
            })
            $after = @($rows | Where-Object {
                $_.Phase -eq 'After' -and $_.CapturedUtc -and
                ([DateTimeOffset] $_.CapturedUtc) -ge ([DateTimeOffset] $sampleTimes[[int] $process.LastSlot])
            })
            if ($before.Count -eq 1 -and $after.Count -eq 1 -and
                $before[0].Identity -eq $after[0].Identity -and
                ([DateTimeOffset] $before[0].StartUtc) -le ([DateTimeOffset] $sampleTimes[[int] $process.FirstSlot])) {
                $identity = $before[0].Identity
                $details = $metadata[$identity]
                $match = 'BracketedInventories'
                $stableServices = @($before[0].Services | Where-Object { $_ -in $after[0].Services })
            }
        }
        if ($details.Path) { $process.Path = $details.Path }
        $services = @($details.Services | Where-Object { $_ })
        if ($match -eq 'BracketedInventories') { $services = $stableServices }
        $systemRoot = [Environment]::GetFolderPath('Windows')
        $systemPath = $false
        if ($systemRoot -and $process.Path) {
            $directory = [IO.Path]::GetDirectoryName($process.Path)
            $systemPath = $directory -ieq (Join-Path $systemRoot 'System32') -or
                $directory -ieq (Join-Path $systemRoot 'SysWOW64')
        }
        $systemFile = [IO.Path]::GetFileName($process.Path)
        $windowsComponent = $systemPath -and
            $systemFile -match '^(svchost|lsass|csrss|smss|wininit|winlogon|services|dwm|fontdrvhost|sihost|taskhostw|dllhost|conhost|SearchIndexer|spoolsv|RuntimeBroker|SecurityHealthService|SgrmBroker)\.exe$'
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
            if ($owner.Key -eq 'unattributed') {
                $category = 'Identified service process'
                $confidence = 'Medium'
                $owner = [pscustomobject]@{
                    Name = "Service process: $($services -join ', ')"; Key = "service/$identity"
                    Evidence = 'Service PID matched to process creation evidence; executable and publisher remain unverified'
                }
            }
        }
        if ($owner.Key -eq 'unattributed') {
            $confidence = 'Low'
            $category = 'Unknown process ownership'
            if ($process.MetadataAccess -eq 'Restricted') { $category = 'Protected or restricted process' }
            elseif ($process.Path) { $category = 'Unattributed application process' }
            $owner = [pscustomobject]@{ Name = $category; Key = "category/$category"; Evidence = $owner.Evidence }
        }
        if ($process.IdentityStatus -eq 'Provisional') {
            $confidence = if ($match -eq 'BracketedInventories') { 'Medium' } else { 'Low' }
        }
        $reasons = New-Object 'System.Collections.Generic.List[string]'
        $evidenceRows = @($byPid[[int] $process.Id] | Where-Object { $_.Identity -eq $identity })
        $pathStatuses = @($evidenceRows.PathStatus | Where-Object { $_ } | Select-Object -Unique)
        if ($process.MetadataAccess -eq 'Restricted' -or 'AccessDenied' -in $pathStatuses) { $reasons.Add('AccessDenied') }
        if (-not $process.StartUtc) { $reasons.Add('CreationTimeUnavailable') }
        if (-not $details) { $reasons.Add('MetadataIdentityUnavailable') }
        foreach ($status in $pathStatuses) {
            if ($status -in @('ProcessExited', 'IdentityMismatch', 'LookupBudgetExceeded', 'LookupUnavailable')) { $reasons.Add($status) }
        }
        if (-not $process.Path) { $reasons.Add('PathUnavailable') }
        if (@($evidenceRows | Where-Object { $_.ServiceLookupStatus -and $_.ServiceLookupStatus -ne 'Available' }).Count) {
            $reasons.Add('ServiceMetadataUnavailable')
        }
        if ($owner.Key -eq 'category/Unattributed application process') { $reasons.Add('ParentUnavailable') }
        if ($category -in @('Protected or restricted process', 'Unattributed application process', 'Unknown process ownership')) {
            $reasons.Add('OwnershipUnresolved')
        }
        $packageDirectory = $null
        if ($process.Path -match '(?i)\\WindowsApps\\([^\\]+)\\') { $packageDirectory = $Matches[1] }
        foreach ($field in @{
            AttributionCategory = $category; AttributionConfidence = $confidence; ProcessType = $type
            ParentId = $details.ParentId; ParentStartUtc = $details.ParentStartUtc
            Services = $services; PackageDirectory = $packageDirectory
            MetadataIdentityMatch = $match; AttributionReasons = $reasons.ToArray(); ImagePathSource = $details.PathSource
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
            AttributionConfidence = $(if (@($group.Processes | Where-Object AttributionConfidence -eq 'Low').Count) { 'Low' }
                elseif (@($group.Processes | Where-Object AttributionConfidence -eq 'Medium').Count) { 'Medium' } else { 'High' })
            AttributionCategory = $group.Processes[0].AttributionCategory
        }
    }
}

function Get-WpbdAttributionQuality {
    param($Samples, $Processes)
    $total = @($Processes).Count
    $identified = @($Processes | Where-Object AttributionCategory -eq 'Identified application').Count
    $system = @($Processes | Where-Object AttributionCategory -eq 'Windows system process').Count
    $service = @($Processes | Where-Object AttributionCategory -eq 'Identified service process').Count
    $unowned = @{}
    foreach ($process in $Processes) {
        if ($process.AttributionCategory -notin @('Identified application', 'Windows system process', 'Identified service process')) { $unowned[$process.InstanceKey] = $true }
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
        IdentifiedServices = $service
        RestrictedProcesses = @($Processes | Where-Object MetadataAccess -eq 'Restricted').Count
        UnattributedApplications = @($Processes | Where-Object AttributionCategory -eq 'Unattributed application process').Count
        UnknownOwnership = @($Processes | Where-Object AttributionCategory -eq 'Unknown process ownership').Count
        RestrictedOwnership = @($Processes | Where-Object AttributionCategory -eq 'Protected or restricted process').Count
        AttributedPercent = Get-WpbdRatio ($identified + $system + $service) $total 100
        ApplicationAndWindowsPercent = Get-WpbdRatio ($identified + $system) $total 100
        AttributionReasons = @($Processes | ForEach-Object { $_.AttributionReasons } | Group-Object | Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ Reason = $_.Name; Identities = $_.Count } })
        ConcurrentProcesses = Get-WpbdStatistics @($Samples | ForEach-Object { [pscustomobject]@{ Count = @($_.Processes).Count } }) 'Count'
        UnattributedPrivateBytes = Get-WpbdStatistics $memory 'PrivateBytes'
        UnattributedSamples = $memory
    }
}
