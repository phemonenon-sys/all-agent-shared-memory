"""Tests for tools/dump/*: synthetic source databases -> dumps -> split files."""
import json
import pathlib
import py_compile
import sqlite3
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
DUMP = ROOT / "tools" / "dump"


def run(script: str, *args):
    proc = subprocess.run(
        [sys.executable, str(DUMP / script), *args], capture_output=True, text=True, timeout=120
    )
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


@pytest.fixture
def claude_mem_db(tmp_path):
    db = tmp_path / "cm.db"
    con = sqlite3.connect(str(db))
    con.executescript(
        """
        CREATE TABLE sdk_sessions(project TEXT, custom_title TEXT, user_prompt TEXT, started_at TEXT, completed_at TEXT, status TEXT);
        CREATE TABLE session_summaries(project TEXT, created_at TEXT, request TEXT, investigated TEXT, learned TEXT,
                                       completed TEXT, next_steps TEXT, notes TEXT);
        CREATE TABLE observations(project TEXT);
        """
    )
    con.execute("INSERT INTO sdk_sessions VALUES('alpha','Title A','do the thing','2026-09-01','2026-09-01','done')")
    con.execute("INSERT INTO sdk_sessions VALUES('beta','Title B','do other','2026-09-02','2026-09-02','done')")
    con.execute("INSERT INTO session_summaries VALUES('alpha','2026-09-01','req','inv','learned X','done','next Y','note')")
    con.execute("INSERT INTO session_summaries VALUES('beta','2026-09-02','req2','inv2','learned Z','done2','next2','note2')")
    con.execute("INSERT INTO observations VALUES('alpha')")
    con.commit()
    con.close()
    return db


def test_dump_claude_mem(tmp_path, claude_mem_db):
    out = tmp_path / "dump.md"
    stdout = run("dump_claude_mem.py", "--db", str(claude_mem_db), "--out", str(out))
    assert "wrote" in stdout
    text = out.read_text(encoding="utf-8")
    assert "PROJECT: alpha" in text and "learned X" in text and "alpha: 1" in text


def test_split_projects(tmp_path, claude_mem_db):
    dump = tmp_path / "dump.md"
    run("dump_claude_mem.py", "--db", str(claude_mem_db), "--out", str(dump))
    outdir = tmp_path / "split"
    run("split_projects.py", "--in", str(dump), "--outdir", str(outdir))
    assert (outdir / "alpha.md").exists()
    assert (outdir / "beta.md").exists()
    assert (outdir / "_session-list.md").exists()
    assert "learned X" in (outdir / "alpha.md").read_text(encoding="utf-8")


def test_dump_opencode(tmp_path):
    db = tmp_path / "oc.db"
    con = sqlite3.connect(str(db))
    con.executescript(
        """
        CREATE TABLE session(id TEXT, title TEXT, directory TEXT, model TEXT, time_created INTEGER, parent_id TEXT);
        CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE todo(session_id TEXT, content TEXT, status TEXT, priority TEXT, time_created INTEGER);
        """
    )
    con.execute("INSERT INTO session VALUES('ses_1','session title','C:/dev','{\"id\":\"deepseek-flash\"}',1789573487000,NULL)")
    con.execute("INSERT INTO message VALUES('msg_1','ses_1',1,'{\"role\":\"user\"}')")
    con.execute("INSERT INTO part VALUES('p1','msg_1','ses_1',1,'{\"type\":\"text\",\"text\":\"hello bridge\"}')")
    con.execute("INSERT INTO message VALUES('msg_2','ses_1',2,'{\"role\":\"assistant\"}')")
    con.execute("INSERT INTO part VALUES('p2','msg_2','ses_1',2,'{\"type\":\"text\",\"text\":\"hello back\"}')")
    con.execute("INSERT INTO todo VALUES('ses_1','finish tests','pending','high',3)")
    con.commit()
    con.close()

    out = tmp_path / "oc.md"
    stdout = run("dump_opencode.py", "--db", str(db), "--out", str(out))
    assert "wrote" in stdout
    text = out.read_text(encoding="utf-8")
    assert "session title" in text and "hello bridge" in text and "finish tests" in text


def test_all_python_tools_compile():
    for script in (ROOT / "tools").rglob("*.py"):
        py_compile.compile(str(script), doraise=True)
