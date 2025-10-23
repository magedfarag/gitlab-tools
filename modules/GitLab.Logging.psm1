Set-StrictMode -Version Latest

$script:LogLevels = @{
    "Debug"   = 0
    "Verbose" = 1
    "Info"    = 2
    "Success" = 2
    "Warning" = 3
    "Error"   = 4
}

function Initialize-GitLabLogging {
    param(
        [ValidateSet("Minimal", "Normal", "Verbose", "Debug")]
        [string]$LogLevel = "Normal",
        [switch]$NonInteractive,
        [switch]$EnableFileLogging,
        [string]$LogFilePath
    )

    $script:LogLevel = $LogLevel
    $script:NonInteractiveMode = $NonInteractive.IsPresent
    $script:FileLoggingEnabled = $EnableFileLogging.IsPresent
    $script:LogFilePath = if ($EnableFileLogging.IsPresent) { $LogFilePath } else { $null }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        [string]$Component = "Main",
        [switch]$NoConsole,
        [switch]$NoFile,
        [hashtable]$StructuredData
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] [$Component] $Message"
    
    $levelPriority = $script:LogLevels[$Level]
    $currentLevelPriority = $script:LogLevels[$script:LogLevel]
    
    if ($levelPriority -lt $currentLevelPriority) { return }
    
    if (-not $NoConsole -and -not ($script:NonInteractiveMode -and $Level -in @("Debug", "Verbose"))) {
        $output = if ($StructuredData) {
            (@{
                timestamp = $timestamp
                level = $Level
                component = $Component
                message = $Message
                data = $StructuredData
            } | ConvertTo-Json -Depth 5)
        } else {
            $Message
        }

        switch ($Level) {
            "Debug" { Write-Host $output -ForegroundColor DarkGray }
            "Verbose" { Write-Host $output -ForegroundColor Gray }
            "Info" { Write-Host $output -ForegroundColor White }
            "Success" { Write-Host $output -ForegroundColor Green }
            "Warning" { Write-Host $output -ForegroundColor Yellow }
            "Error" { Write-Host $output -ForegroundColor Red }
        }
    }
    
    if ($script:FileLoggingEnabled -and $script:LogFilePath -and -not $NoFile) {
        $line = if ($StructuredData) {
            (@{
                timestamp = $timestamp
                level = $Level
                component = $Component
                message = $Message
                data = $StructuredData
            } | ConvertTo-Json -Depth 5)
        } else {
            $logEntry
        }

        Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
    }
}

function Write-LogSection {
    param(
        [string]$Title,
        [string]$Symbol = "="
    )
    
    $separator = $Symbol * 70
    Write-Log -Message $separator -Level "Info"
    Write-Log -Message "  $Title" -Level "Info"
    Write-Log -Message $separator -Level "Info"
}

function Write-LogProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete,
        [int]$Step,
        [int]$TotalSteps
    )
    
    $progressMsg = "[$Step/$TotalSteps] $Activity - $Status ($PercentComplete%)"
    Write-Log -Message $progressMsg -Level "Info" -Component "Progress"
    
    if (-not $script:NonInteractiveMode) {
        Write-Progress -Id 0 -Activity $Activity -Status $Status -PercentComplete $PercentComplete -CurrentOperation "Step $Step of $TotalSteps"
    }
}

Export-ModuleMember -Function Initialize-GitLabLogging,Write-Log,Write-LogSection,Write-LogProgress
