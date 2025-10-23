Set-StrictMode -Version Latest

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


Export-ModuleMember -Function Export-EnhancedCSVReports,Export-CSVReports

