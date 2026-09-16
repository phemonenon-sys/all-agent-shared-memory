#!/usr/bin/env python3
r"""ai_memory - stdlib-only MCP (stdio) server for the shared agent memory store.

Store: C:\Users\User\.agents\memory  (override with AI_MEMORY_DIR)
Protocol: MCP JSON-RPC 2.0 over stdio, newline-delimited messages.
"""
import datetime
import json
import os
import pathlib
import sys

ROOT = pathlib.Path(os.environ.get("AI_MEMORY_DIR", pathlib.Path.home() / ".agents" / "memory")).resolve()
MEM = ROOT / "MEMORY.md"
LOG = ROOT / "log"
PROJ = ROOT / "projects"
SERVER_NAME = "ai-memory"
SERVER_VERSION = "1.0.0"


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def memory_read() -> str:
    body = read_text(MEM)
    if not body:
        return f"Shared memory file missing: {MEM}"
    return body


def memory_search(query: str, max_results: int = 50) -> str:
    query = (query or "").lower().strip()
    if not query:
        return "Provide a non-empty query."
    results = []
    candidates = [MEM]
    candidates += sorted(LOG.glob("*.md")) if LOG.is_dir() else []
    candidates += sorted(PROJ.glob("*.md")) if PROJ.is_dir() else []
    for path in candidates:
        if not path.is_file():
            continue
        for number, line in enumerate(read_text(path).splitlines(), 1):
            if query in line.lower():
                rel = path.relative_to(ROOT) if ROOT in path.parents else path.name
                results.append(f"{rel}:{number}: {line.strip()}")
                if len(results) >= max_results:
                    return "\n".join(results)
    return "\n".join(results) if results else f"No matches for: {query}"


def memory_add(text: str, project: str = "", hot: bool = False, agent: str = "") -> str:
    if not text or not text.strip():
        return "Provide non-empty text."
    now = datetime.datetime.now()
    agent = agent.strip() or os.environ.get("AI_AGENT", "agent")
    line = f"- {now.strftime('%Y-%m-%d %H:%M')} [{agent}] {text.strip()}"
    target_desc = ""
    if project.strip():
        PROJ.mkdir(parents=True, exist_ok=True)
        target = PROJ / f"{project.strip()}.md"
        if not target.exists():
            target.write_text(f"# Project memory: {project.strip()}\n", encoding="utf-8")
        with target.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
        target_desc = f"projects/{target.name}"
    else:
        LOG.mkdir(parents=True, exist_ok=True)
        target = LOG / f"{now.strftime('%Y-%m')}.md"
        if not target.exists():
            target.write_text(f"# Memory log {target.stem}\n", encoding="utf-8")
        with target.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
        target_desc = f"log/{target.name}"
    if hot:
        if not MEM.exists():
            return f"Saved to {target_desc}; MEMORY.md missing, hot append skipped."
        body = read_text(MEM)
        if "## Hot log (auto)" not in body:
            body = body.rstrip() + "\n\n## Hot log (auto)\n"
        MEM.write_text(body.rstrip() + "\n" + line + "\n", encoding="utf-8")
        target_desc += " + MEMORY.md hot log"
    return f"Saved to {target_desc}"


def memory_projects() -> str:
    if not PROJ.is_dir():
        return "No project files yet."
    lines = []
    for path in sorted(PROJ.glob("*.md")):
        first = ""
        for line in read_text(path).splitlines():
            if line.startswith("# "):
                first = line[2:].strip()
                break
        lines.append(f"{path.stem}: {first or '(no title)'}")
    return "\n".join(lines) if lines else "No project files yet."


TOOLS = [
    {
        "name": "memory_read",
        "description": "Read the shared cross-agent memory file (MEMORY.md). Use at the start of work when you need the curated hot memory.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "memory_search",
        "description": "Search the shared memory store (MEMORY.md, monthly logs, project files) for a keyword or phrase.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Keyword or phrase to find."},
                "max_results": {"type": "integer", "description": "Maximum matches to return (default 50)."},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "memory_add",
        "description": "Append a durable fact, preference, decision or handoff note to the shared cross-agent memory. Use hot=true for facts worth injecting into every future session.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "The fact to store (one or two sentences)."},
                "project": {"type": "string", "description": "Optional project name to store under projects/<name>.md instead of the monthly log."},
                "hot": {"type": "boolean", "description": "Also append to MEMORY.md hot log so every agent sees it at session start."},
                "agent": {"type": "string", "description": "Who is saving (e.g. claude, codex, glm, opencode)."},
            },
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "memory_projects",
        "description": "List the per-project memory files in the shared store.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]

DISPATCH = {
    "memory_read": lambda args: memory_read(),
    "memory_search": lambda args: memory_search(args.get("query", ""), int(args.get("max_results") or 50)),
    "memory_add": lambda args: memory_add(
        args.get("text", ""), args.get("project", ""), bool(args.get("hot")), args.get("agent", "")
    ),
    "memory_projects": lambda args: memory_projects(),
}


def send(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def reply(request_id, result=None, error=None) -> None:
    message = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        message["error"] = {"code": error[0], "message": error[1]}
    else:
        message["result"] = result if result is not None else {}
    send(message)


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
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        )
    elif method == "ping":
        reply(request_id, {})
    elif method == "tools/list":
        reply(request_id, {"tools": TOOLS})
    elif method == "tools/call":
        name = params.get("name", "")
        args = params.get("arguments") or {}
        handler = DISPATCH.get(name)
        if handler is None:
            reply(request_id, {"content": [{"type": "text", "text": f"Unknown tool: {name}"}], "isError": True})
            return
        try:
            reply(request_id, {"content": [{"type": "text", "text": handler(args)}]})
        except Exception as exc:  # noqa: BLE001 - report as tool error, keep server alive
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
    except Exception:  # noqa: BLE001 - older interpreters
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
