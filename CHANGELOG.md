# Changelog

All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [SemVer](https://semver.org/).

## [Unreleased]

- **agent-bridge folded in** (`tools/bridge/`): read every agent's chat sessions from any agent (Claude Code, Codex, opencode, ZCode), search across all of them, and schedule agent work via Windows Task Scheduler. MCP server `agent_bridge` exposes `sessions_agents`, `sessions_list`, `session_read`, `session_search`, `schedule_add`, `schedule_list`, `schedule_remove`.
- `install.ps1 -WithBridge` / `install.sh --with-bridge` deploy the bridge and register its MCP server in Claude Code, Codex and opencode.
- Gemini CLI wiring now happens automatically when `~/.gemini` exists.
- `CONTRIBUTING.md`, bug-report issue template, and bridge smoke tests.

## [0.3.0] - 2026-09-16

Reliability release:

- **Tests**: `tests/test_mem_mcp.py`, `tests/test_dump_tools.py` (pytest) and `tests/mem.Tests.ps1` (Pester 5+) covering MCP handshake, secret refusal, hot-log append, managed-block sync idempotency, prune, and the dump tools against synthetic databases.
- **CI**: `.github/workflows/ci.yml` runs pytest on Windows, Pester on Windows, and `shellcheck` + `bash -n` on Linux.
- **`prune`**: `mem.ps1 prune -Keep 50`, `mem.sh prune -Keep 50`, and MCP `memory_prune` trim the hot log with a timestamped backup; `doctor` now warns when `MEMORY.md` exceeds 150 lines.
- **`uninstall.ps1`**: reverses installer wiring (Claude hook, opencode MCP + instructions, Codex `[mcp_servers.ai_memory]`, AGENTS.md blocks) with per-file backups; `-RemoveStore` optionally deletes the store.
- **Fixes**: `install.ps1` no longer writes `[null, path]` when `instructions` is missing and no longer duplicates the memory path on re-runs; search in `mem.ps1`/`mem.sh`/MCP skips files over 1 MB with a warning and caps output (200 matches / 8000 chars); MCP `memory_search` gained `max_chars`.

## [0.2.0] - 2026-09-16

- **Mining workflow**: `docs/mining.md`, `examples/PROJECT.template.md`, and read-only dumpers `tools/dump/dump_claude_mem.py`, `dump_opencode.py`, `split_projects.py` for turning existing agent history into `projects/*.md` state files.
- **Secret guard**: `mem add` (PowerShell, bash, MCP) refuses credential-shaped text unless forced.
- **`doctor`**: verifies store, AGENTS.md block freshness, Claude hook, opencode/Codex wiring, python, and a live MCP handshake.
- **Unix support**: `tools/mem.sh`, `tools/sessionstart-hook.sh`, `tools/install.sh` with working-python resolution and CR-safe parsing.

## [0.1.0] - 2026-09-16

- Initial release: `MEMORY.md` hot layer with native injection into Claude Code (`SessionStart` hook), opencode (`instructions`), Codex/ZCode (managed `AGENTS.md` blocks); append-only logs and per-project files; `tools/mem.ps1` CLI; stdlib MCP server `ai_memory` (`memory_read` / `memory_search` / `memory_add` / `memory_projects`); `install.ps1` with backups.
