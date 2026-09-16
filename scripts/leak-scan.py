#!/usr/bin/env python3
r"""leak-scan - block private-project content from reaching public repos.

Scans the working tree (or a plain directory) and the git history of local
branches, tags and HEAD (not remote-tracking refs, which reflect what is
already public rather than what is being pushed) for terms configured
OUTSIDE this repository:

  1. env LEAK_TERMS_B64   base64 of newline-separated regex terms (for CI secrets)
  2. env LEAK_TERMS_FILE  path to a terms file (one regex per line, # comments)
  3. ~/.agents/leak-guard/denylist.txt   default local list

Keeping the terms out of the repo means the guard itself never reveals what it guards.

Usage:
  python scripts/leak-scan.py                    # tree + history
  python scripts/leak-scan.py --tree
  python scripts/leak-scan.py --history
  python scripts/leak-scan.py --root PATH        # scan any directory (no git needed for --tree)
  python scripts/leak-scan.py --self-test
Exit codes: 0 clean/skip, 1 findings, 2 configuration error.
"""
import argparse
import base64
import os
import pathlib
import re
import subprocess
import sys

SELF_NAME = "leak-scan.py"
DEFAULT_TERMS_FILE = pathlib.Path.home() / ".agents" / "leak-guard" / "denylist.txt"
SKIP_DIRS = {".git", "__pycache__", ".venv", "node_modules"}
SKIP_SUFFIXES = {".png", ".gif", ".jpg", ".jpeg", ".ico", ".zip", ".exe", ".dll", ".pyc", ".woff", ".woff2"}


def load_patterns():
    """Return (patterns, source_paths) or (None, None) on configuration error."""
    sources = []
    source_paths = set()
    raw_b64 = os.environ.get("LEAK_TERMS_B64", "").strip()
    if raw_b64:
        try:
            sources.append(("LEAK_TERMS_B64", base64.b64decode(raw_b64).decode("utf-8", errors="replace")))
        except Exception as exc:  # noqa: BLE001
            print(f"leak-scan: cannot decode LEAK_TERMS_B64: {exc}", file=sys.stderr)
            return None, None
    env_file = os.environ.get("LEAK_TERMS_FILE", "").strip()
    if env_file and pathlib.Path(env_file).exists():
        resolved = pathlib.Path(env_file).resolve()
        source_paths.add(resolved)
        sources.append((env_file, resolved.read_text(encoding="utf-8", errors="replace")))
    if not sources and DEFAULT_TERMS_FILE.exists():
        resolved = DEFAULT_TERMS_FILE.resolve()
        source_paths.add(resolved)
        sources.append((str(resolved), resolved.read_text(encoding="utf-8", errors="replace")))

    patterns = []
    for label, text in sources:
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                patterns.append((line, re.compile(line, re.IGNORECASE)))
            except re.error as exc:
                print(f"leak-scan: bad regex in {label}: {line!r} ({exc})", file=sys.stderr)
                return None, None
    return patterns, source_paths


def scan_text(text: str, label: str, patterns):
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        for raw, compiled in patterns:
            if compiled.search(line):
                hits.append((label, number, line.strip()[:180]))
                break
    return hits


def git_root(start: pathlib.Path):
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, cwd=start
    )
    if out.returncode != 0:
        return None
    return pathlib.Path(out.stdout.strip())


def scan_tree(root: pathlib.Path, patterns, skip_paths=frozenset()):
    repo = git_root(root)
    if repo:
        listing = subprocess.run(["git", "ls-files"], capture_output=True, text=True, cwd=root).stdout.splitlines()
        files = [root / rel for rel in listing]
    else:
        files = [
            path
            for path in sorted(root.rglob("*"))
            if path.is_file()
            and not any(part in SKIP_DIRS for part in path.parts)
            and path.suffix.lower() not in SKIP_SUFFIXES
        ]
    hits = []
    for path in files:
        if path.name == SELF_NAME:
            continue  # the scanner never contains the guarded terms
        try:
            if path.resolve() in skip_paths:
                continue  # the configured denylist itself
        except OSError:
            pass
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if b"\x00" in data[:8192]:
            continue
        rel = str(path.relative_to(root)) if root in path.parents or path.is_relative_to(root) else str(path)
        hits += scan_text(data.decode("utf-8", errors="replace"), rel, patterns)
    return hits


def scan_history(root: pathlib.Path, patterns):
    """Scan local branches + tags + HEAD. Remote-tracking refs are ignored:
    they reflect what is already public, not what is being pushed."""
    repo = git_root(root)
    if not repo:
        return []
    proc = subprocess.Popen(
        ["git", "log", "-p", "--branches", "--tags", "HEAD", "--format=%x1e%h %s"],
        cwd=root,
        stdout=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    hits = []
    commit = "?"
    current_file = ""
    for line in proc.stdout:
        if line.startswith("\x1e"):
            commit = line[1:].strip()
            continue
        if line.startswith("+++ b/"):
            current_file = line[6:].strip()
            continue
        if current_file.endswith(SELF_NAME) or line.startswith(("---", "diff ")):
            continue
        for raw, compiled in patterns:
            if compiled.search(line):
                hits.append((f"{commit} :: {current_file or '?'}", None, line.strip()[:180]))
                break
    proc.wait()
    seen, unique = set(), []
    for hit in hits:
        if hit not in seen:
            seen.add(hit)
            unique.append(hit)
    return unique


def self_test() -> bool:
    synthetic = ["acme-secret-token", r"project\s*nightjar"]
    compiled = [(raw, re.compile(raw, re.IGNORECASE)) for raw in synthetic]
    positive = scan_text("notes: acme-secret-token leaked\nProject Nightjar overview", "sample.md", compiled)
    negative = scan_text("project milestone shipped on schedule", "clean.md", compiled)
    ok = len(positive) == 2 and not negative
    print("self-test OK" if ok else "self-test FAILED")
    return ok


def report(hits, source: str) -> int:
    if not hits:
        print(f"leak-scan [{source}]: clean")
        return 0
    print(f"leak-scan [{source}]: {len(hits)} finding(s) - guarded content detected:")
    for label, number, text in hits[:60]:
        where = f"{label}:{number}" if number else label
        print(f"  {where}: {text}")
    if len(hits) > 60:
        print(f"  ... and {len(hits) - 60} more")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Denylist scanner for public repositories")
    parser.add_argument("--tree", action="store_true")
    parser.add_argument("--history", action="store_true")
    parser.add_argument("--root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

    if not self_test() if args.self_test else False:
        return 1
    if args.self_test and not args.tree and not args.history:
        return 0

    patterns, skip_paths = load_patterns()
    if patterns is None:
        return 2
    if not patterns:
        print(
            "leak-scan: no denylist configured - scanning skipped.\n"
            f"  set LEAK_TERMS_B64 (CI secret), LEAK_TERMS_FILE, or create {DEFAULT_TERMS_FILE}"
        )
        return 0

    root = pathlib.Path(args.root).resolve()
    failures = 0
    if args.tree:
        failures += report(scan_tree(root, patterns, skip_paths), "tree")
    if args.history:
        failures += report(scan_history(root, patterns), "history")
    if failures:
        print("")
        print("Blocked: guarded private-project terms found. Do not publish this content.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
