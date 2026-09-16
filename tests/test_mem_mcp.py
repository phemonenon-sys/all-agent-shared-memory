"""Tests for tools/mem-mcp.py: handshake, memory operations, guards, prune."""
import json
import os
import pathlib
import subprocess
import sys

import pytest

TOOLS = pathlib.Path(__file__).resolve().parent.parent / "tools"
SERVER = TOOLS / "mem-mcp.py"


def rpc(store: pathlib.Path, requests):
    env = dict(os.environ, AI_MEMORY_DIR=str(store))
    payload = "\n".join(json.dumps(r) for r in requests) + "\n"
    proc = subprocess.run(
        [sys.executable, str(SERVER)], input=payload, capture_output=True, text=True, env=env, timeout=60
    )
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def call(store: pathlib.Path, name: str, arguments=None):
    responses = rpc(
        store,
        [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": arguments or {}}},
        ],
    )
    for response in responses:
        if response.get("id") == 2:
            return response["result"]["content"][0]["text"]
    raise AssertionError(f"no response for {name}: {responses}")


@pytest.fixture
def store(tmp_path):
    root = tmp_path / "memory"
    (root / "log").mkdir(parents=True)
    (root / "projects").mkdir()
    (root / "MEMORY.md").write_text("# Shared memory\n\n## Owner\n- test owner\n", encoding="utf-8")
    return root


def test_handshake(store):
    responses = rpc(
        store,
        [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}}],
    )
    info = responses[0]["result"]["serverInfo"]
    assert info["name"] == "ai-memory"
    assert info["version"].startswith("0.3")


def test_tools_list(store):
    responses = rpc(store, [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
    names = {tool["name"] for tool in responses[0]["result"]["tools"]}
    assert {"memory_read", "memory_search", "memory_add", "memory_projects", "memory_prune"} <= names


def test_add_and_hot(store):
    assert "Saved" in call(store, "memory_add", {"text": "plain fact"})
    log = next((store / "log").glob("*.md"))
    assert "plain fact" in log.read_text(encoding="utf-8")

    assert "hot log" in call(store, "memory_add", {"text": "hot fact", "hot": True})
    memory = (store / "MEMORY.md").read_text(encoding="utf-8")
    assert "hot fact" in memory and "## Hot log (auto)" in memory


def test_secret_refusal(store):
    result = call(store, "memory_add", {"text": "key sk-abcdefghijklmnopqrstuvwx1234"})
    assert result.startswith("Refused")
    assert not [p for p in (store / "log").glob("*.md")]


def test_secret_force(store):
    result = call(store, "memory_add", {"text": "not really a key sk-abcdefghijklmnopqrstuvwx1234", "force": True})
    assert "Saved" in result


def test_hot_line_warning(store):
    big = "# Shared memory\n" + "\n".join(f"- filler {i}" for i in range(160)) + "\n\n## Hot log (auto)\n"
    (store / "MEMORY.md").write_text(big, encoding="utf-8")
    result = call(store, "memory_add", {"text": "pushes over the limit", "hot": True})
    assert "warning: MEMORY.md is" in result


def test_search_skips_oversized(store):
    (store / "log" / "2026-01.md").write_text("# log\nfindme\n", encoding="utf-8")
    (store / "log" / "big.md").write_text("x" * (1024 * 1024 + 10) + "\nfindme big\n", encoding="utf-8")
    result = call(store, "memory_search", {"query": "findme"})
    assert "skipped oversized" in result
    assert "findme" in result


def test_search_truncates(store):
    (store / "log" / "2026-02.md").write_text("\n".join("needle" for _ in range(400)), encoding="utf-8")
    result = call(store, "memory_search", {"query": "needle", "max_chars": 200})
    assert "truncated at 200 chars" in result


def test_prune(store):
    hot = "# Shared memory\n\n## Hot log (auto)\n" + "\n".join(f"- entry {i}" for i in range(120)) + "\n"
    (store / "MEMORY.md").write_text(hot, encoding="utf-8")
    result = call(store, "memory_prune", {"keep": 50})
    assert "kept last 50 of 120" in result
    remaining = (store / "MEMORY.md").read_text(encoding="utf-8").splitlines()
    assert sum(1 for line in remaining if line.startswith("- entry")) == 50
    assert list(store.glob("MEMORY.md.bak-prune-*"))
