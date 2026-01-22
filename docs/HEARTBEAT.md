# Heartbeat: Watchdog Patterns for Hang Detection

## The Problem

Long-running stages can:
- Hang silently (deadlocks, infinite loops)
- Appear stuck when actually progressing slowly
- Timeout without useful diagnostics

Without heartbeat monitoring, you stare at a frozen terminal wondering if it's working.

## The Solution: Heartbeat Monitoring

Periodically output progress information during long-running commands:

```
[heartbeat] coverage alive t+00:01:00 last-out=5s line='running test_integration'
[heartbeat] coverage alive t+00:02:00 last-out=3s line='test result: ok. 50 passed'
[heartbeat] coverage alive t+00:03:00 last-out=45s line='test result: ok. 50 passed'
[heartbeat] coverage appears stuck: no output for 60s, terminating...
```

Heartbeat is not only a monitor: it is a watchdog that can terminate hung or timed-out processes and still produce a report and log pointers.

### Real-World Example ([LivingLayers-style](https://livinglayers.ru/?utm_source=github&utm_medium=organic&utm_campaign=agentenforcer2&utm_content=heartbeat.md))

Some projects choose to enrich heartbeat lines with extra context, especially when output is captured to a log:

```
[heartbeat] coverage output captured to: cargo_coverage_20260122_115735_40278d.log (temp; kept on failure)
cargo run --manifest-path tools/ll-ci/Cargo.toml -- coverage
[heartbeat] coverage alive t+00:01:00 last-out=60s line='[stderr] Running `target\debug\ll-ci.exe coverage`' pid=40268 hidden log=cargo_coverage_20260122_115735_40278d.log procs=cargo.exe x3, ll-ci.exe x1 target=1 phase=run arm-in=300s
[heartbeat] coverage alive t+00:05:00 last-out=300s line='[stderr] Running `target\debug\ll-ci.exe coverage`' pid=40268 hidden log=cargo_coverage_20260122_115735_40278d.log phase=compile procs=rustc.exe x4, sccache.exe x4, cargo.exe x3 target=1 arm-in=60s
[heartbeat] coverage alive t+00:07:00 last-out=15s line='[stderr] warning: --no-run is deprecated ...' pid=40268 hidden log=cargo_coverage_20260122_115735_40278d.log phase=coverage procs=cargo-llvm-cov.exe x1, cargo.exe x3 same=1/3
```

Notes:
- `pid`, `procs`, and `phase` help distinguish a real hang from a slow compile/link step.
- `arm-in` makes hang detection behavior predictable (detection starts only after a warm-up period).
- `same=1/3` counter of identical snapshots before interruption.

## Heartbeat Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `HeartbeatSec` | 60 | Interval between heartbeat messages |
| `TimeoutSec` | 0 | Max runtime before force-kill (0 = disabled) |
| `SameLineHangPulses` | 3 | Consecutive heartbeats with same output = hang |
| `SameLineHangMinSec` | 360 | Minimum runtime before hang detection kicks in |

## Hang Detection Strategies

### 1. No Output Timeout

Kill process if no stdout/stderr for X seconds.

```
if (seconds_since_last_output > 120):
    mark_as_hung()
    kill_process()
```

**Problem**: Some stages legitimately produce no output for extended periods.

### 2. Same-Line Detection

Kill process if the last output line repeats across N consecutive heartbeats.

```
if (last_output_line == previous_last_output_line):
    same_line_streak++
    if (same_line_streak >= SameLineHangPulses AND runtime > SameLineHangMinSec):
        mark_as_hung()
        kill_process()
else:
    same_line_streak = 0
```

**Better**: Catches "stuck at 99%" scenarios without false positives on slow tests.

### 3. Progress Signature

Extract a "progress signature" from output (e.g., test count) and detect if it stops advancing.

```
# Parse test runner output
signature = extract_progress(output)  # e.g., "142/500 tests"

if (signature == previous_signature):
    stall_count++
else:
    stall_count = 0
    previous_signature = signature
```

## Pseudocode Implementation

```powershell
function Invoke-CommandWithHeartbeat {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$Label,
        [int]$HeartbeatSec = 60,
        [int]$TimeoutSec = 0,
        [int]$SameLineHangPulses = 3,
        [int]$SameLineHangMinSec = 360
    )
    
    $startTime = Get-Date
    $lastOutputTime = Get-Date
    $lastOutputLine = ""
    $sameLineStreak = 0
    $outputBuffer = [System.Collections.ArrayList]::new()
    
    # Start process with redirected output
    $process = Start-Process -FilePath $Command -ArgumentList $Arguments `
        -NoNewWindow -PassThru -RedirectStandardOutput "stdout.tmp" -RedirectStandardError "stderr.tmp"
    
    # Monitor loop
    while (-not $process.HasExited) {
        Start-Sleep -Seconds $HeartbeatSec
        
        $elapsed = (Get-Date) - $startTime
        $sinceLast = (Get-Date) - $lastOutputTime
        
        # Read new output
        $newOutput = Get-TailOutput -Path "stdout.tmp"
        if ($newOutput) {
            $lastOutputTime = Get-Date
            $currentLine = $newOutput | Select-Object -Last 1
        }
        
        # Heartbeat message
        $snippet = if ($currentLine.Length -gt 60) { 
            $currentLine.Substring(0, 57) + "..." 
        } else { 
            $currentLine 
        }
        Write-Host "[heartbeat] $Label alive t+$($elapsed.ToString('hh\:mm\:ss')) last-out=$([int]$sinceLast.TotalSeconds)s line='$snippet'"
        
        # Same-line hang detection
        if ($currentLine -eq $lastOutputLine) {
            $sameLineStreak++
            if ($sameLineStreak -ge $SameLineHangPulses -and 
                $elapsed.TotalSeconds -gt $SameLineHangMinSec) {
                Write-Warning "[heartbeat] $Label appears stuck: same output for $sameLineStreak heartbeats"
                $process.Kill()
                return @{ ExitCode = -1; Hung = $true }
            }
        } else {
            $sameLineStreak = 0
            $lastOutputLine = $currentLine
        }
        
        # Timeout check
        if ($TimeoutSec -gt 0 -and $elapsed.TotalSeconds -gt $TimeoutSec) {
            Write-Warning "[heartbeat] $Label timed out after $TimeoutSec seconds"
            $process.Kill()
            return @{ ExitCode = -1; TimedOut = $true }
        }
    }
    
    return @{ ExitCode = $process.ExitCode; Hung = $false; TimedOut = $false }
}
```

## Output Logging

Capture full output to log files for post-mortem analysis:

```powershell
$logDir = ".ci_cache/logs"
$logPath = Join-Path $logDir "$Label_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"

# Write header
@"
---
command: $Command $($Arguments -join ' ')
started: $(Get-Date -Format 'o')
---
"@ | Set-Content $logPath

# Append output during execution
$output | Add-Content $logPath

# Write footer on completion
@"
---
exit_code: $exitCode
elapsed_ms: $elapsedMs
---
"@ | Add-Content $logPath
```

## Integration with Orchestrator

```powershell
# build.ps1

$coverageResult = Invoke-CommandWithHeartbeat `
    -Command "cargo" `
    -Arguments @("llvm-cov", "--workspace", "--all-features") `
    -Label "coverage" `
    -HeartbeatSec $HeartbeatSec `
    -TimeoutSec $CoverageTimeoutSec `
    -SameLineHangPulses $HeartbeatSameLinePulses `
    -SameLineHangMinSec $HeartbeatSameLineMinSec

if ($coverageResult.Hung) {
    $StageResults += @{ Name = "coverage"; Status = "fail"; Note = "Process hung" }
} elseif ($coverageResult.TimedOut) {
    $StageResults += @{ Name = "coverage"; Status = "fail"; Note = "Timed out" }
} elseif ($coverageResult.ExitCode -ne 0) {
    $StageResults += @{ Name = "coverage"; Status = "fail"; Note = "Exit code: $($coverageResult.ExitCode)" }
} else {
    $StageResults += @{ Name = "coverage"; Status = "ok" }
}
```

## CLI Flags for Heartbeat Control

```powershell
param(
    [int]$HeartbeatSec = 60,
    [int]$HeartbeatSameLinePulses = 3,
    [int]$HeartbeatSameLineMinSec = 360,
    [int]$CoverageTimeoutSec = 0
)
```

Usage:
```bash
# Faster heartbeat for debugging
./run.ps1 -HeartbeatSec 10

# Disable hang detection (useful for known-slow tests)
./run.ps1 -HeartbeatSameLinePulses 0

# Set hard timeout for coverage
./run.ps1 -CoverageTimeoutSec 600
```

## Best Practices

1. **Don't suppress output**: Heartbeat needs output to detect progress
2. **Log everything**: Full logs are essential for debugging hangs
3. **Tune thresholds per project**: A 3-minute hang is normal for some test suites
4. **Fail gracefully**: Hung processes should still produce a report
5. **Clean up**: Kill child processes, remove temp files on hang/timeout
