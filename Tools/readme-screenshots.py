#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Prepare README specimens; render only with --render --binary.

This is documentation artwork made from real terminal input, not a snapshot
test runner. Outputs stay in a staging directory until a person reviews them.
The showcase owns the escape, image, bar, and Tek address encoders used here.

--demo-home DIR writes the demo HOME the remote screenshots run in, and
--check-status TRACE_LOG EXPECTED checks a capture's tab marks against the
marks its shot expects, from the app's UBIQUITTY_TAB_ACCESSORY_TRACE=1 log.
"""

import argparse
import colorsys
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tomllib

from showcase import tui as T
from showcase.sections.boxdraw import _bar
from showcase.sections.compat import TEK_ENTER, _tek_vectors
import readme_demo_home


ROOT = Path(__file__).resolve().parent.parent
with (ROOT / "Source/Core/Themes/builtin-themes.toml").open("rb") as source:
    NOIR = next(theme for theme in tomllib.load(source)["themes"] if theme["name"] == "Noir")


def rgb(hex_color):
    return tuple(bytes.fromhex(hex_color.removeprefix("#")))


INK = rgb(NOIR["fg"])
BLUE = rgb(NOIR["ansi"][4])
GREEN = rgb(NOIR["ansi"][2])
AMBER = rgb(NOIR["ansi"][3])
VIOLET = rgb(NOIR["ansi"][5])
MUTED = rgb(NOIR["ansi"][8])


def text(row, column, value, color=INK, style=""):
    return T.move(row, column) + T.fg_truecolor(*color) + style + value + T.RESET


def start(title, subtitle):
    return (T.RESET + T.CLEAR + T.HIDE_CURSOR
            + text(2, 4, title, BLUE, T.BOLD)
            + text(3, 4, subtitle, MUTED))


def panel(row, column, width, height, title, color=BLUE):
    result = text(row, column, "╭" + "─" * (width - 2) + "╮", color)
    for offset in range(1, height - 1):
        result += text(row + offset, column, "│" + " " * (width - 2) + "│", color)
    result += text(row + height - 1, column, "╰" + "─" * (width - 2) + "╯", color)
    return result + text(row, column + 2, " " + title + " ", color, T.BOLD)


def hero():
    result = start("Ubiquitty", "One terminal session, wherever the work runs.")
    result += T.move(5, 4)
    for column in range(88):
        rgb = colorsys.hsv_to_rgb(column / 104, 0.65, 0.9)
        result += T.bg_truecolor(*(round(channel * 255) for channel in rgb)) + " "
    result += T.RESET + text(7, 4, "256-color palette", AMBER)
    for red in range(6):
        result += T.move(9 + red, 4)
        for green in range(6):
            for blue in range(6):
                result += T.sgr(48, 5, 16 + 36 * red + 6 * green + blue) + " "
    result += T.RESET + T.move(16, 4)
    result += "".join(T.sgr(48, 5, color) + " " for color in range(232, 256))
    result += T.RESET + T.move(18, 4)
    result += "".join(T.sgr(48, 5, color) + "  " for color in range(16))
    result += T.RESET + text(7, 49, "Code, shaped locally", AMBER)
    code = [
        ("struct Viewport {", VIOLET),
        ("    int rows = 24;", INK),
        ("    int columns = 80;", INK),
        ("};", VIOLET),
        ("", INK),
        ("auto changed = before != after;", BLUE),
        ("if (ready && changed) {", VIOLET),
        ("    surface->draw(frame);", GREEN),
        ("}", VIOLET),
        ("// -> => != == <= >= && ||", MUTED),
    ]
    for row, (line, color) in enumerate(code, 9):
        result += text(row, 49, line, color)
    result += panel(21, 4, 88, 5, "A native text surface")
    result += text(23, 7, "Box drawing  ┼ ╬ ┣     Ligatures  -> != =>     Unicode  λ → ∑", INK)
    result += text(24, 7, "Emoji  👨‍👩‍👧‍👦  👋🏽  🇬🇧  🏳️‍🌈", INK)
    result += T.move(28, 4) + T.bg_truecolor(*BLUE) + T.fg_truecolor(26, 27, 38) + " main "
    result += T.bg_truecolor(42, 46, 66) + T.fg_truecolor(*BLUE) + "\ue0b0"
    result += T.fg_truecolor(*INK) + "  src/terminal.cpp  "
    result += T.RESET + T.fg_truecolor(42, 46, 66) + "\ue0b0" + T.RESET
    return result


def tektronix():
    # Leave Tek mode active: this is the storage tube, not a VT text overlay.
    result = TEK_ENTER + T.ESC + "\x0c"
    front = [(430, 1770), (1430, 1770), (1430, 2570), (430, 2570)]
    back = [(x + 320, y + 250) for x, y in front]
    result += _tek_vectors(front + front[:1]) + _tek_vectors(back + back[:1])
    for a, b in zip(front, back):
        result += _tek_vectors([a, b])
    # Reserve room for the mesh and text in Tek's 4,096-primitive display list.
    circle_steps = 80
    for latitude in range(-60, 61, 20):
        angle = math.radians(latitude)
        points = [(round(2940 + 690 * math.cos(angle) * math.cos(t / circle_steps * math.tau)),
                   round(2270 + 560 * math.sin(angle) + 150 * math.cos(angle) * math.sin(t / circle_steps * math.tau)))
                  for t in range(circle_steps + 1)]
        result += _tek_vectors(points)
    for longitude in range(0, 180, 20):
        angle = math.radians(longitude)
        result += _tek_vectors([
            (round(2940 + 690 * math.cos(t / circle_steps * math.tau) * math.cos(angle)),
             round(2270 + 560 * math.sin(t / circle_steps * math.tau)))
            for t in range(circle_steps + 1)])

    def mesh_point(x, y):
        height = math.sin(x * 2.4) * math.cos(y * 2.4)
        return round(2050 + 510 * (x - y)), round(770 + 160 * (x + y) + 190 * height)

    for axis in range(2):
        for index in range(21):
            fixed = -1.5 + index * 0.15
            result += _tek_vectors([
                mesh_point(fixed, -1.5 + step * 0.05) if axis == 0
                else mesh_point(-1.5 + step * 0.05, fixed)
                for step in range(61)])
    # A pen-up graph move followed by US positions Tek's own alpha text.
    # Keep the labels on the tube, not in a VT overlay or an image editor.
    for x, y, label in ((430, 3000, "Tektronix 4014"),
                        (430, 1540, "Wireframe cube"),
                        (2300, 1540, "Latitude / longitude"),
                        (1100, 70, "z = sin(2.4x) cos(2.4y)")):
        result += _tek_vectors([(x, y)]) + "\x1f" + T.ESC + "8" + label
    return result + T.ESC + "\x0c"


def inline_image():
    width, height = 560, 300
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            c = complex(-2.9 + x / (width - 1) * 4.4,
                        (y / (height - 1) - 0.5) * 4.4 * height / width)
            z = 0j
            for iteration in range(128):
                z = z * z + c
                if abs(z) > 2:
                    break
            if iteration == 127:
                rgb = (0.055, 0.065, 0.11)
            else:
                rgb = colorsys.hsv_to_rgb((0.61 + iteration * 0.021) % 1, 0.72, 0.95)
            pixels.extend(round(channel * 255) for channel in rgb)
            pixels.append(255)
    return (start("Inline raster graphics", "560 × 300 pixels, sent as Kitty RGBA")
            + T.move(6, 7) + T.image_kitty(width, height, pixels, columns=70)
            + text(26, 7, "RGBA pixels. Explicit placement. Native compositing.", MUTED))


def dashboard():
    result = start("System monitor", "Deterministic sample data; real terminal glyphs and colors.")
    result += panel(5, 4, 43, 12, "CPU", BLUE)
    for index, load in enumerate((0.83, 0.56, 0.32, 0.71, 0.24, 0.48, 0.65, 0.17)):
        result += text(7 + index, 6, f"cpu {index}  ", MUTED)
        result += text(7 + index, 14, _bar(load, 24), GREEN)
        result += text(7 + index, 40, f"{round(load * 100):2}%", AMBER)
    for top, name, color, phase in ((5, "Memory", VIOLET, 0), (12, "Network", BLUE, 1.4)):
        result += panel(top, 50, 43, 6, name, color)
        cells = [[0] * 37 for _ in range(3)]
        dots = ((1, 8), (2, 16), (4, 32), (64, 128))
        previous = round(5.5 + 4.5 * math.sin(phase))
        for x in range(74):
            y = round(5.5 + 4.5 * math.sin(x * 0.11 + phase))
            for point in range(min(previous, y), max(previous, y) + 1):
                cells[point // 4][x // 2] |= dots[point % 4][x % 2]
            previous = y
        for row, points in enumerate(cells):
            graph = "".join(chr(0x2800 + value) for value in points)
            result += text(top + 1 + row, 53, graph, color)
    result += panel(19, 4, 89, 9, "Processes", BLUE)
    result += text(21, 7, " PID   COMMAND                         CPU      MEMORY", MUTED)
    for row, line in enumerate(("1204   editor                           8.2%     164 MiB",
                                "1308   language-server                  3.7%     211 MiB",
                                "1412   build                            1.5%      87 MiB",
                                "1427   shell                            0.1%       9 MiB"), 23):
        result += text(row, 7, line)
    return result


def shell_integration():
    result = start("Shell integration", "Prompt, command, output, exit status: OSC 133.")
    commands = [
        ("pwd", ["/work/terminal"], 0),
        ("git status --short", [" M readme.md", "?? Tools/readme-screenshots.py"], 0),
        ("cat missing.txt", ["cat: missing.txt: No such file or directory"], 1),
    ]
    row = 6
    for command, output, status in commands:
        result += T.move(row, 4) + T.OSC + "133;A" + T.ST
        result += T.fg_truecolor(*GREEN) + "dev@work ~/terminal % " + T.RESET
        result += T.OSC + "133;B" + T.ST + command
        result += T.OSC + "133;C" + T.ST + "\r\n"
        result += "\r\n".join("   " + line for line in output) + "\r\n"
        result += T.OSC + f"133;D;{status}" + T.ST
        row += len(output) + 4
    return result + text(21, 4, "The failed command's gutter mark carries its exit status.", MUTED)


def unicode():
    result = start("Unicode, joined at the cell edges", "Borders, blocks, braille, and styled underlines.")
    boxes = [("┌─┐│└┘", "Light"), ("┏━┓┃┗┛", "Heavy"), ("╔═╗║╚╝", "Double")]
    for index, (glyphs, label) in enumerate(boxes):
        column = 4 + index * 27
        result += text(6, column, glyphs[0] + glyphs[1] * 20 + glyphs[2], BLUE)
        result += text(7, column, glyphs[3] + f" {label:<19}" + glyphs[3], BLUE)
        result += text(8, column, glyphs[4] + glyphs[1] * 20 + glyphs[5], BLUE)
    result += text(11, 4, "Blocks    ░▒▓█   ▁▂▃▄▅▆▇█   ▏▎▍▌▋▊▉█", GREEN)
    result += text(13, 4, "Sextants  " + "".join(chr(0x1FB00 + n) for n in range(20)), AMBER)
    result += text(15, 4, "Octants   " + "".join(chr(0x1CD00 + n) for n in range(20)), AMBER)
    result += text(17, 4, "Braille   ⠁⠃⠇⡇⣇⣧⣷⣿   ⣀⣤⣶⣿⣶⣤⣀", VIOLET)
    for column, style, label in ((4, 1, "single"), (19, 2, "double"), (34, 3, "curly"),
                                  (49, 4, "dotted"), (64, 5, "dashed")):
        result += text(21, column, label + " pqgy", INK, T.CSI + f"4:{style}m" + T.CSI + "58:2::224:175:104m")
    return result


def truecolor():
    result = T.RESET + T.CLEAR + T.HIDE_CURSOR
    for row, mode in ((2, T.DECDHL_TOP), (3, T.DECDHL_BOTTOM)):
        result += T.move(row, 1) + mode + T.fg_truecolor(*BLUE) + "  Truecolor, cell by cell" + T.RESET
    for row in range(22):
        result += T.move(row + 6, 4)
        for column in range(80):
            colors = []
            for half in range(2):
                x, y = column / 11, (row * 2 + half) / 8
                wave = math.sin(x) + math.sin(y) + math.sin((x + y) / 2)
                colors.append(tuple(round(v * 255) for v in colorsys.hsv_to_rgb((wave / 8 + 0.55) % 1, 0.75, 0.93)))
            result += T.fg_truecolor(*colors[0]) + T.bg_truecolor(*colors[1]) + "▀"
        result += T.RESET
    return result + text(29, 4, "Two RGB samples per cell. No image payload.", MUTED)


def polish():
    # The underline and raised-text forms the showcase's Text attributes
    # section draws; assembled mathematics from the showcase's evolution.py.
    # These are rendering specimens, not shell output.
    result = start("Typography", "Underlines, raised and lowered text, and assembled mathematics.")
    result += text(6, 4, "Underlines", BLUE, T.BOLD)
    result += text(8, 4, "The quick brown fox jumps — pqjgy descenders", INK, T.sgr(4))
    for column, style, label in ((4, 2, "double"), (20, 3, "curly"),
                                  (36, 4, "dotted"), (52, 5, "dashed")):
        result += text(10, column, label + " pqgy", INK,
                       T.CSI + f"4:{style}m" + T.CSI + "58:2::227:190:124m")
    result += text(13, 4, "Superscript and subscript", BLUE, T.BOLD)
    result += text(15, 4, "E = mc" + T.sgr(73) + "2" + T.sgr(75)
                   + "     a" + T.sgr(73) + "2" + T.sgr(75)
                   + " + b" + T.sgr(73) + "2" + T.sgr(75)
                   + " = c" + T.sgr(73) + "2" + T.sgr(75))
    result += text(17, 4, "H" + T.sgr(74) + "2" + T.sgr(75) + "O"
                   + "       CO" + T.sgr(74) + "2" + T.sgr(75)
                   + "       log" + T.sgr(74) + "2" + T.sgr(75) + " n")
    result += text(20, 4, "Multiline brackets", BLUE, T.BOLD)
    for row, line in enumerate((
            "⎛ n ⎞       n!           ⎡ a  b ⎤             ⎧  x,  x > 0",
            "⎜   ⎟ = ─────────        ⎢      ⎥      |x| =  ⎨",
            "⎝ k ⎠   k! (n−k)!        ⎣ c  d ⎦             ⎩ −x,  x ≤ 0"), 22):
        result += text(row, 4, line)
    return result


def proportional():
    def prose(row, value, color=INK, style=""):
        return (T.move(row, 4) + T.fg_truecolor(*color) + style
                + T.OSC + "66;p=1:c=86;" + value + T.ST + T.RESET)

    result = T.RESET + T.CLEAR + T.HIDE_CURSOR
    result += prose(2, "Text with a little breathing room.", BLUE, T.BOLD)
    result += text(4, 4, "Proportional prose, alongside a familiar terminal grid.", MUTED)
    result += prose(7, "Wide letters and narrow letters keep their own rhythm.")
    result += prose(9, "A paragraph can read like a paragraph, even in a terminal.")
    result += prose(12, "Emphasis stays expressive.", VIOLET, T.BOLD)
    result += prose(14, "An italic aside, a highlighted thought, a clear next step.", GREEN, T.sgr(3))
    result += text(18, 4, "Monospace still keeps code and tables aligned.", AMBER)
    result += text(20, 4, "printf '\\033[73m2\\033[75m'   # raised text, then baseline", BLUE)
    result += text(22, 4, "              width   height", MUTED)
    result += text(23, 4, "viewport         96       31")
    result += text(26, 4, "Select styled text, copy, and paste into a rich-text editor.", MUTED)
    return result + T.move(30, 1) + T.SHOW_CURSOR


def workspace_typography():
    # The split-pane specimen uses real OSC 66 runs inside a cell-aligned box.
    # Keep every claim inside the border, including at the narrower pane width.
    def prose(row, value, color=INK, style="", column=10, cells=58):
        return (T.move(row, column) + T.fg_truecolor(*color) + style
                + T.OSC + f"66;p=1:c={cells};" + value + T.ST + T.RESET)

    result = T.RESET + T.CLEAR + T.HIDE_CURSOR
    result += text(2, 4, "Typography", BLUE, T.BOLD)
    result += panel(4, 4, 69, 10, "Proportional text")
    result += prose(6, "Review queue", BLUE, T.BOLD)
    result += text(8, 6, "□", AMBER)
    result += prose(8, "Check image placement after reconnecting")
    result += text(10, 6, "□", AMBER)
    result += prose(10, "Review the keyboard navigation")
    result += prose(12, "Waiting for your review", GREEN, T.sgr(3))
    result += text(15, 4, "Underlines", BLUE, T.BOLD)
    for column, style, label in ((4, 2, "double"), (21, 3, "curly"),
                                  (38, 4, "dotted"), (55, 5, "dashed")):
        result += text(17, column, label + " pqgy", INK,
                       T.CSI + f"4:{style}m" + T.CSI + "58:2::227:190:124m")
    result += text(20, 4, "Superscript and subscript", BLUE, T.BOLD)
    result += text(22, 4, "E = mc" + T.sgr(73) + "2" + T.sgr(75)
                   + "        H" + T.sgr(74) + "2" + T.sgr(75) + "O"
                   + "        log" + T.sgr(74) + "2" + T.sgr(75) + " n")
    result += text(25, 4, "Multiline brackets", BLUE, T.BOLD)
    for row, line in enumerate((
            "⎛ n ⎞       n!           ⎡ a  b ⎤             ⎧  x,  x > 0",
            "⎜   ⎟ = ─────────        ⎢      ⎥      |x| =  ⎨",
            "⎝ k ⎠   k! (n−k)!        ⎣ c  d ⎦             ⎩ −x,  x ≤ 0"), 27):
        result += text(row, 4, line)
    return result


# One manifest drives both preparation and rendering; dimensions are cells.
CAPTURES = {
    "hero": (hero, 96, 30, "Noir"),
    "tektronix": (tektronix, 92, 34, "Noir"),
    "inline-image": (inline_image, 84, 28, "Noir"),
    "dashboard": (dashboard, 96, 30, "Noir"),
    "shell-integration": (shell_integration, 84, 23, "Noir"),
    "unicode": (unicode, 84, 24, "Noir"),
    "truecolor": (truecolor, 88, 31, "Noir"),
    "polish": (polish, 84, 27, "Noir"),
    "proportional": (proportional, 96, 31, "Noir"),
    "workspace-typography": (workspace_typography, 77, 32, "Noir"),
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_demo_home(directory):
    """Writes the demo HOME into `directory` and returns its manifest."""
    home = directory.resolve()
    contents = readme_demo_home.files(ROOT, workspace_typography())
    for folder in readme_demo_home.FOLDERS:
        (home / folder).mkdir(parents=True, exist_ok=True)
    manifest = {"recipe_sha256": sha256(Path(__file__)),
                "demo_home_sha256": sha256(Path(readme_demo_home.__file__)),
                "files": []}
    for name, data in sorted(contents.items()):
        path = home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        mode = 0o755 if name in readme_demo_home.EXECUTABLES else 0o644
        path.chmod(mode)
        manifest["files"].append({"path": name, "mode": oct(mode), "sha256": sha256(path)})
    (home / ".readme-demo-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


# One `[tab-accessory]` line from TabAccessoryPresenter's trace: a time, then
# `key=value` facts, then ` fading` while a leaving mark is on its way out.
TRACE_LINE = re.compile(r"\[tab-accessory\] (?P<time>[0-9.]+) (?P<facts>.*)$")

# The slot each of Core's answers puts in place, as the trace spells both.
SLOT_FOR_KIND = {
    "ring": ("ring",),
    "bell": ("bell",),
    "colouredBell": ("bell",),
    "statusDot": ("dots(1)",),
    "notificationDot": ("dots(1)",),
    "dots": ("dots(3)",),
    "hint": None,
    "none": ("empty", "hint''"),
}


def parse_trace(lines):
    """The last decision for each tab position, keyed by (position, group size)."""
    decisions = {}
    for line in lines:
        found = TRACE_LINE.search(line.rstrip("\n"))
        if not found:
            continue
        facts = {"time": found["time"]}
        for token in found["facts"].split(" "):
            key, equals, value = token.partition("=")
            if equals:
                facts[key] = value
            elif token:
                facts[token] = "1"
        position, _, size = facts.get("tab", "").partition("/")
        if position.isdigit() and size.isdigit():
            decisions[(int(position), int(size))] = facts
    return decisions


def check_status(trace_lines, expected, status_records=()):
    """Compares a trace with a shot's expected marks; returns the problems.

    `expected` is `{"tabs": N, "marks": {"1": {"kind": "statusDot", ...}}}`:
    each mark names trace facts (`kind`, `slot`, `status`, `progress`, `bell`,
    `isSelected`, ...) that tab's last decision must show. A mark may also
    name a `session` and its `state`, read from `ubq --json status` results.
    """
    decisions = parse_trace(trace_lines)
    tabs = expected.get("tabs")
    states = {record.get("session"): record.get("state") for record in status_records}
    problems = []
    for tab, wanted in sorted(expected.get("marks", {}).items(), key=lambda item: int(item[0])):
        candidates = [(size, facts) for (position, size), facts in decisions.items()
                      if position == int(tab) and (tabs is None or size == tabs)]
        if not candidates:
            problems.append(f"tab {tab}: no decision in the trace" + (f" for a group of {tabs}" if tabs else ""))
            continue
        _, facts = max(candidates, key=lambda candidate: float(candidate[1]["time"]))
        for key, value in wanted.items():
            if key in ("session", "state"):
                continue
            if facts.get(key) != str(value):
                problems.append(f"tab {tab}: {key} is {facts.get(key, 'absent')}, expected {value}")
        slots = SLOT_FOR_KIND.get(facts.get("kind"))
        if slots and "fading" not in facts and facts.get("slot") not in slots:
            problems.append(f"tab {tab}: Core answered {facts.get('kind')} but the slot holds {facts.get('slot')}")
        if "state" in wanted:
            session = wanted.get("session")
            if session not in states:
                problems.append(f"tab {tab}: no status record for session {session}")
            elif states[session] != wanted["state"]:
                problems.append(f"tab {tab}: session {session} is {states[session]}, expected {wanted['state']}")
    return problems


def read_status_records(path):
    """`ubq --json status` results, one JSON document after another."""
    text = path.read_text(encoding="utf-8")
    decoder = json.JSONDecoder()
    records, index = [], 0
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        record, index = decoder.raw_decode(text, index)
        records.extend(record if isinstance(record, list) else [record])
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output-dir", type=Path, help="staging directory, never the checked-in images or goldens")
    parser.add_argument("--demo-home", type=Path, metavar="DIR", help="write the demo HOME for the remote screenshots into DIR")
    parser.add_argument("--check-status", nargs=2, type=Path, metavar=("TRACE_LOG", "EXPECTED"),
                        help="check a UBIQUITTY_TAB_ACCESSORY_TRACE=1 log against a shot's expected marks (JSON)")
    parser.add_argument("--status-records", type=Path, metavar="FILE",
                        help="with --check-status: concatenated `ubq --json status -s SESSION` results")
    parser.add_argument("--only", choices=CAPTURES, help="prepare/render one named specimen")
    parser.add_argument("--binary", type=Path, help="explicit freshly built macOS Ubiquitty executable")
    parser.add_argument("--render", action="store_true", help="also invoke the real renderer; otherwise only prepare inputs")
    args = parser.parse_args()
    modes = [args.output_dir is not None, args.demo_home is not None, args.check_status is not None]
    if sum(modes) != 1:
        parser.error("give exactly one of --output-dir, --demo-home and --check-status")
    if args.status_records and not args.check_status:
        parser.error("--status-records needs --check-status")
    if args.check_status:
        trace, expected = args.check_status
        records = read_status_records(args.status_records) if args.status_records else ()
        problems = check_status(trace.read_text(encoding="utf-8", errors="replace").splitlines(),
                                json.loads(expected.read_text(encoding="utf-8")), records)
        for problem in problems:
            print(problem)
        print(f"{len(problems)} problem(s)" if problems else "Every expected mark is in the trace")
        sys.exit(1 if problems else 0)
    if args.demo_home:
        home = args.demo_home.resolve()
        if home == Path.home().resolve() or home == ROOT or ROOT in home.parents or home in ROOT.parents:
            parser.error("--demo-home must be a directory of its own, not your HOME or this checkout")
        manifest = write_demo_home(home)
        print(f"Wrote {len(manifest['files'])} files into {home}")
        return
    output = args.output_dir.resolve()
    protected = (ROOT / "Docs" / "images", ROOT / "Tests")
    if any(output == path or path in output.parents for path in protected):
        parser.error("use a staging directory; this tool never updates repository images or test goldens")
    if args.binary and not args.binary.is_file():
        parser.error("--binary must name an existing executable")
    if args.render and not args.binary:
        parser.error("--render requires --binary naming a freshly built executable")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"recipe_sha256": sha256(Path(__file__)), "platform": platform.platform(), "captures": []}
    if args.binary:
        manifest["binary"] = str(args.binary.resolve())
        manifest["binary_sha256"] = sha256(args.binary)
    for name, (make_feed, columns, rows, theme) in CAPTURES.items():
        if args.only and name != args.only:
            continue
        feed = output / (name + ".ans")
        config = output / (name + ".toml")
        feed.write_bytes(make_feed().encode("utf-8"))
        settings = ('[font]\nfamily = "JetBrains Mono"\nsize = 14\nligatures = true\nline_spacing = 1.0\n'
                    'proportional_family = "Helvetica Neue"\nproportional_size = 17\n'
                    '[appearance]\ntext_contrast = false\nbackground_opacity = 1.0\n'
                    'follow_system = false\n'
                    'color_space = "srgb"\n'
                    f'theme = "{theme}"\n')
        if name == "tektronix":
            settings += ('[tek]\nglow_vectors = true\ncolor_mode = 1\n'
                         f'beam_color = "{NOIR["ansi"][2]}"\nbackground_color = "{NOIR["bg"]}"\n')
        config.write_text(settings, encoding="utf-8")
        arguments = ["--snapshot", str(output / (name + ".png")), "--snapshot-backend", "macos",
                     "--feed-file", str(feed), "--config", str(config),
                     "--columns", str(columns), "--rows", str(rows), "--scale", "2",
                     "--padding-x", "12", "--padding-y", "12"]
        if name in ("proportional", "workspace-typography"):
            arguments.append("--draws-sized-text")
        record = {"name": name, "columns": columns, "rows": rows, "scale": 2,
                  "feed_sha256": sha256(feed), "config_sha256": sha256(config), "arguments": arguments}
        manifest["captures"].append(record)
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        if args.render:
            environment = dict(os.environ, UBIQUITTY_FAKE_TICKS="0")
            result = subprocess.run([str(args.binary.resolve()), *arguments], env=environment,
                                    capture_output=True, text=True, timeout=60)
            (output / (name + ".render.log")).write_text(result.stdout + result.stderr, encoding="utf-8")
            result.check_returncode()
            record["png_sha256"] = sha256(output / (name + ".png"))
        print(f"{name}: {columns}×{rows}, scale 2, {theme}")
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(manifest['captures'])} specimens in {output}")


if __name__ == "__main__":
    main()
