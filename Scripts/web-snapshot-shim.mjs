#!/usr/bin/env node
// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Scripts/web-snapshot-shim.mjs — the browser frontend, rendered from a shell.
//
// The snapshot driver runs a program and reads a PNG. The web frontend is a
// wasm module a page imports, so this is the program: it loads the module,
// applies the case, renders, and encodes.
//
// No browser. The module builds for node as well as web, and everything the
// render needs is in it — the terminal, the cell builder, the CPU raster and
// the embedded Unifont. What node lacks is a canvas, so the real-face path
// is unreachable here and every render is Unifont. That is what an agreement
// case wants and it is the whole of what this arm can say: a case naming a real
// family is refused below rather than rendered in a font it did not ask for.
//
//   node Scripts/web-snapshot-shim.mjs --snapshot <out> --columns <n> --rows <n> \
//        --config <path> [--feed <text> | --feed-file <path>] [--select-rect r0,c0,r1,c1] [--select-points x0,y0,x1,y1] \
//        [--reflow-from-columns <n>] \
//        [--unfocused] [--view-offset <n>] [--search <text>] [--clear-to-mark | --clear-preserve-input] \
//        [configuration flags: --bg-opacity, --tek-glow, --tek-color-mode, --padding-x, ...]

import fs from 'fs';
import path from 'path';
import zlib from 'zlib';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// The distribution lives in the external build root, outside the checkout,
// where build-web.sh stages it; the root is what Scripts/build_root.py names.
const buildRoot = execFileSync('python3', [path.join(root, 'Scripts', 'build_root.py'), root],
  { encoding: 'utf8' }).trim();
const distribution = path.join(buildRoot, 'web-dist');
const moduleFile = path.join(distribution, 'ubiquitty.js');

// The driver's freshness and provenance guards measure the artefact that
// renders, and this script is not it. Answered before anything else: a caller
// asking which binary this stands for has not asked to render.
if (process.argv[2] === '--print-render-binary') {
  process.stdout.write(path.join(distribution, 'ubiquitty.wasm') + '\n');
  process.exit(0);
}

if (!fs.existsSync(moduleFile)) {
  console.error(`web-snapshot-shim: no built module at ${moduleFile} — run Scripts/build-web.sh first`);
  process.exit(2);
}

// --- The case ---------------------------------------------------------------

const options = { columns: 80, rows: 24 };
const configurationFlags = [];
for (let index = 2; index < process.argv.length; index += 1) {
  const flag = process.argv[index];
  const value = process.argv[index + 1];
  switch (flag) {
    case '--snapshot': options.output = value; index += 1; break;
    case '--columns': options.columns = Number(value); index += 1; break;
    case '--rows': options.rows = Number(value); index += 1; break;
    case '--config': options.config = value; index += 1; break;
    // The backing scale a comparison renders at, matching every other arm.
    case '--device-scale': options.deviceScale = Number(value); index += 1; break;
    case '--feed': options.feed = value; index += 1; break;
    case '--feed-file': options.feed = fs.readFileSync(value, 'utf8'); index += 1; break;
    // The OSC 66 sizing gate the macOS driver takes: a window declares it at
    // session start, and a case that renders sized text asks for it.
    case '--draws-sized-text': options.drawsSizedText = true; break;
    // The backend a case names is this one by construction — the driver picked
    // this program for it.
    case '--snapshot-backend': index += 1; break;
    // What the macOS driver does after the feed, each through the module's
    // own entry.
    case '--select-rect': {
      const bounds = String(value).split(',').map(Number);
      if (bounds.length !== 4 || bounds.some((number) => !Number.isInteger(number))) {
        console.error('web-snapshot-shim: --select-rect takes r0,c0,r1,c1');
        process.exit(3);
      }
      options.selection = bounds;
      index += 1;
      break;
    }
    case '--select-points': {
      const points = String(value).split(',').map(Number);
      if (points.length !== 4 || points.some((number) => !Number.isFinite(number))) {
        console.error('web-snapshot-shim: --select-points takes x0,y0,x1,y1');
        process.exit(3);
      }
      options.selectionPoints = points;
      index += 1;
      break;
    }
    // The feed is written at this width, then the grid rewraps to --columns.
    case '--reflow-from-columns': options.reflowFromColumns = Number(value); index += 1; break;
    case '--unfocused': options.isUnfocused = true; break;
    case '--view-offset': options.viewOffset = Number(value); index += 1; break;
    case '--search': options.search = value; index += 1; break;
    case '--clear-to-mark': options.clearToMark = true; break;
    case '--clear-preserve-input': options.clearPreservingInput = true; break;
    // Anything else is handed to Core, which knows the flags that are
    // configuration keys and writes each into the case's document — the helper
    // every software arm calls — and refuses a word it does not know. So this
    // file never spells a key's TOML, nor a flag it would only forward.
    default: configurationFlags.push(flag); break;
  }
}
if (!options.output || !options.config) {
  console.error('web-snapshot-shim: --snapshot and --config are required');
  process.exit(3);
}

const createModule = (await import(moduleFile)).default;
const wasm = await createModule();
const call = (name, returns, types, values) => wasm.ccall(name, returns, types, values);

// The case's document with the configuration flags written into it. Every
// read below — the keys this arm acts on and the bytes Core parses — is of
// this one document.
let documentText = fs.readFileSync(options.config, 'utf8');
if (configurationFlags.length > 0) {
  const stated = call('ubiquittyWebStateSnapshotFlags', 'string', ['string', 'string'],
    [documentText, configurationFlags.join('\n')]);
  if (stated === null || stated === '') {
    console.error(`web-snapshot-shim: a configuration flag did not parse: ${configurationFlags.join(' ')}`);
    process.exit(3);
  }
  documentText = stated;
}

// A settings file, read for the keys this arm can apply — and refusing the rest
// rather than ignoring them. A key silently dropped renders a picture of a
// terminal the case did not describe, which the tier then compares to one that
// honoured it and reports as a rendering difference.
const applicable = new Set([
  'font.family', 'font.size', 'font.line_spacing', 'appearance.theme', 'appearance.padding',
  'appearance.padding_left', 'appearance.padding_right',
  'appearance.padding_top', 'appearance.padding_bottom', 'cursor.invert_text',
  // Applied by CORE, from the blob below, rather than by a call from here. They
  // are listed because this set is "keys that reach the render", not "keys this
  // file threads by hand" — and the four that Core now answers are the first
  // members of the first kind.
  'underline.thickness', 'underline.offset', 'underline.skip_ink', 'underline.skip_ink_pad',
  'underline.links', 'underline.link_style', 'underline.link_style_per_kind',
  'font.braille_grid', 'font.braille_style', 'selection.style',
  'appearance.shade_blocks',
  // The cursor's shape is Core's as well: the terminal is seeded from the
  // `[cursor]` block at construction and the capture resolves the shape from
  // the terminal, so a bar or an underline named here is the one that draws.
  'cursor.shape',
  // The colour-vision mode is written where every theme application reads
  // it, so the theme the shim names below is substituted on its way in.
  'appearance.colorblind_mode',
  // The colour space: this arm renders sRGB, which is what the harness pins.
  'appearance.color_space',
  'appearance.text_contrast',
  // Folded by Core into the frame style every frame reads: the window's
  // background alpha and the Tektronix tube's colours and glow.
  'appearance.background_opacity',
  'tek.background_color', 'tek.beam_color', 'tek.color_mode', 'tek.glow_vectors',
  // Tracking: the font stack measures every cell with Core's fold of it.
  'font.character_spacing',
  // The background image: its mode and opacity are Core's fold, and the image
  // itself is handed to the module below, because a page has no path to read.
  'appearance.background_image', 'appearance.background_image_opacity', 'appearance.background_image_mode',
]);
// Tables whose keys are the reader's own: a `[triggers]` entry is a regex
// mapped to an action, and Core installs the whole table from the blob.
const applicableTables = new Set(['triggers']);
const settings = new Map();
let section = '';
for (const raw of documentText.split('\n')) {
  const line = raw.replace(/#.*$/, '').trim();
  if (!line) continue;
  const heading = line.match(/^\[([^\]]+)\]$/);
  if (heading) { section = heading[1]; continue; }
  const assignment = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);
  if (!assignment) continue;
  const key = `${section}.${assignment[1]}`;
  const value = assignment[2].trim().replace(/^"(.*)"$/, '$1');
  if (!applicable.has(key) && !applicableTables.has(section)) {
    console.error(`web-snapshot-shim: ${key} is not a setting this arm applies; ` +
                  'the render would not be the one the case describes');
    process.exit(3);
  }
  settings.set(key, value);
}

const family = settings.get('font.family');
if (family !== undefined && family !== 'GNU Unifont') {
  console.error(`web-snapshot-shim: this arm has no canvas and so no real face; ` +
                `the case asks for ${family}`);
  process.exit(3);
}

// --- The render -------------------------------------------------------------


const fontSize = settings.has('font.size') ? Number(settings.get('font.size')) : 0;
// The configuration reaches Core the way a page delivers it: the file's own
// bytes under a name, before the terminal exists, because Core acquires them
// once on first use. Every key the parser understands arrives this way — the
// list above is only the keys this arm additionally has to ACT on after the
// fact, not the keys it can read.
const configurationBytes = Buffer.from(documentText, 'utf8');
call('ubiquittyWebSetPreferenceBlob', null, ['string', 'array', 'number'],
  ['config', configurationBytes, configurationBytes.length]);
const glyphScale = Number.isFinite(options.deviceScale) && options.deviceScale > 0
  ? Math.round(options.deviceScale)
  : 2;
call('ubiquittyWebCreate', null, ['number', 'number', 'number'], [options.rows, options.columns, glyphScale]);
call('ubiquittyWebSetDrawsSizedText', null, ['number'], [options.drawsSizedText ? 1 : 0]);
// One flag declares both OSC 66 facts, as on every snapshot driver.
call('ubiquittyWebSetDrawsProportionalText', null, ['number'], [options.drawsSizedText ? 1 : 0]);
if (settings.has('appearance.background_image')) {
  // The file the configuration names, read here and decoded by Core: a case
  // whose image does not load fails rather than drawing the window without it.
  const imageBytes = fs.readFileSync(settings.get('appearance.background_image'));
  const imageBuffer = wasm._malloc(imageBytes.length);
  wasm.HEAPU8.set(imageBytes, imageBuffer);
  const didDecode = call('ubiquittyWebSetBackgroundImage', 'number', ['number', 'number'], [imageBuffer, imageBytes.length]);
  wasm._free(imageBuffer);
  if (!didDecode) {
    console.error(`web-snapshot-shim: the background image ${settings.get('appearance.background_image')} did not decode`);
    process.exit(3);
  }
}
if (fontSize > 0)
  call('ubiquittyWebSetFontSize', null, ['number'], [fontSize]);
if (settings.has('appearance.theme')) {
  const theme = settings.get('appearance.theme');
  if (!call('ubiquittyWebSetThemeByName', 'number', ['string'], [theme])) {
    console.error(`web-snapshot-shim: no theme named ${theme}`);
    process.exit(3);
  }
}
// The shorthand first, then any per-edge key over it — the precedence Core's
// resolvedPadding() applies. Absent entirely, the frontend keeps its own
// defaults, which are Core's four and not one number.
const edge = (key, fallback) => (settings.has(key) ? Number(settings.get(key)) : fallback);
const shorthand = settings.has('appearance.padding') ? Number(settings.get('appearance.padding')) : undefined;
if (shorthand !== undefined)
  call('ubiquittyWebSetPadding', null, ['number'], [shorthand]);
const current = (name) => call(name, 'number', [], []);
call('ubiquittyWebSetPaddingInsets', null, ['number', 'number', 'number', 'number'], [
  edge('appearance.padding_left', current('ubiquittyWebPaddingLeft')),
  edge('appearance.padding_right', current('ubiquittyWebPaddingRight')),
  edge('appearance.padding_top', current('ubiquittyWebPaddingTop')),
  edge('appearance.padding_bottom', current('ubiquittyWebPaddingBottom')),
]);
if (settings.has('font.line_spacing'))
  call('ubiquittyWebSetLineSpacing', null, ['number'], [Number(settings.get('font.line_spacing'))]);
if (settings.has('cursor.invert_text'))
  call('ubiquittyWebSetCursorInvertText', null, ['number'], [settings.get('cursor.invert_text') === 'true' ? 1 : 0]);


if (options.reflowFromColumns > 0)
  call('ubiquittyWebResize', null, ['number', 'number'], [options.rows, options.reflowFromColumns]);
if (options.feed) {
  // Decoded inside the module, by the function the other headless entry points
  // decode with. A table re-spelled in JavaScript gets the two-character
  // escapes right and \xHH wrong, and the screen fills with literal escape
  // text that reads as a rendering difference.
  call('ubiquittyWebFeedEscaped', null, ['string'], [options.feed]);
}
if (options.reflowFromColumns > 0)
  call('ubiquittyWebResize', null, ['number', 'number'], [options.rows, options.columns]);
if (options.clearToMark)
  call('ubiquittyWebClearToPreviousMark', null, [], []);
else if (options.clearPreservingInput)
  call('ubiquittyWebClearPreservingInput', null, [], []);
if (options.selection)
  call('ubiquittyWebSelectVisibleRect', null, ['number', 'number', 'number', 'number'], options.selection);
if (options.selectionPoints)
  call('ubiquittyWebSelectBetweenPoints', null, ['number', 'number', 'number', 'number'], options.selectionPoints);
if (options.isUnfocused)
  call('ubiquittyWebSetFocus', null, ['number'], [0]);
if (Number.isFinite(options.viewOffset) && options.viewOffset !== 0)
  call('ubiquittyWebScrollBy', null, ['number'], [options.viewOffset]);
if (options.search !== undefined && !call('ubiquittyWebSearchLiteralAndWait', 'number', ['string'], [options.search])) {
  console.error('web-snapshot-shim: --search did not complete successfully');
  process.exit(3);
}

// The page, not the grid: the padding a viewer sees is drawn by CSS in a
// browser and has to be in the pixels here, or every comparison against a
// frontend that drew it differs by the inset.
const base = call('ubiquittyWebRenderPage', 'number', [], []);
const width = call('ubiquittyWebPageWidth', 'number', [], []);
const height = call('ubiquittyWebPageHeight', 'number', [], []);
if (!base || width <= 0 || height <= 0) {
  console.error('web-snapshot-shim: the module rendered nothing');
  process.exit(4);
}
const rgba = Buffer.from(wasm.HEAPU8.subarray(base, base + width * height * 4));

fs.writeFileSync(options.output, encodePNG(rgba, width, height));
console.log(`web-snapshot: ${width}x${height} → ${options.output}`);
// Asked of the module rather than written here: a line this script composes
// says what the script believes, and the point of the marker is to report what
// the wasm actually rendered through.
console.log(call('ubiquittyWebRenderPathMarker', 'string', [], []));

// --- PNG --------------------------------------------------------------------
//
// Written here rather than taken from Core's encoder, which is C++ and not among
// the module's exports. Deflate comes from node's zlib, so what is hand-written
// is the container: the driver reads 8-bit non-interlaced RGBA, which is what
// this writes.

function encodePNG(pixels, imageWidth, imageHeight) {
  const stride = imageWidth * 4;
  const raw = Buffer.alloc((stride + 1) * imageHeight);
  for (let row = 0; row < imageHeight; row += 1) {
    raw[row * (stride + 1)] = 0; // filter: none, so the bytes are the pixels
    pixels.copy(raw, row * (stride + 1) + 1, row * stride, row * stride + stride);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(imageWidth, 0);
  header.writeUInt32BE(imageHeight, 4);
  header[8] = 8; // bit depth
  header[9] = 6; // colour type: RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function chunk(type, body) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(body.length, 0);
  const typed = Buffer.concat([Buffer.from(type, 'ascii'), body]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typed) >>> 0, 0);
  return Buffer.concat([length, typed, crc]);
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1)
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return crc ^ 0xffffffff;
}
