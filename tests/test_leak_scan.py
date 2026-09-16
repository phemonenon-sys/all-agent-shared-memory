"""Tests for scripts/leak-scan.py (external denylist scanner).

The synthetic term is assembled at runtime so this file never contains the
full match itself - otherwise the repo-tree scan would flag its own tests.
"""
import base64
import os
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SCAN = REPO / "scripts" / "leak-scan.py"
TERM = "acme-" + "secret-token"


def run(args, env=None, home=None):
    merged = dict(os.environ)
    merged.pop("LEAK_TERMS_B64", None)
    if home is not None:
        merged["USERPROFILE"] = str(home)  # isolates DEFAULT_TERMS_FILE lookups
        merged["HOME"] = str(home)
    if env:
        merged.update(env)
    return subprocess.run(
        [sys.executable, str(SCAN), *args], capture_output=True, text=True, env=merged, timeout=120
    )


def test_self_test():
    result = run(["--self-test"])
    assert result.returncode == 0, result.stdout + result.stderr
    assert "self-test OK" in result.stdout


def test_repo_tree_is_clean(tmp_path):
    terms = tmp_path / "denylist.txt"
    terms.write_text(TERM + "\n", encoding="utf-8")
    result = run(["--tree"], env={"LEAK_TERMS_FILE": str(terms)})
    assert result.returncode == 0, result.stdout


def test_planted_term_fails(tmp_path):
    (tmp_path / "notes.md").write_text("# " + TERM + " experiment notes\n", encoding="utf-8")
    terms = tmp_path / "denylist.txt"
    terms.write_text(TERM + "\n", encoding="utf-8")
    result = run(["--tree", "--root", str(tmp_path)], env={"LEAK_TERMS_FILE": str(terms)})
    assert result.returncode == 1
    assert "notes.md" in result.stdout


def test_clean_dir_passes(tmp_path):
    (tmp_path / "notes.md").write_text("# shared memory design notes\n", encoding="utf-8")
    terms = tmp_path / "denylist.txt"
    terms.write_text(TERM + "\n", encoding="utf-8")
    result = run(["--tree", "--root", str(tmp_path)], env={"LEAK_TERMS_FILE": str(terms)})
    assert result.returncode == 0, result.stdout


def test_no_denylist_skips(tmp_path):
    (tmp_path / "notes.md").write_text("anything\n", encoding="utf-8")
    result = run(
        ["--tree", "--root", str(tmp_path)],
        env={"LEAK_TERMS_FILE": str(tmp_path / "missing.txt")},
        home=tmp_path,
    )
    assert result.returncode == 0
    assert "no denylist configured" in result.stdout


def test_base64_source(tmp_path):
    (tmp_path / "notes.md").write_text("token: " + TERM + "\n", encoding="utf-8")
    encoded = base64.b64encode((TERM + "\n").encode()).decode()
    result = run(["--tree", "--root", str(tmp_path)], env={"LEAK_TERMS_B64": encoded})
    assert result.returncode == 1
    assert TERM in result.stdout
