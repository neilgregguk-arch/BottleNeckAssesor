function Get-WpbdWorkerPermissions {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not ('Wpbd.WorkerToken' -as [type])) { Add-Type -LiteralPath "$PSScriptRoot/WorkerToken.cs" -ErrorAction Stop }
        $token=[Wpbd.WorkerToken]::ReadCurrent()
        [pscustomobject]@{
            RequestedMode='Standard'; ElevationOutcome='NotRequested'; ElevatedFeatureStatus='Unavailable'
            TokenInspectionStatus=$(if($token.Available){'Available'}else{'Unavailable'})
            ActualWorkerIsElevated=$token.IsElevated; AdministratorGroupPresent=$token.AdministratorGroupPresent
            AdministratorGroupEnabled=$token.AdministratorGroupEnabled; IntegrityRid=$token.IntegrityRid; IntegrityLevel=$token.IntegrityLevel
            VerifiedHighIntegrityAdministrator=$token.VerifiedHighIntegrityAdministrator
            TokenInspectionErrorCode=$token.ErrorCode; TokenInspectionSeconds=$clock.Elapsed.TotalSeconds
        }
    } catch {
        [pscustomobject]@{
            RequestedMode='Standard'; ElevationOutcome='NotRequested'; ElevatedFeatureStatus='Unavailable'
            TokenInspectionStatus='Unavailable'; ActualWorkerIsElevated=$null; AdministratorGroupPresent=$null
            AdministratorGroupEnabled=$null; IntegrityRid=$null; IntegrityLevel='Unavailable'; VerifiedHighIntegrityAdministrator=$false
            TokenInspectionErrorCode=$_.Exception.HResult; TokenInspectionSeconds=$clock.Elapsed.TotalSeconds
        }
    } finally { $clock.Stop() }
}

function Get-WpbdPermissionReport {
    param($Captured, $Processes, $Attribution, $Sampling, $CollectionErrors)
    # Never query the current machine while analysing saved/synthetic measurements.
    $rows=@($Processes | Where-Object {$null -ne $_})
    $verified=@($rows | Where-Object IdentityStatus -eq 'Verified').Count
    $paths=@($rows | Where-Object {$_.Path}).Count
    $services=@($rows | Where-Object {@($_.Services | Where-Object {$_}).Count -gt 0}).Count
    $reasons=@($Attribution.AttributionReasons | Where-Object {$_.Reason -in @('AccessDenied','PathUnavailable','CreationTimeUnavailable','ServiceMetadataUnavailable','OwnershipUnresolved')} | ForEach-Object {"$($_.Reason): $($_.Identities) captured identities"})
    [pscustomobject]@{
        RequestedMode=$(if($Captured.RequestedMode -in @('Standard','Elevated')){$Captured.RequestedMode}else{'NotRecorded'})
        ElevationOutcome=$(if($Captured.ElevationOutcome -eq 'NotRequested' -and $Captured.RequestedMode -eq 'Standard'){'NotRequested'}else{'NotVerified'})
        ElevatedFeatureStatus='Unavailable'
        TokenInspectionStatus=$(if($Captured.TokenInspectionStatus){$Captured.TokenInspectionStatus}else{'NotRecorded'})
        ActualWorkerIsElevated=$Captured.ActualWorkerIsElevated; AdministratorGroupPresent=$Captured.AdministratorGroupPresent
        AdministratorGroupEnabled=$Captured.AdministratorGroupEnabled; IntegrityRid=$Captured.IntegrityRid
        IntegrityLevel=$(if($Captured.IntegrityLevel){$Captured.IntegrityLevel}else{'Unavailable'})
        VerifiedHighIntegrityAdministrator=($Captured.TokenInspectionStatus -eq 'Available' -and $Captured.ActualWorkerIsElevated -is [bool] -and $Captured.ActualWorkerIsElevated -eq $true -and $Captured.AdministratorGroupEnabled -is [bool] -and $Captured.AdministratorGroupEnabled -eq $true -and ($Captured.IntegrityRid -is [int] -or $Captured.IntegrityRid -is [long]) -and $Captured.IntegrityRid -ge 0x3000 -and $Captured.IntegrityRid -le [int]::MaxValue)
        TokenInspectionErrorCode=$Captured.TokenInspectionErrorCode
        Coverage=[pscustomobject]@{
            CapturedIdentities=$rows.Count; VerifiedIdentities=$verified; VerifiedIdentityPercent=Get-WpbdRatio $verified $rows.Count 100
            ExecutablePaths=$paths; ExecutablePathPercent=Get-WpbdRatio $paths $rows.Count 100
            ServiceAssociatedIdentities=$services; ServiceAssociationPercent=Get-WpbdRatio $services $rows.Count 100
            AttributionPercent=$Attribution.AttributedPercent; IdentifiedApplications=$Attribution.IdentifiedApplications
            IdentifiedServices=$Attribution.IdentifiedServices; RestrictedMetadataIdentities=$Attribution.RestrictedProcesses
            CollectionErrorGroups=@($CollectionErrors | Where-Object {$null -ne $_}).Count
            ExpectedSamples=$Sampling.ExpectedSamples; ActualSamples=$Sampling.ActualSamples
            ValidCpuSamples=$Sampling.ValidSamples.CpuTotal; MissedSamples=$Sampling.MissedSampleCount
        }
        Limitations=@(
            $(if($Captured.TokenInspectionStatus -eq 'Unavailable'){'Worker token inspection was unavailable; token elevation could not be verified. Error code: ' + $(if($null -ne $Captured.TokenInspectionErrorCode){$Captured.TokenInspectionErrorCode}else{'Unavailable'})})
            'Elevated diagnostics are unavailable in this build; no privileged worker or cross-account IPC is shipped.'
            'Coverage percentages refer to captured process identities, not every process that ran. Independently captured scans may have different process populations.'
            'Administrator membership alone does not establish elevation. Protected processes can remain inaccessible even to an administrator.'
            $reasons
        )
    }
}
function Get-WpbdPermissionPresentation {
    param($Data)
    if($null -eq $Data){return $null}
    $requested=if($Data.RequestedMode -in @('Standard','Elevated')){$Data.RequestedMode}else{'Not recorded'}
    $available=$Data.TokenInspectionStatus -eq 'Available'
    $elevated=if($Data.ActualWorkerIsElevated -is [bool]){$Data.ActualWorkerIsElevated}else{$null}
    $member=if($Data.AdministratorGroupPresent -is [bool]){$Data.AdministratorGroupPresent}else{$null}
    $enabled=if($Data.AdministratorGroupEnabled -is [bool]){$Data.AdministratorGroupEnabled}else{$null}
    $verified=$available -and $elevated -eq $true -and $enabled -eq $true -and
        ($Data.IntegrityRid -is [int] -or $Data.IntegrityRid -is [long]) -and $Data.IntegrityRid -ge 0x3000 -and $Data.IntegrityRid -le [int]::MaxValue
    $mode=if($requested -eq 'Not recorded'){'Not recorded'}else{
        $requested + $(if($available -and $elevated -eq $false){' / worker not elevated'}elseif($verified){' / elevated worker token recorded'}else{' / worker elevation not verified'})
    }
    $outcome=if($Data.ElevationOutcome -eq 'NotRequested' -and $requested -eq 'Standard'){'Not requested'}else{'Not verified'}
    $integrity=if($Data.IntegrityLevel){$Data.IntegrityLevel}else{'Unavailable'}
    $yesNo={param($v)if($null -eq $v){'Unavailable'}elseif($v){'Yes'}else{'No'}}
    $token="Worker elevated: $(& $yesNo $(if($available){$elevated}else{$null})); administrator group present: $(& $yesNo $member); administrator group enabled: $(& $yesNo $enabled); integrity: $integrity."
    $rows=@(foreach($field in (Get-WpbdPresentationFormat).PermissionFields.PSObject.Properties){
        [pscustomobject]@{Measurement=$field.Value.Label;Value=Format-WpbdDisplayValue $Data.Coverage.($field.Name) $field.Value.Unit}
    })
    [pscustomobject]@{Mode=$mode;Summary="$mode. Elevation: $outcome.";TokenSummary=$token;Coverage=$rows;Limitations=@($Data.Limitations) -join "`n"}
}
