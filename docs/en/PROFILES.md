# Profiles: Execution Modes for Different Contexts

## Why Profiles?

Not every CI run needs full analysis:

| Context | Need | Priority |
|---------|------|----------|
| Pre-commit hook | Fast feedback | Speed |
| Before push | Confidence | Thoroughness |
| Nightly build | Full audit | Coverage |
| Quick iteration | Minimal checks | Speed |

Profiles let you choose the right trade-off.

## Standard Profiles

### Fast (`-Fast`)

**Use case**: AI-agent self-check loop, quick iteration, pre-commit hooks

**Stages**: `fmt` → `lint` → `line-limits` → `build` → `(smoke)tests` → `launch`

**Skips**: `(huge)tests` (if 2+ minutes), `coverage` (if 2+ minutes), `security`, `archive`

```powershell
./run.ps1 -Fast
```

**Typical duration**: 5-30 seconds

### Full (default)

**Use case**: Before push, PR validation

**Stages**: `fmt` → `lint` → `line-limits` → `build` → `tests` → `coverage` → `e2e` → `maintenance` → `launch`

**Skips**: `archive`

```powershell
./run.ps1
```

**Typical duration**: 1-5 minutes

### Maintenance (`-Maintenance`, `-Security`, `-Clear`, etc)

**Use case**: Periodic maintenance run (security + dependencies + housekeeping + etc)

This profile is intentionally “out of band”: run it auto/manualy daily/weekly/pre-release. It can include:
- dependency audit (CVEs, license policy)
- SAST / basic security scanners
- housekeeping (cache/artifact cleanup, policy checks)

```powershell
./run.ps1 -Maintenance
```

### Release (`-Release`)

**Use case**: Building distributable artifacts

**Stages**: `fmt` → `line-limits` → `lint` → `compile` → `test` → `build` → `archive`

**Additional**: Optimized builds, version stamping

```powershell
./run.ps1 -Release
```

**Typical duration**: 2-10 minutes

## Profile Implementation

### Flag-Based Selection

```powershell
param(
    [switch]$Fast,
    [switch]$Release,
    [switch]$Security,
    [switch]$SkipTests,
    [switch]$SkipCoverage,
    [switch]$SkipLint
)

# Derive effective flags
$runLint = -not $SkipLint -and -not $Security
$runTests = -not $Fast -and -not $SkipTests -and -not $Security
$runCoverage = -not $Fast -and -not $SkipCoverage -and -not $Security
$runSecurity = $Security -or $Release
$runBuild = $Release
$runArchive = $Release
```

### Stage Execution Matrix (Rust example)

| Stage           | Fast | Full | Security | Release |
|-----------------|------|------|----------|---------|
| fmt             | ✓ | ✓ | ✗ | ✓ |
| line-limits     | ✓ | ✓ | ✗ | ✓ |
| lint            | ✓ | ✓ | ✗ | ✓ |
| build           | ✓ | ✓ | ✗ | ✓ |
| test (if fast)  | ✓ | ✓ | ✗ | ✓ |
| test            | ✗ | ✓ | ✗ | ✓ |
| coverage (fast) | ✓ | ✓ | ✗ | ✓ |
| coverage        | ✗ | ✓ | ✗ | ✓ |
| security        | ✗ | ✓ | ✓ | ✓ |
| launch          | ✓ | ✓ | ✗ | ✗ |
| archive         | ✗ | ✗ | ✗ | ✓ |

## Skip Flags

Fine-grained control over individual stages:

| Flag | Effect |
|------|--------|
| `-SkipLint` | Skip formatting/lint-related stages (e.g., `fmt`, `line-limits`, `lint`) |
| `-SkipTests` | Skip `test` stage |
| `-SkipCoverage` | Skip `coverage` stage (still runs tests) |
| `-SkipSecurity` | Skip `security` stage |
| `-SkipBuild` | Skip `build` stage |
| `-SkipLaunch` | Skip `launch` stage |

```powershell
# Run full profile but skip coverage (faster)
./run.ps1 -SkipCoverage

# Run everything except security
./run.ps1 -Release -SkipSecurity
```

## Flag Reference (Example Superset)

Projects typically converge on a small set of flags. A useful superset (based on real-world runners) looks like:

| Flag | Category | Intent |
|------|----------|--------|
| `-Fast` | profile | Fast feedback (agent self-check) |
| `-Release` | profile | Produce distributable artifacts |
| `-Security` | profile | Security-only audit run |
| `-SkipLint` | skip | Skip formatter/lint/policy checks |
| `-SkipTests` | skip | Skip test stage |
| `-SkipCoverage` | skip | Skip coverage stage |
| `-SkipLaunch` | skip | CI only (no interactive run) |
| `-NoCache` | cache | Ignore cache for this run (still may write new cache on success) |
| `-ForceAll` | cache | Force all stages to re-run |
| `-Clean` | cache | Delete caches/artifacts before running |
| `-Verbose` | logging | Increase tool verbosity |
| `-ArchiveBuild` | artifacts | Create an archive of produced artifacts |
| `-UpdateSnapshots` | tests | Update snapshot tests during run |
| `-HeartbeatSec` | heartbeat | Heartbeat interval |
| `-HeartbeatSameLinePulses` | heartbeat | Hang detection sensitivity (0 disables) |
| `-HeartbeatSameLineMinSec` | heartbeat | Arm hang detection after this runtime |
| `-CoverageTimeoutSec` | heartbeat | Hard timeout for coverage stage |

Optional pattern (useful for language-specific tools):
- Forward arguments after `--` from `run.ps1` to `build.<lang>` (or a language CI CLI).

## Launch Behavior

Some projects need to run the application after CI:

| Flag | Behavior |
|------|----------|
| (default) | Run CI, then launch app interactively |
| `-SkipLaunch` | Run CI only, no app launch |
| `-FastLaunch` | Skip CI, launch app immediately |

```powershell
# CI for AI-Agent automation
./run.ps1 -Fast -SkipLaunch

# Quick testing
./run.ps1 -Fast
```

## Profile Presets via Config

For complex projects, define profiles in config:

```json
// .ci/config.json
{
  "profiles": {
    "quick": {
      "stages": ["fmt", "line-limits", "lint"],
      "timeout_sec": 60
    },
    "full": {
      "stages": ["fmt", "line-limits", "lint", "compile", "test", "coverage"],
      "timeout_sec": 600
    },
    "nightly": {
      "stages": ["fmt", "line-limits", "lint", "compile", "test", "coverage", "security"],
      "timeout_sec": 1800,
      "coverage_threshold": 80
    }
  }
}
```

Usage:
```powershell
./run.ps1 -Profile nightly
```

## Git Hooks Integration

### Pre-commit (Fast)

```bash
#!/bin/sh
# .git/hooks/pre-commit
pwsh -File ./run.ps1 -Fast -SkipLaunch
```

### Pre-push (Full)

```bash
#!/bin/sh
# .git/hooks/pre-push
pwsh -File ./run.ps1 -SkipLaunch
```

## Profile Composition

Profiles can be combined with skip flags:

```powershell
# Release build without security scan
./run.ps1 -Release -SkipSecurity

# Fast check with lint disabled
./run.ps1 -Fast -SkipLint

# Full profile without coverage (faster tests)
./run.ps1 -SkipCoverage
```

## Recommended Workflows

### Developer Workflow

```bash
# During development: fast feedback
./run.ps1 -Fast

# Before commit: full validation
./run.ps1

# Before PR: ensure CI will pass
./run.ps1 -SkipLaunch
```

### CI/CD Workflow

```bash
# PR validation
./run.ps1 -SkipLaunch

# Nightly build
./run.ps1 -Release -SkipLaunch

# Security audit (weekly)
./run.ps1 -Security -SkipLaunch
```

### Debugging Workflow

```bash
# Skip everything, just launch
./run.ps1 -FastLaunch

# Run tests only
./run.ps1 -SkipLint -SkipCoverage -SkipLaunch

# Force fresh run (ignore cache)
./run.ps1 -NoCache
```
