# =============================================================================
# build.ps1 — Orchestrator
# =============================================================================
# Central CI orchestration: stage execution, caching, reporting.
#
# This is a template. Adapt stages, tools, and paths to your project.
# =============================================================================

#region Parameters
param(
    [switch]$Fast,
    [switch]$Release,
    [switch]$SkipLint,
    [switch]$SkipTests,
    [switch]$SkipCoverage,
    [switch]$SkipLaunch,
    [switch]$NoCache,
    [switch]$Clean,
    [int]$HeartbeatSec = 60,
    [switch]$Help
)
#endregion Parameters

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Configuration
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptRoot

$CacheDir = Join-Path $ScriptRoot ".ci_cache"
$ReportPath = Join-Path $CacheDir "report.json"

$EnforcerDir = Join-Path $ScriptRoot ".enforcer"
$EnforcerLastCheckPath = Join-Path $EnforcerDir "Enforcer_last_check.log"
$EnforcerStatsPath = Join-Path $EnforcerDir "Enforcer_stats.log"

# Create cache directory
if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir | Out-Null
}

# Create Enforcer logs directory (gitignored; manual cleanup)
if (-not (Test-Path $EnforcerDir)) {
    New-Item -ItemType Directory -Path $EnforcerDir | Out-Null
}

# Clean mode
if ($Clean) {
    Write-Host "Cleaning cache directory..." -ForegroundColor Yellow
    Remove-Item -Path $CacheDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $CacheDir | Out-Null
}

$script:CiStartTime = Get-Date
$script:StageResults = @()
$script:Issues = @()
#endregion Configuration

#region Sound (optional, recommended)
# * Adds audible markers for CI progress/completion if sound assets are present.
# * Recommended for local CI: it makes failures and completion noticeable even when the window is not focused.
$CiSoundRoot = Join-Path $ScriptRoot "assets/ci_sounds"
$CiSoundMap = @{
    success = Join-Path $CiSoundRoot "ci_success.opus"
    failure = Join-Path $CiSoundRoot "ci_failure.opus"
    launch  = Join-Path $CiSoundRoot "ci_launch.opus"
}

$CiSoundEnabled = $false
if (Test-Path -Path $CiSoundRoot -PathType Container) {
    $missing = @()
    foreach ($kind in @("success", "failure", "launch")) {
        $path = $CiSoundMap[$kind]
        if (-not $path -or -not (Test-Path -Path $path -PathType Leaf)) {
            $missing += $kind
        }
    }

    if ($missing.Count -eq 0) {
        $CiSoundEnabled = $true
    } else {
        Write-Warning ("[sound] Sound assets folder exists, but some files are missing: {0}" -f ($missing -join ", "))
    }
}

$script:CiFailed = $false
$script:CiFailureSoundPlayed = $false

function Invoke-CiSound {
    param(
        [ValidateSet("success", "failure", "launch")]
        [string]$Kind
    )

    if (-not $CiSoundEnabled) {
        return
    }

    $path = $CiSoundMap[$Kind]
    if (-not $path -or -not (Test-Path -Path $path -PathType Leaf)) {
        Write-Warning ("[sound] Missing {0} sound file: {1}" -f $Kind, $path)
        return
    }

    $player = $null
    foreach ($candidate in @("ffplay", "mpv", "vlc")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            $player = @{ Name = $candidate; Path = $cmd.Source }
            break
        }
    }

    if (-not $player) {
        Write-Warning "[sound] No audio player found (searched: ffplay, mpv, vlc)."
        return
    }

    $playerArgs = switch ($player.Name) {
        "ffplay" { @("-nodisp", "-autoexit", "-loglevel", "quiet", $path) }
        "mpv"    { @("--no-video", "--quiet", $path) }
        "vlc"    { @("--intf", "dummy", "--play-and-exit", "--no-video", $path) }
        default  { @($path) }
    }

    try {
        # * Avoids conflict with PowerShell 6+ built-in $IsWindows (case-insensitive variable names).
        $ciIsWindows = $false
        $isWindowsBuiltIn = Get-Variable -Name "IsWindows" -ErrorAction SilentlyContinue
        if ($isWindowsBuiltIn) {
            $ciIsWindows = [bool]$IsWindows
        } elseif ($env:OS -eq "Windows_NT") {
            $ciIsWindows = $true
        }

        if ($ciIsWindows) {
            Start-Process -FilePath $player.Path -ArgumentList $playerArgs -WindowStyle Hidden | Out-Null
        } else {
            Start-Process -FilePath $player.Path -ArgumentList $playerArgs | Out-Null
        }
    } catch {
        Write-Warning ("[sound] Failed to play {0} sound: {1}" -f $Kind, $_.Exception.Message)
    }
}

function Invoke-FailureSoundOnce {
    if ($script:CiFailureSoundPlayed) {
        return
    }
    $script:CiFailureSoundPlayed = $true
    Invoke-CiSound -Kind "failure"
}

#endregion Sound

#region Helpers
function Add-StageResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Note = ""
    )
    $script:StageResults += @{
        name = $Name
        status = $Status
        note = $Note
    }
}

function Add-Issue {
    param(
        [string]$Language,
        [string]$Tool,
        [string]$Rule,
        [int]$Count = 1,
        [string]$Message = ""
    )
    $script:Issues += @{
        language = $Language
        tool = $Tool
        rule = $Rule
        count = $Count
        message = $Message
    }
}

function Get-ContentHash {
    param([string[]]$Paths)
    
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $allBytes = [System.Collections.ArrayList]::new()
    
    foreach ($pattern in $Paths) {
        $files = Get-ChildItem -Path $pattern -Recurse -File -ErrorAction SilentlyContinue | 
                 Sort-Object FullName
        foreach ($file in $files) {
            $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($file.FullName)
            [void]$allBytes.AddRange($pathBytes)
            $contentBytes = [System.IO.File]::ReadAllBytes($file.FullName)
            [void]$allBytes.AddRange($contentBytes)
        }
    }
    
    $hash = $hasher.ComputeHash([byte[]]$allBytes.ToArray())
    return [BitConverter]::ToString($hash).Replace("-", "").ToLower()
}

function Test-StageCache {
    param(
        [string]$StageName,
        [string[]]$InputPaths
    )
    
    if ($NoCache) { return $false }
    
    $hashFile = Join-Path $CacheDir "$StageName.sha256"
    $trustFile = Join-Path $CacheDir "$StageName.trusted"
    
    $currentHash = Get-ContentHash -Paths $InputPaths
    $storedHash = if (Test-Path $hashFile) { Get-Content $hashFile } else { "" }
    
    if ($currentHash -eq $storedHash -and (Test-Path $trustFile)) {
        return $true
    }
    
    # Store hash for later write on success
    $script:CurrentStageHash = $currentHash
    return $false
}

function Write-StageCache {
    param([string]$StageName)
    
    $hashFile = Join-Path $CacheDir "$StageName.sha256"
    $trustFile = Join-Path $CacheDir "$StageName.trusted"
    
    if ($script:CurrentStageHash) {
        Set-Content -Path $hashFile -Value $script:CurrentStageHash
        New-Item -ItemType File -Path $trustFile -Force | Out-Null
    }
}

function Write-CiReport {
    $overallStatus = if ($script:StageResults | Where-Object { $_.status -eq "fail" }) {
        "fail"
    } elseif ($script:StageResults | Where-Object { $_.status -eq "warn" }) {
        "warn"
    } else {
        "ok"
    }
    
    $report = @{
        schema_version = 1
        started_at_utc = $script:CiStartTime.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        duration_ms = [int]((Get-Date) - $script:CiStartTime).TotalMilliseconds
        status = $overallStatus
        stages = $script:StageResults
        issues = $script:Issues
    }
    
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $ReportPath
}
#endregion Helpers

#region Stage Execution
function Invoke-Stage {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [switch]$Critical,
        [string[]]$CacheInputs
    )
    
    Write-Host ""
    Write-Host ("═" * 20 + " $Name " + "═" * 20) -ForegroundColor Cyan
    
    # Check cache
    if ($CacheInputs -and (Test-StageCache -StageName $Name -InputPaths $CacheInputs)) {
        Write-Host "Cache hit, skipping." -ForegroundColor DarkGray
        Add-StageResult -Name $Name -Status "cached" -Note "Cache hit"
        return
    }
    
    try {
        & $Action
        Add-StageResult -Name $Name -Status "ok"
        
        # Write cache on success
        if ($CacheInputs) {
            Write-StageCache -StageName $Name
        }
    }
    catch {
        Add-StageResult -Name $Name -Status "fail" -Note $_.Exception.Message

        if (-not $script:CiFailed) {
            $script:CiFailed = $true
            Invoke-FailureSoundOnce
        }
        
        if ($Critical) {
            Write-Host "Critical stage failed, stopping pipeline." -ForegroundColor Red
            throw
        }
    }
}
#endregion Stage Execution

#region Stages
try {
    # ─────────────────────────────────────────────────────────────────────────
    # Stage: self-check (CI checks itself)
    # ─────────────────────────────────────────────────────────────────────────
    Invoke-Stage -Name "self-check" -Critical -CacheInputs @("run.ps1", "build.ps1") -Action {
        # TODO: Validate CI scripts/configs before checking the target project.
        # PowerShell ideas:
        # - Parser diagnostics: [System.Management.Automation.Language.Parser]::ParseFile(...)
        # - PSScriptAnalyzer (optional): Invoke-ScriptAnalyzer -Path ...
        Write-Host "Self-checking CI scripts..." -ForegroundColor DarkGray
        # Placeholder - implement for your environment
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Stage: fmt
    # ─────────────────────────────────────────────────────────────────────────
    if (-not $SkipLint) {
        Invoke-Stage -Name "fmt" -Critical -CacheInputs @("src/**/*.py") -Action {
            # TODO: Replace with your formatter
            # Example for Python:
            #   & ruff format --check src/
            # Example for Rust:
            #   & cargo fmt --all -- --check
            Write-Host "Running formatter..." -ForegroundColor DarkGray
            # Placeholder - implement for your language
        }
    } else {
        Add-StageResult -Name "fmt" -Status "skip" -Note "SkipLint"
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # Stage: line-limits
    # ─────────────────────────────────────────────────────────────────────────
    if (-not $SkipLint) {
        Invoke-Stage -Name "line-limits" -CacheInputs @("src/**") -Action {
            # TODO: Enforce max LOC / max files-per-dir rules (human + LLM maintainability).
            # Example:
            #   & tools/ci/line-limits --warn-lines 1500 --fail-lines 2500 --root src
            Write-Host "Checking line limits..." -ForegroundColor DarkGray
            # Placeholder - implement for your project
        }
    } else {
        Add-StageResult -Name "line-limits" -Status "skip" -Note "SkipLint"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Stage: lint
    # ─────────────────────────────────────────────────────────────────────────
    if (-not $SkipLint) {
        Invoke-Stage -Name "lint" -Critical -CacheInputs @("src/**/*.py", "pyproject.toml") -Action {
            # TODO: Replace with your linter
            # Example for Python:
            #   & ruff check src/
            # Example for Rust:
            #   & cargo clippy --all-features -- -D warnings
            Write-Host "Running linter..." -ForegroundColor DarkGray
            # Placeholder - implement for your language
        }
    } else {
        Add-StageResult -Name "lint" -Status "skip" -Note "SkipLint"
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # Stage: compile
    # ─────────────────────────────────────────────────────────────────────────
    Invoke-Stage -Name "compile" -Critical -Action {
        # TODO: Replace with your type checker / compiler
        # Example for Python:
        #   & mypy src/
        # Example for Rust:
        #   & cargo check --all-features
        # Example for TypeScript:
        #   & npx tsc --noEmit
        Write-Host "Running compile/type check..." -ForegroundColor DarkGray
        # Placeholder - implement for your language
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # Stage: test
    # ─────────────────────────────────────────────────────────────────────────
    $runTests = -not $Fast -and -not $SkipTests
    if ($runTests) {
        Invoke-Stage -Name "test" -Critical -Action {
            # TODO: Replace with your test runner
            # Example for Python:
            #   & pytest -q --tb=short
            # Example for Rust:
            #   & cargo test --all-features
            Write-Host "Running tests..." -ForegroundColor DarkGray
            # Placeholder - implement for your language
        }
    } else {
        $skipNote = if ($Fast) { "Fast mode" } else { "SkipTests" }
        Add-StageResult -Name "test" -Status "skip" -Note $skipNote
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # Stage: coverage
    # ─────────────────────────────────────────────────────────────────────────
    $runCoverage = -not $Fast -and -not $SkipCoverage
    if ($runCoverage) {
        Invoke-Stage -Name "coverage" -Action {
            # TODO: Replace with your coverage tool
            # Example for Python:
            #   & pytest --cov=src --cov-report=term
            # Example for Rust:
            #   & cargo llvm-cov --all-features
            Write-Host "Collecting coverage..." -ForegroundColor DarkGray
            # Placeholder - implement for your language
        }
    } else {
        $skipNote = if ($Fast) { "Fast mode" } else { "SkipCoverage" }
        Add-StageResult -Name "coverage" -Status "skip" -Note $skipNote
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # Stage: build (Release only)
    # ─────────────────────────────────────────────────────────────────────────
    if ($Release) {
        Invoke-Stage -Name "build" -Critical -Action {
            # TODO: Replace with your build command
            # Example for Rust:
            #   & cargo build --release
            Write-Host "Building release..." -ForegroundColor DarkGray
            # Placeholder - implement for your language
        }
    }
    
}
catch {
    Write-Host "Pipeline failed: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $script:CiFailed) {
        $script:CiFailed = $true
        Invoke-FailureSoundOnce
    }
}
finally {
    # ─────────────────────────────────────────────────────────────────────────
    # Summary
    # ─────────────────────────────────────────────────────────────────────────
    Write-CiReport

    # Write Enforcer logs (last snapshot + append-only stats)
    try {
        $reportJson = Get-Content -Path $ReportPath -Raw
        Set-Content -Path $EnforcerLastCheckPath -Value $reportJson

        $started = $script:CiStartTime.ToUniversalTime().ToString("o")
        $finished = (Get-Date).ToUniversalTime().ToString("o")
        Add-Content -Path $EnforcerStatsPath -Value ("--- Check started at {0} ---" -f $started)
        foreach ($issue in $script:Issues) {
            if ($null -eq $issue) { continue }
            $lang = $issue.language
            $tool = $issue.tool
            $rule = $issue.rule
            $count = $issue.count
            $msg = $issue.message
            Add-Content -Path $EnforcerStatsPath -Value ("{0}: [{1}] {2} — {3} (x{4})" -f $lang, $tool, $rule, $msg, $count)
        }
        $overall = "ok"
        if ($script:StageResults | Where-Object { $_.status -eq "fail" }) { $overall = "fail" }
        elseif ($script:StageResults | Where-Object { $_.status -eq "warn" }) { $overall = "warn" }
        Add-Content -Path $EnforcerStatsPath -Value ("--- Check finished at {0} (status={1}) ---" -f $finished, $overall)
        Add-Content -Path $EnforcerStatsPath -Value ""
    } catch {
        Write-Host ("Failed to write Enforcer logs: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host ("═" * 20 + " SUMMARY " + "═" * 20) -ForegroundColor Cyan
    
    foreach ($stage in $script:StageResults) {
        $color = switch ($stage.status) {
            "ok"   { "Green" }
            "warn" { "Yellow" }
            "fail" { "Red" }
            "cached" { "Cyan" }
            "skip" { "DarkGray" }
            default { "White" }
        }
        $note = if ($stage.note) { " ($($stage.note))" } else { "" }
        Write-Host ("  {0,-15} {1}{2}" -f $stage.name, $stage.status.ToUpper(), $note) -ForegroundColor $color
    }
    
    $duration = [int]((Get-Date) - $script:CiStartTime).TotalSeconds
    Write-Host ""
    Write-Host "Duration: ${duration}s" -ForegroundColor DarkGray
    Write-Host "Report: $ReportPath" -ForegroundColor DarkGray
    
    # Exit code based on overall status
    $hasFail = $script:StageResults | Where-Object { $_.status -eq "fail" }
    if ($hasFail) {
        # * Ensures the failure marker plays even if the failure originated outside Invoke-Stage.
        if (-not $script:CiFailed) {
            $script:CiFailed = $true
            Invoke-FailureSoundOnce
        }
        exit 1
    }

    # * Emits an audible "completion" marker for successful runs.
    if ($SkipLaunch) {
        Invoke-CiSound -Kind "success"
    }
}
#endregion Stages

#region Launch (optional)
if (-not $SkipLaunch -and -not $hasFail) {
    Write-Host ""
    Write-Host "Launching application..." -ForegroundColor Cyan
    Invoke-CiSound -Kind "launch"
    # TODO: Add your launch command here
    # Example:
    #   & python -m myapp
    #   & cargo run
}
#endregion Launch

