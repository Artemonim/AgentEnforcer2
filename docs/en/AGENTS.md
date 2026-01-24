# The `AGENTS.md` Concept: an operational contract for working with an AI agent

This document explains *why* and *how* to use `AGENTS.md` in a project repository so that the AI agent behaves predictably: it quickly finds the needed knowledge, does not break forbidden zones, follows key engineering constraints, and **always** runs local CI before the final report.

> Important: this is not an attempt to "standardize prompting" or replace [AgentCompass](https://github.com/Artemonim/AgentCompass). This is a practical model: `AGENTS.md` as an **execution contract** (operational contract).

## `AGENTS.md` and `README.md`: separation of roles

- `README.md` is a project showcase and a starter How To for humans.
- `AGENTS.md` is a production execution contract. It is automatically pulled into context by all current agents.

Important:
- do not overload `README.md` with production details that are primarily important to the agent;
- do not turn `AGENTS.md` into a "README for humans/non-specialists": people can read it if they want, but its main job is to make the agent's work reproducible and verifiable.

## Project-agnostic agent behavior rules (Agent Policy)

In many projects there is a set of universal rules for the agent (in the spirit of [AgentCompass/COMPASS.md](https://github.com/Artemonim/AgentCompass/blob/master/COMPASS.md)): security, report format, requirements, etc.

Recommendation:
- Keep such rules in the environment settings where the agent runs (for example, Cursor User Rules or similar "User Rules / System Prompt" in your agent system);
- If your IDE/agent system cannot specify separate project-agnostic rules of behavior (as in Codex or the [initial Cursor Subagents implementation](https://forum.cursor.com/t/subagents-do-not-receive-user-rules/148987)), move them to a separate repository file (for example, `.cursor/rules/CodexRules.md`, `AGENT_RULES.md`, `AGENT_POLICY.md`, etc) and reference it at the start of each prompt and/or from `AGENTS.md`.

```md
You are a subagent.

Important: At the very start of work, fully read ".cursor/rules/CodexRules.md" and follow it as your primary rules.
```

> `AGENTS.md` should provide guidance about the specific current project.

---

## AGENTS.md Structure

### Doctrine (the first thing the agent should see)

Doctrine is 1-3 short declarative rules that the agent must consider **before** writing code. These are not tips, but constraints on the design decisions accepted in a specific project. Multiple non-conflicting, non-overlapping doctrines are acceptable at the same time.

Example of a "performance-first" doctrine:

- Any component that can become heavy (CPU/GPU/IO) or affects responsiveness is designed as a job/async system: snapshot -> parallel work -> apply, with cancellation/superseding, backpressure, and observability.
- A sequential implementation is acceptable only if it consistently fits into target budgets (latency/frame time/IO) and is not a bottleneck; the choice is confirmed by metrics and/or profiling.

Why this belongs in `AGENTS.md`:
- the agent has no right to "do it simple first, then optimize" if the doctrine requires a different architecture;
- the doctrine reduces the risk of a "correct but unacceptable" solution.

### Documentation map (where to look)

`AGENTS.md` should give the agent quick links to the "source of truth":
- what to read for high-level familiarization with the project;
- where the main documents are and what they provide;
- where to search for decisions and terms.

#### Links to large documents and specific sections

If a document is large, it is useful to add pointers to specific line ranges or sections so the agent does not reread everything. The format can be the same as in [LivingLayers](https://livinglayers.ru/?utm_source=github&utm_medium=organic&utm_campaign=agentenforcer2&utm_content=agents.md):

```md
- `doc/decision_log.md` contains a list of important project design decisions and their rationales.
- - Pre-Alpha Decisions | lines 78-334
- - - ADR-001: Hybrid Physics Architecture | 80-130
- - - ADR-002: Alpha Progression as Go/No-Go Gates | 134-162
- - - ADR-003: Material System Extensibility | 166-205
```

Recommendation:
- keep these links at the "beacon" level, without trying to cover everything;
- update line ranges when the document is substantially edited.

### Code Map (where to look in code)

The Code Map is needed so the agent does not do "repository reconnaissance" and does not spend iterations on the wrong folders.

#### Stability principle

In the Code Map, include **only top-level paths** that rarely change:
- `src/` is the main application code
- `backend/` is the server-side part
- `tools/` are project utilities and scripts

Why only top-level:
- lower-level directories move more often and quickly become outdated;
- for the agent, "where to look in general" matters more than "which specific subfolder contains one file".

#### Addendum: documentation links next to paths

If it is useful, you can leave links to specific documentation sections next to paths in the same format as above (for example, with line ranges). This speeds up the "code <-> explanation" transition.

### Read-only zones (if applicable)

If the project has submodules, vendor content, autogenerated files, or "do not touch manually" areas, this must be declared explicitly.

Example:
- Do not modify files inside `doc/Unity` and `doc/pytorch`: these are submodules, treat as read-only.

Why this belongs in `AGENTS.md`:
- agents tend to "fix everything"; explicit prohibition prevents costly mistakes.

### Final verification command (mandatory ritual)

`AGENTS.md` must contain an explicit command that the agent must run before saying "done".

Example:

```md
### Quality Control

- You must use the `run.ps1` runner to check code quality. Always use a terminal timeout of at least 25 minutes.
- By default, run `./run.ps1 -Fast -SkipLaunch`.
- In most cases, sending `./run.ps1 -Fast -SkipLaunch` to your terminal is enough - it is a local CI that runs all checks and provides a convenient response.
```

Why this is critical:
- without this line, the agent easily finishes work by the "looks correct" principle without running CI;
- local CI is the "engine of changes": *write -> run -> fix -> repeat*.

#### Local CI timeout: a practical necessity for Cursor v2.4.21

In Cursor v2.4.21 (as in OpenAI Codex) it is impossible to run a terminal without a timeout. If the command does not finish within the allocated time, the terminal can be moved to background, and the agent loses access to output/process - which breaks the agent loop "run CI -> read output -> fix".

Recommendation:
- set the timeout for running local CI with a buffer of +10% of the expected full run time for your project;
- update the timeout as the project grows.

### Glossary: a "distillation" of frequently used terms

In large projects, a glossary often lives in a separate document (for example, `doc/glossary.md`). But in `AGENTS.md` it makes sense to duplicate the most frequent terms that constantly appear in communication with the agent.

How to do it:
- keep the description as short as possible (1 line);
- do not try to move the whole dictionary: the goal is to reduce clarification questions and interpretation errors.

Example:
```md
- runner - `run.ps1`
- builder - `build.ps1`
- fragment - a piece of a structure formed after destruction
- shard - a single-voxel particle (dust) formed after destruction
```

---

## AGENTS.md anti-patterns

- Make `AGENTS.md` a "language/style textbook": User Rules, linters, formatters, configs, CONTRIBUTION.md, and other project style guides exist for that.
- Duplicate flags and help for local CI: the source of truth should be in `run.ps1 --help`.
- Write an overly detailed glossary or subfolder map: it will take too many tokens, become outdated quickly, and mislead the agent.
