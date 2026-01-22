# Concept: Local CI for Agent-Driven Development

## The Goal

The main goal of local CI in this blueprint is agent-driven self-verification:

```
write code → run CI → fix issues → repeat → present results
```

This reduces the need for a human to copy-paste compiler/test output into a chat and enables a tight, automated correction loop.

Local CI is the **execution engine** for that loop: it runs on the developer machine, controls the environment, and produces structured outputs the agent can reason about.

## Agent Instruction Files (e.g., `AGENTS.md`)

Many repositories keep a dedicated instruction file for coding agents (often named `AGENTS.md`).

Recommendation: include an explicit final verification command in that file so the agent consistently runs local CI before reporting completion.

Example:

```ps
`./run.ps1 -SkipLaunch`
# or
`./run.ps1 -Fast -SkipLaunch`   # If full CI runs 5+ minutes
```

This reduces the chance of successful answers that were never validated by CI.

## Design Philosophy

### 1. Fail Fast, Fail Loud

The CI should stop at the first critical failure. Don't waste time running tests if the code doesn't compile.

```
fmt (fail) → STOP
fmt (ok) → lint (fail) → STOP
fmt (ok) → lint (ok) → test (fail) → STOP
```

### 2. Idempotent by Default

Running the CI twice with no code changes should:
- Produce identical results
- Skip already-passed stages (via caching)
- Not modify the working tree (unless explicitly requested)

### 3. Observable Execution

Long-running stages should provide heartbeat output so you know the CI isn't stuck:

```
[heartbeat] coverage alive t+00:02:15 last-out=3s line='test result: ok. 142 passed'
```

### 4. Language-Agnostic Orchestration

The orchestrator (`build.ps1`) doesn't care what language your project uses. It only cares about:
- Running stages in order
- Collecting statuses
- Managing caches
- Producing reports

Language-specific logic is delegated to `build.<lang>` scripts.

### 5. Profiles for Different Contexts

Not every run needs full coverage or security analysis. Profiles let the agent choose the right trade-off.

See: `docs/PROFILES.md`.

Typical intent:
- `-Fast`: agent self-check / quick iteration
- (default): before push / PR validation
- `-Security`: periodic audit
- `-Release`: artifact build

## Output Discipline (Console vs Logs)

Local CI must clearly surface problems, but it should avoid flooding the console:
- Show tools issues.
    - When tool output is too long or there are too many issues, print only the minimum and point to a log file. For example, omit issues after 240 characters (the number should be selected based on the specifics of the project).
- Show a compact end-of-run summary with short notes.

This keeps the agent loop efficient and keeps chat contexts from being consumed by noise.

## Enforcer Logs and Process Improvement

This blueprint uses two persistent log files:
- `Enforcer_last_check.log`: machine-readable snapshot of the latest run (overwrite each run)
- `Enforcer_stats.log`: append-only history for trend analysis

**Important**: `Enforcer_stats.log` is not "just a log". It is meant to be reviewed weekly/monthly to answer:
- Which issues happen most often?
- Should some rules be tuned (stricter/looser)?
- Should prompting/agent workflow be adjusted to prevent recurring classes of mistakes?

> If you work in a team, develop mechanisms for collecting logs into a single storage or even a shared log file.

**Retention policy**:
- Do not auto-delete `Enforcer_stats.log` by time.
- Cleanup happens only manually, after review and process changes.

## What This Blueprint Provides

1. **Architecture patterns** — How to structure your CI scripts
2. **Stage contracts** — What each stage should do and return
3. **Caching strategies** — How to skip redundant work
4. **Hang detection** — How to catch stuck processes
5. **Report format** — How to structure CI output for tooling

## What This Blueprint Does NOT Provide

- Ready-to-run scripts (adapt to your project)
- Language-specific tool configurations (use your linters)
- Cloud CI integration (that's a separate concern)

## Terminology

| Term | Meaning |
|------|---------|
| **Runner** | User/Agent entry point script (`run.ps1`) |
| **Builder** | The main script that runs stages in order (`build.ps1`) |
| **Stage** | A single CI step (e.g., `fmt`, `lint`, `test`) |
| **Profile** / **Flag** | A predefined set of stages for a specific use case |
| **Trust stamp** | A file indicating a stage was previously successful |
| **Hash guard** | Cache invalidation based on source file hashes |
| **Heartbeat** | Periodic output during long-running stages, with hang termination |

## Common Flags (Examples)

Exact flags are project-specific, but typical patterns include:
- `-Fast`: skip expensive stages and focus on fast feedback
- `-Release`: build artifacts
- `-Skip<Stage>`: fine-grained stage control (e.g., `-SkipLaunch`, `-SkipCoverage`)
