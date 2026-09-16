# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private vulnerability reporting: go to the repository's **Security** tab →
**Report a vulnerability** (direct link: `https://github.com/<you>/all-agent-shared-memory/security/advisories/new`).
If that is unavailable, open a minimal issue that says only "security report - please contact me" and a maintainer will
follow up with a private channel.

Include: affected version/commit, a description, reproduction steps, and the impact you can demonstrate.

## Scope and threat model

This project deliberately has a small attack surface:

- **No network code in the runtime.** The memory tools (`mem.ps1`, `mem.sh`, `mem-mcp.py`, the hooks) never call the
  network. Only the optional history dumpers read local files; the bridge reads local agent stores read-only.
- **No dependencies.** PowerShell 5.1+ and Python stdlib only. There is no package supply chain to compromise.
- **Plain-text stores.** Memory files are Markdown by design; treat the store directory like any sensitive notes
  folder. The write path refuses credential-shaped text, but no scanner is perfect - never paste secrets into memory.
- **Scheduled tasks** run local commands as your user; review `sched.py` task wrappers before enabling them.

Reports we care about most: injection through memory content into an agent session, path traversal in
install/uninstall scripts, the secret guard being bypassable with trivially different formatting, or any way a
*read* operation can mutate an agent store.

## Supported versions

Only the latest tagged release is supported with security fixes.
