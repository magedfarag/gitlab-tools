<# gitlab-insights-setup.ps1
# Description: Pushes GitLab Insights configuration to projects and enables analytics
# This script deploys the insights.yml file and configures analytics for better visibility
# Usage: 
 .\gitlab-insights-setup.ps1 -GroupId 6 -EnableAnalytics
 
 .\gitlab-insights-setup.ps1 -GroupId 123 `
               -GitLabURL "https://gitlab.example.com" `
               -AccessToken "your_access_token_here" `
               -EnableAnalytics -DeployToAllProjects

# Parameters:
# -GroupId: GitLab group ID to deploy insights configuration
# -GitLabURL: GitLab instance URL (default: http://localhost)
# -AccessToken: GitLab access token with appropriate permissions
# -EnableAnalytics: Enable analytics and insights features
# -DeployToAllProjects: Deploy insights to all projects in the group
# -ProjectIds: Specific project IDs to deploy to (comma-separated)
# -ForceUpdate: Overwrite existing insights configuration

#>

param(
    [string]$GitLabURL,
    [string]$AccessToken,
    [Parameter(Mandatory=$true)]
    [string]$GroupId = 6,
    [switch]$EnableAnalytics,
    [switch]$DeployToAllProjects,
    [string]$ProjectIds = "",
    [switch]$ForceUpdate,
    [string]$InsightsFilePath = ".\.gitlab\insights.yml"
)

# Initialize counters
$script:successCount = 0
$script:failedCount = 0
$script:skippedCount = 0
$script:processedProjects = @()

# Headers for API calls
$headers = @{
    "PRIVATE-TOKEN" = $AccessToken
    "Content-Type" = "application/json"
}

# Function to standardize API calls with error handling
function Invoke-GitLabAPI {
    param($Uri, $Method = 'Get', $Body = $null, $ExpectedErrors = @())
    try {
        $params = @{
            Uri = $Uri
            Method = $Method
            Headers = $headers
        }
        if ($Body) { $params['Body'] = $Body }
        $response = Invoke-RestMethod @params
        return @{ Success = $true; Data = $response; StatusCode = 0 }
    }
    catch {
        $statusCode = 0
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        
        if ($statusCode -in $ExpectedErrors) {
            Write-Warning "Expected condition encountered (HTTP $statusCode) for $Uri :: $($_.Exception.Message)"
            return @{ Success = $false; Data = $null; StatusCode = $statusCode; IsExpected = $true }
        }
        
        Write-Error "API call failed for $Uri :: $($_.Exception.Message)"
        return @{ Success = $false; Data = $null; StatusCode = $statusCode; IsExpected = $false }
    }
}

# Function to URL encode file paths for GitLab API
function Get-UrlEncodedPath {
    param([string]$Path)
    $encoded = ""
    foreach ($char in $Path.ToCharArray()) {
        switch ($char) {
            '/' { $encoded += '%2F' }
            '.' { $encoded += '%2E' }
            '-' { $encoded += '%2D' }
            ' ' { $encoded += '%20' }
            default { $encoded += $char }
        }
    }
    return $encoded
}

# Function to deploy insights to a specific project
function Deploy-InsightsToProject {
    param(
        [object]$Project,
        [string]$InsightsContent
    )
    
    Write-Host "   → Processing project: $($Project.name) (ID: $($Project.id))" -ForegroundColor Gray
    
    # Check if insights file already exists
    $insightsFilePath = ".gitlab/insights.yml"
    $encodedFilePath = Get-UrlEncodedPath -Path $insightsFilePath
    $getFileUri = "$GitLabURL/api/v4/projects/$($Project.id)/repository/files/$encodedFilePath"
    
    $existingFileResult = Invoke-GitLabAPI -Uri $getFileUri -Method Get -ExpectedErrors @(404, 400)
    $fileExists = $existingFileResult.Success
    
    if ($fileExists -and -not $ForceUpdate) {
        Write-Host "     ⚠ Insights file already exists - use -ForceUpdate to overwrite" -ForegroundColor Yellow
        $script:skippedCount++
        return $false
    }
    
    # Get project info for default branch
    $projectInfoUri = "$GitLabURL/api/v4/projects/$($Project.id)"
    $projectInfo = Invoke-GitLabAPI -Uri $projectInfoUri -Method Get -ExpectedErrors @(500, 404, 403)
    $defaultBranch = if ($projectInfo.Success -and $projectInfo.Data.default_branch) { 
        $projectInfo.Data.default_branch 
    } else { 
        "main" 
    }
    
    # Encode the insights content
    $encodedContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($InsightsContent))
    
    if ($fileExists) {
        # Update existing file
        $updateFileUri = "$GitLabURL/api/v4/projects/$($Project.id)/repository/files/$encodedFilePath"
        $updateBody = @{
            branch = $defaultBranch
            content = $encodedContent
            commit_message = "Update GitLab Insights configuration with enhanced analytics"
        } | ConvertTo-Json
        
        $updateResult = Invoke-GitLabAPI -Uri $updateFileUri -Method Put -Body $updateBody -ExpectedErrors @(400, 403)
        
        if ($updateResult.Success) {
            Write-Host "     ✓ Updated insights configuration" -ForegroundColor Green
            $script:successCount++
            return $true
        } else {
            Write-Host "     ✗ Failed to update insights file" -ForegroundColor Red
            $script:failedCount++
            return $false
        }
    } else {
        # Create new file
        $createFileUri = "$GitLabURL/api/v4/projects/$($Project.id)/repository/files/$encodedFilePath"
        $createBody = @{
            branch = $defaultBranch
            content = $encodedContent
            commit_message = "Add GitLab Insights configuration for enhanced analytics and monitoring"
        } | ConvertTo-Json
        
        $createResult = Invoke-GitLabAPI -Uri $createFileUri -Method Post -Body $createBody -ExpectedErrors @(400, 403)
        
        if ($createResult.Success) {
            Write-Host "     ✓ Created insights configuration" -ForegroundColor Green
            $script:successCount++
            return $true
        } else {
            Write-Host "     ✗ Failed to create insights file" -ForegroundColor Red
            $script:failedCount++
            return $false
        }
    }
}

# Function to enable analytics features
function Enable-ProjectAnalytics {
    param([object]$Project)
    
    Write-Host "   → Enabling analytics for: $($Project.name)" -ForegroundColor Gray
    
    # Enable project-level analytics features
    $updateProjectUri = "$GitLabURL/api/v4/projects/$($Project.id)"
    $analyticsSettings = @{
        analytics_access_level = "enabled"
        repository_access_level = "enabled"
        issues_access_level = "enabled"
        merge_requests_access_level = "enabled"
        builds_access_level = "enabled"
        operations_access_level = "enabled"
        security_and_compliance_access_level = "enabled"
    } | ConvertTo-Json
    
    $enableResult = Invoke-GitLabAPI -Uri $updateProjectUri -Method Put -Body $analyticsSettings -ExpectedErrors @(400, 403, 404)
    
    if ($enableResult.Success) {
        Write-Host "     ✓ Analytics enabled" -ForegroundColor Green
        return $true
    } elseif ($enableResult.IsExpected) {
        Write-Host "     ⚠ Analytics settings may already be configured" -ForegroundColor Yellow
        return $true
    } else {
        Write-Host "     ✗ Failed to enable analytics" -ForegroundColor Red
        return $false
    }
}

# Function to configure group-level insights
function Enable-GroupInsights {
    param([string]$GroupId)
    
    Write-Host "   → Configuring group-level insights..." -ForegroundColor Gray
    
    # Enable group-level analytics
    $updateGroupUri = "$GitLabURL/api/v4/groups/$GroupId"
    $groupSettings = @{
        project_creation_level = "maintainer"
        visibility = "internal"
        request_access_enabled = $true
        analytics_access_level = "enabled"
    } | ConvertTo-Json
    
    $groupResult = Invoke-GitLabAPI -Uri $updateGroupUri -Method Put -Body $groupSettings -ExpectedErrors @(400, 403, 404)
    
    if ($groupResult.Success -or $groupResult.IsExpected) {
        Write-Host "     ✓ Group insights configured" -ForegroundColor Green
        return $true
    } else {
        Write-Host "     ⚠ Group insights may need manual configuration" -ForegroundColor Yellow
        return $false
    }
}

# Main execution starts here
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "GITLAB INSIGHTS DEPLOYMENT & ANALYTICS ENABLEMENT" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan

# Step 1: Validate insights file exists
Write-Host "`nStep 1: Validating insights configuration file..." -ForegroundColor Cyan

if (-not (Test-Path $InsightsFilePath)) {
    Write-Error "Insights file not found at: $InsightsFilePath"
    Write-Host "Please ensure the .gitlab/insights.yml file exists before running this script." -ForegroundColor Red
    exit 1
}

$insightsContent = Get-Content -Path $InsightsFilePath -Raw
Write-Host "   ✓ Insights file loaded ($($insightsContent.Length) characters)" -ForegroundColor Green

# Step 2: Get target projects
Write-Host "`nStep 2: Identifying target projects..." -ForegroundColor Cyan

$targetProjects = @()

if ($DeployToAllProjects) {
    # Get all projects in the group
    Write-Host "   → Getting all projects in group $GroupId..." -ForegroundColor Gray
    $getProjectsUri = "$GitLabURL/api/v4/groups/$GroupId/projects?per_page=100&include_subgroups=true"
    $projectsResult = Invoke-GitLabAPI -Uri $getProjectsUri -Method Get
    
    if ($projectsResult.Success -and $projectsResult.Data) {
        $targetProjects = $projectsResult.Data | Where-Object { $_.name -notlike "*security-policies*" }
        Write-Host "   ✓ Found $($targetProjects.Count) projects to process" -ForegroundColor Green
    } else {
        Write-Error "Failed to retrieve projects from group $GroupId"
        exit 1
    }
} elseif ($ProjectIds) {
    # Get specific projects by ID
    $projectIdList = $ProjectIds -split ","
    Write-Host "   → Getting specified projects: $ProjectIds" -ForegroundColor Gray
    
    foreach ($projectId in $projectIdList) {
        $projectId = $projectId.Trim()
        $getProjectUri = "$GitLabURL/api/v4/projects/$projectId"
        $projectResult = Invoke-GitLabAPI -Uri $getProjectUri -Method Get -ExpectedErrors @(404, 403)
        
        if ($projectResult.Success) {
            $targetProjects += $projectResult.Data
        } else {
            Write-Warning "Could not access project ID: $projectId"
        }
    }
    
    Write-Host "   ✓ Found $($targetProjects.Count) accessible projects" -ForegroundColor Green
} else {
    Write-Error "Please specify either -DeployToAllProjects or -ProjectIds parameter"
    exit 1
}

if ($targetProjects.Count -eq 0) {
    Write-Error "No projects found to process"
    exit 1
}

# Step 3: Deploy insights configuration
Write-Host "`nStep 3: Deploying insights configuration..." -ForegroundColor Cyan

foreach ($project in $targetProjects) {
    $deployResult = Deploy-InsightsToProject -Project $project -InsightsContent $insightsContent
    
    if ($deployResult) {
        $script:processedProjects += @{
            Name = $project.name
            Id = $project.id
            Status = "Success"
            InsightsUrl = "$($project.web_url)/-/insights"
        }
    }
    
    # Small delay to avoid API rate limiting
    Start-Sleep -Milliseconds 200
}

# Step 4: Enable analytics features
if ($EnableAnalytics) {
    Write-Host "`nStep 4: Enabling analytics features..." -ForegroundColor Cyan
    
    # Enable group-level insights
    Enable-GroupInsights -GroupId $GroupId
    
    # Enable project-level analytics
    foreach ($project in $targetProjects) {
        Enable-ProjectAnalytics -Project $project
        Start-Sleep -Milliseconds 200
    }
}

# Step 5: Summary and verification
Write-Host "`n" + "=" * 80 -ForegroundColor Green
Write-Host "INSIGHTS DEPLOYMENT COMPLETED!" -ForegroundColor Green
Write-Host "=" * 80 -ForegroundColor Green

Write-Host "`nDeployment Summary:" -ForegroundColor Cyan
Write-Host "  ✓ Successfully deployed: $script:successCount projects" -ForegroundColor Green
Write-Host "  ⚠ Skipped: $script:skippedCount projects" -ForegroundColor Yellow
Write-Host "  ✗ Failed: $script:failedCount projects" -ForegroundColor Red
Write-Host "  📊 Total processed: $($targetProjects.Count) projects" -ForegroundColor Cyan

if ($script:processedProjects.Count -gt 0) {
    Write-Host "`nSuccessfully configured projects:" -ForegroundColor Green
    foreach ($project in $script:processedProjects) {
        if ($project.Status -eq "Success") {
            Write-Host "  • $($project.Name) - Insights: $($project.InsightsUrl)" -ForegroundColor White
        }
    }
}

# Access URLs
Write-Host "`nAccess Your Analytics:" -ForegroundColor Cyan
Write-Host "• Group Analytics: $GitLabURL/groups/$GroupId/-/analytics" -ForegroundColor White
Write-Host "• Group Insights: $GitLabURL/groups/$GroupId/-/insights" -ForegroundColor White
Write-Host "• Security Dashboard: $GitLabURL/groups/$GroupId/-/security/discover" -ForegroundColor White

if ($EnableAnalytics) {
    Write-Host "`nAnalytics Features Enabled:" -ForegroundColor Yellow
    Write-Host "• Issue Analytics - Track issue creation and resolution" -ForegroundColor White
    Write-Host "• Merge Request Analytics - Monitor MR throughput and review times" -ForegroundColor White
    Write-Host "• Repository Analytics - Code contribution and commit statistics" -ForegroundColor White
    Write-Host "• CI/CD Analytics - Pipeline success rates and performance" -ForegroundColor White
    Write-Host "• Security Analytics - Vulnerability trends and compliance" -ForegroundColor White
}

# Configuration tips
Write-Host "`nConfiguration Tips:" -ForegroundColor Cyan
Write-Host "1. Customize chart colors and thresholds in insights.yml" -ForegroundColor White
Write-Host "2. Set up Slack/email notifications for security alerts" -ForegroundColor White
Write-Host "3. Configure environment variables for integrations" -ForegroundColor White
Write-Host "4. Review access controls for sensitive analytics data" -ForegroundColor White
Write-Host "5. Schedule regular reviews of security and compliance metrics" -ForegroundColor White

# Next steps
Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Wait 5-10 minutes for data to populate in dashboards" -ForegroundColor White
Write-Host "2. Visit the insights URLs above to view your analytics" -ForegroundColor White
Write-Host "3. Configure notification endpoints (Slack, email, JIRA)" -ForegroundColor White
Write-Host "4. Set up automated reporting for stakeholders" -ForegroundColor White
Write-Host "5. Train team members on using the new analytics features" -ForegroundColor White

if ($script:failedCount -gt 0) {
    Write-Host "`nTroubleshooting Failed Deployments:" -ForegroundColor Yellow
    Write-Host "• Check GitLab permissions (Maintainer role required)" -ForegroundColor White
    Write-Host "• Verify access token has 'api' and 'write_repository' scopes" -ForegroundColor White
    Write-Host "• Ensure projects are not archived or have repository disabled" -ForegroundColor White
    Write-Host "• Use -ForceUpdate to overwrite existing insights configurations" -ForegroundColor White
}

Write-Host "`nInsights deployment completed successfully! 📊✨" -ForegroundColor Green