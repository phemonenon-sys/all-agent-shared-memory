#!/usr/bin/env python3
r"""Dump opencode sessions (titles, first prompt, last assistant reply, todos) - read-only.

Usage:
  python dump_opencode.py --db ~/.local/share/opencode/opencode.db --out mining/opencode-dump.md
"""
import argparse
import datetime
import json
import pathlib
import sqlite3


def part_text(data: str) -> str:
    try:
        parsed = json.loads(data)
    except Exception:
        return ""
    kind = parsed.get("type")
    if kind == "text":
        return parsed.get("text") or ""
    if kind == "tool":
        return f"[tool: {parsed.get('tool')}]"
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Dump opencode sessions (read-only)")
    parser.add_argument(
        "--db", default=str(pathlib.Path.home() / ".local" / "share" / "opencode" / "opencode.db")
    )
    parser.add_argument("--out", default="opencode-dump.md")
    args = parser.parse_args()

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    lines = ["# opencode sessions\n", f"Generated: {datetime.datetime.now():%Y-%m-%d %H:%M}\n"]

    for session in cur.execute(
        "select id, title, directory, model, time_created from session order by time_created desc"
    ):
        created = datetime.datetime.fromtimestamp((session["time_created"] or 0) / 1000).strftime(
            "%Y-%m-%d %H:%M"
        )
        model = ""
        try:
            model = json.loads(session["model"] or "{}").get("id", "")
        except Exception:
            pass
        lines.append(
            f"\n\n## SESSION {session['id']} | {created} | model={model} | dir={session['directory']}"
        )
        lines.append(f"title: {session['title']}")

        messages = cur.execute(
            "select id, data from message where session_id=? order by time_created", (session["id"],)
        ).fetchall()
        first_user = ""
        last_assistant = ""
        for message in messages:
            try:
                role = json.loads(message["data"]).get("role")
            except Exception:
                continue
            parts = cur.execute(
                "select data from part where message_id=? order by time_created", (message["id"],)
            ).fetchall()
            text = " ".join(t for t in (part_text(p["data"]) for p in parts) if t).strip()
            if not text:
                continue
            if role == "user" and not first_user:
                first_user = text[:600]
            if role == "assistant":
                last_assistant = text[:900]
        if first_user:
            lines.append(f"first user: {first_user}")
        if last_assistant:
            lines.append(f"last assistant: {last_assistant}")

    lines.append("\n\n## Todos (all sessions)\n")
    for r in cur.execute(
        "select session_id, content, status, priority from todo order by time_created desc limit 200"
    ):
        lines.append(f"- [{r['status']}] ({r['priority']}) {r['content']}")

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
