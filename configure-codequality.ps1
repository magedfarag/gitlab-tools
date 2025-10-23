param(
    [Parameter(Mandatory)]
    [string]$GitLabUrl,

    [Parameter(Mandatory)]
    [string]$AccessToken,

    [Parameter(Mandatory)]
    [int[]]$ProjectIds,

    [string]$Branch,

    [switch]$EnableCodeQuality = $true,

    [switch]$EnableCoverage,

    [ValidateSet('cobertura', 'lcov', 'jacoco')]
    [string]$CoverageFormat = 'cobertura',

    [string]$CoverageReportPath = 'coverage/coverage.xml',

    [string]$CoverageScript = './scripts/run-tests.sh --coverage'
)

# helper: prepare headers for GitLab API
function Get-GitLabHeaders {
    param([string]$Token)
    return @{
        'PRIVATE-TOKEN' = $Token
        'Content-Type'  = 'application/json'
    }
}

# helper: fetch project metadata
function Get-GitLabProject {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$ProjectId
    )

    $uri = "$BaseUrl/api/v4/projects/$ProjectId"
    return Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -MaximumRetryCount 3 -RetryIntervalSec 2
}

# helper: fetch raw file content
function Get-GitLabFile {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$ProjectId,
        [string]$FilePath,
        [string]$Ref
    )

    $encodedPath = [uri]::EscapeDataString($FilePath)
    $uri = "$BaseUrl/api/v4/projects/$ProjectId/repository/files/$encodedPath/raw?ref=$Ref"
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -MaximumRetryCount 3 -RetryIntervalSec 2
    } catch {
        return $null
    }
}

# helper: upsert file
function Set-GitLabFile {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$ProjectId,
        [string]$FilePath,
        [string]$Ref,
        [string]$Content,
        [string]$CommitMessage,
        [switch]$IsNew
    )

    $encodedPath = [uri]::EscapeDataString($FilePath)
    $uri = "$BaseUrl/api/v4/projects/$ProjectId/repository/files/$encodedPath"
    $body = @{
        branch         = $Ref
        content        = $Content
        commit_message = $CommitMessage
    } | ConvertTo-Json -Depth 5

    $method = if ($IsNew) { 'Post' } else { 'Put' }
    return Invoke-RestMethod -Method $method -Uri $uri -Headers $Headers -Body $body -MaximumRetryCount 3 -RetryIntervalSec 2
}

# helper: ensure include template
function Ensure-CodeQualityInclude {
    param([string]$Content)

    if ($Content -match 'Code-Quality\.gitlab-ci\.yml') {
        return $Content
    }

    $includePattern = '(?ms)^include:\s*\r?\n((?:\s+- .*\r?\n)*)'
    if ($Content -match $includePattern) {
        $existing = $matches[0]
        if ($existing -notmatch 'Code-Quality\.gitlab-ci\.yml') {
            $replacement = $existing.TrimEnd() + [Environment]::NewLine + '  - template: Code-Quality.gitlab-ci.yml' + [Environment]::NewLine
            return [regex]::Replace($Content, $includePattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
        }
    } else {
        $prefix = "include:`n  - template: Code-Quality.gitlab-ci.yml`n`n"
        return $prefix + $Content
    }

    return $Content
}

# helper: ensure coverage job
function Ensure-CoverageJob {
    param(
        [string]$Content,
        [string]$Format,
        [string]$ReportPath,
        [string]$Script
    )

    if ($Content -match 'coverage_report:') {
        return $Content
    }

    $coverageJob = @"

# Auto-added coverage report job. Adjust the script section to match your project.
publish_coverage_report:
  stage: test
  image: registry.gitlab.com/gitlab-org/ci-cd/jobs/base:latest
  script:
    - $Script
  artifacts:
    reports:
      coverage_report:
        format: $Format
        path: $ReportPath
    paths:
      - $ReportPath
  allow_failure: false
"@

    if ($Content.Trim().Length -eq 0) {
        return $coverageJob.TrimStart()
    }

    return ($Content.TrimEnd() + [Environment]::NewLine + $coverageJob)
}

# helper: normalize line endings
function Normalize-LineEndings {
    param([string]$Content)
    return $Content -replace "`r`n", "`n"
}

$headers = Get-GitLabHeaders -Token $AccessToken

foreach ($projectId in $ProjectIds) {
    Write-Host "Processing project $projectId..." -ForegroundColor Cyan

    try {
        $project = Get-GitLabProject -BaseUrl $GitLabUrl -Headers $headers -ProjectId $projectId
    } catch {
        Write-Warning "Failed to fetch project $projectId : $($_.Exception.Message)"
        continue
    }

    $targetBranch = if ($Branch) { $Branch } else { $project.default_branch }
    if (-not $targetBranch) {
        Write-Warning "Project $projectId has no default branch and none provided. Skipping."
        continue
    }

    $ciPath = '.gitlab-ci.yml'
    $existingContent = Get-GitLabFile -BaseUrl $GitLabUrl -Headers $headers -ProjectId $projectId -FilePath $ciPath -Ref $targetBranch
    $isNewFile = $false

    if (-not $existingContent) {
        Write-Host "No existing $ciPath found. A new file will be created." -ForegroundColor Yellow
        $existingContent = ''
        $isNewFile = $true
    }

    $updatedContent = Normalize-LineEndings -Content $existingContent

    if ($EnableCodeQuality) {
        $updatedContent = Ensure-CodeQualityInclude -Content $updatedContent
    }

    if ($EnableCoverage) {
        $updatedContent = Ensure-CoverageJob -Content $updatedContent -Format $CoverageFormat -ReportPath $CoverageReportPath -Script $CoverageScript
    }

    if ($updatedContent -eq (Normalize-LineEndings -Content $existingContent)) {
        Write-Host "No changes required for project $projectId." -ForegroundColor Green
        continue
    }

    $commitMessageParts = @()
    if ($EnableCodeQuality) { $commitMessageParts += 'enable code quality artifact' }
    if ($EnableCoverage) { $commitMessageParts += 'publish coverage report' }
    if (-not $commitMessageParts) { $commitMessageParts = @('update CI configuration') }
    $commitMessage = "chore(ci): " + ($commitMessageParts -join ' & ')

    try {
        Set-GitLabFile -BaseUrl $GitLabUrl -Headers $headers -ProjectId $projectId -FilePath $ciPath -Ref $targetBranch -Content $updatedContent -CommitMessage $commitMessage -IsNew:$isNewFile | Out-Null
        Write-Host "Updated $ciPath for project $projectId on branch $targetBranch." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to update $ciPath for project $projectId : $($_.Exception.Message)"
    }
}
