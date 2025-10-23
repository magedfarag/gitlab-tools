Set-StrictMode -Version Latest

$script:LogLevels = @{
    "Debug"   = 0
    "Verbose" = 1
    "Info"    = 2
    "Success" = 2
    "Warning" = 3
    "Error"   = 4
}

$script:LogLevel = "Normal"
$script:NonInteractiveMode = $false
$script:FileLoggingEnabled = $false
$script:LogFilePath = $null

$script:CurrentSection = 'General'
$script:ActiveProgressState = @{
    Overall   = $null
    Checkpoint = $null
}

function Set-LogSection {
    param([string]$Section)

    if ([string]::IsNullOrWhiteSpace($Section)) {
        $script:CurrentSection = 'General'
    } else {
        $script:CurrentSection = $Section.Trim()
    }
}

function Update-ProgressDisplay {
    if ($script:NonInteractiveMode) { return }

    $overall = $script:ActiveProgressState.Overall
    if ($overall) {
        $overallParams = @{
            Id              = 0
            Activity        = $overall.Activity
            Status          = $overall.Status
            PercentComplete = $overall.Percent
        }
        if ($overall.CurrentOperation) { $overallParams.CurrentOperation = $overall.CurrentOperation }
        Write-Progress @overallParams
    }

    $checkpoint = $script:ActiveProgressState.Checkpoint
    if ($checkpoint) {
        $checkpointParams = @{
            Id              = 1
            ParentId        = 0
            Activity        = $checkpoint.Activity
            Status          = $checkpoint.Status
            PercentComplete = $checkpoint.Percent
        }
        if ($checkpoint.CurrentOperation) { $checkpointParams.CurrentOperation = $checkpoint.CurrentOperation }
        Write-Progress @checkpointParams
    }
}

function Complete-GitLabProgress {
    if ($script:NonInteractiveMode) { return }

    if ($script:ActiveProgressState.Checkpoint) {
        Write-Progress -Id 1 -ParentId 0 -Activity $script:ActiveProgressState.Checkpoint.Activity -Completed
    }
    if ($script:ActiveProgressState.Overall) {
        Write-Progress -Id 0 -Activity $script:ActiveProgressState.Overall.Activity -Completed
    }

    $script:ActiveProgressState.Overall = $null
    $script:ActiveProgressState.Checkpoint = $null
}

function Initialize-GitLabLogging {
    param(
        [ValidateSet("Minimal", "Normal", "Verbose", "Debug")]
        [string]$LogLevel = "Normal",
        [switch]$NonInteractive,
        [switch]$EnableFileLogging,
        [string]$LogFilePath
    )

    switch ($LogLevel) {
        "Minimal" { $script:LogLevel = "Warning" }
        "Normal"  { $script:LogLevel = "Info" }
        "Verbose" { $script:LogLevel = "Verbose" }
        "Debug"   { $script:LogLevel = "Debug" }
        default   { $script:LogLevel = "Info" }
    }
    $script:NonInteractiveMode = $NonInteractive.IsPresent
    $script:FileLoggingEnabled = $EnableFileLogging.IsPresent
    $script:LogFilePath = if ($EnableFileLogging.IsPresent) { $LogFilePath } else { $null }
    Set-LogSection -Section 'General'
    $script:ActiveProgressState = @{
        Overall   = $null
        Checkpoint = $null
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        [Alias("Component")]
        [string]$Activity = "Main",
        [string]$Section,
        [switch]$NoConsole,
        [switch]$NoFile,
        [hashtable]$StructuredData
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $sectionLabel = if ($PSBoundParameters.ContainsKey('Section')) {
        if ([string]::IsNullOrWhiteSpace($Section)) { 'General' } else { $Section.Trim() }
    } elseif ($script:CurrentSection) {
        $script:CurrentSection
    } else {
        'General'
    }

    $activityLabel = if ([string]::IsNullOrWhiteSpace($Activity)) { 'General' } else { $Activity }
    $header = "[$sectionLabel] [$activityLabel]"
    $logEntry = "[$timestamp] [$Level] $header $Message"

    $levelPriority = $script:LogLevels[$Level]
    $currentLevelPriority = $script:LogLevels[$script:LogLevel]
    $shouldOutput = $levelPriority -ge $currentLevelPriority

    if ($shouldOutput -and -not $NoConsole -and -not ($script:NonInteractiveMode -and $Level -in @("Debug", "Verbose"))) {
        if ($StructuredData) {
            $payload = @{
                timestamp = $timestamp
                level     = $Level
                section   = $sectionLabel
                activity  = $activityLabel
                message   = $Message
                data      = $StructuredData
            }
            $output = ($payload | ConvertTo-Json -Depth 6)
        } else {
            $output = "$header $Message"
        }

        switch ($Level) {
            "Debug"   { Write-Host $output -ForegroundColor DarkGray }
            "Verbose" { Write-Host $output -ForegroundColor Gray }
            "Info"    { Write-Host $output -ForegroundColor White }
            "Success" { Write-Host $output -ForegroundColor Green }
            "Warning" { Write-Host $output -ForegroundColor Yellow }
            "Error"   { Write-Host $output -ForegroundColor Red }
        }
    }

    if ($shouldOutput -and $script:FileLoggingEnabled -and $script:LogFilePath -and -not $NoFile) {
        if ($StructuredData) {
            $filePayload = @{
                timestamp = $timestamp
                level     = $Level
                section   = $sectionLabel
                activity  = $activityLabel
                message   = $Message
                data      = $StructuredData
            }
            $line = ($filePayload | ConvertTo-Json -Depth 6)
        } else {
            $line = $logEntry
        }

        Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
    }

    Update-ProgressDisplay
}

function Write-LogSection {
    param(
        [string]$Title,
        [string]$Symbol = "="
    )

    Set-LogSection -Section $Title
    $sectionLabel = if ([string]::IsNullOrWhiteSpace($Title)) { 'General' } else { $Title.Trim() }
    $separator = $Symbol * 70
    Write-Log -Message $separator -Level "Info" -Activity "SectionHeader" -Section $sectionLabel
    Write-Log -Message ("  {0}" -f $sectionLabel) -Level "Info" -Activity "SectionHeader" -Section $sectionLabel
    Write-Log -Message $separator -Level "Info" -Activity "SectionHeader" -Section $sectionLabel
}

function Write-LogProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete,
        [int]$Step,
        [int]$TotalSteps,
        [ValidateSet('Overall','Checkpoint')]
        [string]$Scope = 'Overall'
    )

    $activityLabel = if ([string]::IsNullOrWhiteSpace($Activity)) { 'Progress' } else { $Activity }
    $statusText = if ([string]::IsNullOrWhiteSpace($Status)) { 'In progress' } else { $Status }
    $percentValue = if ($null -eq $PercentComplete) { 0.0 } else { [double]$PercentComplete }
    $percentClamped = [math]::Min([math]::Max($percentValue, 0), 100)
    $percentString = "{0:0.##}" -f $percentClamped

    $stepText = if ($TotalSteps -gt 0) { "$Step/$TotalSteps" } else { "$Step" }
    $operationText = if ($TotalSteps -gt 0) { "Step $Step of $TotalSteps" } else { "Step $Step" }

    $overallState = @{
        Activity         = 'Overall Progress'
        Status           = "$activityLabel ($stepText)"
        Percent          = $percentClamped
        CurrentOperation = $operationText
    }

    $checkpointState = @{
        Activity         = $activityLabel
        Status           = $statusText
        Percent          = $percentClamped
        CurrentOperation = $operationText
    }

    if ($Scope -eq 'Overall') {
        $script:ActiveProgressState.Overall = $overallState
        if (-not $script:ActiveProgressState.Checkpoint) {
            $script:ActiveProgressState.Checkpoint = $checkpointState
        }
    } else {
        $script:ActiveProgressState.Checkpoint = $checkpointState
        if (-not $script:ActiveProgressState.Overall) {
            $script:ActiveProgressState.Overall = $overallState
        }
    }

    $progressMsg = "[{0}] [{1}] {2} - {3} ({4}%)" -f $stepText, $Scope, $activityLabel, $statusText, $percentString
    Write-Log -Message $progressMsg -Level "Info" -Activity "Progress" -Section "Progress"
}

Export-ModuleMember -Function Initialize-GitLabLogging,Write-Log,Write-LogSection,Write-LogProgress,Complete-GitLabProgress
