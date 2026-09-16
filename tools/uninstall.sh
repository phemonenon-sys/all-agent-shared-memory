#!/usr/bin/env bash
# All-Agent Shared Memory - uninstaller for Linux / macOS.
# Usage: bash tools/uninstall.sh [store-path] [--remove-store] [--with-bridge]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOVE_STORE=0
WITH_BRIDGE=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --remove-store) REMOVE_STORE=1 ;;
    --with-bridge) WITH_BRIDGE=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
STORE="${ARGS[0]:-$HOME/.agents/memory}"
STAMP="$(date +%Y%m%d-%H%M%S)"

PY=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; print(sys.version_info[0])' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

echo "== Uninstalling All-Agent Shared Memory wiring"
echo "  store: $STORE"

if [ -z "$PY" ]; then
  echo "  python3 not found - cannot edit JSON/TOML safely; aborting (remove wiring manually)"
  exit 2
fi

echo "== 1/7 Claude Code"
CS="$HOME/.claude/settings.json"
if [ -f "$CS" ] && grep -q 'sessionstart-hook' "$CS"; then
  cp "$CS" "$CS.bak-uninstall-$STAMP"
  "$PY" - "$CS" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
hooks = data.get("hooks") or {}
entries = hooks.get("SessionStart") or []
kept_groups = []
for group in entries:
    handlers = [h for h in group.get("hooks", []) if "sessionstart-hook" not in (h.get("command") or "")]
    if handlers:
        group["hooks"] = handlers
        kept_groups.append(group)
if kept_groups:
    hooks["SessionStart"] = kept_groups
else:
    hooks.pop("SessionStart", None)
if not hooks:
    data.pop("hooks", None)
path.write_text(json.dumps(data, indent=2), encoding="utf-8")
print("  removed shared-memory SessionStart hook")
PY
  echo "  note: claude CLI MCP (agent_bridge) removal: claude mcp remove agent_bridge -s user"
else
  echo "  no shared-memory hook found - skipped"
fi

echo "== 2/7 opencode"
OC="$HOME/.config/opencode/opencode.json"
if [ -f "$OC" ] && grep -qE 'ai_memory|agent_bridge' "$OC"; then
  cp "$OC" "$OC.bak-uninstall-$STAMP"
  "$PY" - "$OC" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
for name in ("ai_memory", "agent_bridge"):
    (data.get("mcp") or {}).pop(name, None)
if data.get("instructions"):
    data["instructions"] = [i for i in data["instructions"] if i and "agents/memory" not in i.replace("\\", "/")]
path.write_text(json.dumps(data, indent=2), encoding="utf-8")
print("  removed memory/bridge MCP entries + instructions entry")
PY
else
  echo "  nothing registered - skipped"
fi

echo "== 3/7 Codex"
CT="$HOME/.codex/config.toml"
if [ -f "$CT" ] && grep -qE '\[mcp_servers\.(ai_memory|agent_bridge)\]' "$CT"; then
  cp "$CT" "$CT.bak-uninstall-$STAMP"
  "$PY" - "$CT" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
out, skipping = [], False
for line in path.read_text(encoding="utf-8").splitlines():
    if line.strip() in ("[mcp_servers.ai_memory]", "[mcp_servers.agent_bridge]"):
        skipping = True
        continue
    if skipping and line.startswith("["):
        skipping = False
    if not skipping:
        out.append(line)
path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
print("  removed ai_memory/agent_bridge sections")
PY
else
  echo "  nothing registered - skipped"
fi

echo "== 4/7 AGENTS.md blocks"
"$PY" - "$STORE" "$HOME" <<'PY'
import json, pathlib, re, sys
store, home = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
targets = [home / ".codex/AGENTS.md", home / ".zcode/workspace/default/AGENTS.md"]
hosts = store / "hosts.json"
if hosts.exists():
    try:
        targets = [pathlib.Path(t) for t in json.loads(hosts.read_text(encoding="utf-8")).get("block_targets") or []]
    except Exception:
        pass
for target in targets:
    if not target.exists():
        print(f"  {target} - not present")
        continue
    content = target.read_text(encoding="utf-8", errors="replace")
    if "AI-MEMORY:BEGIN" not in content:
        print(f"  {target} - no block found")
        continue
    new = re.sub(r"(?s)\n*<!-- AI-MEMORY:BEGIN -->.*?<!-- AI-MEMORY:END -->\n?", "\n", content)
    target.write_text(new, encoding="utf-8")
    print(f"  removed block from {target}")
PY

echo "== 5/7 agent-bridge"
BRIDGE="$(dirname "$STORE")/agent-bridge"
if [ -d "$BRIDGE" ]; then
  rm -rf "$BRIDGE"
  echo "  deleted $BRIDGE"
  echo "  note: scheduler is Windows-only; check 'crontab -l' for any agent jobs you created"
else
  echo "  bridge not deployed - skipped"
fi

echo "== 6/7 Gemini"
GF="$HOME/.gemini/GEMINI.md"
if [ -f "$GF" ] && grep -qE 'agents/memory' "$GF"; then
  cp "$GF" "$GF.bak-uninstall-$STAMP"
  "$PY" - "$GF" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
new = re.sub(r"(?m)^@.*agents/memory[^\n]*\n?", "", content)
path.write_text(new.rstrip() + "\n", encoding="utf-8")
print("  removed import line")
PY
else
  echo "  no import line - skipped"
fi

echo "== 7/7 Store"
if [ "$REMOVE_STORE" -eq 1 ] && [ -f "$STORE/MEMORY.md" ]; then
  rm -rf "$STORE"
  echo "  deleted $STORE"
else
  echo "  kept $STORE (pass --remove-store to delete it)"
fi

echo "== Done"
echo "  *.bak-uninstall-$STAMP backups kept for rollback"
