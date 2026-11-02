// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
// scaled-run-selection.mjs — does the module light a scaled proportional run's
// last letter through its ink?
//
// A selection over an OSC 66 run at p=1:s=3 is lit letter by letter, on every
// band row, from the spans Core hands the frontend; the page draws those spans
// and nothing of its own. The letter that shows a wrong span is the last one:
// its ink begins in one of the run's cells and runs on into the next, and a
// span that stops at the cell it begins in leaves the ink bare, so a drag over
// the whole word reads as "Hell" with the o unlit. That picture is not reachable
// from any C++ test of the spans: it is the pixels, so this reads the pixels.
//
// The render is the snapshot arm's — Scripts/web-snapshot-shim.mjs, the module
// in node with its embedded Unifont and Noto Sans — and the selection is the
// rectangle --select-rect sets, as the verifier's sheet drags it: the middle
// band row alone, from the run's third column to the last column with ink,
// forwards and backwards. The geometry is read off the module's own frame
// rather than assumed: a selection over an empty row calibrates the cell, and
// the letters' ink on the middle band says where the word ends.
//
//   node Tests/Web/scaled-run-selection.mjs [dist-dir]
import fs from 'fs';
import os from 'os';
import path from 'path';
import zlib from 'zlib';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const shim = path.join(root, 'Scripts', 'web-snapshot-shim.mjs');
const distribution = process.argv[2];
if (distribution && !fs.existsSync(path.join(distribution, 'ubiquitty.js'))) {
  console.error(`scaled-run-selection: no built module at ${distribution} — run Scripts/build-web.sh first`);
  process.exit(2);
}

const failures = [];
const check = (condition, message) => { if (!condition) failures.push(message); };

// --- The frames ---------------------------------------------------------------

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'scaled-run-selection-'));
const configuration = path.join(scratch, 'case.toml');
fs.writeFileSync(configuration, '[appearance]\ntheme = "Noir Clair"\n');
const columns = 30;
const rows = 6;
// The verifier's screen: a scale-2 run after a sized X, and the scale-3 run
// on the rows below, both "Hello" claiming six cells.
const feed = '\\e[?25lAx\\e]66;s=2;X\\e\\\\yz \\e]66;p=1:c=6:s=2;Hello\\e\\\\|\\r\\n\\r\\n\\e]66;p=1:c=6:s=3;Hello\\e\\\\|';
const runRow = 2;
const runScale = 3;
const claimColumns = 6 * runScale;

function render(name, selection) {
  const output = path.join(scratch, `${name}.png`);
  const args = [shim, '--snapshot', output, '--config', configuration, '--columns', String(columns), '--rows', String(rows),
    '--device-scale', '2', '--draws-sized-text', '--feed', feed];
  if (selection) args.push('--select-rect', selection.join(','));
  execFileSync(process.execPath, args, { stdio: ['ignore', 'ignore', 'inherit'] });
  return decodePNG(fs.readFileSync(output));
}

// The shim writes 8-bit RGBA with no filter; anything else is a change to the
// shim this reader has to follow.
function decodePNG(bytes) {
  let cursor = 8;
  let width = 0;
  let height = 0;
  const data = [];
  while (cursor < bytes.length) {
    const length = bytes.readUInt32BE(cursor);
    const type = bytes.toString('latin1', cursor + 4, cursor + 8);
    const body = bytes.subarray(cursor + 8, cursor + 8 + length);
    if (type === 'IHDR') {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      if (body[8] !== 8 || body[9] !== 6 || body[12] !== 0)
        throw new Error('scaled-run-selection: the shim wrote a PNG this reader does not take (want 8-bit RGBA, not interlaced)');
    } else if (type === 'IDAT') {
      data.push(body);
    }
    cursor += 12 + length;
  }
  const raw = zlib.inflateSync(Buffer.concat(data));
  const stride = width * 4;
  const pixels = Buffer.alloc(stride * height);
  for (let row = 0; row < height; row += 1) {
    if (raw[row * (stride + 1)] !== 0)
      throw new Error('scaled-run-selection: the shim wrote a filtered PNG row this reader does not take');
    raw.copy(pixels, row * stride, row * (stride + 1) + 1, row * (stride + 1) + 1 + stride);
  }
  const at = (x, y) => pixels.readUInt32BE((y * width + x) * 4);
  return { width, height, at };
}

const bare = render('bare');
// The cell, from the module's own frame: a selection over the whole of the
// empty last row tints exactly that row's cells.
const calibration = render('calibration', [rows - 1, 0, rows - 1, columns - 1]);
let rowLeft = bare.width;
let rowRight = -1;
let rowTop = bare.height;
let rowBottom = -1;
for (let y = 0; y < bare.height; y += 1) {
  for (let x = 0; x < bare.width; x += 1) {
    if (bare.at(x, y) === calibration.at(x, y)) continue;
    rowLeft = Math.min(rowLeft, x);
    rowRight = Math.max(rowRight, x);
    rowTop = Math.min(rowTop, y);
    rowBottom = Math.max(rowBottom, y);
  }
}
if (rowRight < 0) {
  console.error('scaled-run-selection: FAILED — a selection over the last row tinted nothing, so the frame cannot be read');
  process.exit(1);
}
const cellWidth = (rowRight + 1 - rowLeft) / columns;
const cellHeight = rowBottom + 1 - rowTop;
const gridTop = rowTop - (rows - 1) * cellHeight;
const gridLeft = rowLeft;
check(Number.isInteger(cellWidth) && cellWidth > 0 && cellHeight > 0, `the calibration row is ${rowRight + 1 - rowLeft}x${cellHeight} px, not a whole number of ${columns} cells`);
const background = bare.at(rowLeft, rowTop);
const columnOf = (x) => Math.floor((x - gridLeft) / cellWidth);
const xOf = (column) => gridLeft + column * cellWidth;
const bandRows = Array.from({ length: runScale }, (_, band) => runRow + band);
const bandTop = (row) => gridTop + row * cellHeight;
const isInk = (x, y) => bare.at(x, y) !== background;

// Where the word's ink is on the middle band: the first and last ink column of
// the claim, the "|" after the claim left out.
const middle = bandTop(runRow + 1) + Math.floor(cellHeight / 2);
let inkLeft = -1;
let inkRight = -1;
for (let y = bandTop(runRow); y < bandTop(runRow + runScale); y += 1) {
  for (let x = xOf(0); x < xOf(claimColumns); x += 1) {
    if (!isInk(x, y)) continue;
    inkLeft = inkLeft < 0 ? x : Math.min(inkLeft, x);
    inkRight = Math.max(inkRight, x);
  }
}
check(inkLeft >= 0 && inkRight > inkLeft, 'the scale-3 run drew no ink in its claim');
const lastInkColumn = columnOf(inkRight);
check(lastInkColumn >= 1 && lastInkColumn < claimColumns, `the word's ink ends in column ${lastInkColumn}, outside the claim`);

// --- The drags ----------------------------------------------------------------

// Every pixel between the word's first and last ink column, on every band
// row, that is background in the bare frame: tinted where the selection holds
// the o, bare where it does not.
// Whether a pixel column has background to tint on every band row: a stem
// fills the middle band's whole height, so its columns say nothing about the
// highlight's edges there.
const hasBackgroundOnEveryBand = (x) => bandRows.every((row) => {
  for (let y = bandTop(row); y < bandTop(row + 1); y += 1) {
    if (!isInk(x, y)) return true;
  }
  return false;
});
function tintedBackground(lit, fromX, toX) {
  let background_ = 0;
  let tinted = 0;
  const perBand = [];
  for (const row of bandRows) {
    let first = -1;
    let last = -1;
    for (let y = bandTop(row); y < bandTop(row + 1); y += 1) {
      for (let x = fromX; x <= toX; x += 1) {
        if (isInk(x, y)) continue;
        background_ += 1;
        if (lit.at(x, y) === bare.at(x, y)) continue;
        tinted += 1;
        if (!hasBackgroundOnEveryBand(x)) continue;
        first = first < 0 ? x : Math.min(first, x);
        last = Math.max(last, x);
      }
    }
    perBand.push([first, last]);
  }
  return { background: background_, tinted, perBand };
}
// The highlight's extent on each band row: the same left and right.
const sameOnEveryBand = (perBand) => perBand.every(([first, last]) => first === perBand[0][0] && last === perBand[0][1]);

for (const [name, rectangle] of [
  ['F', [runRow + 1, 2, runRow + 1, lastInkColumn]],
  ['F-mirror', [runRow + 1, lastInkColumn, runRow + 1, 2]],
]) {
  const lit = render(name, rectangle);
  const word = tintedBackground(lit, inkLeft, inkRight);
  check(word.background > 0 && word.tinted === word.background,
    `${name} (rect ${rectangle.join(',')}): ${word.tinted} of ${word.background} background pixel(s) between the H's ink and the o's are tinted; the o's ink past the cell it begins in is bare`);
  check(sameOnEveryBand(word.perBand), `${name}: the band rows light different extents: ${word.perBand.map(([first, last]) => `${first}-${last}`).join(' ')}`);
  // The claim's tail stays bare: the selection ended on the o, whose advance
  // may reach a cell past its ink, and no further.
  const tail = tintedBackground(lit, xOf(lastInkColumn + 2), xOf(claimColumns) - 1);
  check(tail.tinted === 0, `${name}: ${tail.tinted} pixel(s) of the claim's tail after the o are tinted`);
}
// Ending two cells short of the o holds "He": the o's cell stays bare while
// the H's columns light.
const short = render('short', [runRow + 1, 0, runRow + 1, 2 * runScale - 1]);
const oColumns = tintedBackground(short, xOf(lastInkColumn), inkRight);
check(oColumns.tinted === 0, `short (rect ${runRow + 1},0,${runRow + 1},${2 * runScale - 1}): ${oColumns.tinted} pixel(s) of the o's column are tinted`);
const hColumns = tintedBackground(short, inkLeft, xOf(1) - 1);
check(hColumns.background > 0 && hColumns.tinted === hColumns.background, 'short: the H is not lit');

fs.rmSync(scratch, { recursive: true, force: true });
if (failures.length > 0) {
  console.error('scaled-run-selection: FAILED');
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
console.log(`scaled-run-selection: the o's ink through column ${lastInkColumn} lit on all ${runScale} band rows, forwards and backwards, and bare short of it`);
