#!/usr/bin/env bash
# All-Agent Shared Memory - CLI for Linux / macOS / Git Bash.
# Usage: mem.sh read|add|search|sync|status|doctor|prune [-Text ...] [-Query ...] [-Project ...] [-Agent ...] [-Hot] [-Force] [-Keep N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
MEM="$ROOT/MEMORY.md"
LOGDIR="$ROOT/log"
PROJDIR="$ROOT/projects"
HOSTS="$ROOT/hosts.json"

CMD="${1:-read}"
if [ $# -gt 0 ]; then shift; fi
TEXT=""; QUERY=""; PROJECT=""; AGENT="${AI_AGENT:-agent}"; HOT=0; FORCE=0; KEEP=50
while [ $# -gt 0 ]; do
  case "$1" in
    -Text|--text) TEXT="${2:-}"; shift 2 ;;
    -Query|--query) QUERY="${2:-}"; shift 2 ;;
    -Project|--project) PROJECT="${2:-}"; shift 2 ;;
    -Agent|--agent) AGENT="${2:-}"; shift 2 ;;
    -Keep|--keep) KEEP="${2:-50}"; shift 2 ;;
    -Hot|--hot) HOT=1; shift ;;
    -Force|--force) FORCE=1; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$LOGDIR" "$PROJDIR"

SECRET_RE='(AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|(ghp_|gho_|ghs_|ghr_)[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}|(api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*[^[:space:]]{16,}|[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,})'

has_secret() { printf '%s' "$1" | grep -Eq "$SECRET_RE"; }

find_python() {
  for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; print(sys.version_info[0])' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

get_targets() {
  local py
  if [ -f "$HOSTS" ] && py="$(find_python)"; then
    "$py" - "$HOSTS" <<'PY'
import json, sys
try:
    for t in json.load(open(sys.argv[1], encoding="utf-8")).get("block_targets") or []:
        print(t)
except Exception:
    pass
PY
  else
    printf '%s\n' "$HOME/.codex/AGENTS.md" "$HOME/.zcode/workspace/default/AGENTS.md"
  fi
}

case "$CMD" in
  read)
    cat "$MEM"
    ;;

  add)
    if [ -z "$TEXT" ]; then echo 'add requires -Text "..."' >&2; exit 2; fi
    if [ "$FORCE" -eq 0 ] && has_secret "$TEXT"; then
      echo "refused: text matches a secret pattern (key/token/password). Use -Force only for false positives; never store real credentials." >&2
      exit 3
    fi
    LINE="- $(date '+%Y-%m-%d %H:%M') [$AGENT] $TEXT"
    if [ -n "$PROJECT" ]; then
      TARGET="$PROJDIR/$PROJECT.md"
      [ -f "$TARGET" ] || printf '# Project memory: %s\n' "$PROJECT" > "$TARGET"
      printf '%s\n' "$LINE" >> "$TARGET"
      echo "saved -> projects/$PROJECT.md"
    else
      TARGET="$LOGDIR/$(date '+%Y-%m').md"
      [ -f "$TARGET" ] || printf '# Memory log %s\n' "$(date '+%Y-%m')" > "$TARGET"
      printf '%s\n' "$LINE" >> "$TARGET"
      echo "saved -> log/$(date '+%Y-%m').md"
    fi
    if [ "$HOT" -eq 1 ]; then
      grep -q '^## Hot log (auto)' "$MEM" || printf '\n## Hot log (auto)\n' >> "$MEM"
      printf '%s\n' "$LINE" >> "$MEM"
      echo "also appended to MEMORY.md -> Hot log (auto)"
    fi
    ;;

  search)
    if [ -z "$QUERY" ]; then echo 'search requires -Query "..."' >&2; exit 2; fi
    SEARCHABLE=""
    for f in "$MEM" "$LOGDIR"/*.md "$PROJDIR"/*.md; do
      [ -f "$f" ] || continue
      size=$(wc -c < "$f" | tr -d ' ')
      if [ "$size" -gt 1048576 ]; then
        echo "warning: skipped oversized file $(basename "$f") ($((size / 1024)) KB)" >&2
      else
        SEARCHABLE="$SEARCHABLE $f"
      fi
    done
    if [ -z "$SEARCHABLE" ]; then echo "no matches for: $QUERY"; exit 0; fi
    # shellcheck disable=SC2086
    if ! grep -rni --include='*.md' -- "$QUERY" $SEARCHABLE 2>/dev/null | head -n 200 | sed "s|$ROOT/||"; then
      echo "no matches for: $QUERY"
    fi
    ;;

  prune)
    if ! PY="$(find_python)"; then echo "prune requires python3 (or python/py)" >&2; exit 2; fi
    "$PY" - "$MEM" "$KEEP" <<'PY'
import datetime, pathlib, sys

mem = pathlib.Path(sys.argv[1])
keep = max(1, min(int(sys.argv[2] or 50), 1000))
lines = mem.read_text(encoding="utf-8", errors="replace").splitlines()
heading = None
for index, line in enumerate(lines):
    if line.strip() == "## Hot log (auto)":
        heading = index
        break
if heading is None:
    print("No '## Hot log (auto)' section found; nothing to prune.")
    raise SystemExit(0)
head = lines[: heading + 1]
hot = [line for line in lines[heading + 1:] if line.strip()]
kept = hot[-keep:]
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = mem.with_name(mem.name + f".bak-prune-{stamp}")
backup.write_text(mem.read_text(encoding="utf-8"), encoding="utf-8")
mem.write_text("\n".join(head + kept) + "\n", encoding="utf-8")
print(f"pruned hot log: kept last {len(kept)} of {len(hot)} entries ({len(lines)} -> {len(head) + len(kept)} lines; backup: {backup.name})")
PY
    ;;

  sync)
    if ! PY="$(find_python)"; then echo "sync requires python3 (or python/py)" >&2; exit 2; fi
    "$PY" - "$ROOT" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
mem = (root / "MEMORY.md").read_text(encoding="utf-8")
hosts = root / "hosts.json"
targets = []
if hosts.exists():
    try:
        targets = json.loads(hosts.read_text(encoding="utf-8")).get("block_targets") or []
    except Exception:
        targets = []
if not targets:
    home = pathlib.Path.home()
    targets = [str(home / ".codex/AGENTS.md"), str(home / ".zcode/workspace/default/AGENTS.md")]
body = (
    "## Shared agent memory (auto-synced)\n\n"
    "This block is generated by mem.sh sync. Edit MEMORY.md, then re-run sync.\n"
    f"Full store: {root} (log/ + projects/; search via tools/mem.sh search -Query \"...\").\n"
    "Save durable facts: bash " + str(root / "tools/mem.sh") + " add -Text \"...\" -Agent codex [-Hot] [-Project name].\n"
    "Never store secrets here.\n\n"
    "--- BEGIN SHARED MEMORY CONTENT ---\n\n" + mem.rstrip() + "\n\n--- END SHARED MEMORY CONTENT ---\n"
)
block = "<!-- AI-MEMORY:BEGIN -->\n" + body.strip() + "\n<!-- AI-MEMORY:END -->"
for target in targets:
    path = pathlib.Path(target)
    path.parent.mkdir(parents=True, exist_ok=True)
    current = path.read_text(encoding="utf-8") if path.exists() else ""
    if "<!-- AI-MEMORY:BEGIN -->" in current:
        current = re.sub(r"(?s)<!-- AI-MEMORY:BEGIN -->.*?<!-- AI-MEMORY:END -->", block, current)
    else:
        current = (current.rstrip() + "\n\n" + block + "\n") if current.strip() else block + "\n"
    path.write_text(current, encoding="utf-8")
    print("synced ->", target)
PY
    ;;

  status)
    echo "root        : $ROOT"
    if [ -f "$MEM" ]; then
      echo "MEMORY.md   : $(wc -c < "$MEM" | tr -d ' ') bytes, $(wc -l < "$MEM" | tr -d ' ') lines"
    else
      echo "MEMORY.md   : missing"
    fi
    log_count=$(find "$LOGDIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    proj_count=$(find "$PROJDIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    echo "log files   : $log_count   project files: $proj_count"
    while IFS= read -r target; do
      target="$(printf '%s' "$target" | tr -d '\r')"
      if [ -f "$target" ]; then echo "block       : $target"; else echo "block       : $target (missing - run sync)"; fi
    done < <(get_targets)
    ;;

  doctor)
    FAILS=0
    check() {
      if [ "$2" = "1" ]; then echo "[PASS] $1 $3"; else FAILS=$((FAILS+1)); echo "[FAIL] $1 $3"; fi
    }
    skip() { echo "[SKIP] $1 $2"; }

    MEMOK=0; [ -f "$MEM" ] && MEMOK=1
    check "store MEMORY.md" "$MEMOK" "$MEM"
    TOOLSOK=0; { [ -f "$SCRIPT_DIR/mem.sh" ] && [ -f "$SCRIPT_DIR/mem-mcp.py" ]; } && TOOLSOK=1
    check "store tools" "$TOOLSOK" "mem.sh + mem-mcp.py"

    while IFS= read -r target; do
      target="$(printf '%s' "$target" | tr -d '\r')"
      if [ ! -f "$target" ]; then check "block $target" 0 "file missing - run sync"; continue; fi
      if ! grep -q 'AI-MEMORY:BEGIN' "$target"; then check "block $target" 0 "missing block - run sync"; continue; fi
      if [ -f "$MEM" ] && [ "$target" -ot "$MEM" ]; then check "block $target" 0 "present but stale - run sync"; else check "block $target" 1 "fresh"; fi
    done < <(get_targets)

    CS="$HOME/.claude/settings.json"
    if [ -f "$CS" ]; then
      if grep -q 'sessionstart-hook\.sh' "$CS"; then check "claude hook" 1 "$CS"; else check "claude hook" 0 "hook not found in $CS"; fi
    else skip "claude hook" "no settings.json"; fi

    OC="$HOME/.config/opencode/opencode.json"
    if [ -f "$OC" ]; then
      if grep -q 'ai_memory' "$OC"; then check "opencode wiring" 1 "$OC"; else check "opencode wiring" 0 "ai_memory not registered"; fi
    else skip "opencode wiring" "no opencode.json"; fi

    CT="$HOME/.codex/config.toml"
    if [ -f "$CT" ]; then
      if grep -q 'ai_memory' "$CT"; then check "codex mcp" 1 "$CT"; else check "codex mcp" 0 "ai_memory not registered"; fi
    else skip "codex mcp" "no config.toml"; fi

    if PY="$(find_python)"; then
      check "python for MCP" 1 "$PY"
      if "$PY" - "$SCRIPT_DIR/mem-mcp.py" <<'PY' | grep -q serverInfo
import json, subprocess, sys
p = subprocess.Popen([sys.executable, sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
out, _ = p.communicate('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"doctor","version":"0"}}}\n', timeout=10)
print(out)
PY
      then check "mcp handshake" 1 "initialize answered"; else check "mcp handshake" 0 "no serverInfo response"; fi
    else
      check "python for MCP" 0 "not found - MCP unavailable (CLI still works)"
    fi

    echo ""
    if [ "$FAILS" -gt 0 ]; then echo "doctor: $FAILS problem(s) found"; exit 1; fi
    echo "doctor: all checks passed"
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 2
    ;;
esac
