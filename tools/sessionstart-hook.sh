#!/usr/bin/env bash
# Claude Code SessionStart hook (Linux / macOS): prints the shared memory as additional context.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEM="$ROOT/MEMORY.md"
CLI="$ROOT/tools/mem.sh"

if [ ! -f "$MEM" ]; then
  exit 0
fi

PY=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; print(sys.version_info[0])' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "sessionstart-hook.sh requires python3 (or python/py) for JSON encoding" >&2
  exit 0
fi

"$PY" - "$MEM" "$CLI" <<'PY'
import json, pathlib, sys

mem_path, cli = sys.argv[1], sys.argv[2]
content = pathlib.Path(mem_path).read_text(encoding="utf-8")
context = (
    f"[Shared agent memory auto-loaded from {mem_path}]\n\n"
    "How to maintain it:\n"
    f"- Save durable facts: bash {cli} add -Text \"...\" -Agent claude [-Hot] [-Project name]\n"
    f"- Search deeper history: bash {cli} search -Query \"...\"\n"
    "- Raw session history stays in each host's own store; this file is the curated cross-agent layer.\n"
    "- Never store secrets in memory files.\n\n"
    "--- BEGIN SHARED MEMORY ---\n\n" + content + "\n\n--- END SHARED MEMORY ---\n"
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}))
PY
exit 0
