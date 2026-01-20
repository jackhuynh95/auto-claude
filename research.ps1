# ==============================================================================
# Script: research.ps1
# Description: Research a topic and create a GitHub issue with detailed analysis
#
# Usage:       .\research.ps1 "<topic>" ["<description>"] [-Auto]
# Example:     .\research.ps1 "Add dark mode support"
#              .\research.ps1 "Add dark mode" "Support dark mode toggle in settings with system preference detection"
#              .\research.ps1 "Fix login bug" -Auto
# ==============================================================================

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Topic,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$Description = "",

    [Parameter(Mandatory=$false)]
    [switch]$Auto
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$PromptsDir = Join-Path $ScriptDir "prompts"
$LogDir = Join-Path $ProjectRoot "logs"
$LogFile = Join-Path $LogDir "research-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Ensure log directory exists
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ------------------------------------------------------------------------------
# Logging functions
# ------------------------------------------------------------------------------

function Write-Log {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogFile -Value "[$timestamp] $logMessage"
}

function Write-Info { param([string]$Message) Write-Log "INFO" $Message }
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green; Add-Content -Path $LogFile -Value "[OK] $Message" }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow; Add-Content -Path $LogFile -Value "[WARN] $Message" }
function Write-Err { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; Add-Content -Path $LogFile -Value "[ERROR] $Message"; exit 1 }

# ------------------------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------------------------

function Test-Preflight {
    # Check GitHub CLI
    if (!(Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Err "GitHub CLI (gh) not found"
    }

    # Check GitHub auth
    $authStatus = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "GitHub CLI not authenticated"
    }

    # Check Claude CLI
    if (!(Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Err "Claude CLI not found"
    }

    Write-Success "Pre-flight passed"
}

# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

function Get-IssueType {
    param([string]$TopicText)

    $topicLower = $TopicText.ToLower()

    if ($topicLower -match "fix|bug|error|broken|crash") {
        return "bug"
    }
    elseif ($topicLower -match "add|new|create|implement") {
        return "feature"
    }
    else {
        return "enhancement"
    }
}

function Get-Slug {
    param([string]$TopicText)

    $slug = $TopicText.ToLower()
    $slug = $slug -replace '[^a-z0-9]+', '-'
    $slug = $slug -replace '^-|-$', ''
    if ($slug.Length -gt 50) {
        $slug = $slug.Substring(0, 50)
    }
    return $slug
}

function Get-PromptContent {
    param([string]$PromptName)

    $promptFile = Join-Path $PromptsDir "$PromptName.txt"
    if (!(Test-Path $promptFile)) {
        Write-Err "Prompt file not found: $promptFile"
    }
    return Get-Content -Path $promptFile -Raw
}

# ------------------------------------------------------------------------------
# Research via Claude
# ------------------------------------------------------------------------------

function Invoke-Research {
    Write-Info "Researching: $Topic"
    if ($Description) {
        Write-Info "Description: $Description"
    }

    $slug = Get-Slug -TopicText $Topic
    $today = Get-Date -Format "yyyy-MM-dd"

    # Research output file path
    $researchDir = Join-Path $ProjectRoot "research"
    if (!(Test-Path $researchDir)) {
        New-Item -ItemType Directory -Path $researchDir -Force | Out-Null
    }
    $script:ResearchFile = Join-Path $researchDir "$slug-$today.md"

    # Load and substitute prompt template
    $prompt = Get-PromptContent -PromptName "research"
    $prompt = $prompt -replace '\{\{TOPIC\}\}', $Topic
    $prompt = $prompt -replace '\{\{DESCRIPTION\}\}', $Description
    $prompt = $prompt -replace '\{\{SLUG\}\}', $slug
    $prompt = $prompt -replace '\{\{DATE\}\}', $today

    # Create temp file for Claude output
    $outputFile = Join-Path $LogDir "research-output-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    # Build Claude command
    $claudeArgs = @("-p", $prompt, "--output-format", "text")
    if ($Auto) {
        $claudeArgs += "--dangerously-skip-permissions"
        Write-Warn "YOLO mode enabled"
    }

    # Run Claude and capture output
    Write-Info "Running Claude research..."
    $output = & claude @claudeArgs 2>&1
    $output | Out-File -FilePath $outputFile -Encoding utf8
    $output | Tee-Object -Append -FilePath $LogFile

    # Save full Claude output as research file (raw output)
    Copy-Item -Path $outputFile -Destination $script:ResearchFile -Force
    Write-Info "Saved research to: $($script:ResearchFile)"

    # Extract issue body from output
    $script:IssueBody = ""
    $content = Get-Content -Path $outputFile -Raw

    if ($content -match '===ISSUE_BODY_START===([\s\S]*?)===ISSUE_BODY_END===') {
        $script:IssueBody = $Matches[1].Trim()
        Write-Info "Extracted structured issue body from Claude output"
    }
    else {
        Write-Warn "No structured issue body found, using fallback template"
    }

    # Clean up temp file
    Remove-Item -Path $outputFile -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# Create GitHub Issue
# ------------------------------------------------------------------------------

function New-GitHubIssue {
    $type = Get-IssueType -TopicText $Topic
    $title = "${type}: $Topic"

    # Truncate title if too long
    if ($title.Length -gt 72) {
        $title = $title.Substring(0, 72)
    }

    Write-Info "Creating GitHub issue..."

    # Use extracted body if available, otherwise fallback
    $body = ""
    if ($script:IssueBody) {
        $body = $script:IssueBody
    }
    else {
        $slug = Get-Slug -TopicText $Topic
        $today = Get-Date -Format "yyyy-MM-dd"
        $body = @"
## Overview

$Topic

> 📊 **Research file:** ``research/$slug-$today.md``
> 📅 **Research date:** $today

---

## Requirements

- [ ] Review research file for full context
- [ ] Implement the requested change
- [ ] Add tests if applicable
- [ ] Update documentation if needed

---

## Definition of Done

- [ ] Feature works as described
- [ ] No regressions introduced

---

*Generated via research.ps1 (fallback template)*
*Use ``/plan #<issue-number>`` to create detailed implementation plan*
"@
    }

    # Create issue
    $issueUrl = gh issue create --title $title --label $type --body $body

    return $issueUrl
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

function Main {
    Write-Host ""
    Write-Info "=========================================="
    Write-Info "Research: $Topic"
    Write-Info "=========================================="

    Set-Location $ProjectRoot
    Test-Preflight

    # Run research (populates $script:IssueBody if Claude outputs structured content)
    Invoke-Research

    $issueUrl = New-GitHubIssue
    $issueNum = if ($issueUrl -match '(\d+)$') { $Matches[1] } else { "?" }

    Write-Host ""
    Write-Success "=========================================="
    Write-Success "RESEARCH COMPLETE"
    Write-Success "=========================================="
    Write-Host "Topic:  $Topic"
    Write-Host "Issue:  #$issueNum"
    Write-Host "URL:    $issueUrl"
    Write-Host ""
    Write-Host "Next:   .\ship-issue.ps1 $issueNum"
    Write-Success "=========================================="
}

# Run main
Main
