using module ./modules/GitLab.Types.psm1
<#
This script coordinates the GitLab reporting workflow using modular components.
#>

param(
    [string]$GitLabURL,
    [string]$AccessToken,
    [string]$OutputPath = '.\report',
    [int]$DaysBack = 360,
    [switch]$IncludeSecurityData = $true,
    [switch]$IncludeAllReports = $true,
    [ValidateSet("Minimal","Normal","Verbose","Debug")]
    [string]$LogLevel = 'Normal',
    [switch]$NonInteractive,
    [switch]$EnableFileLogging,
    [switch]$ForceRestart
)

Import-Module "$PSScriptRoot/modules/GitLab.Logging.psm1" -Force
Import-Module "$PSScriptRoot/modules/GitLab.Workflow.psm1" -Force
Import-Module "$PSScriptRoot/modules/GitLab.ApiClient.psm1" -Force
Import-Module "$PSScriptRoot/modules/GitLab.Projects.psm1" -Force
Import-Module "$PSScriptRoot/modules/GitLab.Analytics.psm1" -Force
Import-Module "$PSScriptRoot/modules/GitLab.Exports.psm1" -Force
Import-Module "$PSScriptRoot/modules/GitLab.Dashboard.psm1" -Force

$headers = @{
    'PRIVATE-TOKEN' = $AccessToken
    'Content-Type'  = 'application/json'
}
$global:GitLabURL = $GitLabURL
$global:GitLabHeaders = $headers
$global:headers = $headers

$reportDate = Get-Date -Format 'yyyy-MM-dd'
$scriptStartTime = Get-Date

if (!(Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$logFilePath = if ($EnableFileLogging) { Join-Path $OutputPath "GitLab-Dashboard-$reportDate.log" } else { $null }
Initialize-GitLabLogging -LogLevel $LogLevel -NonInteractive:$NonInteractive -EnableFileLogging:$EnableFileLogging -LogFilePath $logFilePath
Write-Log -Message 'GitLab Comprehensive Management Dashboard - Starting' -Level 'Info' -Component 'Init'
Write-Log -Message "Log Level: $LogLevel" -Level 'Info' -Component 'Init'
Write-Log -Message "Non-Interactive Mode: $($NonInteractive.IsPresent)" -Level 'Info' -Component 'Init'
Write-Log -Message "Output Path: $OutputPath" -Level 'Info' -Component 'Init'
Write-Log -Message "Days Back: $DaysBack" -Level 'Info' -Component 'Init'

function Update-OverallProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete,
        [int]$Step,
        [int]$TotalSteps
    )
    Write-LogProgress -Activity 'GitLab Comprehensive Dashboard' -Status $Status -PercentComplete $PercentComplete -Step $Step -TotalSteps $TotalSteps
}

$checkpointStageLabels = [ordered]@{
    'ProjectReports'    = 'Project data collection'
    'SecurityScans'     = 'Security scan aggregation'
    'CodeQuality'       = 'Code quality analysis'
    'CostAnalysis'      = 'Cost analysis'
    'TeamActivity'      = 'Team activity insights'
    'TechnologyStack'   = 'Technology stack analysis'
    'ProjectLifecycle'  = 'Project lifecycle assessment'
    'BusinessAlignment' = 'Business alignment assessment'
    'FeatureAdoption'   = 'Feature adoption analysis'
    'Collaboration'     = 'Collaboration analysis'
    'DevOpsMaturity'    = 'DevOps maturity assessment'
    'AdoptionBarriers'  = 'Adoption barriers analysis'
}

$hostTag = try { ([uri]$GitLabURL).Host } catch { $GitLabURL }
if (-not $hostTag) { $hostTag = 'gitlab' }
$hostTag = ($hostTag -replace '[^a-zA-Z0-9\-\.]', '-')
$runKey = "{0}-{1}-d{2}-sec{3}-all{4}" -f $reportDate, $hostTag, $DaysBack, [int][bool]$IncludeSecurityData, [int][bool]$IncludeAllReports
$checkpointSignature = @{
    GitLabURL = $GitLabURL
    DaysBack = $DaysBack
    IncludeSecurityData = [bool]$IncludeSecurityData
    IncludeAllReports = [bool]$IncludeAllReports
}
$script:CheckpointContext = Initialize-GitLabCheckpoints -OutputPath $OutputPath -RunKey $runKey -Signature $checkpointSignature -ForceRestart:$ForceRestart

function Get-StageLabel {
    param([string]$Stage)
    if ($checkpointStageLabels.Contains($Stage)) { return $checkpointStageLabels[$Stage] }
    return $Stage
}

function Start-Checkpoint {
    param([string]$Stage)
    Start-GitLabCheckpoint -Context $script:CheckpointContext -Stage $Stage -Label (Get-StageLabel $Stage)
}

function Complete-Checkpoint {
    param(
        [string]$Stage,
        $Data,
        [switch]$FromCache,
        [switch]$Skipped
    )

    if ($Skipped) {
        Save-GitLabCheckpoint -Context $script:CheckpointContext -Stage $Stage -Skipped
        return
    }

    if ($FromCache) {
        Save-GitLabCheckpoint -Context $script:CheckpointContext -Stage $Stage -Restored
        return
    }

    if ($PSBoundParameters.ContainsKey('Data')) {
        Save-GitLabCheckpoint -Context $script:CheckpointContext -Stage $Stage -Data $Data
    } else {
        Save-GitLabCheckpoint -Context $script:CheckpointContext -Stage $Stage
    }
}

function Restore-Checkpoint {
    param([string]$Stage)
    $data = Restore-GitLabCheckpoint -Context $script:CheckpointContext -Stage $Stage -Label (Get-StageLabel $Stage)
    if ($null -ne $data) {
        Complete-Checkpoint -Stage $Stage -FromCache
    }
    return $data
}

function Publish-CheckpointSummary {
    Publish-GitLabCheckpointSummary -Context $script:CheckpointContext -StageLabels $checkpointStageLabels
}

function ConvertTo-Array {
    param($Data)
    return ConvertTo-GitLabArray -Data $Data
}

function Test-GitLabConnection {
    param([string]$GitLabURL = 'http://localhost', [string]$AccessToken = 'glpat-bkOzctpmnpqfB10rZWdCHW86MQp1OjEH.01.0w1l4gyho')
    try {
        Write-Log -Message "Testing connection to GitLab instance at $GitLabURL" -Level 'Info' -Component 'Connection'
        $testHeaders = @{'PRIVATE-TOKEN' = $AccessToken}
        $uri = "$GitLabURL/api/v4/version"
        $version = Invoke-RestMethod -Uri $uri -Headers $testHeaders -TimeoutSec 30
        Write-Log -Message "Successfully connected to GitLab $($version.version)" -Level 'Success' -Component 'Connection'
        return $true
    } catch {
        Write-Log -Message "Failed to connect to GitLab: $($_.Exception.Message)" -Level 'Error' -Component 'Connection'
        Write-Log -Message 'Please check GitLab URL, access token permissions, and network connectivity.' -Level 'Warning' -Component 'Connection'
        return $false
    }
}

$script:ApiClient = New-GitLabApiClient -BaseUri ([uri]$GitLabURL) -AccessToken $AccessToken -DefaultPerPage 100 -MaxPages 100 -MaxRetries 3 -InitialDelayMs 250 -MaxDelayMs 16000 -MinDelayBetweenCallsMs 200

Write-LogSection -Title 'GitLab Comprehensive Management Dashboard - Template Edition' -Symbol '='
Write-Log -Message 'Starting GitLab dashboard generation' -Level 'Info' -Component 'Main'
Write-Log -Message "GitLab URL: $GitLabURL" -Level 'Debug' -Component 'Main'
Write-Log -Message "Include Security Data: $IncludeSecurityData" -Level 'Debug' -Component 'Main'
Write-Log -Message "Include All Reports: $IncludeAllReports" -Level 'Debug' -Component 'Main'

if (-not (Test-GitLabConnection -GitLabURL $GitLabURL -AccessToken $AccessToken)) { return }

Write-Log -Message 'Starting project data collection' -Level 'Info' -Component 'DataCollection'
$projectReports = Restore-Checkpoint -Stage 'ProjectReports'
if ($projectReports) {
    $projectReports = ConvertTo-Array $projectReports
    Write-Log -Message "Restored $($projectReports.Count) project records from checkpoint" -Level 'Info' -Component 'DataCollection'
} else {
    Start-Checkpoint -Stage 'ProjectReports'
    $progressCallback = {
        param($Activity, $Status, $PercentComplete, $Step, $TotalSteps)
        Update-OverallProgress -Activity $Activity -Status $Status -PercentComplete $PercentComplete -Step $Step -TotalSteps $TotalSteps
    }
    $projectReports = Get-GitLabProjectReports -ApiClient $script:ApiClient -DaysBack $DaysBack -UpdateProgress $progressCallback
    if (-not $projectReports -or $projectReports.Count -eq 0) {
        Write-Error 'No projects returned from GitLab API. Aborting. Ensure the token has appropriate scope and project visibility.'
        return
    }
    Write-Log -Message "Processed $($projectReports.Count) projects successfully" -Level 'Success' -Component 'DataCollection'
    Write-Host "   ✓ Processed $($projectReports.Count) projects successfully" -ForegroundColor Green
    Complete-Checkpoint -Stage 'ProjectReports' -Data $projectReports
}

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

if ($IncludeSecurityData) {
    $restoredSecurity = Restore-Checkpoint -Stage 'SecurityScans'
    if ($restoredSecurity) {
        $securityScanResults = ConvertTo-Array $restoredSecurity
    } else {
        Start-Checkpoint -Stage 'SecurityScans'
        Write-LogProgress -Activity 'Collecting security scan data' -Status 'Analyzing security posture' -PercentComplete 15 -Step 2 -TotalSteps 12
        $securityScanResults = Get-ExistingSecurityScanData -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'SecurityScans' -Data $securityScanResults
    }
} else {
    Complete-Checkpoint -Stage 'SecurityScans' -Skipped
}

if ($IncludeAllReports) {
    $restoredCodeQuality = Restore-Checkpoint -Stage 'CodeQuality'
    if ($restoredCodeQuality) {
        $codeQualityReports = ConvertTo-Array $restoredCodeQuality
    } else {
        Start-Checkpoint -Stage 'CodeQuality'
        Write-LogProgress -Activity 'Generating code quality reports' -Status 'Analyzing code quality metrics' -PercentComplete 25 -Step 3 -TotalSteps 12
        $codeQualityReports = Generate-CodeQualityReport -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'CodeQuality' -Data $codeQualityReports
    }

    $restoredCost = Restore-Checkpoint -Stage 'CostAnalysis'
    if ($restoredCost) {
        $costReports = ConvertTo-Array $restoredCost
    } else {
        Start-Checkpoint -Stage 'CostAnalysis'
        Write-LogProgress -Activity 'Generating cost analysis reports' -Status 'Calculating cost-benefit metrics' -PercentComplete 35 -Step 4 -TotalSteps 12
        $costReports = Generate-CostAnalysisReport -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'CostAnalysis' -Data $costReports
    }

    $restoredTeam = Restore-Checkpoint -Stage 'TeamActivity'
    if ($restoredTeam) {
        $teamReports = ConvertTo-Array $restoredTeam
    } else {
        Start-Checkpoint -Stage 'TeamActivity'
        Write-LogProgress -Activity 'Generating team activity reports' -Status 'Analyzing team engagement' -PercentComplete 45 -Step 5 -TotalSteps 12
        $teamReports = Generate-TeamActivityReport -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'TeamActivity' -Data $teamReports
    }

    $restoredTech = Restore-Checkpoint -Stage 'TechnologyStack'
    if ($restoredTech) {
        $techReports = ConvertTo-Array $restoredTech
    } else {
        Start-Checkpoint -Stage 'TechnologyStack'
        Write-LogProgress -Activity 'Generating technology stack reports' -Status 'Analyzing technology usage' -PercentComplete 55 -Step 6 -TotalSteps 12
        $techReports = Generate-TechnologyStackReport -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'TechnologyStack' -Data $techReports
    }

    $restoredLifecycle = Restore-Checkpoint -Stage 'ProjectLifecycle'
    if ($restoredLifecycle) {
        $lifecycleReports = ConvertTo-Array $restoredLifecycle
    } else {
        Start-Checkpoint -Stage 'ProjectLifecycle'
        Write-LogProgress -Activity 'Generating project lifecycle reports' -Status 'Analyzing project maturity' -PercentComplete 65 -Step 7 -TotalSteps 12
        $lifecycleReports = Generate-ProjectLifecycleReport -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'ProjectLifecycle' -Data $lifecycleReports
    }

    $restoredBusiness = Restore-Checkpoint -Stage 'BusinessAlignment'
    if ($restoredBusiness) {
        $businessReports = ConvertTo-Array $restoredBusiness
    } else {
        Start-Checkpoint -Stage 'BusinessAlignment'
        Write-LogProgress -Activity 'Generating business alignment reports' -Status 'Analyzing business value' -PercentComplete 70 -Step 8 -TotalSteps 12
        $businessReports = Generate-BusinessAlignmentReport -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'BusinessAlignment' -Data $businessReports
    }

    $restoredFeature = Restore-Checkpoint -Stage 'FeatureAdoption'
    if ($restoredFeature) {
        $featureAdoptionReports = ConvertTo-Array $restoredFeature
    } else {
        Start-Checkpoint -Stage 'FeatureAdoption'
        Write-LogProgress -Activity 'Generating GitLab feature adoption reports' -Status 'Analyzing feature utilization' -PercentComplete 75 -Step 9 -TotalSteps 12
        $featureAdoptionReports = Generate-GitLabFeatureAdoptionReport -ProjectReports $projectReports
        Complete-Checkpoint -Stage 'FeatureAdoption' -Data $featureAdoptionReports
    }

    $restoredCollaboration = Restore-Checkpoint -Stage 'Collaboration'
    if ($restoredCollaboration) {
        $collaborationReports = ConvertTo-Array $restoredCollaboration
    } else {
        Start-Checkpoint -Stage 'Collaboration'
        Write-LogProgress -Activity 'Generating team collaboration reports' -Status 'Analyzing collaboration patterns' -PercentComplete 80 -Step 10 -TotalSteps 12
        $collaborationReports = Generate-TeamCollaborationReport -ProjectReports $projectReports -TeamReports $teamReports
        Complete-Checkpoint -Stage 'Collaboration' -Data $collaborationReports
    }

    $restoredDevOps = Restore-Checkpoint -Stage 'DevOpsMaturity'
    if ($restoredDevOps) {
        $devOpsMaturityReports = ConvertTo-Array $restoredDevOps
    } else {
        Start-Checkpoint -Stage 'DevOpsMaturity'
        Write-LogProgress -Activity 'Generating DevOps maturity reports' -Status 'Analyzing DevOps practices' -PercentComplete 85 -Step 11 -TotalSteps 12
        $devOpsMaturityReports = Generate-DevOpsMaturityReport -ProjectReports $projectReports -FeatureReports $featureAdoptionReports
        Complete-Checkpoint -Stage 'DevOpsMaturity' -Data $devOpsMaturityReports
    }

    $restoredBarriers = Restore-Checkpoint -Stage 'AdoptionBarriers'
    if ($restoredBarriers) {
        $adoptionBarrierReports = ConvertTo-Array $restoredBarriers
    } else {
        Start-Checkpoint -Stage 'AdoptionBarriers'
        Write-LogProgress -Activity 'Generating adoption barriers analysis' -Status 'Identifying improvement opportunities' -PercentComplete 90 -Step 12 -TotalSteps 12
        $adoptionBarrierReports = Generate-AdoptionBarriersReport -ProjectReports $projectReports -FeatureReports $featureAdoptionReports -TeamReports $teamReports
        Complete-Checkpoint -Stage 'AdoptionBarriers' -Data $adoptionBarrierReports
    }
} else {
    foreach ($stage in 'CodeQuality','CostAnalysis','TeamActivity','TechnologyStack','ProjectLifecycle','BusinessAlignment','FeatureAdoption','Collaboration','DevOpsMaturity','AdoptionBarriers') {
        Complete-Checkpoint -Stage $stage -Skipped
    }
}

try {
    Write-Log -Message 'Exporting enhanced CSV reports...' -Level 'Info' -Component 'CSV'
    Export-EnhancedCSVReports -ProjectReports $projectReports -SecurityScanResults $securityScanResults -CodeQualityReports $codeQualityReports -CostReports $costReports -TeamReports $teamReports -TechReports $techReports -LifecycleReports $lifecycleReports -BusinessReports $businessReports -FeatureAdoptionReports $featureAdoptionReports -CollaborationReports $collaborationReports -DevOpsMaturityReports $devOpsMaturityReports -AdoptionBarrierReports $adoptionBarrierReports -OutputPath $OutputPath -ReportDate $reportDate
} catch {
    Write-Log -Message "Failed to export enhanced CSV reports: $($_.Exception.Message)" -Level 'Error' -Component 'CSV'
}

Write-Log -Message 'Generating comprehensive dashboard from template...' -Level 'Info' -Component 'Dashboard'
$executionTime = (Get-Date) - $scriptStartTime
$templatePath = Join-Path $PSScriptRoot 'gitlab-report-template.html'
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
    -ExecutionTime $executionTime `
    -TemplatePath $templatePath

if ($dashboardHTML) {
    $dashboardPath = Join-Path $OutputPath "GitLab-Dashboard-$reportDate.html"
    $dashboardHTML | Out-File -FilePath $dashboardPath -Encoding UTF8
    Write-Log -Message "Dashboard generated successfully: $dashboardPath" -Level 'Success' -Component 'Dashboard'
    Write-Log -Message "Execution Time: $([math]::Round($executionTime.TotalMinutes, 2)) minutes" -Level 'Info' -Component 'Performance'
}
else {
    Write-Log -Message 'Failed to generate dashboard' -Level 'Error' -Component 'Dashboard'
}

Publish-CheckpointSummary





