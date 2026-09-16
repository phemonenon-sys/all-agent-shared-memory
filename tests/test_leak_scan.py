"""Tests for the hardline guard (scripts/leak-scan.py).

The guard loads its denylist from outside the repo (LEAK_TERMS_B64,
LEAK_TERMS_FILE, or ~/.agents/leak-guard/denylist.txt), so tests inject a
SYNTHETIC terms file - no real guarded terms appear in test sources.
"""
import os
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SCAN = REPO / "scripts" / "leak-scan.py"
CANARY = "zz-planted-canary-77"


def run_scan(*args, cwd=REPO, terms_file=None):
    env = dict(os.environ)
    env.pop("LEAK_TERMS_B64", None)
    if terms_file is None:
        env.pop("LEAK_TERMS_FILE", None)
    else:
        env["LEAK_TERMS_FILE"] = str(terms_file)
    return subprocess.run(
        [sys.executable, str(SCAN), *args],
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
    )


def _init_repo(path: pathlib.Path):
    for cmd in (
        ["git", "init", "-b", "main"],
        ["git", "config", "user.email", "test@localhost"],
        ["git", "config", "user.name", "test"],
    ):
        subprocess.run(cmd, cwd=path, check=True, capture_output=True)
    (path / "terms.txt").write_text(CANARY + "\n", encoding="utf-8")
    return path / "terms.txt"


def test_self_test_passes():
    result = run_scan("--self-test")
    assert result.returncode == 0, result.stdout


def test_repo_tree_and_history_are_clean():
    # No terms configured here on purpose: with the synthetic canary absent
    # from the repo, any configured denylist must still report clean.
    result = run_scan("--tree", "--history")
    assert result.returncode == 0, result.stdout


def test_planted_term_blocks(tmp_path):
    terms = _init_repo(tmp_path)
    (tmp_path / "notes.md").write_text(f"# design notes about {CANARY}\n", encoding="utf-8")
    subprocess.run(["git", "add", "notes.md"], cwd=tmp_path, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "wip"], cwd=tmp_path, check=True, capture_output=True)
    result = run_scan("--tree", "--history", cwd=tmp_path, terms_file=terms)
    assert result.returncode == 1
    assert "notes.md" in result.stdout


def test_clean_tree_passes(tmp_path):
    terms = _init_repo(tmp_path)
    (tmp_path / "notes.md").write_text("# shared memory design notes\n", encoding="utf-8")
    subprocess.run(["git", "add", "notes.md"], cwd=tmp_path, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "wip"], cwd=tmp_path, check=True, capture_output=True)
    result = run_scan("--tree", "--history", cwd=tmp_path, terms_file=terms)
    assert result.returncode == 0, result.stdout


def test_no_terms_configured_skips_cleanly(tmp_path, monkeypatch):
    monkeypatch.delenv("LEAK_TERMS_B64", raising=False)
    monkeypatch.delenv("LEAK_TERMS_FILE", raising=False)
    (tmp_path / "notes.md").write_text("anything\n", encoding="utf-8")
    env = dict(os.environ)
    env.pop("LEAK_TERMS_B64", None)
    env.pop("LEAK_TERMS_FILE", None)
    # Point HOME at an empty dir so no default denylist is found.
    empty_home = tmp_path / "emptyhome"
    empty_home.mkdir()
    env["HOME"] = str(empty_home)
    env["USERPROFILE"] = str(empty_home)
    result = subprocess.run(
        [sys.executable, str(SCAN), "--tree", "--root", str(tmp_path)],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0
    assert "no denylist configured" in result.stdout
