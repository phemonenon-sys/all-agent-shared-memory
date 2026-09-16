# All-Agent Shared Memory

[![ci](https://github.com/<you>/all-agent-shared-memory/actions/workflows/ci.yml/badge.svg)](https://github.com/<you>/all-agent-shared-memory/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

One small memory file that **every** coding agent reads at session start - Claude Code, Codex, opencode, ZCode, Gemini CLI - plus an append-only log, per-project memory files, and a tiny MCP server. No daemon, no database, no embeddings, no LLM in the memory path. The whole system is a few hundred readable lines: audit it before you trust it with your agents' memory.

```
every agent session start ─┐
                           ├─ reads  MEMORY.md   (curated hot layer, auto-injected natively)
agent learns a fact ───────┘
                           ├─ writes log\<yyyy-MM>.md        (mem add / MCP memory_add)
                           ├─ writes projects\<name>.md      (mem add -Project name)
                           └─ HOT facts also land in MEMORY.md (-Hot)
```

## Why this one

The agent-memory space is crowded ([deja-vu](https://github.com/vshulcz/deja-vu), [memorix](https://github.com/AVIDS2/memorix), [memmy-agent](https://github.com/MemTensor/memmy-agent), [cass_memory_system](https://github.com/Dicklesworthstone/cass_memory_system), [memsearch](https://github.com/zilliztech/memsearch), [shared-agent-memory](https://github.com/dan-calin/shared-agent-memory), and many more). This one is deliberately the smallest, and it does three things most of them do not:

1. **Zero dependencies, zero binaries.** PowerShell and Python-stdlib scripts only. No Go/Rust/Node binary to install, no vector DB, no background service, no API keys. If you can read a script, you can audit your memory layer.
2. **Static injection, not retrieval.** Each host loads `MEMORY.md` through its own native mechanism at session start, so memory is simply *in context* - nothing to query, nothing to forget to call.
3. **Handoff elimination.** Ships the [session-mining playbook](docs/mining.md) that distills existing agent history (claude-mem, Codex, opencode, ZCode) into curated `projects\<name>.md` state files, so a brand-new agent can continue any project cold.
4. **Cross-agent sessions + scheduling** (`tools/bridge`, optional via `-WithBridge`). Any agent can list/read/search every other agent's chats - Claude Code, Codex, opencode, ZCode - and schedule work in them. The retrieval layer, without the binary.

Plus small things that matter: **secret-pattern refusal at write time** (keys/tokens never enter memory files), a **doctor** command that verifies every wiring point, **`prune`** so the hot layer cannot grow forever, and a **test suite + CI** (pytest, Pester, shellcheck) you can point at.

## Install

**Windows** (PowerShell 5.1+, Python 3.10+ recommended for MCP):

```powershell
git clone https://github.com/<you>/all-agent-shared-memory
cd all-agent-shared-memory
powershell -NoProfile -ExecutionPolicy Bypass -File tools\install.ps1 [-WithBridge] [-DryRun]
```

**Linux / macOS** (bash, Python 3.10+ recommended):

```bash
git clone https://github.com/<you>/all-agent-shared-memory
cd all-agent-shared-memory
bash tools/install.sh [--with-bridge]
```

Both installers are idempotent, back up every config they touch, and wire:

1. Store at `~/.agents/memory` (memory store: `MEMORY.md`, `log/`, `projects/`, `hosts.json`).
2. Claude Code `SessionStart` hook (`~/.claude/settings.json`).
3. opencode `instructions` + `ai_memory` MCP server (`~/.config/opencode/opencode.json`).
4. Codex `[mcp_servers.ai_memory]` (`~/.codex/config.toml`).
5. Managed `AGENTS.md` blocks for Codex and ZCode (targets listed in `hosts.json`).
6. Gemini CLI: add `@~/.agents/memory/MEMORY.md` to `~/.gemini/GEMINI.md` (one line, manual).

Note: when patching `settings.json` / `opencode.json`, the installer rewrites the file through a JSON round-trip (formatting may change; comments are not valid in these files anyway). Every touched file is backed up as `*.bak-asm-*` first.

## Daily use

Windows:

```powershell
$mem = "$env:USERPROFILE\.agents\memory\tools\mem.ps1"
powershell -NoProfile -File $mem read|add|search|sync|status|doctor
```

Linux / macOS / Git Bash: `bash ~/.agents/memory/tools/mem.sh <command>`

```text
add -Text "fact" [-Hot] [-Project name]     append a durable fact (-Hot pins into MEMORY.md)
search -Query "..."                          search the store (skips files >1MB, caps output)
prune [-Keep 50]                             trim the MEMORY.md hot log (timestamped backup kept)
doctor                                       verify every wiring point; warns when MEMORY.md >150 lines
sync                                         refresh embedded AGENTS.md copies
```

- `add` refuses text that looks like a credential (API keys, tokens, JWTs, private keys). `-Force` overrides for confirmed false positives.
- MCP tools (`memory_read`, `memory_search`, `memory_add`, `memory_projects`, `memory_prune`) are registered for Claude Code, Codex and opencode; any MCP client can run the server directly: `python tools/mem-mcp.py` (override store with `AI_MEMORY_DIR`).

## Mining your history into handoff-free project files

`projects\<name>.md` files are what let a fresh agent resume work without a handoff. The full method with agent prompt templates is in [docs/mining.md](docs/mining.md); the tools are:

```bash
python tools/dump/dump_claude_mem.py --db ~/.claude-mem/claude-mem.db --out mining/claude-mem-dump.md
python tools/dump/dump_opencode.py   --db ~/.local/share/opencode/opencode.db --out mining/opencode-dump.md
python tools/dump/split_projects.py  --in mining/claude-mem-dump.md --outdir mining/claude-mem
```

All dumps are read-only. Codex (`~/.codex/memories/`) and ZCode (`~/.zcode/cli/memories/`) are already Markdown - point agents at those folders directly.

## Tests

CI runs on every push: pytest and Pester on Windows, `shellcheck` + `bash -n` on Linux (`.github/workflows/ci.yml`). Locally:

```powershell
python -m pytest -q tests                      # MCP server, secret guard, search guards, prune, dump tools
powershell -Command "Invoke-Pester -Path tests" # mem.ps1: hot log, managed blocks, prune, doctor
```

## Layout

```
~/.agents/memory/
  MEMORY.md              curated hot layer - auto-loaded everywhere
  log\<yyyy-MM>.md       append-only notes
  projects\<name>.md     per-project state (state, paths, rules, open threads)
  hosts.json             which AGENTS.md files get the synced block
  tools\
    mem.ps1 / mem.sh       CLI (Windows / Unix)
    sessionstart-hook.ps1 / .sh   Claude Code hooks
    mem-mcp.py             stdio MCP server (stdlib only)
    bridge\                cross-agent sessions + scheduler (optional; -WithBridge)
    dump\                  read-only history dumpers (claude-mem, opencode, split)
docs/mining.md           history -> project files playbook
examples\                MEMORY.template.md, PROJECT.template.md
```

## How each agent gets the memory

| Agent | Mechanism | Live? |
|---|---|---|
| Claude Code | `SessionStart` hook -> additionalContext | every session |
| opencode | `instructions` array points at `MEMORY.md` | every session |
| Codex | managed block in `~/.codex/AGENTS.md` (`mem sync`) | refresh with sync |
| ZCode | managed block in its workspace `AGENTS.md` + native memory pointer | refresh with sync |
| Gemini CLI | `@`-import of `MEMORY.md` in `~/.gemini/GEMINI.md` | every session |
| any MCP client | `ai_memory` server (stdio) | on tool call |

## Security notes

- Memory files are plain markdown and the write path refuses credential-shaped text - but no scanner is perfect: never paste real secrets into memory.
- The Claude hook prints the memory file into the session context; keep that in mind if you mirror the store anywhere.
- Nothing leaves your machine. There is no telemetry and no network code outside the dump scripts' file reads.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\uninstall.ps1 -DryRun   # preview
powershell -NoProfile -ExecutionPolicy Bypass -File tools\uninstall.ps1           # remove wiring
powershell -NoProfile -ExecutionPolicy Bypass -File tools\uninstall.ps1 -RemoveStore  # also delete the store
```

It reverses the Claude hook, the opencode `ai_memory` + instruction entry, the Codex `[mcp_servers.ai_memory]` section and the managed `AGENTS.md` blocks, keeping `*.bak-uninstall-*` backups of every touched file.

## License

MIT - see [CHANGELOG.md](CHANGELOG.md) for release history.
