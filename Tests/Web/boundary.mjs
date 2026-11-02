// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// boundary.mjs — the JavaScript half of the browser frontend, exercised without
// a browser.
//
// `test_web_terminal` covers the C++ bridge and cannot see this side: the page
// names every entry point as a string, marshals bytes through the heap by hand,
// and translates browser event shapes. A keyboard defect reaches a user
// through exactly that gap when the encoder is right and the translation is
// not.
//
// Node loads the same module the page loads. What it cannot supply is a canvas,
// a socket or a real clipboard, so this drives the boundary rather than the
// page: every named entry point resolves, bytes survive the round trip, and the
// asynchronous clipboard contract holds in both directions.
//
// Run against a staged build: `node boundary.mjs <dist-dir>`.

import fs from 'fs';
import path from 'path';

const dist = path.resolve(process.argv[2] ?? '.');

// The module is built for the web, where the wasm arrives over fetch. Node has
// fetch but not for a local path, so this supplies the bytes directly.
globalThis.fetch = async (url) => {
  const leaf = String(url).replace(/^file:\/\//, '').split('/').pop();
  const bytes = fs.readFileSync(path.join(dist, leaf));
  return { ok: true, arrayBuffer: async () => bytes.buffer, headers: { get: () => 'application/wasm' } };
};

let failures = 0;
function check(condition, what) {
  if (condition) return;
  console.error(`FAIL: ${what}`);
  ++failures;
}

const factory = (await import(path.join(dist, 'ubiquitty.js'))).default;
const wasm = await factory();
const call = (name, ret, args) => wasm.cwrap(name, ret, args);
const programMetadata = call('ubiquittyWebProgramMetadataJSON', 'string', []);
check(programMetadata() === 'null', 'metadata is absent before terminal creation');

// --- Every entry point the page names must resolve --------------------------
//
// The page calls these by string, so a dropped or renamed export is an error
// nowhere until the frame that first needs it — which in practice means the
// feature is dead and nobody notices.
const page = fs.readFileSync(path.join(dist, 'terminal.js'), 'utf8');
const named = [...new Set([...page.matchAll(/cwrap\('([A-Za-z0-9_]+)'/g)].map((m) => m[1]))];
check(named.length > 20, `the page names a plausible number of entry points (${named.length})`);
for (const symbol of named) {
  let resolved = true;
  try {
    call(symbol, 'number', []);
  } catch {
    resolved = false;
  }
  check(resolved, `${symbol} resolves`);
}

const create = call('ubiquittyWebCreate', null, ['number', 'number', 'number']);
const feedBytes = call('ubiquittyWebFeed', null, ['number', 'number']);
const buildFrame = call('ubiquittyWebBuildFrame', 'number', []);
const cellCount = call('ubiquittyWebCellInstanceCount', 'number', []);
const rows = call('ubiquittyWebRows', 'number', []);
const columns = call('ubiquittyWebColumns', 'number', []);

// The tier counted below is the focused BLOCK's: a bar or an underline is an
// overlay and re-emits no cell. The shape is a `[cursor]` preference Core
// reads from the blob at construction, and the shipped default is a bar, so
// the test names the block it counts rather than inheriting whichever default
// ships. Once, before the first create: Core acquires the blob on first use,
// and the second create below reads the same values.
const setPreferenceBlob = call('ubiquittyWebSetPreferenceBlob', null, ['string', 'array', 'number']);
const blockCursor = new TextEncoder().encode('[cursor]\nshape = "block"\n');
setPreferenceBlob('config', blockCursor, blockCursor.length);

create(6, 20, 1);
check(rows() === 6 && columns() === 20, 'the grid is the size the page asked for');

// A page is Core's rule, not the row count: Keys::pageLinesForRows keeps one
// row of overlap, as every other frontend's page chord does.
const pageLines = call('ubiquittyWebPageLines', 'number', []);
check(pageLines() === rows() - 1, `a page keeps a row of overlap (${pageLines()} rows of ${rows()})`);

// --- Bytes survive the heap round trip --------------------------------------
//
// The page allocates, copies into HEAPU8, calls, and frees. A wrong length or a
// stale view loses or corrupts input with nothing to show for it.
const encoder = new TextEncoder();
function feed(text) {
  const bytes = encoder.encode(text);
  const buffer = wasm._malloc(bytes.length);
  wasm.HEAPU8.set(bytes, buffer);
  feedBytes(buffer, bytes.length);
  wasm._free(buffer);
}

// The cursor is parked on a blank cell away from the text, so the tier's
// one cell is the only instance past the grid's own.
feed('hello\u001b[3;10H');
check(buildFrame() === 1, 'a frame builds');
// One per cell, and the focused block's cell once more at the tail of the
// stream: the cursor tier (InstanceCounts::cursorTier). The grid's area alone
// would mean the buffer was sized to the grid and clipped the tier.
check(cellCount() === 6 * 20 + 1, 'one instance per visible cell, and the cursor tier\'s');

// --- OSC 52, both directions ------------------------------------------------
//
// Core is synchronous and a browser clipboard is a promise, so both directions
// are staged. A write that is never taken never reaches the clipboard; a read
// that is never answered leaves the program waiting.
const pendingWrite = call('ubiquittyWebPendingClipboardWrite', 'string', []);
const hasPendingWrite = call('ubiquittyWebHasPendingClipboardWrite', 'number', []);
const takeWrite = call('ubiquittyWebTakeClipboardWrite', null, []);
const wantsRead = call('ubiquittyWebWantsClipboardRead', 'number', []);
const provideRead = call('ubiquittyWebProvideClipboardRead', null, ['string']);

check(pendingWrite() === '', 'nothing staged before a program asks');
feed('\x1b]52;c;aGk=\x1b\\'); // base64 "hi"
check(pendingWrite() === 'hi', 'a program write is staged, decoded, and readable as a JS string');
takeWrite();
check(pendingWrite() === '', 'and clears once taken');
check(hasPendingWrite() === 0, 'no operation remains after taking it');
feed('\x1b]52;c;\x1b\\');
check(hasPendingWrite() === 1 && pendingWrite() === '', 'an empty clear is an operation');
takeWrite();
check(hasPendingWrite() === 0, 'the empty clear retires exactly once');

check(wantsRead() === 0, 'no read pending');
feed('\x1b]52;c;?\x1b\\');
check(wantsRead() === 1, 'a program read asks the page');
provideRead('pasted');
check(wantsRead() === 0, 'and is retired once answered');

// A refusal must still answer, or the program waits forever.
feed('\x1b]52;c;?\x1b\\');
check(wantsRead() === 1, 'a second read asks again');
provideRead('');
check(wantsRead() === 0, 'an empty answer retires it too');

// --- Keys across the C ABI --------------------------------------------------
//
// The page passes a key code, the base-layout key, modifier bits and the
// produced text. Those four arguments are where a keyboard defect at this seam lies.
//
// A key bound for a host travels as an intent on a pane the host has bound,
// and this harness has no host, so what the four arguments encode to is read
// where a page with no host puts it: fed back into its own terminal.
// `test_web_terminal` reads the intent a bound pane sends.
const buildKey = call('ubiquittyWebBuildKey', 'number', ['number', 'number', 'number', 'number']);
const feedKey = call('ubiquittyWebFeedKey', 'number', ['number', 'number', 'number', 'number']);
const frameLength = call('ubiquittyWebFrameLength', 'number', []);
const cursorRow = call('ubiquittyWebCursorRow', 'number', []);
const cursorColumn = call('ubiquittyWebCursorColumn', 'number', []);
const selectAll = call('ubiquittyWebSelectAll', null, []);
const selectionText = call('ubiquittyWebSelectionText', 'string', []);
const clearSelection = call('ubiquittyWebClearSelection', null, []);
const keyModifierCtrl = 4;

function screenText() {
  selectAll();
  const text = selectionText();
  clearSelection();
  return text;
}

feed('\u001b[2J\u001b[2;3H');
check(feedKey(0x63, 0x63, keyModifierCtrl, 0x63) === 1, 'Ctrl-C encodes to something');
check(cursorRow() === 1 && cursorColumn() === 2 && !screenText().includes('c'),
  'Ctrl-C crosses the ABI as ETX, which prints nothing and moves nothing');

// An escape sequence completes only behind an ESC: the tail alone prints.
check(feedKey(27, 0, 0, 0) === 1, 'Escape encodes to something');
feed('[4;7H');
check(cursorRow() === 3 && cursorColumn() === 6 && !screenText().includes('H'), 'Escape crosses as ESC');

check(feedKey(0x3a, 0x3b, 1, 0x3a) === 1, 'a shifted key encodes to something');
{
  const text = screenText();
  check(text.includes(':') && !text.includes(';'), `a shifted key sends what was typed (${JSON.stringify(text.trim())})`);
}
check(feedKey(0, 0, 1, 0) === 0, 'a bare modifier encodes to nothing');
check(buildKey(0, 0, 1, 0) === 0, 'a bare modifier produces no frame');
check(buildKey(0x61, 0x61, 0, 0x61) === 0, 'a key before the host has bound the pane waits for the bind, and leaves no frame to send');

// --- A link's modifier across the C ABI --------------------------------------
//
// The page passes the click's Command or Ctrl as the third argument, and Core
// answers an ssh link only when it is held. Dropped on the way, every click
// would read as plain and the link would never open.
{
  const linkAtCell = call('ubiquittyWebLinkAtCell', 'string', ['number', 'number', 'number']);
  // Twenty columns: the web link after it ends on the first row.
  feed('\u001b[H\u001b[2J\u001b]8;;ssh://build.example\u001b\\connect\u001b]8;;\u001b\\ http://x.io');
  check(linkAtCell(0, 2, 0) === '', 'a plain click leaves an ssh link alone');
  check(linkAtCell(0, 2, 1) === 'ssh://build.example', `the link modifier opens it (${JSON.stringify(linkAtCell(0, 2, 1))})`);
  check(linkAtCell(0, 12, 0) === 'http://x.io', `and a web link opens on a plain click (${JSON.stringify(linkAtCell(0, 12, 0))})`);
}

// --- The host's listing across the C ABI -------------------------------------
//
// The ask, and the generation the connect rule waits on. Every entry point
// resolves by the loop at the top of this file, which says nothing about what
// it returns; only a call can see a value that crosses wrong.
const buildListSessions = call('ubiquittyWebBuildListSessions', 'number', []);
const hostAnswerGeneration = call('ubiquittyWebHostAnswerGeneration', 'number', []);

check(buildListSessions() === 0 && frameLength() === 0,
  'directory requests wait for the authenticated typed Welcome');
check(buildListSessions() === 0 && frameLength() === 0,
  'repeated requests before Welcome do not accumulate frames');
check(hostAnswerGeneration() === 0, 'asking is not answering — no answer has landed');

// Core's question for ending what a row stands for crosses as one JSON text,
// and its refusal is a sentence: a 'string' taken as 'number' hands JSON.parse
// a heap address, and a request with no tree has nothing to ask.
const hostDestructiveConfirmationJSON = call('ubiquittyWebHostDestructiveConfirmationJSON', 'string', ['number', 'string', 'string']);
const hostTerminateRefusal = call('ubiquittyWebHostTerminateRefusal', 'string', []);
{
  const question = JSON.parse(hostDestructiveConfirmationJSON(2, 'pane:1', 'host'));
  check(question.token === 0 && typeof question.whyNot === 'string' && question.whyNot.length > 0,
    'a question about a host that has described nothing is refused with a sentence');
  check(typeof hostTerminateRefusal() === 'string', 'the terminate refusal crosses as a JS string');
}

// --- The host's outline across the C ABI -------------------------------------
//
// The rows cross as one JSON text and a row is named back by text, so the
// string return and the string arguments are what a wrong cwrap would break:
// a 'string' taken as 'number' hands JSON.parse a heap address.
const subscribeHostListing = call('ubiquittyWebSubscribeHostListing', 'number', []);
const hostOutlineGeneration = call('ubiquittyWebHostOutlineGeneration', 'number', []);
const isHostListingRefused = call('ubiquittyWebIsHostListingRefused', 'number', []);
const hostOutlineJSON = call('ubiquittyWebHostOutlineJSON', 'string', ['string']);
const collapseHostOutlineRow = call('ubiquittyWebCollapseHostOutlineRow', 'number', ['string']);
const expandHostOutlineRow = call('ubiquittyWebExpandHostOutlineRow', 'number', ['string']);
const collapseRecordedHostOutlineRow = call('ubiquittyWebCollapseRecordedHostOutlineRow', 'number', ['number', 'number', 'number', 'number']);
const expandRecordedHostOutlineRow = call('ubiquittyWebExpandRecordedHostOutlineRow', 'number', ['number', 'number', 'number', 'number']);

check(subscribeHostListing() === 0, 'no host has welcomed the page, so there is nobody to subscribe to');
check(hostOutlineGeneration() === 0 && isHostListingRefused() === 0, 'and no answer to read');
const outlineOfNoHost = JSON.parse(hostOutlineJSON(''));
check(Array.isArray(outlineOfNoHost.rows) && outlineOfNoHost.rows.length === 0 && outlineOfNoHost.matchCount === 0,
  'the outline of no host crosses as JSON with no rows');
check(JSON.parse(hostOutlineJSON('a search')).rows.length === 0, 'a search crosses as text');
check(collapseHostOutlineRow('workspace:9') === 1 && expandHostOutlineRow('workspace:9') === 1,
  'a row is closed and opened by the identity its JSON spells');
check(collapseHostOutlineRow('nine') === 0 && expandHostOutlineRow('') === 0, 'text that is no identity names no row');
check(collapseRecordedHostOutlineRow(5, 1, 0, 0) === 1 && expandRecordedHostOutlineRow(5, 1, 0, 0) === 1,
  'a row with no identity is named by its place');
check(collapseRecordedHostOutlineRow(5, 3, 0, 0) === 0 && collapseRecordedHostOutlineRow(-1, 1, 0, 0) === 0
  && expandRecordedHostOutlineRow(5, 2, -1, 0) === 0, 'a place that names no row is refused');

// A change asked of the host's structure: an operation's number, three
// strings and an index in, a request's number out, and its result as JSON.
const requestHostStructureChange = call('ubiquittyWebRequestHostStructureChange', 'number', ['number', 'string', 'string', 'string', 'string', 'number']);
const hostStructureGeneration = call('ubiquittyWebHostStructureGeneration', 'number', []);
const hostStructureResultJSON = call('ubiquittyWebHostStructureResultJSON', 'string', []);
check(JSON.parse(hostStructureResultJSON()).requestID === 0 && hostStructureGeneration() === 0, 'no change has settled before one is asked');
check(requestHostStructureChange(1, 'nine', 'label', '', '', 0) === 0 && requestHostStructureChange(0, 'tab:7', '', '', '', 0) === 0,
  'text that is no identity, or an operation that is none, asks nothing');
const refusedChange = requestHostStructureChange(1, 'tab:7', 'logs', '', '', 0);
const structureResult = JSON.parse(hostStructureResultJSON());
check(refusedChange > 0 && hostStructureGeneration() === 1 && structureResult.requestID === refusedChange,
  'a change asked with no host listed settles at once under its number');
check(structureResult.outcome === 'refusedHere' && structureResult.target === 'tab:7' && structureResult.operation === 1
  && typeof structureResult.reason === 'string' && structureResult.reason.length > 0,
  'and says in words why it was refused');

// --- The font seam in a host with no DOM ------------------------------------
//
// Node has no document, so setting a family here is the shape a worker or a
// non-browser embedder has. The rasterizer must fall back rather than throw out
// of a synchronous call the C++ side cannot catch.
wasm.ubiquittyFontFamily = 'JetBrains Mono';
let threw = false;
try {
  create(6, 20, 1);
  // Parked off the text again, so the count still carries the tier's cell and
  // this leg keeps measuring the font fallback rather than where the cursor
  // happens to stand.
  feed('after a font was named\u001b[5;4H');
  check(buildFrame() === 1, 'a frame still builds with a font named and no DOM');
  check(cellCount() === 6 * 20 + 1, 'and the grid is intact, cursor tier and all');
} catch (error) {
  threw = true;
  console.error(`FAIL: naming a font in a DOM-less host threw: ${error.message}`);
}
check(!threw, 'the font path degrades rather than throwing');

// --- A family change reaches the rasterizer ---------------------------------
//
// The quoted family the rasterizer draws with is cached on the module, and the
// page changes `ubiquittyFontFamily` at run time in two places: OSC 50 through
// applyPendingFontFamily, and the Beam font palette. Both then rebuild the font
// stack. A cache that outlives the value it was computed from means the rebuild
// constructs a rasterizer that measures and draws the FIRST family for the life
// of the page — the setting reads as ignored, with nothing anywhere saying why.
//
// Observed through the module property rather than through pixels: this is the
// value every draw is keyed on, and node has no DOM to draw into. The property
// is what the EM_JS seam publishes, so a stale one is the defect itself and not
// a proxy for it.
wasm.ubiquittyFontFamily = 'Family One';
wasm.ubiquittyFontFamilyCSS = undefined; // a fresh page, before anything cached
create(6, 20, 1);
const firstCSS = wasm.ubiquittyFontFamilyCSS;
check(typeof firstCSS === 'string' && firstCSS.includes('Family One'),
  `the first family reaches the rasterizer (${firstCSS})`);

// The second family, applied the way the page applies one: assign, then rebuild
// through a public export. setFontSize is the rebuild every other caller uses.
wasm.ubiquittyFontFamily = 'Family Two';
call('ubiquittyWebSetFontSize', null, ['number'])(18);
const secondCSS = wasm.ubiquittyFontFamilyCSS;
check(typeof secondCSS === 'string' && secondCSS.includes('Family Two'),
  `a family changed at run time reaches the rasterizer too (${secondCSS})`);

// --- The axis list splits in two, and `wght` is on the right side -----------
//
// The page registers a face carrying `font-variation-settings`, and weight must
// not be among them: a descriptor naming an axis outranks the property for it,
// so a weight baked into that face would pin every cell to one and the SGR tier
// and the bold face would both stop moving. The filter is the rule; this is the
// only place it can be read.
const setVariations = call('ubiquittyWebSetFontVariations', null, ['string']);
const variationCSS = call('ubiquittyWebFontVariationSettingsCSS', 'string', []);

setVariations('slnt=-6 wght=250 opsz=14.5');
const css = variationCSS();
check(css.includes('"slnt" -6'), `slnt reaches the registered face (${css})`);
check(css.includes('"opsz" 14.5'), `opsz reaches it too (${css})`);
check(!css.includes('wght'), `wght does NOT, or it would pin every cell (${css})`);

// A specification naming only a weight leaves nothing for the face to carry, so
// the page registers none — an empty descriptor would be a face identical to
// the one already served, under a second name.
setVariations('wght=250');
check(variationCSS() === '', 'a weight-only list registers no face');

// The grammar is Core's on both sides. A token neither can read is skipped
// rather than refusing the ones spelled correctly.
setVariations('slnt=-6 nonsense opsz=14.5');
const salvaged = variationCSS();
check(salvaged.includes('"slnt" -6') && salvaged.includes('"opsz" 14.5'),
  `a bad token costs only itself (${salvaged})`);

// --- The clipboard a remote host does not have ------------------------------
//
// The page polls for a pending request and answers from the browser's own
// clipboard. Everything else about that path has a C++ case; what only this
// harness can check is that the page's cwrap SIGNATURES carry it — a MIME that
// arrives empty or a request id that reads as zero is a feature that resolves,
// runs, and answers nothing, which is invisible from either side alone.
//
// Independent encodings exercise the canonical envelopes, the Greet/Welcome
// handshake and the typed pane request. Fixed-width numbers are little-endian;
// channels, lengths and strings are canonical LEB128. The returned bytes are decoded here as well,
// so matching C ABI types alone cannot conceal a wrong wire operation.
{
  const littleEndian = (value, width) => Array.from({ length: width }, (_, byte) =>
    Number((BigInt(value) >> BigInt(8 * byte)) & 255n));
  const variable = (value) => {
    const bytes = [];
    do {
      const byte = value & 127;
      value = Math.floor(value / 128);
      bytes.push(byte | (value ? 128 : 0));
    } while (value);
    return bytes;
  };
  const text = (value) => {
    const bytes = encoder.encode(value);
    return [...variable(bytes.length), ...bytes];
  };
  const identity = (low, high) => [...littleEndian(low, 8), ...littleEndian(high, 8)];
  const envelope = (kind, channel, body) => Uint8Array.from([kind, ...variable(channel), ...variable(body.length), ...body]);
  const requestFrame = (requestID, kind, mime) => {
    return envelope(51, 1, [...littleEndian(requestID, 4), 0, kind, ...text(mime)]);
  };

  const feedFromHost = call('ubiquittyWebFeedFromHost', 'number', ['number', 'number']);
  const serveID = call('ubiquittyWebPendingClipboardServeID', 'number', []);
  const serveWantsTypes = call('ubiquittyWebPendingClipboardServeWantsTypes', 'number', []);
  const serveMime = call('ubiquittyWebPendingClipboardServeMime', 'string', []);
  const beginServe = call('ubiquittyWebBeginClipboardServeItems', null, []);
  const addServe = call('ubiquittyWebAddClipboardServeItem', null, ['string', 'number', 'number']);
  const buildServeAnswer = call('ubiquittyWebBuildClipboardServeAnswer', 'number', ['number']);
  const frameBytes = call('ubiquittyWebFrameLength', 'number', []);

  const readFixed = (bytes, offset, width) => {
    let value = 0;
    for (let byte = 0; byte < width; ++byte) value += bytes[offset + byte] * 2 ** (8 * byte);
    return value;
  };
  const readVariable = (bytes, cursor) => {
    let value = 0;
    for (let shift = 0; shift < 35; shift += 7) {
      const byte = bytes[cursor.offset++];
      if (byte === undefined) throw new Error('truncated fixture varint');
      value += (byte & 127) * 2 ** shift;
      if (!(byte & 128)) return value;
    }
    throw new Error('oversized fixture varint');
  };
  // Every envelope in the page's owed bytes, in order.
  const envelopesAt = (base) => {
    const bytes = wasm.HEAPU8.slice(base, base + frameBytes());
    const envelopes = [];
    for (const cursor = { offset: 0 }; cursor.offset < bytes.length;) {
      const kind = bytes[cursor.offset++];
      const channel = readVariable(bytes, cursor);
      const bodyLength = readVariable(bytes, cursor);
      envelopes.push({ kind, channel, body: bytes.slice(cursor.offset, cursor.offset + bodyLength) });
      cursor.offset += bodyLength;
    }
    return envelopes;
  };
  const answerOf = (base) => {
    const replies = envelopesAt(base).filter((sent) => sent.kind === 74);
    check(replies.length === 1, `one typed clipboard reply frames (${replies.length})`);
    return replies[0] ?? { channel: 0, body: new Uint8Array() };
  };
  const checkAnswer = (base, requestID, mime, payload) => {
    const { channel, body } = answerOf(base);
    check(channel === 1 && readFixed(body, 0, 4) === requestID, 'the typed answer preserves pane and request identity');
    check(body[4] === 0 && readFixed(body, 5, 4) === 0, 'the answer is successful and inline');
    check(readFixed(body, 9, 4) === body.length - 13, 'the exact clipboard bundle length is carried');
    if (!body.length) return;
    const cursor = { offset: 13 };
    check(readVariable(body, cursor) === 1, 'one MIME item is carried');
    const nameLength = readVariable(body, cursor);
    const name = new TextDecoder().decode(body.subarray(cursor.offset, cursor.offset + nameLength));
    cursor.offset += nameLength;
    check(name === mime, `the answer MIME is preserved (${name})`);
    const length = readVariable(body, cursor);
    const delivered = body.subarray(cursor.offset, cursor.offset + length);
    check(length === payload.length && delivered.every((byte, index) => byte === payload[index]),
      `the payload crosses whole, NUL included (${length} bytes)`);
    check(cursor.offset + length === body.length, 'the answer has no trailing bytes');
  };

  const feedHost = (bytes) => {
    const buffer = wasm._malloc(bytes.length);
    wasm.HEAPU8.set(bytes, buffer);
    feedFromHost(buffer, bytes.length);
    wasm._free(buffer);
  };

  // Opt in the way a real page does. The serve gate refuses a page that never
  // claimed the capability, so a harness that skipped the HELLO would be
  // measuring the refusal path and reporting it as the answer path.
  const buildHelloForServe = call('ubiquittyWebBuildHello', 'number', ['string', 'number', 'number', 'string', 'number']);
  const hello = buildHelloForServe('', 7, 1, '', 0); // token, session, clipboardServing, workspace, endsWhenDetached
  check(hello !== 0, 'the opted-in page sends HELLO');
  const greets = envelopesAt(hello);
  check(greets.length === 1 && greets[0].kind === 1 && greets[0].channel === 0, 'the page opens with one Greet');
  const version = readFixed(greets[0]?.body ?? [0, 0], 0, 2);
  // The page's own fingerprint, after its version and app version, so this
  // host is one of the page's build.
  const greetBody = Array.from(greets[0]?.body ?? []);
  let fingerprintAt = 2;
  let appVersionLength = 0;
  for (let factor = 1; ; factor *= 128) {
    const byte = greetBody[fingerprintAt++] ?? 0;
    appVersionLength += (byte & 127) * factor;
    if (!(byte & 128))
      break;
  }
  fingerprintAt += appVersionLength;
  const fingerprint = greetBody.slice(fingerprintAt, fingerprintAt + 32);
  // An Owner granted session 7 of daemon incarnation 42, then its pane bound
  // under handle 1.
  const welcome = [...littleEndian(version, 2), ...text(''), ...fingerprint,
    ...identity(1, 2), ...identity(3, 4), ...identity(5, 6), 0,
    0, ...littleEndian(7, 4), ...littleEndian(0, 4), ...littleEndian(42, 8), ...text('host.sock'), 0, ...text(''),
    ...littleEndian(0, 8), // restoredFromDaemonInstanceID: not a restored workspace
    1, ...littleEndian(0, 4), ...littleEndian(0, 4), ...text('boundary'),
    ...littleEndian(32, 2), ...littleEndian(16 * 1024 * 1024, 4), ...littleEndian(64, 2), ...variable(0),
    ...littleEndian(0, 8), 0, ...variable(0), 0];
  feedHost(Uint8Array.from([...envelope(2, 0, welcome), ...envelope(7, 0, [...variable(1), ...identity(7, 42)])]));

  check(serveID() === 0, 'no request is pending before the host asks');

  feedHost(requestFrame(4242, 1, 'image/png')); // kind 1 = one item
  check(serveID() === 4242, `the request id crosses whole (${serveID()})`);
  check(serveWantsTypes() === 0, 'and it wants one payload, not the list');
  check(serveMime() === 'image/png', `the MIME crosses as a string (${serveMime()})`);

  // The page's own call shape: malloc, copy into HEAPU8, pass base + length.
  // A payload with a NUL inside it, because a signature that treated the
  // pointer as a C string would truncate here and nowhere else.
  const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x1a]);
  beginServe();
  const buffer = wasm._malloc(png.length);
  wasm.HEAPU8.set(png, buffer);
  addServe('image/png', buffer, png.length);
  wasm._free(buffer);
  const answerBase = buildServeAnswer(0); // 0 = OK
  check(answerBase !== 0, 'the answer frames');
  checkAnswer(answerBase, 4242, 'image/png', png);
  check(serveID() === 0, 'the request is spent once answered');

  // A type list is the other kind, and it answers with names and no bytes.
  feedHost(requestFrame(7, 0, '')); // kind 0 = the list
  check(serveWantsTypes() === 1, 'the probe asks for types');
  check(serveMime() === '', 'and names no MIME');
  beginServe();
  addServe('text/plain', 0, 0);
  const typesBase = buildServeAnswer(0);
  check(typesBase !== 0, 'a name-only answer frames');
  checkAnswer(typesBase, 7, 'text/plain', new Uint8Array());
  check(serveID() === 0, 'the type-list request retires once answered');
  feedHost(envelope(0x9d, 1, [...littleEndian(99, 4), 0, 0, ...text('')]));
  check(serveID() === 0, 'a frame of no known kind never reaches the browser clipboard');
}

// --- Pointer lock is decided in Core; the page reports facts ----------------
//
// The page's own timers are gone: the chord's hold is the ladder's clock, and
// the page books one wake-up at the deadline Core names. Driven here without
// a mode set, which is enough to see the wire: no grab means no chord.
{
  const pointerLockVerdict = call('ubiquittyWebPointerLockVerdict', 'number', ['number']);
  const notePointerLockGrab = call('ubiquittyWebNotePointerLockGrab', null, ['number']);
  const notePointerLockChord = call('ubiquittyWebNotePointerLockChord', null, ['number', 'number', 'number', 'number', 'number']);
  const tickPointerLockChord = call('ubiquittyWebTickPointerLockChord', 'number', ['number', 'number', 'number', 'number', 'number']);
  const chordTicksUntilDeadline = call('ubiquittyWebPointerLockChordTicksUntilDeadline', 'number', []);
  const hintTicksUntilExpiry = call('ubiquittyWebHintTicksUntilExpiry', 'number', []);
  check(pointerLockVerdict(1) === 0, 'with 7403 clear a focused page holds no grab');
  check(hintTicksUntilExpiry() === 0, 'no lesson stands, so no repaint is owed');
  notePointerLockChord(1, 1, 0, 0, 0);
  check(chordTicksUntilDeadline() === 0, 'a ⌃⌘ with no grab is a shortcut and arms nothing');
  notePointerLockGrab(1);
  notePointerLockChord(1, 1, 0, 0, 0);
  check(chordTicksUntilDeadline() === 30, 'under a grab the chord arms for the 500 ms hold, in ticks');
  check(tickPointerLockChord(1, 1, 0, 0, 0) === 0, 'asked at once, the hold has not elapsed');
  notePointerLockChord(1, 1, 0, 0, 1);
  check(chordTicksUntilDeadline() === 0, 'a key joining the chord makes it a shortcut, which disarms');

  // The page cannot query live modifiers, so the deadline ask relies on the
  // last key EDGE the keyup listener reported. Re-arm, then report the edge
  // a real Control-key-up event carries -- ctrl back to 0, the sole survivor
  // (Command) still down -- and the chord must disarm from that report alone,
  // with no third key needed.
  notePointerLockChord(1, 1, 0, 0, 0);
  check(chordTicksUntilDeadline() === 30, 're-armed for the next case');
  notePointerLockChord(0, 1, 0, 0, 0); // ctrl keyup: ctrl=0, meta still held
  check(chordTicksUntilDeadline() === 0, 'a Control keyup alone disarms the chord, meta still down');

  // The grab release a real page reports on every pointer-lock exit alike --
  // the program's own `7403l`, a lost focus, or the browser's own Escape
  // handler firing `pointerlockchange` with no help from this page's
  // keyboard code.
  // Escape cannot be driven headlessly (no real Pointer Lock API here), so
  // this is the report path Escape rides once it reaches the page: the same
  // `ubiquittyWebNotePointerLockGrab(0)` call the `pointerlockchange`
  // listener makes unconditionally, on every exit reason alike.
  notePointerLockGrab(0);
  check(pointerLockVerdict(0) === 0, 'an unfocused page never holds');
  notePointerLockChord(1, 1, 0, 0, 0); // the full chord, offered again with no grab
  check(chordTicksUntilDeadline() === 0, 'a released grab leaves nothing for the chord to break out of');
}

// --- Relative pointer lock (7403): every pointer event is the program's -----
//
// `movementX`/`movementY` are the page's contribution -- Core reads them as
// the fact's `deltaX`/`deltaY` and encodes the SGR-pixels report itself. The
// report travels as input on a pane the host has bound, and this harness has
// no host, so what crosses here is the verdict: the event is consumed, and
// nothing is left for the page to send. `test_web_terminal` reads the report
// and its delta from a bound pane.
{
  create(6, 20, 1);
  feed('\x1b[?1016h'); // SGR-pixels (1016): the frame the 7403 report rides
  feed('\x1b[?7403h'); // relative pointer lock
  const pointerCall = call('ubiquittyWebPointer', 'number',
    ['number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number']);
  const kindMotion = call('ubiquittyWebPointerKindMotion', 'number', [])();
  const buttonNone = call('ubiquittyWebPointerButtonNone', 'number', [])();

  const pointerVerdict = call('ubiquittyWebPointerVerdict', 'number', []);
  const verdictConsumed = call('ubiquittyWebPointerVerdictConsumed', 'number', [])();

  const stillFrame = pointerCall(kindMotion, buttonNone, 0, 0, 0, 0, /* deltaX */ 0, /* deltaY */ 0, 0, 0, 0, 0, 1, 0, /* xInCells */ -1);
  check(stillFrame === 0, 'a motion with no delta under 7403 is swallowed, not reported');
  check((pointerVerdict() & verdictConsumed) !== 0, 'and is the program\'s all the same');

  const movedFrame = pointerCall(kindMotion, buttonNone, 0, 0, 0, 0, /* deltaX */ 5, /* deltaY */ -3, 0, 0, 0, 0, 1, 0);
  check((pointerVerdict() & verdictConsumed) !== 0, 'a motion delta under 7403 is the program\'s');
  check(movedFrame === 0, 'and waits for the host to bind the pane, leaving no frame to send');
}

// Proportional queries require the renderer declaration.
{
  const takeReplies = call('ubiquittyWebTakeReplies', 'number', ['number', 'number']);
  const drawsProportional = call('ubiquittyWebDrawsProportionalText', 'number', []);
  const setDrawsProportional = call('ubiquittyWebSetDrawsProportionalText', null, ['number']);
  const replies = () => {
    const capacity = 256;
    const buffer = wasm._malloc(capacity);
    const length = takeReplies(buffer, capacity);
    const text = new TextDecoder().decode(wasm.HEAPU8.slice(buffer, buffer + length));
    wasm._free(buffer);
    return text;
  };
  const query = '\x1b]66;p=1:q=1:i=5;OK\x1b\\';
  create(6, 20, 1);
  replies();
  check(drawsProportional() === 0, 'a bare module declares no proportional runs');
  feed(query);
  check(replies() === '', 'and leaves the measure query unanswered');
  setDrawsProportional(1);
  check(drawsProportional() === 1, 'the bundled renderer\'s declaration takes');
  feed(query);
  check(replies().startsWith('\x1b]66;i=5:c='), 'and the measure query is answered');
  check(page.includes('setDrawsProportionalText(1)'), 'the bundled page declares the runs its atlas draws');
}

// A standalone embedder delivers encoded input to a byte sink, not back into
// the parser. Control bytes, including NUL, must survive the explicit length.
{
  create(6, 20, 1);
  const encode = call('ubiquittyWebEncodeLocalKeyEvent', 'number', Array(8).fill('number'));
  const name = call('ubiquittyWebKeyCodeForName', 'number', ['string']);
  const modifiers = call('ubiquittyWebKeyModifiers', 'number', Array(4).fill('number'));
  const capture = call('ubiquittyWebCaptureProgramState', 'string', []);
  const buffer = wasm._malloc(64), control = modifiers(0, 0, 1, 0);
  const key = (code, bits = 0, capacity = 64) => {
    const length = encode(code, 0, bits, 0, 1, 0, buffer, capacity);
    return Array.from(wasm.HEAPU8.slice(buffer, buffer + length));
  };
  const before = capture();
  check(JSON.stringify(key(name('Tab'))) === '[9]', 'Tab reaches the byte sink');
  check(JSON.stringify(key(97, control)) === '[1]' && JSON.stringify(key(107, control)) === '[11]', 'Ctrl+A and Ctrl+K use Core encoding');
  check(JSON.stringify(key(32, control)) === '[0]', 'encoded NUL is one byte, not an empty C string');
  check(capture() === before, 'encoding does not echo into the terminal');
  check(JSON.stringify(key(name('ArrowUp'))) === '[27,91,65]', 'normal cursor encoding');
  feed('\x1b[?1h');
  check(JSON.stringify(key(name('ArrowUp'))) === '[27,79,65]', 'application cursor encoding follows live Core modes');
  check(key(name('ArrowUp'), 0, 1).length === 0, 'small output buffers do not receive partial sequences');
  wasm._free(buffer);
}

// The metadata bridge reads decoded Core state, separately from the expensive
// grid capture and without consuming progress events another observer needs.
{
  create(6, 20, 1);
  const empty = JSON.parse(programMetadata());
  check(empty.host === null, 'standalone metadata does not invent host process facts');
  check(empty.primaryRecord === null && empty.records.length === 0 && empty.exitStatus === null, 'empty metadata distinguishes absent records and exit status');
  feed('\x1b]2;Review “pane”\x1b\\\x1b]7;file://host/srv/project\x1b\\'
    + '\x1b]7501;state=working:app=claude:progress=40\x1b\\'
    + '\x1b]7501;id=tool:state=blocked:kind=permission:msg=UnVuIHRlc3RzPw==\x1b\\'
    + '\x1b]9;4;1;25\x1b\\');
  const snapshot = programMetadata(), metadata = JSON.parse(snapshot);
  check(metadata.programTitle === 'Review “pane”' && metadata.currentDirectory === '/srv/project', 'raw title and directory cross the UTF-8 boundary');
  check(metadata.primaryRecord === 1 && metadata.records[1].effectiveApp === 'claude'
    && metadata.records[1].message === 'Run tests?', 'Core selects the blocked child and inherits its application');
  check(metadata.records[0].progress === 40 && metadata.records[1].progress === null
    && metadata.progress.state === 1 && metadata.progress.value === 25, 'record progress and OSC 9;4 remain distinct');
  check(programMetadata() === snapshot, 'reading metadata consumes nothing');
  feed('\x1b]7501;id=tool:state=invalid\x1b\\');
  check(programMetadata() === snapshot, 'malformed replacements cannot alter decoded metadata');
  feed('\x1b]7501;state=done:app=claude\x1b\\\x1b]133;D;7\x1b\\\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\');
  const prompt = JSON.parse(programMetadata());
  check(prompt.isReadingCommand && prompt.exitStatus === 7 && prompt.records.length === 1
    && prompt.records[0].state === 'done', 'a prompt expires blocked records while retaining done');
  feed('\x1b]7501;state=clear\x1b\\');
  check(JSON.parse(programMetadata()).primaryRecord === null, 'clearing records removes the primary index');
}

// A workspace uses one module and carrier with independently selected views.
// Recreating the carrier must retire every old view and frame pointer.
{
  const createWorkspace = call('ubiquittyWebCreateWorkspace', null, ['number', 'number', 'number']);
  const createPane = call('ubiquittyWebCreateWorkspacePane', 'number', ['number', 'number', 'number', 'number']);
  const selectPane = call('ubiquittyWebSelectWorkspacePane', 'number', ['number']);
  const destroyPane = call('ubiquittyWebDestroyWorkspacePane', null, ['number']);
  createWorkspace(24, 80, 1);
  check(createPane(101, 6, 20, 1) === 1, 'a first workspace renderer is created');
  check(createPane(102, 8, 30, 1) === 1, 'a second workspace renderer is created');
  check(rows() === 8 && columns() === 30, 'the second renderer owns its grid');
  check(selectPane(101) === 1 && rows() === 6 && columns() === 20, 'selection restores the first grid');
  check(createPane(101, 1, 1, 1) === 0, 'duplicate pane identities cannot replace a live renderer');
  destroyPane(101);
  check(selectPane(101) === 0, 'destroyed views cannot be selected');
  check(selectPane(102) === 1 && rows() === 8, 'destroying one view preserves its sibling');
  const catalog = JSON.parse(call('ubiquittyWebSettingsCatalogJSON', 'string', [])());
  check(catalog.themes.length > 5 && catalog.themes.every(name => typeof name === 'string'), 'appearance uses the Core theme catalog');
  createWorkspace(10, 40, 1);
  check(selectPane(102) === 0 && selectPane(0) === 1 && rows() === 10, 'switching workspaces retires the previous renderers');
  const outline = JSON.parse(call('ubiquittyWebHostWorkspaceJSON', 'string', [])());
  check(!outline.complete && outline.workspaces.length === 0 && outline.questions.length === 0, 'a new carrier starts without invented workspaces or permissions');
}

// Browser appearance edits use Core defaults/ranges and apply atomically.
{
  const catalog = () => JSON.parse(call('ubiquittyWebSettingsCatalogJSON', 'string', [])());
  const configure = call('ubiquittyWebSetRenderingPreferences', 'number', ['string']);
  const values = () => Object.fromEntries(catalog().rendering.map(item => [item.key, item.value]));
  const before = values();
  check(catalog().rendering.find(item => item.key === 'font.proportional_size').max === 96, 'proportional size uses Core bounds');
  check(configure(JSON.stringify({ 'font.proportional_family': 'Georgia', 'font.proportional_size': 18,
    'font.features': 'liga=0', 'underline.skip_ink': false, 'underline.thickness': 2 })) === 1, 'rendering preferences apply');
  check(values()['font.proportional_family'] === 'Georgia' && values()['underline.thickness'] === 2, 'rendering preferences round trip');
  const stable = JSON.stringify(values());
  for (const bad of [null, [], {'font.proportional_size': 1000}, {'font.weight': 400.5}, {'underline.skip_ink': 1},
    {'font.proportional_family': 'a'.repeat(257)}, {'font.features': 'x\n[ssh]'}, {'font.proportional_size': 24, 'host.command': 'sh'}]) {
    check(configure(JSON.stringify(bad)) === 0 && JSON.stringify(values()) === stable, 'invalid preference cannot partially mutate configuration');
  }
  check(configure(JSON.stringify(before)) === 1, 'appearance reset restores the previous document values');
}

console.log(failures === 0
  ? `=== Results: ALL PASSED (${named.length} page entry points + metadata/preferences boundary + 63 cases) ===`
  : `=== Results: FAILED (${failures}) ===`);
process.exit(failures === 0 ? 0 : 1);
