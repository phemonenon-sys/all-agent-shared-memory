# Shared agent memory - template
# Copy this to MEMORY.md in your store root and fill it in.
# Keep it short (target < 150 lines). It is injected into every agent session.

> Store: <your store path> (log\ + projects\; search: tools\mem.ps1 search -Query "...")
> Save durable facts: powershell -NoProfile -File <store>\tools\mem.ps1 add -Text "..." -Agent <name> [-Hot] [-Project <name>]
> "remember this" from the owner = save immediately (-Hot for durable facts).
> Never store secrets in memory files.

## Owner

- Who the owner is, role, language, communication style.
- How they like results: verdicts, evidence, coverage ledgers, etc.

## Machine

- OS, CPU, RAM, GPU (and its limits), installed tooling that matters.

## Agent stack

- Which agents run here (Claude Code, Codex, opencode, ZCode, Gemini CLI...).
- Where each one's config/skills live. Which MCP servers are connected.

## Conventions

- Repo/workflow conventions worth enforcing across agents.
- Where handoffs/reports should live. What never goes into memory (secrets).

## Active workstreams

- One line per project: status + pointer to projects\<name>.md.

## Pinned decisions

- Date-stamped decisions that must survive.

## Hot log (auto)
