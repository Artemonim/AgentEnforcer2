# Stages: Definitions and Contracts

## Stage Status Semantics

Every stage must produce exactly one of these statuses:

| Status | Meaning | Pipeline Behavior | Exit Code |
|--------|---------|-------------------|-----------|
| `ok` | Stage completed successfully | Continue to next stage | 0 |
| `warn` | Stage completed with non-critical issues | Continue to next stage | 0 |
| `fail` | Stage failed with critical issues | Stop pipeline (configurable) | 1 |
| `cached` | Stage was skipped due to a cache hit | Continue to next stage | 0 |
| `skip` | Stage was skipped due to flags / profile / non-applicability | Continue to next stage | 0 |

## Standard Stages

### 0. CI Self-Check (`self-check`)

**Purpose**: Validate the CI itself (runner/orchestrator scripts, configs, and glue code) before running checks on the target project.

This stage prevents the agent loop from wasting time on broken CI scaffolding:

```
write CI → run CI → CI fails (self-check) → fix CI → run again
```

**What to validate (examples)**:
- Runner and Builder script syntax (fast parser diagnostics)
- CI script linting (style + correctness)
- Basic invariants: required files exist, required tools are discoverable, config files parse
- `tools/*.ps1`

**Tooling ideas**:
- PowerShell:
  - Parser diagnostics (`System.Management.Automation.Language.Parser`)
  - PSScriptAnalyzer (with optional settings file)
- Bash: `shellcheck`
- Makefiles: basic `make -n` / lint tooling (project-specific)
- CI config: JSON/YAML schema validation (if applicable)

**Status mapping**:
- `ok`: CI scripts/configs are valid
- `warn`: Non-blocking CI issues (style warnings) that should be addressed
- `fail`: CI is invalid (parse errors, critical lint errors)
- `cached`: Cache hit
- `skip`: Disabled via flag / profile / non-applicability

> CI is a critical part of your product, so I recommend FAIL even on WARN.

### 1. Format (`fmt`)

**Purpose**: Ensure consistent code style.

**Tools by language**:
- Python: `ruff format`, `black`
- Rust: `cargo fmt`
- TypeScript: `prettier`, `eslint --fix`
- Go: `gofmt`

**Behavior**:
- Check mode: Verify formatting without changes
- Fix mode: Auto-fix formatting issues

**Status mapping**:
- `ok`: Code is properly formatted
- `fail`: Code has formatting issues (check mode)
- `cached`: Cache hit
- `skip`: Disabled via flag / profile / non-applicability

```
# Pseudocode contract
Input:  Source files
Output: Status (ok|fail|cached|skip)
Effect: None (check) or Modified files (fix)
```

### 2. Lint (`lint`)

**Purpose**: Catch code quality issues, style violations, potential bugs.

**Tools by language**:
- Python: `ruff check`, `flake8`, `pylint`
- Rust: `cargo clippy`
- TypeScript: `eslint`
- Go: `golangci-lint`

**Behavior**:
- Report issues with file:line:column locations
- Optionally auto-fix safe issues

**Status mapping**:
- `ok`: No issues found
- `warn`: Only non-critical issues (e.g., style suggestions)
- `fail`: Critical issues found
- `cached`: Cache hit
- `skip`: Disabled via flag / profile / non-applicability

### 3. Policy: Line Limits (`line-limits`)

**Purpose**: Prevent "god files" and oversized directories that become hard to maintain (for humans and LLMs).

This stage is intentionally language-agnostic and can be implemented as:
- A small compiled helper (`tools/ci/line-limits`)
- A script (`tools/ci/line_limits.py`)
- A language-native tool (if you already have one)

**What to check (examples)**:
- Max lines of executable code for executable files (warn/fail thresholds)
- Max files per directory (warn/fail thresholds)
- A short "top offenders" list for the console summary

**Status mapping**:
- `ok`: No limits exceeded
- `warn`: At least one warn threshold exceeded (non-blocking)
- `fail`: At least one fail threshold exceeded (blocking)
- `cached`: Cache hit
- `skip`: Disabled via flag / profile / non-applicability

**Thresholds (example)**:

```
warn_threshold_lines = 1500
fail_threshold_lines = 2500

max_files_per_dir_warn = 20
max_files_per_dir_fail = 50
```

**Console output guidance**:
- Print only the top few offenders.
- Always write full details into a log file and reference it from the summary.

### 4. Compile / Type Check (`compile`)

**Purpose**: Verify code compiles and type-checks.

Note: in some ecosystems `compile` and `build` are effectively the same command (or one strictly subsumes the other).  
In that case it is acceptable to:
- merge `compile` into `build`, or
- treat `compile` as "fast build" (e.g., `cargo check`, `tsc --noEmit`) and `build` as "artifact build" (e.g., `cargo build --release`, packaging).

**Tools by language**:
- Python: `mypy`, `pyright`, `python -m compileall`
- Rust: `cargo check` / `cargo build`
- TypeScript: `tsc --noEmit`
- Go: `go build`

**Status mapping**:
- `ok`: Code compiles without errors
- `warn`: Compiles with warnings (if warnings are non-fatal)
- `fail`: Compilation errors
- `cached`: Cache hit
- `skip`: Disabled via flag / profile / non-applicability

### 5. Test (`test`)

**Purpose**: Run automated tests.

**Tools by language**:
- Python: `pytest`
- Rust: `cargo test`
- TypeScript: `vitest`, `jest`
- Go: `go test`

**Behavior**:
- Run test suite
- Report pass/fail counts
- Optionally fail fast on first failure

**Status mapping**:
- `ok`: All tests passed
- `warn`: Tests passed but with warnings (e.g., slow tests)
- `fail`: One or more tests failed
- `cached`: Cache hit (optional)
- `skip`: Disabled via flag / profile / non-applicability

### 6. Coverage (`coverage`)

**Purpose**: Measure test coverage and enforce thresholds.

**Tools by language**:
- Python: `pytest-cov`, `coverage.py`
- Rust: `cargo llvm-cov`, `tarpaulin`
- TypeScript: `vitest --coverage`, `c8`
- Go: `go test -cover`

**Behavior**:
- Collect coverage data during test run
- Report coverage percentages
- Optionally fail if below threshold

**Advanced: Coverage guidance**

[Some projects](https://dtf.ru/indie/4685854-alfa-2-1-zavershenie-testirovaniya-i-uluchshenie-ci-sistemy) implement a “what to test next” mechanism ([CovRank](https://dtf.ru/indie/4571267-optimizatsiya-ci-i-testirovanie-v-alpha-2-proekta-living-layers)): instead of only enforcing a threshold, the CI emits a ranked list of low-coverage, high-impact targets to guide the agent toward the most effective tests to add.

This is intentionally outside the core blueprint

**Status mapping**:
- `ok`: Coverage meets or exceeds threshold
- `warn`: Coverage below warn threshold but above fail threshold
- `fail`: Coverage below fail threshold
- `cached`: Cache hit (optional)
- `skip`: Disabled via `-Fast` or `-SkipCoverage`

**Thresholds (example)**:
```
warn_threshold = 75%
fail_threshold = 60%

coverage >= 75%  → ok
60% <= coverage < 75%  → warn
coverage < 60%  → fail
```

### 7. Security (`security`)

**Purpose**: Detect security vulnerabilities.

**Tools by language**:
- Python: `bandit`, `pip-audit`
- Rust: `cargo audit`
- TypeScript: `npm audit`
- Go: `govulncheck`

**Behavior**:
- Scan for known vulnerabilities
- Check dependencies for CVEs
- Report severity levels

**Status mapping**:
- `ok`: No high/critical vulnerabilities
- `warn`: Only low/medium severity issues
- `fail`: High/critical vulnerabilities found
- `cached`: Cache hit (optional)
- `skip`: Disabled or not applicable

### 8. Build (`build`)

**Purpose**: Produce distributable artifacts.

**Behavior**:
- Compile release binaries
- Bundle assets
- Generate version metadata

**Status mapping**:
- `ok`: Build succeeded
- `fail`: Build failed
- `cached`: Cache hit (optional)
- `skip`: Not applicable (e.g., library projects)

### 9. Archive (`archive`)

**Purpose**: Package build artifacts for distribution.

**Behavior**:
- Create versioned archive (zip, tar.gz)
- Include binaries, assets, documentation
- Generate checksums

**Status mapping**:
- `ok`: Archive created successfully
- `fail`: Archive creation failed
- `cached`: Cache hit (optional)
- `skip`: `-SkipArchive` or build stage failed

## Stage Result Object

```json
{
  "name": "test",
  "status": "fail",
  "note": "3 tests failed",
  "duration_ms": 12500,
  "details": {
    "total": 142,
    "passed": 139,
    "failed": 3,
    "skipped": 0
  }
}
```

## Custom Stages

Projects can define custom stages following the same contract:

Common examples:
- `e2e`: end-to-end or integration test suite (often slower, may require local infra)
- `launch`: run the app after CI (interactive/manual verification step; often skipped for automation via `-SkipLaunch`)
- `workspace-policy`: repo-wide policy checks (metadata, conventions, file placement)
- `target-size`: build artifact size / directory budget guards

```powershell
# Custom stage example: Database migrations
Invoke-Stage -Name "db-migrate" -Action {
    # Run migrations in check mode
    $result = & alembic check
    if ($LASTEXITCODE -ne 0) {
        throw "Pending migrations detected"
    }
}
```

## Stage Configuration

Stages can be configured via `.ci/config.json`:

```json
{
  "stages": {
    "coverage": {
      "warn_threshold": 75,
      "fail_threshold": 60
    },
    "security": {
      "ignore_advisories": ["CVE-2023-XXXXX"]
    },
    "lint": {
      "disabled_rules": ["E501", "W503"]
    }
  }
}
```
