# Contributing

Thanks for looking at this repo. It is deliberately small - keep it that way.

## Ground rules

- **Zero dependencies.** PowerShell 5.1+ and Python stdlib only. No new runtime packages, no binaries, no services. Any PR that adds a dependency needs a very good reason in the description.
- **Read-only on other tools' data.** Anything that touches agent stores (claude-mem, Codex, opencode, ZCode, Task Scheduler) must not write unless it is explicitly an installer/uninstaller action, and must back up before editing.
- **Evidence over claims.** PRs that change behavior should update or add tests.

## Development

```powershell
python -m pytest -q tests                      # python: MCP server, dump tools, bridge smoke
powershell -Command "Invoke-Pester -Path tests" # mem.ps1 behaviors (Pester 5+)
```

CI runs both on Windows plus `shellcheck` on Linux. Run at least the pytest suite before opening a PR.

## Style

- Keep `mem.ps1` / `mem.sh` / `mem-mcp.py` behavior in lockstep: a new command or guard lands in all three.
- User-facing strings: plain ASCII where possible, no emojis.
- Never log or persist secrets; the secret guard patterns live in `tools/mem.ps1` and `tools/mem-mcp.py` - extend both together.

## Commit messages

Conventional-ish (`fix:`, `feat:`, `docs:`, `chore:`), one logical change per commit.

## Reporting issues

Use the issue template. For security concerns, follow [SECURITY.md](SECURITY.md) - do not open a public issue for
vulnerabilities.
