# Presentation only: never classify measurements or modify the supplied diagnostic.
function Get-WpbdPresentationFormat {
    if (-not $script:WpbdPresentationFormat) {
        $script:WpbdPresentationFormat = Get-Content -LiteralPath "$PSScriptRoot/Presentation-Format.json" -Raw | ConvertFrom-Json
    }
    $script:WpbdPresentationFormat
}

function Format-WpbdDisplayValue {
    param($Value, [string] $Unit = 'count')
    if ($null -eq $Value) { return 'Unavailable' }
    $v = [double] $Value
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return 'Unavailable' }
    $format = '0.##'; $suffix = ''
    switch ($Unit) {
        'bytes' {
            if ([Math]::Abs($v) -ge 1GB) { $v /= 1GB; $format='0.00'; $suffix=' GiB' }
            else { $v /= 1MB; $format='0.#'; $suffix=' MiB' }
        }
        'bytes/s' {
            if ([Math]::Abs($v) -ge 1MB) { $v /= 1MB; $suffix=' MiB/s' }
            else { $v /= 1KB; $suffix=' KiB/s' }
        }
        'percent' { $format='0.0'; $suffix='%' }
        'ms' { $format='0.00'; $suffix=' ms' }
        'seconds' { $suffix=' s' }
        { $_ -in @('reads/s','pages/s','ops/s') } { $suffix=" $Unit" }
    }
    $digits=if($format -in @('0.#','0.0')){1}else{2}
    $v=[Math]::Round($v,$digits,[MidpointRounding]::AwayFromZero)
    $v.ToString($format, [Globalization.CultureInfo]::InvariantCulture) + $suffix
}

function Get-WpbdEvidenceRows {
    param($Evidence, [string] $Prefix = '')
    if ($null -eq $Evidence) { return }
    $spec=Get-WpbdPresentationFormat
    foreach ($p in $Evidence.PSObject.Properties) {
        $key=$p.Name; $v=$p.Value; $field=$spec.Fields.$key
        $label=if($field){$field.Label}else{[regex]::Replace($key,'(?<=[a-z])(?=[A-Z])',' ')}
        if($Prefix){$label="$Prefix / $label"}
        $unit=if($field){$field.Unit}elseif($key -match 'Percent$'){'percent'}elseif($key -match 'Bytes$'){'bytes'}elseif($key -match 'Seconds$'){'seconds'}else{'count'}
        if ($null -ne $v -and $v.PSObject.Properties['Average'] -and $v.PSObject.Properties['Count']) {
            [pscustomobject]@{Key=$key; Measurement=$label; Average=Format-WpbdDisplayValue $v.Average $unit; Minimum=Format-WpbdDisplayValue $v.Minimum $unit; Maximum=Format-WpbdDisplayValue $v.Maximum $unit; Coverage="$($v.Count) samples"}
        } elseif ($v -is [pscustomobject]) {
            Get-WpbdEvidenceRows $v $label
        } elseif ($v -is [array]) {
            $index=0
            foreach($item in $v){
                if($item -is [pscustomobject]){Get-WpbdEvidenceRows $item "$label $index"}
                else{[pscustomobject]@{Key=$key;Measurement=$label;Average=[string]$item;Minimum='—';Maximum='—';Coverage='Recorded'}}
                $index++
            }
        } else {
            $value=if($null -eq $v){'Unavailable'}elseif($v -is [ValueType] -and $v -isnot [bool]){Format-WpbdDisplayValue $v $unit}else{[string]$v}
            [pscustomobject]@{Key=$key;Measurement=$label;Average=$value;Minimum='—';Maximum='—';Coverage='Recorded'}
        }
    }
}

function Get-WpbdContributorPresentation {
    param($Contributor)
    $c=$Contributor; $unit=if($c.Resource -eq 'CpuPercent'){'percent'}else{'bytes'}
    $resource=if($c.Resource -eq 'CpuPercent'){'CPU'}else{'private allocation'}
    $usage="Average $(Format-WpbdDisplayValue $c.Usage.Average $unit); peak $(Format-WpbdDisplayValue $c.Usage.Maximum $unit) $resource"
    $kind=if(-not $c.ApplicationKey){'Individual process'}elseif($c.ApplicationKey -match '^(service|windows)/'){'Process group'}else{'Application group'}
    $attribution=if($c.ApplicationKey){"Ownership evidence: $($c.AttributionConfidence) confidence"}else{'Ownership unresolved'}
    $coverage="$($c.MeasurementCoverage.ValidSamples) of $($c.MeasurementCoverage.SelectedSamples) selected samples"
    $details=@(
        "$kind — $attribution. $coverage."
        $c.Reason
        "Application reference: $(if($c.ApplicationKey){$c.ApplicationKey}else{'Unavailable'})"
        "Relevant $resource`: average $(Format-WpbdDisplayValue $c.Usage.Average $unit); minimum $(Format-WpbdDisplayValue $c.Usage.Minimum $unit); peak $(Format-WpbdDisplayValue $c.Usage.Maximum $unit); $(Format-WpbdDisplayValue $c.Usage.Count) measured samples."
        "Present in $(Format-WpbdDisplayValue $c.MeasurementCoverage.PresentSamples) of $(Format-WpbdDisplayValue $c.MeasurementCoverage.SelectedSamples) selected samples."
        "Working set: average $(Format-WpbdDisplayValue $c.WorkingSetBytes.Average bytes); minimum $(Format-WpbdDisplayValue $c.WorkingSetBytes.Minimum bytes); peak $(Format-WpbdDisplayValue $c.WorkingSetBytes.Maximum bytes); $(Format-WpbdDisplayValue $c.WorkingSetBytes.Count) measured samples."
        $(foreach($p in $c.ProcessIdentities){
            "$($p.Name) — PID $($p.Id), $($p.IdentityStatus); identity: $($p.InstanceKey)"
            if($p.Usage){"  Average $(Format-WpbdDisplayValue $p.Usage.Average $unit); minimum $(Format-WpbdDisplayValue $p.Usage.Minimum $unit); peak $(Format-WpbdDisplayValue $p.Usage.Maximum $unit); $(Format-WpbdDisplayValue $p.Usage.Count) measured samples."}
            if($p.WorkingSetBytes){"  Working set: average $(Format-WpbdDisplayValue $p.WorkingSetBytes.Average bytes); minimum $(Format-WpbdDisplayValue $p.WorkingSetBytes.Minimum bytes); peak $(Format-WpbdDisplayValue $p.WorkingSetBytes.Maximum bytes); $(Format-WpbdDisplayValue $p.WorkingSetBytes.Count) measured samples."}
        })
        "Measured slots: $(@($c.SampleSlots) -join ', ')"
    ) -join "`n"
    [pscustomobject]@{Name=$c.Name;Kind=$kind;Usage=$usage;Attribution=$attribution;Coverage=$coverage;Details=$details}
}

function Get-WpbdInsightPresentation {
    param($Insight)
    $i=$Insight
    $rows=@(Get-WpbdEvidenceRows $i.SupportingEvidence)
    $keys=(Get-WpbdPresentationFormat).PrimaryFields.($i.Category)
    $primary=if($keys){@(foreach($key in $keys){$rows | Where-Object Key -eq $key})}else{@($rows | Select-Object -First 4)}
    $observation=$i.Observation
    if($i.Category -in @('Memory pressure','Elevated memory utilisation')){
        $e=$i.SupportingEvidence
        $observation="Average physical memory use was $(Format-WpbdDisplayValue $e.UsedPercent.Average percent); minimum available RAM was $(Format-WpbdDisplayValue $e.AvailableBytes.Minimum bytes)."
    }
    $contributors=@($i.PotentialContributors | ForEach-Object {Get-WpbdContributorPresentation $_})
    $steps=@($i.SuggestedInvestigation | Where-Object {$_})
    $limits=@($i.DataLimitations | Where-Object {$_})
    $window=if($i.StartedUtc -and $i.CompletedUtc){"$($i.StartedUtc) to $($i.CompletedUtc)"}else{'Unavailable'}
    [pscustomobject]@{
        Observation=$observation; Interpretation=$i.Interpretation; Measurements=@($primary); TechnicalMeasurements=$rows
        Contributors=@($contributors | Select-Object -First 5); AllContributors=$contributors
        Steps=@(for($n=0;$n -lt [Math]::Min(3,$steps.Count);$n++){"$($n+1). $($steps[$n])"})
        AllSteps=@(for($n=0;$n -lt $steps.Count;$n++){"$($n+1). $($steps[$n])"})
        Limitation=if($limits.Count){$limits[-1]}else{''}
        TechnicalReferences="Observation window (UTC): $window`nSample slots: $(@($i.SampleSlots) -join ', ')`nMeasurement references: $(@($i.MeasurementReferences) -join ', ')"
        Limitations=$limits -join "`n"
    }
}

function Get-WpbdOverview {
    param($Diagnostic)
    $d=$Diagnostic; $insights=@($d.DiagnosticInsights | Where-Object {$null -ne $_})
    $significant=@($d.Findings | Where-Object {$_.Category -notin @('No clear bottleneck detected','Insufficient diagnostic data')}).Count
    $advisories=@($d.Advisories | Where-Object {$null -ne $_})
    $summary=$d.Assessment.Summary
    if($advisories.Count){$summary += ' ' + (($advisories | ForEach-Object {$_.Category}) -join '; ') + '.'}
    $top=@($insights | Where-Object Id -ne 'operation.normal' | Select-Object -First 1)
    if(-not $top.Count){$top=@($insights | Select-Object -First 1)}
    $focus=if($top.Count){"Highest-priority insight: $($top[0].Title) — $($top[0].Priority) priority; $($top[0].Confidence) confidence."}else{'Insight priority and confidence were not recorded.'}
    $findingWord=if($significant -eq 1){'finding'}else{'findings'}
    $advisoryWord=if($advisories.Count -eq 1){'advisory'}else{'advisories'}
    [pscustomobject]@{Summary=$summary;Focus=$focus;Counts="$significant significant $findingWord; $($advisories.Count) $advisoryWord.";Sampling="$($d.SamplingQuality.ActualSamples) of $($d.SamplingQuality.ExpectedSamples) scheduled samples collected; $($d.SamplingQuality.MissedSampleCount) missed."}
}
function New-WpbdHtmlInsight {
    param($Insight, $Diagnostic)
    $i=$Insight; $p=Get-WpbdInsightPresentation $i
    $measurements=New-WpbdHtmlTable @('Supporting measurement','Average / value','Minimum','Maximum','Coverage') @($p.Measurements | ForEach-Object {,@($_.Measurement,$_.Average,$_.Minimum,$_.Maximum,$_.Coverage)})
    $technical=New-WpbdHtmlTable @('Measurement','Average / value','Minimum','Maximum','Coverage') @($p.TechnicalMeasurements | ForEach-Object {,@($_.Measurement,$_.Average,$_.Minimum,$_.Maximum,$_.Coverage)})
    $contributors=if($p.Contributors.Count){
        '<h4>Potential contributors</h4>' + (New-WpbdHtmlTable @('Application / process','Type','Relevant measured usage','Attribution','Coverage') @($p.Contributors | ForEach-Object {,@($_.Name,$_.Kind,$_.Usage,$_.Attribution,$_.Coverage)}))
    }
    $steps=(@($p.Steps | ForEach-Object {'<li>'+(ConvertTo-WpbdHtmlText ($_ -replace '^\d+\. ',''))+'</li>'}) -join '')
    $allSteps=(@($p.AllSteps | ForEach-Object {'<li>'+(ConvertTo-WpbdHtmlText ($_ -replace '^\d+\. ',''))+'</li>'}) -join '')
    $allContributors=(@($p.AllContributors | ForEach-Object {'<h5>'+(ConvertTo-WpbdHtmlText $_.Name)+'</h5><p class="technical-text">'+(ConvertTo-WpbdHtmlText $_.Details)+'</p>'}) -join '')
    $keys=@{}; foreach($c in $i.PotentialContributors){foreach($identity in $c.ProcessIdentities){$keys[$identity.InstanceKey]=$true}}
    $identities=@($Diagnostic.Statistics.Processes.All | Where-Object {$_.InstanceKey -and $keys.ContainsKey($_.InstanceKey)})
    $ownership=if($identities.Count){New-WpbdHtmlTable @('Process','PID','Executable path','Ownership evidence','Attribution category','Attribution confidence','Metadata match','Reason codes') @($identities | ForEach-Object {,@($_.Name,$_.Id,$_.Path,$_.OwnershipEvidence,$_.AttributionCategory,$_.AttributionConfidence,$_.MetadataIdentityMatch,($_.AttributionReasons -join ', '))})}
    @"
<article class="finding insight"><h3>$(ConvertTo-WpbdHtmlText $i.Title)</h3>
<p class="meta">Priority: $(ConvertTo-WpbdHtmlText $i.Priority) &middot; Severity: $(ConvertTo-WpbdHtmlText $i.Severity) &middot; Confidence: $(ConvertTo-WpbdHtmlText $i.Confidence)</p>
<p>$(ConvertTo-WpbdHtmlText $p.Observation)</p><p>$(ConvertTo-WpbdHtmlText $p.Interpretation)</p>
$measurements$contributors
<h4>Suggested investigation</h4><ol>$steps</ol>
<p class="meta">$(ConvertTo-WpbdHtmlText $p.Limitation)</p>
<details><summary>Technical evidence and full contributor details</summary>
<p class="technical-text">$(ConvertTo-WpbdHtmlText $p.TechnicalReferences)</p>$technical
$allContributors$ownership<h4>All recorded investigation steps</h4><ol>$allSteps</ol>
<h4>Collection and interpretation limitations</h4><p class="technical-text">$(ConvertTo-WpbdHtmlText $p.Limitations)</p>
</details></article>
"@
}
