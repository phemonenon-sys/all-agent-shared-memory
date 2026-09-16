#!/usr/bin/env python3
r"""agent-bridge - read every agent's chats from any agent (read-only).

Unified session layer across Claude Code, Codex, opencode and ZCode:
list sessions, read transcripts, search across all of them.

Commands:
  python bridge.py agents
  python bridge.py list  [--agent claude|codex|opencode|zcode] [--limit 20]
  python bridge.py read  --agent A --session S [--tail 40] [--max-chars 20000]
  python bridge.py search --query "..." [--agent A] [--limit 30]

stdlib only. Never writes to any agent store.
"""
import argparse
import datetime
import glob
import json
import os
import pathlib
import re
import sqlite3
import sys

HOME = pathlib.Path.home()
OPENCODE_DB = HOME / ".local" / "share" / "opencode" / "opencode.db"
AGENTS = ("claude", "codex", "opencode", "zcode")


def _mtime(path: str) -> float:
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def codex_files(limit: int = 40):
    files = glob.glob(str(HOME / ".codex" / "sessions" / "**" / "rollout-*.jsonl"), recursive=True)
    files += glob.glob(str(HOME / ".codex" / "archived_sessions" / "rollout-*.jsonl"))
    files.sort(key=_mtime, reverse=True)
    return files[: limit * 3]


def claude_files(limit: int = 40):
    files = glob.glob(str(HOME / ".claude" / "projects" / "*" / "*.jsonl"))
    files.sort(key=_mtime, reverse=True)
    return files[: limit * 3]


def zcode_files(limit: int = 40):
    files = glob.glob(str(HOME / ".zcode" / "cli" / "agents" / "sess_*" / "agent_*" / "transcript.jsonl"))
    files.sort(key=_mtime, reverse=True)
    return files[: limit * 3]


def deep_text(obj, out, depth=0):
    """Collect likely text strings from an unknown JSON shape."""
    if depth > 6 or len(out) > 200:
        return
    if isinstance(obj, str):
        if len(obj) > 1:
            out.append(obj)
    elif isinstance(obj, list):
        for item in obj:
            deep_text(item, out, depth + 1)
    elif isinstance(obj, dict):
        for key in ("text", "content", "delta", "output_text", "message", "input", "output"):
            if key in obj:
                value = obj[key]
                if isinstance(value, str):
                    out.append(value)
                else:
                    deep_text(value, out, depth + 1)


def clip(text: str, n: int = 400) -> str:
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text[:n]


def looks_system(text: str) -> bool:
    head = re.sub(r"\s+", " ", text.strip())[:140].lower()
    return (
        head.startswith("<")
        or head.startswith("# [")
        or "agents.md instructions" in head
        or "environment_context" in head
        or "recommended_plugins" in head
        or "system-reminder" in head
    )


# ---------------------------------------------------------------- adapters

def opencode_sessions(limit: int):
    if not OPENCODE_DB.exists():
        return []
    con = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT id, title, directory, time_created FROM session ORDER BY time_created DESC LIMIT ?",
        (limit,),
    ).fetchall()
    con.close()
    out = []
    for row in rows:
        ts = datetime.datetime.fromtimestamp((row["time_created"] or 0) / 1000).strftime("%Y-%m-%d %H:%M")
        out.append({"agent": "opencode", "id": row["id"], "when": ts, "title": clip(row["title"] or "", 100),
                    "extra": clip(row["directory"] or "", 80)})
    return out


def opencode_read(session_id: str, tail: int, max_chars: int) -> str:
    con = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    messages = con.execute(
        "SELECT id, data, time_created FROM message WHERE session_id=? ORDER BY time_created", (session_id,)
    ).fetchall()
    lines = []
    for message in messages:
        try:
            role = json.loads(message["data"]).get("role", "?")
        except Exception:
            role = "?"
        parts = con.execute(
            "SELECT data FROM part WHERE message_id=? ORDER BY time_created", (message["id"],)
        ).fetchall()
        texts = []
        for part in parts:
            try:
                parsed = json.loads(part["data"])
            except Exception:
                continue
            if parsed.get("type") == "text":
                texts.append(parsed.get("text") or "")
            elif parsed.get("type") == "tool":
                texts.append(f"[tool: {parsed.get('tool')}]")
        text = "\n".join(t for t in texts if t).strip()
        if text:
            lines.append(f"[{role}] {text}")
    con.close()
    return _apply_tail(lines, tail, max_chars)


def codex_parse(path: str):
    session_id, cwd, title, lines, first_user = pathlib.Path(path).stem, "", "", [], ""
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            kind = item.get("type")
            payload = item.get("payload") or {}
            if kind == "session_meta":
                session_id = payload.get("session_id") or session_id
                cwd = payload.get("cwd") or cwd
            elif kind == "response_item" and payload.get("type") == "message":
                role = payload.get("role", "?")
                parts = []
                for chunk in payload.get("content") or []:
                    if isinstance(chunk, dict):
                        parts.append(chunk.get("text") or "")
                text = "\n".join(p for p in parts if p).strip()
                if text:
                    lines.append(f"[{role}] {text}")
                    if role == "user" and not first_user and not looks_system(text):
                        first_user = text
            elif kind == "response_item" and payload.get("type") == "function_call":
                lines.append(f"[tool] {payload.get('name', '?')}")
    title = clip(first_user, 100)
    return session_id, cwd, title, lines


def codex_sessions(limit: int):
    out = []
    for path in codex_files(limit):
        session_id, cwd, title, lines = codex_parse(path)
        if not lines:
            continue
        ts = datetime.datetime.fromtimestamp(_mtime(path)).strftime("%Y-%m-%d %H:%M")
        out.append({"agent": "codex", "id": session_id, "when": ts, "title": title, "extra": clip(cwd, 80),
                    "path": path})
        if len(out) >= limit:
            break
    return out


def codex_read(session_id: str, tail: int, max_chars: int) -> str:
    for path in codex_files(200):
        if session_id in pathlib.Path(path).stem:
            _, _, _, lines = codex_parse(path)
            return _apply_tail(lines, tail, max_chars)
    return f"codex session not found: {session_id}"


def claude_parse(path: str):
    session_id = pathlib.Path(path).stem
    title, lines, first_user, cwd = "", [], "", ""
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            kind = item.get("type")
            cwd = item.get("cwd") or cwd
            if kind == "custom-title":
                title = item.get("customTitle") or title
            elif kind in ("user", "assistant"):
                message = item.get("message") or {}
                content = message.get("content")
                parts = []
                if isinstance(content, str):
                    parts.append(content)
                elif isinstance(content, list):
                    for chunk in content:
                        if not isinstance(chunk, dict):
                            continue
                        if chunk.get("type") == "text":
                            parts.append(chunk.get("text") or "")
                        elif chunk.get("type") == "tool_use":
                            parts.append(f"[tool: {chunk.get('name', '?')}]")
                text = "\n".join(p for p in parts if p).strip()
                if text:
                    lines.append(f"[{kind}] {text}")
                    if kind == "user" and not first_user and not text.startswith("[tool") and not looks_system(text):
                        first_user = text
    if not title:
        title = clip(first_user, 100)
    return session_id, title, lines, cwd


def claude_project(path: str) -> str:
    parent = pathlib.Path(path).parent.name
    if parent.startswith("C--"):
        return parent.replace("--", ":\\", 1).replace("-", " ", 1).replace("-", os.sep)
    return parent


def claude_sessions(limit: int):
    out = []
    for path in claude_files(limit):
        session_id, title, lines, cwd = claude_parse(path)
        if not lines:
            continue
        ts = datetime.datetime.fromtimestamp(_mtime(path)).strftime("%Y-%m-%d %H:%M")
        out.append({"agent": "claude", "id": session_id, "when": ts, "title": title,
                    "extra": cwd or claude_project(path), "path": path})
        if len(out) >= limit:
            break
    return out


def claude_read(session_id: str, tail: int, max_chars: int) -> str:
    for path in claude_files(200):
        if session_id in pathlib.Path(path).stem:
            _, _, lines, _ = claude_parse(path)
            return _apply_tail(lines, tail, max_chars)
    return f"claude session not found: {session_id}"


def zcode_parse(path: str):
    session_id = pathlib.Path(path).parent.parent.name
    title, lines, first_user = "", [], ""
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            kind = item.get("type")
            payload = item.get("payload") or {}
            if kind == "turn_started":
                text = payload.get("input") or ""
                text = text if isinstance(text, str) else " ".join(deep_text(text, []))
                if text.strip():
                    lines.append(f"[user] {clip(text, 4000)}")
                    if not first_user:
                        first_user = text
            elif kind == "model_complete":
                collected = []
                deep_text(payload, collected)
                text = "\n".join(dict.fromkeys(c for c in collected if len(c) > 2)).strip()
                if text:
                    lines.append(f"[assistant] {text[:8000]}")
            elif kind == "tool_call_scheduled":
                name = payload.get("toolName") or payload.get("name") or payload.get("tool")
                if name:
                    lines.append(f"[tool: {name}]")
    title = clip(first_user, 100)
    return session_id, title, lines


def zcode_sessions(limit: int):
    out = []
    for path in zcode_files(limit):
        session_id, title, lines = zcode_parse(path)
        if not lines:
            continue
        ts = datetime.datetime.fromtimestamp(_mtime(path)).strftime("%Y-%m-%d %H:%M")
        out.append({"agent": "zcode", "id": session_id, "when": ts, "title": title, "extra": "", "path": path})
        if len(out) >= limit:
            break
    return out


def _apply_tail(lines, tail: int, max_chars: int) -> str:
    if tail and tail > 0:
        lines = lines[-tail:]
    text = "\n\n".join(lines)
    if max_chars and len(text) > max_chars:
        text = text[:max_chars] + f"\n\n... [truncated at {max_chars} chars]"
    return text


# ---------------------------------------------------------------- commands

def cmd_agents():
    print("agents available for cross-reading:\n")
    counts = {
        "claude": len(claude_sessions(500)),
        "codex": len(codex_sessions(500)),
        "opencode": len(opencode_sessions(500)),
        "zcode": len(zcode_sessions(500)),
    }
    for agent in AGENTS:
        print(f"  {agent:10s} {counts[agent]:4d} sessions readable")


def cmd_list(agent, limit):
    sessions = []
    if agent in (None, "claude"):
        sessions += claude_sessions(limit)
    if agent in (None, "codex"):
        sessions += codex_sessions(limit)
    if agent in (None, "opencode"):
        sessions += opencode_sessions(limit)
    if agent in (None, "zcode"):
        sessions += zcode_sessions(limit)
    sessions.sort(key=lambda s: s["when"], reverse=True)
    for s in sessions[:limit]:
        print(f"{s['agent']:9s} {s['when']}  {s['id'][:44]:44s}  {s['title'][:70]}")
        if s.get("extra"):
            print(f"{'':9s} {'':16s}  {'':44s}  @ {s['extra']}")
    print(f"\n{len(sessions[:limit])} sessions")


def cmd_read(agent, session, tail, max_chars):
    if agent == "claude":
        text = claude_read(session, tail, max_chars)
    elif agent == "codex":
        text = codex_read(session, tail, max_chars)
    elif agent == "opencode":
        text = opencode_read(session, tail, max_chars)
    elif agent == "zcode":
        found = [p for p in zcode_files(500) if session in p]
        text = _apply_tail(zcode_parse(found[0])[2], tail, max_chars) if found else f"zcode session not found: {session}"
    else:
        text = f"unknown agent: {agent}"
    print(text)


def cmd_search(query, agent, limit):
    hits = 0
    needle = query.lower()
    if agent in (None, "opencode") and OPENCODE_DB.exists():
        con = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        rows = con.execute(
            "SELECT p.data, s.title, m.session_id FROM part p JOIN message m ON p.message_id=m.id "
            "JOIN session s ON s.id=m.session_id WHERE p.data LIKE ? LIMIT ?",
            (f"%{needle}%", limit),
        ).fetchall()
        for row in rows:
            try:
                parsed = json.loads(row["data"])
            except Exception:
                continue
            text = parsed.get("text") if parsed.get("type") == "text" else None
            if text and needle in text.lower():
                idx = text.lower().find(needle)
                print(f"opencode  {row['session_id'][:40]:40s}  ...{clip(text[max(0, idx - 60): idx + 160], 200)}")
                hits += 1
        con.close()
    if agent in (None, "claude"):
        for path in claude_files(120):
            session_id, _, lines, _ = claude_parse(path)
            for line in lines:
                if needle in line.lower():
                    idx = line.lower().find(needle)
                    print(f"claude    {session_id[:40]:40s}  ...{clip(line[max(0, idx - 60): idx + 160], 200)}")
                    hits += 1
                    break
            if hits >= limit:
                break
    if agent in (None, "codex"):
        for path in codex_files(120):
            session_id, _, _, lines = codex_parse(path)
            for line in lines:
                if needle in line.lower():
                    idx = line.lower().find(needle)
                    print(f"codex     {session_id[:40]:40s}  ...{clip(line[max(0, idx - 60): idx + 160], 200)}")
                    hits += 1
                    break
            if hits >= limit:
                break
    if agent in (None, "zcode"):
        for path in zcode_files(120):
            session_id, _, lines = zcode_parse(path)
            for line in lines:
                if needle in line.lower():
                    idx = line.lower().find(needle)
                    print(f"zcode     {session_id[:40]:40s}  ...{clip(line[max(0, idx - 60): idx + 160], 200)}")
                    hits += 1
                    break
            if hits >= limit:
                break
    print(f"\n{hits} hit(s)")


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    parser = argparse.ArgumentParser(description="Cross-agent session reader (read-only)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("agents")

    p_list = sub.add_parser("list")
    p_list.add_argument("--agent", choices=AGENTS)
    p_list.add_argument("--limit", type=int, default=15)

    p_read = sub.add_parser("read")
    p_read.add_argument("--agent", choices=AGENTS, required=True)
    p_read.add_argument("--session", required=True)
    p_read.add_argument("--tail", type=int, default=60)
    p_read.add_argument("--max-chars", type=int, default=30000)

    p_search = sub.add_parser("search")
    p_search.add_argument("--query", required=True)
    p_search.add_argument("--agent", choices=AGENTS)
    p_search.add_argument("--limit", type=int, default=20)

    args = parser.parse_args()
    if args.command == "agents":
        cmd_agents()
    elif args.command == "list":
        cmd_list(args.agent, args.limit)
    elif args.command == "read":
        cmd_read(args.agent, args.session, args.tail, args.max_chars)
    elif args.command == "search":
        cmd_search(args.query, args.agent, args.limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
