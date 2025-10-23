using module ./GitLab.Types.psm1
Set-StrictMode -Version Latest

function Expand-Template {
    param(
        [string]$TemplatePath,
        [hashtable]$Parameters
    )
    
    try {
        # Load the template
        if (-not (Test-Path $TemplatePath)) {
            $templateName = if ($TemplatePath) { Split-Path -Path $TemplatePath -Leaf } else { 'gitlab-report-template.html' }
            $moduleParent = Split-Path -Path $PSScriptRoot -Parent
            if ($moduleParent) {
                $alternatePath = Join-Path $moduleParent $templateName
                if (Test-Path $alternatePath) {
                    Write-Log -Message "Template not found at $TemplatePath. Using fallback path $alternatePath." -Level "Warning" -Component "TemplateExpansion"
                    $TemplatePath = $alternatePath
                }
            }
        }

        if (-not (Test-Path $TemplatePath)) {
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
        
        $originalErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            $expandedContent = $ExecutionContext.InvokeCommand.ExpandString($templateContent)
        } catch {
            $errorRecord = $_
            $message = $errorRecord.Exception.Message
            $position = if ($errorRecord.InvocationInfo -and $errorRecord.InvocationInfo.PositionMessage) { $errorRecord.InvocationInfo.PositionMessage.Trim() } else { "Position unknown" }
            Write-Log -Message "Template expansion error: $message [$position]" -Level "Error" -Component "TemplateExpansion"
            throw
        } finally {
            $ErrorActionPreference = $originalErrorPreference
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
        [timespan]$ExecutionTime,
        [string]$TemplatePath
    )
    
    $ProjectReports = @(ConvertTo-GitLabArray $ProjectReports | Where-Object { $_ -ne $null })
    $SecurityScanResults = @(ConvertTo-GitLabArray $SecurityScanResults | Where-Object { $_ -ne $null })
    $CodeQualityReports = @(ConvertTo-GitLabArray $CodeQualityReports | Where-Object { $_ -ne $null })
    $CostReports = @(ConvertTo-GitLabArray $CostReports | Where-Object { $_ -ne $null })
    $TeamReports = @(ConvertTo-GitLabArray $TeamReports | Where-Object { $_ -ne $null })
    $TechReports = @(ConvertTo-GitLabArray $TechReports | Where-Object { $_ -ne $null })
    $LifecycleReports = @(ConvertTo-GitLabArray $LifecycleReports | Where-Object { $_ -ne $null })
    $BusinessReports = @(ConvertTo-GitLabArray $BusinessReports | Where-Object { $_ -ne $null })
    $FeatureAdoptionReports = @(ConvertTo-GitLabArray $FeatureAdoptionReports | Where-Object { $_ -ne $null })
    $CollaborationReports = @(ConvertTo-GitLabArray $CollaborationReports | Where-Object { $_ -ne $null })
    $DevOpsMaturityReports = @(ConvertTo-GitLabArray $DevOpsMaturityReports | Where-Object { $_ -ne $null })
    $AdoptionBarrierReports = @(ConvertTo-GitLabArray $AdoptionBarrierReports | Where-Object { $_ -ne $null })
    
    Write-Log -Message ("Dashboard dataset types: Projects={0} Security={1} Feature={2}" -f `
        ($ProjectReports.GetType().FullName), `
        ($SecurityScanResults.GetType().FullName), `
        ($FeatureAdoptionReports.GetType().FullName)) -Level "Debug" -Component "Dashboard"
    if ($ProjectReports.Count -gt 0) {
        Write-Log -Message ("First project type: {0}" -f $ProjectReports[0].GetType().FullName) -Level "Debug" -Component "Dashboard"
    }

    # Calculate all metrics needed for the template with safe division
    $totalProjects = if ($ProjectReports) { $ProjectReports.Count } else { 0 }
    $activeProjects = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.DaysSinceLastActivity -le 30 }).Count } else { 0 }
    $staleProjects = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 90 }).Count } else { 0 }
    
    $highAdoption = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'High' }).Count } else { 0 }
    $mediumAdoption = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'Medium' }).Count } else { 0 }
    $lowAdoption = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'Low' }).Count } else { 0 }
    $veryLowAdoption = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.AdoptionLevel -eq 'Very Low' }).Count } else { 0 }
    
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
    $projectsWithCriticalVulns = if ($SecurityScanResults) { @($SecurityScanResults | Where-Object { $_.CriticalVulnerabilities -gt 0 }).Count } else { 0 }
    
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
    $activity7Days = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.DaysSinceLastActivity -le 7 }).Count } else { 0 }
    $activity30Days = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 7 -and $_.DaysSinceLastActivity -le 30 }).Count } else { 0 }
    $activity90Days = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 30 -and $_.DaysSinceLastActivity -le 90 }).Count } else { 0 }
    $activityOlder = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.DaysSinceLastActivity -gt 90 }).Count } else { 0 }

    # Pipeline success distribution
    $pipelineExcellent = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.PipelineSuccessRate -gt 0.9 }).Count } else { 0 }
    $pipelineGood = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.PipelineSuccessRate -gt 0.7 -and $_.PipelineSuccessRate -le 0.9 }).Count } else { 0 }
    $pipelineFair = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.PipelineSuccessRate -gt 0.5 -and $_.PipelineSuccessRate -le 0.7 }).Count } else { 0 }
    $pipelinePoor = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.PipelineSuccessRate -le 0.5 -and $_.PipelinesTotal -gt 0 }).Count } else { 0 }
    $pipelineNone = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.PipelinesTotal -eq 0 }).Count } else { 0 }

    # Team contribution distribution
    $singleContributor = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.ContributorsCount -eq 1 }).Count } else { 0 }
    $smallTeam = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.ContributorsCount -ge 2 -and $_.ContributorsCount -le 3 }).Count } else { 0 }
    $largeTeam = if ($ProjectReports) { @($ProjectReports | Where-Object { $_.ContributorsCount -ge 4 }).Count } else { 0 }

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

    $adoptionProjectsCount = $highAdoption + $mediumAdoption
    $adoptionRatioString = if ($totalProjects -gt 0) { "$adoptionProjectsCount/$totalProjects" } else { "0/$totalProjects" }

    $collaborationChartHasData = $false
    if ($CollaborationReports -and $CollaborationReports.Count -gt 0) {
        $collaborationChartHasData = $true
    }

    $barriersChartHasData = $false
    if ($AdoptionBarrierReports -and $AdoptionBarrierReports.Count -gt 0) {
        $barriersChartHasData = $true
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
        adoptionProjectsCount = $adoptionProjectsCount
        adoptionRatio = $adoptionRatioString
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
            $criticalCount = @($AdoptionBarrierReports | Where-Object { $_.BarrierSeverity -ge 7 }).Count
            Write-Log -Message "AdoptionBarrierReports: Count=$($AdoptionBarrierReports.Count), CriticalBarriers=$criticalCount" -Level "Debug" -Component "ChartData"
            $criticalCount
        } else { 
            Write-Log -Message "AdoptionBarrierReports: Empty or null" -Level "Debug" -Component "ChartData"
            0 
        }
        collaborationChartHasData = $collaborationChartHasData.ToString().ToLower()
        barriersChartHasData = $barriersChartHasData.ToString().ToLower()
        excellentAdoption = if ($FeatureAdoptionReports) { 
            @($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Excellent" }).Count 
        } else { 0 }
        goodAdoption = if ($FeatureAdoptionReports) { 
            @($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Good" }).Count 
        } else { 0 }
        needsImprovementAdoption = if ($FeatureAdoptionReports) { 
            @($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Fair" }).Count + 
            @($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Basic" }).Count 
        } else { 0 }
        poorAdoption = if ($FeatureAdoptionReports) { 
            @($FeatureAdoptionReports | Where-Object { $_.AdoptionLevel -eq "Minimal" }).Count 
        } else { 0 }
    }
    
    # Resolve the template path, preferring the repository root copy if present
    $moduleParent = Split-Path -Path $PSScriptRoot -Parent
    $templateCandidates = @()
    if ($moduleParent) {
        $templateCandidates += Join-Path $moduleParent "gitlab-report-template.html"
    }
    $templateCandidates += Join-Path $PSScriptRoot "gitlab-report-template.html"
    $templatePath = $templateCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $templatePath) {
        $templatePath = $templateCandidates[0]
    }
    
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

Export-ModuleMember -Function Expand-Template,New-ConsolidatedDashboardFromTemplate



