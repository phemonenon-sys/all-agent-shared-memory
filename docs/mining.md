# Mining your agent history into project memory

The point of this playbook: an agent that has never seen your chats should be able to **continue a project cold**, without a handoff document. That is different from searching old transcripts - it is distillation into curated state.

The method was proven on real machines before this repo existed: ~800 session summaries, ~90 rollout summaries, thousands of observations and 60+ app sessions collapsed into 11 project files.

## Sources: where agent history actually lives

| Agent | Distilled source (best signal) | Raw source (last resort) |
|---|---|---|
| Claude Code | claude-mem SQLite: `session_summaries` + `observations` (`~/.claude-mem/claude-mem.db`) | `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/memories/rollout_summaries/*.md` + `memory_summary.md` | `~/.codex/sessions/**/*.jsonl` |
| opencode | `opencode.db` (`session`, `message`, `part`, `todo` tables) | same DB |
| ZCode | `~/.zcode/cli/memories/**/memory/*.md` + workspace reports | `~/.zcode/cli/rollout/*.jsonl` |

Always mine the distilled layer first; raw transcripts are 50-100x the volume for little extra signal.

## Step 1 - dump to text (read-only)

```bash
python tools/dump/dump_claude_mem.py --db ~/.claude-mem/claude-mem.db --out mining/claude-mem-dump.md
python tools/dump/dump_opencode.py   --db ~/.local/share/opencode/opencode.db --out mining/opencode-dump.md
python tools/dump/split_projects.py  --in mining/claude-mem-dump.md --outdir mining/claude-mem
```

Codex and ZCode are already Markdown - just point agents at the folders. All dump scripts open SQLite read-only and never write outside `--out`.

## Step 2 - extraction wave (one agent per source)

Give each agent one source slice and this prompt template:

> Read <source files> fully (chunk large files with offset/limit). Extract durable, decision-grade facts. Output one Markdown extract with a section per project:
> `### State` (dated bullets, newest first, literal verdicts, hashes, counts) / `### Key paths` / `### Rules & gates` / `### Open threads / next steps` / `### Traps & lessons` / `### Evidence pointers`.
> Only facts present in the source. No invention. Keep exact dates and numbers. Mark quarantine flags. Unclear items are marked `unclear:` - never guessed. Write only your output file.

## Step 3 - merge wave (one agent per project)

Give each agent the relevant extracts plus the project-file template (see `examples/PROJECT.template.md`) and require:

- `Status` line: one literal sentence (what works, what is blocked, what is next).
- `Start here:` pointer: the freshest handoff/report plus this file.
- Conflicts between sources stay **both dated** - never silently reconciled.
- `Open threads` items must be actionable alone: what, where, why, next gate.
- Cap ~250 lines; state beats biography.

## Step 4 - wire it in

Reference every project file from `MEMORY.md` so each agent sees the index at session start. `mem sync` refreshes embedded copies.

## Hard-won rules

- One agent per output file. Parallel writers on the same file produce incoherent merges.
- Project buckets in history stores are messy: cwd shorthands (`re`, `b`, `i-g`), hash names, and buckets whose label lies (a bucket named after a folder may contain a different project). Classify by content, not by label.
- The freshest handoff document on disk beats any extract - say so in the file.
- Numbers with retraction history keep their retraction marker in the project file.
- Keep a coverage ledger in your final report: fully read / sampled / deliberately skipped + why.
