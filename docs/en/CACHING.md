# Caching: Hash Guards and Trust Stamps

## Why Cache?

Without caching, the CI runs every stage on every invocation, even when nothing changed. This wastes time and breaks the fast feedback loop.

Good caching should:
- Skip stages when source files haven't changed
- Invalidate when relevant files are modified
- Be deterministic (same inputs → same cache decision)
- Be transparent (easy to force re-run)

## Cache Components

### 1. Hash Files (`.sha256`)

Store a hash of all inputs relevant to a stage.

```
.ci_cache/
├── fmt.sha256       # Hash of source files for fmt stage
├── lint.sha256      # Hash of source files + lint config
├── test.sha256      # Hash of source + test files
└── coverage.sha256  # Hash of source + test files + coverage config
```

**Hash computation**:
```
hash = SHA256(
    sorted(file_paths) +
    sorted(file_contents)
)
```

**What to include in hash**:
- Source files (`.py`, `.rs`, `.ts`, etc.)
- Configuration files (`.eslintrc`, `pyproject.toml`, etc.)
- Lock files (`Cargo.lock`, `package-lock.json`, etc.)

**What to exclude**:
- `.git/` directory
- Build artifacts (`target/`, `dist/`, `node_modules/`)
- Cache directories (`.ci_cache/`)
- IDE settings (`.vscode/`, `.idea/`)

### 2. Trust Stamps (`.trusted`)

Indicate that a stage was previously successful for a given hash.

```
.ci_cache/
├── fmt.sha256       # Contains: a1b2c3d4...
├── fmt.trusted      # Exists only if fmt passed for a1b2c3d4...
```

**Logic**:
```
if hash_file_exists AND hash_matches_current AND trust_file_exists:
    → Cache hit, skip stage
else:
    → Cache miss, run stage
    if stage_passed:
        → Write new hash + trust stamp
```

## Cache Flow

1. Compute current hash:
```py
current_hash = hash(src/**/*.py, .ruff.toml)
```
2. Read stored hash:
```py
stored_hash = read(".ci_cache/lint.sha256")
```
3. Check cache validity
```py
if stored_hash == current_hash
   AND exists(".ci_cache/lint.trusted"):
   → CACHED (cache hit)
else:
   → RUN stage
```
4. After successful run
```py
write(".ci_cache/lint.sha256", current_hash)
touch(".ci_cache/lint.trusted")
```

## Pseudocode

```powershell
function Test-StageCache {
    param(
        [string]$StageName,
        [string[]]$InputPaths,
        [string]$CacheDir = ".ci_cache"
    )
    
    $hashFile = Join-Path $CacheDir "$StageName.sha256"
    $trustFile = Join-Path $CacheDir "$StageName.trusted"
    
    # Compute current hash
    $currentHash = Get-ContentHash -Paths $InputPaths
    
    # Check stored hash
    $storedHash = if (Test-Path $hashFile) { 
        Get-Content $hashFile 
    } else { 
        "" 
    }
    
    # Cache hit?
    if ($currentHash -eq $storedHash -and (Test-Path $trustFile)) {
        return @{ CacheHit = $true; Hash = $currentHash }
    }
    
    return @{ CacheHit = $false; Hash = $currentHash }
}

function Write-StageCache {
    param(
        [string]$StageName,
        [string]$Hash,
        [string]$CacheDir = ".ci_cache"
    )
    
    $hashFile = Join-Path $CacheDir "$StageName.sha256"
    $trustFile = Join-Path $CacheDir "$StageName.trusted"
    
    Set-Content -Path $hashFile -Value $Hash
    New-Item -ItemType File -Path $trustFile -Force | Out-Null
}

function Clear-StageCache {
    param(
        [string]$StageName,
        [string]$CacheDir = ".ci_cache"
    )
    
    Remove-Item -Path (Join-Path $CacheDir "$StageName.*") -Force -ErrorAction SilentlyContinue
}
```

## Cache Invalidation

### Automatic Invalidation

Cache is automatically invalidated when:
- Source files change (hash mismatch)
- Configuration files change (if included in hash)
- Lock files change (dependencies updated)

### Manual Invalidation

Provide CLI flags for manual cache control:

| Flag | Effect |
|------|--------|
| `-NoCache` | Ignore cache, but still write new cache on success |
| `-ForceAll` | Implies `-NoCache`, re-run everything |
| `-Clean` | Delete cache directory before running |

```powershell
# run.ps1 flags
param(
    [switch]$NoCache,     # Ignore cache for this run
    [switch]$ForceAll,    # Force all stages to re-run
    [switch]$Clean        # Delete cache before running
)
```

## Per-Stage Hash Inputs

Different stages have different inputs:

| Stage | Hash Inputs |
|-------|-------------|
| `fmt` | Source files only |
| `lint` | Source files + lint config (`.ruff.toml`, `.eslintrc`) |
| `compile` | Source files + build config + lock files |
| `test` | Source + test files + test config |
| `coverage` | Same as test + coverage config |

```powershell
$StageInputs = @{
    "fmt" = @("src/**/*.py")
    "lint" = @("src/**/*.py", ".ruff.toml", "pyproject.toml")
    "test" = @("src/**/*.py", "tests/**/*.py", "pyproject.toml")
    "coverage" = @("src/**/*.py", "tests/**/*.py", "pyproject.toml", ".coveragerc")
}
```

## Daily/Periodic Cache Expiry

Some checks should run at least once per day, even with no code changes:

```powershell
function Test-RunEnvChecksToday {
    param([switch]$Force)
    
    $stampFile = ".ci_cache/env_check.stamp"
    $today = (Get-Date).ToString("yyyy-MM-dd")
    
    if ($Force) { return $true }
    
    if (Test-Path $stampFile) {
        $stampDate = Get-Content $stampFile
        if ($stampDate -eq $today) {
            return $false  # Already ran today
        }
    }
    
    return $true  # Need to run
}
```

## Cache Directory Structure

```
.ci_cache/
├── fmt.sha256          # Hash for fmt stage
├── fmt.trusted         # Trust stamp for fmt stage
├── lint.sha256
├── lint.trusted
├── test.sha256
├── test.trusted
├── coverage.sha256
├── coverage.trusted
├── env_check.stamp     # Date of last environment check
├── report.json         # Last CI run report
├── logs/               # Command output logs
│   ├── lint_2024-01-15.log
│   └── test_2024-01-15.log
└── temp/               # Temporary files (cleaned on exit)
```

## Gitignore

Add to `.gitignore`:

```gitignore
# Local CI cache
.ci_cache/
```
