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

## Leak guard (privacy hardline)

This repository ships a denylist scanner that blocks private-project identifiers from being published:

- `scripts/leak-scan.py` scans every tracked file **and the full git history** (CI runs it with `fetch-depth: 0`, so a green run is proof the entire history is clean).
- `.githooks/pre-push` runs the same scan locally and aborts the push on findings. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

The guarded terms deliberately live **outside** the repository, so the guard never reveals what it guards:

| Source | Use |
|---|---|
| `LEAK_TERMS_B64` env | base64 of newline-separated regex terms; wired to the repo's `LEAK_TERMS_B64` Actions secret |
| `LEAK_TERMS_FILE` env | path to a terms file (useful for tests) |
| `~/.agents/leak-guard/denylist.txt` | default local list (one regex per line, `#` comments) |

Add new terms to the local list and the repo secret - never to a committed file.

## Style

- Keep `mem.ps1` / `mem.sh` / `mem-mcp.py` behavior in lockstep: a new command or guard lands in all three.
- User-facing strings: plain ASCII where possible, no emojis.
- Never log or persist secrets; the secret guard patterns live in `tools/mem.ps1` and `tools/mem-mcp.py` - extend both together.

## Commit messages

Conventional-ish (`fix:`, `feat:`, `docs:`, `chore:`), one logical change per commit.

## Reporting issues

Use the issue template. For security concerns, follow [SECURITY.md](SECURITY.md) - do not open a public issue for
vulnerabilities.
