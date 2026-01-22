/**
 * build.ts — TypeScript-specific CI logic (template)
 *
 * This script is a reference implementation for the "language-specific layer"
 * in the Agent Enforcer 2 blueprint.
 *
 * It is intended to be called by an orchestrator (e.g. `build.ps1`) and prints
 * structured JSON output describing tool results.
 *
 * Adapt the CONFIG section to your project.
 *
 * Security:
 * - Never embed secrets in this file. Use environment variables instead.
 * - Avoid executing untrusted inputs as shell commands.
 *
 * Recommended runtime:
 * - Use `tsx` or compile to JS and run with Node.
 *
 * Example commands (adapt):
 * - `npx tsx tools/ci/build.ts --json`
 * - `node dist/tools/ci/build.js --json`
 */

import { spawn } from 'node:child_process';

// =============================================================================
// Configuration
// =============================================================================

/**
 * Directories to check (relative to project root).
 * Used only for display / future extensibility; npm scripts usually define targets.
 */
const TARGET_DIRS = ['src', 'tests'];

type ToolConfig = Readonly<{
  /** Human-readable description. */
  description: string;
  /** If true, non-zero exit code fails the whole pipeline. */
  critical: boolean;
  /** If true, tool has a "fix" mode (optional). */
  canFix: boolean;
  /** Executable to run (no shell). */
  command: string;
  /** Args for check mode. */
  args: string[];
  /** Args for fix mode (optional). */
  argsFix?: string[];
}>;

/**
 * Tool list is modeled after typical TS stacks and the PinGineer repo:
 * - prettier check
 * - eslint
 * - tsc --noEmit
 * - tests
 * - build
 *
 * If your repo already has npm scripts, prefer calling them here.
 */
const TOOLS: Readonly<Record<string, ToolConfig>> = {
  'prettier-check': {
    description: 'Formatter check (Prettier)',
    critical: true,
    canFix: true,
    command: 'npm',
    args: ['run', 'format:check'],
    argsFix: ['run', 'format'],
  },
  eslint: {
    description: 'Linter (ESLint)',
    critical: true,
    canFix: false,
    command: 'npm',
    args: ['run', 'lint'],
  },
  tsc: {
    description: 'Type checker (tsc --noEmit)',
    critical: true,
    canFix: false,
    command: 'npm',
    args: ['run', 'typecheck'],
  },
  test: {
    description: 'Test runner (vitest/jest/etc.)',
    critical: true,
    canFix: false,
    command: 'npm',
    args: ['run', 'test'],
  },
  build: {
    description: 'Build (vite/tsc/bundler)',
    critical: true,
    canFix: false,
    command: 'npm',
    args: ['run', 'build'],
  },
};

// =============================================================================
// Output format
// =============================================================================

type ToolResult = Readonly<{
  tool: string;
  description: string;
  available: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
  critical: boolean;
  canFix: boolean;
  fixed: boolean;
  durationMs: number;
}>;

type Summary = Readonly<{
  totalToolsRun: number;
  criticalFailures: number;
  overallStatus: 'PASS' | 'FAIL';
  durationMs: number;
}>;

type Report = Readonly<{
  tools: Record<string, ToolResult>;
  summary: Summary;
  meta: Readonly<{
    targetDirs: string[];
  }>;
}>;

// =============================================================================
// CLI
// =============================================================================

type Cli = Readonly<{
  tool?: string;
  paths: string[];
  fix: boolean;
  json: boolean;
  verbose: boolean;
}>;

function parseArgs(argv: string[]): Cli {
  // * Minimal parser to keep the template dependency-free.
  const cli: Cli = {
    paths: [],
    fix: false,
    json: false,
    verbose: false,
  };

  const nextValue = (i: number): string => {
    const v = argv[i + 1];
    if (!v) throw new Error(`Missing value after ${argv[i]}`);
    return v;
  };

  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--tool') {
      // eslint-disable-next-line no-param-reassign
      (cli as { tool: string }).tool = nextValue(i);
      i += 1;
    } else if (a === '--path') {
      const v = nextValue(i);
      (cli as { paths: string[] }).paths.push(v);
      i += 1;
    } else if (a === '--fix') {
      (cli as { fix: boolean }).fix = true;
    } else if (a === '--json') {
      (cli as { json: boolean }).json = true;
    } else if (a === '--verbose' || a === '-v') {
      (cli as { verbose: boolean }).verbose = true;
    } else if (a === '--help' || a === '-h' || a === '-?') {
      // eslint-disable-next-line no-console
      console.log(
        [
          'Usage: build.ts [--tool NAME] [--path DIR ...] [--fix] [--json] [-v]',
          '',
          'Options:',
          '  --tool NAME     Run a single tool (e.g. eslint, tsc).',
          '  --path DIR      Add target dir (repeatable).',
          '  --fix           Use fix mode where possible.',
          '  --json          Print JSON report (recommended for orchestrators).',
          '  -v, --verbose   Print extra logs to stderr.',
        ].join('\n'),
      );
      process.exit(0);
    } else if (a.startsWith('-')) {
      throw new Error(`Unknown argument: ${a}`);
    }
  }

  return cli;
}

// =============================================================================
// Tool runner
// =============================================================================

function nowMs(): number {
  return Date.now();
}

function runCommand(
  command: string,
  args: string[],
  verbose: boolean,
): Promise<{ exitCode: number; stdout: string; stderr: string; available: boolean }> {
  return new Promise((resolve) => {
    if (verbose) {
      // eslint-disable-next-line no-console
      console.error(`Running: ${command} ${args.join(' ')}`);
    }

    const child = spawn(command, args, {
      shell: false,
      windowsHide: true,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (b) => {
      stdout += b.toString();
    });
    child.stderr.on('data', (b) => {
      stderr += b.toString();
    });

    child.on('error', (err: unknown) => {
      const msg = err instanceof Error ? err.message : String(err);
      resolve({ exitCode: 127, stdout: '', stderr: msg, available: false });
    });

    child.on('close', (code) => {
      resolve({
        exitCode: typeof code === 'number' ? code : 1,
        stdout,
        stderr,
        available: true,
      });
    });
  });
}

async function runTool(
  toolName: string,
  cfg: ToolConfig,
  fixMode: boolean,
  verbose: boolean,
): Promise<ToolResult> {
  const started = nowMs();

  const args =
    fixMode && cfg.canFix && cfg.argsFix && cfg.argsFix.length > 0 ? cfg.argsFix : cfg.args;

  const res = await runCommand(cfg.command, args, verbose);

  return {
    tool: toolName,
    description: cfg.description,
    available: res.available,
    exitCode: res.exitCode,
    stdout: res.stdout,
    stderr: res.stderr,
    critical: cfg.critical,
    canFix: cfg.canFix,
    fixed: fixMode && cfg.canFix,
    durationMs: nowMs() - started,
  };
}

async function runAllChecks(cli: Cli): Promise<Report> {
  const started = nowMs();

  const preferredOrder = ['prettier-check', 'eslint', 'tsc', 'test', 'build'];
  const defaultTools = preferredOrder.filter((t) =>
    Object.prototype.hasOwnProperty.call(TOOLS, t),
  );

  const toolsToRun = cli.tool ? [cli.tool] : defaultTools;

  const results: Record<string, ToolResult> = {};

  for (const toolName of toolsToRun) {
    const cfg = TOOLS[toolName];
    if (!cfg) {
      results[toolName] = {
        tool: toolName,
        description: 'Unknown tool',
        available: false,
        exitCode: 127,
        stdout: '',
        stderr: `Unknown tool: ${toolName}`,
        critical: true,
        canFix: false,
        fixed: false,
        durationMs: 0,
      };
      // eslint-disable-next-line no-continue
      continue;
    }
    // eslint-disable-next-line no-await-in-loop
    results[toolName] = await runTool(toolName, cfg, cli.fix, cli.verbose);
  }

  const criticalFailures = Object.values(results).filter((r) => r.critical && r.exitCode !== 0)
    .length;

  const overallStatus: Summary['overallStatus'] = criticalFailures > 0 ? 'FAIL' : 'PASS';

  return {
    tools: results,
    summary: {
      totalToolsRun: Object.keys(results).length,
      criticalFailures,
      overallStatus,
      durationMs: nowMs() - started,
    },
    meta: {
      targetDirs: cli.paths.length > 0 ? cli.paths : TARGET_DIRS,
    },
  };
}

async function main(): Promise<void> {
  const cli = parseArgs(process.argv.slice(2));
  const report = await runAllChecks(cli);

  if (cli.json) {
    // eslint-disable-next-line no-console
    console.log(JSON.stringify(report, null, 2));
  } else {
    // eslint-disable-next-line no-console
    console.error(`Status: ${report.summary.overallStatus}`);
    // eslint-disable-next-line no-console
    console.error(`Duration: ${report.summary.durationMs}ms`);
    for (const [name, r] of Object.entries(report.tools)) {
      const status = r.exitCode === 0 ? 'OK' : 'FAIL';
      // eslint-disable-next-line no-console
      console.log(`  ${name}: ${status}`);
    }
  }

  process.exit(report.summary.overallStatus === 'PASS' ? 0 : 1);
}

// eslint-disable-next-line @typescript-eslint/no-floating-promises
main();

