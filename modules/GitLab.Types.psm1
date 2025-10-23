Set-StrictMode -Version Latest

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
    [string]$StrategicImpact
    [string]$CustomerSegment
    [string]$RevenueModel
    [string]$BusinessCriticality
    [string]$StakeholderOwner
    [string]$AlignmentScore
}

class FeatureAdoption {
    [string]$ProjectName
    [int]$ProjectId
    [int]$FeatureAdoptionScore
    [string]$AdoptionLevel
    [bool]$UsingIssues
    [bool]$UsingMergeRequests
    [bool]$UsingCI_CD
    [bool]$UsingSecurityScanning
    [bool]$UsingWiki
    [bool]$UsingContainer_Registry
    [bool]$UsingPackage_Registry
    [bool]$UsingPages
    [bool]$UsingEnvironments
    [bool]$UsingAutoDevOps
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
    [double]$DeploymentFrequency
    [double]$LeadTime
    [double]$ChangeFailureRate
    [double]$RecoveryTime
    [string]$DORAScore
    [string]$MaturityLevel
    [int]$CI_CDScore
    [int]$TestingScore
    [int]$SecurityScore
    [int]$MonitoringScore
    [int]$AutomationScore
    [int]$CollaborationScore
    [int]$MaturityScore
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
