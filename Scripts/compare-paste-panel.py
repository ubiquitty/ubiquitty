#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""compare-paste-panel.py — the paste-progress panel against its reference.

The panel is meant to be the system's own copy-progress sheet, to the point.
Eyes cannot hold a point, so this measures both images the same way and prints
the difference: the panel's size, and the row band each element's ink occupies,
in points below the panel's top edge.

    Scripts/compare-paste-panel.py <ours.png> [--reference <path>] [--tolerance 1.0]

The reference is Tests/Platform/goldens/paste-push-panel-reference.png — a
screenshot of the system's panel. Both images are read at 2x and reported in
points, so a capture from a different display scale still compares.

Exit 0 when every band matches within the tolerance; 1 with a table otherwise.
"""

import argparse
import os
import struct
import sys
import zlib
from collections import Counter


def loadPNG(path):
    """Decodes a PNG into (width, height, channels, rows-of-bytes)."""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'{path} is not a PNG')
    pos, idat = 8, b''
    width = height = channels = None
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            width, height, depth, colour = struct.unpack('>IIBB', body[:10])
            if depth != 8:
                raise ValueError(f'{path}: only 8-bit images are read here')
            channels = {0: 1, 2: 3, 4: 2, 6: 4}[colour]
        elif kind == b'IDAT':
            idat += body
        elif kind == b'IEND':
            break
        pos += 12 + length

    raw = zlib.decompress(idat)
    stride = width * channels
    rows, previous, at = [], bytearray(stride), 0
    for _ in range(height):
        filterType = raw[at]
        at += 1
        line = bytearray(raw[at:at + stride])
        at += stride
        if filterType == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filterType == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filterType == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filterType == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        rows.append(bytes(line))
        previous = line
    return width, height, channels, rows


class Panel:
    """One panel found inside a screenshot, and the ink inside it."""

    def __init__(self, path):
        self.width, self.height, self.channels, self.rows = loadPNG(path)
        self.path = path
        self._findBounds()
        # The sheet's own colour: the commonest inside it, which no corner
        # sample can get wrong — the corners are rounded, and a screenshot
        # keeps whatever showed through them.
        counts = Counter(self.pixel(x, y)
                         for y in range(self.top, self.bottom + 1, 2)
                         for x in range(self.left, self.right + 1, 2))
        self.background = counts.most_common(1)[0][0]

    def pixel(self, x, y):
        offset = x * self.channels
        row = self.rows[y]
        return row[offset], row[offset + 1], row[offset + 2]

    def _findBounds(self):
        """The panel's rectangle: the sheet, not the desktop around it.

        Keyed on difference from the image's own corner rather than on
        brightness, so a dark-mode sheet on a light desktop and a light sheet
        on a dark one are found by the same rule.
        """
        corner = self.pixel(1, 1)

        def differs(x, y):
            p = self.pixel(x, y)
            return abs(p[0] - corner[0]) + abs(p[1] - corner[1]) + abs(p[2] - corner[2]) > 40

        columns = [x for x in range(self.width)
                   if sum(1 for y in range(0, self.height, 4) if differs(x, y)) > self.height // 24]
        rowsWithInk = [y for y in range(self.height)
                       if sum(1 for x in range(0, self.width, 4) if differs(x, y)) > self.width // 24]
        if not columns or not rowsWithInk:
            raise ValueError(f'{self.path}: no panel found')
        self.left, self.right = min(columns), max(columns)
        self.top, self.bottom = min(rowsWithInk), max(rowsWithInk)

    # The sheet's rounded corners let the desktop through, and a screenshot of
    # one keeps whatever showed. Scanning inside the corner radius reports the
    # panel's content rather than the shape of its edge.
    edgeInsetPoints = 5

    def sizeInPoints(self, scale=2.0):
        return (self.right - self.left + 1) / scale, (self.bottom - self.top + 1) / scale

    def columnBands(self, y0Points, y1Points, scale=2.0, inkThreshold=45, minimumRun=1.0):
        """The column bands carrying ink in a row of the panel, in points.

        The horizontal half of the same question: where each element starts
        across the sheet, so "two points left" is a number rather than an
        impression.
        """
        y0 = self.top + int(y0Points * scale)
        y1 = min(self.bottom, self.top + int(y1Points * scale))
        inset = int(self.edgeInsetPoints * scale)
        found, start = [], None
        for x in range(self.left + inset, self.right + 1 - inset):
            ink = 0
            for y in range(y0, y1):
                p = self.pixel(x, y)
                if (abs(p[0] - self.background[0]) + abs(p[1] - self.background[1])
                        + abs(p[2] - self.background[2])) > inkThreshold:
                    ink += 1
                    if ink > 1:
                        break
            marked = ink > 1
            if marked and start is None:
                start = x
            elif not marked and start is not None:
                found.append(((start - self.left) / scale, (x - 1 - self.left) / scale))
                start = None
        if start is not None:
            found.append(((start - self.left) / scale, (self.right - self.left) / scale))
        return [band for band in found if band[1] - band[0] >= minimumRun]

    def bands(self, x0Points, x1Points, scale=2.0, inkThreshold=45, minimumRun=1.0):
        """The row bands carrying ink in a column of the panel, in points."""
        x0 = self.left + int(x0Points * scale)
        x1 = min(self.right, self.left + int(x1Points * scale))
        inset = int(self.edgeInsetPoints * scale)
        found, start = [], None
        for y in range(self.top + inset, self.bottom + 1 - inset):
            ink = 0
            for x in range(x0, x1):
                p = self.pixel(x, y)
                if (abs(p[0] - self.background[0]) + abs(p[1] - self.background[1])
                        + abs(p[2] - self.background[2])) > inkThreshold:
                    ink += 1
                    if ink > 2:
                        break
            marked = ink > 2
            if marked and start is None:
                start = y
            elif not marked and start is not None:
                found.append(((start - self.top) / scale, (y - 1 - self.top) / scale))
                start = None
        if start is not None:
            found.append(((start - self.top) / scale, (self.bottom - self.top) / scale))
        return [band for band in found if band[1] - band[0] >= minimumRun]


# What the panel is made of, as column ranges to look for ink in. The bands
# each column yields are matched in order: the titlebar's buttons, then the
# title, the bar, and the status line.
COLUMNS = (
    ('text column', 60, 200),
    ('icon column', 6, 52),
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('ours')
    parser.add_argument('--reference', default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'Tests', 'Platform', 'goldens', 'paste-push-panel-reference.png'))
    parser.add_argument('--tolerance', type=float, default=1.0,
                        help='points a band may differ by and still match')
    arguments = parser.parse_args()

    reference = Panel(arguments.reference)
    ours = Panel(arguments.ours)

    failures = 0
    referenceSize = reference.sizeInPoints()
    ourSize = ours.sizeInPoints()
    print(f'panel size: reference {referenceSize[0]:.0f}x{referenceSize[1]:.0f}pt, '
          f'ours {ourSize[0]:.0f}x{ourSize[1]:.0f}pt')
    if abs(referenceSize[0] - ourSize[0]) > arguments.tolerance or abs(referenceSize[1] - ourSize[1]) > arguments.tolerance:
        failures += 1

    for label, x0, x1 in COLUMNS:
        referenceBands = reference.bands(x0, x1)
        ourBands = ours.bands(x0, x1)
        print(f'\n{label}:')
        for index in range(max(len(referenceBands), len(ourBands))):
            r = referenceBands[index] if index < len(referenceBands) else None
            o = ourBands[index] if index < len(ourBands) else None
            if r is None or o is None:
                print(f'  band {index}: reference {r}, ours {o}  MISSING')
                failures += 1
                continue
            deltaTop, deltaBottom = o[0] - r[0], o[1] - r[1]
            verdict = 'ok' if max(abs(deltaTop), abs(deltaBottom)) <= arguments.tolerance else 'OFF'
            if verdict == 'OFF':
                failures += 1
            print(f'  band {index}: reference {r[0]:5.1f}..{r[1]:5.1f}  '
                  f'ours {o[0]:5.1f}..{o[1]:5.1f}  '
                  f'delta {deltaTop:+.1f}/{deltaBottom:+.1f}  {verdict}')

    # Where each row's ink begins across the sheet: the icon's left edge, the
    # title's, and the bar's — the horizontal half of the same comparison.
    for label, y0, y1 in (('title row', 36, 47), ('bar row', 52, 60), ('status row', 67, 77)):
        referenceColumns = reference.columnBands(y0, y1)
        ourColumns = ours.columnBands(y0, y1)
        r = referenceColumns[0] if referenceColumns else None
        o = ourColumns[0] if ourColumns else None
        if r is None or o is None:
            print(f'\n{label}: reference {r}, ours {o}  MISSING')
            failures += 1
            continue
        delta = o[0] - r[0]
        verdict = 'ok' if abs(delta) <= arguments.tolerance else 'OFF'
        if verdict == 'OFF':
            failures += 1
        print(f'\n{label}: ink starts at reference {r[0]:5.1f}pt, ours {o[0]:5.1f}pt  '
              f'delta {delta:+.1f}  {verdict}')

    if failures:
        print(f'\ncompare-paste-panel: {failures} difference(s) past {arguments.tolerance}pt')
        return 1
    print('\ncompare-paste-panel: every band matches the reference')
    return 0


if __name__ == '__main__':
    sys.exit(main())
