#!/usr/bin/env python3
r"""sched - schedule agent work with Windows Task Scheduler.

Templates:
  agent=claude   -> claude -p "<prompt>"
  agent=codex    -> codex exec "<prompt>"
  agent=opencode -> rejected: the desktop app ships no headless CLI on PATH;
                    pass a custom --command instead if you have one wired.

Tasks live in ~/.agents/scheduler/tasks/<name>.cmd and log to
~/.agents/scheduler/logs/<name>.log. Read-only listing, no remote services.

CLI:
  python sched.py add --name nightly --time 03:00 --agent claude --prompt "summarize open work"
  python sched.py add --name once --time 14:30 --date 2026-09-17 --command "echo hello"
  python sched.py list
  python sched.py remove --name nightly
"""
import argparse
import pathlib
import platform
import re
import shutil
import subprocess
import sys

BASE = pathlib.Path.home() / ".agents" / "scheduler"
TASKS = BASE / "tasks"
LOGS = BASE / "logs"
PREFIX = "AgentScheduler"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,48}$")
TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

WINDOWS_ONLY_MESSAGE = (
    "Scheduling is Windows-only (Windows Task Scheduler / schtasks). "
    "On Linux/macOS use cron or systemd timers; the sessions_* bridge tools work on every OS."
)


def _require_windows() -> None:
    if platform.system() != "Windows":
        raise RuntimeError(WINDOWS_ONLY_MESSAGE)


def _find_codex() -> str:
    exe = shutil.which("codex")
    if exe:
        return exe
    candidates = list((pathlib.Path.home() / ".codex").rglob("codex.exe"))
    return str(candidates[0]) if candidates else "codex"


def build_command(agent: str, prompt: str, command: str) -> str:
    if command:
        return command
    if agent == "claude":
        return f'claude -p "{prompt}"'
    if agent == "codex":
        return f'"{_find_codex()}" exec "{prompt}"'
    if agent == "opencode":
        raise ValueError(
            "opencode desktop ships no headless CLI on PATH. Use agent=claude/codex or pass --command."
        )
    raise ValueError(f"unknown agent: {agent}")


def add(name: str, command: str, time_str: str, daily: bool, date: str) -> str:
    _require_windows()
    if not NAME_RE.match(name):
        raise ValueError("name must be alphanumeric/dot/dash, max 49 chars")
    if not TIME_RE.match(time_str):
        raise ValueError("time must be HH:MM (24h)")
    if not daily and not DATE_RE.match(date or ""):
        raise ValueError("one-shot tasks need --date YYYY-MM-DD")
    TASKS.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)

    wrapper = TASKS / f"{name}.cmd"
    log = LOGS / f"{name}.log"
    wrapper.write_text(
        "@echo off\r\n"
        f'echo [%date% %time%] start {name} >> "{log}"\r\n'
        f"{command} >> \"{log}\" 2>&1\r\n"
        f'echo [%date% %time%] done (exit %errorlevel%) >> "{log}"\r\n',
        encoding="utf-8",
    )

    args = ["schtasks", "/Create", "/F", "/TN", f"{PREFIX}\\{name}", "/TR", f'cmd /c "{wrapper}"']
    if daily:
        args += ["/SC", "DAILY", "/ST", time_str]
    else:
        year, month, day = date.split("-")
        args += ["/SC", "ONCE", "/ST", time_str, "/SD", f"{month}/{day}/{year}"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "schtasks failed").strip())
    return f"scheduled '{name}' -> {time_str}{' daily' if daily else ' once on ' + date}"


def remove(name: str) -> str:
    _require_windows()
    if not NAME_RE.match(name):
        raise ValueError("bad task name")
    subprocess.run(["schtasks", "/Delete", "/F", "/TN", f"{PREFIX}\\{name}"], capture_output=True, text=True)
    wrapper = TASKS / f"{name}.cmd"
    if wrapper.exists():
        wrapper.unlink()
    return f"removed '{name}'"


def list_tasks() -> str:
    if platform.system() != "Windows":
        return WINDOWS_ONLY_MESSAGE
    lines = []
    if TASKS.exists():
        for wrapper in sorted(TASKS.glob("*.cmd")):
            name = wrapper.stem
            query = subprocess.run(
                ["schtasks", "/Query", "/TN", f"{PREFIX}\\{name}", "/FO", "LIST"],
                capture_output=True,
                text=True,
            )
            status = "registered"
            next_run = ""
            for row in query.stdout.splitlines():
                row = row.strip()
                if row.lower().startswith("next run time"):
                    next_run = row.split(":", 1)[-1].strip()
                if row.lower().startswith("status"):
                    status = row.split(":", 1)[-1].strip()
            content = wrapper.read_text(encoding="utf-8", errors="replace").splitlines()
            command = content[2] if len(content) > 2 else ""
            lines.append(f"{name:24s} {status:10s} next={next_run or '-':20s} cmd={command[:90]}")
    if not lines:
        return "no scheduled tasks"
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Schedule agent work (Windows Task Scheduler)")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    p_add = sub.add_parser("add")
    p_add.add_argument("--name", required=True)
    p_add.add_argument("--time", required=True)
    p_add.add_argument("--date", default="")
    p_add.add_argument("--daily", action="store_true")
    p_add.add_argument("--agent", choices=["claude", "codex", "opencode"], default="")
    p_add.add_argument("--prompt", default="")
    p_add.add_argument("--command", default="")

    sub.add_parser("list")

    p_remove = sub.add_parser("remove")
    p_remove.add_argument("--name", required=True)

    args = parser.parse_args()
    try:
        if args.subcommand == "add":
            cmd = build_command(args.agent, args.prompt.replace('"', "'"), args.command)
            print(add(args.name, cmd, args.time, args.daily, args.date))
        elif args.subcommand == "list":
            print(list_tasks())
        elif args.subcommand == "remove":
            print(remove(args.name))
    except (ValueError, RuntimeError) as exc:
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
        print(f"error: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
