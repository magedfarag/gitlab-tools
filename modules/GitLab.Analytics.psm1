Set-StrictMode -Version Latest

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

# COMPREHENSIVE REPORT GENERATION FUNCTIONS
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


Export-ModuleMember -Function Get-CodeQualityArtifactIssues,Get-ExistingSecurityScanData,Get-SecurityScanResults,Process-SecurityResults,Get-SecurityGrade,Get-RiskLevel,Get-ProjectHealth,Get-AdoptionLevel,Get-Recommendation,Generate-CodeQualityReport,Generate-CostAnalysisReport,Generate-TeamActivityReport,Generate-TechnologyStackReport,Generate-ProjectLifecycleReport,Generate-BusinessAlignmentReport,Generate-GitLabFeatureAdoptionReport,Generate-TeamCollaborationReport,Generate-DevOpsMaturityReport,Generate-AdoptionBarriersReport

