#!/usr/bin/env bash
# All-Agent Shared Memory - installer for Linux / macOS.
# Usage: bash tools/install.sh [store-path] [--with-bridge]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_BRIDGE=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --with-bridge) WITH_BRIDGE=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
STORE="${ARGS[0]:-$HOME/.agents/memory}"

echo "== Installing All-Agent Shared Memory"
echo "  store : $STORE"
echo "  source: $REPO"

mkdir -p "$STORE" "$STORE/log" "$STORE/projects" "$STORE/tools"
cp "$REPO/tools/mem.sh" "$STORE/tools/mem.sh"
cp "$REPO/tools/sessionstart-hook.sh" "$STORE/tools/sessionstart-hook.sh"
cp "$REPO/tools/mem-mcp.py" "$STORE/tools/mem-mcp.py"
chmod +x "$STORE/tools/mem.sh" "$STORE/tools/sessionstart-hook.sh"
echo "  copied tools"

if [ ! -f "$STORE/MEMORY.md" ]; then
  cp "$REPO/examples/MEMORY.template.md" "$STORE/MEMORY.md"
  echo "  seeded MEMORY.md from template"
else
  echo "  MEMORY.md exists - left untouched"
fi

if [ ! -f "$STORE/hosts.json" ]; then
  cat > "$STORE/hosts.json" <<JSON
{
  "block_targets": [
    "$HOME/.codex/AGENTS.md",
    "$HOME/.zcode/workspace/default/AGENTS.md"
  ]
}
JSON
  echo "  wrote hosts.json"
fi

if command -v python3 >/dev/null 2>&1; then
  CS="$HOME/.claude/settings.json"
  if [ -f "$CS" ]; then
    python3 - "$CS" "$STORE/tools/sessionstart-hook.sh" <<'PY'
import json, pathlib, shutil, sys

settings = pathlib.Path(sys.argv[1])
hook = sys.argv[2]
data = json.loads(settings.read_text(encoding="utf-8"))
hooks = data.setdefault("hooks", {})
entries = hooks.setdefault("SessionStart", [])
if "sessionstart-hook.sh" in json.dumps(entries):
    print("  claude hook already present - skipped")
else:
    entries.append({"hooks": [{"type": "command", "command": f"bash {hook}", "timeout": 15}]})
    shutil.copy2(settings, str(settings) + ".bak-asm")
    settings.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print("  claude hook added (backup: settings.json.bak-asm)")
PY
  else
    echo "  no ~/.claude/settings.json - skipping Claude hook"
  fi

  CT="$HOME/.codex/config.toml"
  if [ -f "$CT" ]; then
    if grep -q 'ai_memory' "$CT"; then
      echo "  codex config already references ai_memory - skipped"
    else
      cp "$CT" "$CT.bak-asm"
      {
        echo ""
        echo "[mcp_servers.ai_memory]"
        echo "command = '$(command -v python3)'"
        echo "args = ['$STORE/tools/mem-mcp.py']"
        echo "startup_timeout_sec = 30"
      } >> "$CT"
      echo "  appended [mcp_servers.ai_memory] (backup: config.toml.bak-asm)"
    fi
  fi

  OC="$HOME/.config/opencode/opencode.json"
  if [ -f "$OC" ]; then
    python3 - "$OC" "$STORE/MEMORY.md" "$STORE/tools/mem-mcp.py" <<'PY'
import json, pathlib, shutil, sys

path = pathlib.Path(sys.argv[1])
mem, server = sys.argv[2], sys.argv[3]
data = json.loads(path.read_text(encoding="utf-8"))
if "ai_memory" in json.dumps(data):
    print("  opencode config already references ai_memory - skipped")
else:
    instructions = data.get("instructions") or []
    if mem not in instructions:
        instructions.append(mem)
    data["instructions"] = instructions
    data.setdefault("mcp", {})["ai_memory"] = {
        "type": "local",
        "command": [sys.executable, server],
        "enabled": True,
    }
    shutil.copy2(path, str(path) + ".bak-asm")
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print("  opencode instructions + ai_memory added (backup: opencode.json.bak-asm)")
PY
  fi
else
  echo "  python3 not found - skipped MCP/claude wiring (install Python 3.10+ and re-run, or wire manually)"
fi

echo "== Sync AGENTS.md blocks"
bash "$STORE/tools/mem.sh" sync || true

echo "== Bridge (optional)"
if [ "$WITH_BRIDGE" -eq 1 ]; then
  BRIDGE="$(dirname "$STORE")/agent-bridge"
  mkdir -p "$BRIDGE"
  cp "$REPO/tools/bridge/bridge.py" "$REPO/tools/bridge/bridge-mcp.py" "$REPO/tools/bridge/sched.py" "$REPO/tools/bridge/README.md" "$BRIDGE/"
  echo "  deployed -> $BRIDGE"
  PY="$(command -v python3 || command -v python || true)"
  OC="$HOME/.config/opencode/opencode.json"
  if [ -f "$OC" ] && [ -n "$PY" ]; then
    "$PY" - "$OC" "$BRIDGE/bridge-mcp.py" <<'PY'
import json, pathlib, shutil, sys
path = pathlib.Path(sys.argv[1]); server = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
if "agent_bridge" in json.dumps(data):
    print("  opencode: already registered - skipped")
else:
    data.setdefault("mcp", {})["agent_bridge"] = {"type": "local", "command": [sys.executable, server], "enabled": True}
    shutil.copy2(path, str(path) + ".bak-asm")
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print("  opencode: registered mcp.agent_bridge")
PY
  fi
  CT="$HOME/.codex/config.toml"
  if [ -f "$CT" ] && [ -n "$PY" ]; then
    if grep -q 'agent_bridge' "$CT"; then
      echo "  codex: already registered - skipped"
    else
      cp "$CT" "$CT.bak-asm"
      printf '\n[mcp_servers.agent_bridge]\ncommand = %s\nargs = [%s]\nstartup_timeout_sec = 30\n' "'$PY'" "'$BRIDGE/bridge-mcp.py'" >> "$CT"
      echo "  codex: appended [mcp_servers.agent_bridge]"
    fi
  fi
  if command -v claude >/dev/null 2>&1 && [ -n "$PY" ]; then
    claude mcp add -s user agent_bridge "$PY" "$BRIDGE/bridge-mcp.py" >/dev/null 2>&1 && echo "  claude: agent_bridge registered (user scope)" || echo "  claude: registration failed - add manually"
  fi
else
  echo "  skipped (pass --with-bridge to deploy agent-bridge and register agent_bridge)"
fi

echo "== Gemini (optional)"
if [ -d "$HOME/.gemini" ]; then
  if grep -q 'agents/memory' "$HOME/.gemini/GEMINI.md" 2>/dev/null; then
    echo "  already wired - skipped"
  else
    printf '\n@%s\n' "$STORE/MEMORY.md" >> "$HOME/.gemini/GEMINI.md"
    echo "  added @-import to ~/.gemini/GEMINI.md"
  fi
else
  echo "  no ~/.gemini - skipped (add '@$STORE/MEMORY.md' if you install Gemini CLI)"
fi

echo "== Done"
echo "  CLI : bash $STORE/tools/mem.sh read|add|search|sync|status|doctor|prune"
echo "  MCP : ai_memory (memory_read / memory_search / memory_add / memory_projects / memory_prune)"
if [ "$WITH_BRIDGE" -eq 1 ]; then
  echo "  Bridge CLI : python $(dirname "$STORE")/agent-bridge/bridge.py list"
  echo "  Bridge MCP : agent_bridge (sessions_* + schedule_*)"
fi
