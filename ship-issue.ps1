#Requires -Version 5.1
<#
.SYNOPSIS
    Automates GitHub issue -> Plan -> Code -> PR workflow via Claude CLI

.DESCRIPTION
    Ship Issue - Automated GitHub issue implementation workflow
    Designed for CI/CD pipelines and headless automation on Windows

.PARAMETER IssueNumber
    The GitHub issue number to implement

.PARAMETER Auto
    Enable YOLO mode (auto-approve all Claude prompts)

.EXAMPLE
    .\ship-issue.ps1 42
    .\ship-issue.ps1 42 -Auto

.NOTES
    Requirements:
      - Claude CLI installed and authenticated
      - GitHub CLI (gh) installed and authenticated
      - Git configured with push access

    Environment Variables:
      - ANTHROPIC_API_KEY: Required for Claude CLI auth
      - GITHUB_TOKEN: Optional, for gh CLI if not logged in
      - SHIP_AUTO: Set to "true" for YOLO mode (same as -Auto flag)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$IssueNumber,

    [Parameter(Mandatory = $false)]
    [switch]$Auto
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $ProjectRoot "logs\ship-$Timestamp.log"

# Cached issue data (populated by Get-IssueData)
$script:IssueJson = $null
$script:IssueTitle = ""
$script:IssueBody = ""
$script:IssueState = ""
$script:IssueType = ""  # "feat" or "fix"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

function Initialize-Logging {
    $logDir = Split-Path -Parent $LogFile
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [string]$Level,
        [string]$Message,
        [string]$Color = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $logEntry
}

function Write-Info { param([string]$Message) Write-Log "INFO" $Message "Cyan" }
function Write-Success { param([string]$Message) Write-Log "SUCCESS" $Message "Green" }
function Write-Warn { param([string]$Message) Write-Log "WARN" $Message "Yellow" }
function Write-Err { param([string]$Message) Write-Log "ERROR" $Message "Red" }

# ------------------------------------------------------------------------------
# GitHub Issue Data (single API call, reuse with ConvertFrom-Json)
# ------------------------------------------------------------------------------

function Get-IssueData {
    Write-Info "Fetching issue #$IssueNumber data..."

    # Single API call - fetch all needed fields
    # Temporarily disable error action to capture gh errors
    $prevErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $jsonOutput = gh issue view $IssueNumber --json title,body,state,labels 2>&1
    $ghExitCode = $LASTEXITCODE

    $ErrorActionPreference = $prevErrorAction

    if ($ghExitCode -ne 0) {
        Write-Err "Failed to fetch issue #$IssueNumber. Issue may not exist."
        Write-Err "GitHub CLI output: $jsonOutput"
        exit 1
    }

    try {
        $script:IssueJson = $jsonOutput | ConvertFrom-Json
    } catch {
        Write-Err "Failed to parse issue data: $_"
        exit 1
    }

    if (-not $script:IssueJson -or -not $script:IssueJson.title) {
        Write-Err "Issue #$IssueNumber not found or has no title."
        exit 1
    }

    # Extract fields
    $script:IssueTitle = $script:IssueJson.title
    $script:IssueBody = if ($script:IssueJson.body) { $script:IssueJson.body } else { "" }
    $script:IssueState = $script:IssueJson.state

    # Determine type: fix for bugs, feat for others
    $hasBug = $script:IssueJson.labels | Where-Object { $_.name -eq "bug" }
    if ($hasBug) {
        $script:IssueType = "fix"
    } else {
        $script:IssueType = "feat"
    }

    Write-Success "Issue data cached (title: $($script:IssueTitle), type: $($script:IssueType))"
}

# ------------------------------------------------------------------------------
# GitHub Issue Commenting
# ------------------------------------------------------------------------------

function Add-IssueComment {
    param(
        [string]$FilePath,
        [string]$Message
    )

    if ($FilePath -and (Test-Path $FilePath)) {
        Write-Info "Posting comment from file to issue #$IssueNumber..."
        gh issue comment $IssueNumber --body-file $FilePath
        Write-Success "Comment posted to issue #$IssueNumber"
    } elseif ($Message) {
        Write-Info "Posting comment to issue #$IssueNumber..."
        gh issue comment $IssueNumber --body $Message
        Write-Success "Comment posted to issue #$IssueNumber"
    } else {
        Write-Warn "No file or message provided for comment"
    }
}

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------

function Test-Preflight {
    Write-Info "Running pre-flight checks..."

    # Check Claude CLI
    if (-not (Get-Command "claude" -ErrorAction SilentlyContinue)) {
        Write-Err "Claude CLI not found. Install it first."
        exit 1
    }

    # Check GitHub CLI
    if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
        Write-Err "GitHub CLI (gh) not found. Install it first."
        exit 1
    }

    # Check gh auth
    $authStatus = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "GitHub CLI not authenticated. Run 'gh auth login' first."
        exit 1
    }

    # Fetch and cache issue data (single API call)
    Get-IssueData

    # Check issue is open
    if ($script:IssueState -ne "OPEN") {
        Write-Err "Issue #$IssueNumber is not open (state: $($script:IssueState))"
        exit 1
    }

    # Check clean working tree
    $gitStatus = git status --porcelain
    if ($gitStatus) {
        Write-Warn "Working tree not clean. Stashing changes..."
        git stash push -m "auto-stash-ship-$IssueNumber"
    }

    Write-Success "Pre-flight checks passed"
}

# ------------------------------------------------------------------------------
# Claude CLI Wrapper
# ------------------------------------------------------------------------------

function Invoke-Claude {
    param([string]$Prompt)

    $flags = @()

    # Determine mode
    if ($Auto -or $env:SHIP_AUTO -eq "true") {
        $flags += "--dangerously-skip-permissions"
        Write-Warn "Running in YOLO mode (auto-approve enabled)"
    }

    Write-Info "Executing Claude command..."

    # Run Claude with prompt
    $allArgs = @("-p", $Prompt) + $flags + @("--continue", "--output-format", "text")
    $output = & claude @allArgs 2>&1 | Tee-Object -FilePath $LogFile -Append

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Claude command failed with exit code $LASTEXITCODE"
        throw "Claude command failed"
    }

    return $output
}

# ------------------------------------------------------------------------------
# Workflow Steps
# ------------------------------------------------------------------------------

function Step-1-BranchSetup {
    Write-Info "Step 1: Issue Analysis & Branch Setup"

    # Create slug from title
    $slug = $script:IssueTitle.ToLower() -replace '[^a-z0-9]', '-' -replace '--+', '-'
    $slug = $slug.Substring(0, [Math]::Min(40, $slug.Length))
    $branch = "$($script:IssueType)/issue-$IssueNumber-$slug"

    # Create branch
    $existingBranch = git branch --list $branch
    if ($existingBranch) {
        Write-Warn "Branch $branch already exists, checking out..."
        git checkout $branch
    } else {
        git checkout -b $branch
    }

    Write-Success "Step 1 complete: Branch $branch"
    return $branch
}

function Step-2-Planning {
    param([string]$Branch)

    Write-Info "Step 2: Planning Phase"

    $issueContent = @"
$($script:IssueTitle)

$($script:IssueBody)
"@

    # Run planning command via Claude
    Invoke-Claude "/plan:fast Implement GitHub issue #$IssueNumber`:

$issueContent

Create implementation plan following project conventions."

    Write-Success "Step 2 complete: Plan created"
}

function Step-3-Implementation {
    Write-Info "Step 3: Implementation Phase"

    # Find latest plan
    $planFiles = Get-ChildItem -Path ".\plans" -Filter "plan.md" -Recurse -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 1

    if (-not $planFiles) {
        Write-Err "No plan found. Step 2 may have failed."
        exit 1
    }

    $planPath = $planFiles.FullName

    # Run implementation
    Invoke-Claude "/code:auto $planPath"

    Write-Success "Step 3 complete: Implementation done"
}

function Step-3b-PostReports {
    Write-Info "Step 3b: Post Reports to Issue"

    # Only scan apps/**/*report*.md (temporary test reports)
    # Skip plans/reports/*.md (permanent documentation - don't delete)
    $appReports = Get-ChildItem -Path ".\apps" -Filter "*report*.md" -Recurse -File -ErrorAction SilentlyContinue

    if (-not $appReports) {
        Write-Info "No report files found in apps/"
        return
    }

    foreach ($report in $appReports) {
        Write-Info "Found report: $($report.FullName)"
        Add-IssueComment -FilePath $report.FullName
        # Cleanup: remove after posting
        Write-Info "Removing: $($report.FullName)"
        Remove-Item -Path $report.FullName -Force
    }

    Write-Success "Reports posted and cleaned up"
}

function Step-4-Commit {
    Write-Info "Step 4: Commit Changes"

    # Check if there are changes to commit
    $gitStatus = git status --porcelain
    if (-not $gitStatus) {
        Write-Warn "No changes to commit"
        return
    }

    # Stage and commit
    git add -A

    $commitMessage = @"
$($script:IssueType)(#$IssueNumber): $($script:IssueTitle)

Closes #$IssueNumber

Implemented via automated ship workflow.
"@

    git commit -m $commitMessage

    Write-Success "Step 4 complete: Changes committed"
}

function Step-5-CreatePR {
    Write-Info "Step 5: Create Pull Request"

    $branch = git branch --show-current

    # Push branch
    git push -u origin HEAD

    # Create PR body
    $diffStat = git diff --stat origin/main...HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        $diffStat = "See commits"
    }

    $prBody = @"
## Summary
Automated implementation for issue #$IssueNumber

## Related Issue
Closes #$IssueNumber

## Changes
$diffStat

---
*Generated by ship-issue.ps1 automation*
"@

    # Create PR
    $prUrl = gh pr create `
        --base main `
        --title "$($script:IssueType)(#$IssueNumber): $($script:IssueTitle)" `
        --body $prBody

    # Add 'shipped' label to issue (keeps issue open for manual testing)
    Write-Info "Adding 'shipped' label to issue #$IssueNumber..."
    $labelResult = gh issue edit $IssueNumber --add-label "shipped" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not add 'shipped' label (may not exist). Creating it..."
        gh label create "shipped" --description "Implementation complete, awaiting verification" --color "7057ff" 2>&1 | Out-Null
        gh issue edit $IssueNumber --add-label "shipped"
    }

    Write-Success "Step 5 complete: PR created, issue labeled as 'shipped'"
    return $prUrl
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

function Main {
    Write-Info "=========================================="
    Write-Info "Ship Issue #$IssueNumber"
    Write-Info "=========================================="

    Push-Location $ProjectRoot
    try {
        Initialize-Logging

        # Pre-flight
        Test-Preflight

        # Execute workflow
        $branch = Step-1-BranchSetup
        Step-2-Planning -Branch $branch
        Step-3-Implementation
        Step-3b-PostReports
        Step-4-Commit
        $prUrl = Step-5-CreatePR

        # Summary
        Write-Host ""
        Write-Host "=========================================="
        Write-Success "SHIP COMPLETE"
        Write-Host "=========================================="
        Write-Host "Issue:    #$IssueNumber"
        Write-Host "Branch:   $branch"
        Write-Host "PR:       $prUrl"
        Write-Host "Log:      $LogFile"
        Write-Host "=========================================="
    }
    finally {
        Pop-Location
    }
}

# Run if executed directly
Main
