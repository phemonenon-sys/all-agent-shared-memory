#!/usr/bin/env python3
r"""Dump claude-mem's distilled session summaries to a Markdown file (read-only).

Usage:
  python dump_claude_mem.py --db ~/.claude-mem/claude-mem.db --out mining/claude-mem-dump.md
"""
import argparse
import datetime
import pathlib
import sqlite3


def main() -> int:
    parser = argparse.ArgumentParser(description="Dump claude-mem summaries (read-only)")
    parser.add_argument("--db", default=str(pathlib.Path.home() / ".claude-mem" / "claude-mem.db"))
    parser.add_argument("--out", default="claude-mem-dump.md")
    args = parser.parse_args()

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    lines = ["# claude-mem session summaries\n", f"Generated: {datetime.datetime.now():%Y-%m-%d %H:%M}\n"]

    lines.append("\n## Sessions\n")
    for r in cur.execute(
        "select project, custom_title, user_prompt, started_at, completed_at, status "
        "from sdk_sessions order by started_at"
    ):
        title = (r["custom_title"] or "").strip() or (r["user_prompt"] or "").strip()[:120]
        lines.append(f"- {r['started_at']} | {r['status']} | {r['project']} | {title}")

    lines.append("\n\n## Summaries by project\n")
    current = None
    for r in cur.execute(
        """select project, created_at, request, investigated, learned, completed, next_steps, notes
           from session_summaries order by project, created_at"""
    ):
        project = r["project"] or "(none)"
        if project != current:
            current = project
            lines.append(f"\n\n### PROJECT: {project}\n")
        lines.append(f"\n--- {r['created_at']} ---")
        for field in ("request", "investigated", "learned", "completed", "next_steps", "notes"):
            value = r[field]
            if value and str(value).strip():
                lines.append(f"[{field}] {str(value).strip()}")

    lines.append("\n\n## Observation counts by project\n")
    for r in cur.execute("select project, count(*) c from observations group by project order by c desc"):
        lines.append(f"- {r['project']}: {r['c']}")

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
