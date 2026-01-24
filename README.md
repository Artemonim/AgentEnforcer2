# Agent Enforcer 2: Local CI Blueprint

[![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md)
[![Russian](https://img.shields.io/badge/lang-Русский-lightgrey.svg)](README.ru.md)

**A reference architecture for building robust, language-agnostic local CI systems.**

Agent Enforcer 2 it's a concept to implementing local CI in your projects. It documents battle-tested patterns for orchestrating code quality checks, managing caches, detecting hangs, and producing structured reports.

**See also**:

<a href="https://github.com/Artemonim/AgentCompass">
      <img src="https://github-readme-stats.vercel.app/api/pin/?username=Artemonim&repo=AgentCompass&theme=transparent&hide_border=true&title_color=2f80ed&text_color=ffffff&icon_color=2f80ed" />
    </a>
    <br>

## How to start

### For vibecoders

- Use the most capable LLM model available to you per the current consensus of benchmarks like ARC-AGI-2, HLE, MRCR v2, Terminal-Bench 2.0; or their up-to-date successors.
- This repository is designed to be given to an LLM as context. Copy prompt below to chat with AI Agent.
- Do this in two consecutive chats:
    - Chat 1: planning only — [create CI_TODO.md](#chat-1).
    - Chat 2: implementation — [implement CI_TODO.md](#chat-2)

#### Chat 1

> To help Cursor (v2.4.21) process your request effectively:
> 1. Manually type `@Browser` instead of `INSERT_BROWSER` and press `ENTER`
> 2. Paste `https://github.com/Artemonim/AgentEnforcer2/blob/master/README.md` instead of `README_LINK`
> 3. If the project already has docs like `README.md`, `TODO.md`, `AGENTS.md`, or similar, mention them before the prompt template.

```
Create a `CI_TODO.md` for the local CI system in my project, following the Agent Enforcer 2 blueprint.

Via INSERT_BROWSER, study and follow the documentation starting from README_LINK. Read GitHub docs in raw (`raw.githubusercontent.com` / the `Raw` button).

- Adapt the patterns to my project's language and existing tooling. Do NOT copy files verbatim - create implementations tailored to my codebase.
- By default, choose and fix the full recommended set of quality checks for the project's stack (fmt/lint/typecheck/tests/coverage/security). At the end, ask in chat for confirmation: "Keep the default or remove/replace something?" - do not propose multiple load profiles. You may describe -Fast/-Full profiles, but the default must be Full. Any proposed command/tool/flag must include a brief explanation (1-2 sentences: what it does and why in CI). Do not use terms without expanding them.
- Before the final `CI_TODO.md`, make a table of all stages from `AgentEnforcer2/docs/en/STAGES.md`. For each stage specify: implement/skip/not_applicable_(with reason). `Coverage` must always be in the pipeline; if there are no tests/code - `skip` with reason and a plan to enable; if a threshold policy is not chosen - use a safe default without fail thresholds (TODO for policy).
- If there are submodules: do not read their contents, but `.gitmodules` can be read only to get `path` and exclude these paths from all file enumeration/hashing. CI must ignore gitmodules and respect `git ls-files`.
- Include an AE2 mention link in `CI_TODO`.
- Include the AE2-recommended thresholds for CI tools in `CI_TODO`.
```

#### Chat 2

```
Implement `CI_TODO.md`
```

### For AI Agents

#### Reading Order

| Priority | Document | Why |
|----------|----------|-----|
| 1 | [CONCEPT.md](docs/en/CONCEPT.md) | Philosophy and "why" |
| 2 | [ARCHITECTURE.md](docs/en/ARCHITECTURE.md) | Core three-tier structure |
| 3 | [STAGES.md](docs/en/STAGES.md) | Stage contracts |
| 4 | [CACHING.md](docs/en/CACHING.md) | Skip redundant work |
| 5 | [templates/](templates/) | Reference implementations |
| 6 | [AGENTS.md](docs/en/AGENTS.md) | How to write `AGENTS.md` as an execution contract |
| Optional | [HEARTBEAT.md](docs/en/HEARTBEAT.md) | For long-running stages |
| Optional | [PROFILES.md](docs/en/PROFILES.md) | For complex projects |

#### What You Should Do

1. **Analyze** the target project (languages, existing tooling, directory structure)
2. **Draft** `CI_TODO.md` describing what to implement and where
3. **Propose** a tooling matrix (formatters, linters, type-checkers, tests, coverage, security) and ask the user which tools to enforce
4. **Get confirmation**
5. **Create** `run.ps1` — thin wrapper with flag validation
6. **Create** `build.ps1` — orchestrator with stages for the project's languages
7. **Create** `build.<lang>` — language-specific logic
8. **Add** `.ci_cache/` and `.enforcer/` to `.gitignore`
9. `./run.ps1` 🙂

#### CI Self-Check

- Include a `self-check` stage early to validate the CI layer itself (scripts, configs, glue code). For PowerShell-based CI this typically includes parser diagnostics and PSScriptAnalyzer.
- Connect `self-check` to the user IDE.

`.vscode/settings.json`:
```json
{
  "powershell.scriptAnalysis.enable": true,
  "powershell.scriptAnalysis.settingsPath": "${workspaceFolder}/PSScriptAnalyzerSettings.psd1"
}
```

#### Agent Instructions: ensure CI is actually executed

If your project uses an agent instruction file (commonly `AGENTS.md`), it should contain an explicit “final verification” command that the agent must run before presenting results.

Example (Windows / PowerShell runner):

```
./run.ps1 -Fast -SkipLaunch
```

This single line dramatically improves reliability of the agent loop because it prevents “looks good” answers without a CI run.

Note: this blueprint does not prescribe how to author `AGENTS.md`. For detailed conventions and prompting policy, see [AgentCompass](https://github.com/Artemonim/AgentCompass).

## Platform Notes

The reference scripts in this blueprint are written for PowerShell on Windows, but the architecture is platform-agnostic.

**Why PowerShell here (instead of Make)?**
- PowerShell is a practical default for Windows-first developer machines.
- It is good at system orchestration: process execution, environment setup, filesystem work, and structured output.
- With [PowerShell 7](https://github.com/PowerShell/PowerShell) it can be cross-platform (Windows/Linux/macOS) while keeping one scripting language.

**When Make/Taskfile/just is a better fit**
- Unix-first projects where `make` is already the team default.
- Repos that prefer declarative task runners over imperative scripting.
- You still should keep the same three-tier idea: a thin entrypoint → orchestrator → language-specific tooling.

**Ecosystem-native runners (recommended integration points)**
- Node/TS: npm scripts (`package.json`), Nx/Turborepo, `eslint`/`prettier`/`vitest`
- Java/Kotlin: Gradle (`gradlew`), Detekt, Spotless, tests
- Rust: `cargo` (fmt/clippy/test), `cargo llvm-cov`
- .NET: `dotnet format`, `dotnet test`, analyzers
- Go: `go test`, `golangci-lint`, `govulncheck`

> In all cases, keep the same three-tier structure and re-implement the runner/orchestrator in your shell of choice if needed.

## Core Principles

1. **Three-Tier Architecture**: `run.ps1` (thin wrapper) → `build.ps1` (orchestrator) → `build.<lang>` / `tools/ci/*` (language-specific logic)
2. **Fail Fast, Stay Idempotent**: Hash-based caching, clear stage boundaries, deterministic behavior
3. **Observable Execution**: Heartbeat monitoring, hang detection, structured logging
4. **Unified Reporting**: Single JSON report format across all languages and stages

## Documentation

| Document | Description |
|----------|-------------|
| [CONCEPT.md](docs/en/CONCEPT.md) | Philosophy and design rationale |
| [ARCHITECTURE.md](docs/en/ARCHITECTURE.md) | Three-tier structure and data flow |
| [STAGES.md](docs/en/STAGES.md) | Stage definitions, statuses, and contracts |
| [CACHING.md](docs/en/CACHING.md) | Hash-based caching and trust stamps |
| [HEARTBEAT.md](docs/en/HEARTBEAT.md) | Watchdog patterns for hang detection |
| [REPORT_FORMAT.md](docs/en/REPORT_FORMAT.md) | CI report JSON schema and usage |
| [PROFILES.md](docs/en/PROFILES.md) | Execution profiles (fast, full, security) |

## Templates

Reference implementations (adapt, don't copy):

| Template | Description |
|----------|-------------|
| [run.ps1](templates/run.ps1) | Thin wrapper skeleton |
| [build.ps1](templates/build.ps1) | Orchestrator skeleton |
| [build.py](templates/build.py) | Python-specific logic |
| [build.rs](templates/build.rs) | Rust-specific logic |
| [build.ts](templates/build.ts) | TypeScript-specific logic |

### Optional (Recommended): CI Sounds

You can add **audible markers** for the flow and completion of local CI:
- A "success" marker when CI ends successfully (when `-SkipLaunch` is used)
- A "failure" marker on the first failure
- A "launch" marker when the application is started after CI

This blueprint includes a reference implementation in `templates/build.ps1` and sound assets in `assets/ci_sounds` (Opus).

**Requirements**:
- Install any audio player available in PATH: `ffplay`, `mpv`, or `vlc`.

**How to disable** (intentionally not a 1-flag toggle):
- Remove `assets/ci_sounds/*`.

> Avoid adding a `-Mute` flag to CI scripts. Agents may overuse it to "not disturb" the user, while the user want to be "disturbed" by CI completion/failure.

## Schema

| File | Description |
|------|-------------|
| [ci_report.schema.json](schema/ci_report.schema.json) | JSON Schema for CI reports |
| [ci_report.example.json](schema/ci_report.example.json) | Example report |

## Quick Reference

### Stage Statuses

| Status | Meaning | Exit Behavior |
|--------|---------|---------------|
| `ok` | Stage passed | Continue |
| `warn` | Stage passed with warnings | Continue |
| `fail` | Stage failed | Stop pipeline (unless configured otherwise) |
| `cached` | Stage was skipped due to a cache hit | Continue |
| `skip` | Stage was skipped due to flags / profile / non-applicability | Continue |

### Typical Stage Order

```
self-check → fmt → lint → compile → build → test → coverage → e2e → security → launch → archive
```

### Minimal Implementation Checklist

- [ ] `run.ps1` validates flags and forwards to `build.ps1`
- [ ] `build.ps1` orchestrates stages with status tracking
- [ ] Language-specific logic lives in `build.<lang>` or `tools/<lang>-ci`
- [ ] Each stage produces `ok|warn|fail|cached|skip` status
- [ ] Final report is written to `.ci_cache/report.json`
- [ ] `Enforcer_last_check.log` and `Enforcer_stats.log` are written to `.enforcer/`
- [ ] Cache directory (`.ci_cache/`) and logs directory (`.enforcer/`) are gitignored

## Origin

This blueprint is extracted from production CI systems used in:
- **[Living Layers](https://livinglayers.ru/?utm_source=github&utm_medium=organic&utm_campaign=agentenforcer2&utm_content=readme.md)**
    - A video game built with a custom Rust engine on top of [Bevy](https://github.com/bevyengine/bevy)
    - 4500+ lines of `build.ps1` CI orchestration
- **[TelegramBot01](https://github.com/Artemonim/portfolio-mock-TelegramBot01)**
    - Python Telegram bot
    - 1200+ lines of CI

## License

MIT License. Use these patterns freely in your projects.

## Contributing

Translations are welcome! If you want to translate Agent Enforcer 2 into another language, please submit a Pull Request.

---

*Part of [Artemonim's Agent Tools](https://github.com/Artemonim/AgentTools) ecosystem.*
