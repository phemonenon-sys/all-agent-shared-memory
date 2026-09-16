#!/usr/bin/env python3
r"""Build assets/demo.gif from real command output (no manual screen recording).

Runs the actual CLI against the local store, captures stdout, sanitizes paths,
and renders a terminal-style animated GIF with Pillow.

Usage:
  python scripts/build-demo-gif.py [--out assets/demo.gif]
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HOME = pathlib.Path.home()
MEM = HOME / ".agents" / "memory" / "tools" / "mem.ps1"
BRIDGE_DIR = HOME / ".agents" / "agent-bridge"

WIDTH, HEIGHT = 880, 820
PAD = 20
LINE_H = 23
FONT_SIZE = 15
BG = (13, 17, 23)
CHROME = (22, 27, 34)
FG = (214, 222, 235)
DIM = (138, 148, 158)
GREEN = (126, 231, 135)
BLUE = (121, 192, 255)
YELLOW = (230, 200, 120)

TYPE_MS = 45
OUTPUT_MS = 850
CHARS_PER_FRAME = 2

PROMPT = "PS C:\\> "


def run(cmd, cwd=None):
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, timeout=180)
    return (result.stdout + result.stderr).replace("\r\n", "\n").strip("\n")


def sanitize(text: str) -> str:
    text = text.replace(str(HOME), r"C:\Users\you")
    text = re.sub(r"asm-[a-z0-9-]+", "asm-demo", text)
    return text


def collect_scenes():
    scenes = []

    def cmd(text):
        scenes.append({"type": "cmd", "text": text})

    def out(text, color=FG):
        for line in sanitize(text).splitlines():
            scenes.append({"type": "out", "text": line, "color": color})

    bridge_out = run([sys.executable, "bridge.py", "agents"], cwd=str(BRIDGE_DIR))
    mem_pwsh = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(MEM)]

    cmd("cd ~\\.agents\\agent-bridge")
    cmd("python bridge.py agents")
    out(bridge_out, BLUE)
    cmd("cd ~\\.agents\\memory\\tools")
    cmd('.\\mem.ps1 add -Text "demo entry from the GIF build" -Hot')
    out(run(mem_pwsh + ["add", "-Text", "demo entry from the GIF build", "-Hot"]), YELLOW)
    cmd('.\\mem.ps1 search -Query "demo entry"')
    out(run(mem_pwsh + ["search", "-Query", "demo entry"]))
    cmd(".\\mem.ps1 doctor")
    out(run(mem_pwsh + ["doctor"]), GREEN)
    return scenes


def load_fonts():
    regular = ImageFont.truetype(r"C:\Windows\Fonts\consola.ttf", FONT_SIZE)
    bold = ImageFont.truetype(r"C:\Windows\Fonts\consolab.ttf", FONT_SIZE)
    chrome = ImageFont.truetype(r"C:\Windows\Fonts\consola.ttf", 13)
    return regular, bold, chrome


def render_frame(lines, cursor_on, fonts):
    regular, bold, chrome = fonts
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, WIDTH, 34], fill=CHROME)
    for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        draw.ellipse([14 + i * 22, 12, 24 + i * 22, 22], fill=color)
    draw.text((88, 10), "all-agent-shared-memory - demo", font=chrome, fill=DIM)

    y = 48
    for entry in lines:
        if entry["type"] == "cmd":
            draw.text((PAD, y), PROMPT, font=bold, fill=GREEN)
            draw.text((PAD + draw.textlength(PROMPT, font=bold), y), entry["text"], font=regular, fill=FG)
        else:
            draw.text((PAD, y), entry["text"], font=regular, fill=entry.get("color", FG))
        y += LINE_H
    if cursor_on:
        draw.rectangle([PAD, y + 3, PAD + 9, y + 18], fill=(90, 200, 120))
    return img


def build(out_path: pathlib.Path):
    scenes = collect_scenes()
    fonts = load_fonts()
    frames, durations = [], []
    lines = []
    pending_output = []

    def flush_output():
        nonlocal pending_output
        if pending_output:
            lines.extend(pending_output)
            frames.append(render_frame(lines, True, fonts))
            durations.append(OUTPUT_MS)
            pending_output = []

    for scene in scenes:
        if scene["type"] == "cmd":
            flush_output()
            prefix = {"type": "cmd", "text": ""}
            lines.append(prefix)
            text = scene["text"]
            for i in range(0, len(text), CHARS_PER_FRAME):
                prefix["text"] = text[: i + CHARS_PER_FRAME]
                frames.append(render_frame(lines, True, fonts))
                durations.append(TYPE_MS)
        else:
            pending_output.append(scene)
    flush_output()

    frames.append(render_frame(lines, True, fonts)); durations.append(1600)
    frames.append(render_frame(lines, False, fonts)); durations.append(500)
    frames.append(render_frame(lines, True, fonts)); durations.append(2500)

    # normalize to a shared palette to keep the GIF small
    palette_source = frames[-1].convert("P", palette=Image.ADAPTIVE, colors=64)
    quantized = [frame.quantize(palette=palette_source, dither=Image.NONE) for frame in frames]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    quantized[0].save(
        out_path,
        save_all=True,
        append_images=quantized[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )
    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"wrote {out_path} ({size_mb:.2f} MB, {len(frames)} frames)")
    return size_mb


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(pathlib.Path(__file__).resolve().parent.parent / "assets" / "demo.gif"))
    args = parser.parse_args()
    build(pathlib.Path(args.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
