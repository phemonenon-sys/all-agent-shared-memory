#!/usr/bin/env python3
"""Split a claude-mem dump into one file per project bucket (for the extraction wave).

Usage:
  python split_projects.py --in mining/claude-mem-dump.md --outdir mining/claude-mem
"""
import argparse
import pathlib
import re


def main() -> int:
    parser = argparse.ArgumentParser(description="Split a claude-mem dump by project")
    parser.add_argument("--in", dest="source", required=True)
    parser.add_argument("--outdir", required=True)
    args = parser.parse_args()

    raw = pathlib.Path(args.source).read_text(encoding="utf-8")
    parts = raw.split("## Summaries by project", 1)
    header = parts[0]
    body = parts[1] if len(parts) > 1 else ""
    body = body.split("## Observation counts by project", 1)[0]

    outdir = pathlib.Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "_session-list.md").write_text(header, encoding="utf-8")

    written = []
    for part in re.split(r"(?m)^### PROJECT: ", body)[1:]:
        name = part.splitlines()[0].strip()
        slug = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_") or "unknown"
        path = outdir / f"{slug}.md"
        with path.open("a", encoding="utf-8") as handle:
            handle.write(f"# PROJECT: {name}\n" + part + "\n")
        written.append((slug, len(part)))

    for slug, size in sorted(written, key=lambda item: -item[1]):
        print(f"{slug:50s} {size / 1024:8.1f} KB")
    print(f"\ntotal project files: {len(written)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
