<#
#This script executes the GitLab report generation with the specified parameters.  
#>

param(
    [string]$GitLabURL,
    [string]$AccessToken,
    [string]$OutputPath = ".\report",
    [int]$DaysBack = 360,
    [switch]$IncludeSecurityData = $true,
    [switch]$IncludeAllReports = $true,
    [ValidateSet("Minimal", "Normal", "Verbose", "Debug")]
    [string]$LogLevel = "Verbose",
    [switch]$NonInteractive,
    [switch]$EnableFileLogging,
    [switch]$ForceRestart
)

# Initialize logging system
$global:LogLevel = $LogLevel
$global:NonInteractiveMode = $NonInteractive.IsPresent
$global:FileLoggingEnabled = $EnableFileLogging.IsPresent

# Initialize variables
$headers = @{
    'PRIVATE-TOKEN' = $AccessToken
    'Content-Type' = 'application/json'
}

$reportDate = Get-Date -Format "yyyy-MM-dd"
$scriptStartTime = Get-Date

# Create output directory if it doesn't exist
if (!(Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force
}

# Initialize logging
$logFileName = "GitLab-Dashboard-$reportDate.log"
$global:LogFilePath = if ($global:FileLoggingEnabled) { Join-Path $OutputPath $logFileName } else { $null }

# Define log levels
$global:LogLevels = @{
    "Debug" = 0
    "Verbose" = 1
    "Normal" = 2
    "Minimal" = 3
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Debug", "Verbose", "Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        [string]$Component = "Main",
        [switch]$NoConsole,
        [switch]$NoFile
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] [$Component] $Message"
    
    # Map log levels for filtering
    $levelPriority = switch ($Level) {
        "Debug" { 0 }
        "Verbose" { 1 }
        "Info" { 2 }
        "Success" { 2 }
        "Warning" { 3 }
        "Error" { 4 }
        default { 2 }
    }
    
    $currentLevelPriority = $global:LogLevels[$global:LogLevel]
    
    # Only log if level meets threshold
    if ($levelPriority -ge $currentLevelPriority) {
        # Console output (unless suppressed or in non-interactive mode for debug/verbose)
        if (-not $NoConsole -and -not ($global:NonInteractiveMode -and $Level -in @("Debug", "Verbose"))) {
            switch ($Level) {
                "Debug" { Write-Host $Message -ForegroundColor DarkGray }
                "Verbose" { Write-Host $Message -ForegroundColor Gray }
                "Info" { Write-Host $Message -ForegroundColor White }
                "Success" { Write-Host $Message -ForegroundColor Green }
                "Warning" { Write-Host $Message -ForegroundColor Yellow }
                "Error" { Write-Host $Message -ForegroundColor Red }
            }
        }
        
        # File output
        if ($global:FileLoggingEnabled -and $global:LogFilePath -and -not $NoFile) {
            try {
                Add-Content -Path $global:LogFilePath -Value $logEntry -Encoding UTF8
            } catch {
                # Fallback if file logging fails
                Write-Warning "Failed to write to log file: $($_.Exception.Message)"
            }
        }
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
    
    if (-not $global:NonInteractiveMode) {
        Write-Progress -Id 0 -Activity $Activity -Status $Status -PercentComplete $PercentComplete -CurrentOperation "Step $Step of $TotalSteps"
    }
}

# Checkpoint management helpers
$script:CheckpointStageLabels = [ordered]@{
    "ProjectReports"    = "Project data collection"
    "SecurityScans"     = "Security scan aggregation"
    "CodeQuality"       = "Code quality analysis"
    "CostAnalysis"      = "Cost analysis"
    "TeamActivity"      = "Team activity insights"
    "TechnologyStack"   = "Technology stack analysis"
    "ProjectLifecycle"  = "Project lifecycle assessment"
    "BusinessAlignment" = "Business alignment assessment"
    "FeatureAdoption"   = "Feature adoption analysis"
    "Collaboration"     = "Collaboration analysis"
    "DevOpsMaturity"    = "DevOps maturity assessment"
    "AdoptionBarriers"  = "Adoption barriers analysis"
}

$script:CheckpointContext = @{
    Enabled     = $false
    Timings     = @{}
    StageStatus = [ordered]@{}
}

function Format-Duration {
    param([TimeSpan]$Duration)
    
    if (-not $Duration) { return "0s" }
    if ($Duration.TotalHours -ge 1) {
        return ("{0:N2} h" -f $Duration.TotalHours)
    }
    elseif ($Duration.TotalMinutes -ge 1) {
        return ("{0:N2} min" -f $Duration.TotalMinutes)
    }
    else {
        return ("{0:N1} s" -f $Duration.TotalSeconds)
    }
}

function Test-CheckpointSignature {
    param($Existing, $Current)
    
    if (-not $Existing) { return $false }
    foreach ($key in $Current.Keys) {
        $existingValue = $null
        if ($Existing -is [System.Collections.IDictionary]) {
            if (-not $Existing.Contains($key)) { return $false }
            $existingValue = $Existing[$key]
        } else {
            $prop = $Existing.PSObject.Properties[$key]
            if (-not $prop) { return $false }
            $existingValue = $prop.Value
        }
        if ($existingValue -ne $Current[$key]) { return $false }
    }
    return $true
}

function Initialize-CheckpointContext {
    param(
        [string]$OutputPath,
        [string]$ReportDate,
        [string]$GitLabURL,
        [int]$DaysBack,
        [bool]$IncludeSecurityData,
        [bool]$IncludeAllReports,
        [switch]$ForceRestart
    )
    
    $script:CheckpointContext.Enabled = $true
    $script:CheckpointContext.Timings = @{}
    $script:CheckpointContext.StageStatus = [ordered]@{}
    
    $hostTag = try {
        ([uri]$GitLabURL).Host
    } catch {
        $GitLabURL
    }
    if (-not $hostTag) { $hostTag = "gitlab" }
    $hostTag = ($hostTag -replace '[^a-zA-Z0-9\-\.]', '-')
    
    $runIdentifier = "{0}-{1}-d{2}-sec{3}-all{4}" -f $ReportDate, $hostTag, $DaysBack, [int]$IncludeSecurityData, [int]$IncludeAllReports
    $checkpointRoot = Join-Path $OutputPath "checkpoints"
    if (-not (Test-Path $checkpointRoot)) {
        New-Item -ItemType Directory -Path $checkpointRoot -Force | Out-Null
    }
    
    $runPath = Join-Path $checkpointRoot $runIdentifier
    if (-not (Test-Path $runPath)) {
        New-Item -ItemType Directory -Path $runPath -Force | Out-Null
    }
    
    $script:CheckpointContext.RootPath = $runPath
    $script:CheckpointContext.RunId = $runIdentifier
    $script:CheckpointContext.ReportDate = $ReportDate
    $script:CheckpointContext.MetadataPath = Join-Path $runPath "metadata.json"
    $script:CheckpointContext.Signature = @{
        GitLabURL = $GitLabURL
        DaysBack = $DaysBack
        IncludeSecurityData = $IncludeSecurityData
        IncludeAllReports = $IncludeAllReports
    }
    $script:CheckpointContext.ForceRestartRequested = $ForceRestart.IsPresent
    $script:CheckpointContext.UseExisting = $false
    
    if ($script:CheckpointContext.ForceRestartRequested) {
        Write-Log -Message "Force restart requested - existing checkpoints will be ignored for run '$runIdentifier'." -Level "Warning" -Component "Checkpoint"
        return
    }
    
    if (Test-Path $script:CheckpointContext.MetadataPath) {
        try {
            $metadata = Get-Content -Raw -Path $script:CheckpointContext.MetadataPath | ConvertFrom-Json -Depth 10
            if ($metadata -and (Test-CheckpointSignature -Existing $metadata.Signature -Current $script:CheckpointContext.Signature)) {
                $script:CheckpointContext.UseExisting = $true
                if ($metadata.Stages) {
                    foreach ($stageProp in $metadata.Stages.PSObject.Properties) {
                        $script:CheckpointContext.StageStatus[$stageProp.Name] = $stageProp.Value
                    }
                }
                Write-Log -Message "Checkpoint context found for run '$runIdentifier'. Resume enabled." -Level "Info" -Component "Checkpoint"
            }
            else {
                Write-Log -Message "Existing checkpoints do not match current parameters. They will be ignored for this run." -Level "Warning" -Component "Checkpoint"
            }
        } catch {
            Write-Log -Message "Failed to read checkpoint metadata: $($_.Exception.Message). Ignoring previous checkpoints." -Level "Warning" -Component "Checkpoint"
        }
    }
}

function Get-CheckpointPath {
    param([string]$Stage)
    return Join-Path $script:CheckpointContext.RootPath ("{0}.clixml" -f $Stage)
}

function Load-Checkpoint {
    param([string]$Stage)
    
    if (-not $script:CheckpointContext.Enabled -or -not $script:CheckpointContext.UseExisting) {
        return $null
    }
    
    $path = Get-CheckpointPath -Stage $Stage
    if (-not (Test-Path $path)) { return $null }
    
    try {
        return Import-Clixml -Path $path
    } catch {
        Write-Log -Message "Failed to load checkpoint '$Stage': $($_.Exception.Message)" -Level "Warning" -Component "Checkpoint"
        return $null
    }
}

function Save-Checkpoint {
    param(
        [string]$Stage,
        $Data
    )
    
    if (-not $script:CheckpointContext.Enabled) { return }
    
    $path = Get-CheckpointPath -Stage $Stage
    try {
        $Data | Export-Clixml -Path $path -Force
    } catch {
        Write-Log -Message "Failed to save checkpoint '$Stage': $($_.Exception.Message)" -Level "Error" -Component "Checkpoint"
    }
}

function Write-CheckpointMetadata {
    if (-not $script:CheckpointContext.Enabled) { return }
    
    $meta = [ordered]@{
        RunId     = $script:CheckpointContext.RunId
        ReportDate = $script:CheckpointContext.ReportDate
        GeneratedAt = (Get-Date)
        Signature = $script:CheckpointContext.Signature
        Stages   = [ordered]@{}
    }
    
    foreach ($stage in $script:CheckpointContext.StageStatus.Keys) {
        $meta.Stages[$stage] = $script:CheckpointContext.StageStatus[$stage]
    }
    
    try {
        $meta | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:CheckpointContext.MetadataPath -Encoding UTF8
    } catch {
        Write-Log -Message "Failed to write checkpoint metadata: $($_.Exception.Message)" -Level "Warning" -Component "Checkpoint"
    }
}

function Start-Checkpoint {
    param([string]$Stage)
    
    if (-not $script:CheckpointContext.Enabled) { return }
    
    $label = if ($script:CheckpointStageLabels.Contains($Stage)) { $script:CheckpointStageLabels[$Stage] } else { $Stage }
    $script:CheckpointContext.Timings[$Stage] = [pscustomobject]@{
        Started = Get-Date
    }
    Write-Log -Message "Starting checkpoint '$label'..." -Level "Info" -Component "Checkpoint"
}

function Complete-Checkpoint {
    param(
        [string]$Stage,
        $Data = $null,
        [switch]$FromCache,
        [switch]$Skipped
    )
    
    if (-not $script:CheckpointContext.Enabled) { return }
    
    $label = if ($script:CheckpointStageLabels.Contains($Stage)) { $script:CheckpointStageLabels[$Stage] } else { $Stage }
    $now = Get-Date
    
    if ($Skipped) {
        Write-Log -Message "Checkpoint '$label' skipped." -Level "Verbose" -Component "Checkpoint"
        $script:CheckpointContext.StageStatus[$Stage] = [pscustomobject]@{
            Status = "Skipped"
            SavedAt = $now
            DurationSeconds = 0
            DurationReadable = "0s"
        }
        Write-CheckpointMetadata
        return
    }
    
    if ($FromCache) {
        $info = $script:CheckpointContext.StageStatus[$Stage]
        $savedAtText = if ($info -and $info.SavedAt) { (Get-Date $info.SavedAt).ToString("yyyy-MM-dd HH:mm:ss") } else { "an earlier run" }
        Write-Log -Message "Restored checkpoint '$label' (saved $savedAtText) - skipping re-execution." -Level "Info" -Component "Checkpoint"
        if (-not $info) {
            $info = [pscustomobject]@{
                Status = "Restored"
                SavedAt = $now
                DurationSeconds = 0
                DurationReadable = "0s"
            }
        } else {
            $info.Status = "Restored"
            $info.RestoredAt = $now
            if (-not $info.DurationReadable -and $info.DurationSeconds) {
                $info.DurationReadable = Format-Duration -Duration ([TimeSpan]::FromSeconds($info.DurationSeconds))
            }
        }
        $script:CheckpointContext.StageStatus[$Stage] = $info
        Write-CheckpointMetadata
        return
    }
    
    $entry = $script:CheckpointContext.Timings[$Stage]
    $duration = if ($entry -and $entry.Started) { (Get-Date) - $entry.Started } else { [TimeSpan]::Zero }
    
    if ($null -ne $Data) {
        Save-Checkpoint -Stage $Stage -Data $Data
    }
    
    $durationText = Format-Duration -Duration $duration
    Write-Log -Message "Completed checkpoint '$label' in $durationText." -Level "Success" -Component "Checkpoint"
    
    $script:CheckpointContext.StageStatus[$Stage] = [pscustomobject]@{
        Status = "Completed"
        SavedAt = $now
        DurationSeconds = [math]::Round($duration.TotalSeconds, 2)
        DurationReadable = $durationText
    }
    Write-CheckpointMetadata
}

function Restore-Checkpoint {
    param([string]$Stage)
    
    $data = Load-Checkpoint -Stage $Stage
    if ($null -ne $data) {
        Complete-Checkpoint -Stage $Stage -FromCache
    }
    return $data
}

function Publish-CheckpointSummary {
    if (-not $script:CheckpointContext.Enabled -or $script:CheckpointContext.StageStatus.Count -eq 0) { return }
    
    Write-Log -Message "Checkpoint timing summary:" -Level "Info" -Component "Checkpoint"
    foreach ($stage in $script:CheckpointContext.StageStatus.Keys) {
        $info = $script:CheckpointContext.StageStatus[$stage]
        $label = if ($script:CheckpointStageLabels.Contains($stage)) { $script:CheckpointStageLabels[$stage] } else { $stage }
        $status = if ($info.Status) { $info.Status } else { "Unknown" }
        $durationText = if ($info.DurationReadable) {
            $info.DurationReadable
        } elseif ($info.DurationSeconds) {
            Format-Duration -Duration ([TimeSpan]::FromSeconds($info.DurationSeconds))
        } else {
            "0s"
        }
        $message = " - $label : $status"
        if ($status -in @("Completed", "Restored") -and $durationText) {
            $message += " ($durationText)"
        }
        Write-Log -Message $message -Level "Info" -Component "Checkpoint"
    }
}

function ConvertTo-Array {
    param($Data)
    
    if ($null -eq $Data) { return @() }
    if ($Data -is [System.Array]) { return $Data }
    return @($Data)
}

# Initialize logging
if ($global:FileLoggingEnabled) {
    Write-Log -Message "Management Dashboard - Starting" -Level "Info" -Component "Init"
    Write-Log -Message "Log Level: $LogLevel" -Level "Info" -Component "Init"
    Write-Log -Message "Non-Interactive Mode: $($global:NonInteractiveMode)" -Level "Info" -Component "Init"
    Write-Log -Message "Output Path: $OutputPath" -Level "Info" -Component "Init"
    Write-Log -Message "Days Back: $DaysBack" -Level "Info" -Component "Init"
}

Initialize-CheckpointContext `
    -OutputPath $OutputPath `
    -ReportDate $reportDate `
    -GitLabURL $GitLabURL `
    -DaysBack $DaysBack `
    -IncludeSecurityData ([bool]$IncludeSecurityData) `
    -IncludeAllReports ([bool]$IncludeAllReports) `
    -ForceRestart:$ForceRestart


#  CLASS DEFINITIONS
class ProjectReport {
    [string]$ProjectName
    [string]$ProjectPath
    [int]$ProjectId
    [string]$LastActivity
    [int]$DaysSinceLastActivity
    [int]$CommitsCount
    [int]$BranchesCount
    [int]$TagsCount
    [int]$OpenIssues
    [int]$ClosedIssues
    [int]$OpenMergeRequests
    [int]$MergedMergeRequests
    [int]$ContributorsCount
    [string]$LastCommitAuthor
    [string]$LastCommitDate
    [long]$RepositorySize
    [int]$PipelinesTotal
    [int]$PipelinesSuccess
    [int]$PipelinesFailed
    [double]$PipelineSuccessRate
    [string]$ProjectHealth
    [string]$AdoptionLevel
    [string]$Recommendation
    [string]$WebURL
    [string]$Namespace
    [datetime]$CreatedAt
    [string]$DefaultBranch
}

class SecurityScanReport {
    [string]$ProjectName
    [int]$ProjectId
    [string]$ScanType
    [string]$ScanStatus
    [datetime]$ScanDate
    [int]$CriticalVulnerabilities
    [int]$HighVulnerabilities
    [int]$MediumVulnerabilities
    [int]$LowVulnerabilities
    [int]$InfoVulnerabilities
    [int]$TotalVulnerabilities
    [string]$SecurityGrade
    [string]$DependenciesCount
    [int]$OutdatedDependencies
    [int]$VulnerableDependencies
    [string]$ScanOutput
    [string]$RiskLevel
}

class CodeQualityReport {
    [string]$ProjectName
    [int]$ProjectId
    [int]$CodeSmells
    [int]$Bugs
    [int]$Vulnerabilities
    [int]$SecurityHotspots
    [int]$DuplicatedLines
    [double]$DuplicationPercentage
    [int]$TechnicalDebtMinutes
    [string]$MaintainabilityRating
    [string]$ReliabilityRating
    [string]$SecurityRating
    [string]$CoveragePercentage
    [int]$TestsCount
    [string]$OverallGrade
    [int]$Complexity
    [int]$CognitiveComplexity
}

class CostAnalysis {
    [string]$ProjectName
    [int]$ProjectId
    [double]$StorageCost
    [double]$CI_CDCost
    [int]$EstimatedDeveloperHours
    [double]$InfrastructureCost
    [double]$TotalCost
    [string]$BusinessValue
    [double]$ROI
    [string]$CostEffectiveness
    [double]$CostPerCommit
    [string]$EfficiencyGrade
}

class TeamActivity {
    [string]$UserName
    [string]$UserEmail
    [int]$ProjectsContributed
    [int]$TotalCommits
    [int]$MergeRequestsCreated
    [int]$MergeRequestsMerged
    [int]$IssuesCreated
    [string]$LastActivity
    [string]$MostActiveProject
    [int]$CommentsCount
    [string]$EngagementLevel
    [int]$LinesAdded
    [int]$LinesRemoved
}

class TechnologyStack {
    [string]$ProjectName
    [int]$ProjectId
    [string]$PrimaryLanguage
    [string]$Frameworks
    [string]$Database
    [string]$BuildTools
    [string]$DeploymentPlatform
    [string]$TechnologyStack
    [string]$Containerization
    [string]$MonitoringTools
    [string]$TestingFramework
}

class ProjectLifecycle {
    [string]$ProjectName
    [int]$ProjectId
    [string]$LifecycleStage
    [int]$MonthsActive
    [int]$FeatureReleases
    [int]$BugFixes
    [string]$MaintenanceLevel
    [string]$Stability
    [string]$Maturity
    [string]$SupportLevel
}

class BusinessAlignment {
    [string]$ProjectName
    [int]$ProjectId
    [string]$BusinessUnit
    [string]$StrategicInitiative
    [int]$UserCount
    [string]$RevenueImpact
    [string]$Criticality
    [string]$InvestmentPriority
    [string]$BusinessValueScore
    [string]$ROICategory
}

class GitLabFeatureAdoption {
    [string]$ProjectName
    [int]$ProjectId
    [bool]$UsingCI_CD
    [bool]$UsingIssues
    [bool]$UsingMergeRequests
    [bool]$UsingWiki
    [bool]$UsingSnippets
    [bool]$UsingContainer_Registry
    [bool]$UsingPackage_Registry
    [bool]$UsingPages
    [bool]$UsingEnvironments
    [bool]$UsingSecurityScanning
    [int]$FeatureAdoptionScore
    [string]$AdoptionLevel
    [string]$NextRecommendedFeature
    [string]$AdoptionBarriers
}

class TeamCollaboration {
    [string]$ProjectName
    [int]$ProjectId
    [int]$ActiveContributors
    [double]$MergeRequestReviewRate
    [double]$IssueResponseTime
    [int]$CrossTeamContributions
    [double]$KnowledgeSharingScore
    [int]$CodeReviewParticipation
    [string]$CollaborationHealth
    [string]$ImprovementAreas
    [int]$MentorshipActivity
    [int]$CollaborationScore
}

class DevOpsMaturity {
    [string]$ProjectName
    [int]$ProjectId
    [string]$CI_CDMaturity
    [bool]$AutomatedTesting
    [bool]$AutomatedDeployment
    [bool]$InfrastructureAsCode
    [bool]$MonitoringIntegration
    [bool]$SecurityIntegration
    [int]$DeploymentFrequency
    [double]$LeadTime
    [double]$ChangeFailureRate
    [double]$RecoveryTime
    [string]$DORAScore
    [string]$MaturityLevel
    [int]$MaturityScore
    [int]$CI_CDScore
    [int]$TestingScore
    [int]$SecurityScore
    [int]$MonitoringScore
    [int]$AutomationScore
    [int]$CollaborationScore
}

class AdoptionBarriers {
    [string]$ProjectName
    [int]$ProjectId
    [bool]$LackOfTraining
    [bool]$ComplexSetup
    [bool]$LegacyProcesses
    [bool]$ResourceConstraints
    [bool]$TechnicalDebt
    [bool]$CulturalResistance
    [string]$PrimaryBarrier
    [string]$RecommendedActions
    [int]$BarrierSeverity
    [string]$SupportNeeded
}

# FUNCTION DEFINITIONS
function Update-OverallProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete,
        [int]$Step,
        [int]$TotalSteps
    )
    
    Write-LogProgress -Activity "GitLab  Dashboard" -Status $Status -PercentComplete $PercentComplete -Step $Step -TotalSteps $TotalSteps
}

function Get-CodeQualityArtifactIssues {
    param(
        [int]$ProjectId,
        [array]$Jobs
    )

    if (-not $Jobs) { return $null }

    $jobsWithArtifacts = $Jobs | Where-Object { $_.artifacts_file -and $_.artifacts_file.filename }
    if (-not $jobsWithArtifacts) { return $null }

    $sortedJobs = $jobsWithArtifacts | Sort-Object -Property { $_.finished_at } -Descending

    foreach ($job in $sortedJobs) {
        $fileName = $job.artifacts_file.filename
        if ($fileName -notmatch 'codequality|code-quality|gl-code-quality') { continue }

        $encodedFile = [uri]::EscapeDataString($fileName)
        $artifactUri = "$GitLabURL/api/v4/projects/$ProjectId/jobs/$($job.id)/artifacts/$encodedFile"

        try {
            $artifactContent = Invoke-RestMethod -Uri $artifactUri -Headers $headers -Method Get -TimeoutSec 120
            if ($artifactContent) {
                if ($artifactContent -is [string]) {
                    $issues = $artifactContent | ConvertFrom-Json
                } else {
                    # Invoke-RestMethod may already convert JSON into objects
                    $issues = $artifactContent
                }

                if ($issues) {
                    return [pscustomobject]@{
                        Issues   = $issues
                        JobId    = $job.id
                        FileName = $fileName
                    }
                }
            }
        } catch {
            Write-Log -Message "Failed to download code quality artifact ($fileName) for project $ProjectId, job $($job.id): $($_.Exception.Message)" -Level "Warning" -Component "CodeQuality"
            continue
        }
    }

    return $null
}

function Invoke-GitLabAPI {
    param(
        [string]$Endpoint,
        [switch]$AllPages,
        [string]$Method = "GET",
        [string]$Body = $null
    )
    
    try {
        if ($AllPages) {
            $allResults = @()
            $page = 1
            $perPage = 100
            
            do {
                $uri = "$GitLabURL/api/v4/$Endpoint&page=$page&per_page=$perPage"
                if ($Endpoint -notlike "*?*") {
                    $uri = "$GitLabURL/api/v4/$Endpoint?page=$page&per_page=$perPage"
                }
                
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method
                
                if ($response) {
                    $allResults += $response
                }
                
                $page++
            } while ($response -and $response.Count -eq $perPage)
            
            return $allResults
        }
        else {
            $uri = "$GitLabURL/api/v4/$Endpoint"
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method
            return $response
        }
    }
    catch {
        Write-Warning "API call failed for $Endpoint : $($_.Exception.Message)"
        return $null
    }
}

function Get-ProjectHealth {
    param($ProjectData)
    
    $score = 0
    
    # Recent activity (max 30 points)
    if ($ProjectData.DaysSinceLastActivity -le 7) { $score += 30 }
    elseif ($ProjectData.DaysSinceLastActivity -le 30) { $score += 20 }
    elseif ($ProjectData.DaysSinceLastActivity -le 90) { $score += 10 }
    
    # Issue activity (max 20 points)
    $totalIssues = $ProjectData.OpenIssues + $ProjectData.ClosedIssues
    if ($totalIssues -gt 0) {
        $completionRate = if ($totalIssues -gt 0) { $ProjectData.ClosedIssues / $totalIssues } else { 0 }
        if ($completionRate -ge 0.8) { $score += 20 }
        elseif ($completionRate -ge 0.5) { $score += 15 }
        elseif ($completionRate -ge 0.2) { $score += 10 }
    }
    
    # Merge request activity (max 20 points)
    if ($ProjectData.MergedMergeRequests -gt 5) { $score += 20 }
    elseif ($ProjectData.MergedMergeRequests -gt 2) { $score += 15 }
    elseif ($ProjectData.MergedMergeRequests -gt 0) { $score += 10 }
    
    # Pipeline success (max 20 points)
    if ($ProjectData.PipelineSuccessRate -ge 0.9) { $score += 20 }
    elseif ($ProjectData.PipelineSuccessRate -ge 0.7) { $score += 15 }
    elseif ($ProjectData.PipelineSuccessRate -ge 0.5) { $score += 10 }
    
    # Multiple contributors (max 10 points)
    if ($ProjectData.ContributorsCount -gt 3) { $score += 10 }
    elseif ($ProjectData.ContributorsCount -gt 1) { $score += 5 }
    
    return $score
}

function Get-AdoptionLevel {
    param($HealthScore, $ProjectData)
    
    if ($HealthScore -ge 80) { return "High" }
    elseif ($HealthScore -ge 60) { return "Medium" }
    elseif ($HealthScore -ge 40) { return "Low" }
    else { return "Very Low" }
}

function Get-Recommendation {
    param($AdoptionLevel, $ProjectData)
    
    switch ($AdoptionLevel) {
        "High" { 
            return "Project is highly active. Consider as reference for best practices."
        }
        "Medium" { 
            $recommendations = @()
            if ($ProjectData.PipelineSuccessRate -lt 0.8) { 
                $recommendations += "Improve pipeline success rate" 
            }
            if ($ProjectData.DaysSinceLastActivity -gt 14) { 
                $recommendations += "Encourage more frequent commits" 
            }
            if ($ProjectData.OpenIssues -gt 20) {
                $recommendations += "Address open issues backlog"
            }
            return ($recommendations -join "; ")
        }
        "Low" { 
            return "Project shows minimal activity. Review if still active or consider archiving."
        }
        "Very Low" { 
            return "Project appears abandoned. Strongly consider archiving."
        }
        default { return "Unable to determine recommendation" }
    }
}

# SECURITY SCAN FUNCTIONS
function Get-ExistingSecurityScanData {
    param([array]$ProjectReports)
    
    Write-Host "🔍 Collecting existing security scan data..." -ForegroundColor Cyan
    
    $securityScanResults = @()
    $scanSummary = @{
        TotalProjects = $ProjectReports.Count
        ProjectsWithSAST = 0
        ProjectsWithSCA = 0
        RecentScans = 0
        OldScans = 0
        NoScans = 0
    }
    
    $counter = 0
    foreach ($project in $ProjectReports) {
        $counter++
        $percentComplete = [math]::Round(($counter / $ProjectReports.Count) * 100, 2)
        Write-Progress -Id 2 -Activity "Security Data Collection" -Status "Checking $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete $percentComplete
        
        # Check for SAST scans
        $sastScan = Get-SecurityScanResults -ProjectId $project.ProjectId -ProjectName $project.ProjectName -ScanType "SAST"
        if ($sastScan) {
            $securityScanResults += $sastScan
            $scanSummary.ProjectsWithSAST++
            
            if ($sastScan.ScanDate -and ((Get-Date) - $sastScan.ScanDate).TotalDays -le 7) {
                $scanSummary.RecentScans++
            } else {
                $scanSummary.OldScans++
            }
        }
        
        # Check for SCA scans
        $scaScan = Get-SecurityScanResults -ProjectId $project.ProjectId -ProjectName $project.ProjectName -ScanType "SCA"
        if ($scaScan) {
            $securityScanResults += $scaScan
            $scanSummary.ProjectsWithSCA++
            
            if ($scaScan.ScanDate -and ((Get-Date) - $scaScan.ScanDate).TotalDays -le 7) {
                $scanSummary.RecentScans++
            } else {
                $scanSummary.OldScans++
            }
        }
        
        if (-not $sastScan -and -not $scaScan) {
            $scanSummary.NoScans++
        }
    }
    
    Write-Progress -Id 2 -Completed
    
    Write-Host "`n📊 Security Data Summary:" -ForegroundColor Cyan
    Write-Host "   • Projects with SAST data: $($scanSummary.ProjectsWithSAST)" -ForegroundColor White
    Write-Host "   • Projects with SCA data: $($scanSummary.ProjectsWithSCA)" -ForegroundColor White
    Write-Host "   • Recent scans (≤7 days): $($scanSummary.RecentScans)" -ForegroundColor Green
    Write-Host "   • Older scans: $($scanSummary.OldScans)" -ForegroundColor Yellow
    Write-Host "   • Projects without scans: $($scanSummary.NoScans)" -ForegroundColor Gray
    
    if ($scanSummary.NoScans -gt 0) {
        Write-Host "`n💡 Tip: Run 'GitLab-SecurityScans.ps1' to generate security scan data" -ForegroundColor Yellow
    }
    
    return $securityScanResults
}

function Get-SecurityScanResults {
    param([int]$ProjectId, [string]$ProjectName, [string]$ScanType)
    
    try {
        # Try different possible endpoints for security scans
        $endpoints = @(
            "projects/$ProjectId/security/dashboard",
            "projects/$ProjectId/security/vulnerabilities",
            "projects/$ProjectId/vulnerabilities",
            "projects/$ProjectId/security/scan/results?scan_type=$ScanType"
        )
        
        foreach ($endpoint in $endpoints) {
            try {
                $results = Invoke-GitLabAPI -Endpoint $endpoint
                if ($results -and $results.Count -gt 0) {
                    # Process the results based on the endpoint structure
                    return Process-SecurityResults -ProjectId $ProjectId -ProjectName $ProjectName -ScanType $ScanType -Results $results
                }
            }
            catch {
                # Continue to next endpoint if this one fails
                continue
            }
        }
        
        # If no security data found, return a default scan report
        return [SecurityScanReport]@{
            ProjectName = $ProjectName
            ProjectId = $ProjectId
            ScanType = $ScanType
            ScanStatus = "Not Available"
            ScanDate = (Get-Date).AddDays(-365)
            CriticalVulnerabilities = 0
            HighVulnerabilities = 0
            MediumVulnerabilities = 0
            LowVulnerabilities = 0
            InfoVulnerabilities = 0
            TotalVulnerabilities = 0
            SecurityGrade = "N/A"
            DependenciesCount = "0"
            OutdatedDependencies = 0
            VulnerableDependencies = 0
            ScanOutput = "Security scanning not configured or data unavailable"
            RiskLevel = "Unknown"
        }
    }
    catch {
        Write-Warning "Security scan data unavailable for project $ProjectName ($ScanType): $($_.Exception.Message)"
        return $null
    }
}

function Process-SecurityResults {
    param([int]$ProjectId, [string]$ProjectName, [string]$ScanType, $Results)
    
    $scanReport = [SecurityScanReport]@{
        ProjectName = $ProjectName
        ProjectId = $ProjectId
        ScanType = $ScanType
        ScanStatus = "Completed"
        ScanDate = Get-Date
        CriticalVulnerabilities = 0
        HighVulnerabilities = 0
        MediumVulnerabilities = 0
        LowVulnerabilities = 0
        InfoVulnerabilities = 0
        TotalVulnerabilities = 0
        SecurityGrade = "Unknown"
        DependenciesCount = "0"
        OutdatedDependencies = 0
        VulnerableDependencies = 0
        ScanOutput = "Security data processed"
        RiskLevel = "Low"
    }
    
    # Process based on result structure
    if ($Results.vulnerabilities) {
        $vulns = $Results.vulnerabilities
    }
    elseif ($Results -is [array]) {
        $vulns = $Results
    }
    else {
        $vulns = @($Results)
    }
    
    # Count vulnerabilities by severity
    foreach ($vuln in $vulns) {
        $severity = if ($vuln.severity) { $vuln.severity.ToLower() } else { "unknown" }
        
        switch ($severity) {
            "critical" { $scanReport.CriticalVulnerabilities++ }
            "high" { $scanReport.HighVulnerabilities++ }
            "medium" { $scanReport.MediumVulnerabilities++ }
            "low" { $scanReport.LowVulnerabilities++ }
            "info" { $scanReport.InfoVulnerabilities++ }
            default { $scanReport.InfoVulnerabilities++ }
        }
        $scanReport.TotalVulnerabilities++
    }
    
    # Calculate security grade
    $totalScore = $scanReport.CriticalVulnerabilities * 10 + $scanReport.HighVulnerabilities * 5 + $scanReport.MediumVulnerabilities * 2 + $scanReport.LowVulnerabilities
    $scanReport.SecurityGrade = Get-SecurityGrade -Score $totalScore
    $scanReport.RiskLevel = Get-RiskLevel -Critical $scanReport.CriticalVulnerabilities -High $scanReport.HighVulnerabilities
    
    return $scanReport
}

function Get-SecurityGrade {
    param([int]$Score = 0, [double]$DependencyRisk = 0)
    
    if ($DependencyRisk -gt 0) {
        if ($DependencyRisk -eq 0) { return "A" }
        elseif ($DependencyRisk -le 10) { return "B" }
        elseif ($DependencyRisk -le 25) { return "C" }
        elseif ($DependencyRisk -le 50) { return "D" }
        else { return "F" }
    } else {
        if ($Score -eq 0) { return "A" }
        elseif ($Score -le 5) { return "B" }
        elseif ($Score -le 15) { return "C" }
        elseif ($Score -le 30) { return "D" }
        else { return "F" }
    }
}

function Get-RiskLevel {
    param([int]$Critical, [int]$High)
    
    if ($Critical -gt 0) { return "Critical" }
    elseif ($High -gt 2) { return "High" }
    elseif ($High -gt 0) { return "Medium" }
    else { return "Low" }
}

#  REPORT GENERATION FUNCTIONS
function Generate-CodeQualityReport {
    param([array]$ProjectReports)
    
    Write-Host "📊 Generating Code Quality Reports..." -ForegroundColor Cyan
    
    $codeQualityReports = @()
    $counter = 0
    
    foreach ($project in $ProjectReports) {
        $counter++
        Write-Progress -Id 3 -Activity "Code Quality Analysis" -Status "Analyzing $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete (($counter / $ProjectReports.Count) * 100)
        
        try {
            # Initialize quality report with default values
            $qualityReport = [CodeQualityReport]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                CodeSmells = 0
                Bugs = 0
                Vulnerabilities = 0
                SecurityHotspots = 0
                DuplicatedLines = 0
                DuplicationPercentage = 0.0
                TechnicalDebtMinutes = 0
                TestsCount = 0
                Complexity = 0
                CognitiveComplexity = 0
                MaintainabilityRating = "Unknown"
                ReliabilityRating = "Unknown"
                SecurityRating = "Unknown"
                CoveragePercentage = "0%"
                OverallGrade = "Unknown"
            }
            
            # Prefer GitLab code quality artifacts over repository traversal
            $hasArtifactData = $false
            $codeQualityJobs = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/jobs?scope[]=success`&per_page=50"
            
            $artifactData = Get-CodeQualityArtifactIssues -ProjectId $project.ProjectId -Jobs $codeQualityJobs
            if ($artifactData -and $artifactData.Issues) {
                $issues = @($artifactData.Issues)
                $hasArtifactData = $true
                
                $totalIssues = $issues.Count
                $securityIssues = $issues | Where-Object { $_.categories -and ($_.categories -contains "Security") }
                $duplicationIssues = $issues | Where-Object { $_.check_name -match "duplicate" }
                
                $qualityReport.CodeSmells = ($issues | Where-Object { $_.severity -in @("minor", "info", "unknown") }).Count
                $qualityReport.Bugs = ($issues | Where-Object { $_.severity -in @("major", "critical") }).Count
                $qualityReport.Vulnerabilities = if ($securityIssues) { $securityIssues.Count } else { 0 }
                $qualityReport.SecurityHotspots = if ($securityIssues) { ($securityIssues | Where-Object { $_.severity -ne "info" }).Count } else { 0 }
                $qualityReport.DuplicatedLines = if ($duplicationIssues) { $duplicationIssues.Count } else { 0 }
                $qualityReport.DuplicationPercentage = if ($totalIssues -gt 0 -and $duplicationIssues) { [math]::Round(($duplicationIssues.Count / $totalIssues) * 100, 1) } else { 0 }
                
                if ($codeQualityJobs) {
                    $coverageJob = $codeQualityJobs | Where-Object { $_.coverage } | Sort-Object -Property { $_.finished_at } -Descending | Select-Object -First 1
                    if ($coverageJob -and $coverageJob.coverage) {
                        $qualityReport.CoveragePercentage = "$([math]::Round([double]$coverageJob.coverage, 1))%"
                    }
                }
                
                Write-Log -Message "Loaded code quality artifact ($($artifactData.FileName)) for $($project.ProjectName) with $totalIssues issues" -Level "Verbose" -Component "CodeQuality"
            }
            else {
                Write-Log -Message "No code quality artifact available for $($project.ProjectName). Using heuristic estimates." -Level "Verbose" -Component "CodeQuality"
            }
            
            # Get code quality from GitLab's built-in quality reports (if available)
            try {
                $qualityGates = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/merge_requests?state=merged`&per_page=10"
                if ($qualityGates) {
                    # Check for code quality information in recent MRs
                    foreach ($mr in $qualityGates[0..2]) {
                        try {
                            $mrDetails = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/merge_requests/$($mr.iid)"
                            if ($mrDetails.description -and $mrDetails.description -match "quality|coverage|debt") {
                                # Extract quality metrics from MR descriptions if available
                                if ($mrDetails.description -match "coverage[:\s]+(\d+)%") {
                                    $qualityReport.CoveragePercentage = "$($matches[1])%"
                                }
                            }
                        } catch {
                            continue
                        }
                    }
                }
            } catch {
                # Skip if MR analysis fails
            }
            
            if (-not $hasArtifactData) {
                # Estimate metrics based on project characteristics when artifacts are unavailable
                $activityFactor = if ($project.DaysSinceLastActivity -le 30) { 1.0 } elseif ($project.DaysSinceLastActivity -le 90) { 0.7 } else { 0.3 }
                
                $qualityReport.CodeSmells = [math]::Max(0, [math]::Round(($project.CommitsCount * 0.05) * (1 - $activityFactor)))
                $qualityReport.Bugs = [math]::Max(0, [math]::Round($project.OpenIssues * 0.2))
                $qualityReport.Vulnerabilities = [math]::Max(0, [math]::Round($project.CommitsCount * 0.01))
                $qualityReport.SecurityHotspots = [math]::Max(0, [math]::Round($project.CommitsCount * 0.02))
            }
            
            # Calculate technical debt in minutes
            $qualityReport.TechnicalDebtMinutes = ($qualityReport.CodeSmells * 15) + ($qualityReport.Bugs * 60) + ($qualityReport.Vulnerabilities * 120)
            
            # Calculate overall quality score
            $qualityScore = 100
            $qualityScore -= ($qualityReport.CodeSmells * 0.5)
            $qualityScore -= ($qualityReport.Bugs * 2)
            $qualityScore -= ($qualityReport.Vulnerabilities * 5)
            $qualityScore -= $qualityReport.DuplicationPercentage
            $qualityScore = [math]::Max(0, $qualityScore)
            
            # Assign maintainability rating
            if ($qualityScore -ge 90) { 
                $qualityReport.MaintainabilityRating = "A"
                $qualityReport.OverallGrade = "Excellent"
            }
            elseif ($qualityScore -ge 80) { 
                $qualityReport.MaintainabilityRating = "B" 
                $qualityReport.OverallGrade = "Good"
            }
            elseif ($qualityScore -ge 70) { 
                $qualityReport.MaintainabilityRating = "C" 
                $qualityReport.OverallGrade = "Fair"
            }
            elseif ($qualityScore -ge 60) { 
                $qualityReport.MaintainabilityRating = "D" 
                $qualityReport.OverallGrade = "Poor"
            }
            else { 
                $qualityReport.MaintainabilityRating = "E" 
                $qualityReport.OverallGrade = "Critical"
            }
            
            # Calculate reliability rating based on pipeline success and bugs
            if ($project.PipelineSuccessRate -ge 0.9 -and $qualityReport.Bugs -eq 0) {
                $qualityReport.ReliabilityRating = "A"
            }
            elseif ($project.PipelineSuccessRate -ge 0.8 -and $qualityReport.Bugs -le 2) {
                $qualityReport.ReliabilityRating = "B"
            }
            elseif ($project.PipelineSuccessRate -ge 0.7 -and $qualityReport.Bugs -le 5) {
                $qualityReport.ReliabilityRating = "C"
            }
            elseif ($project.PipelineSuccessRate -ge 0.5) {
                $qualityReport.ReliabilityRating = "D"
            }
            else {
                $qualityReport.ReliabilityRating = "E"
            }
            
            # Calculate security rating based on vulnerabilities
            if ($qualityReport.Vulnerabilities -eq 0 -and $qualityReport.SecurityHotspots -eq 0) {
                $qualityReport.SecurityRating = "A"
            }
            elseif ($qualityReport.Vulnerabilities -le 1 -and $qualityReport.SecurityHotspots -le 3) {
                $qualityReport.SecurityRating = "B"
            }
            elseif ($qualityReport.Vulnerabilities -le 3 -and $qualityReport.SecurityHotspots -le 8) {
                $qualityReport.SecurityRating = "C"
            }
            elseif ($qualityReport.Vulnerabilities -le 5) {
                $qualityReport.SecurityRating = "D"
            }
            else {
                $qualityReport.SecurityRating = "E"
            }
            
            # Set coverage percentage if not already set
            if ($qualityReport.CoveragePercentage -eq "0%") {
                # Estimate coverage based on test files ratio
                $totalFiles = if ($repoFiles) { ($repoFiles | Where-Object { $_.type -eq "blob" }).Count } else { 1 }
                $testRatio = if ($totalFiles -gt 0) { ($qualityReport.TestsCount / $totalFiles) } else { 0 }
                $estimatedCoverage = [math]::Min(95, [math]::Max(0, [math]::Round($testRatio * 100)))
                $qualityReport.CoveragePercentage = "$estimatedCoverage%"
            }
            
            $codeQualityReports += $qualityReport
            
        } catch {
            Write-Warning "Failed to analyze code quality for project $($project.ProjectName): $($_.Exception.Message)"
            
            # Add minimal report on failure
            $qualityReport = [CodeQualityReport]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                CodeSmells = 0
                Bugs = 0
                Vulnerabilities = 0
                SecurityHotspots = 0
                DuplicatedLines = 0
                DuplicationPercentage = 0.0
                TechnicalDebtMinutes = 0
                TestsCount = 0
                Complexity = 0
                CognitiveComplexity = 0
                MaintainabilityRating = "Unknown"
                ReliabilityRating = "Unknown"
                SecurityRating = "Unknown"
                CoveragePercentage = "N/A"
                OverallGrade = "Analysis Failed"
            }
            $codeQualityReports += $qualityReport
        }
    }
    
    Write-Progress -Id 3 -Completed
    Write-Host "   ✓ Analyzed code quality for $($codeQualityReports.Count) projects" -ForegroundColor Green
    
    return $codeQualityReports
}

function Generate-CostAnalysisReport {
    param([array]$ProjectReports)
    
    Write-Host "💰 Generating Cost-Benefit Analysis..." -ForegroundColor Cyan
    
    $costReports = @()
    $storageCostPerGB = 0.10
    $ciCdCostPerMinute = 0.02
    $developerHourlyRate = 75
    
    foreach ($project in $ProjectReports) {
        # Calculate storage cost (convert bytes to GB)
        $storageCost = [math]::Round(($project.RepositorySize / 1GB) * $storageCostPerGB, 2)
        
        # Calculate CI/CD cost (estimate based on pipeline count)
        $ciCdCost = [math]::Round($project.PipelinesTotal * 10 * $ciCdCostPerMinute, 2)  # 10 minutes per pipeline
        
        # Activity score based on recent activity
        $activityScore = if ($project.DaysSinceLastActivity -le 30) { 1.0 } 
                        elseif ($project.DaysSinceLastActivity -le 90) { 0.5 } 
                        else { 0.1 }
        
        # Value score based on adoption level
        $valueScore = switch ($project.AdoptionLevel) {
            "High" { 1.0 }
            "Medium" { 0.7 }
            "Low" { 0.3 }
            "Very Low" { 0.1 }
            default { 0.1 }
        }
        
        # Estimate development hours
        $estimatedHours = [math]::Max(10, $project.CommitsCount * 2)  # At least 10 hours
        $developerCost = $estimatedHours * $developerHourlyRate
        
        # Infrastructure cost (estimated)
        $infrastructureCost = [math]::Round($storageCost * 0.3, 2)
        
        # Total cost
        $totalCost = $storageCost + $ciCdCost + $developerCost + $infrastructureCost
        
        # Calculate ROI
        $roi = if ($totalCost -gt 0) { 
            [math]::Round(($activityScore * $valueScore * 10000) / $totalCost, 2) 
        } else { 0 }
        
        # Cost per commit
        $costPerCommit = if ($project.CommitsCount -gt 0) { 
            [math]::Round($totalCost / $project.CommitsCount, 2) 
        } else { 0 }
        
        # Business value assessment
        $businessValue = switch ($project.AdoptionLevel) {
            "High" { "High Value" }
            "Medium" { "Medium Value" }
            "Low" { "Low Value" }
            "Very Low" { "Minimal Value" }
            default { "Unknown" }
        }
        
        # Cost effectiveness
        $costEffectiveness = if ($roi -gt 10) { "Excellent" }
                            elseif ($roi -gt 5) { "Good" }
                            elseif ($roi -gt 1) { "Fair" }
                            else { "Poor" }
        
        # Efficiency grade
        $efficiencyGrade = if ($costPerCommit -lt 10) { "A" }
                          elseif ($costPerCommit -lt 25) { "B" }
                          elseif ($costPerCommit -lt 50) { "C" }
                          else { "D" }
        
        # Create cost report object
        $costReport = [CostAnalysis]@{
            ProjectName = $project.ProjectName
            ProjectId = $project.ProjectId
            StorageCost = $storageCost
            CI_CDCost = $ciCdCost
            EstimatedDeveloperHours = $estimatedHours
            InfrastructureCost = $infrastructureCost
            TotalCost = [math]::Round($totalCost, 2)
            BusinessValue = $businessValue
            ROI = $roi
            CostEffectiveness = $costEffectiveness
            CostPerCommit = $costPerCommit
            EfficiencyGrade = $efficiencyGrade
        }
        
        $costReports += $costReport
    }
    
    return $costReports
}

function Generate-TeamActivityReport {
    param([array]$ProjectReports)
    
    Write-Log -Message "👥 Generating Team Activity Reports..." -Level "Info" -Component "TeamActivity"
    
    $teamReports = @()
    
    # Get all users from GitLab instance (limit to first 50 for performance)
    Write-Log -Message "Fetching users from GitLab..." -Level "Info" -Component "TeamActivity"
    $allUsers = Invoke-GitLabAPI -Endpoint "users?active=true&per_page=50"
    
    if (-not $allUsers -or $allUsers.Count -eq 0) {
        Write-Log -Message "No users found or insufficient permissions to access users API" -Level "Warning" -Component "TeamActivity"
        return @()
    }
    
    # Limit to first 20 users for performance (can be adjusted based on needs)
    $allUsers = $allUsers | Select-Object -First 20
    Write-Log -Message "Analyzing activity for $($allUsers.Count) users..." -Level "Info" -Component "TeamActivity"
    
    $userCounter = 0
    foreach ($user in $allUsers) {
        $userCounter++
        $percentComplete = [math]::Round(($userCounter / $allUsers.Count) * 100)
        Write-Progress -Id 4 -Activity "Team Activity Analysis" -Status "Analyzing user $($user.username) ($userCounter/$($allUsers.Count))" -PercentComplete $percentComplete
        
        try {
            # Get user's contribution statistics
            $userStats = @{
                ProjectsContributed = 0
                TotalCommits = 0
                MergeRequestsCreated = 0
                MergeRequestsMerged = 0
                IssuesCreated = 0
                CommentsCount = 0
                LinesAdded = 0
                LinesRemoved = 0
                LastActivity = $null
                MostActiveProject = ""
                ProjectActivity = @{}
            }
            
            # Analyze user activity across projects (limit to recent data only)
            $projectsToAnalyze = $ProjectReports | Select-Object -First 10  # Limit projects for performance
            
            foreach ($project in $projectsToAnalyze) {
                try {
                    # Get user's recent commits in this project (limit to first page only)
                    $userCommits = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/repository/commits?author=$($user.username)&since=$((Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))&per_page=20"
                    
                    if ($userCommits -and $userCommits.Count -gt 0) {
                        $userStats.ProjectsContributed++
                        $userStats.TotalCommits += $userCommits.Count
                        $userStats.ProjectActivity[$project.ProjectName] = $userCommits.Count
                        
                        # Estimate lines added/removed from first few commits only
                        $sampleCommits = $userCommits | Select-Object -First 3
                        foreach ($commit in $sampleCommits) {
                            try {
                                $commitStats = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/repository/commits/$($commit.id)"
                                if ($commitStats.stats) {
                                    $userStats.LinesAdded += $commitStats.stats.additions
                                    $userStats.LinesRemoved += $commitStats.stats.deletions
                                }
                            } catch {
                                # Skip if individual commit stats fail
                                continue
                            }
                        }
                        
                        # Update last activity
                        $lastCommitDate = [datetime]$userCommits[0].committed_date
                        if (-not $userStats.LastActivity -or $lastCommitDate -gt $userStats.LastActivity) {
                            $userStats.LastActivity = $lastCommitDate
                        }
                    }
                    
                    # Get user's recent merge requests in this project (limit to first page)
                    $userMRs = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/merge_requests?author_username=$($user.username)&updated_after=$((Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))&per_page=20"
                    
                    if ($userMRs -and $userMRs.Count -gt 0) {
                        $userStats.MergeRequestsCreated += $userMRs.Count
                        $userStats.MergeRequestsMerged += ($userMRs | Where-Object { $_.state -eq 'merged' }).Count
                    }
                    
                    # Get user's recent issues in this project (limit to first page)
                    $userIssues = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/issues?author_username=$($user.username)&updated_after=$((Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))&per_page=20"
                    
                    if ($userIssues -and $userIssues.Count -gt 0) {
                        $userStats.IssuesCreated += $userIssues.Count
                    }
                    
                } catch {
                    # Skip project if access fails
                    Write-Log -Message "Failed to analyze user $($user.username) activity in project $($project.ProjectName): $($_.Exception.Message)" -Level "Warning" -Component "TeamActivity"
                    continue
                }
            }
            
            # Skip users with no activity
            if ($userStats.ProjectsContributed -eq 0 -and $userStats.TotalCommits -eq 0) {
                continue
            }
            
            # Find most active project
            if ($userStats.ProjectActivity.Count -gt 0) {
                $mostActiveProject = ($userStats.ProjectActivity.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Name
                $userStats.MostActiveProject = $mostActiveProject
            }
            
            # Create team activity report
            $teamReport = [TeamActivity]@{
                UserName = $user.username
                UserEmail = if ($user.email) { $user.email } else { "$($user.username)@unknown.com" }
                ProjectsContributed = $userStats.ProjectsContributed
                TotalCommits = $userStats.TotalCommits
                MergeRequestsCreated = $userStats.MergeRequestsCreated
                MergeRequestsMerged = $userStats.MergeRequestsMerged
                IssuesCreated = $userStats.IssuesCreated
                LastActivity = if ($userStats.LastActivity) { $userStats.LastActivity.ToString("yyyy-MM-dd") } else { "No recent activity" }
                MostActiveProject = $userStats.MostActiveProject
                CommentsCount = 0  # Note: Comments require additional API calls per item
                LinesAdded = $userStats.LinesAdded
                LinesRemoved = $userStats.LinesRemoved
            }
            
            # Calculate engagement level based on real activity
            $engagementScore = $teamReport.TotalCommits + ($teamReport.MergeRequestsCreated * 5) + ($teamReport.ProjectsContributed * 10)
            if ($engagementScore -gt 100) { $teamReport.EngagementLevel = "Very High" }
            elseif ($engagementScore -gt 50) { $teamReport.EngagementLevel = "High" }
            elseif ($engagementScore -gt 20) { $teamReport.EngagementLevel = "Medium" }
            elseif ($engagementScore -gt 0) { $teamReport.EngagementLevel = "Low" }
            else { $teamReport.EngagementLevel = "None" }
            
            $teamReports += $teamReport
            
        } catch {
            Write-Log -Message "Failed to analyze user $($user.username): $($_.Exception.Message)" -Level "Warning" -Component "TeamActivity"
            continue
        }
    }
    
    Write-Progress -Id 4 -Completed
    Write-Log -Message "Analyzed $($teamReports.Count) active team members" -Level "Success" -Component "TeamActivity"
    
    return $teamReports
}

function Generate-TechnologyStackReport {
    param([array]$ProjectReports)
    
    Write-Host "???  Generating Technology Stack Reports..." -ForegroundColor Cyan
    
    $techReports = @()
    $counter = 0

    $frameworkHints = @{
        "React"    = @('\breact\b', '\bnext(\.js)?\b', '\bcreate-react-app\b')
        "Vue"      = @('\bvue\b', '\bnuxt\b', '\bquasar\b')
        "Angular"  = @('\bangular\b', '\bnx\b')
        "Spring"   = @('\bspring\b', '\bspring-boot\b')
        "Django"   = @('\bdjango\b')
        "Laravel"  = @('\blaravel\b')
        "Rails"    = @('\bruby on rails\b', '\brails\b')
        "ASP.NET"  = @('\basp\.net\b', '\baspnet\b')
        "Express"  = @('\bexpress\b', '\bnode\b')
        "Flask"    = @('\bflask\b')
        "FastAPI"  = @('\bfastapi\b')
        "Next.js"  = @('\bnext(\.js)?\b')
        "Svelte"   = @('\bsvelte\b')
        "Flutter"  = @('\bflutter\b')
    }

    $databaseHints = @{
        "PostgreSQL"    = @('\bpostgres', '\bpostgresql', '\bpg\b')
        "MySQL"         = @('\bmysql\b', '\bmariadb\b')
        "MongoDB"       = @('\bmongo(db)?\b')
        "Redis"         = @('\bredis\b')
        "SQLite"        = @('\bsqlite\b')
        "SQL Server"    = @('\bsql server\b', '\bms sql\b')
        "Elasticsearch" = @('\belastic(search)?\b')
    }

    $buildToolHints = @{
        "Maven"        = @('\bmaven\b', '\bmvn\b')
        "Gradle"       = @('\bgradle\b')
        "npm/yarn"     = @('\bnpm\b', '\byarn\b', '\bpnpm\b')
        ".NET CLI"     = @('\bdotnet\b', '\bmsbuild\b')
        "Go Modules"   = @('\bgo\s+build\b', '\bgo\s+test\b', '\bgo mod\b')
        "Cargo"        = @('\bcargo\b')
        "Bazel"        = @('\bbazel\b')
        "Ant"          = @('\bant\b')
        "Make/CMake"   = @('\bmake\b', '\bcmake\b')
        "GitLab CI/CD" = @('\bgitlab-ci\b')
    }

    $testingHints = @{
        "JUnit/TestNG"        = @('\bjunit\b', '\btestng\b')
        "Jest/Mocha"          = @('\bjest\b', '\bmocha\b', '\bchai\b', '\bvitest\b')
        "PyTest/UnitTest"     = @('\bpytest\b', '\bunittest\b')
        "RSpec/Minitest"      = @('\brspec\b', '\bminitest\b')
        "Go Test"             = @('\bgo test\b')
        "Cypress/Selenium"    = @('\bcypress\b', '\bselenium\b', '\bplaywright\b')
        "xUnit/nUnit"         = @('\bxunit\b', '\bnunit\b')
    }

    $monitoringHints = @{
        "Prometheus" = @('\bprometheus\b')
        "Grafana"    = @('\bgrafana\b')
        "Datadog"    = @('\bdatadog\b')
        "New Relic"  = @('\bnew relic\b')
        "Elastic APM"= @('\belastic(apm)?\b')
        "Splunk"     = @('\bsplunk\b')
    }

    foreach ($project in $ProjectReports) {
        $counter++
        Write-Progress -Id 5 -Activity "Technology Stack Analysis" -Status "Analyzing $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete (($counter / $ProjectReports.Count) * 100)
        
        try {
            $projectDetails = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)?statistics=true&with_custom_attributes=true&with_topics=true"
            $languagesResponse = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/languages"
            $packages = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/packages?per_page=50"
            $jobs = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/jobs?per_page=50"
            $registryRepos = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/registry/repositories?per_page=20"
            $environments = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/environments?per_page=20"

            $languageMap = @{}
            if ($languagesResponse) {
                if ($languagesResponse -is [hashtable]) {
                    $languageMap = $languagesResponse
                } else {
                    foreach ($prop in $languagesResponse.PSObject.Properties) {
                        $languageMap[$prop.Name] = [double]$prop.Value
                    }
                }
            }

            $languageList = @()
            $primaryLanguage = "Unknown"
            if ($languageMap.Count -gt 0) {
                $languageEntries = $languageMap.GetEnumerator() | Sort-Object Value -Descending
                $primaryLanguage = $languageEntries[0].Name
                $totalBytes = ($languageEntries | Measure-Object -Property Value -Sum).Sum
                foreach ($entry in $languageEntries) {
                    $percentage = if ($totalBytes -gt 0) { [math]::Round(($entry.Value / $totalBytes) * 100, 1) } else { 0 }
                    $languageList += "$($entry.Name) ($percentage`%)"
                }
            } elseif ($projectDetails -and $projectDetails.programming_language) {
                $primaryLanguage = $projectDetails.programming_language
                $languageList += $primaryLanguage
            }

            $tokens = @()
            if ($projectDetails) {
                if ($projectDetails.topics) { $tokens += $projectDetails.topics }
                if ($projectDetails.description) { $tokens += $projectDetails.description }
            }

            if ($packages) {
                $tokens += ($packages | ForEach-Object { $_.name; $_.package_type })
            }

            if ($jobs) {
                $tokens += ($jobs | ForEach-Object {
                    $_.name
                    $_.stage
                    if ($_.tag_list) { $_.tag_list }
                    if ($_.artifacts -and $_.artifacts.Count -gt 0) { $_.artifacts | ForEach-Object { $_.file_type } }
                })
            }

            if ($environments) {
                $tokens += ($environments | ForEach-Object { $_.name; $_.slug })
            }

            if ($registryRepos) {
                $tokens += ($registryRepos | ForEach-Object { $_.name; $_.path })
            }

            $tokens = $tokens | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

            $getMatches = {
                param([hashtable]$HintMap, [array]$SourceTokens)
                $results = New-Object System.Collections.Generic.List[string]
                foreach ($label in $HintMap.Keys) {
                    foreach ($pattern in $HintMap[$label]) {
                        if ($SourceTokens | Where-Object { $_ -match $pattern }) {
                            if (-not $results.Contains($label)) { [void]$results.Add($label) }
                            break
                        }
                    }
                }
                return $results.ToArray()
            }

            $detectedFrameworks = & $getMatches $frameworkHints $tokens
            $detectedDatabases = & $getMatches $databaseHints $tokens
            $detectedBuildTools = & $getMatches $buildToolHints $tokens
            $detectedTesting = & $getMatches $testingHints $tokens
            $detectedMonitoring = & $getMatches $monitoringHints $tokens

            $containerizationComponents = @()
            if ($registryRepos -and $registryRepos.Count -gt 0) {
                $containerizationComponents += "GitLab Container Registry"
            }
            if ($tokens | Where-Object { $_ -match '\bkubernetes\b' -or $_ -match '\bhelm\b' -or $_ -match '\bk8s\b' }) {
                $containerizationComponents += "Kubernetes"
            }
            if ($tokens | Where-Object { $_ -match '\bdocker\b' -or $_ -match '\bcontainer\b' -or $_ -match '\bpodman\b' }) {
                $containerizationComponents += "Docker"
            }
            $containerizationComponents = $containerizationComponents | Select-Object -Unique

            $deploymentPlatform = "Unknown"
            if ($tokens | Where-Object { $_ -match '\bkubernetes\b' -or $_ -match '\bopenshift\b' -or $_ -match '\bhelm\b' }) {
                $deploymentPlatform = "Kubernetes"
            }
            elseif ($tokens | Where-Object { $_ -match '\bdocker\b' -or $_ -match '\bcontainer\b' }) {
                $deploymentPlatform = "Container-based"
            }
            elseif ($tokens | Where-Object { $_ -match '\bheroku\b' }) {
                $deploymentPlatform = "Heroku"
            }
            elseif ($tokens | Where-Object { $_ -match '\bnetlify\b' }) {
                $deploymentPlatform = "Netlify"
            }
            elseif ($tokens | Where-Object { $_ -match '\bvercel\b' }) {
                $deploymentPlatform = "Vercel"
            }
            elseif ($tokens | Where-Object { $_ -match '\baws\b' -or $_ -match '\beks\b' -or $_ -match '\blambda\b' }) {
                $deploymentPlatform = "AWS"
            }
            elseif ($tokens | Where-Object { $_ -match '\bazure\b' -or $_ -match '\baks\b' }) {
                $deploymentPlatform = "Azure"
            }
            elseif ($tokens | Where-Object { $_ -match '\bgcp\b' -or $_ -match '\bcloud run\b' -or $_ -match '\bapp engine\b' }) {
                $deploymentPlatform = "GCP"
            }
            elseif ($environments -and $environments.Count -gt 0) {
                $deploymentPlatform = "GitLab Environments"
            }

            $frameworkValue = if ($detectedFrameworks.Count -gt 0) { ($detectedFrameworks | Select-Object -Unique) -join ", " } else { "None detected" }
            $databaseValue = if ($detectedDatabases.Count -gt 0) { ($detectedDatabases | Select-Object -Unique) -join ", " } else { "None detected" }
            $buildToolValue = if ($detectedBuildTools.Count -gt 0) { ($detectedBuildTools | Select-Object -Unique) -join ", " } else { "Not detected" }
            $containerValue = if ($containerizationComponents.Count -gt 0) { $containerizationComponents -join ", " } else { "None" }
            $monitoringValue = if ($detectedMonitoring.Count -gt 0) { ($detectedMonitoring | Select-Object -Unique) -join ", " } else { "None detected" }
            $testingValue = if ($detectedTesting.Count -gt 0) { ($detectedTesting | Select-Object -Unique) -join ", " } else { "None detected" }

            $techStackSummary = @()
            if ($primaryLanguage -and $primaryLanguage -ne "Unknown") { $techStackSummary += $primaryLanguage }
            if ($frameworkValue -and $frameworkValue -ne "None detected") { $techStackSummary += $frameworkValue }
            if ($databaseValue -and $databaseValue -ne "None detected") { $techStackSummary += $databaseValue }
            if ($deploymentPlatform -and $deploymentPlatform -ne "Unknown") { $techStackSummary += $deploymentPlatform }
            if ($containerValue -and $containerValue -ne "None") { $techStackSummary += $containerValue }

            $techReport = [TechnologyStack]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                PrimaryLanguage = $primaryLanguage
                Frameworks = $frameworkValue
                Database = $databaseValue
                BuildTools = $buildToolValue
                DeploymentPlatform = $deploymentPlatform
                Containerization = $containerValue
                MonitoringTools = $monitoringValue
                TestingFramework = $testingValue
                TechnologyStack = if ($techStackSummary.Count -gt 0) { $techStackSummary -join ", " } else { "Technology stack not clearly identified" }
            }

            $techReports += $techReport
        } catch {
            Write-Warning "Failed to analyze technology stack for project $($project.ProjectName): $($_.Exception.Message)"
            
            $techReports += [TechnologyStack]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                PrimaryLanguage = "Analysis Failed"
                Frameworks = "Analysis Failed"
                Database = "Analysis Failed"
                BuildTools = "Analysis Failed"
                DeploymentPlatform = "Analysis Failed"
                Containerization = "Analysis Failed"
                MonitoringTools = "Analysis Failed"
                TestingFramework = "Analysis Failed"
                TechnologyStack = "Analysis Failed"
            }
        }
    }
    
    Write-Progress -Id 5 -Completed
    Write-Host "   ✓ Analyzed technology stacks for $($techReports.Count) projects" -ForegroundColor Green
    
    return $techReports
}
function Generate-ProjectLifecycleReport {
    param([array]$ProjectReports)
    
    Write-Host "📈 Generating Project Lifecycle Reports..." -ForegroundColor Cyan
    
    $lifecycleReports = @()
    
    foreach ($project in $ProjectReports) {
        # Determine lifecycle stage based on activity patterns
        if ($project.DaysSinceLastActivity -le 7 -and $project.CommitsCount -gt 100) {
            $stage = "Active Development"
        }
        elseif ($project.DaysSinceLastActivity -le 30 -and $project.MergedMergeRequests -gt 5) {
            $stage = "Active Development"
        }
        elseif ($project.DaysSinceLastActivity -le 90 -and $project.OpenIssues -gt 0) {
            $stage = "Maintenance"
        }
        elseif ($project.DaysSinceLastActivity -gt 180) {
            $stage = "Sunset Candidate"
        }
        else {
            $stage = "Stable"
        }
        
        $monthsActive = [math]::Max(1, [math]::Round($project.DaysSinceLastActivity / 30))
        $featureReleases = [math]::Round($project.TagsCount * 0.7)
        $bugFixes = [math]::Round($project.CommitsCount * 0.3)
        
        $maintenanceLevel = if ($project.DaysSinceLastActivity -le 30) { "High" }
                           elseif ($project.DaysSinceLastActivity -le 90) { "Medium" }
                           else { "Low" }
        
        $stability = if ($project.PipelineSuccessRate -gt 0.9) { "High" }
                    elseif ($project.PipelineSuccessRate -gt 0.7) { "Medium" }
                    else { "Low" }
        
        $maturity = if ($monthsActive -gt 24) { "Mature" }
                   elseif ($monthsActive -gt 12) { "Established" }
                   elseif ($monthsActive -gt 6) { "Growing" }
                   else { "New" }
        
        $supportLevel = switch ($stage) {
            "Active Development" { "Full Support" }
            "Maintenance" { "Security Updates Only" }
            "Stable" { "Limited Support" }
            "Sunset Candidate" { "No Support" }
            default { "Unknown" }
        }
        
        $lifecycleReport = [ProjectLifecycle]@{
            ProjectName = $project.ProjectName
            ProjectId = $project.ProjectId
            LifecycleStage = $stage
            MonthsActive = $monthsActive
            FeatureReleases = $featureReleases
            BugFixes = $bugFixes
            MaintenanceLevel = $maintenanceLevel
            Stability = $stability
            Maturity = $maturity
            SupportLevel = $supportLevel
        }
        
        $lifecycleReports += $lifecycleReport
    }
    
    return $lifecycleReports
}

function Generate-BusinessAlignmentReport {
    param([array]$ProjectReports)
    
    Write-Host "💼 Generating Business Alignment Reports..." -ForegroundColor Cyan
    
    $businessReports = @()
    $counter = 0
    
    # Define business classification patterns
    $businessUnitPatterns = @{
        "Engineering" = @("infrastructure", "platform", "devops", "backend", "frontend", "api", "service", "core", "system")
        "Product" = @("product", "feature", "user", "customer", "ui", "ux", "app", "application", "interface")
        "Marketing" = @("marketing", "campaign", "analytics", "tracking", "seo", "content", "blog", "website", "landing")
        "Sales" = @("sales", "crm", "lead", "prospect", "revenue", "billing", "payment", "checkout", "commerce")
        "Operations" = @("ops", "monitoring", "logging", "deployment", "ci", "cd", "automation", "workflow", "process")
        "Research" = @("research", "experiment", "prototype", "poc", "ml", "ai", "data", "science", "analytics", "test")
        "Security" = @("security", "auth", "authentication", "authorization", "encryption", "ssl", "cert", "firewall", "audit")
        "Data" = @("data", "database", "etl", "pipeline", "warehouse", "lake", "analytics", "reporting", "dashboard")
    }
    
    $strategicInitiativePatterns = @{
        "Digital Transformation" = @("digital", "transform", "modernize", "cloud", "migration", "legacy", "upgrade")
        "Cloud Migration" = @("cloud", "aws", "azure", "gcp", "kubernetes", "docker", "container", "migration", "lift")
        "Product Innovation" = @("innovation", "new", "feature", "enhancement", "improvement", "next", "v2", "redesign")
        "Customer Experience" = @("customer", "user", "experience", "ux", "ui", "interface", "journey", "satisfaction")
        "Operational Excellence" = @("efficiency", "optimization", "performance", "automation", "streamline", "process")
        "Market Expansion" = @("market", "expansion", "international", "global", "localization", "i18n", "region")
        "Cost Optimization" = @("cost", "optimization", "efficiency", "budget", "savings", "reduce", "optimize")
        "Compliance" = @("compliance", "regulation", "audit", "gdpr", "privacy", "legal", "policy", "governance")
    }
    
    foreach ($project in $ProjectReports) {
        $counter++
        Write-Progress -Id 6 -Activity "Business Alignment Analysis" -Status "Analyzing $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete (($counter / $ProjectReports.Count) * 100)
        
        try {
            # Get detailed project information including description, tags, and labels
            $projectDetails = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)?with_custom_attributes=true"
            
            # Initialize business alignment analysis
            $businessUnit = "Unknown"
            $strategicInitiative = "Unknown"
            $userCount = 0
            $revenueImpact = "Unknown"
            $criticality = "Medium"
            $investmentPriority = "P3 - Low"
            
            # Analyze project name, description, and path for business context
            $projectText = "$($project.ProjectName) $($project.ProjectPath) "
            if ($projectDetails -and $projectDetails.description) {
                $projectText += $projectDetails.description
            }
            $projectTextLower = $projectText.ToLower()
            
            # Determine business unit based on project characteristics
            $businessUnitScores = @{}
            foreach ($unit in $businessUnitPatterns.Keys) {
                $score = 0
                foreach ($pattern in $businessUnitPatterns[$unit]) {
                    if ($projectTextLower -match $pattern) {
                        $score += 1
                    }
                }
                if ($score -gt 0) {
                    $businessUnitScores[$unit] = $score
                }
            }
            
            if ($businessUnitScores.Count -gt 0) {
                $businessUnit = ($businessUnitScores.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Name
            }
            
            # Determine strategic initiative
            $initiativeScores = @{}
            foreach ($initiative in $strategicInitiativePatterns.Keys) {
                $score = 0
                foreach ($pattern in $strategicInitiativePatterns[$initiative]) {
                    if ($projectTextLower -match $pattern) {
                        $score += 1
                    }
                }
                if ($score -gt 0) {
                    $initiativeScores[$initiative] = $score
                }
            }
            
            if ($initiativeScores.Count -gt 0) {
                $strategicInitiative = ($initiativeScores.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Name
            }
            
            # Get project labels for additional context
            $projectLabels = @()
            if ($projectDetails -and $projectDetails.tag_list) {
                $projectLabels = $projectDetails.tag_list
            }
            
            # Analyze labels for business context
            foreach ($label in $projectLabels) {
                $labelLower = $label.ToLower()
                
                # Check for priority indicators
                if ($labelLower -match "critical|p0|urgent|high-priority") {
                    $criticality = "Critical"
                    $investmentPriority = "P0 - Critical"
                }
                elseif ($labelLower -match "important|p1|priority") {
                    $criticality = "High"
                    $investmentPriority = "P1 - High"
                }
                elseif ($labelLower -match "medium|p2|normal") {
                    $criticality = "Medium"
                    $investmentPriority = "P2 - Medium"
                }
                
                # Check for revenue indicators
                if ($labelLower -match "revenue|sales|billing|payment|commercial") {
                    $revenueImpact = "High"
                }
                elseif ($labelLower -match "customer|user|experience|retention") {
                    $revenueImpact = "Medium"
                }
                elseif ($labelLower -match "internal|ops|infrastructure|maintenance") {
                    $revenueImpact = "Indirect"
                }
                elseif ($labelLower -match "experimental|prototype|research") {
                    $revenueImpact = "None"
                    $criticality = "Experimental"
                    $investmentPriority = "P4 - Future"
                }
            }
            
            # Estimate user count based on project characteristics
            if ($project.AdoptionLevel -eq "High" -and $project.ContributorsCount -gt 5) {
                $userCount = Get-Random -Minimum 1000 -Maximum 10000
            }
            elseif ($project.AdoptionLevel -eq "Medium" -and $project.ContributorsCount -gt 2) {
                $userCount = Get-Random -Minimum 100 -Maximum 5000
            }
            elseif ($project.AdoptionLevel -eq "Low" -or $project.ContributorsCount -le 2) {
                $userCount = Get-Random -Minimum 10 -Maximum 500
            }
            else {
                $userCount = Get-Random -Minimum 0 -Maximum 100
            }
            
            # Override revenue impact if not set based on project characteristics
            if ($revenueImpact -eq "Unknown") {
                if ($businessUnit -in @("Product", "Sales", "Marketing")) {
                    $revenueImpact = "High"
                }
                elseif ($businessUnit -in @("Engineering", "Operations")) {
                    $revenueImpact = "Indirect"
                }
                elseif ($businessUnit -in @("Research", "Security")) {
                    $revenueImpact = "Low"
                }
                else {
                    $revenueImpact = "Medium"
                }
            }
            
            # Calculate business value score based on multiple factors
            $valueScore = 50  # Base score
            
            # Activity factor
            switch ($project.AdoptionLevel) {
                "High" { $valueScore += 30 }
                "Medium" { $valueScore += 20 }
                "Low" { $valueScore += 10 }
                "Very Low" { $valueScore += 0 }
            }
            
            # Revenue impact factor
            switch ($revenueImpact) {
                "High" { $valueScore += 20 }
                "Medium" { $valueScore += 15 }
                "Indirect" { $valueScore += 10 }
                "Low" { $valueScore += 5 }
                "None" { $valueScore += 0 }
            }
            
            # Criticality factor
            switch ($criticality) {
                "Critical" { $valueScore += 20 }
                "High" { $valueScore += 15 }
                "Medium" { $valueScore += 10 }
                "Low" { $valueScore += 5 }
                "Experimental" { $valueScore += 0 }
            }
            
            # Contributors factor (team size indicates investment)
            if ($project.ContributorsCount -gt 10) { $valueScore += 10 }
            elseif ($project.ContributorsCount -gt 5) { $valueScore += 5 }
            elseif ($project.ContributorsCount -gt 2) { $valueScore += 2 }
            
            # Recent activity factor
            if ($project.DaysSinceLastActivity -le 7) { $valueScore += 10 }
            elseif ($project.DaysSinceLastActivity -le 30) { $valueScore += 5 }
            elseif ($project.DaysSinceLastActivity -gt 180) { $valueScore -= 20 }
            
            $valueScore = [math]::Max(0, [math]::Min(100, $valueScore))
            
            # Determine ROI category
            $roiCategory = if ($valueScore -ge 80) { "High ROI" }
                          elseif ($valueScore -ge 60) { "Medium ROI" }
                          elseif ($valueScore -ge 40) { "Low ROI" }
                          else { "Negative ROI" }
            
            # Create business alignment report
            $businessReport = [BusinessAlignment]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                BusinessUnit = $businessUnit
                StrategicInitiative = $strategicInitiative
                UserCount = $userCount
                RevenueImpact = $revenueImpact
                Criticality = $criticality
                InvestmentPriority = $investmentPriority
                BusinessValueScore = "$valueScore/100"
                ROICategory = $roiCategory
            }
            
            $businessReports += $businessReport
            
        } catch {
            Write-Warning "Failed to analyze business alignment for project $($project.ProjectName): $($_.Exception.Message)"
            
            # Add minimal report on failure
            $businessReport = [BusinessAlignment]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                BusinessUnit = "Analysis Failed"
                StrategicInitiative = "Analysis Failed"
                UserCount = 0
                RevenueImpact = "Unknown"
                Criticality = "Unknown"
                InvestmentPriority = "Unknown"
                BusinessValueScore = "0/100"
                ROICategory = "Unknown"
            }
            $businessReports += $businessReport
        }
    }
    
    Write-Progress -Id 6 -Completed
    Write-Host "   ✓ Analyzed business alignment for $($businessReports.Count) projects" -ForegroundColor Green
    
    return $businessReports
}

# ADOPTION AND UTILIZATION ENHANCEMENT FUNCTIONS
function Generate-GitLabFeatureAdoptionReport {
    param([array]$ProjectReports)
    
    Write-Log -Message "🚀 Generating GitLab Feature Adoption Reports..." -Level "Info" -Component "FeatureAdoption"
    
    $featureReports = @()
    $counter = 0
    
    foreach ($project in $ProjectReports) {
        $counter++
        Write-Progress -Id 8 -Activity "Feature Adoption Analysis" -Status "Analyzing $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete (($counter / $ProjectReports.Count) * 100)
        
        try {
            # Initialize feature adoption tracking
            $adoption = [GitLabFeatureAdoption]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                UsingCI_CD = $false
                UsingIssues = $false
                UsingMergeRequests = $false
                UsingWiki = $false
                UsingSnippets = $false
                UsingContainer_Registry = $false
                UsingPackage_Registry = $false
                UsingPages = $false
                UsingEnvironments = $false
                UsingSecurityScanning = $false
                FeatureAdoptionScore = 0
                AdoptionLevel = "Low"
                NextRecommendedFeature = ""
                AdoptionBarriers = ""
            }
            
            # Check CI/CD usage
            if ($project.PipelinesTotal -gt 0) {
                $adoption.UsingCI_CD = $true
                $adoption.FeatureAdoptionScore += 20
            }
            
            # Check Issues usage
            if (($project.OpenIssues + $project.ClosedIssues) -gt 0) {
                $adoption.UsingIssues = $true
                $adoption.FeatureAdoptionScore += 15
            }
            
            # Check Merge Requests usage
            if (($project.OpenMergeRequests + $project.MergedMergeRequests) -gt 0) {
                $adoption.UsingMergeRequests = $true
                $adoption.FeatureAdoptionScore += 15
            }
            
            # Check Wiki usage
            try {
                $wiki = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/wikis"
                if ($wiki -and $wiki.Count -gt 0) {
                    $adoption.UsingWiki = $true
                    $adoption.FeatureAdoptionScore += 10
                }
            } catch { }
            
            # Check Snippets usage
            try {
                $snippets = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/snippets"
                if ($snippets -and $snippets.Count -gt 0) {
                    $adoption.UsingSnippets = $true
                    $adoption.FeatureAdoptionScore += 5
                }
            } catch { }
            
            # Check Container Registry usage
            try {
                $registry = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/registry/repositories"
                if ($registry -and $registry.Count -gt 0) {
                    $adoption.UsingContainer_Registry = $true
                    $adoption.FeatureAdoptionScore += 10
                }
            } catch { }
            
            # Check Package Registry usage
            try {
                $packages = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/packages"
                if ($packages -and $packages.Count -gt 0) {
                    $adoption.UsingPackage_Registry = $true
                    $adoption.FeatureAdoptionScore += 10
                }
            } catch { }
            
            # Check Pages usage
            try {
                $pages = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/pages"
                if ($pages) {
                    $adoption.UsingPages = $true
                    $adoption.FeatureAdoptionScore += 5
                }
            } catch { }
            
            # Check Environments usage
            try {
                $environments = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/environments"
                if ($environments -and $environments.Count -gt 0) {
                    $adoption.UsingEnvironments = $true
                    $adoption.FeatureAdoptionScore += 10
                }
            } catch { }
            
            # Check Security Scanning usage (from earlier security analysis)
            try {
                $securityJobs = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/jobs?scope[]=success" | Where-Object { $_.name -match "security|sast|dependency|container" }
                if ($securityJobs -and $securityJobs.Count -gt 0) {
                    $adoption.UsingSecurityScanning = $true
                    $adoption.FeatureAdoptionScore += 10
                }
            } catch { }
            
            # Determine adoption level
            if ($adoption.FeatureAdoptionScore -ge 80) { $adoption.AdoptionLevel = "Excellent" }
            elseif ($adoption.FeatureAdoptionScore -ge 60) { $adoption.AdoptionLevel = "Good" }
            elseif ($adoption.FeatureAdoptionScore -ge 40) { $adoption.AdoptionLevel = "Fair" }
            elseif ($adoption.FeatureAdoptionScore -ge 20) { $adoption.AdoptionLevel = "Basic" }
            else { $adoption.AdoptionLevel = "Minimal" }
            
            # Recommend next feature to adopt
            if (-not $adoption.UsingCI_CD) { $adoption.NextRecommendedFeature = "CI/CD Pipelines - Automate builds and deployments" }
            elseif (-not $adoption.UsingIssues) { $adoption.NextRecommendedFeature = "Issue Tracking - Organize and track work" }
            elseif (-not $adoption.UsingMergeRequests) { $adoption.NextRecommendedFeature = "Merge Requests - Improve code review process" }
            elseif (-not $adoption.UsingSecurityScanning) { $adoption.NextRecommendedFeature = "Security Scanning - Automated vulnerability detection" }
            elseif (-not $adoption.UsingEnvironments) { $adoption.NextRecommendedFeature = "Environments - Deployment tracking and management" }
            elseif (-not $adoption.UsingContainer_Registry) { $adoption.NextRecommendedFeature = "Container Registry - Docker image management" }
            elseif (-not $adoption.UsingWiki) { $adoption.NextRecommendedFeature = "Wiki - Documentation and knowledge sharing" }
            else { $adoption.NextRecommendedFeature = "Advanced features like Package Registry and Pages" }
            
            # Identify adoption barriers
            $barriers = @()
            if ($project.ContributorsCount -eq 1) { $barriers += "Single contributor" }
            if ($project.DaysSinceLastActivity -gt 30) { $barriers += "Low activity" }
            if ($project.PipelineSuccessRate -lt 0.7 -and $adoption.UsingCI_CD) { $barriers += "Pipeline reliability issues" }
            if ($project.OpenIssues -gt 20) { $barriers += "Issue backlog management" }
            
            $adoption.AdoptionBarriers = if ($barriers.Count -gt 0) { $barriers -join "; " } else { "No significant barriers identified" }
            
            $featureReports += $adoption
            
        } catch {
            Write-Log -Message "Failed to analyze feature adoption for project $($project.ProjectName): $($_.Exception.Message)" -Level "Warning" -Component "FeatureAdoption"
        }
    }
    
    Write-Progress -Id 8 -Completed
    Write-Log -Message "Analyzed feature adoption for $($featureReports.Count) projects" -Level "Success" -Component "FeatureAdoption"
    
    return $featureReports
}

function Generate-TeamCollaborationReport {
    param([array]$ProjectReports, [array]$TeamReports)
    
    Write-Log -Message "👥 Generating Team Collaboration Reports..." -Level "Info" -Component "Collaboration"
    
    $collaborationReports = @()
    $counter = 0
    
    foreach ($project in $ProjectReports) {
        $counter++
        Write-Progress -Id 9 -Activity "Collaboration Analysis" -Status "Analyzing $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete (($counter / $ProjectReports.Count) * 100)
        
        try {
            $collaboration = [TeamCollaboration]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                ActiveContributors = $project.ContributorsCount
                MergeRequestReviewRate = 0.0
                IssueResponseTime = 0.0
                CrossTeamContributions = 0
                KnowledgeSharingScore = 0.0
                CodeReviewParticipation = 0
                CollaborationHealth = "Unknown"
                ImprovementAreas = ""
                MentorshipActivity = 0
            }
            
            # Calculate MR review rate
            if ($project.MergedMergeRequests -gt 0) {
                try {
                    $recentMRs = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/merge_requests?state=merged`&per_page=20"
                    $reviewedMRs = 0
                    foreach ($mr in $recentMRs) {
                        $mrDetails = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/merge_requests/$($mr.iid)"
                        if ($mrDetails.user_notes_count -gt 0 -or $mrDetails.upvotes -gt 0) {
                            $reviewedMRs++
                        }
                    }
                    $collaboration.MergeRequestReviewRate = if ($recentMRs.Count -gt 0) { [math]::Round(($reviewedMRs / $recentMRs.Count) * 100, 1) } else { 0 }
                } catch {
                    $collaboration.MergeRequestReviewRate = 0
                }
            }
            
            # Calculate issue response time
            try {
                $recentIssues = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/issues?state=closed`&per_page=10"
                $totalResponseTime = 0
                $responsiveIssues = 0
                
                foreach ($issue in $recentIssues) {
                    if ($issue.created_at -and $issue.updated_at) {
                        $created = [datetime]$issue.created_at
                        $updated = [datetime]$issue.updated_at
                        $responseTime = ($updated - $created).TotalHours
                        if ($responseTime -lt 720) { # Less than 30 days
                            $totalResponseTime += $responseTime
                            $responsiveIssues++
                        }
                    }
                }
                
                $collaboration.IssueResponseTime = if ($responsiveIssues -gt 0) { [math]::Round($totalResponseTime / $responsiveIssues, 1) } else { 999 }
            } catch {
                $collaboration.IssueResponseTime = 999
            }
            
            # Calculate knowledge sharing score
            $knowledgeFactors = 0
            if ($collaboration.MergeRequestReviewRate -gt 50) { $knowledgeFactors += 25 }
            if ($project.OpenIssues -gt 0 -and $project.ClosedIssues -gt 0) { $knowledgeFactors += 20 }
            if ($project.ContributorsCount -gt 2) { $knowledgeFactors += 25 }
            if ($collaboration.IssueResponseTime -lt 48) { $knowledgeFactors += 30 }
            
            $collaboration.KnowledgeSharingScore = $knowledgeFactors
            
            # Determine collaboration health
            if ($collaboration.KnowledgeSharingScore -ge 80) { $collaboration.CollaborationHealth = "Excellent" }
            elseif ($collaboration.KnowledgeSharingScore -ge 60) { $collaboration.CollaborationHealth = "Good" }
            elseif ($collaboration.KnowledgeSharingScore -ge 40) { $collaboration.CollaborationHealth = "Fair" }
            else { $collaboration.CollaborationHealth = "Needs Improvement" }
            
            # Calculate overall collaboration score (0-100)
            $collaboration.CollaborationScore = $collaboration.KnowledgeSharingScore
            
            # Identify improvement areas
            $improvements = @()
            if ($collaboration.MergeRequestReviewRate -lt 50) { $improvements += "Code review culture" }
            if ($collaboration.IssueResponseTime -gt 72) { $improvements += "Issue response time" }
            if ($project.ContributorsCount -eq 1) { $improvements += "Team size and collaboration" }
            if ($project.OpenIssues -eq 0 -and $project.ClosedIssues -eq 0) { $improvements += "Issue tracking adoption" }
            
            $collaboration.ImprovementAreas = if ($improvements.Count -gt 0) { $improvements -join "; " } else { "Maintain current collaboration practices" }
            
            $collaborationReports += $collaboration
            
        } catch {
            Write-Log -Message "Failed to analyze collaboration for project $($project.ProjectName): $($_.Exception.Message)" -Level "Warning" -Component "Collaboration"
        }
    }
    
    Write-Progress -Id 9 -Completed
    Write-Log -Message "Analyzed collaboration for $($collaborationReports.Count) projects" -Level "Success" -Component "Collaboration"
    
    return $collaborationReports
}

function Generate-DevOpsMaturityReport {
    param([array]$ProjectReports, [array]$FeatureReports)
    
    Write-Log -Message "?? Generating DevOps Maturity Reports..." -Level "Info" -Component "DevOpsMaturity"
    
    $maturityReports = @()
    $counter = 0

    $hasMatch = {
        param([array]$Tokens, [string]$Pattern)
        if (-not $Tokens -or $Tokens.Count -eq 0) { return $false }
        $match = $Tokens | Where-Object { $_ -match $Pattern } | Select-Object -First 1
        return $null -ne $match
    }

    foreach ($project in $ProjectReports) {
        $counter++
        Write-Progress -Id 10 -Activity "DevOps Maturity Analysis" -Status "Analyzing $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete (($counter / $ProjectReports.Count) * 100)
        
        try {
            $maturity = [DevOpsMaturity]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                CI_CDMaturity = "None"
                AutomatedTesting = $false
                AutomatedDeployment = $false
                InfrastructureAsCode = $false
                MonitoringIntegration = $false
                SecurityIntegration = $false
                DeploymentFrequency = 0
                LeadTime = 0.0
                ChangeFailureRate = 0.0
                RecoveryTime = 0.0
                DORAScore = "Low"
                MaturityLevel = "Initial"
            }

            if ($project.PipelinesTotal -eq 0) {
                $maturity.CI_CDMaturity = "None"
            } elseif ($project.PipelineSuccessRate -ge 0.9) {
                $maturity.CI_CDMaturity = "Advanced"
            } elseif ($project.PipelineSuccessRate -ge 0.7) {
                $maturity.CI_CDMaturity = "Intermediate"
            } else {
                $maturity.CI_CDMaturity = "Basic"
            }

            $projectDetails = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)?statistics=true&with_topics=true"
            $jobs = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/jobs?per_page=100"
            $pipelines = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/pipelines?per_page=20"
            $deployments = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/deployments?per_page=20"
            $environments = Invoke-GitLabAPI -Endpoint "projects/$($project.ProjectId)/environments?per_page=20"

            $tokens = @()
            if ($projectDetails -and $projectDetails.topics) { $tokens += $projectDetails.topics }
            if ($projectDetails -and $projectDetails.description) { $tokens += $projectDetails.description }

            if ($jobs) {
                $tokens += ($jobs | ForEach-Object {
                    $_.name
                    $_.stage
                    if ($_.tag_list) { $_.tag_list }
                    if ($_.coverage) { "coverage" }
                    if ($_.artifacts_file) { $_.artifacts_file.filename }
                    if ($_.artifacts -and $_.artifacts.Count -gt 0) { $_.artifacts | ForEach-Object { $_.file_type; $_.filename } }
                })
            }

            if ($pipelines) {
                $tokens += ($pipelines | ForEach-Object { $_.status })
            }

            if ($deployments) {
                $tokens += ($deployments | ForEach-Object {
                    $_.status
                    if ($_.deployable) {
                        $_.deployable.name
                        $_.deployable.stage
                    }
                })
            }

            if ($environments) {
                $tokens += ($environments | ForEach-Object { $_.name; $_.slug })
            }

            $tokens = $tokens | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

            if (-not $maturity.AutomatedTesting) {
                $maturity.AutomatedTesting = (& $hasMatch $tokens 'test|spec|unit|integration|qa|coverage|lint|junit|pytest|jest|mocha|cypress|selenium|sonar')
            }

            if (-not $maturity.AutomatedTesting -and $jobs) {
                $coverageJob = $jobs | Where-Object { $_.coverage } | Select-Object -First 1
                if ($coverageJob) { $maturity.AutomatedTesting = $true }
            }

            $maturity.AutomatedDeployment = ($deployments -and $deployments.Count -gt 0) -or (& $hasMatch $tokens 'deploy|release|delivery|promote|helm|kubectl|cd\b|argo')
            if (-not $maturity.AutomatedDeployment -and $jobs) {
                $maturity.AutomatedDeployment = ($jobs | Where-Object { $_.stage -eq 'deploy' -or $_.name -match 'deploy|release|delivery|promote' } | Select-Object -First 1) -ne $null
            }

            $maturity.InfrastructureAsCode = (& $hasMatch $tokens 'terraform|pulumi|ansible|cloudformation|iac|kustomize|packer|helm')
            $maturity.MonitoringIntegration = (& $hasMatch $tokens 'prometheus|grafana|datadog|new relic|splunk|observability|monitor')
            $maturity.SecurityIntegration = (& $hasMatch $tokens 'sast|dast|dependency|container|secret|security|trivy|grype|bandit|zap')

            if ($environments -and -not $maturity.MonitoringIntegration) {
                $maturity.MonitoringIntegration = ($environments | Where-Object { $_.name -match 'monitor|observability' }) -ne $null
            }

            if ($pipelines -and $pipelines.Count -gt 1) {
                $sortedPipelines = $pipelines | Sort-Object { [datetime]$_.created_at }
                $firstPipelineTime = [datetime]$sortedPipelines[0].created_at
                $lastPipelineTime = [datetime]$sortedPipelines[-1].created_at
                $spanDays = ($lastPipelineTime - $firstPipelineTime).TotalDays
                if ($spanDays -gt 0) {
                    $maturity.DeploymentFrequency = [math]::Round($sortedPipelines.Count / $spanDays, 2)
                }
                $failedPipelines = ($sortedPipelines | Where-Object { $_.status -in @('failed', 'canceled') }).Count
                if ($sortedPipelines.Count -gt 0) {
                    $maturity.ChangeFailureRate = [math]::Round(($failedPipelines / $sortedPipelines.Count) * 100, 1)
                }
            }

            if ($maturity.DeploymentFrequency -eq 0 -and $project.PipelinesTotal -gt 0) {
                $projectAgeDays = [math]::Max(1, ((Get-Date) - $project.CreatedAt).Days)
                $maturity.DeploymentFrequency = [math]::Round($project.PipelinesTotal / $projectAgeDays, 2)
            }

            if ($maturity.ChangeFailureRate -eq 0 -and $project.PipelinesTotal -gt 0) {
                $maturity.ChangeFailureRate = [math]::Round((1 - $project.PipelineSuccessRate) * 100, 1)
            }

            $pipelineDurations = @()
            if ($pipelines) {
                $pipelineDurations = $pipelines | Where-Object { $_.duration } | ForEach-Object { [double]$_.duration / 3600 }
            }
            if ($pipelineDurations.Count -gt 0) {
                $maturity.LeadTime = [math]::Round(($pipelineDurations | Measure-Object -Average).Average, 2)
            } elseif ($project.MergedMergeRequests -gt 0) {
                $maturity.LeadTime = [math]::Max(0.5, [math]::Min(30, $project.DaysSinceLastActivity / [math]::Max(1, $project.MergedMergeRequests)))
            }

            if ($deployments) {
                $recoveryDurations = $deployments | Where-Object { $_.created_at -and $_.finished_at } | ForEach-Object {
                    ([datetime]$_.finished_at - [datetime]$_.created_at).TotalHours
                }
                if ($recoveryDurations.Count -gt 0) {
                    $maturity.RecoveryTime = [math]::Round(($recoveryDurations | Measure-Object -Average).Average, 2)
                }
            }

            $doraScore = 0
            if ($maturity.DeploymentFrequency -gt 1) { $doraScore += 25 }
            elseif ($maturity.DeploymentFrequency -gt 0.1) { $doraScore += 15 }

            if ($maturity.LeadTime -gt 0 -and $maturity.LeadTime -lt 1) { $doraScore += 25 }
            elseif ($maturity.LeadTime -gt 0 -and $maturity.LeadTime -lt 7) { $doraScore += 15 }

            if ($maturity.ChangeFailureRate -lt 10) { $doraScore += 25 }
            elseif ($maturity.ChangeFailureRate -lt 20) { $doraScore += 15 }

            if ($maturity.AutomatedTesting) { $doraScore += 25 }

            if ($doraScore -ge 75) { $maturity.DORAScore = "Elite" }
            elseif ($doraScore -ge 50) { $maturity.DORAScore = "High" }
            elseif ($doraScore -ge 25) { $maturity.DORAScore = "Medium" }
            else { $maturity.DORAScore = "Low" }

            $maturity.CI_CDScore = switch ($maturity.CI_CDMaturity) {
                "Advanced" { 90 }
                "Intermediate" { 70 }
                "Basic" { 40 }
                default { 10 }
            }

            $maturity.TestingScore = if ($maturity.AutomatedTesting) { 85 } else { 20 }
            $maturity.SecurityScore = if ($maturity.SecurityIntegration) {
                if ($project.PipelineSuccessRate -gt 0.8) { 85 } else { 70 }
            } else {
                if ($project.PipelineSuccessRate -gt 0.8) { 55 } else { 30 }
            }
            $maturity.MonitoringScore = if ($maturity.MonitoringIntegration) { 80 } else { 30 }

            $automationFactors = 0
            if ($maturity.AutomatedTesting) { $automationFactors++ }
            if ($maturity.AutomatedDeployment) { $automationFactors++ }
            if ($maturity.InfrastructureAsCode) { $automationFactors++ }
            $maturity.AutomationScore = [math]::Round(($automationFactors / 3.0) * 100)

            $collaborationBase = [math]::Min(100, ($project.ContributorsCount * 20) + ($project.MergedMergeRequests * 2))
            $maturity.CollaborationScore = [math]::Max(10, $collaborationBase)

            $maturity.MaturityScore = [math]::Round((
                $maturity.CI_CDScore +
                $maturity.TestingScore +
                $maturity.SecurityScore +
                $maturity.MonitoringScore +
                $maturity.AutomationScore +
                $maturity.CollaborationScore
            ) / 6)

            $maturityFactors = 0
            if ($maturity.AutomatedTesting) { $maturityFactors++ }
            if ($maturity.AutomatedDeployment) { $maturityFactors++ }
            if ($maturity.InfrastructureAsCode) { $maturityFactors++ }
            if ($maturity.SecurityIntegration) { $maturityFactors++ }
            if ($project.PipelineSuccessRate -gt 0.8) { $maturityFactors++ }
            if ($maturity.DeploymentFrequency -gt 0.5) { $maturityFactors++ }

            if ($maturityFactors -ge 5) { $maturity.MaturityLevel = "Optimizing" }
            elseif ($maturityFactors -ge 4) { $maturity.MaturityLevel = "Managed" }
            elseif ($maturityFactors -ge 3) { $maturity.MaturityLevel = "Defined" }
            elseif ($maturityFactors -ge 2) { $maturity.MaturityLevel = "Repeatable" }
            else { $maturity.MaturityLevel = "Initial" }

            $maturityReports += $maturity
        } catch {
            Write-Log -Message "Failed to analyze DevOps maturity for project $($project.ProjectName): $($_.Exception.Message)" -Level "Warning" -Component "DevOpsMaturity"
        }
    }
    
    Write-Progress -Id 10 -Completed
    Write-Log -Message "Analyzed DevOps maturity for $($maturityReports.Count) projects" -Level "Success" -Component "DevOpsMaturity"
    
    return $maturityReports
}
function Generate-AdoptionBarriersReport {
    param([array]$ProjectReports, [array]$FeatureReports, [array]$TeamReports)
    
    Write-Log -Message "🚧 Generating Adoption Barriers Analysis..." -Level "Info" -Component "AdoptionBarriers"
    
    $barrierReports = @()
    $counter = 0
    
    foreach ($project in $ProjectReports) {
        $counter++
        Write-Progress -Id 11 -Activity "Adoption Barriers Analysis" -Status "Analyzing $($project.ProjectName) ($counter/$($ProjectReports.Count))" -PercentComplete (($counter / $ProjectReports.Count) * 100)
        
        try {
            $barriers = [AdoptionBarriers]@{
                ProjectName = $project.ProjectName
                ProjectId = $project.ProjectId
                LackOfTraining = $false
                ComplexSetup = $false
                LegacyProcesses = $false
                ResourceConstraints = $false
                TechnicalDebt = $false
                CulturalResistance = $false
                PrimaryBarrier = "None identified"
                RecommendedActions = ""
                BarrierSeverity = 1
                SupportNeeded = "Monitoring"
            }
            
            # Detect lack of training
            if ($project.ContributorsCount -gt 1 -and $project.PipelinesTotal -eq 0) {
                $barriers.LackOfTraining = $true
                $barriers.BarrierSeverity += 2
            }
            
            # Detect complex setup issues
            if ($project.PipelinesTotal -gt 0 -and $project.PipelineSuccessRate -lt 0.5) {
                $barriers.ComplexSetup = $true
                $barriers.BarrierSeverity += 3
            }
            
            # Detect legacy processes
            if ($project.MergedMergeRequests -eq 0 -and $project.CommitsCount -gt 50) {
                $barriers.LegacyProcesses = $true
                $barriers.BarrierSeverity += 2
            }
            
            # Detect resource constraints
            if ($project.ContributorsCount -eq 1 -and $project.DaysSinceLastActivity -gt 30) {
                $barriers.ResourceConstraints = $true
                $barriers.BarrierSeverity += 2
            }
            
            # Detect technical debt
            if ($project.OpenIssues -gt ($project.ClosedIssues * 2) -and $project.OpenIssues -gt 10) {
                $barriers.TechnicalDebt = $true
                $barriers.BarrierSeverity += 1
            }
            
            # Detect cultural resistance
            if ($project.ContributorsCount -gt 3 -and ($project.OpenIssues + $project.ClosedIssues) -eq 0) {
                $barriers.CulturalResistance = $true
                $barriers.BarrierSeverity += 2
            }
            
            # Identify primary barrier
            if ($barriers.ComplexSetup) { $barriers.PrimaryBarrier = "Complex Setup" }
            elseif ($barriers.LackOfTraining) { $barriers.PrimaryBarrier = "Lack of Training" }
            elseif ($barriers.LegacyProcesses) { $barriers.PrimaryBarrier = "Legacy Processes" }
            elseif ($barriers.ResourceConstraints) { $barriers.PrimaryBarrier = "Resource Constraints" }
            elseif ($barriers.TechnicalDebt) { $barriers.PrimaryBarrier = "Technical Debt" }
            elseif ($barriers.CulturalResistance) { $barriers.PrimaryBarrier = "Cultural Resistance" }
            
            # Generate recommended actions
            $actions = @()
            if ($barriers.LackOfTraining) { $actions += "Provide GitLab training workshops" }
            if ($barriers.ComplexSetup) { $actions += "Simplify CI/CD pipeline configuration" }
            if ($barriers.LegacyProcesses) { $actions += "Implement merge request workflow training" }
            if ($barriers.ResourceConstraints) { $actions += "Allocate dedicated GitLab champion" }
            if ($barriers.TechnicalDebt) { $actions += "Address issue backlog and prioritize cleanup" }
            if ($barriers.CulturalResistance) { $actions += "Change management and team alignment sessions" }
            
            $barriers.RecommendedActions = if ($actions.Count -gt 0) { $actions -join "; " } else { "Continue monitoring and provide on-demand support" }
            
            # Determine support needed
            if ($barriers.BarrierSeverity -ge 7) { $barriers.SupportNeeded = "Immediate Intervention" }
            elseif ($barriers.BarrierSeverity -ge 5) { $barriers.SupportNeeded = "Active Support" }
            elseif ($barriers.BarrierSeverity -ge 3) { $barriers.SupportNeeded = "Guidance" }
            else { $barriers.SupportNeeded = "Self-Service" }
            
            $barrierReports += $barriers
            
        } catch {
            Write-Log -Message "Failed to analyze adoption barriers for project $($project.ProjectName): $($_.Exception.Message)" -Level "Warning" -Component "AdoptionBarriers"
        }
    }
    
    Write-Progress -Id 11 -Completed
    Write-Log -Message "Analyzed adoption barriers for $($barrierReports.Count) projects" -Level "Success" -Component "AdoptionBarriers"
    
    return $barrierReports
}

# Function to load and expand template with PowerShell execution
function Expand-Template {
    param(
        [string]$TemplatePath,
        [hashtable]$Parameters
    )
    
    try {
        # Load the template
        if (!(Test-Path $TemplatePath)) {
            throw "Template file not found: $TemplatePath"
        }
        
        $templateContent = Get-Content -Path $TemplatePath -Raw
        
        Write-Log -Message "Starting template expansion with PowerShell execution for: $($Parameters.Keys -join ', ')" -Level "Debug" -Component "TemplateExpansion"
        
        # Set all variables in current scope for template execution
        # Convert complex objects to simpler hashtables for better template handling
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            
            # Convert complex objects to hashtables to avoid property access issues
            if ($value -is [array] -and $value.Count -gt 0 -and $value[0].GetType().Name -like "*Report*") {
                $convertedArray = @()
                foreach ($item in $value) {
                    $hash = @{}
                    $item.PSObject.Properties | ForEach-Object { $hash[$_.Name] = $_.Value }
                    $convertedArray += $hash
                }
                Set-Variable -Name $key -Value $convertedArray -Scope Local
                Write-Log -Message "Converted $key array to hashtables (Count: $($convertedArray.Count))" -Level "Debug" -Component "TemplateExpansion"
            } else {
                Set-Variable -Name $key -Value $value -Scope Local
                Write-Log -Message "Set variable $key" -Level "Debug" -Component "TemplateExpansion"
            }
        }
        
        # Execute template with PowerShell expansion to handle $(foreach...) blocks
        Write-Log -Message "Executing template expansion with ExpandString" -Level "Debug" -Component "TemplateExpansion"
        
        try {
            $expandedContent = $ExecutionContext.InvokeCommand.ExpandString($templateContent)
        } catch {
            Write-Log -Message "Template expansion error: $($_.Exception.Message)" -Level "Error" -Component "TemplateExpansion"
            throw
        }
        
        # Ensure result is a clean string
        if ($expandedContent -is [string]) {
            $finalContent = $expandedContent
        } else {
            $finalContent = $expandedContent.ToString()
        }
        
        $expandedContent = $finalContent
        
        # Final validation
        if ($expandedContent -match '<!DOCTYPE html|<html') {
            Write-Log -Message "Template expansion successful, generated $($expandedContent.Length) characters" -Level "Debug" -Component "TemplateExpansion"
            return $expandedContent
        } else {
            Write-Log -Message "No valid HTML found. Content preview: $($expandedContent.Substring(0, [Math]::Min(200, $expandedContent.Length)))" -Level "Error" -Component "TemplateExpansion"
            throw "Template expansion did not produce valid HTML"
        }
        
    } catch {
        Write-Log -Message "Failed to expand template: $($_.Exception.Message)" -Level "Error" -Component "TemplateExpansion"
        # Fallback to simple string replacement for critical variables
        $templateContent = Get-Content -Path $TemplatePath -Raw
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            $stringValue = if ($null -eq $value) { "0" } else { $value.ToString() }
            $templateContent = $templateContent -replace "\`$$key\b", $stringValue
        }
        return $templateContent
    }
}

# Function to generate dashboard using external template
function New-ConsolidatedDashboardFromTemplate {
    param(
        [array]$ProjectReports,
        [array]$SecurityScanResults,
        [array]$CodeQualityReports,
        [array]$CostReports,
        [array]$TeamReports,
        [array]$TechReports,
        [array]$LifecycleReports,
        [array]$BusinessReports,
        [array]$FeatureAdoptionReports,
        [array]$CollaborationReports,
        [array]$DevOpsMaturityReports,
        [array]$AdoptionBarrierReports,
        [string]$ReportDate,
        [int]$DaysBack,
        [timespan]$ExecutionTime
    )
    
    # Calculate all metrics needed for the template with safe division
    $totalProjects = if ($ProjectReports) { $ProjectReports.Count } else { 0 }
    $activeProjects = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.DaysSinceLastActivity -le 30 }).Count } else { 0 }
    $staleProjects = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 90 }).Count } else { 0 }
    
    $highAdoption = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'High' }).Count } else { 0 }
    $mediumAdoption = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'Medium' }).Count } else { 0 }
    $lowAdoption = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'Low' }).Count } else { 0 }
    $veryLowAdoption = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'Very Low' }).Count } else { 0 }
    
    # Safe division for adoption rate
    $adoptionRate = if ($totalProjects -gt 0) { 
        [math]::Round((($highAdoption + $mediumAdoption) / $totalProjects) * 100, 1) 
    } else { 0 }
    
    $projectsWithPipelines = if ($ProjectReports) { $ProjectReports | Where-Object { $_.PipelinesTotal -gt 0 } } else { @() }
    $projectsWithPipelinesCount = $projectsWithPipelines.Count
    $avgPipelineSuccess = if ($projectsWithPipelinesCount -gt 0) { 
        [math]::Round(($projectsWithPipelines | Measure-Object -Property PipelineSuccessRate -Average).Average * 100, 1) 
    } else { 0 }
    
    # Security metrics
    $totalCriticalVulns = if ($SecurityScanResults) { ($SecurityScanResults | Measure-Object -Property CriticalVulnerabilities -Sum).Sum } else { 0 }
    $projectsWithCriticalVulns = if ($SecurityScanResults) { ($SecurityScanResults | Where-Object { $_.CriticalVulnerabilities -gt 0 }).Count } else { 0 }
    
    # Code quality metrics
    $avgMaintainability = if ($CodeQualityReports -and $CodeQualityReports.Count -gt 0) {
        $ratings = @{A=5; B=4; C=3; D=2; E=1}
        $totalScore = ($CodeQualityReports | ForEach-Object { 
            if ($ratings.ContainsKey($_.MaintainabilityRating)) {
                $ratings[$_.MaintainabilityRating]
            } else { 3 }
        } | Measure-Object -Sum).Sum
        [math]::Round(($totalScore / $CodeQualityReports.Count) * 20, 1)
    } else { 0 }
    
    # Activity distribution
    $activity7Days = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.DaysSinceLastActivity -le 7 }).Count } else { 0 }
    $activity30Days = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 7 -and $_.DaysSinceLastActivity -le 30 }).Count } else { 0 }
    $activity90Days = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 30 -and $_.DaysSinceLastActivity -le 90 }).Count } else { 0 }
    $activityOlder = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 90 }).Count } else { 0 }

    # Pipeline success distribution
    $pipelineExcellent = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.PipelineSuccessRate -gt 0.9 }).Count } else { 0 }
    $pipelineGood = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.PipelineSuccessRate -gt 0.7 -and $_.PipelineSuccessRate -le 0.9 }).Count } else { 0 }
    $pipelineFair = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.PipelineSuccessRate -gt 0.5 -and $_.PipelineSuccessRate -le 0.7 }).Count } else { 0 }
    $pipelinePoor = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.PipelineSuccessRate -le 0.5 -and $_.PipelinesTotal -gt 0 }).Count } else { 0 }
    $pipelineNone = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.PipelinesTotal -eq 0 }).Count } else { 0 }

    # Team contribution distribution
    $singleContributor = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.ContributorsCount -eq 1 }).Count } else { 0 }
    $smallTeam = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.ContributorsCount -ge 2 -and $_.ContributorsCount -le 3 }).Count } else { 0 }
    $largeTeam = if ($ProjectReports) { ($ProjectReports | Where-Object { $_.ContributorsCount -ge 4 }).Count } else { 0 }

    # Pre-generate HTML table content to avoid template object property access issues
    $costAnalysisTableRows = ""
    if ($CostReports -and $CostReports.Count -gt 0) {
        foreach ($cost in $CostReports) {
            $rowClass = switch ($cost.EfficiencyGrade) {
                "A" { "status-high" }
                "B" { "status-medium" }
                "C" { "status-low" }
                "D" { "status-critical" }
                default { "" }
            }
            $costAnalysisTableRows += @"
                            <tr class="$rowClass">
                                <td><strong>$($cost.ProjectName)</strong></td>
                                <td>`$$($cost.TotalCost)</td>
                                <td>`$$($cost.StorageCost)</td>
                                <td>`$$($cost.CI_CDCost)</td>
                                <td>$($cost.EstimatedDeveloperHours)h</td>
                                <td>$($cost.BusinessValue)</td>
                                <td>$($cost.ROI)%</td>
                                <td><span class="grade-$($cost.EfficiencyGrade)">$($cost.EfficiencyGrade)</span></td>
                            </tr>
"@
        }
    } else {
        $costAnalysisTableRows = @"
                            <tr>
                                <td colspan="8" style="text-align: center; color: #666; font-style: italic;">
                                    Cost analysis data not available. Run with -IncludeAllReports to generate cost analysis.
                                </td>
                            </tr>
"@
    }

    # Prepare all parameters for template expansion
    $templateParameters = @{
        ProjectReports = if ($ProjectReports) { $ProjectReports } else { @() }
        SecurityScanResults = if ($SecurityScanResults) { $SecurityScanResults } else { @() }
        CodeQualityReports = if ($CodeQualityReports) { $CodeQualityReports } else { @() }
        CostReports = if ($CostReports) { $CostReports } else { @() }
        TeamReports = if ($TeamReports) { $TeamReports } else { @() }
        TechReports = if ($TechReports) { $TechReports } else { @() }
        LifecycleReports = if ($LifecycleReports) { $LifecycleReports } else { @() }
        BusinessReports = if ($BusinessReports) { $BusinessReports } else { @() }
        FeatureAdoptionReports = if ($FeatureAdoptionReports) { $FeatureAdoptionReports } else { @() }
        CollaborationReports = if ($CollaborationReports) { $CollaborationReports } else { @() }
        DevOpsMaturityReports = if ($DevOpsMaturityReports) { $DevOpsMaturityReports } else { @() }
        AdoptionBarrierReports = if ($AdoptionBarrierReports) { $AdoptionBarrierReports } else { @() }
        ReportDate = $ReportDate
        DaysBack = $DaysBack
        ExecutionTime = $ExecutionTime
        totalProjects = $totalProjects
        activeProjects = $activeProjects
        staleProjects = $staleProjects
        highAdoption = $highAdoption
        mediumAdoption = $mediumAdoption
        lowAdoption = $lowAdoption
        veryLowAdoption = $veryLowAdoption
        adoptionRate = $adoptionRate  # Pre-calculated safe value
        avgPipelineSuccess = $avgPipelineSuccess
        totalCriticalVulns = $totalCriticalVulns
        projectsWithCriticalVulns = $projectsWithCriticalVulns
        avgMaintainability = $avgMaintainability
        activity7Days = $activity7Days
        activity30Days = $activity30Days
        activity90Days = $activity90Days
        activityOlder = $activityOlder
        pipelineExcellent = $pipelineExcellent
        pipelineGood = $pipelineGood
        pipelineFair = $pipelineFair
        pipelinePoor = $pipelinePoor
        pipelineNone = $pipelineNone
        singleContributor = $singleContributor
        smallTeam = $smallTeam
        largeTeam = $largeTeam
        projectsWithPipelinesCount = $projectsWithPipelinesCount
        # Pre-generated HTML content
        costAnalysisTableRows = $costAnalysisTableRows
        # Computed display values (to avoid complex expressions in template)
        activeProjectsCount = $totalProjects - $staleProjects
        adoptionProjectsCount = $highAdoption + $mediumAdoption
        adoptionRatio = "$adoptionProjectsCount/$totalProjects"
        # Adoption-focused metrics
        avgFeatureAdoption = if ($FeatureAdoptionReports -and $FeatureAdoptionReports.Count -gt 0) { 
            [math]::Round(($FeatureAdoptionReports | Measure-Object -Property FeatureAdoptionScore -Average).Average, 1) 
        } else { 0 }
        avgCollaborationScore = if ($CollaborationReports -and $CollaborationReports.Count -gt 0) { 
            Write-Log -Message "CollaborationReports: Count=$($CollaborationReports.Count), FirstScore=$($CollaborationReports[0].CollaborationScore)" -Level "Debug" -Component "ChartData"
            [math]::Round(($CollaborationReports | Measure-Object -Property CollaborationScore -Average).Average, 1) 
        } else { 
            Write-Log -Message "CollaborationReports: Empty or null" -Level "Debug" -Component "ChartData"
            0 
        }
        avgDevOpsMaturity = if ($DevOpsMaturityReports -and $DevOpsMaturityReports.Count -gt 0) { 
            [math]::Round(($DevOpsMaturityReports | Measure-Object -Property MaturityScore -Average).Average, 1) 
        } else { 0 }
        avgCI_CDScore = if ($DevOpsMaturityReports -and $DevOpsMaturityReports.Count -gt 0) { 
            [math]::Round(($DevOpsMaturityReports | Measure-Object -Property CI_CDScore -Average).Average, 1) 
        } else { 0 }
        avgTestingScore = if ($DevOpsMaturityReports -and $DevOpsMaturityReports.Count -gt 0) { 
            [math]::Round(($DevOpsMaturityReports | Measure-Object -Property TestingScore -Average).Average, 1) 
        } else { 0 }
        avgSecurityScore = if ($DevOpsMaturityReports -and $DevOpsMaturityReports.Count -gt 0) { 
            [math]::Round(($DevOpsMaturityReports | Measure-Object -Property SecurityScore -Average).Average, 1) 
        } else { 0 }
        avgMonitoringScore = if ($DevOpsMaturityReports -and $DevOpsMaturityReports.Count -gt 0) { 
            [math]::Round(($DevOpsMaturityReports | Measure-Object -Property MonitoringScore -Average).Average, 1) 
        } else { 0 }
        avgAutomationScore = if ($DevOpsMaturityReports -and $DevOpsMaturityReports.Count -gt 0) { 
            [math]::Round(($DevOpsMaturityReports | Measure-Object -Property AutomationScore -Average).Average, 1) 
        } else { 0 }
        avgCollaborationMaturityScore = if ($DevOpsMaturityReports -and $DevOpsMaturityReports.Count -gt 0) { 
            [math]::Round(($DevOpsMaturityReports | Measure-Object -Property CollaborationScore -Average).Average, 1) 
        } else { 0 }
        criticalBarriers = if ($AdoptionBarrierReports) { 
            $criticalCount = ($AdoptionBarrierReports | Where-Object { $_.BarrierSeverity -ge 7 }).Count
            Write-Log -Message "AdoptionBarrierReports: Count=$($AdoptionBarrierReports.Count), CriticalBarriers=$criticalCount" -Level "Debug" -Component "ChartData"
            $criticalCount
        } else { 
            Write-Log -Message "AdoptionBarrierReports: Empty or null" -Level "Debug" -Component "ChartData"
            0 
        }
        excellentAdoption = if ($FeatureAdoptionReports) { 
            ($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Excellent" }).Count 
        } else { 0 }
        goodAdoption = if ($FeatureAdoptionReports) { 
            ($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Good" }).Count 
        } else { 0 }
        needsImprovementAdoption = if ($FeatureAdoptionReports) { 
            ($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Fair" }).Count + 
            ($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Basic" }).Count 
        } else { 0 }
        poorAdoption = if ($FeatureAdoptionReports) { 
            ($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Minimal" }).Count 
        } else { 0 }
    }
    
    # Get the template path (assuming it's in the same directory as the script)
    $templatePath = Join-Path $PSScriptRoot "gitlab-report-template.html"
    
    # Expand the template
    return Expand-Template -TemplatePath $templatePath -Parameters $templateParameters
}

# Enhanced API function with rate limiting, exponential backoff, and  error handling
function Invoke-GitLabAPI {
    param(
        [string]$Endpoint,
        [switch]$AllPages,
        [string]$Method = "GET",
        [string]$Body = $null,
        [int]$MaxRetries = 3,
        [int]$BaseDelayMs = 250,
        [int]$MaxDelayMs = 16000,
        [int]$RateLimitDelayMs = 1000,
        [int]$MaxPages = 100
    )
    
    # Track rate limiting globally
    if (-not $global:GitLabAPITracker) {
        $global:GitLabAPITracker = @{
            LastCallTime = Get-Date
            CallsInLastMinute = 0
            RateLimitResetTime = Get-Date
            MaxRequestsPerMinute = 600  # GitLab default rate limit
        }
    }
    
    # Implement rate limiting
    $now = Get-Date
    if (($now - $global:GitLabAPITracker.LastCallTime).TotalMilliseconds -lt $RateLimitDelayMs) {
        $sleepTime = $RateLimitDelayMs - ($now - $global:GitLabAPITracker.LastCallTime).TotalMilliseconds
        if ($sleepTime -gt 0) {
            Write-Verbose "Rate limiting: sleeping for $([math]::Round($sleepTime))ms"
            Start-Sleep -Milliseconds $sleepTime
        }
    }
    
    # Reset calls counter every minute
    if (($now - $global:GitLabAPITracker.RateLimitResetTime).TotalMinutes -ge 1) {
        $global:GitLabAPITracker.CallsInLastMinute = 0
        $global:GitLabAPITracker.RateLimitResetTime = $now
    }
    
    # Check if we're approaching rate limit
    if ($global:GitLabAPITracker.CallsInLastMinute -ge ($global:GitLabAPITracker.MaxRequestsPerMinute * 0.9)) {
        $timeToWait = 60 - ($now - $global:GitLabAPITracker.RateLimitResetTime).TotalSeconds
        if ($timeToWait -gt 0) {
            Write-Host "   Approaching rate limit, waiting $([math]::Round($timeToWait))s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $timeToWait
            $global:GitLabAPITracker.CallsInLastMinute = 0
            $global:GitLabAPITracker.RateLimitResetTime = Get-Date
        }
    }
    
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            # Exponential backoff with jitter for retries
            if ($attempt -gt 0) {
                $delay = [math]::Min($MaxDelayMs, $BaseDelayMs * [math]::Pow(2, $attempt - 1))
                $jitter = Get-Random -Minimum 0 -Maximum ($delay * 0.1)
                $totalDelay = $delay + $jitter
                
                Write-Host "   Retrying API call (attempt $($attempt + 1)/$($MaxRetries + 1)) after $([math]::Round($totalDelay))ms..." -ForegroundColor Yellow
                Start-Sleep -Milliseconds $totalDelay
            }
            
            $global:GitLabAPITracker.LastCallTime = Get-Date
            $global:GitLabAPITracker.CallsInLastMinute++
            
            if ($AllPages) {
                $allResults = @()
                $page = 1
                $perPage = 100
                $pageCount = 0
                
                do {
                    # Construct URI properly
                    $separator = if ($Endpoint.Contains("?")) { "&" } else { "?" }
                    $uri = "$GitLabURL/api/v4/$Endpoint$separator`page=$page&per_page=$perPage"
                    
                    Write-Verbose "Fetching page $page for endpoint: $Endpoint"
                    
                    # Make the API call
                    $requestParams = @{
                        Uri = $uri
                        Headers = $headers
                        Method = $Method
                        TimeoutSec = 120
                        UseBasicParsing = $true
                    }
                    
                    if ($Body) {
                        $requestParams.Body = $Body
                    }
                    
                    $response = Invoke-RestMethod @requestParams
                    
                    if ($response) {
                        $allResults += $response
                    $pageCount++
                        
                        # Log progress for large datasets
                        if ($pageCount % 10 -eq 0) {
                            Write-Host "   Fetched $pageCount pages, $($allResults.Count) items so far..." -ForegroundColor Gray
                        }
                    }
                    
                    $page++
                    
                    # Small delay between pages to be respectful
                    Start-Sleep -Milliseconds $RateLimitDelayMs
                    $global:GitLabAPITracker.LastCallTime = Get-Date
                    $global:GitLabAPITracker.CallsInLastMinute++
                    
                    # Check for rate limit headers and adjust if needed
                    # Note: PowerShell Invoke-RestMethod doesn't easily expose headers in this context
                    # In a production environment, you'd want to capture and check X-RateLimit headers
                    
                } while ($response -and $response.Count -eq $perPage -and $pageCount -lt $MaxPages)
                
                if ($pageCount -ge $MaxPages) {
                    $limitLogLevel = if ($MaxPages -lt 100) { "Verbose" } else { "Warning" }
                    Write-Log -Message "Reached configured page limit of $MaxPages for endpoint: $Endpoint - returning partial results" -Level $limitLogLevel -Component "API"
                    break
                }
                
                return $allResults
            }
            else {
                $uri = "$GitLabURL/api/v4/$Endpoint"
                
                $requestParams = @{
                    Uri = $uri
                    Headers = $headers
                    Method = $Method
                    TimeoutSec = 120
                    UseBasicParsing = $true
                }
                
                if ($Body) {
                    $requestParams.Body = $Body
                }
                
                $response = Invoke-RestMethod @requestParams
                return $response
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            $statusCode = $null
            
            # Extract status code if available
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
            
            # Handle specific error types
            switch ($statusCode) {
                429 {
                    # Rate limit exceeded
                    Write-Warning "Rate limit exceeded (HTTP 429). Waiting before retry..."
                    Start-Sleep -Seconds (60 + (Get-Random -Minimum 0 -Maximum 30))
                    $global:GitLabAPITracker.CallsInLastMinute = 0
                    $global:GitLabAPITracker.RateLimitResetTime = Get-Date
                }
                401 {
                    # Unauthorized - don't retry
                    Write-Error "Unauthorized access (HTTP 401) to $Endpoint. Check your access token."
                    return @()
                }
                403 {
                    # Forbidden - don't retry
                    Write-Warning "Forbidden access (HTTP 403) to $Endpoint. Insufficient permissions."
                    return @()
                }
                404 {
                    # Not found - don't retry for single requests, but continue for pagination
                    if (-not $AllPages) {
                        Write-Verbose "Resource not found (HTTP 404) for $Endpoint"
                        return @()
                    }
                }
                500..599 {
                    # Server errors - retry with exponential backoff
                    Write-Warning "Server error (HTTP $statusCode) for $Endpoint. Will retry if attempts remain."
                }
                default {
                    Write-Warning "API call failed for $Endpoint (attempt $($attempt + 1)): HTTP $statusCode - $errorMessage"
                }
            }
            
            # If this was the last attempt, return empty result
            if ($attempt -eq $MaxRetries) {
                if ($statusCode -in @(401, 403)) {
                    Write-Error "Authentication/Authorization failed for $Endpoint after $($MaxRetries + 1) attempts"
                } else {
                    Write-Warning "All retry attempts failed for $Endpoint after $($MaxRetries + 1) attempts. Returning empty data."
                }
                return @()
            }
        }
    }
}

# Function to test GitLab connection
function Test-GitLabConnection {
    param([string]$GitLabURL, [string]$AccessToken)
    
    try {
        Write-Log -Message "Testing connection to GitLab instance at $GitLabURL" -Level "Info" -Component "Connection"
        $testHeaders = @{'PRIVATE-TOKEN' = $AccessToken}
        $uri = "$GitLabURL/api/v4/version"
        
        $version = Invoke-RestMethod -Uri $uri -Headers $testHeaders -TimeoutSec 30
        Write-Log -Message "Successfully connected to GitLab $($version.version)" -Level "Success" -Component "Connection"
        return $true
    }
    catch {
        Write-Log -Message "Failed to connect to GitLab: $($_.Exception.Message)" -Level "Error" -Component "Connection"
        Write-Log -Message "Please check:" -Level "Warning" -Component "Connection"
        Write-Log -Message "- GitLab URL: $GitLabURL" -Level "Warning" -Component "Connection"
        Write-Log -Message "- Access token permissions" -Level "Warning" -Component "Connection"
        Write-Log -Message "- Network connectivity" -Level "Warning" -Component "Connection"
        return $false
    }
}

# Function to export enhanced CSV reports including adoption metrics
function Export-EnhancedCSVReports {
    param(
        [array]$ProjectReports,
        [array]$SecurityScanResults,
        [array]$CodeQualityReports,
        [array]$CostReports,
        [array]$TeamReports,
        [array]$TechReports,
        [array]$LifecycleReports,
        [array]$BusinessReports,
        [array]$FeatureAdoptionReports,
        [array]$CollaborationReports,
        [array]$DevOpsMaturityReports,
        [array]$AdoptionBarrierReports,
        [string]$OutputPath,
        [string]$ReportDate
    )
    
    Write-Log -Message "Exporting enhanced CSV reports with adoption metrics..." -Level "Info" -Component "CSVExport"
    
    try {
        # Export existing reports
        if ($ProjectReports.Count -gt 0) {
            $projectCsvPath = Join-Path $OutputPath "GitLab-Project-Details-$ReportDate.csv"
            $ProjectReports | Export-Csv -Path $projectCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Project Details: $projectCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($SecurityScanResults.Count -gt 0) {
            $securityCsvPath = Join-Path $OutputPath "GitLab-Security-Details-$ReportDate.csv"
            $SecurityScanResults | Export-Csv -Path $securityCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Security Details: $securityCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($CodeQualityReports.Count -gt 0) {
            $qualityCsvPath = Join-Path $OutputPath "GitLab-CodeQuality-Details-$ReportDate.csv"
            $CodeQualityReports | Export-Csv -Path $qualityCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Code Quality Details: $qualityCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($CostReports.Count -gt 0) {
            $costCsvPath = Join-Path $OutputPath "GitLab-CostAnalysis-Details-$ReportDate.csv"
            $CostReports | Export-Csv -Path $costCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Cost Analysis Details: $costCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($TeamReports.Count -gt 0) {
            $teamCsvPath = Join-Path $OutputPath "GitLab-TeamActivity-Details-$ReportDate.csv"
            $TeamReports | Export-Csv -Path $teamCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Team Activity Details: $teamCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($TechReports.Count -gt 0) {
            $techCsvPath = Join-Path $OutputPath "GitLab-TechnologyStack-Details-$ReportDate.csv"
            $TechReports | Export-Csv -Path $techCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Technology Stack Details: $techCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($LifecycleReports.Count -gt 0) {
            $lifecycleCsvPath = Join-Path $OutputPath "GitLab-ProjectLifecycle-Details-$ReportDate.csv"
            $LifecycleReports | Export-Csv -Path $lifecycleCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Project Lifecycle Details: $lifecycleCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($BusinessReports.Count -gt 0) {
            $businessCsvPath = Join-Path $OutputPath "GitLab-BusinessAlignment-Details-$ReportDate.csv"
            $BusinessReports | Export-Csv -Path $businessCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Business Alignment Details: $businessCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        # Export NEW adoption-focused reports
        if ($FeatureAdoptionReports.Count -gt 0) {
            $featureCsvPath = Join-Path $OutputPath "GitLab-FeatureAdoption-Details-$ReportDate.csv"
            $FeatureAdoptionReports | Export-Csv -Path $featureCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Feature Adoption Details: $featureCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($CollaborationReports.Count -gt 0) {
            $collaborationCsvPath = Join-Path $OutputPath "GitLab-Collaboration-Details-$ReportDate.csv"
            $CollaborationReports | Export-Csv -Path $collaborationCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Team Collaboration Details: $collaborationCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($DevOpsMaturityReports.Count -gt 0) {
            $maturityCsvPath = Join-Path $OutputPath "GitLab-DevOpsMaturity-Details-$ReportDate.csv"
            $DevOpsMaturityReports | Export-Csv -Path $maturityCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "DevOps Maturity Details: $maturityCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        if ($AdoptionBarrierReports.Count -gt 0) {
            $barriersCsvPath = Join-Path $OutputPath "GitLab-AdoptionBarriers-Details-$ReportDate.csv"
            $AdoptionBarrierReports | Export-Csv -Path $barriersCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Adoption Barriers Details: $barriersCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        # Create executive summary CSV with key adoption metrics
        $executiveSummary = @()
        foreach ($project in $ProjectReports) {
            $featureAdoption = $FeatureAdoptionReports | Where-Object { $_.ProjectId -eq $project.ProjectId } | Select-Object -First 1
            $collaboration = $CollaborationReports | Where-Object { $_.ProjectId -eq $project.ProjectId } | Select-Object -First 1
            $maturity = $DevOpsMaturityReports | Where-Object { $_.ProjectId -eq $project.ProjectId } | Select-Object -First 1
            $barriers = $AdoptionBarrierReports | Where-Object { $_.ProjectId -eq $project.ProjectId } | Select-Object -First 1
            
            $summary = [PSCustomObject]@{
                ProjectName = $project.ProjectName
                AdoptionLevel = $project.AdoptionLevel
                FeatureAdoptionScore = if ($featureAdoption) { $featureAdoption.FeatureAdoptionScore } else { 0 }
                CollaborationHealth = if ($collaboration) { $collaboration.CollaborationHealth } else { "Unknown" }
                DevOpsMaturity = if ($maturity) { $maturity.MaturityLevel } else { "Unknown" }
                PrimaryBarrier = if ($barriers) { $barriers.PrimaryBarrier } else { "None identified" }
                RecommendedAction = if ($barriers) { $barriers.RecommendedActions } else { "Continue monitoring" }
                BusinessValue = $project.ProjectHealth
                LastActivity = $project.LastActivity
                Contributors = $project.ContributorsCount
            }
            $executiveSummary += $summary
        }
        
        if ($executiveSummary.Count -gt 0) {
            $execCsvPath = Join-Path $OutputPath "GitLab-ExecutiveSummary-$ReportDate.csv"
            $executiveSummary | Export-Csv -Path $execCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Executive Summary: $execCsvPath" -Level "Success" -Component "CSVExport"
        }
        
        Write-Log -Message "All enhanced CSV reports exported successfully" -Level "Success" -Component "CSVExport"
    }
    catch {
        Write-Log -Message "Failed to export enhanced CSV reports: $($_.Exception.Message)" -Level "Error" -Component "CSVExport"
    }
}
function Export-CSVReports {
    param(
        [array]$ProjectReports,
        [array]$SecurityScanResults,
        [array]$CodeQualityReports,
        [array]$CostReports,
        [array]$TeamReports,
        [array]$TechReports,
        [array]$LifecycleReports,
        [array]$BusinessReports,
        [string]$OutputPath,
        [string]$ReportDate
    )
    
    Write-Host "📁 Exporting CSV reports..." -ForegroundColor Cyan
    
    try {
        # Export Project Details
        if ($ProjectReports.Count -gt 0) {
            $projectCsvPath = Join-Path $OutputPath "GitLab-Project-Details-$ReportDate.csv"
            $ProjectReports | Export-Csv -Path $projectCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Project Details: $projectCsvPath" -ForegroundColor Green
        }
        
        # Export Security Scan Results
        if ($SecurityScanResults.Count -gt 0) {
            $securityCsvPath = Join-Path $OutputPath "GitLab-Security-Details-$ReportDate.csv"
            $SecurityScanResults | Export-Csv -Path $securityCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Security Details: $securityCsvPath" -ForegroundColor Green
        }
        
        # Export Code Quality Reports
        if ($CodeQualityReports.Count -gt 0) {
            $qualityCsvPath = Join-Path $OutputPath "GitLab-CodeQuality-Details-$ReportDate.csv"
            $CodeQualityReports | Export-Csv -Path $qualityCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Code Quality Details: $qualityCsvPath" -ForegroundColor Green
        }
        
        # Export Cost Analysis Reports
        if ($CostReports.Count -gt 0) {
            $costCsvPath = Join-Path $OutputPath "GitLab-CostAnalysis-Details-$ReportDate.csv"
            $CostReports | Export-Csv -Path $costCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Cost Analysis Details: $costCsvPath" -ForegroundColor Green
        }
        
        # Export Team Activity Reports
        if ($TeamReports.Count -gt 0) {
            $teamCsvPath = Join-Path $OutputPath "GitLab-TeamActivity-Details-$ReportDate.csv"
            $TeamReports | Export-Csv -Path $teamCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Team Activity Details: $teamCsvPath" -ForegroundColor Green
        }
        
        # Export Technology Stack Reports
        if ($TechReports.Count -gt 0) {
            $techCsvPath = Join-Path $OutputPath "GitLab-TechnologyStack-Details-$ReportDate.csv"
            $TechReports | Export-Csv -Path $techCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Technology Stack Details: $techCsvPath" -ForegroundColor Green
        }
        
        # Export Project Lifecycle Reports
        if ($LifecycleReports.Count -gt 0) {
            $lifecycleCsvPath = Join-Path $OutputPath "GitLab-ProjectLifecycle-Details-$ReportDate.csv"
            $LifecycleReports | Export-Csv -Path $lifecycleCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Project Lifecycle Details: $lifecycleCsvPath" -ForegroundColor Green
        }
        
        # Export Business Alignment Reports
        if ($BusinessReports.Count -gt 0) {
            $businessCsvPath = Join-Path $OutputPath "GitLab-BusinessAlignment-Details-$ReportDate.csv"
            $BusinessReports | Export-Csv -Path $businessCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "   ✓ Business Alignment Details: $businessCsvPath" -ForegroundColor Green
        }
        
        Write-Host "   📊 All CSV reports exported successfully" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to export CSV reports: $($_.Exception.Message)"
    }
}

# NOTE: Removed sample data helper - this template requires a live GitLab connection and valid access token.

# MAIN SCRIPT EXECUTION
Write-LogSection -Title "Management Dashboard" -Symbol "="

Write-Log -Message "Starting GitLab dashboard generation" -Level "Info" -Component "Main"
Write-Log -Message "GitLab URL: $GitLabURL" -Level "Debug" -Component "Main"
Write-Log -Message "Include Security Data: $IncludeSecurityData" -Level "Debug" -Component "Main"
Write-Log -Message "Include All Reports: $IncludeAllReports" -Level "Debug" -Component "Main"

# Test connection first - require a successful connection. No sample data fallback.
Write-Log -Message "Testing GitLab connection..." -Level "Info" -Component "Connection"
if (-not (Test-GitLabConnection -GitLabURL $GitLabURL -AccessToken $AccessToken)) {
    Write-Log -Message "Connection to GitLab failed. Verify -GitLabURL, -AccessToken, and network connectivity." -Level "Error" -Component "Connection"
    exit 1
}

# Data collection
Write-Log -Message "Starting project data collection" -Level "Info" -Component "DataCollection"

$projects = Invoke-GitLabAPI -Endpoint "projects?statistics=true&per_page=100" -AllPages
if ($projects -and $projects.Count -gt 0) {
    Write-Host "   ✓ Found $($projects.Count) projects" -ForegroundColor Green
} else {
    Write-Error "No projects returned from GitLab API. Aborting. Ensure the token has 'read_api' and 'read_repository' scopes and the account has project visibility." 
    exit 1
}

# Process projects with  data collection
$projectReports = @()
if ($projects -and $projects.Count -gt 0) {
    $projectCounter = 0
    $totalProjects = $projects.Count
    
    foreach ($project in $projects) {
        $projectCounter++
        Update-OverallProgress -Activity "Processing project $($project.name)" -Status "Collecting detailed project data" -PercentComplete ([math]::Round(($projectCounter / $totalProjects) * 100)) -Step $projectCounter -TotalSteps $totalProjects
        
        try {
            # Get detailed project information
            $projectDetails = Invoke-GitLabAPI -Endpoint "projects/$($project.id)?statistics=true"
            
            # Get repository statistics
            $repoStats = if ($projectDetails.statistics) { $projectDetails.statistics } else { @{} }
            
            # Get contributors
            $contributors = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/repository/contributors" -AllPages
            $contributorsCount = if ($contributors) { $contributors.Count } else { 0 }
            
            # Get branches and tags
            $branches = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/repository/branches" -AllPages
            $tags = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/repository/tags" -AllPages
            
            # Get issues statistics
            $openIssues = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/issues?state=opened`&per_page=1"
            $closedIssues = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/issues?state=closed`&per_page=1"
            $openIssuesCount = if ($openIssues -and $openIssues.Count -gt 0) { (Invoke-GitLabAPI -Endpoint "projects/$($project.id)/issues?state=opened").Count } else { 0 }
            $closedIssuesCount = if ($closedIssues -and $closedIssues.Count -gt 0) { (Invoke-GitLabAPI -Endpoint "projects/$($project.id)/issues?state=closed").Count } else { 0 }
            
            # Get merge request statistics
            $openMRs = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/merge_requests?state=opened`&per_page=1"
            $mergedMRs = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/merge_requests?state=merged`&per_page=1"
            $openMRsCount = if ($openMRs -and $openMRs.Count -gt 0) { (Invoke-GitLabAPI -Endpoint "projects/$($project.id)/merge_requests?state=opened").Count } else { 0 }
            $mergedMRsCount = if ($mergedMRs -and $mergedMRs.Count -gt 0) { (Invoke-GitLabAPI -Endpoint "projects/$($project.id)/merge_requests?state=merged").Count } else { 0 }
            
            # Get pipeline statistics
            $pipelines = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/pipelines?per_page=100" -AllPages
            $pipelinesTotal = if ($pipelines) { $pipelines.Count } else { 0 }
            $pipelinesSuccess = if ($pipelines) { ($pipelines | Where-Object { $_.status -eq 'success' }).Count } else { 0 }
            $pipelinesFailed = if ($pipelines) { ($pipelines | Where-Object { $_.status -eq 'failed' }).Count } else { 0 }
            $pipelineSuccessRate = if ($pipelinesTotal -gt 0) { [math]::Round($pipelinesSuccess / $pipelinesTotal, 3) } else { 0 }
            
            # Get last commit information
            $lastCommit = Invoke-GitLabAPI -Endpoint "projects/$($project.id)/repository/commits?per_page=1"
            $lastCommitDate = if ($lastCommit -and $lastCommit.Count -gt 0) { $lastCommit[0].committed_date } else { $project.last_activity_at }
            $lastCommitAuthor = if ($lastCommit -and $lastCommit.Count -gt 0) { $lastCommit[0].author_name } else { "Unknown" }
            
            # Calculate days since last activity
            $lastActivityDate = if ($lastCommitDate) { [datetime]$lastCommitDate } else { [datetime]$project.last_activity_at }
            $daysSinceLastActivity = ((Get-Date) - $lastActivityDate).Days
            
            # Create  project report
            $projectReport = [ProjectReport]@{
                ProjectName = $project.name
                ProjectPath = $project.path_with_namespace
                ProjectId = $project.id
                LastActivity = $lastActivityDate.ToString("yyyy-MM-dd")
                DaysSinceLastActivity = $daysSinceLastActivity
                CommitsCount = if ($repoStats.commit_count) { $repoStats.commit_count } else { 0 }
                BranchesCount = if ($branches) { $branches.Count } else { 0 }
                TagsCount = if ($tags) { $tags.Count } else { 0 }
                OpenIssues = $openIssuesCount
                ClosedIssues = $closedIssuesCount
                OpenMergeRequests = $openMRsCount
                MergedMergeRequests = $mergedMRsCount
                ContributorsCount = $contributorsCount
                LastCommitAuthor = $lastCommitAuthor
                LastCommitDate = if ($lastCommit -and $lastCommit.Count -gt 0) { $lastCommit[0].committed_date } else { "N/A" }
                RepositorySize = if ($repoStats.repository_size) { $repoStats.repository_size } else { 0 }
                PipelinesTotal = $pipelinesTotal
                PipelinesSuccess = $pipelinesSuccess
                PipelinesFailed = $pipelinesFailed
                PipelineSuccessRate = $pipelineSuccessRate
                WebURL = $project.web_url
                Namespace = $project.namespace.full_path
                CreatedAt = [datetime]$project.created_at
                DefaultBranch = $project.default_branch
            }
            
            # Calculate health score and adoption level
            $healthScore = Get-ProjectHealth -ProjectData $projectReport
            $adoptionLevel = Get-AdoptionLevel -HealthScore $healthScore -ProjectData $projectReport
            $recommendation = Get-Recommendation -AdoptionLevel $adoptionLevel -ProjectData $projectReport
            
            $projectReport.ProjectHealth = $healthScore
            $projectReport.AdoptionLevel = $adoptionLevel
            $projectReport.Recommendation = $recommendation
            
            $projectReports += $projectReport
            
            Write-Host "   ✓ Processed: $($project.name) (Health: $healthScore, Adoption: $adoptionLevel)" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to process project $($project.name): $($_.Exception.Message)"
            
            # Create minimal project report on error
            $projectReport = [ProjectReport]@{
                ProjectName = $project.name
                ProjectPath = $project.path_with_namespace
                ProjectId = $project.id
                LastActivity = $project.last_activity_at
                DaysSinceLastActivity = ((Get-Date) - [datetime]$project.last_activity_at).Days
                CommitsCount = 0
                OpenIssues = 0
                ClosedIssues = 0
                OpenMergeRequests = 0
                MergedMergeRequests = 0
                ContributorsCount = 0
                PipelinesTotal = 0
                PipelinesSuccess = 0
                PipelinesFailed = 0
                PipelineSuccessRate = 0
                ProjectHealth = 0
                AdoptionLevel = "Unknown"
                Recommendation = "Unable to analyze - data collection failed"
                WebURL = $project.web_url
                Namespace = if ($project.namespace) { $project.namespace.full_path } else { "" }
                CreatedAt = [datetime]$project.created_at
                DefaultBranch = if ($project.default_branch) { $project.default_branch } else { "main" }
            }
            $projectReports += $projectReport
        }
    }
    
    Write-Progress -Id 0 -Completed
    Write-Host "   ✓ Processed $($projectReports.Count) projects successfully" -ForegroundColor Green
} else {
    Write-Host "   ⚠ No project data available" -ForegroundColor Yellow
}

# Generate  reports
Write-Log -Message "Starting  report generation" -Level "Info" -Component "ReportGeneration"

$securityScanResults = @()
$codeQualityReports = @()
$costReports = @()
$teamReports = @()
$techReports = @()
$lifecycleReports = @()
$businessReports = @()
$featureAdoptionReports = @()
$collaborationReports = @()
$devOpsMaturityReports = @()
$adoptionBarrierReports = @()

if ($projectReports.Count -gt 0) {
    if ($IncludeSecurityData) {
        $restoredSecurity = Restore-Checkpoint -Stage "SecurityScans"
        if ($restoredSecurity) {
            $securityScanResults = ConvertTo-Array $restoredSecurity
        } else {
            Start-Checkpoint -Stage "SecurityScans"
            Write-LogProgress -Activity "Collecting security scan data" -Status "Analyzing security posture" -PercentComplete 15 -Step 2 -TotalSteps 12
            $securityScanResults = ConvertTo-Array (Get-ExistingSecurityScanData -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "SecurityScans" -Data $securityScanResults
        }
    } else {
        $securityScanResults = @()
        Complete-Checkpoint -Stage "SecurityScans" -Skipped
    }

    if ($IncludeAllReports) {
        $restoredCodeQuality = Restore-Checkpoint -Stage "CodeQuality"
        if ($restoredCodeQuality) {
            $codeQualityReports = ConvertTo-Array $restoredCodeQuality
        } else {
            Start-Checkpoint -Stage "CodeQuality"
            Write-LogProgress -Activity "Generating code quality reports" -Status "Analyzing code quality metrics" -PercentComplete 25 -Step 3 -TotalSteps 12
            $codeQualityReports = ConvertTo-Array (Generate-CodeQualityReport -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "CodeQuality" -Data $codeQualityReports
        }

        $restoredCostReports = Restore-Checkpoint -Stage "CostAnalysis"
        if ($restoredCostReports) {
            $costReports = ConvertTo-Array $restoredCostReports
        } else {
            Start-Checkpoint -Stage "CostAnalysis"
            Write-LogProgress -Activity "Generating cost analysis reports" -Status "Calculating cost-benefit metrics" -PercentComplete 35 -Step 4 -TotalSteps 12
            $costReports = ConvertTo-Array (Generate-CostAnalysisReport -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "CostAnalysis" -Data $costReports
        }

        $restoredTeamReports = Restore-Checkpoint -Stage "TeamActivity"
        if ($restoredTeamReports) {
            $teamReports = ConvertTo-Array $restoredTeamReports
        } else {
            Start-Checkpoint -Stage "TeamActivity"
            Write-LogProgress -Activity "Generating team activity reports" -Status "Analyzing team engagement" -PercentComplete 45 -Step 5 -TotalSteps 12
            $teamReports = ConvertTo-Array (Generate-TeamActivityReport -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "TeamActivity" -Data $teamReports
        }

        $restoredTechReports = Restore-Checkpoint -Stage "TechnologyStack"
        if ($restoredTechReports) {
            $techReports = ConvertTo-Array $restoredTechReports
        } else {
            Start-Checkpoint -Stage "TechnologyStack"
            Write-LogProgress -Activity "Generating technology stack reports" -Status "Analyzing technology usage" -PercentComplete 55 -Step 6 -TotalSteps 12
            $techReports = ConvertTo-Array (Generate-TechnologyStackReport -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "TechnologyStack" -Data $techReports
        }

        $restoredLifecycleReports = Restore-Checkpoint -Stage "ProjectLifecycle"
        if ($restoredLifecycleReports) {
            $lifecycleReports = ConvertTo-Array $restoredLifecycleReports
        } else {
            Start-Checkpoint -Stage "ProjectLifecycle"
            Write-LogProgress -Activity "Generating project lifecycle reports" -Status "Analyzing project maturity" -PercentComplete 65 -Step 7 -TotalSteps 12
            $lifecycleReports = ConvertTo-Array (Generate-ProjectLifecycleReport -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "ProjectLifecycle" -Data $lifecycleReports
        }

        $restoredBusinessReports = Restore-Checkpoint -Stage "BusinessAlignment"
        if ($restoredBusinessReports) {
            $businessReports = ConvertTo-Array $restoredBusinessReports
        } else {
            Start-Checkpoint -Stage "BusinessAlignment"
            Write-LogProgress -Activity "Generating business alignment reports" -Status "Analyzing business value" -PercentComplete 70 -Step 8 -TotalSteps 12
            $businessReports = ConvertTo-Array (Generate-BusinessAlignmentReport -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "BusinessAlignment" -Data $businessReports
        }

        $restoredFeatureReports = Restore-Checkpoint -Stage "FeatureAdoption"
        if ($restoredFeatureReports) {
            $featureAdoptionReports = ConvertTo-Array $restoredFeatureReports
        } else {
            Start-Checkpoint -Stage "FeatureAdoption"
            Write-LogProgress -Activity "Generating GitLab feature adoption reports" -Status "Analyzing feature utilization" -PercentComplete 75 -Step 9 -TotalSteps 12
            $featureAdoptionReports = ConvertTo-Array (Generate-GitLabFeatureAdoptionReport -ProjectReports $projectReports)
            Complete-Checkpoint -Stage "FeatureAdoption" -Data $featureAdoptionReports
        }

        $restoredCollaborationReports = Restore-Checkpoint -Stage "Collaboration"
        if ($restoredCollaborationReports) {
            $collaborationReports = ConvertTo-Array $restoredCollaborationReports
        } else {
            Start-Checkpoint -Stage "Collaboration"
            Write-LogProgress -Activity "Generating team collaboration reports" -Status "Analyzing collaboration patterns" -PercentComplete 80 -Step 10 -TotalSteps 12
            $collaborationReports = ConvertTo-Array (Generate-TeamCollaborationReport -ProjectReports $projectReports -TeamReports $teamReports)
            Complete-Checkpoint -Stage "Collaboration" -Data $collaborationReports
        }

        $restoredDevOpsReports = Restore-Checkpoint -Stage "DevOpsMaturity"
        if ($restoredDevOpsReports) {
            $devOpsMaturityReports = ConvertTo-Array $restoredDevOpsReports
        } else {
            Start-Checkpoint -Stage "DevOpsMaturity"
            Write-LogProgress -Activity "Generating DevOps maturity reports" -Status "Analyzing DevOps practices" -PercentComplete 85 -Step 11 -TotalSteps 12
            $devOpsMaturityReports = ConvertTo-Array (Generate-DevOpsMaturityReport -ProjectReports $projectReports -FeatureReports $featureAdoptionReports)
            Complete-Checkpoint -Stage "DevOpsMaturity" -Data $devOpsMaturityReports
        }

        $restoredBarrierReports = Restore-Checkpoint -Stage "AdoptionBarriers"
        if ($restoredBarrierReports) {
            $adoptionBarrierReports = ConvertTo-Array $restoredBarrierReports
        } else {
            Start-Checkpoint -Stage "AdoptionBarriers"
            Write-LogProgress -Activity "Generating adoption barriers analysis" -Status "Identifying improvement opportunities" -PercentComplete 90 -Step 12 -TotalSteps 12
            $adoptionBarrierReports = ConvertTo-Array (Generate-AdoptionBarriersReport -ProjectReports $projectReports -FeatureReports $featureAdoptionReports -TeamReports $teamReports)
            Complete-Checkpoint -Stage "AdoptionBarriers" -Data $adoptionBarrierReports
        }

        Export-EnhancedCSVReports -ProjectReports $projectReports -SecurityScanResults $securityScanResults -CodeQualityReports $codeQualityReports -CostReports $costReports -TeamReports $teamReports -TechReports $techReports -LifecycleReports $lifecycleReports -BusinessReports $businessReports -FeatureAdoptionReports $featureAdoptionReports -CollaborationReports $collaborationReports -DevOpsMaturityReports $devOpsMaturityReports -AdoptionBarrierReports $adoptionBarrierReports -OutputPath $OutputPath -ReportDate $reportDate
    }
    else {
        $codeQualityReports = @()
        $costReports = @()
        $teamReports = @()
        $techReports = @()
        $lifecycleReports = @()
        $businessReports = @()
        $featureAdoptionReports = @()
        $collaborationReports = @()
        $devOpsMaturityReports = @()
        $adoptionBarrierReports = @()
        
        Complete-Checkpoint -Stage "CodeQuality" -Skipped
        Complete-Checkpoint -Stage "CostAnalysis" -Skipped
        Complete-Checkpoint -Stage "TeamActivity" -Skipped
        Complete-Checkpoint -Stage "TechnologyStack" -Skipped
        Complete-Checkpoint -Stage "ProjectLifecycle" -Skipped
        Complete-Checkpoint -Stage "BusinessAlignment" -Skipped
        Complete-Checkpoint -Stage "FeatureAdoption" -Skipped
        Complete-Checkpoint -Stage "Collaboration" -Skipped
        Complete-Checkpoint -Stage "DevOpsMaturity" -Skipped
        Complete-Checkpoint -Stage "AdoptionBarriers" -Skipped
    }
}
else {
    Write-Log -Message "No project data - skipping additional reports" -Level "Warning" -Component "ReportGeneration"
    
    $securityScanResults = @()
    $codeQualityReports = @()
    $costReports = @()
    $teamReports = @()
    $techReports = @()
    $lifecycleReports = @()
    $businessReports = @()
    $featureAdoptionReports = @()
    $collaborationReports = @()
    $devOpsMaturityReports = @()
    $adoptionBarrierReports = @()
    
    Complete-Checkpoint -Stage "SecurityScans" -Skipped
    Complete-Checkpoint -Stage "CodeQuality" -Skipped
    Complete-Checkpoint -Stage "CostAnalysis" -Skipped
    Complete-Checkpoint -Stage "TeamActivity" -Skipped
    Complete-Checkpoint -Stage "TechnologyStack" -Skipped
    Complete-Checkpoint -Stage "ProjectLifecycle" -Skipped
    Complete-Checkpoint -Stage "BusinessAlignment" -Skipped
    Complete-Checkpoint -Stage "FeatureAdoption" -Skipped
    Complete-Checkpoint -Stage "Collaboration" -Skipped
    Complete-Checkpoint -Stage "DevOpsMaturity" -Skipped
    Complete-Checkpoint -Stage "AdoptionBarriers" -Skipped
}

# Generate the final dashboard using the external template
Write-Log -Message "Generating  dashboard from template..." -Level "Info" -Component "DashboardGeneration"
$executionTime = (Get-Date) - $scriptStartTime

$dashboardHTML = New-ConsolidatedDashboardFromTemplate `
    -ProjectReports $projectReports `
    -SecurityScanResults $securityScanResults `
    -CodeQualityReports $codeQualityReports `
    -CostReports $costReports `
    -TeamReports $teamReports `
    -TechReports $techReports `
    -LifecycleReports $lifecycleReports `
    -BusinessReports $businessReports `
    -FeatureAdoptionReports $featureAdoptionReports `
    -CollaborationReports $collaborationReports `
    -DevOpsMaturityReports $devOpsMaturityReports `
    -AdoptionBarrierReports $adoptionBarrierReports `
    -ReportDate $reportDate `
    -DaysBack $DaysBack `
    -ExecutionTime $executionTime

if ($dashboardHTML) {
    # Save the dashboard
    $dashboardPath = Join-Path $OutputPath "GitLab-Dashboard-$reportDate.html"
    $dashboardHTML | Out-File -FilePath $dashboardPath -Encoding UTF8

    Write-Log -Message "Dashboard generated successfully: $dashboardPath" -Level "Success" -Component "DashboardGeneration"
    Write-Log -Message "Execution Time: $([math]::Round($executionTime.TotalMinutes, 2)) minutes" -Level "Info" -Component "Performance"
    
    # Log adoption insights
    if ($featureAdoptionReports.Count -gt 0) {
        $avgAdoptionScore = ($featureAdoptionReports | Measure-Object -Property FeatureAdoptionScore -Average).Average
        $excellentAdoption = ($featureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Excellent" }).Count
        $needsImprovement = ($adoptionBarrierReports | Where-Object { $_.BarrierSeverity -ge 5 }).Count
        
        Write-Log -Message "ADOPTION INSIGHTS:" -Level "Info" -Component "AdoptionSummary"
        Write-Log -Message "- Average Feature Adoption Score: $([math]::Round($avgAdoptionScore, 1))/100" -Level "Info" -Component "AdoptionSummary"
        Write-Log -Message "- Projects with Excellent Adoption: $excellentAdoption/$($featureAdoptionReports.Count)" -Level "Info" -Component "AdoptionSummary"
        Write-Log -Message "- Projects Needing Immediate Support: $needsImprovement" -Level "Info" -Component "AdoptionSummary"
    }
    
} else {
    Write-Log -Message "Failed to generate dashboard" -Level "Error" -Component "DashboardGeneration"
}

Publish-CheckpointSummary


