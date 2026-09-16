# All-Agent Shared Memory

One small memory file that **every** coding agent reads at session start - Claude Code, Codex, opencode, ZCode, Gemini CLI - plus an append-only log, per-project memory files, and a tiny MCP server. No daemon, no database, no embeddings, no LLM in the memory path.

```
every agent session start ─┐
                           ├─ reads  MEMORY.md   (curated hot layer, auto-injected natively)
agent learns a fact ───────┘
                           ├─ writes log\<yyyy-MM>.md        (mem.ps1 add / MCP memory_add)
                           ├─ writes projects\<name>.md      (mem.ps1 add -Project name)
                           └─ HOT facts also land in MEMORY.md (-Hot)
```

## Why another agent-memory tool?

The space has grown ([deja-vu](https://github.com/vshulcz/deja-vu), [memorix](https://github.com/AVIDS2/memorix), [memmy-agent](https://github.com/MemTensor/memmy-agent), [cass_memory_system](https://github.com/Dicklesworthstone/cass_memory_system), [memsearch](https://github.com/zilliztech/memsearch), [shared-agent-memory](https://github.com/dan-calin/shared-agent-memory) and many more). This one is deliberately the smallest:

- **Zero dependencies.** PowerShell 5.1+ scripts and a Python-stdlib-only MCP server. No Go/Rust/Node binary, no vector DB, no API keys, no build step.
- **Static injection, not retrieval.** Each host loads `MEMORY.md` through its own native mechanism, so memory is simply *in context at session start* - nothing to query, nothing to forget to call.
- **Writes stay explicit.** Facts are appended by a one-line command or an MCP tool call; no hidden capture, no transcripts leaving your machine.
- **Windows-first wiring that actually exists**: SessionStart hook for Claude Code, `instructions` for opencode, managed `AGENTS.md` blocks for Codex and ZCode, `GEMINI.md` for Gemini CLI.
- **Comes with a session-mining method** so an existing pile of agent history can be distilled into `projects\<name>.md` files that let any agent resume any project without a handoff.

If you want semantic search over years of transcripts, use one of the tools above. If you want "one markdown file every agent already reads, wired up in five minutes", this is that.

## Install

Requires Windows with PowerShell 5.1+ and Python 3.10+ (Python is only needed for the MCP server; the store and CLI work without it).

```powershell
git clone https://github.com/<you>/all-agent-shared-memory
cd all-agent-shared-memory
powershell -NoProfile -ExecutionPolicy Bypass -File tools\install.ps1
```

The installer is idempotent and backs up every config it touches:

1. Creates the store at `%USERPROFILE%\.agents\memory` (override with `-StorePath`).
2. Copies the tools and seeds `MEMORY.md` from `examples\MEMORY.template.md`.
3. Adds the Claude Code `SessionStart` hook to `~/.claude/settings.json`.
4. Adds `instructions` + the `ai_memory` MCP server to `~/.config/opencode/opencode.json`.
5. Appends `[mcp_servers.ai_memory]` to `~/.codex/config.toml`.
6. Syncs managed `AGENTS.md` blocks into `~/.codex/AGENTS.md` and `~/.zcode/workspace/default/AGENTS.md`.

Preview first with `-DryRun`; skip pieces with `-SkipClaude`, `-SkipOpencode`, `-SkipCodex`, `-SkipZcode`.

## Daily use

```powershell
$mem = "$env:USERPROFILE\.agents\memory\tools\mem.ps1"

powershell -NoProfile -File $mem read                          # print the hot layer
powershell -NoProfile -File $mem add -Text "fact"              # append to this month's log
powershell -NoProfile -File $mem add -Text "fact" -Hot         # also pin into MEMORY.md
powershell -NoProfile -File $mem add -Text "fact" -Project myproject
powershell -NoProfile -File $mem search -Query "frozen hashes"
powershell -NoProfile -File $mem sync                          # refresh embedded AGENTS.md copies
powershell -NoProfile -File $mem status
```

Anything you save with `-Hot` is in every agent's next session. The MCP server exposes the same operations as tools: `memory_read`, `memory_search`, `memory_add`, `memory_projects` (registered automatically for Claude Code, Codex and opencode; any MCP client can run it directly: `python tools\mem-mcp.py`).

## Layout

```
~/.agents/memory/
  MEMORY.md              curated hot layer - auto-loaded everywhere
  log\<yyyy-MM>.md       append-only notes
  projects\<name>.md     per-project memory (state, paths, rules, open threads)
  hosts.json             which AGENTS.md files get the synced block
  tools\
    mem.ps1              CLI
    sessionstart-hook.ps1  Claude Code hook (emits MEMORY.md as session context)
    mem-mcp.py           stdio MCP server (stdlib only)
```

## How each agent gets the memory

| Agent | Mechanism | Live? |
|---|---|---|
| Claude Code | `SessionStart` hook -> additionalContext | every session |
| opencode | `instructions` array points at `MEMORY.md` | every session |
| Codex | managed block in `~/.codex/AGENTS.md` (`mem.ps1 sync`) | refresh with sync |
| ZCode | managed block in its workspace `AGENTS.md` + its native memory pointer | refresh with sync |
| Gemini CLI | `@`-import of `MEMORY.md` in `~/.gemini/GEMINI.md` | every session |
| any MCP client | `ai_memory` server (stdio) | on tool call |

## Mining existing sessions (the "no handoff needed" trick)

The `projects\` layer is what makes agents able to continue work cold. To build it from history already on disk:

1. Dump each host's distilled session store to text (claude-mem SQLite: `session_summaries`; Codex: `~/.codex/memories/rollout_summaries\`; ZCode: `~/.zcode/cli/memories\`; opencode: `opencode.db`).
2. Have one agent per source extract dated facts per project into a mining folder.
3. Have one agent per project merge those extracts into `projects\<name>.md` (state newest-first, key paths, rules/gates, open threads, traps, evidence pointers).
4. Reference the project files from `MEMORY.md` so every agent knows they exist.

## Security notes

- Memory files are plain markdown - never store secrets, tokens or credentials in them.
- The hook prints the memory file into the session context; keep that in mind if you mirror the store anywhere.
- Uninstall is manual by design: remove the hook / `ai_memory` entries and delete the store.

## License

MIT
