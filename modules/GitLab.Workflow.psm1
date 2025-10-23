Set-StrictMode -Version Latest

class GitLabCheckpointContext {
    [string]$RootPath
    [string]$RunId
    [datetime]$Created
    [hashtable]$Signature
    [hashtable]$StageStatus
    [hashtable]$Timings
    [bool]$UseExisting = $false
    [bool]$ForceRestart = $false
    [bool]$Enabled = $true
    [string]$MetadataPath
}

function Format-GitLabDuration {
    param([TimeSpan]$Duration)
    if (-not $Duration) { return "0s" }
    if ($Duration.TotalHours -ge 1) {
        return ("{0:N2} h" -f $Duration.TotalHours)
    } elseif ($Duration.TotalMinutes -ge 1) {
        return ("{0:N2} min" -f $Duration.TotalMinutes)
    }
    return ("{0:N1} s" -f $Duration.TotalSeconds)
}

function Initialize-GitLabCheckpoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$RunKey,
        [hashtable]$Signature,
        [switch]$ForceRestart
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $root = Join-Path $OutputPath 'checkpoints'
    if (-not (Test-Path $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $runPath = Join-Path $root $RunKey
    if (-not (Test-Path $runPath)) {
        New-Item -ItemType Directory -Path $runPath -Force | Out-Null
    }

    $context = [GitLabCheckpointContext]::new()
    $context.RootPath = $runPath
    $context.RunId = $RunKey
    $context.Created = Get-Date
    $context.Signature = if ($Signature) { $Signature } else { @{} }
    $context.StageStatus = [ordered]@{}
    $context.Timings = @{}
    $context.MetadataPath = Join-Path $runPath 'metadata.json'
    $context.ForceRestart = $ForceRestart.IsPresent

    if (-not $context.ForceRestart -and (Test-Path $context.MetadataPath)) {
        try {
            $metadata = Get-Content -Raw -Path $context.MetadataPath | ConvertFrom-Json -Depth 10
            if ($metadata -and $metadata.Signature) {
                $match = $true
                foreach ($key in $context.Signature.Keys) {
                    if ($metadata.Signature.$key -ne $context.Signature[$key]) {
                        $match = $false
                        break
                    }
                }
                if ($match) {
                    $context.UseExisting = $true
                    if ($metadata.Stages) {
                        foreach ($prop in $metadata.Stages.PSObject.Properties) {
                            $context.StageStatus[$prop.Name] = $prop.Value
                        }
                    }
                }
            }
        } catch {
            Write-Log -Message "Failed to read checkpoint metadata: $($_.Exception.Message)" -Level "Warning" -Component "Checkpoint"
        }
    }

    return $context
}

function Save-GitLabCheckpointMetadata {
    param([GitLabCheckpointContext]$Context)
    if (-not $Context.Enabled) { return }
    $metadata = [ordered]@{
        RunId = $Context.RunId
        Signature = $Context.Signature
        GeneratedAt = Get-Date
        Stages = $Context.StageStatus
    }
    $metadata | ConvertTo-Json -Depth 10 | Out-File -FilePath $Context.MetadataPath -Encoding UTF8
}

function Get-GitLabCheckpoint {
    [CmdletBinding()]
    param(
        [GitLabCheckpointContext]$Context,
        [string]$Stage
    )

    if (-not $Context.Enabled -or -not $Context.UseExisting) { return $null }
    $path = Join-Path $Context.RootPath ("{0}.clixml" -f $Stage)
    if (-not (Test-Path $path)) { return $null }
    try {
        return Import-Clixml -Path $path
    } catch {
        Write-Log -Message "Failed to load checkpoint '$Stage': $($_.Exception.Message)" -Level "Warning" -Component "Checkpoint"
        return $null
    }
}

function Save-GitLabCheckpoint {
    [CmdletBinding()]
    param(
        [GitLabCheckpointContext]$Context,
        [string]$Stage,
        [object]$Data = $null,
        [switch]$Skipped,
        [switch]$Restored
    )

    if (-not $Context.Enabled) { return }
    $now = Get-Date

    if ($Skipped) {
        $Context.StageStatus[$Stage] = [ordered]@{
            Status = 'Skipped'
            SavedAt = $now
            DurationSeconds = 0
            DurationReadable = "0s"
        }
        Save-GitLabCheckpointMetadata -Context $Context
        return
    }

    if ($Restored) {
        $entry = $Context.StageStatus[$Stage]
        if ($entry) {
            if ($entry -isnot [hashtable]) {
                $converted = [ordered]@{}
                $entry.PSObject.Properties | ForEach-Object { $converted[$_.Name] = $_.Value }
                $entry = $converted
            }
        } else {
            $entry = [ordered]@{}
        }

        $entry['Status'] = 'Restored'
        $entry['RestoredAt'] = $now
        if ($entry.ContainsKey('DurationSeconds') -and $entry['DurationSeconds'] -and -not $entry['DurationReadable']) {
            $entry['DurationReadable'] = Format-GitLabDuration ([TimeSpan]::FromSeconds($entry['DurationSeconds']))
        }

        if (-not $entry.ContainsKey('SavedAt')) {
            $entry['SavedAt'] = $now
        }

        $Context.StageStatus[$Stage] = $entry
        Save-GitLabCheckpointMetadata -Context $Context
        return
    }

    $startInfo = $Context.Timings[$Stage]
    $duration = if ($startInfo -and $startInfo.Started) { (Get-Date) - $startInfo.Started } else { [TimeSpan]::Zero }
    if ($null -ne $Data) {
        $path = Join-Path $Context.RootPath ("{0}.clixml" -f $Stage)
        try {
            $Data | Export-Clixml -Path $path -Force
        } catch {
            Write-Log -Message "Failed to save checkpoint '$Stage': $($_.Exception.Message)" -Level "Error" -Component "Checkpoint"
        }
    }

    $Context.StageStatus[$Stage] = [ordered]@{
        Status = 'Completed'
        SavedAt = $now
        DurationSeconds = [math]::Round($duration.TotalSeconds, 2)
        DurationReadable = Format-GitLabDuration $duration
    }
    Save-GitLabCheckpointMetadata -Context $Context
}

function Start-GitLabCheckpoint {
    [CmdletBinding()]
    param(
        [GitLabCheckpointContext]$Context,
        [string]$Stage,
        [string]$Label
    )

    if (-not $Context.Enabled) { return }
    $Context.Timings[$Stage] = @{ Started = Get-Date }
    if ($Label) {
        Write-Log -Message "Starting checkpoint '$Label'..." -Level "Info" -Component "Checkpoint"
    }
}

function Restore-GitLabCheckpoint {
    [CmdletBinding()]
    param(
        [GitLabCheckpointContext]$Context,
        [string]$Stage,
        [string]$Label
    )

    $data = Get-GitLabCheckpoint -Context $Context -Stage $Stage
    if ($null -ne $data) {
        $info = $Context.StageStatus[$Stage]
        $saved = if ($info -and $info.SavedAt) { (Get-Date $info.SavedAt).ToString("yyyy-MM-dd HH:mm:ss") } else { "previous run" }
        Write-Log -Message "Restored checkpoint '$Label' (saved $saved)" -Level "Info" -Component "Checkpoint"
        Save-GitLabCheckpoint -Context $Context -Stage $Stage -Restored
    }
    return $data
}

function Publish-GitLabCheckpointSummary {
    param([GitLabCheckpointContext]$Context, [hashtable]$StageLabels)
    if (-not $Context.Enabled -or $Context.StageStatus.Count -eq 0) { return }
    Write-Log -Message "Checkpoint timing summary:" -Level "Info" -Component "Checkpoint"
    foreach ($stage in $Context.StageStatus.Keys) {
        $info = $Context.StageStatus[$stage]
        $label = if ($StageLabels -and $StageLabels.Contains($stage)) { $StageLabels[$stage] } else { $stage }
        $status = if ($info.Status) { $info.Status } else { "Unknown" }
        $durationText = if ($info.DurationReadable) {
            $info.DurationReadable
        } elseif ($info.DurationSeconds) {
            Format-GitLabDuration ([TimeSpan]::FromSeconds($info.DurationSeconds))
        } else {
            "0s"
        }
        $message = " - $label : $status"
        if ($status -in @("Completed","Restored") -and $durationText) {
            $message += " ($durationText)"
        }
        Write-Log -Message $message -Level "Info" -Component "Checkpoint"
    }
}

function ConvertTo-GitLabArray {
    param($Data)
    if ($null -eq $Data) { return @() }
    if ($Data -is [string]) { return @($Data) }
    if ($Data -is [System.Collections.IEnumerable]) {
        return @($Data | ForEach-Object { $_ })
    }
    return @($Data)
}

Export-ModuleMember -Function Initialize-GitLabCheckpoints,Start-GitLabCheckpoint,Save-GitLabCheckpoint,Restore-GitLabCheckpoint,Publish-GitLabCheckpointSummary,ConvertTo-GitLabArray,Format-GitLabDuration,Get-GitLabCheckpoint
