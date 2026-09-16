#!/usr/bin/env bash
# All-Agent Shared Memory - installer for Linux / macOS.
# Usage: bash tools/install.sh [store-path]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="${1:-$HOME/.agents/memory}"

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

echo "== Done"
echo "  CLI : bash $STORE/tools/mem.sh read|add|search|sync|status|doctor"
echo "  MCP : ai_memory (memory_read / memory_search / memory_add / memory_projects)"
echo "  For Gemini CLI: add '@$STORE/MEMORY.md' to ~/.gemini/GEMINI.md"
