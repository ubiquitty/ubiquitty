#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""The grid cache switched on against switched off, frame for frame.

Runs the app's snapshot command twice over one multi-frame feed, once with
UBIQUITTY_GRID_CACHE=1 and once with 0, and requires every frame's pixels to be
byte-identical. The feed walks the events that change pixels without
necessarily changing a cell: scroll regions, palette writes, resets, line
attributes, the alternate screen, stacked marks, images. Extra arguments pass
through to the snapshot command (a backdrop, a background opacity, a search).

Usage: Scripts/check-grid-cache-differential.py APP CONFIG [snapshot flags...]
       Scripts/check-grid-cache-differential.py --self-test
Exit 0 when every frame matches, 1 when any differs. KEEP=<dir> keeps the pairs.
The self-test needs no app: it holds the frame comparison to planted pairs.
"""
import os, shutil, subprocess, sys, zlib, struct, tempfile


def esc(b):
    return b.replace("\\", "\\\\").replace("\x1b", "\\e")

def screen(rows):
    s = "\x1b[H"
    for r in range(1, rows + 1):
        s += f"\x1b[{r};1Hrow {r} \x1b[31mred\x1b[0m \x1b[44mblue\x1b[0m gjpqy -> != === \x1b[4:3mcurl\x1b[0m"
    return s

FRAMES = [
    ("first", screen(10)),
    ("settle", ""),
    ("edit", "\x1b[3;5Hedited"),
    ("cursor", "\x1b[7;9H"),
    ("scroll", "\x1b[10;1H\r\nscrolled one\r\nscrolled two"),
    ("margin_up", "\x1b[3;6r\x1b[6;1H\r\nin region\r\nagain\x1b[r"),
    ("margin_down", "\x1b[2;5r\x1b[2;1H\x1bM\x1bMdown\x1b[r"),
    ("su", "\x1b[2S"),
    ("sd", "\x1b[1T"),
    ("il", "\x1b[4;1H\x1b[2L"),
    ("dl", "\x1b[3;1H\x1b[1M"),
    ("el", "\x1b[2;3H\x1b[K"),
    ("ech", "\x1b[5;2H\x1b[4X"),
    ("ich_dch", "\x1b[6;2H\x1b[3@\x1b[7;2H\x1b[2P"),
    ("descender_row_change", "\x1b[8;1H\x1b[2Kgggg yyyy jjjj"),
    ("descender_row_clear", "\x1b[8;1H\x1b[2K"),
    ("combining_above", "\x1b[9;1Hé̂̃̄ å̋"),
    ("combining_above_clear", "\x1b[9;1H\x1b[2K"),
    ("ligature_edit", "\x1b[4;1H\x1b[2Ka -> b != c === d <=> e"),
    ("ligature_break", "\x1b[4;4H x"),
    ("osc4", "\x1b]4;1;rgb:00/ff/00\x07"),
    ("osc10", "\x1b]10;rgb:ff/ff/00\x07"),
    ("osc11", "\x1b]11;rgb:20/00/40\x07"),
    ("osc12", "\x1b]12;rgb:ff/00/ff\x07"),
    ("osc_reset", "\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07"),
    ("decscnm_on", "\x1b[?5h"),
    ("decscnm_off", "\x1b[?5l"),
    ("decdwl", "\x1b[2;1H\x1b#6"),
    ("decdhl", "\x1b[4;1H\x1b#3\x1b[5;1H\x1b#4"),
    ("decswl", "\x1b[2;1H\x1b#5\x1b[4;1H\x1b#5\x1b[5;1H\x1b#5"),
    ("decaln", "\x1b#8"),
    ("refill", screen(10)),
    ("alt_enter", "\x1b[?1049h\x1b[H\x1b[2Jalternate"),
    ("alt_edit", "\x1b[4;1Hmore alternate"),
    ("alt_exit", "\x1b[?1049l"),
    ("wide", "\x1b[6;1H世界 \U0001F600 x"),
    ("box", "\x1b[7;1H┌──┐│█▓▒"),
    ("hyperlink", "\x1b[7;12H\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\"),
    ("sync", "\x1b[?2026h\x1b[2;1Hsync body\x1b[?2026l"),
    ("ed", "\x1b[2J"),
    ("refill2", screen(10)),
    ("ris", "\x1bc"),
    ("refill3", screen(10)),
    ("bg_red", "\x1b]11;rgb:80/00/00\x07"),
    ("ris_blue", "\x1bc\x1b]11;rgb:00/00/80\x07"),
    ("refill4", screen(10)),
    ("sixel", "\x1b[3;3H\x1bPq#0;2;100;0;0#0~~~~~~-~~~~~~\x1b\\"),
    ("after_sixel", "\x1b[3;3H\x1b[2K"),
    ("text_after", "\x1b[3;3Hplain"),
    ("idle", ""),
]

def run(app, config, extra, cache, outdir):
    env = dict(os.environ, UBIQUITTY_GRID_CACHE=cache)
    args = [app, "--snapshot", os.path.join(outdir, "000_first.png"), "--snapshot-backend", "swift",
            "--columns", "40", "--rows", "10", "--config", config, "--feed", esc(FRAMES[0][1])] + extra
    for i, (name, feed) in enumerate(FRAMES[1:], 1):
        args += ["--also-feed", esc(feed), "--also-snapshot", os.path.join(outdir, f"{i:03d}_{name}.png")]
    r = subprocess.run(args, env=env, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
        raise SystemExit(f"render failed cache={cache}")

def pixels(path):
    data = open(path, "rb").read()
    pos = 8; idat = b""; w = h = 0
    while pos < len(data):
        n, t = struct.unpack(">I4s", data[pos:pos + 8]); body = data[pos + 8:pos + 8 + n]
        if t == b"IHDR": w, h = struct.unpack(">II", body[:8]); bpp = {6: 4, 2: 3}[body[9]]
        if t == b"IDAT": idat += body
        pos += 12 + n
    raw = zlib.decompress(idat); stride = w * bpp; out = bytearray(); prev = bytearray(stride); i = 0
    for y in range(h):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line; prev = line
    return w, h, bpp, bytes(out)

def differingPixels(pathA, pathB):
    """The pixels two PNG frames disagree on, as flat indices; None for a shape mismatch."""
    a = pixels(pathA)
    b = pixels(pathB)
    if a[:3] != b[:3]:
        return None
    w, h, bpp, pa = a
    pb = b[3]
    return [i // bpp for i in range(0, len(pa), bpp) if pa[i:i + bpp] != pb[i:i + bpp]]


def writePNG(path, width, height, rgba, filterType=0):
    """Writes an RGBA PNG with one filter on every row, for the self-test's planted frames."""
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        row = rgba[y * stride:(y + 1) * stride]
        raw.append(filterType)
        if filterType == 1:
            raw += bytes((row[x] - (row[x - 4] if x >= 4 else 0)) & 255 for x in range(stride))
        else:
            raw += row

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


def selfTest():
    """Holds the comparison to planted pairs: equal frames agree across PNG
    filters, and one changed pixel is found where it was planted."""
    width, height = 7, 5
    frame = bytes((x * 31 + y * 17 + c * 5) & 255 for y in range(height) for x in range(width) for c in range(4))
    changed = bytearray(frame)
    changed[(3 * width + 4) * 4 + 1] ^= 0x40
    with tempfile.TemporaryDirectory() as scratch:
        plain = os.path.join(scratch, "plain.png")
        filtered = os.path.join(scratch, "filtered.png")
        planted = os.path.join(scratch, "planted.png")
        writePNG(plain, width, height, frame)
        writePNG(filtered, width, height, frame, filterType=1)
        writePNG(planted, width, height, bytes(changed))
        failures = []
        if differingPixels(plain, filtered) != []:
            failures.append("two encodings of one frame were told apart")
        if differingPixels(plain, planted) != [3 * width + 4]:
            failures.append("the planted pixel was not the one difference found")
    if failures:
        print(f"check-grid-cache-differential: self-test FAILED — {len(failures)} finding(s): {'; '.join(failures)}")
        return 1
    print("check-grid-cache-differential: self-test ok (equal frames agree, a planted pixel is found)")
    return 0


def main(arguments):
    if arguments[:1] == ["--self-test"]:
        return selfTest()
    if len(arguments) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    app, config, extra = arguments[0], arguments[1], arguments[2:]
    with tempfile.TemporaryDirectory() as on, tempfile.TemporaryDirectory() as off:
        run(app, config, extra, "1", on)
        run(app, config, extra, "0", off)
        names = sorted(os.listdir(on))
        bad = 0
        for n in names:
            diff = differingPixels(os.path.join(on, n), os.path.join(off, n))
            if diff == []:
                continue
            bad += 1
            if diff is None:
                print(f"DIFF {n}: the frames differ in size")
                continue
            w = pixels(os.path.join(on, n))[0]
            ys = sorted({d // w for d in diff})
            xs = sorted({d % w for d in diff})
            print(f"DIFF {n}: {len(diff)} px, y {ys[0]}..{ys[-1]}, x {xs[0]}..{xs[-1]}")
            keep = os.environ.get("KEEP")
            if keep:
                os.makedirs(keep, exist_ok=True)
                shutil.copy(os.path.join(on, n), os.path.join(keep, "on_" + n))
                shutil.copy(os.path.join(off, n), os.path.join(keep, "off_" + n))
        print(f"frames={len(names)} differing={bad}")
        return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
