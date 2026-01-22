# Report Format: CI Output Schema

## Purpose

A structured JSON report enables:
- Programmatic analysis of CI results
- Historical tracking of issues over time
- Integration with external tools (dashboards, notifications)
- Reproducible debugging (exact timestamps, durations)

## Schema Overview

```json
{
  "schema_version": 1,
  "started_at_utc": "2024-01-15T10:30:00Z",
  "finished_at_utc": "2024-01-15T10:32:45Z",
  "duration_ms": 165000,
  "status": "warn",
  "stages": [...],
  "issues": [...],
  "metrics": {...}
}
```

## Full Schema

### Root Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | yes | Schema version for forward compatibility |
| `started_at_utc` | string (ISO 8601) | yes | CI run start timestamp |
| `finished_at_utc` | string (ISO 8601) | yes | CI run end timestamp |
| `duration_ms` | integer | yes | Total duration in milliseconds |
| `status` | string | yes | Overall status: `ok`, `warn`, `fail` |
| `stages` | array | yes | List of stage results |
| `issues` | array | yes | List of detected issues |
| `metrics` | object | no | Optional metrics (coverage, etc.) |

### Stage Object

```json
{
  "name": "test",
  "status": "fail",
  "note": "3 tests failed",
  "duration_ms": 12500
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Stage identifier |
| `status` | string | yes | `ok`, `warn`, `fail`, `cached`, `skip` |
| `note` | string | no | Human-readable status details |
| `duration_ms` | integer | no | Stage duration |

### Issue Object

```json
{
  "language": "python",
  "tool": "ruff",
  "rule": "E501",
  "count": 5,
  "message": "Line too long"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `language` | string | yes | Language/context (e.g., `python`, `rust`, `ci`) |
| `tool` | string | yes | Tool that reported the issue |
| `rule` | string | yes | Rule/error code |
| `count` | integer | yes | Number of occurrences |
| `message` | string | no | Representative message |

### Metrics Object

```json
{
  "coverage": {
    "lines_percent": 82.5,
    "functions_percent": 78.3,
    "branches_percent": 71.2,
    "status": "warn"
  },
  "test_counts": {
    "total": 142,
    "passed": 139,
    "failed": 3,
    "skipped": 0
  }
}
```

## Example Report

```json
{
  "schema_version": 1,
  "started_at_utc": "2024-01-15T10:30:00Z",
  "finished_at_utc": "2024-01-15T10:32:45Z",
  "duration_ms": 165000,
  "status": "warn",
  "stages": [
    { "name": "fmt", "status": "ok", "duration_ms": 1200 },
    { "name": "lint", "status": "warn", "note": "5 warnings", "duration_ms": 3500 },
    { "name": "compile", "status": "ok", "duration_ms": 8200 },
    { "name": "test", "status": "ok", "duration_ms": 45000 },
    { "name": "coverage", "status": "warn", "note": "72.5% < 80% threshold", "duration_ms": 95000 },
    { "name": "security", "status": "ok", "duration_ms": 12100 }
  ],
  "issues": [
    { "language": "python", "tool": "ruff", "rule": "E501", "count": 3, "message": "Line too long (> 100 chars)" },
    { "language": "python", "tool": "ruff", "rule": "F401", "count": 2, "message": "Unused import" },
    { "language": "ci", "tool": "coverage", "rule": "below_warn", "count": 1, "message": "Coverage 72.5% below 80% threshold" }
  ],
  "metrics": {
    "coverage": {
      "lines_percent": 72.5,
      "functions_percent": 68.2,
      "status": "warn"
    },
    "test_counts": {
      "total": 142,
      "passed": 142,
      "failed": 0,
      "skipped": 0
    }
  }
}
```

## File Locations

| File | Purpose |
|------|---------|
| `.ci_cache/report.json` | Latest CI run report (overwritten each run) |
| `.ci_cache/logs/` | Full tool outputs (when clamped/hidden) |
| `.enforcer/Enforcer_last_check.log` | Machine-readable snapshot of last run |
| `.enforcer/Enforcer_stats.log` | Append-only historical log of issues |

## Console Output vs Full Logs

The orchestrator should prefer **compact console output**:
- Print a short summary with stage statuses and minimal notes.
- If tool output is too long or too noisy, clamp the console output and write the full output into `.ci_cache/logs/`.
- Always point the user/agent to the log file path when clamping happens.

> Each CI line should be as compact as possible while still providing all the necessary information. Agent should only read CI logs in extreme cases.

## Historical Stats Log

For tracking issue trends over time, append a summary to `Enforcer_stats.log`:

```
--- Check started at 2024-01-15T10:30:00Z ---
python: [ruff] E501 — Line too long (x3)
python: [ruff] F401 — Unused import (x2)
ci: [coverage] below_warn — Coverage 72.5% below 80% threshold (x1)
--- Check finished at 2024-01-15T10:32:45Z (status=warn) ---

--- Check started at 2024-01-15T14:20:00Z ---
python: [ruff] E501 — Line too long (x1)
--- Check finished at 2024-01-15T14:22:30Z (status=ok) ---
```

**Retention policy**:
- Do not auto-delete or rotate `Enforcer_stats.log` by time.
- Keep it until you review it (weekly/monthly) and adjust rules/process/prompting.
- Cleanup happens only manually, after review.

## Writing Reports

### PowerShell

```powershell
function Write-CiReport {
    param(
        [array]$Stages,
        [array]$Issues,
        [hashtable]$Metrics,
        [string]$OutputPath
    )
    
    $overallStatus = if ($Stages | Where-Object { $_.Status -eq "fail" }) {
        "fail"
    } elseif ($Stages | Where-Object { $_.Status -eq "warn" }) {
        "warn"
    } else {
        "ok"
    }
    
    $report = @{
        schema_version = 1
        started_at_utc = $script:CiStartTime.ToString("o")
        finished_at_utc = (Get-Date).ToString("o")
        duration_ms = [int]((Get-Date) - $script:CiStartTime).TotalMilliseconds
        status = $overallStatus
        stages = $Stages
        issues = $Issues
        metrics = $Metrics
    }
    
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath
}
```

### Python

```python
import json
from datetime import datetime, timezone
from typing import List, Dict, Any

def write_ci_report(
    stages: List[Dict],
    issues: List[Dict],
    metrics: Dict,
    output_path: str,
    start_time: datetime
) -> None:
    end_time = datetime.now(timezone.utc)
    
    overall_status = "ok"
    for stage in stages:
        if stage["status"] == "fail":
            overall_status = "fail"
            break
        if stage["status"] == "warn":
            overall_status = "warn"
    
    report = {
        "schema_version": 1,
        "started_at_utc": start_time.isoformat(),
        "finished_at_utc": end_time.isoformat(),
        "duration_ms": int((end_time - start_time).total_seconds() * 1000),
        "status": overall_status,
        "stages": stages,
        "issues": issues,
        "metrics": metrics,
    }
    
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)
```

## Consuming Reports

### Check CI Status

```bash
# Exit code based on report status
jq -e '.status == "ok" or .status == "warn"' .ci_cache/report.json
```

### Extract Failed Stages

```bash
jq '.stages[] | select(.status == "fail") | .name' .ci_cache/report.json
```

### Count Issues by Tool

```bash
jq '[.issues[] | {tool: .tool, count: .count}] | group_by(.tool) | map({tool: .[0].tool, total: map(.count) | add})' .ci_cache/report.json
```

## Schema Evolution

When changing the schema:

1. Increment `schema_version`
2. Keep backward compatibility (new fields should be optional)
3. Document changes in this file

| Version | Changes |
|---------|---------|
| 1 | Initial schema |
