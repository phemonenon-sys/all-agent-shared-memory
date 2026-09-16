"""Tests for scripts/leak-scan.py (external denylist scanner)."""
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SCAN = REPO / "scripts" / "leak-scan.py"


def run(args, env=None, home=None):
    merged = dict(**(__import__("os").environ))
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
    terms.write_text("acme-secret-token\n", encoding="utf-8")
    result = run(["--tree"], env={"LEAK_TERMS_FILE": str(terms)})
    assert result.returncode == 0, result.stdout


def test_planted_term_fails(tmp_path):
    (tmp_path / "notes.md").write_text("# acme-secret-token experiment notes\n", encoding="utf-8")
    terms = tmp_path / "denylist.txt"
    terms.write_text("acme-secret-token\n", encoding="utf-8")
    result = run(["--tree", "--root", str(tmp_path)], env={"LEAK_TERMS_FILE": str(terms)})
    assert result.returncode == 1
    assert "notes.md" in result.stdout


def test_clean_dir_passes(tmp_path):
    (tmp_path / "notes.md").write_text("# shared memory design notes\n", encoding="utf-8")
    terms = tmp_path / "denylist.txt"
    terms.write_text("acme-secret-token\n", encoding="utf-8")
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
    import base64

    (tmp_path / "notes.md").write_text("token: acme-secret-token\n", encoding="utf-8")
    encoded = base64.b64encode(b"acme-secret-token\n").decode()
    result = run(["--tree", "--root", str(tmp_path)], env={"LEAK_TERMS_B64": encoded})
    assert result.returncode == 1
    assert "acme-secret-token" in result.stdout
