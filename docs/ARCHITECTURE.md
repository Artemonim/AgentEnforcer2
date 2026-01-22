# Architecture: Three-Tier Local CI

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      User / AI-Agent                        │
│                           │                                 │
│                           ▼                                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    run.ps1                           │   │
│  │              (Thin Wrapper Layer)                    │   │
│  │  • Validates CLI flags                               │   │
│  │  • Shows help                                        │   │
│  │  • Forwards to build.ps1                             │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                   build.ps1                          │   │
│  │             (Orchestrator Layer)                     │   │
│  │  • Manages stage execution order                     │   │
│  │  • Handles caching (hash guards, trust stamps)       │   │
│  │  • Runs heartbeat monitoring                         │   │
│  │  • Collects stage results                            │   │
│  │  • Produces final report                             │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                 │
│          ┌────────────────┼─────────────────┐               │
│          ▼                ▼                 ▼               │
│   ┌─────────────┐  ┌─────────────┐  ┌────────────────┐      │
│   │  build.py   │  │  build.rs   │  │  build.<lang>  │      │
│   │  (Python)   │  │   (Rust)    │  │    (<lang>)    │      │
│   │             │  │             │  │                │      │
│   │  Language-  │  │  Language-  │  │  Language-     │      │
│   │  specific   │  │  specific   │  │  specific      │      │
│   │  logic      │  │  logic      │  │  logic         │      │
│   └─────────────┘  └─────────────┘  └────────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

## Layer 1: Thin Wrapper (`run.ps1`)

**Purpose**: Agent-facing entry point with minimal logic.

**Responsibilities**:
- Parse and validate CLI flags
- Detect unknown/invalid parameters early
- Display help text
- Forward execution to `build.ps1`

**Why separate from orchestrator?**
- Keeps the entry point simple and readable: the AI agent will likely read the CI entrypoint anyway, even if it’s not required for the task. When it's "*just*" the full CI interface, you can safely include `run.ps1` into the prompt context entirely.
- Allows different entry points (e.g., `run.ps1`, `ci.ps1`, `check.ps1`)

### Pseudocode

```powershell
# run.ps1 — Thin wrapper

param(
    [switch]$Fast,
    [switch]$SkipTests,
    [switch]$Help
)

# Known parameters for validation
$knownParams = @('Fast', 'SkipTests', 'Help')

# Reject unknown parameters
if ($args) {
    Write-Error "Unknown parameter(s): $($args -join ', ')"
    exit 1
}

# Show help
if ($Help) {
    Show-Help
    exit 0
}

# Forward to orchestrator
& "$PSScriptRoot/build.ps1" @PSBoundParameters
exit $LASTEXITCODE
```

## Layer 2: Orchestrator (`build.ps1`)

**Purpose**: Central control of the CI pipeline.

**Responsibilities**:
- Define stage order and dependencies
- Manage execution profiles
- Fully own the developer-machine execution environment for the target project (what runs around the code)
- Prepare and validate prerequisites (SDKs, toolchains, PATH, env vars, virtualenvs, local infra)
- Manage build/runtime "outer world" concerns (temp dirs, caches, artifacts, log files)
- Handle caching (check hashes, write trust stamps)
- Run commands with heartbeat monitoring
- Collect stage results into structured report
- Handle cleanup and artifact management

**Key Data Structures**:

```powershell
# Stage result object
$StageResult = @{
    Name   = "test"
    Status = "ok"      # ok | warn | fail | cached | skip
    Note   = ""        # Optional details
}

# CI Report (written to .ci_cache/report.json)
$CiReport = @{
    schema_version  = 1
    started_at_utc  = "2024-01-15T10:30:00Z"
    finished_at_utc = "2024-01-15T10:32:45Z"
    duration_ms     = 165000
    status          = "ok"    # ok | warn | fail
    stages          = @()     # Array of StageResult
    issues          = @()     # Array of detected issues
}
```

### Pseudocode

```powershell
# build.ps1 — Orchestrator

param([switch]$Fast, [switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$StageResults = @()
$CacheDir = ".ci_cache"

# Stage execution helper
function Invoke-Stage {
    param([string]$Name, [scriptblock]$Action, [switch]$Critical)
    
    try {
        $result = & $Action
        $StageResults += @{ Name = $Name; Status = "ok" }
    }
    catch {
        $StageResults += @{ Name = $Name; Status = "fail"; Note = $_.Message }
        if ($Critical) { throw }
    }
}

# Run stages
Invoke-Stage -Name "fmt" -Critical -Action {
    # Call language-specific formatter
}

Invoke-Stage -Name "lint" -Critical -Action {
    # Call language-specific linter
}

if (-not $SkipTests) {
    Invoke-Stage -Name "test" -Critical -Action {
        # Call language-specific test runner
    }
}

if (-not $Fast) {
    Invoke-Stage -Name "coverage" -Action {
        # Call language-specific coverage tool
    }
}

# Write final report
Write-CiReport -Stages $StageResults -OutputPath "$CacheDir/report.json"
```

## Layer 3: Language-Specific Logic (`build.<lang>`)

**Purpose**: Encapsulate all language/framework-specific tooling.

**Responsibilities**:
- Configure and run linters (ruff, eslint, clippy, etc.)
- Run test frameworks (pytest, vitest, cargo test, etc.)
- Collect coverage data
- Parse tool outputs into structured format
- Handle language-specific edge cases

**Why separate?**
- Orchestrator remains language-agnostic
- Easy to add new languages without modifying orchestrator
- Language experts can maintain their section independently
- Can be replaced with compiled tools for performance (e.g., Rust CLI)

### Pseudocode (Python)

```python
# build.py — Python-specific CI logic

import subprocess
import json
import sys

TOOLS = {
    "ruff-format": {
        "command": ["ruff", "format", "--check"],
        "fix_command": ["ruff", "format"],
        "critical": False,
    },
    "ruff-lint": {
        "command": ["ruff", "check"],
        "critical": True,
    },
    "pytest": {
        "command": ["pytest", "-q", "--tb=short"],
        "critical": True,
    },
}

def run_tool(name: str, fix: bool = False) -> dict:
    config = TOOLS[name]
    cmd = config.get("fix_command") if fix else config["command"]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    return {
        "tool": name,
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "critical": config["critical"],
    }

def main():
    results = []
    for tool_name in ["ruff-format", "ruff-lint", "pytest"]:
        results.append(run_tool(tool_name))
    
    # Output JSON for orchestrator to consume
    json.dump(results, sys.stdout)

if __name__ == "__main__":
    main()
```

## Data Flow

```
1. User runs: ./run.ps1 -Fast

2. run.ps1:
   - Validates -Fast is known
   - Forwards to build.ps1 -Fast

3. build.ps1:
   - Checks hash cache for "lint" stage
   - Cache hit → skips lint (status: cached)
   - -Fast flag → skips heavy tools
   - Collects all stage results
   - Writes .ci_cache/report.json

4. build.py (called by build.ps1 for Python stages):
   - Runs ruff format --check
   - Runs ruff check
   - Returns JSON with tool results

5. Output:
   - Console: Stage-by-stage status
   - File: .ci_cache/report.json
   - Exit code: 0 (success) or 1 (failure)
```

## Console Summary (High-Signal Output)

The orchestrator should print a compact summary at the end of the run:
- A stable list of stages with `OK | WARN | FAIL | CACHED | SKIP`
- Short notes (coverage %, top offenders, one-line failures)
- Pointers to log files when output is too long or too noisy

**Goal**: the AI agent can iterate on an automatic loop:
`write code → run local CI → fix → repeat`, without the human copy-pasting error logs into chat.

## Directory Structure

```
project/
├── run.ps1              # Thin wrapper (entry point)
├── build.ps1            # Orchestrator
├── build.py             # Python-specific logic (optional)
├── build.ts             # TypeScript-specific logic (optional)
├── tools/
│   └── ci/              # Compiled CI helpers (optional)
│       └── src/
│           └── main.rs
├── .ci_cache/           # Cache directory (gitignored)
│   ├── report.json      # Last CI run report
│   ├── fmt.sha256       # Hash for fmt stage
│   ├── fmt.trusted      # Trust stamp for fmt stage
│   └── logs/            # Command output logs
├── .enforcer/            # Persistent local CI logs
│   ├── Enforcer_last_check.log
│   └── Enforcer_stats.log
└── .ci/                 # CI configuration (optional)
    └── config.json      # Custom thresholds, disabled rules, etc.
```

## When to Use Each Layer

| Task | Layer | Example |
|------|-------|---------|
| Add new CLI flag | `run.ps1` | `[switch]$Verbose` |
| Add new stage | `build.ps1` | Security scanning stage |
| Change caching logic | `build.ps1` | Different hash algorithm |
| Add new linter | `build.<lang>` | Add mypy to Python |
| Parse tool output | `build.<lang>` | Extract coverage % |
| Complex analysis | `tools/ci/` | Coverage ranking algorithm |
