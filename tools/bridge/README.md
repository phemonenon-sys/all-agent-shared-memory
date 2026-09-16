# agent-bridge (component of All-Agent Shared Memory)

One shared session layer: **any agent can read every other agent's chats, and any agent can schedule work.**
Source lives here; `install.ps1 -WithBridge` deploys it to `~/.agents/agent-bridge/` and registers the
`agent_bridge` MCP server in Claude Code, Codex and opencode.

## What it does

| Capability | How |
|---|---|
| Read another agent's chat | `bridge.py read --agent codex --session <id>` (normalized `[user]` / `[assistant]` / `[tool]` transcript) |
| See every session | `bridge.py list` (Claude projects, Codex rollouts + archived, opencode DB, ZCode transcripts) |
| Search all history | `bridge.py search --query "frozen model"` |
| Use from inside any agent | MCP server `agent_bridge` -> `sessions_agents`, `sessions_list`, `session_read`, `session_search` |
| Schedule agent work | MCP -> `schedule_add` / `schedule_list` / `schedule_remove` (Windows Task Scheduler; logs to `~/.agents/scheduler/logs/`) |

Scheduling templates: `agent=claude` -> `claude -p "<prompt>"`; `agent=codex` -> `codex exec "<prompt>"`;
the opencode desktop app ships no headless CLI on PATH, so pass a raw `--command` if you wire one.

## CLI examples

```powershell
$b = "$env:USERPROFILE\.agents\agent-bridge"
python $b\bridge.py agents
python $b\bridge.py list --agent claude --limit 10
python $b\bridge.py read --agent codex --session 019fb445 --tail 40
python $b\bridge.py search --query "frozen model" --limit 10

python $b\sched.py add --name nightly-notes --time 03:30 --daily --agent claude --prompt "..."
python $b\sched.py list
python $b\sched.py remove --name nightly-notes
```

## Safety

- Read-only on every agent store (SQLite opened `mode=ro`).
- ZCode "model I/O" logs contain full request bodies; the bridge reads only `transcript.jsonl` files, not those.
- Scheduled tasks are local Windows Task Scheduler entries under the `AgentScheduler\` folder; delete via `sched.py remove` or Task Scheduler.

## Tests

`tests/test_bridge_smoke.py` covers transcript normalization, title filtering, scheduling templates and
module imports; run with `python -m pytest -q tests`.
