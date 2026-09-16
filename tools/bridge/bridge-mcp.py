#!/usr/bin/env python3
r"""agent_bridge - stdio MCP server: read every agent's sessions + schedule agent work.

Tools:
  sessions_agents()                          which agent stores are readable + counts
  sessions_list(agent?, limit?)              recent sessions across Claude/Codex/opencode/ZCode
  session_read(agent, session, tail?, max_chars?)   normalized transcript
  session_search(query, agent?, limit?)      search across all session stores
  schedule_add(name, time, agent?, prompt?, command?, daily?)  Windows Task Scheduler
  schedule_list()
  schedule_remove(name)

stdlib only; read-only on all agent stores.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import bridge  # noqa: E402
import sched  # noqa: E402


def sessions_agents() -> str:
    counts = {
        "claude": len(bridge.claude_sessions(500)),
        "codex": len(bridge.codex_sessions(500)),
        "opencode": len(bridge.opencode_sessions(500)),
        "zcode": len(bridge.zcode_sessions(500)),
    }
    return "\n".join(f"{agent}: {count} sessions readable" for agent, count in counts.items())


def sessions_list(agent: str = "", limit: int = 15) -> str:
    agent = agent.strip() or None
    merged = []
    if agent in (None, "claude"):
        merged += bridge.claude_sessions(limit)
    if agent in (None, "codex"):
        merged += bridge.codex_sessions(limit)
    if agent in (None, "opencode"):
        merged += bridge.opencode_sessions(limit)
    if agent in (None, "zcode"):
        merged += bridge.zcode_sessions(limit)
    merged.sort(key=lambda s: s["when"], reverse=True)
    lines = [
        f"{s['agent']:9s} {s['when']}  {s['id']}  {s['title'][:90]}"
        + (f"  @ {s['extra']}" if s.get("extra") else "")
        for s in merged[:limit]
    ]
    return "\n".join(lines) or "no sessions found"


def session_read(agent: str, session: str, tail: int = 60, max_chars: int = 30000) -> str:
    agent = agent.strip().lower()
    if agent == "claude":
        return bridge.claude_read(session, tail, max_chars)
    if agent == "codex":
        return bridge.codex_read(session, tail, max_chars)
    if agent == "opencode":
        return bridge.opencode_read(session, tail, max_chars)
    if agent == "zcode":
        found = [p for p in bridge.zcode_files(500) if session in p]
        if not found:
            return f"zcode session not found: {session}"
        return bridge._apply_tail(bridge.zcode_parse(found[0])[2], tail, max_chars)
    return f"unknown agent: {agent} (use claude|codex|opencode|zcode)"


def session_search(query: str, agent: str = "", limit: int = 20) -> str:
    import contextlib
    import io

    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        bridge.cmd_search(query, agent.strip() or None, limit)
    return buffer.getvalue().strip() or "no hits"


def schedule_add(name: str, time: str, agent: str = "", prompt: str = "", command: str = "", daily: bool = True) -> str:
    try:
        cmd = sched.build_command(agent, prompt.replace('"', "'"), command)
        return sched.add(name, cmd, time, bool(daily), "")
    except (ValueError, RuntimeError) as exc:
        return f"error: {exc}"


def schedule_list() -> str:
    return sched.list_tasks()


def schedule_remove(name: str) -> str:
    try:
        return sched.remove(name)
    except ValueError as exc:
        return f"error: {exc}"


TOOLS = [
    {
        "name": "sessions_agents",
        "description": "List which agent session stores are readable from any agent and their session counts.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "sessions_list",
        "description": "List recent chat sessions across Claude Code, Codex, opencode and ZCode (newest first).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agent": {"type": "string", "description": "Optional filter: claude | codex | opencode | zcode."},
                "limit": {"type": "integer", "description": "Max sessions (default 15)."},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "session_read",
        "description": "Read a session transcript from another agent, normalized to [user]/[assistant]/[tool] lines.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agent": {"type": "string", "description": "claude | codex | opencode | zcode"},
                "session": {"type": "string", "description": "Session id (from sessions_list)."},
                "tail": {"type": "integer", "description": "How many trailing entries (default 60, 0 = all)."},
                "max_chars": {"type": "integer", "description": "Output cap (default 30000)."},
            },
            "required": ["agent", "session"],
            "additionalProperties": False,
        },
    },
    {
        "name": "session_search",
        "description": "Search all agent chat history for a phrase; returns matching sessions and snippets.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Phrase to find."},
                "agent": {"type": "string", "description": "Optional filter: claude | codex | opencode | zcode."},
                "limit": {"type": "integer", "description": "Max hits (default 20)."},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "schedule_add",
        "description": "Schedule an agent task on this Windows machine (Task Scheduler). agent=claude runs 'claude -p', agent=codex runs 'codex exec', or pass a raw command.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Task name (alphanumeric/dot/dash)."},
                "time": {"type": "string", "description": "HH:MM (24h)."},
                "agent": {"type": "string", "description": "claude | codex | opencode (or leave empty and pass command)."},
                "prompt": {"type": "string", "description": "Prompt for the agent."},
                "command": {"type": "string", "description": "Raw command instead of an agent template."},
                "daily": {"type": "boolean", "description": "true = daily (default), false = one-shot (needs raw command today)."},
            },
            "required": ["name", "time"],
            "additionalProperties": False,
        },
    },
    {
        "name": "schedule_list",
        "description": "List scheduled agent tasks and their next run times.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "schedule_remove",
        "description": "Remove a scheduled task by name.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
            "additionalProperties": False,
        },
    },
]

DISPATCH = {
    "sessions_agents": lambda a: sessions_agents(),
    "sessions_list": lambda a: sessions_list(a.get("agent", ""), int(a.get("limit") or 15)),
    "session_read": lambda a: session_read(
        a.get("agent", ""), a.get("session", ""), int(a.get("tail") if a.get("tail") is not None else 60),
        int(a.get("max_chars") or 30000),
    ),
    "session_search": lambda a: session_search(a.get("query", ""), a.get("agent", ""), int(a.get("limit") or 20)),
    "schedule_add": lambda a: schedule_add(
        a.get("name", ""), a.get("time", ""), a.get("agent", ""), a.get("prompt", ""),
        a.get("command", ""), bool(a.get("daily", True)),
    ),
    "schedule_list": lambda a: schedule_list(),
    "schedule_remove": lambda a: schedule_remove(a.get("name", "")),
}


def reply(request_id, result=None, error=None) -> None:
    message = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        message["error"] = {"code": error[0], "message": error[1]}
    else:
        message["result"] = result if result is not None else {}
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(message: dict) -> None:
    request_id = message.get("id")
    if request_id is None:
        return
    method = message.get("method", "")
    params = message.get("params") or {}
    if method == "initialize":
        reply(
            request_id,
            {
                "protocolVersion": params.get("protocolVersion") or "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "agent-bridge", "version": "0.1.0"},
            },
        )
    elif method == "ping":
        reply(request_id, {})
    elif method == "tools/list":
        reply(request_id, {"tools": TOOLS})
    elif method == "tools/call":
        handler = DISPATCH.get(params.get("name", ""))
        if handler is None:
            reply(request_id, {"content": [{"type": "text", "text": f"Unknown tool: {params.get('name')}"}], "isError": True})
            return
        try:
            reply(request_id, {"content": [{"type": "text", "text": handler(params.get("arguments") or {})}]})
        except Exception as exc:  # noqa: BLE001
            reply(request_id, {"content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}], "isError": True})
    elif method == "resources/list":
        reply(request_id, {"resources": []})
    elif method == "prompts/list":
        reply(request_id, {"prompts": []})
    else:
        reply(request_id, error=(-32601, f"Method not found: {method}"))


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    except Exception:
        pass
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(message, dict):
            handle(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
