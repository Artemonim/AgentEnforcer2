//! build.rs — Rust-specific CI logic (template)
//!
//! This is a reference implementation for the "language-specific layer"
//! in the Agent Enforcer 2 blueprint.
//!
//! It is intended to be called by an orchestrator (e.g. `build.ps1`) and prints
//! structured JSON output describing tool results.
//!
//! Adapt the `CONFIG` section to your project.
//!
//! Dependencies (put into your project's `Cargo.toml` if you adopt this file):
//! - clap = { version = "4", features = ["derive"] }
//! - serde = { version = "1", features = ["derive"] }
//! - serde_json = "1"
//! - anyhow = "1"
//!
//! Security:
//! - Never embed secrets in this file. Use environment variables instead.
//! - Avoid executing untrusted inputs as shell commands.
//!
//! Notes:
//! - This template avoids shell invocation and uses `std::process::Command`.
//! - Add timeouts if your environment requires strict execution limits.
#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use std::process::{Command, ExitStatus};
use std::time::Instant;

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use serde::Serialize;

// =============================================================================
// Configuration
// =============================================================================

/// Directories to check (relative to project root).
const TARGET_DIRS: &[&str] = &["src", "crates", "tests"];

/// Configures which tools/stages exist and how they are executed.
///
/// * Keep this list aligned with your `build.ps1` stages.
fn tools_config() -> BTreeMap<&'static str, ToolConfig> {
    BTreeMap::from([
        (
            "cargo-fmt",
            ToolConfig {
                description: "Formatter (cargo fmt)",
                critical: true,
                can_fix: false,
                command: "cargo",
                args: vec!["fmt", "--all", "--", "--check"],
                args_fix: vec!["fmt", "--all"],
            },
        ),
        (
            "cargo-clippy",
            ToolConfig {
                description: "Linter (cargo clippy)",
                critical: true,
                can_fix: false,
                command: "cargo",
                args: vec![
                    "clippy",
                    "--all-targets",
                    "--all-features",
                    "--",
                    "-D",
                    "warnings",
                ],
                args_fix: vec![],
            },
        ),
        (
            "cargo-test",
            ToolConfig {
                description: "Test runner (cargo test)",
                critical: true,
                can_fix: false,
                command: "cargo",
                args: vec!["test", "--all-features"],
                args_fix: vec![],
            },
        ),
    ])
}

#[derive(Clone, Debug)]
struct ToolConfig {
    description: &'static str,
    critical: bool,
    can_fix: bool,
    command: &'static str,
    /// Arguments for "check" mode.
    args: Vec<&'static str>,
    /// Arguments for "fix" mode (optional).
    args_fix: Vec<&'static str>,
}

// =============================================================================
// Output format
// =============================================================================

#[derive(Debug, Serialize)]
struct ToolResult {
    tool: String,
    description: String,
    available: bool,
    exit_code: i32,
    stdout: String,
    stderr: String,
    critical: bool,
    can_fix: bool,
    fixed: bool,
    duration_ms: u128,
}

#[derive(Debug, Serialize)]
struct Summary {
    total_tools_run: usize,
    critical_failures: usize,
    overall_status: String,
    duration_ms: u128,
}

#[derive(Debug, Serialize)]
struct Report {
    tools: BTreeMap<String, ToolResult>,
    summary: Summary,
}

// =============================================================================
// CLI
// =============================================================================

#[derive(Debug, Parser)]
#[command(name = "build.rs", about = "Rust CI tool runner (template)")]
struct Cli {
    /// Run only one tool by name (e.g. cargo-fmt).
    #[arg(long)]
    tool: Option<String>,

    /// Override target dirs (repeatable): --path src --path crates
    #[arg(long = "path")]
    paths: Vec<String>,

    /// Enable auto-fix where possible (tool-dependent).
    #[arg(long)]
    fix: bool,

    /// Print the report as JSON (recommended for orchestrators).
    #[arg(long)]
    json: bool,

    /// Print extra logs to stderr.
    #[arg(long, short)]
    verbose: bool,
}

// =============================================================================
// Tool runner
// =============================================================================

fn status_to_exit_code(status: ExitStatus) -> i32 {
    match status.code() {
        Some(code) => code,
        None => 1, // terminated by signal on Unix, or otherwise unknown
    }
}

fn run_tool(
    tool_name: &str,
    cfg: &ToolConfig,
    target_paths: &[String],
    fix_mode: bool,
    verbose: bool,
) -> ToolResult {
    let started = Instant::now();

    let mut cmd = Command::new(cfg.command);

    let args = if fix_mode && cfg.can_fix && !cfg.args_fix.is_empty() {
        &cfg.args_fix
    } else {
        &cfg.args
    };
    cmd.args(args);

    // * Rust tooling typically uses the workspace config; paths are optional.
    // * If you want per-path clippy checks, adapt this logic to your layout.
    if verbose {
        eprintln!("Running: {} {}", cfg.command, args.join(" "));
        if !target_paths.is_empty() {
            eprintln!("Target paths: {}", target_paths.join(", "));
        }
    }

    let output = match cmd.output() {
        Ok(out) => out,
        Err(err) => {
            return ToolResult {
                tool: tool_name.to_string(),
                description: cfg.description.to_string(),
                available: false,
                exit_code: 127,
                stdout: String::new(),
                stderr: format!("Failed to execute `{}`: {}", cfg.command, err),
                critical: cfg.critical,
                can_fix: cfg.can_fix,
                fixed: fix_mode && cfg.can_fix,
                duration_ms: started.elapsed().as_millis(),
            };
        }
    };

    ToolResult {
        tool: tool_name.to_string(),
        description: cfg.description.to_string(),
        available: true,
        exit_code: status_to_exit_code(output.status),
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        critical: cfg.critical,
        can_fix: cfg.can_fix,
        fixed: fix_mode && cfg.can_fix,
        duration_ms: started.elapsed().as_millis(),
    }
}

fn run_all_checks(cli: &Cli) -> Result<Report> {
    let started = Instant::now();

    let configs = tools_config();

    let mut tools_to_run: Vec<String> = if let Some(ref only) = cli.tool {
        vec![only.clone()]
    } else {
        configs.keys().map(|s| (*s).to_string()).collect()
    };

    // Standard order.
    let preferred_order = ["cargo-fmt", "cargo-clippy", "cargo-test"];
    tools_to_run.sort_by_key(|name| {
        preferred_order
            .iter()
            .position(|x| x == name)
            .unwrap_or(999)
    });

    let target_paths = if cli.paths.is_empty() {
        TARGET_DIRS.iter().map(|p| (*p).to_string()).collect()
    } else {
        cli.paths.clone()
    };

    let mut results: BTreeMap<String, ToolResult> = BTreeMap::new();

    for tool_name in tools_to_run {
        let cfg = configs
            .get(tool_name.as_str())
            .ok_or_else(|| anyhow!("Unknown tool: {}", tool_name))?;

        let res = run_tool(&tool_name, cfg, &target_paths, cli.fix, cli.verbose);
        results.insert(tool_name, res);
    }

    let critical_failures = results
        .values()
        .filter(|r| r.critical && r.exit_code != 0)
        .count();

    let overall_status = if critical_failures > 0 {
        "FAIL".to_string()
    } else {
        "PASS".to_string()
    };

    Ok(Report {
        summary: Summary {
            total_tools_run: results.len(),
            critical_failures,
            overall_status,
            duration_ms: started.elapsed().as_millis(),
        },
        tools: results,
    })
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    let report = run_all_checks(&cli).context("Failed to run Rust checks")?;

    if cli.json {
        let json = serde_json::to_string_pretty(&report)?;
        println!("{json}");
    } else {
        eprintln!("Status: {}", report.summary.overall_status);
        eprintln!("Duration: {}ms", report.summary.duration_ms);
        for (name, r) in &report.tools {
            let status = if r.exit_code == 0 { "OK" } else { "FAIL" };
            println!("  {name}: {status}");
        }
    }

    if report.summary.overall_status == "PASS" {
        Ok(())
    } else {
        Err(anyhow!("Rust checks failed"))
    }
}

