"""Smoke tests for tools/bridge: transcript helpers and scheduling templates."""
import pathlib
import platform
import sys

import pytest

BRIDGE = pathlib.Path(__file__).resolve().parent.parent / "tools" / "bridge"
sys.path.insert(0, str(BRIDGE))

import bridge  # noqa: E402
import sched  # noqa: E402


def test_looks_system_filters_harness_noise():
    assert bridge.looks_system("<recommended_plugins> list of plugins")
    assert bridge.looks_system("# AGENTS.md instructions <INSTRUCTIONS>")
    assert bridge.looks_system("<environment_context>\n cwd=...")
    assert not bridge.looks_system("this is our thinking developing chat")


def test_apply_tail_and_truncation():
    lines = [f"[user] line {i}" for i in range(10)]
    out = bridge._apply_tail(lines, tail=3, max_chars=10000)
    assert out.count("[user]") == 3
    assert "line 9" in out and "line 7" in out and "line 6" not in out

    long_out = bridge._apply_tail(lines, tail=0, max_chars=40)
    assert "truncated at 40 chars" in long_out


def test_secret_free_title_clip():
    assert len(bridge.clip("a" * 500, 100)) == 100


def test_sched_templates():
    assert sched.build_command("claude", "do work", "") == 'claude -p "do work"'
    codex_cmd = sched.build_command("codex", "do work", "")
    assert codex_cmd.endswith('exec "do work"')
    assert sched.build_command("", "", "echo hi") == "echo hi"
    with pytest.raises(ValueError):
        sched.build_command("opencode", "do work", "")


@pytest.mark.skipif(platform.system() != "Windows", reason="scheduler is Windows-only")
def test_sched_add_validation():
    with pytest.raises(ValueError):
        sched.add("bad name!", "echo hi", "23:59", False, "2026-01-01")
    with pytest.raises(ValueError):
        sched.add("ok", "echo hi", "25:00", True, "")


@pytest.mark.skipif(platform.system() != "Windows", reason="scheduler is Windows-only")
def test_sched_rejects_bad_dates():
    with pytest.raises(ValueError):
        sched.add("ok", "echo hi", "23:59", False, "01/02/2026")
