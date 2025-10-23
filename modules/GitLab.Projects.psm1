using module ./GitLab.Types.psm1
Set-StrictMode -Version Latest

function Get-ProjectHealth {
    param($ProjectData)

    $score = 0

    if ($ProjectData.DaysSinceLastActivity -le 7) { $score += 30 }
    elseif ($ProjectData.DaysSinceLastActivity -le 30) { $score += 20 }
    elseif ($ProjectData.DaysSinceLastActivity -le 90) { $score += 10 }

    $totalIssues = $ProjectData.OpenIssues + $ProjectData.ClosedIssues
    if ($totalIssues -gt 0) {
        $completionRate = if ($totalIssues -gt 0) { $ProjectData.ClosedIssues / $totalIssues } else { 0 }
        if ($completionRate -ge 0.8) { $score += 20 }
        elseif ($completionRate -ge 0.5) { $score += 15 }
        elseif ($completionRate -ge 0.2) { $score += 10 }
    }

    if ($ProjectData.MergedMergeRequests -gt 5) { $score += 20 }
    elseif ($ProjectData.MergedMergeRequests -gt 2) { $score += 15 }
    elseif ($ProjectData.MergedMergeRequests -gt 0) { $score += 10 }

    if ($ProjectData.PipelineSuccessRate -ge 0.9) { $score += 20 }
    elseif ($ProjectData.PipelineSuccessRate -ge 0.7) { $score += 15 }
    elseif ($ProjectData.PipelineSuccessRate -ge 0.5) { $score += 10 }

    if ($ProjectData.ContributorsCount -gt 3) { $score += 10 }
    elseif ($ProjectData.ContributorsCount -gt 1) { $score += 5 }

    return $score
}

function Get-AdoptionLevel {
    param($HealthScore)

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

function Get-GitLabProjectReports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$ApiClient,
        [Parameter(Mandatory)][int]$DaysBack,
        [scriptblock]$UpdateProgress
    )

    $projects = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects?statistics=true&per_page=100" -AllPages))
    if (-not $projects) {
        return @()
    }

    Write-Log -Message "Fetched $($projects.Count) projects from GitLab" -Level "Info" -Component "DataCollection"

    $projectReports = @()
    $totalProjects = $projects.Count
    $projectCounter = 0

    foreach ($project in $projects) {
        $projectCounter++
        if ($UpdateProgress) {
            & $UpdateProgress `
                -Activity "Processing project $($project.name)" `
                -Status "Collecting detailed project data" `
                -PercentComplete ([math]::Round(($projectCounter / $totalProjects) * 100)) `
                -Step $projectCounter `
                -TotalSteps $totalProjects
        }

        try {
            $projectDetails = Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)?statistics=true"
            $repoStats = if ($projectDetails.statistics) { $projectDetails.statistics } else { @{} }

            $contributors = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/repository/contributors" -AllPages))
            $contributorsCount = if ($contributors) { $contributors.Count } else { 0 }

            $branches = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/repository/branches" -AllPages))
            $tags = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/repository/tags" -AllPages))

            $openIssues = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/issues?state=opened`&per_page=1"))
            $closedIssues = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/issues?state=closed`&per_page=1"))
            $openIssuesCount = if ($openIssues.Count -gt 0) { (ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/issues?state=opened")).Count } else { 0 }
            $closedIssuesCount = if ($closedIssues.Count -gt 0) { (ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/issues?state=closed")).Count } else { 0 }

            $openMRs = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/merge_requests?state=opened`&per_page=1"))
            $mergedMRs = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/merge_requests?state=merged`&per_page=1"))
            $openMRsCount = if ($openMRs.Count -gt 0) { (ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/merge_requests?state=opened")).Count } else { 0 }
            $mergedMRsCount = if ($mergedMRs.Count -gt 0) { (ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/merge_requests?state=merged")).Count } else { 0 }

            $pipelines = @(ConvertTo-GitLabArray (Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/pipelines?per_page=100" -AllPages))
            $pipelinesTotal = if ($pipelines) { $pipelines.Count } else { 0 }
            $pipelinesSuccess = if ($pipelines) { ($pipelines | Where-Object { $_.status -eq 'success' }).Count } else { 0 }
            $pipelinesFailed = if ($pipelines) { ($pipelines | Where-Object { $_.status -eq 'failed' }).Count } else { 0 }
            $pipelineSuccessRate = if ($pipelinesTotal -gt 0) { [math]::Round($pipelinesSuccess / $pipelinesTotal, 3) } else { 0 }

            $lastCommit = Invoke-GitLabApiRequest -Client $ApiClient -Endpoint "projects/$($project.id)/repository/commits?per_page=1"
            $lastCommitDate = if ($lastCommit -and $lastCommit.Count -gt 0) { $lastCommit[0].committed_date } else { $project.last_activity_at }
            $lastCommitAuthor = if ($lastCommit -and $lastCommit.Count -gt 0) { $lastCommit[0].author_name } else { "Unknown" }

            $lastActivityDate = if ($lastCommitDate) { [datetime]$lastCommitDate } else { [datetime]$project.last_activity_at }
            $daysSinceLastActivity = ((Get-Date) - $lastActivityDate).Days

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

            $healthScore = Get-ProjectHealth -ProjectData $projectReport
            $adoptionLevel = Get-AdoptionLevel -HealthScore $healthScore
            $recommendation = Get-Recommendation -AdoptionLevel $adoptionLevel -ProjectData $projectReport

            $projectReport.ProjectHealth = $healthScore
            $projectReport.AdoptionLevel = $adoptionLevel
            $projectReport.Recommendation = $recommendation

            $projectReports += $projectReport
        }
        catch {
            Write-Log -Message "Failed to process project $($project.name): $($_.Exception.Message)" -Level "Warning" -Component "DataCollection"

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

    return $projectReports
}

Export-ModuleMember -Function Get-GitLabProjectReports
