#!/usr/bin/env python3
"""
build.py — Python-specific CI logic

This module handles Python-specific tooling: formatters, linters, type checkers,
test runners. It is called by the orchestrator (build.ps1) and returns structured
JSON output.

Adapt the TOOLS configuration and TARGET_DIRS to your project.
"""

import argparse
import json
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional


# =============================================================================
# Configuration
# =============================================================================

# Directories to check (relative to project root)
TARGET_DIRS = ["src", "tests"]

# Tool configurations
TOOLS: Dict[str, Dict[str, Any]] = {
    "ruff-format": {
        "command": [sys.executable, "-m", "ruff"],
        "args": ["format", "--check"],
        "args_fix": ["format"],
        "description": "Code formatter (ruff)",
        "can_fix": True,
        "critical": False,
    },
    "ruff-lint": {
        "command": [sys.executable, "-m", "ruff"],
        "args": ["check"],
        "args_fix": ["check", "--fix"],
        "description": "Linter (ruff)",
        "can_fix": True,
        "critical": True,
    },
    "mypy": {
        "command": [sys.executable, "-m", "mypy"],
        "args": [],
        "description": "Type checker (mypy)",
        "can_fix": False,
        "critical": True,
    },
    "pytest": {
        "command": [sys.executable, "-m", "pytest"],
        "args": ["-q", "--tb=short"],
        "description": "Test runner (pytest)",
        "can_fix": False,
        "critical": True,
    },
}


# =============================================================================
# Tool Runner
# =============================================================================


def run_tool(
    tool_name: str,
    target_paths: Optional[List[str]] = None,
    fix_mode: bool = False,
    verbose: bool = False,
) -> Dict[str, Any]:
    """Run a single tool and return structured results."""

    if tool_name not in TOOLS:
        return {
            "tool": tool_name,
            "available": False,
            "error": f"Unknown tool: {tool_name}",
            "exit_code": 127,
        }

    config = TOOLS[tool_name]
    paths = target_paths or TARGET_DIRS

    # Build command
    command = list(config["command"])

    if fix_mode and config.get("can_fix"):
        command.extend(config.get("args_fix", []))
    else:
        command.extend(config.get("args", []))

    # Add target paths (except for tools that don't take paths)
    if tool_name not in ["pytest"]:  # pytest uses pyproject.toml config
        command.extend(paths)

    if verbose:
        print(f"Running: {' '.join(command)}", file=sys.stderr)

    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=300,  # 5 minute timeout
        )

        return {
            "tool": tool_name,
            "description": config["description"],
            "available": True,
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "critical": config["critical"],
            "can_fix": config.get("can_fix", False),
            "fixed": fix_mode and config.get("can_fix", False),
        }

    except subprocess.TimeoutExpired:
        return {
            "tool": tool_name,
            "available": True,
            "exit_code": 124,
            "error": "Command timed out",
            "critical": config["critical"],
        }
    except FileNotFoundError:
        return {
            "tool": tool_name,
            "available": False,
            "exit_code": 127,
            "error": f"Tool not found: {config['command'][0]}",
            "critical": config["critical"],
        }


# =============================================================================
# Main Runner
# =============================================================================


def run_all_checks(
    target_paths: Optional[List[str]] = None,
    fix_mode: bool = False,
    specific_tool: Optional[str] = None,
    verbose: bool = False,
    json_output: bool = False,
) -> Dict[str, Any]:
    """Run all configured tools and return aggregated results."""

    start_time = time.time()
    results: Dict[str, Any] = {}

    # Determine which tools to run
    tools_to_run = [specific_tool] if specific_tool else list(TOOLS.keys())

    # Standard order
    preferred_order = ["ruff-format", "ruff-lint", "mypy", "pytest"]
    tools_to_run = [t for t in preferred_order if t in tools_to_run]

    # Run each tool
    for tool_name in tools_to_run:
        result = run_tool(
            tool_name,
            target_paths=target_paths,
            fix_mode=fix_mode,
            verbose=verbose,
        )
        results[tool_name] = result

        if not json_output:
            status = "OK" if result["exit_code"] == 0 else "FAIL"
            print(f"  {tool_name}: {status}")

    # Generate summary
    critical_failures = sum(
        1
        for r in results.values()
        if r.get("exit_code", 0) != 0 and r.get("critical", False)
    )

    results["summary"] = {
        "total_tools_run": len(results) - 1,  # exclude summary itself
        "critical_failures": critical_failures,
        "overall_status": "FAIL" if critical_failures > 0 else "PASS",
        "execution_time": round(time.time() - start_time, 2),
    }

    return results


# =============================================================================
# CLI
# =============================================================================


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Python CI tool runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "--tool",
        choices=list(TOOLS.keys()),
        help="Run only specific tool",
    )

    parser.add_argument(
        "--path",
        nargs="+",
        help="Target paths (default: src tests)",
    )

    parser.add_argument(
        "--fix",
        action="store_true",
        help="Auto-fix issues where possible",
    )

    parser.add_argument(
        "--no-fix",
        action="store_true",
        help="Disable auto-fixing (for CI)",
    )

    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Verbose output",
    )

    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON",
    )

    args = parser.parse_args()

    # Determine fix mode
    fix_mode = args.fix and not args.no_fix

    # Validate paths
    target_paths = None
    if args.path:
        import os

        target_paths = []
        for path in args.path:
            if os.path.exists(path):
                target_paths.append(path)
            else:
                print(f"Warning: Path not found: {path}", file=sys.stderr)

    # Run checks
    results = run_all_checks(
        target_paths=target_paths,
        fix_mode=fix_mode,
        specific_tool=args.tool,
        verbose=args.verbose,
        json_output=args.json,
    )

    # Output
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        summary = results["summary"]
        print()
        print(f"Status: {summary['overall_status']}")
        print(f"Duration: {summary['execution_time']}s")

    # Exit code
    sys.exit(0 if results["summary"]["overall_status"] == "PASS" else 1)


if __name__ == "__main__":
    main()

