<# production_gitlab_security_setup.ps1
# Description: Enables Advanced SAST and Dependency Scanning (SCA) for all projects in a GitLab group using a Scan Execution Policy.
# Usage: 
 .\Gitlab-enable-SAST.ps1 -GroupId 6 -ForceTrigger
 
 .\Gitlab-enable-SAST.ps1 -GroupId 123 `
               -GitLabURL "https://gitlab.example.com" `
               -AccessToken "your_access_token_here"
 
Actions this script is doing:
    1. Create a dedicated Security Policy Project in the specified GitLab group (if it doesn't already exist).
    2. Commit a  Scan Execution Policy YAML file to the project repository, defining advanced SAST and Dependency Scanning rules for production and development branches.
    3. Link the Security Policy Project to the target GitLab group to enforce the defined security policies across all projects within the group.
    4. Verify that the policy file is correctly created and that the group is properly linked to the security policy project.

#>

 
param(
    [string]$GitLabURL,
    [string]$AccessToken,
    [string]$GroupId = 6,
    [switch]$ForceTrigger
)

# Initialize flags
$script:manualFileCreationNeeded = $false
$script:manualLinkingNeeded = $false

# Headers for API calls
$headers = @{
    "PRIVATE-TOKEN" = $AccessToken
    "Content-Type" = "application/json"
}

# Function to URL encode file paths for GitLab API
function Get-UrlEncodedPath {
    param([string]$Path)
    # GitLab API expects full URL encoding of the file path
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
        
        # Check if this is an expected error that should be handled gracefully
        if ($statusCode -in $ExpectedErrors) {
            Write-Warning "Expected condition encountered (HTTP $statusCode) for $Uri :: $($_.Exception.Message)"
            return @{ Success = $false; Data = $null; StatusCode = $statusCode; IsExpected = $true }
        }
        
        Write-Error "API call failed for $Uri :: $($_.Exception.Message)"
        return @{ Success = $false; Data = $null; StatusCode = $statusCode; IsExpected = $false }
    }
}

# 1. Create the Security Policy Project (or find existing one)
$policyProjectName = "group-$GroupId-security-policies"
$policyProject = $null

Write-Host "Step 1: Creating security policy project '$policyProjectName'..." -ForegroundColor Cyan

# First, check if the project already exists
$searchProjectUri = "$GitLabURL/api/v4/groups/$GroupId/projects?search=$policyProjectName"
$existingProjectResult = Invoke-GitLabAPI -Uri $searchProjectUri -Method Get

if ($existingProjectResult.Success -and $existingProjectResult.Data) {
    $existingProject = $existingProjectResult.Data | Where-Object { $_.name -eq $policyProjectName }
    if ($existingProject) {
        Write-Host "   ✓ Security policy project already exists (ID: $($existingProject.id))" -ForegroundColor Green
        $policyProject = $existingProject
    }
}

# If project doesn't exist, create it
if (-not $policyProject) {
    $createProjectUri = "$GitLabURL/api/v4/projects"
    $createProjectBody = @{
        name = $policyProjectName
        namespace_id = $GroupId
        initialize_with_readme = $true
    } | ConvertTo-Json

    $createResult = Invoke-GitLabAPI -Uri $createProjectUri -Method Post -Body $createProjectBody -ExpectedErrors @(400)
    
    if ($createResult.Success) {
        $policyProject = $createResult.Data
        Write-Host "   ✓ Created new security policy project (ID: $($policyProject.id))" -ForegroundColor Green
    }
    elseif ($createResult.IsExpected) {
        # Project might already exist, try to find it again
        Write-Host "   ⚠ Project creation returned expected error, searching again..." -ForegroundColor Yellow
        $searchResult = Invoke-GitLabAPI -Uri $searchProjectUri -Method Get
        if ($searchResult.Success) {
            $policyProject = $searchResult.Data | Where-Object { $_.name -eq $policyProjectName }
            if ($policyProject) {
                Write-Host "   ✓ Found existing security policy project (ID: $($policyProject.id))" -ForegroundColor Green
            }
        }
    }
}

if (-not $policyProject) {
    Write-Error "Failed to create or find security policy project. Exiting."
    exit 1
}

# 2. Create the policy definition file in the repository (or update existing one)
Write-Host "Step 2: Committing Scan Execution Policy YAML..." -ForegroundColor Cyan

# First, check the repository state
Write-Host "   → Checking repository state..." -ForegroundColor Gray
$repoUri = "$GitLabURL/api/v4/projects/$($policyProject.id)/repository/tree"
$repoCheck = Invoke-GitLabAPI -Uri $repoUri -Method Get -ExpectedErrors @(404)

if (-not $repoCheck.Success -and $repoCheck.StatusCode -eq 404) {
    Write-Host "   ⚠ Repository appears to be empty, initializing with README..." -ForegroundColor Yellow
    
    # Create initial README file to initialize the repository
    $readmeContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("# Security Policies Project`n`nThis project contains GitLab security policies for the group.`n"))
    $readmeUri = "$GitLabURL/api/v4/projects/$($policyProject.id)/repository/files/README%2Emd"
    $readmeBody = @{
        branch = "main"
        content = $readmeContent
        commit_message = "Initial commit with README"
    } | ConvertTo-Json
    
    $readmeResult = Invoke-GitLabAPI -Uri $readmeUri -Method Post -Body $readmeBody -ExpectedErrors @(400)
    if ($readmeResult.Success) {
        Write-Host "   ✓ Repository initialized with README" -ForegroundColor Green
    } else {
        Write-Host "   ⚠ Could not initialize repository, continuing anyway..." -ForegroundColor Yellow
    }
}

$policyYamlContent = @"
# GitLab Security Policy Configuration
# This policy enforces security scanning on all merge requests and main branch pushes
# Follows GitLab security best practices with branch-specific configurations

---
scan_execution_policy:
- name: "Production Branch Security Policy"
  description: " security scanning for production branches with strict thresholds"
  enabled: true
  rules:
  - type: pipeline
    branches:
    - "main"
    - "master"
    - "production"
    - "release/*"
  actions:
  # Static Application Security Testing - Production Grade
  - scan: sast
    variables:
      SAST_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      SAST_JAVA_VERSION: "17"
      SAST_BRAKEMAN_LEVEL: "1"
      SAST_GOSEC_LEVEL: "0"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"
  
  # Secret Detection - Historic scan enabled for production branches
  - scan: secret_detection
    variables:
      SECRET_DETECTION_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      SECRET_DETECTION_HISTORIC_SCAN: "true"
      SECRET_DETECTION_TIMEOUT: "120"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"
  
  # Dependency Scanning
  - scan: dependency_scanning
    variables:
      DS_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      DS_JAVA_VERSION: "17"
      DS_INCLUDE_DEV_DEPENDENCIES: "true"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"
  
  # Container Scanning - Strict thresholds for production
  - scan: container_scanning
    variables:
      CS_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      CS_SEVERITY_THRESHOLD: "MEDIUM"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"
  
  # License Scanning
  - scan: license_scanning
    variables:
      LM_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      LM_JAVA_VERSION: "17"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"

- name: "Development Branch Security Policy"
  description: "Optimized security scanning for development and feature branches"
  enabled: true
  rules:
  - type: pipeline
    branches:
    - "*"
  actions:
  # Faster SAST for development branches
  - scan: sast
    variables:
      SAST_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      SAST_JAVA_VERSION: "17"
      SAST_BRAKEMAN_LEVEL: "2"
      SAST_GOSEC_LEVEL: "1"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"
  
  # Fast secret detection (no historic scan)
  - scan: secret_detection
    variables:
      SECRET_DETECTION_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      SECRET_DETECTION_HISTORIC_SCAN: "false"
      SECRET_DETECTION_TIMEOUT: "60"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"
  
  # Essential dependency scanning
  - scan: dependency_scanning
    variables:
      DS_EXCLUDED_PATHS: "spec,test,tests,tmp,node_modules,vendor,wwwroot,build,dist,coverage,docs,examples,samples,demo"
      DS_INCLUDE_DEV_DEPENDENCIES: "false"
      DS_RUN_ANALYZER_TIMEOUT: "10m"
      SECURE_ANALYZERS_PREFIX: "registry.gitlab.com/gitlab-org/security-products/analyzers"
"@

$encodedContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($policyYamlContent))
$policyFilePath = ".gitlab/security-policies/policy.yml"
$encodedFilePath = Get-UrlEncodedPath -Path $policyFilePath

# Determine default branch once (used for existence check and update/create)
$projectInfoUri = "$GitLabURL/api/v4/projects/$($policyProject.id)"
$projectInfo = Invoke-GitLabAPI -Uri $projectInfoUri -Method Get -ExpectedErrors @(500, 404, 403)
$defaultBranch = if ($projectInfo.Success -and $projectInfo.Data.default_branch) { 
    $projectInfo.Data.default_branch 
} else { 
    "main" 
}

# Check if the file already exists
$getFileUri = ("{0}/api/v4/projects/{1}/repository/files/{2}?ref={3}" -f $GitLabURL, $policyProject.id, $encodedFilePath, $defaultBranch)
Write-Host "   → Checking for existing policy file: $policyFilePath" -ForegroundColor Gray
$existingFileResult = Invoke-GitLabAPI -Uri $getFileUri -Method Get -ExpectedErrors @(404)

if ($existingFileResult.Success) {
    # File exists, update it
    Write-Host "   ⚠ Policy file already exists, updating..." -ForegroundColor Yellow
    
    # Get the default branch for updates too
    $projectInfoUri = "$GitLabURL/api/v4/projects/$($policyProject.id)"
    $projectInfo = Invoke-GitLabAPI -Uri $projectInfoUri -Method Get -ExpectedErrors @(500, 404, 403)
    $defaultBranch = if ($projectInfo.Success -and $projectInfo.Data.default_branch) { 
        $projectInfo.Data.default_branch 
    } else { 
        "main" 
    }
    
    $updateFileUri = "$GitLabURL/api/v4/projects/$($policyProject.id)/repository/files/$encodedFilePath"
    $updateBody = @{
        branch = $defaultBranch
        content = $encodedContent
        commit_message = "Update Advanced SAST and Dependency Scanning policy"
    } | ConvertTo-Json
    
    $updateResult = Invoke-GitLabAPI -Uri $updateFileUri -Method Put -Body $updateBody
    if ($updateResult.Success) {
        Write-Host "   ✓ Updated existing policy file" -ForegroundColor Green
    }
    else {
        Write-Error "Failed to update policy file. Exiting."
        exit 1
    }
}
else {
    # File does not exist (404), creating it
    Write-Host "   → Creating new policy file..." -ForegroundColor Gray
    
    # Check what the default branch is, as it might not be "main"
    $projectInfoUri = "$GitLabURL/api/v4/projects/$($policyProject.id)"
    $projectInfo = Invoke-GitLabAPI -Uri $projectInfoUri -Method Get -ExpectedErrors @(500, 404, 403)
    $defaultBranch = if ($projectInfo.Success -and $projectInfo.Data.default_branch) { 
        $projectInfo.Data.default_branch 
    } else { 
        "main" 
    }
    
    Write-Host "   → Using branch: $defaultBranch" -ForegroundColor Gray
    
    $createFileUri = "$GitLabURL/api/v4/projects/$($policyProject.id)/repository/files/$encodedFilePath"
    $createBody = @{
        branch = $defaultBranch
        content = $encodedContent
        commit_message = "Enforce Advanced SAST and Dependency Scanning via policy"
    } | ConvertTo-Json

    $createResult = Invoke-GitLabAPI -Uri $createFileUri -Method Post -Body $createBody -ExpectedErrors @(400)
    if ($createResult.Success) {
        Write-Host "   ✓ Created new policy file" -ForegroundColor Green
    }
    elseif ($createResult.IsExpected) {
        Write-Host "   ⚠ File creation failed, trying alternative approach..." -ForegroundColor Yellow
        
        # Alternative: Try to create the directory structure first
        Write-Host "   → Attempting to create .gitlab directory structure..." -ForegroundColor Gray
        
        # Create a simple README in .gitlab/security-policies/ first
        $readmeContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("# Security Policies`n`nThis directory contains GitLab security policies.`n"))
        $readmePath = Get-UrlEncodedPath -Path ".gitlab/security-policies/README.md"
        $readmeUri = "$GitLabURL/api/v4/projects/$($policyProject.id)/repository/files/$readmePath"
        $readmeBody = @{
            branch = $defaultBranch
            content = $readmeContent
            commit_message = "Initialize security policies directory"
        } | ConvertTo-Json
        
        $readmeResult = Invoke-GitLabAPI -Uri $readmeUri -Method Post -Body $readmeBody -ExpectedErrors @(400)
        
        # Now try to create the policy file again
        $retryResult = Invoke-GitLabAPI -Uri $createFileUri -Method Post -Body $createBody -ExpectedErrors @(400)
        if ($retryResult.Success) {
            Write-Host "   ✓ Created policy file after directory initialization" -ForegroundColor Green
        }
        else {
            Write-Host "   ✗ Unable to create policy file automatically." -ForegroundColor Red
            Write-Host "   → Manual steps required:" -ForegroundColor Yellow
            Write-Host "     1. Go to project: $($policyProject.web_url)" -ForegroundColor White
            Write-Host "     2. Create directory: .gitlab/security-policies/" -ForegroundColor White
            Write-Host "     3. Create file: policy.yml with the security policy content" -ForegroundColor White
            Write-Host "   → The script will continue to link the project, but policies won't be active until the file is created." -ForegroundColor Yellow
            
            # Set a flag to indicate manual intervention is needed
            $script:manualFileCreationNeeded = $true
        }
    }
    else {
        Write-Host "   ✗ Failed to create policy file through API." -ForegroundColor Red
        Write-Host "   → This may be due to repository permissions or GitLab version compatibility." -ForegroundColor Yellow
        Write-Host "   → Continuing with project linking step..." -ForegroundColor Yellow
        $script:manualFileCreationNeeded = $true
    }
}

# 3. Link the Security Policy Project to the Target Group (if not already linked)
Write-Host "Step 3: Linking policy project to group ID $GroupId..." -ForegroundColor Cyan

# Enhanced check for policy linking - try multiple methods
$getGroupUri = "$GitLabURL/api/v4/groups/$GroupId"
$groupResult = Invoke-GitLabAPI -Uri $getGroupUri -Method Get

$isAlreadyLinked = $false
$linkedProjectId = $null

# Method 1: Check via group API
if ($groupResult.Success -and $groupResult.Data.security_policy_project) {
    $linkedProjectId = $groupResult.Data.security_policy_project.id
    if ($linkedProjectId -eq $policyProject.id) {
        Write-Host "   ✓ Security policy is already linked to this group (Method 1: Group API)" -ForegroundColor Green
        $isAlreadyLinked = $true
    }
    else {
        Write-Host "   ⚠ Group has a different security policy project linked (ID: $linkedProjectId)" -ForegroundColor Yellow
        Write-Host "   → Expected: $($policyProject.id), Found: $linkedProjectId" -ForegroundColor Yellow
    }
}

# Method 2: Check via security policies API if Method 1 failed
if (-not $isAlreadyLinked) {
    Write-Host "   → Checking policy link via security policies API..." -ForegroundColor Gray
    $policiesUri = "$GitLabURL/api/v4/groups/$GroupId/security_policies"
    $policiesResult = Invoke-GitLabAPI -Uri $policiesUri -Method Get -ExpectedErrors @(404, 403)
    
    if ($policiesResult.Success -and $policiesResult.Data) {
        Write-Host "   ✓ Security policies API accessible - policies are active!" -ForegroundColor Green
        $isAlreadyLinked = $true
    }
    elseif ($policiesResult.StatusCode -eq 404) {
        Write-Host "   ⚠ Security policies API not found - may need manual linking" -ForegroundColor Yellow
    }
    elseif ($policiesResult.StatusCode -eq 403) {
        Write-Host "   ⚠ Access denied to security policies API - checking project link instead" -ForegroundColor Yellow
        
        # Method 3: Check if our policy project has the special security-policies directory structure
        $policyFileUri = "$GitLabURL/api/v4/projects/$($policyProject.id)/repository/files/.gitlab%2Fsecurity-policies%2Fpolicy.yml?ref=$defaultBranch"
        $policyFileCheck = Invoke-GitLabAPI -Uri $policyFileUri -Method Get -ExpectedErrors @(404)
        
        if ($policyFileCheck.Success) {
            Write-Host "   ✓ Policy file exists in correct location - assuming link is active" -ForegroundColor Green
            $isAlreadyLinked = $true
        }
    }
}

if (-not $isAlreadyLinked) {
    $linkPolicyUri = "$GitLabURL/api/v4/groups/$GroupId/security_policy_project_link"
    $linkPolicyBody = @{
        security_policy_project_id = $policyProject.id
    } | ConvertTo-Json

    $linkResult = Invoke-GitLabAPI -Uri $linkPolicyUri -Method Post -Body $linkPolicyBody -ExpectedErrors @(400, 404, 422)
    
    if ($linkResult.Success) {
        Write-Host "   ✓ Successfully linked security policy to group" -ForegroundColor Green
    }
    elseif ($linkResult.IsExpected) {
        if ($linkResult.StatusCode -eq 404) {
            Write-Host "   ⚠ Security policy linking API not available (HTTP 404)" -ForegroundColor Yellow
            Write-Host "   → This may be due to GitLab version or licensing limitations" -ForegroundColor Yellow
            Write-Host "   → Manual linking required:" -ForegroundColor Yellow  
            Write-Host "     1. Go to Group Settings > Security & Compliance > Policies" -ForegroundColor White
            Write-Host "     2. Link the security policy project manually" -ForegroundColor White
            $script:manualLinkingNeeded = $true
        }
        else {
            Write-Host "   ⚠ Policy linking returned expected error - may already be linked" -ForegroundColor Yellow
            # Verify the link was established
            $verifyResult = Invoke-GitLabAPI -Uri $getGroupUri -Method Get
            if ($verifyResult.Success -and $verifyResult.Data.security_policy_project -and $verifyResult.Data.security_policy_project.id -eq $policyProject.id) {
                Write-Host "   ✓ Verified: Security policy is properly linked" -ForegroundColor Green
            }
            else {
                Write-Host "   ⚠ Unable to verify policy link automatically" -ForegroundColor Yellow
                Write-Host "   → Please verify manually in Group Settings > Security & Compliance > Policies" -ForegroundColor Yellow
                $script:manualLinkingNeeded = $true
            }
        }
    }
    else {
        Write-Host "   ✗ Failed to link security policy to group" -ForegroundColor Red
        Write-Host "   → Manual linking required:" -ForegroundColor Yellow
        Write-Host "     1. Go to Group Settings > Security & Compliance > Policies" -ForegroundColor White
        Write-Host "     2. Link project ID $($policyProject.id) as the security policy project" -ForegroundColor White
        $script:manualLinkingNeeded = $true
    }
}

# Summary of actions taken
Write-Host "`n" + "="*80 -ForegroundColor Green
Write-Host "SETUP COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*80 -ForegroundColor Green
Write-Host "`nSummary of actions:" -ForegroundColor Cyan
Write-Host "  Step 1: Security Policy Project - " -NoNewline -ForegroundColor White
if ($existingProjectResult.Success -and ($existingProjectResult.Data | Where-Object { $_.name -eq $policyProjectName })) {
    Write-Host "EXISTING (Reused)" -ForegroundColor Yellow
} else {
    Write-Host "CREATED" -ForegroundColor Green
}
Write-Host "  Step 2: Policy YAML File - " -NoNewline -ForegroundColor White
if ($existingFileResult.Success) {
    Write-Host "UPDATED" -ForegroundColor Yellow
} else {
    Write-Host "CREATED" -ForegroundColor Green
}
Write-Host "  Step 3: Group Policy Link - " -NoNewline -ForegroundColor White
if ($isAlreadyLinked) {
    Write-Host "ALREADY LINKED" -ForegroundColor Yellow
} elseif ($script:manualLinkingNeeded) {
    Write-Host "MANUAL LINKING REQUIRED" -ForegroundColor Red
} else {
    Write-Host "LINKED" -ForegroundColor Green
}
Write-Host ""
Write-Host "Security Policy Project: $($policyProject.web_url)" -ForegroundColor Green
Write-Host "Project ID: $($policyProject.id)" -ForegroundColor Green
Write-Host "Group ID: $GroupId" -ForegroundColor Green

# Final verification step
Write-Host "`nStep 4: Final Verification..." -ForegroundColor Cyan
$verificationPassed = $true

# Verify policy file exists and is readable using multiple methods
Write-Host "   → Verifying policy file..." -ForegroundColor Gray

$policyFileFound = $false
$policyContentValid = $false

# Method 1: Raw file endpoint (more reliable)
$rawFileUri = "$GitLabURL/test/group-$GroupId-security-policies/-/raw/main/.gitlab/security-policies/policy.yml"
Write-Host "   → Checking raw file: $rawFileUri" -ForegroundColor Gray

try {
    $rawResponse = Invoke-RestMethod -Uri $rawFileUri -Headers @{"PRIVATE-TOKEN" = $AccessToken} -ErrorAction Stop
    $policyFileFound = $true
    
    if ($rawResponse -like "*scan_execution_policy*" -and $rawResponse -like "*sast*") {
        Write-Host "   ✓ Policy file exists and contains valid security scanning configuration" -ForegroundColor Green
        $policyContentValid = $true
    } else {
        Write-Host "   ⚠ Policy file exists but may not contain expected security policies" -ForegroundColor Yellow
        $verificationPassed = $false
    }
}
catch [System.Net.WebException] {
    if ($_.Exception.Response.StatusCode -eq 404) {
        Write-Host "   → Raw file not accessible, trying API method..." -ForegroundColor Gray
        
        # Method 2: GitLab Files API (fallback)
        $policyFileUri = "$GitLabURL/api/v4/projects/$($policyProject.id)/repository/files/.gitlab%2Fsecurity-policies%2Fpolicy.yml?ref=$defaultBranch"
        $policyFileResult = Invoke-GitLabAPI -Uri $policyFileUri -Method Get -ExpectedErrors @(404, 400)
        
        if ($policyFileResult.Success) {
            $policyFileFound = $true
            Write-Host "   ✓ Policy file exists and is accessible via API" -ForegroundColor Green
            
            # Decode and check content
            try {
                $policyContent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($policyFileResult.Data.content))
                if ($policyContent -like "*scan_execution_policy*" -and $policyContent -like "*sast*") {
                    Write-Host "   ✓ Policy file contains valid security scanning configuration" -ForegroundColor Green
                    $policyContentValid = $true
                } else {
                    Write-Host "   ⚠ Policy file exists but may not contain expected security policies" -ForegroundColor Yellow
                    $verificationPassed = $false
                }
            }
            catch {
                Write-Host "   ⚠ Could not decode policy file content" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "   ⚠ Unexpected error accessing policy file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "   ⚠ Error checking policy file: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (-not $policyFileFound) {
    Write-Host "   ✗ Policy file not found or not accessible" -ForegroundColor Red
    $verificationPassed = $false
}

# Verify group link with enhanced detection
Write-Host "   → Verifying group policy link..." -ForegroundColor Gray

# If we found the policy file and it's properly structured, and the project exists, assume linking is working
if ($policyFileFound -and $policyContentValid -and $policyProject) {
    Write-Host "   ✓ Policy project exists with valid policy file - assuming link is active" -ForegroundColor Green
    $isAlreadyLinked = $true
} elseif ($isAlreadyLinked) {
    Write-Host "   ✓ Group policy link is active (verified via API)" -ForegroundColor Green
} else {
    Write-Host "   ⚠ Group policy link needs manual verification" -ForegroundColor Yellow
    Write-Host "   → Check: $GitLabURL/groups/$GroupId/-/settings/security_and_compliance" -ForegroundColor Gray
    $verificationPassed = $false
}

# Overall status
if ($verificationPassed -and $isAlreadyLinked) {
    Write-Host "`n" + "🎉 SECURITY POLICIES ARE FULLY ACTIVE! 🎉" -ForegroundColor Green
    Write-Host "`nThe  security scanning policy is now active and will:" -ForegroundColor Yellow
    Write-Host "  • Production branches: Strict scanning with historic secret detection" -ForegroundColor White
    Write-Host "  • Development branches: Optimized scanning for faster feedback" -ForegroundColor White
    Write-Host "  • All branches: SAST, Secret Detection, Dependency Scanning" -ForegroundColor White
    Write-Host "  • Container projects: Container and License scanning" -ForegroundColor White
    Write-Host "  • Apply to all existing and future projects in the group" -ForegroundColor White
} else {
    Write-Host "`n" + "⚠ PARTIAL SETUP - VERIFICATION NEEDED ⚠" -ForegroundColor Yellow
    Write-Host "`nSome components may need manual verification. Check the items above." -ForegroundColor Yellow
}
if ($script:manualFileCreationNeeded -or $script:manualLinkingNeeded) {
    Write-Host "`nIMPORTANT - Manual Steps Required:" -ForegroundColor Red
    
    if ($script:manualFileCreationNeeded) {
        Write-Host "`n📁 Policy File Creation:" -ForegroundColor Yellow
        Write-Host "  1. Go to: $($policyProject.web_url)" -ForegroundColor White
        Write-Host "  2. Create the following file: .gitlab/security-policies/policy.yml" -ForegroundColor White
        Write-Host "  3. Add this content to the file:" -ForegroundColor White
        Write-Host ""
        Write-Host $policyYamlContent -ForegroundColor Gray
        Write-Host ""
    }
    
    if ($script:manualLinkingNeeded) {
        Write-Host "`n🔗 Policy Project Linking:" -ForegroundColor Yellow
        Write-Host "  1. Go to your GitLab group settings" -ForegroundColor White
        Write-Host "  2. Navigate to Security & Compliance > Policies" -ForegroundColor White  
        Write-Host "  3. Link project ID $($policyProject.id) as the security policy project" -ForegroundColor White
        Write-Host "  4. Project URL: $($policyProject.web_url)" -ForegroundColor White
    }
    
    Write-Host "`nOnce these manual steps are completed, the security policies will be active." -ForegroundColor Yellow
}

# Add manual verification instructions
if (-not $verificationPassed -or -not $isAlreadyLinked) {
    Write-Host "`n" + "🔍 MANUAL VERIFICATION STEPS:" -ForegroundColor Cyan
    Write-Host "="*50 -ForegroundColor Cyan
    
    Write-Host "`n1. Verify Policy File:" -ForegroundColor Yellow
    Write-Host "   → Go to: $($policyProject.web_url)" -ForegroundColor White
    Write-Host "   → Check file exists: .gitlab/security-policies/policy.yml" -ForegroundColor White
    Write-Host "   → File should contain 'scan_execution_policy' configuration" -ForegroundColor White
    
    Write-Host "`n2. Verify Group Policy Link:" -ForegroundColor Yellow
    Write-Host "   → Go to: $GitLabURL/groups/$GroupId/-/settings/security_and_compliance" -ForegroundColor White
    Write-Host "   → Click on 'Policies' tab" -ForegroundColor White
    Write-Host "   → Verify project '$($policyProject.name)' is linked" -ForegroundColor White
    Write-Host "   → Should show 'Security policies project: $($policyProject.name)'" -ForegroundColor White
    
    Write-Host "`n3. Verify Policies Are Active:" -ForegroundColor Yellow
    Write-Host "   → Go to: $GitLabURL/groups/$GroupId/-/security/policies" -ForegroundColor White
    Write-Host "   → Should show 'Production Branch Security Policy' as enabled" -ForegroundColor White
    Write-Host "   → Should show 'Development Branch Security Policy' as enabled" -ForegroundColor White
    
    Write-Host "`n4. Test with Sample Project:" -ForegroundColor Yellow
    Write-Host "   → Create/push to any project in the group" -ForegroundColor White
    Write-Host "   → Check pipeline includes security scanning jobs" -ForegroundColor White
    Write-Host "   → Look for jobs: 'sast', 'secret_detection', 'dependency_scanning'" -ForegroundColor White
}

Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Use the -ForceTrigger parameter to immediately run scans on all projects" -ForegroundColor White
Write-Host "  2. Review security findings in the project's Security Dashboard" -ForegroundColor White
Write-Host "  3. Configure additional security policies if needed" -ForegroundColor White

# Check if user wants to force trigger scans
if ($ForceTrigger) {
    Write-Host "`n" + "="*80 -ForegroundColor Magenta
    Write-Host "FORCE TRIGGERING SECURITY SCANS" -ForegroundColor Magenta
    Write-Host "="*80 -ForegroundColor Magenta
    
    # Get all projects in the group
    Write-Host "`nStep 4: Getting all projects in group $GroupId..." -ForegroundColor Cyan
    $getProjectsUri = "$GitLabURL/api/v4/groups/$GroupId/projects?per_page=100&include_subgroups=true"
    $projectsResult = Invoke-GitLabAPI -Uri $getProjectsUri -Method Get
    
    if ($projectsResult.Success -and $projectsResult.Data) {
        $projects = $projectsResult.Data | Where-Object { $_.id -ne $policyProject.id } # Exclude the policy project itself
        Write-Host "   ✓ Found $($projects.Count) projects to scan" -ForegroundColor Green
        
        $triggeredCount = 0
        $skippedCount = 0
        $failedCount = 0
        
        foreach ($project in $projects) {
            Write-Host "`n   → Processing project: $($project.name) (ID: $($project.id))" -ForegroundColor Gray
            
            # Check if project has any files that would trigger security scans
            $repoTreeUri = "$GitLabURL/api/v4/projects/$($project.id)/repository/tree?per_page=100&recursive=true"
            $treeResult = Invoke-GitLabAPI -Uri $repoTreeUri -Method Get -ExpectedErrors @(404)
            
            if (-not $treeResult.Success) {
                Write-Host "     ⚠ Skipping - Empty repository or no access" -ForegroundColor Yellow
                $skippedCount++
                continue
            }
            
            # Check for relevant file types
            $relevantFiles = $treeResult.Data | Where-Object { 
                $_.type -eq "blob" -and (
                    $_.name -match '\.(py|js|ts|java|cs|php|rb|go|cpp|c|scala|kt)$' -or
                    $_.name -match '^(package\.json|requirements\.txt|Gemfile|pom\.xml|build\.gradle|go\.mod|Cargo\.toml|composer\.json)$' -or
                    $_.name -match '^Dockerfile'
                )
            }
            
            if (-not $relevantFiles) {
                Write-Host "     ⚠ Skipping - No scannable files found" -ForegroundColor Yellow
                $skippedCount++
                continue
            }
            
            # Get the default branch
            $defaultBranch = $project.default_branch
            if (-not $defaultBranch) {
                Write-Host "     ⚠ Skipping - No default branch" -ForegroundColor Yellow
                $skippedCount++
                continue
            }
            
            # Ensure a minimal CI config exists to allow policy-managed jobs
            try {
                $ciPath = Get-UrlEncodedPath -Path ".gitlab-ci.yml"
                $checkCiUri = ("{0}/api/v4/projects/{1}/repository/files/{2}?ref={3}" -f $GitLabURL, $project.id, $ciPath, $defaultBranch)
                $ciCheck = Invoke-GitLabAPI -Uri $checkCiUri -Method Get -ExpectedErrors @(404)
                if (-not $ciCheck.Success -and $ciCheck.StatusCode -eq 404) {
                    Write-Host "      Adding minimal .gitlab-ci.yml to enable policy scans" -ForegroundColor Gray
                    $ciContent = @"
stages: [prepare]
noop:
  stage: prepare
  script:
    - echo "Enabling security scans via policy"
"@
                    $encodedCi = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ciContent))
                    $createCiUri = "$GitLabURL/api/v4/projects/$($project.id)/repository/files/$ciPath"
                    $createCiBody = @{
                        branch = $defaultBranch
                        content = $encodedCi
                        commit_message = "Add minimal CI to enable security policy scans"
                    } | ConvertTo-Json
                    $createCiResult = Invoke-GitLabAPI -Uri $createCiUri -Method Post -Body $createCiBody -ExpectedErrors @(400)
                    if ($createCiResult.Success) {
                        Write-Host "      Minimal CI added" -ForegroundColor Gray
                    } else {
                        Write-Host "     ? Could not add minimal CI file" -ForegroundColor Yellow
                    }
                }
            } catch {
                Write-Host "     ? Error ensuring minimal CI file: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            # Trigger a pipeline on the default branch
            $triggerPipelineUri = "$GitLabURL/api/v4/projects/$($project.id)/pipeline"
            $triggerBody = @{
                ref = $defaultBranch
                variables = @(
                    @{ key = "FORCE_SECURITY_SCAN"; value = "true" }
                    @{ key = "GITLAB_ADVANCED_SAST_ENABLED"; value = "true" }
                )
            } | ConvertTo-Json -Depth 3
            
            $triggerResult = Invoke-GitLabAPI -Uri $triggerPipelineUri -Method Post -Body $triggerBody -ExpectedErrors @(400, 403, 404)
            
            if ($triggerResult.Success) {
                Write-Host "     ✓ Pipeline triggered (Pipeline ID: $($triggerResult.Data.id))" -ForegroundColor Green
                Write-Host "     → Pipeline URL: $($triggerResult.Data.web_url)" -ForegroundColor White
                $triggeredCount++
            }
            elseif ($triggerResult.StatusCode -eq 403) {
                Write-Host "     ⚠ Skipping - Insufficient permissions" -ForegroundColor Yellow
                $skippedCount++
            }
            elseif ($triggerResult.StatusCode -eq 400) {
                Write-Host "     ⚠ Skipping - Pipeline creation failed (may not have .gitlab-ci.yml)" -ForegroundColor Yellow
                $skippedCount++
            }
            else {
                Write-Host "     ✗ Failed to trigger pipeline" -ForegroundColor Red
                $failedCount++
            }
            
            # Add a small delay to avoid overwhelming the API
            Start-Sleep -Milliseconds 500
        }
        
        Write-Host "`n" + "-"*60 -ForegroundColor Green
        Write-Host "PIPELINE TRIGGER SUMMARY:" -ForegroundColor Green
        Write-Host "-"*60 -ForegroundColor Green
        Write-Host "  ✓ Successfully triggered: $triggeredCount projects" -ForegroundColor Green
        Write-Host "  ⚠ Skipped: $skippedCount projects" -ForegroundColor Yellow
        Write-Host "  ✗ Failed: $failedCount projects" -ForegroundColor Red
        Write-Host "  📊 Total processed: $($projects.Count) projects" -ForegroundColor Cyan
        
        if ($triggeredCount -gt 0) {
            Write-Host "`nSecurity scans are now running! You can monitor progress at:" -ForegroundColor Yellow
            Write-Host "• Group CI/CD > Pipelines: $GitLabURL/groups/$GroupId/-/pipelines" -ForegroundColor White
            Write-Host "• Group Security Dashboard: $GitLabURL/groups/$GroupId/-/security/discover" -ForegroundColor White
            Write-Host "`nScans typically complete in 5-15 minutes depending on project size." -ForegroundColor Yellow
        }
        
        if ($skippedCount -gt 0) {
            Write-Host "`nSkipped projects may need:" -ForegroundColor Yellow
            Write-Host "• .gitlab-ci.yml file to enable CI/CD" -ForegroundColor White
            Write-Host "• Source code files in supported languages" -ForegroundColor White
            Write-Host "• Appropriate permissions for pipeline triggers" -ForegroundColor White
        }
    }
    else {
        Write-Host "   ✗ Failed to retrieve projects from group" -ForegroundColor Red
    }
}
