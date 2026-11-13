// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// page-smoke.mjs — does the page reach its first frame?
//
// Everything else about this frontend is tested through WebTerminal, which is
// portable C++ and reachable from ctest. The page is not, and a `const` bound
// below the first call that reads it makes the module throw
// `ReferenceError: Cannot access 'x' before initialization` on the first paint
// and die before drawing — with the code in the bundle, every export resolved,
// and every C++ test passing. Presence is not execution.
//
// So this loads the built page against a stub DOM and asserts it gets to a
// frame. It is a smoke test on purpose: it does not check what was drawn, only
// that drawing happened without throwing.
//
// No browser and no new dependency — the surface the page touches is about
// twenty calls, and stubbing them is cheaper than adding jsdom to a repository
// that has no node dependencies at all.
//
//   node Tests/Web/page-smoke.mjs [dist-dir]

import fs from 'fs';
import path from 'path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const le = (value, width) => Array.from({ length: width }, (_, byte) =>
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
const textBytes = (text) => Array.from(new TextEncoder().encode(text));
const wireText = (text) => { const bytes = textBytes(text); return [...variable(bytes.length), ...bytes]; };
const identityBytes = (low, high) => [...le(low, 8), ...le(high, 8)];
// One canonical envelope: [u8 kind][varint channel][varint length][body].
const typedFrame = (kind, channel, body) => Uint8Array.from([kind, ...variable(channel), ...variable(body.length), ...body]);
// Every envelope in one write, in order. A write may hold several.
function envelopesIn(bytes) {
  const envelopes = [];
  let cursor = 0;
  const readVariable = () => {
    let value = 0;
    let factor = 1;
    let byte;
    do {
      byte = bytes[cursor++];
      if (byte === undefined) throw new Error('page-smoke: a write ends inside an envelope header');
      value += (byte & 127) * factor;
      factor *= 128;
    } while (byte & 128);
    return value;
  };
  while (cursor < bytes.length) {
    const kind = bytes[cursor++];
    const channel = readVariable();
    const length = readVariable();
    envelopes.push({ kind, channel, body: bytes.subarray(cursor, cursor + length) });
    cursor += length;
  }
  return envelopes;
}
// The Greet's leading fields, in putGreet's order (Messages.cpp): the build,
// the client's identity, and the admission request.
function readGreet(body) {
  const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
  let cursor = 0;
  const readVariable = () => {
    let value = 0;
    let factor = 1;
    let byte;
    do { byte = body[cursor++]; value += (byte & 127) * factor; factor *= 128; } while (byte & 128);
    return value;
  };
  const readText = () => {
    const length = readVariable();
    const value = new TextDecoder().decode(body.subarray(cursor, cursor + length));
    cursor += length;
    return value;
  };
  const greet = { wireVersion: view.getUint16(0, true) };
  cursor = 2;
  greet.appVersion = readText();
  greet.engineFingerprint = Array.from(body.subarray(cursor, cursor + 32));
  cursor += 32;
  greet.clientInstance = Array.from(body.subarray(cursor, cursor + 16));
  cursor += 16;
  greet.clientKind = body[cursor++];
  greet.requestedRole = body[cursor++];
  greet.target = body[cursor++];
  greet.sessionID = view.getUint32(cursor, true);
  greet.workspaceID = view.getUint32(cursor + 4, true);
  cursor += 16; // the two IDs and the expected daemon incarnation
  greet.workspaceName = readText();
  greet.agentLabel = readText();
  greet.sshHost = readText();
  greet.isAttachOnly = body[cursor++] === 1;
  greet.endsWhenDetached = body[cursor++] === 1;
  greet.servesClipboard = body[cursor++] === 1;
  return greet;
}
// The last Greet among the writes, or null.
function lastGreet(frames) {
  for (let index = frames.length - 1; index >= 0; --index) {
    const greet = envelopesIn(frames[index]).find((envelope) => envelope.kind === 1 && envelope.channel === 0);
    if (greet) return readGreet(greet.body);
  }
  return null;
}
// The daemon incarnation every fake host here names; a pane's ID is its
// session and this.
const fixtureDaemonInstanceID = 1;
// A granted Welcome for what a Greet asked: the same target, the session it
// named or the one the host assigned, the page's own build's fingerprint, and
// putWelcome's field order.
const typedWelcome = (greet, assignedSessionID = 1) => {
  const version = window.ubiquitty.wireVersion;
  const target = greet ? greet.target : 0;
  const sessionID = (greet && greet.sessionID) || assignedSessionID;
  const workspaceID = target === 1 ? ((greet && greet.workspaceID) || 1) : 0;
  return typedFrame(2, 0, [...le(version, 2), ...wireText(''), ...(greet ? greet.engineFingerprint : new Array(32).fill(0)),
    ...identityBytes(1, 2), ...identityBytes(3, 4), ...identityBytes(5, 6), 0,
    target, ...le(target < 2 ? sessionID : 0, 4), ...le(workspaceID, 4), ...le(fixtureDaemonInstanceID, 8),
    ...wireText('host-fake.sock'), 0, ...wireText(''),
    ...le(0, 8), // restoredFromDaemonInstanceID: a live workspace, not one restored from a record
    1, ...le(0, 4), ...le(0, 4), ...wireText(''),
    ...le(32, 2), ...le(16 * 1024 * 1024, 4), ...le(64, 2), ...variable(0), ...le(0, 8), 0, ...variable(0), 0]);
};
// Every Call of one method among the writes, including Calls sharing a write
// with Acks or Facts.
function directoryCalls(frames, method = 'host.sessions.subscribe') {
  const calls = [];
  for (const bytes of frames) {
    for (const envelope of envelopesIn(bytes)) {
      if (envelope.kind !== 13) continue;
      const call = JSON.parse(new TextDecoder().decode(envelope.body));
      if (call.method === method) calls.push(call);
    }
  }
  return calls;
}

// SessionTreeWire and Records encoders' one-window, one-tab directory shape.
// The page must consume the structure, listed identity and facts before it can
// satisfy the separately delivered revision promise.
function directoryRecords(rows) {
  const frames = [];
  for (const [index, row] of rows.entries()) {
    const workspace = row.workspaceID || row.id;
    const handle = 0x40000000 + index;
    const attendees = [];
    for (let attendee = 0; attendee < row.attendees; ++attendee)
      attendees.push(...le(attendee + 1, 4), attendee < row.humans ? 0 : 1);
    const leaf = [0, ...identityBytes(row.id, 1), ...le(row.id, 4), ...le(row.id, 4),
      ...le(row.rows, 2), ...le(row.columns, 2), ...le(0, 4), ...le(1, 8),
      ...wireText(''), 0, ...wireText(''), 0, ...variable(row.attendees), ...attendees];
    const tab = [...le(row.id, 4), ...wireText(''), 0, ...wireText(''), 1, 0, ...leaf];
    const window = [...le(row.id, 4), ...wireText(''), 0, 0, 1, 0, ...tab];
    const structure = [...le(1, 8), 0, row.flags & 2 ? 1 : 0, ...le(workspace, 4),
      ...wireText(row.workspaceName), ...wireText(''), 0, 1, 0, ...window];
    frames.push(typedFrame(16, 0, [...le(workspace, 4), ...le(1, 8), 0, 0, ...structure]));
    frames.push(typedFrame(17, 0, [...variable(handle), ...identityBytes(row.id, 1)]));
    const facts = [...le(1, 4), ...[row.title, row.cwd, '', '', '', '', '', '', ''].flatMap(wireText),
      ...le(row.rows, 2), ...le(row.columns, 2), 0, 0, ...le(1, 4), ...wireText(row.process), ...le(1, 4),
      row.flags & 1, 0, 0, ...wireText(''), 0, ...le(0, 8), 0, ...le(0, 8), ...le(0, 8), ...le(0, 8), 0, 0, 0];
    frames.push(typedFrame(48, handle, facts));
  }
  return frames;
}
const directoryAnswer = (id, rows) => typedFrame(14, 0, [0, ...textBytes(JSON.stringify({ jsonrpc: '2.0', id,
  result: { workspaces: rows.map(row => row.workspaceID || row.id), structureRevisions: rows.map(() => '1'),
    paneRevisions: rows.map(row => ({ session: row.id, revision: 1 })), panes: rows.length, hostNowUnixMilliseconds: 1 } }))]);

const dist = path.resolve(process.argv[2] ?? 'build/web-dist');
if (!fs.existsSync(path.join(dist, 'terminal.js'))) {
  console.error(`page-smoke: no built page at ${dist} — run Scripts/build-web.sh first`);
  process.exit(2);
}

// A page owns its timers and DOM. Running two ESM instances against the
// same document lets the demo's frame tick overwrite the attached verdict.
// Separate processes retain every assertion and give each run one page.
const phase = process.argv[3];
if (!phase) {
  for (const name of ['local', 'attached']) {
    const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), dist, name], { stdio: 'inherit' });
    if (child.status !== 0) process.exit(child.status ?? 1);
  }
  process.exit(0);
}
if (!['local', 'attached'].includes(phase)) {
  console.error(`page-smoke: unknown phase ${phase}`);
  process.exit(2);
}

// --- The stub DOM ---------------------------------------------------------
//
// One file for every probe here; see Tests/Web/stub-dom.mjs for what a copy per
// probe cost when the copies drifted.
import { installStubDom, elementFor, elements, listeners, hostRecordTouches, paints } from './stub-dom.mjs';

installStubDom(dist);

const loadedFaces = [];
const declaredFaces = ['JetBrains Mono', 'Symbols Nerd Font Mono'].map(family => ({
  family,
  status: 'unloaded',
  async load() { loadedFaces.push(family); this.status = 'loaded'; return this; },
}));
document.fonts[Symbol.iterator] = function* () {
  yield* declaredFaces;
};
// --- The run --------------------------------------------------------------

const wiring = [
  ['ime:keydown', 'typing — the keydown listener moved to the IME element'],
  ['ime:keyup', 'key RELEASE — kitty REPORT_EVENTS clients get no key-up without it'],
  ['ime:compositionend', 'input-method composition — CJK and dead keys'],
  ['window:focus', 'focus reporting — DEC 1004, the hollow cursor, the bell gate'],
  ['window:blur', 'focus loss'],
  ['document:visibilitychange', 'hidden tab focus and unheard bells'],
  ['screen:wheel', 'scrollback by wheel'],
  ['screen:mousedown', 'selection'],
  ['window:resize', 'reflow'],
  ['document:pointerlockchange', 'pointer-lock grab reporting — Escape exiting the browser\'s own lock would leave Core holding a stale grab, and the lesson naming the way out would never withdraw'],
];

const failures = [];
// Reported and EXITED rather than collected. A throw inside one of the awaited
// sections below aborts the rest of this file: an installed handler stops node
// from exiting nonzero on its own, the verdict block never runs, the loop drains
// and the process exits 0 — a broken page reporting as a silent pass, which is
// the one shape this file exists to catch. The stack goes with it, because the
// message alone does not say which section stopped.
const die = (why) => {
  console.error('page-smoke: FAILED');
  console.error(`  ${why}`);
  process.exit(1);
};
process.on('uncaughtException', (error) => die(`uncaught: ${(error && error.stack) || error}`));
process.on('unhandledRejection', (error) => die(`unhandled rejection: ${(error && error.stack) || error}`));

// Wrapped, because a throw at MODULE scope — a syntax error, a bad top-level
// binding — rejects this import rather than surfacing through the handlers
// above. Unwrapped, the rejection stops the file here: the verdict block below
// never runs, node drains its loop and exits 0, and a completely broken page
// reports as a silent pass. That is the exact failure this file exists to
// catch, in the one shape it could not see.
if (phase === 'local') {
  try {
    await import(path.join(dist, 'terminal.js'));
  } catch (error) {
    console.error('page-smoke: FAILED');
    console.error(`  the page threw while loading: ${(error && error.message) || error}`);
    process.exit(1);
  }

  // main() runs off the wasm factory's promise, so give it a turn to finish.
  await new Promise((resolve) => setTimeout(resolve, 2500));

  // A page that threw on first paint still registered no paint, so the count is
  // the assertion that matters — not the absence of an exception, which a
  // swallowed rejection would hide.
  if (paints === 0)
    failures.push('the page never painted a frame');
  if (!loadedFaces.includes('Symbols Nerd Font Mono'))
    failures.push('the bundled symbols face was not loaded before routing');

  // Each of these is a wiring with no test of its own, and each fails
  // silently: a missing listener is a feature that does nothing rather
  // than a page that breaks, which is why reaching a frame is not enough.

  for (const [key, what] of wiring) {
    if (!listeners.has(key)) failures.push(`no ${key} listener — ${what} would not work`);
  }

  // DECSET 7403's grab report rides `pointerlockchange`, which this stub DOM
  // cannot fire for real — there is no Pointer Lock API here to grant or
  // revoke. What this file can drive is the listener itself: call it exactly
  // as the browser would on any exit (the program's own `7403l`, a lost focus,
  // or the browser's own Escape handler, all alike from this listener's point
  // of view) and confirm it runs to a repaint rather than throwing partway through
  // the call into Core. The report's WIRE — that the call reaches Core and
  // changes what Core answers — is proven in boundary.mjs, which can read
  // Core's state back; this file only proves the listener executes.
  {
    const pointerlockchange = listeners.get('document:pointerlockchange');
    if (pointerlockchange) {
      const before = paints;
      try {
        pointerlockchange();
      } catch (error) {
        failures.push(`the pointerlockchange listener threw: ${(error && error.message) || error}`);
      }
      if (paints <= before)
        failures.push('the pointerlockchange listener ran but painted nothing — a withdrawing lesson would not redraw');
    }
  }

  // The surface an embedding document reads the host's outline through, asserted
  // by CALLING it. window.ubiquitty is one object literal built at module scope and
  // carries the connection half and the outline half together, so every key on it
  // exists whether or not main() installed the implementation behind it: a typeof
  // check passes on a page that painted a frame and then stopped short. The reader
  // answers rows only once main() has run, and throws until then.
  if (typeof globalThis.window.ubiquitty?.requestSessions !== 'function'
      || typeof globalThis.window.ubiquitty?.outline !== 'function') {
    failures.push('window.ubiquitty exposes no outline — an embedder has nothing to read');
  } else {
    try {
      const outline = globalThis.window.ubiquitty.outline();
      if (!Array.isArray(outline?.rows))
        failures.push(`window.ubiquitty.outline() answered ${typeof outline?.rows} rows rather than a list`);
    } catch (error) {
      failures.push(`window.ubiquitty.outline() throws on a loaded page (${(error && error.message) || error}) — `
        + 'the handle carries the key and nothing behind it');
    }
  }

  // Which path painted, counted rather than sampled.
  //
  // The stub canvas answers only '2d', so `new WebGLRenderer(canvas)` throws and
  // every frame takes the software raster. That makes this run the negative arm
  // for the readout itself: a build whose status line always says "WebGL2" passes
  // every other assertion in this file and in the C++ suite, because nothing else
  // executes terminal.js at all.
  //
  // It matters because the status line is one variable both paths write, flushed
  // on a 500ms tick — so it reports whichever frame happened to cross the tick,
  // and a session mixing the paths reads as whichever won the coin toss. Five
  // separate investigations into a frame-rate complaint died on that ambiguity;
  // the cure is a counter per path, and this is the case that catches a readout
  // that stops telling the two apart.
  //
  // The readout is written on a half-second tick and only when a frame was
  // counted, so a run that paints twice never flushes it. Driving the wheel
  // listener across that boundary is what makes the line exist to assert on —
  // scrolling repaints, and this run has scrollback because the banner printed.
  const wheel = listeners.get('screen:wheel');
  if (wheel) {
    for (let i = 0; i < 4; ++i) {
      wheel({ deltaY: (i % 2 ? -120 : 120), preventDefault() {}, ctrlKey: false, metaKey: false, shiftKey: false, altKey: false, clientX: 10, clientY: 10 });
      await new Promise((resolve) => setTimeout(resolve, 220));
    }
  }

  // The window padding, and the one thing about it that fails quietly. The visible
  // margin is easy to eyeball; a click landing one cell off near an edge is not,
  // and it is what an inset applied to the drawing rather than to the element
  // produces. So the assertion is on the rect the pointer maps through.
  {
    const screen = elements.get('screen-viewport');
    const inset = parseFloat(screen && screen.style.inset);
    if (!(inset > 0)) {
      failures.push(`the canvas viewport was never inset: ${JSON.stringify(screen && screen.style.inset)}`);
    } else if (screen.getBoundingClientRect().left !== inset) {
      failures.push('the padding moved the canvas without moving the rect the pointer measures from');
    }
    if (screen.getBoundingClientRect().top !== inset)
      failures.push('the padding insets the left edge but not the top');

    // The two halves have to agree: Core shrinks the grid by the inset and the
    // page moves the canvas by it, and nothing above compares them. Shrunk by one
    // amount and moved by another passes every assertion so far, and shows as a
    // terminal whose right edge is under the window's.
    //
    // The fit is the one check that ties them together, and it is an assertion
    // about the RENDERED size, so it can only be made against a context whose
    // measurement tracks the font it was set. A context that answers a constant
    // makes the rasterizer's cell and the raster's cell disagree by the glyph
    // scale, and the canvas comes out about twice the window wide on a page doing
    // nothing wrong — a check that fails for a reason it cannot name.
    const drawn = elements.get('screen');
    const drawnWidth = drawn && drawn.width;
    const drawnHeight = drawn && drawn.height;
    // window's, not globalThis's: the stub defines it there, and reading the
    // wrong one silently yields 1 and fails the fit by exactly the ratio.
    const scale = window.devicePixelRatio || 1;
    if (!(drawnWidth > 0) || !(drawnHeight > 0)) {
      failures.push('the canvas has no backing-store size, so the fit below would compare nothing');
    } else {
      // Device pixels, because that is what the canvas backing store is in. The
      // inset is CSS px on both edges.
      const availableWidth = Math.round((window.innerWidth - 2 * inset) * scale);
      const availableHeight = Math.round((window.innerHeight - 2 * inset) * scale);
      if (drawnWidth > availableWidth)
        failures.push(`the inset canvas is wider than the window it sits in: ${drawnWidth} > ${availableWidth} device px`);
      if (drawnHeight > availableHeight)
        failures.push(`the inset canvas is taller than the window it sits in: ${drawnHeight} > ${availableHeight} device px`);
      // A canvas that fits by collapsing fits trivially. One cell of slack on each
      // axis is the most a floor() over the cell size can leave, so a gap wider
      // than that is the grid disagreeing with the space rather than rounding.
      const cellWidth = Math.max(1, Math.round(16 * scale * 0.5));
      if (availableWidth - drawnWidth > cellWidth * 2)
        failures.push(`the inset canvas leaves ${availableWidth - drawnWidth} device px unused, more than rounding explains`);
    }
  }

  {
    const line = elements.has('status') ? String(elements.get('status').textContent || '') : '';
    if (!line) {
      failures.push('the status line was never written — the half-second tick never flushed a frame');
    } else {
      if (!/cpu[1-9]/.test(line))
        failures.push(`the status line reports no CPU frames on a run that has no WebGL2 context: ${JSON.stringify(line)}`);
      if (!/gpu0\b/.test(line))
        failures.push(`the status line claims GPU frames on a run whose canvas answers only 2d: ${JSON.stringify(line)}`);
      if (!/CPU \(/.test(line))
        failures.push(`the status line does not name the path that painted: ${JSON.stringify(line)}`);
    }
  }

  // Not asserted: the tab title. This run has no host and the local
  // banner sets no OSC 0/2, so document.title correctly stays empty — and every
  // assertion I could write about it here passes whether the page reads the
  // terminal or ignores it. A check that cannot fail is worse than the gap it
  // appears to close.

  // --- A page with no host is the terminal -------------------------------------
  //
  // The gate that stops an attached client echoing into its mirror is one condition
  // away from swallowing input on a page that has no host at all. The attached arm
  // is asserted further down; a gate stuck closed passes that one and leaves a
  // standalone page dead to the keyboard with nothing on screen explaining it, which
  // is a hole no assertion in this file could see.
  //
  // The observable is a PAINT, for the reason the other arm uses one: a local feed
  // repaints to show the character, so counting paints across a keystroke separates
  // "swallowed" from "echoed" without reading the grid. Run here, while this page is
  // still the standalone one — the attached import below replaces the listener.
  {
    const keydown = listeners.get('ime:keydown');
    if (!keydown) {
      failures.push('no ime:keydown listener — the standalone echo check cannot run');
    } else {
      const quiet = paints;
      await new Promise((resolve) => setTimeout(resolve, 200));
      const drift = paints - quiet; // repaints that happen with no input at all
      const before = paints;
      keydown({
        key: 'a', code: 'KeyA', keyCode: 65,
        ctrlKey: false, altKey: false, shiftKey: false, metaKey: false,
        isComposing: false,
        preventDefault() {}, stopPropagation() {},
      });
      await new Promise((resolve) => setTimeout(resolve, 200));
      if (paints - before <= drift)
        failures.push(`a page with no host swallowed a keystroke (${paints - before} paint(s) against a ${drift}-paint `
          + 'quiet baseline) — with nothing to send to, the page is the terminal and the echo is what makes it usable');
    }
  }

  // Search returns before scanning, publishes on idle, and also works without
  // requestIdleCallback. The standalone input above leaves a searchable letter.
  {
    const api = window.ubiquitty;
    const events = [];
    const originalDispatch = window.dispatchEvent;
    window.dispatchEvent = (event) => {
      if (event.type === 'ubiquitty-search') events.push(event.detail);
      return originalDispatch(event);
    };
    const idle = [];
    window.requestIdleCallback = (callback) => { idle.push(callback); };
    const first = api.search('absent search token');
    const pending = api.search('a');
    if (pending.isComplete || pending.generation === first.generation || idle.length !== 1)
      failures.push('search scanned inline, reused the replaced generation, or booked duplicate idle work');
    for (let slices = 0; idle.length && slices < 1000; ++slices) idle.shift()();
    if (!api.searchStatus.isComplete || api.searchStatus.foundCount < 1)
      failures.push('idle search did not find the locally typed letter');
    if (!api.stepSearch('older')) failures.push('search could not step its published matches');
    if (!events.some((status) => status.generation === pending.generation && status.isComplete))
      failures.push('search completion did not reach the embedder event');
    const beforeOutput = api.searchStatus;
    listeners.get('ime:keydown')({
      key: 'a', code: 'KeyA', keyCode: 65,
      ctrlKey: false, altKey: false, shiftKey: false, metaKey: false,
      isComposing: false, preventDefault() {}, stopPropagation() {},
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    for (let slices = 0; idle.length && slices < 1000; ++slices) idle.shift()();
    const afterOutput = api.searchStatus;
    if (afterOutput.generation !== beforeOutput.generation || afterOutput.foundCount !== beforeOutput.foundCount + 1
        || afterOutput.revealEpoch !== beforeOutput.revealEpoch)
      failures.push('completed search did not refresh on output while preserving its focus');
    delete window.requestIdleCallback;
    api.search('');
    const deadline = Date.now() + 5000;
    while (!api.searchStatus.isComplete && Date.now() < deadline)
      await new Promise((resolve) => setTimeout(resolve, 10));
    if (!api.searchStatus.isComplete || api.searchStatus.foundCount !== 0 || api.stepSearch('older'))
      failures.push('search clear did not finish through the timer fallback');
    window.dispatchEvent = originalDispatch;
  }

  // A local program uses the page's real event handlers; embedding must never
  // need a second key decoder, selection handler or wheel convention.
  {
    const api = window.ubiquitty;
    const inputs = [], pastes = [];
    api.configure({ theme: 'Noir' });
    const intendedPalette = JSON.stringify(api.capture().palette);
    const savedPadding = localStorage.getItem('ubiquitty.padding');
    api.configure({ fontSize: 12, lineSpacing: 3, padding: 0, theme: 'Noir' });
    if (JSON.stringify(api.capture().palette) !== intendedPalette) failures.push('font configuration reset the chosen theme');
    if (localStorage.getItem('ubiquitty.padding') !== savedPadding) failures.push('embedding overwrote the saved padding');
    api.setLocalProgram({ input: bytes => inputs.push([...bytes]), paste: text => pastes.push(text) });
    api.feed('\x1b[2J\x1b[3J\x1b[H\x1b]2;Embedded program\x07hello world');
    if (api.metadata.programTitle !== 'Embedded program') failures.push('embedding metadata lost the program title');
    const before = JSON.stringify(api.capture().rows);
    const key = (key, code, extra = {}) => listeners.get('ime:keydown')({
      key, code, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false,
      isComposing: false, preventDefault() {}, stopPropagation() {}, ...extra,
    });
    for (const [name, code, extra] of [
      ['Control', 'ControlLeft', { ctrlKey: true }], ['Enter', 'Enter', {}], ['Tab', 'Tab', {}],
      ['a', 'KeyA', { ctrlKey: true }], ['k', 'KeyK', { ctrlKey: true }], ['p', 'KeyP', {}],
    ]) key(name, code, extra);
    if (JSON.stringify(inputs) !== JSON.stringify([[13], [9], [1], [11], [112]]))
      failures.push(`embedded keyboard bytes differed: ${JSON.stringify(inputs)}`);
    if (JSON.stringify(api.capture().rows) !== before) failures.push('embedded input echoed into the grid');
    let pasted = false;
    const clipboardText = 'ls\n\x1b[31m';
    listeners.get('ime:paste')({ clipboardData: {
      types: ['text/plain'], files: [], getData: () => clipboardText,
    }, preventDefault() { pasted = true; } });
    if (!pasted || pastes.length !== 1 || pastes[0] !== clipboardText)
      failures.push('native paste did not reach the local program as a separate intent');
    let prevented = false;
    listeners.get('ime:keydown')({key:'v',code:'KeyV',metaKey:true,ctrlKey:false,altKey:false,shiftKey:false,
      preventDefault() { prevented = true; },stopPropagation() {}});
    if (prevented) failures.push('Cmd+V prevented the native clipboard event');
    if (JSON.stringify(api.capture().rows) !== before) failures.push('native paste echoed into the grid');
    const columnWidth = parseFloat(elements.get('screen').style.width) / api.capture().rows[0].length;
    const click = { clientX: columnWidth * 7.5, clientY: 4, button: 0, buttons: 1, detail: 2,
      shiftKey:false,altKey:false,ctrlKey:false,metaKey:false,preventDefault() {} };
    listeners.get('screen:mousedown')(click);
    listeners.get('screen:mouseup')({...click,buttons:0});
    let copied = '';
    listeners.get('ime:copy')({clipboardData:{setData:(_type,text)=>{copied=text;}},preventDefault() {}});
    if (copied !== 'world') failures.push(`double-click copied ${JSON.stringify(copied)}, expected world`);
    const raster = api.snapshot();
    if (raster.width <= 0 || raster.pixels.length !== raster.width * raster.height * 4)
      failures.push('embedded snapshot has no complete raster');
    const first = raster.pixels[0];
    api.feed('\r\nnext frame');
    api.snapshot();
    if (raster.pixels[0] !== first) failures.push('snapshot aliases the next frame');
    let rejected = false;
    try { api.configure({ fontSize: NaN }); } catch { rejected = true; }
    if (!rejected) failures.push('invalid embedding font size was accepted');
    api.setLocalProgram(null);
  }

}

// --- The attached run -----------------------------------------------------
//
// What the page asks for in its Greet is decided in JavaScript, so no C++ test
// can see it: a request set by mistake would bind a workspace or claim the
// clipboard, and the page would still draw. The only place that is observable
// is the first write on the wire, which has to be the Greet alone: anything
// ahead of it is a frame before admission, and the host closes on it.
//
// This phase gets its own module instance and document, so the local page
// cannot keep painting over the attached page while these checks run.

if (phase === 'attached') {
  let greetFrame = null;
  let socketsOpened = 0;
  let lastSocket = null;
  // Every frame the page sends, not only the first. The embedder API section at the
  // end drives a second connect, and the Greet it produces is the only place the
  // session that connect asked for appears — a socket that was constructed proves
  // the wiring, not what it asked the host for.
  const sentFrames = [];
  // When set, new sockets never fire onopen — so the page stays detached for as
  // long as the test needs, instead of racing its own 250ms reconnect backoff.
  let refuseOpen = false;
  globalThis.WebSocket = class WebSocketStub {
    // The page gates every send on `socket.readyState !== WebSocket.OPEN`, which
    // reads the static off the class rather than the instance. A stub without it
    // compares against undefined and silently sends nothing.
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url) {
      this.url = url;
      this.readyState = 1;
      this.closeCalls = 0;
      socketsOpened += 1;
      lastSocket = this;
      // main() assigns onopen after constructing, so the open cannot be synchronous.
      if (!refuseOpen) setTimeout(() => { if (this.onopen) this.onopen(); }, 0);
    }
    send(bytes) {
      sentFrames.push(new Uint8Array(bytes));
      if (!greetFrame) greetFrame = sentFrames[sentFrames.length - 1];
    }
    close() { this.closeCalls += 1; }
  };
  // Seed a theme before the page loads. The restore runs once, just after
  // create(), so this is the only moment that can exercise it.
  const SEEDED_THEME = 'Nord';
  localStorage.setItem('ubiquitty.theme', SEEDED_THEME);
  // debug=1 so the page's own log is readable; the restore reports through it.
  window.location = { search: '?attach=ws://127.0.0.1:0/ws&debug=1' };
  globalThis.location = window.location;

  try {
    await import(`${path.join(dist, 'terminal.js')}?attached`);
  } catch (error) {
    console.error('page-smoke: FAILED');
    console.error(`  the attached page threw while loading: ${(error && error.message) || error}`);
    process.exit(1);
  }
  await new Promise((resolve) => setTimeout(resolve, 2500));

  if (!greetFrame) {
    failures.push('the attached page sent no Greet — the socket wiring did not reach a send');
  } else {
    const envelopes = envelopesIn(greetFrame);
    const expectedVersion = globalThis.window.ubiquitty.wireVersion;
    const greet = envelopes.length === 1 && envelopes[0].kind === 1 && envelopes[0].channel === 0
      ? readGreet(envelopes[0].body) : null;
    // Read the fields ahead of the one under test first. A layout change would
    // otherwise make this read some unrelated bytes and report them as a wrong
    // request, which sends the next reader to the wrong file.
    if (!greet || greet.wireVersion !== expectedVersion) {
      failures.push(`the first write is not one Greet in the expected layout (${envelopes.map((envelope) => envelope.kind).join(',')}, `
        + `version ${greet && greet.wireVersion}, page speaks ${expectedVersion}) — fix these offsets against putGreet`);
    } else {
      // The page states the version Core derived for the build, in the Greet and
      // on its own surface alike, and never the build identity.
      const pageVersion = globalThis.window.ubiquitty.appVersion;
      if (greet.appVersion !== pageVersion || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(\.[1-9]\d*)?$/.test(greet.appVersion))
        failures.push(`the Greet states app version '${greet.appVersion}' and the page '${pageVersion}' — both are Core's Sync::appVersion(), MAJOR.MINOR.PATCH[.N]`);
      if (!globalThis.window.ubiquitty.buildIdentity)
        failures.push('the page states no build identity');
      if (greet.target !== 0 || greet.workspaceName !== '' || greet.servesClipboard)
        failures.push(`a plain page's Greet asked for target ${greet.target}, workspace '${greet.workspaceName}', `
          + `clipboard serving ${greet.servesClipboard} — it neither carries a workspace, serves the clipboard nor administers the host`);
    }
  }

  // --- Reconnect ---------------------------------------------------------------
  //
  // A dropped socket must not leave the page dead until a reload, with the status
  // saying "detached" and nothing trying again. On a laptop that slept for a minute that
  // is the whole terminal gone, with no indication that reloading would fix it.
  //
  // The assertion is that a SECOND socket is constructed after a close. Checking
  // that onclose ran, or that the status text changed, would pass against a page
  // that gives up — the observable that matters is the reconnect actually being
  // attempted.
  if (!lastSocket) {
    failures.push('no socket was constructed, so the reconnect path cannot be exercised');
  } else {
    const before = socketsOpened;
    lastSocket.readyState = 3;
    if (lastSocket.onclose) lastSocket.onclose({ code: 1006 });
    // The first backoff is 250ms; allow generously for a loaded machine, and fail
    // rather than hang if it never comes.
    await new Promise((resolve) => setTimeout(resolve, 1200));
    if (socketsOpened <= before)
      failures.push(`the page did not reconnect after the socket closed (${socketsOpened} socket(s) opened, expected more than ${before})`);
  }

  // --- A stored theme is read back at startup ----------------------------------
  //
  // Seeding the store before the page loads is the whole test: the restore runs
  // once, just after create(), and a helper that cannot read the store at that
  // moment is indistinguishable from an empty store — a recall helper declared
  // below its first use throws a TDZ ReferenceError, and its own catch turns
  // that into ''.
  {
    // The page's own debug panel is the observable. Checking that the store still
    // holds the seeded value would pass either way — the restore never writes.
    const log = elementFor('debug').textContent || '';
    if (!log.includes(`theme restored: ${SEEDED_THEME}`)) {
      failures.push(`the page did not restore the stored theme "${SEEDED_THEME}" at startup — `
        + 'its recall helper is unreachable at the moment the restore runs, and its own catch turns that into ""');
    }
  }

  // --- A refused connection must back OFF, not hammer --------------------------
  //
  // The backoff must not reset in socket.onopen. A socket that OPENS and is then
  // refused — a stale token against a restarted host is the common one — would
  // reset the counter every cycle and retry at 250ms forever, reading as
  // "detached — reconnecting" flickering and never settling.
  //
  // This stub never sends a HelloAck, so every reconnect here is exactly that
  // case. The announced delay in the status line is the observable: it must GROW
  // across cycles. Asserting only "it reconnected" passes against the hammering,
  // which is the whole bug.
  {
    const delayFromStatus = () => {
      const match = /reconnecting in ([0-9.]+)s/.exec(elementFor('status').textContent || '');
      return match ? Number(match[1]) : -1;
    };
    const cycle = async () => {
      const before = socketsOpened;
      if (lastSocket) { lastSocket.readyState = 3; if (lastSocket.onclose) lastSocket.onclose({ code: 1006 }); }
      const announced = delayFromStatus();
      // A backoff above 900ms still owns the closed socket at that point.
      // Wait for its replacement before closing the next connection.
      for (let attempt = 0; attempt < 120 && socketsOpened === before; ++attempt)
        await new Promise((resolve) => setTimeout(resolve, 50));
      return announced;
    };

    refuseOpen = false;
    const first = await cycle();
    const second = await cycle();
    const third = await cycle();

    if (first < 0 || second < 0 || third < 0) {
      failures.push(`the status line never announced a reconnect delay (${first}, ${second}, ${third})`);
    } else if (!(third > first)) {
      failures.push(`a refused connection is not backing off: announced ${first}s, ${second}s, ${third}s — `
        + 'the counter is resetting on socket open rather than on the HelloAck');
    }
  }

  // --- Detached input must not fork the mirror ---------------------------------
  //
  // An attached client's grid is a MIRROR of the host's. Typing into it while the
  // socket is down forks it: the host never saw those bytes, so the next update
  // is applied against a baseline that no longer matches and patches the wrong
  // cells. A standalone page (no ?attach=) is the terminal and must still echo.
  //
  // Compare the captured grid. Cursor blink repaints an unchanged mirror, so a
  // paint count cannot distinguish a local echo from presentation alone.
  {
    const keydown = listeners.get('ime:keydown');
    if (!keydown) {
      failures.push('no ime:keydown listener — the detached-input check cannot run');
    } else {
      // The window that matters is the BACKOFF GAP, and it is narrow. `attach()`
      // assigns `socket` the moment it constructs one, so during a reconnect
      // attempt the page has a non-null socket that is not open yet and takes the
      // send path — where the frame is dropped on a readyState check. The local
      // feed is only reachable between onclose (which nulls it) and the next
      // attach, which is 250ms later.
      //
      // So the keystroke goes in SYNCHRONOUSLY after onclose, in the same tick,
      // while socket is still null. Waiting even one turn lands in the send path
      // and the check passes against the bug.
      refuseOpen = true;

      const before = JSON.stringify(window.ubiquitty.capture().rows);
      if (lastSocket) { lastSocket.readyState = 3; if (lastSocket.onclose) lastSocket.onclose({ code: 1006 }); }
      keydown({
        key: 'a', code: 'KeyA', keyCode: 65,
        ctrlKey: false, altKey: false, shiftKey: false, metaKey: false,
        isComposing: false,
        preventDefault() {}, stopPropagation() {},
      });
      await new Promise((resolve) => setTimeout(resolve, 300));
      if (JSON.stringify(window.ubiquitty.capture().rows) !== before)
        failures.push('a detached attached-client echoed a keystroke into the mirrored grid');
    }
  }

  // --- A refusal has to reach the screen ---------------------------------------
  //
  // The host refuses an attach for eight distinct reasons, and the one a browser
  // meets most is that nobody is attached to grant consent — a question for a
  // person at another screen, not a credential problem. The page carried its own
  // table of those reasons, written when five existed, and printed the raw wire
  // number for the three added since beside advice to reissue a token. Core owns
  // the wording now; what this asserts is that the page still puts it on screen,
  // which no C++ test can see.
  //
  // Last, because the verdict is sticky by design: it outranks the reconnect
  // countdown the section above reads, which is exactly the behaviour that keeps a
  // refusal from being erased a quarter-second after it arrives.
  {
    refuseOpen = false;
    window.ubiquitty.connect({ url: 'ws://127.0.0.1:0/refused', sessionID: 7 });
    await new Promise((resolve) => setTimeout(resolve, 60));
    // Layout source of truth: putBye in Messages.cpp. A host refuses an
    // admission with a Bye in place of the Welcome: [u8 reason][varint+bytes
    // detail][u8 hasPeer]. 17 is the consent refusal
    // (Protocol::Sync::ByeReason::NoConsent).
    const frame = typedFrame(10, 0, [17, ...wireText(''), 0]);
    if (!lastSocket || !lastSocket.onmessage) {
      failures.push('no socket with an onmessage handler — the refusal path cannot be exercised');
    } else {
      lastSocket.onmessage({ data: frame.buffer });
      await new Promise((resolve) => setTimeout(resolve, 300));
      const shown = elementFor('status').textContent || '';
      if (!shown.includes('allow'))
        failures.push(`a refusal for want of consent left the status line reading "${shown}" — `
          + 'the user is looking at a blank grid with nothing saying a person has to allow it');
      if (shown.includes('token'))
        failures.push(`the consent refusal blamed the token ("${shown}") — reissuing one cannot fix it`);
    }
  }

  // --- The embedder API --------------------------------------------------------
  //
  // A sidebar app that frames this page drives the connection from host-page code:
  // attach to a session, switch to another, open a new one. None of that is visible
  // to a C++ test — the object is assembled in JavaScript — and asserting that it
  // has the keys proves only that an object literal was written.
  //
  // So what is asserted is that a programmatic connect reaches a socket with the
  // url and the session id the caller passed, and that a programmatic detach takes
  // the RETRY down rather than leaving a timer armed that reopens the connection the
  // embedder closed.
  //
  // Last, because it ends the page detached: everything above needs the reconnect
  // loop the sections share.
  {
    const api = globalThis.window.ubiquitty;
    if (!api || typeof api.connect !== 'function' || typeof api.detach !== 'function') {
      failures.push('window.ubiquitty exposes no connect()/detach() — an embedder can reach this page only through '
        + 'the query string, which is read once at load and cannot switch sessions');
    } else {
      // `ready` is the only correct moment to call connect(), so a handle whose
      // promise never settles is one nobody can use. Raced against a timeout: an
      // await on a promise that never resolves hangs this file instead of failing
      // it, and a run CI kills at the time limit names nothing.
      const settled = await Promise.race([
        api.ready.then(() => 'resolved', (error) => `rejected: ${error && error.message}`),
        new Promise((resolve) => setTimeout(() => resolve('never settled'), 500)),
      ]);
      if (settled !== 'resolved')
        failures.push(`window.ubiquitty.ready ${settled} — an embedder waiting for the terminal waits forever`);

      // A socket opened by the API rather than by ?attach=. The url differs from the
      // query string's, so a connect that ignores its argument and reattaches to
      // whatever the page already held shows up here rather than passing.
      refuseOpen = false;
      const embedderUrl = 'ws://127.0.0.1:0/embedded';
      const requestedSession = 4242;
      sentFrames.length = 0;
      const before = socketsOpened;
      api.connect({ url: embedderUrl, token: 'embedder-token', sessionID: requestedSession });
      // The socket this connect produced, or null. Held rather than read back off
      // `lastSocket` at each step: the sections above leave one behind, and driving
      // that one would assert about a connection the API never opened — and a null
      // deref reports as an uncaught TypeError naming neither.
      const embedderSocket = socketsOpened > before ? lastSocket : null;
      if (!embedderSocket)
        failures.push(`ubiquitty.connect() constructed no socket (${socketsOpened} opened, expected more than ${before}) — `
          + 'an embedder cannot attach at all');
      else if (embedderSocket.url !== embedderUrl)
        failures.push(`ubiquitty.connect() opened ${JSON.stringify(embedderSocket.url)} rather than the url it was given`);

      if (embedderSocket) {
        for (const pending of [0, 2 * 1024 * 1024, 17, 0]) {
          embedderSocket.bufferedAmount = pending;
          if (api.bufferedAmount !== pending)
            failures.push(`the shared carrier reports ${api.bufferedAmount} queued bytes instead of ${pending}`);
        }
      }

      await new Promise((resolve) => setTimeout(resolve, 300));

      // The Greet this connect produced, found by KIND rather than by position: a
      // positional read would assert about whatever the page sends behind it —
      // and pass on a page that sent no Greet at all.
      const hello = lastGreet(sentFrames);
      if (!hello) {
        failures.push('the programmatic connect sent no Greet — nothing the embedder asked for reached the wire');
      } else if (hello.sessionID !== requestedSession) {
        failures.push(`the Greet asked for session ${hello.sessionID}, not the ${requestedSession} the embedder named — `
          + 'a sidebar switching servers would land on whichever session the tab last held');
      }

      if (embedderSocket && (api.connectionState === 'loading' || api.connectionState === 'detached'))
        failures.push(`ubiquitty.connectionState reads "${api.connectionState}" while a socket is open`);
      if (api.url !== embedderUrl)
        failures.push(`ubiquitty.url reads ${JSON.stringify(api.url)} rather than the url this page is attached to`);

      // The refusal the section above delivered belongs to the connection that
      // earned it. It is sticky by design — it outranks the reconnect countdown —
      // so one carried across a connect explains the old session's refusal over the
      // new session's screen.
      //
      // Asserted before the acknowledgement below, which is the whole window it
      // covers: Core's own notice is per-terminal and only a screen clears it, so
      // the next host frame restores the text. The window is what matters — it is
      // the one where a fresh session would present the previous session's refusal
      // as its own status.
      const shown = elementFor('status').textContent || '';
      if (shown.includes('consent'))
        failures.push(`a refusal from the previous connection is still on the status line after a connect: "${shown}"`);

      // The host admits the attach. Hand-built, like the refusal above, and
      // carrying the version the page itself announced — a hardcoded one would
      // meet Core's wire-version gate on the next bump and report the attach as
      // refused, which reads as a page defect.
      //
      // Without an admission there is no attached state to observe: the page
      // reports 'handshaking' and holds no session id, so the assertions that follow
      // it would pass on a page that never learns either — checks that could not
      // fail, which is worse than the gap they appear to close.
      if (hello && embedderSocket) {
        if (directoryCalls(sentFrames).length)
          failures.push('the page requested a directory before the typed Welcome');
        embedderSocket.onmessage({ data: typedWelcome(hello) });
        await new Promise((resolve) => setTimeout(resolve, 300));

        if (api.connectionState !== 'attached')
          failures.push(`an acknowledged attach reads as "${api.connectionState}" rather than attached — `
            + 'a sidebar cannot tell a live session from one still handshaking');
        if (api.sessionID !== requestedSession)
          failures.push(`ubiquitty.sessionID reads ${api.sessionID} rather than the ${requestedSession} the host acknowledged — `
            + 'an embedder has nothing to store for the reload that comes back to this shell');

        // The Welcome admits exactly one initial subscription.
        const askedOnAttach = directoryCalls(sentFrames);
        if (askedOnAttach.length !== 1)
          failures.push('an acknowledged attach asked for no session list — an embedded sidebar draws no rows until '
            + 'something asks, and a dropped ask is indistinguishable from a host holding no sessions');

        // Asking through the handle is a second wiring from answering through it:
        // the reader above and this one are installed into the same implementation
        // from inside main(), and a handle that lost this half throws where the
        // sidebar refreshes while every assertion above still passes.
        sentFrames.length = 0;
        let askFailure = '';
        try {
          api.requestSessions();
          const asked = directoryCalls(sentFrames);
          if (asked.length !== 1 || asked[0].id === askedOnAttach[0]?.id)
            askFailure = 'put no uniquely correlated directory Call on the wire';
        } catch (error) {
          askFailure = `threw (${(error && error.message) || error})`;
        }
        if (askFailure)
          failures.push(`ubiquitty.requestSessions() ${askFailure} — an embedder cannot refresh the host's session list`);
      }

      // A drop arms the backoff at its FIRST delay, because connect() resets the
      // counter — 250ms, short enough that the wait below is a real one. Left where
      // the sections above drove it, the capped 5s delay would sail past any wait
      // this file can afford and the assertion could not fail.
      if (embedderSocket) {
        embedderSocket.readyState = 3;
        if (embedderSocket.onclose) embedderSocket.onclose({ code: 1006 });
        if (api.connectionState !== 'reconnecting')
          failures.push(`a dropped socket reads as "${api.connectionState}" rather than reconnecting — `
            + 'an embedder cannot tell a retry in flight from a session it has to reopen');
      }

      api.detach();
      if (api.connectionState !== 'detached')
        failures.push(`ubiquitty.connectionState reads "${api.connectionState}" after detach()`);
      if (api.sessionID !== 0)
        failures.push(`ubiquitty.sessionID reads ${api.sessionID} after detach() — that id belongs to a connection that no longer exists`);

      const quiet = socketsOpened;
      const quietPaints = paints;
      await new Promise((resolve) => setTimeout(resolve, 900));
      if (socketsOpened > quiet)
        failures.push(`detach() left the reconnect timer armed (${socketsOpened} socket(s) opened, expected ${quiet}) — `
          + 'the page reopens the connection the embedder closed, and a sidebar that switched away gets two clients on one grid');

      // A page that has ever attached must not echo locally after a DETACH either.
      // The host's cells are still on screen, so a keystroke fed into them forks the
      // baseline the next update patches against — and the section above tests only
      // the reconnect gap, where the page still holds its attach state. A gate keyed
      // on that state rather than on the mirror passes there and fails here, which is
      // exactly what an embedder-driven detach produces.
      for (const mutate of [() => api.feed('forged output'), () => api.setLocalProgram({ input() {}, paste() {} })]) {
        let rejected = false;
        try { mutate(); } catch { rejected = true; }
        if (!rejected) failures.push('a detached host mirror accepted a local program mutation');
      }

      const keydownWhileDetached = listeners.get('ime:keydown');
      if (!keydownWhileDetached) {
        failures.push('no ime:keydown listener — the detached-embedder echo check cannot run');
      } else {
        const drift = paints - quietPaints; // repaints across the quiet window above
        const beforeKey = paints;
        keydownWhileDetached({
          key: 'b', code: 'KeyB', keyCode: 66,
          ctrlKey: false, altKey: false, shiftKey: false, metaKey: false,
          isComposing: false,
          preventDefault() {}, stopPropagation() {},
        });
        await new Promise((resolve) => setTimeout(resolve, 300));
        if (paints - beforeKey > drift)
          failures.push(`a detached embedder page echoed a keystroke into the host's grid `
            + `(${paints - beforeKey} paint(s) against a ${drift}-paint quiet baseline) — that forks the mirror`);
      }
    }
  }

  // A queued callback belongs to the socket that installed it, even after a
  // detach or replacement. It must neither feed old bytes into the new Core
  // connection nor close/clear the new transport or change its status.
  {
    const api = window.ubiquitty;
    api.connect({ url: 'ws://127.0.0.1:0/stale', sessionID: 11 });
    await new Promise((resolve) => setTimeout(resolve, 60));
    const oldSocket = lastSocket;
    const callbacks = {
      open: oldSocket.onopen, message: oldSocket.onmessage,
      error: oldSocket.onerror, close: oldSocket.onclose,
    };
    // 0x84 is a kind no envelope has, so Core refuses it as a protocol fault
    // rather than ignoring it as an extension.
    const refusedFrame = { data: new Uint8Array([0x84, 0, 0, 0, 0]).buffer };
    const invoke = (name, event) => {
      try { callbacks[name](event); }
      catch (error) { failures.push(`a retired socket's ${name} callback threw: ${error.message}`); }
    };
    api.detach();
    invoke('message', refusedFrame);
    if (api.connectionState !== 'detached') failures.push('a retired message resurrected a detached connection');

    const replacementURL = 'ws://127.0.0.1:0/replacement';
    api.connect({ url: replacementURL, sessionID: 12 });
    await new Promise((resolve) => setTimeout(resolve, 60));
    const replacement = lastSocket;
    const framesBefore = sentFrames.length;
    const statusBefore = elementFor('status').textContent;
    const readsBefore = elementFor('debug').dataset.rx;
    invoke('open');
    invoke('message', refusedFrame);
    invoke('error');
    invoke('close', { code: 1006 });
    if (sentFrames.length !== framesBefore) failures.push('a retired socket sent frames on its replacement');
    if (replacement.closeCalls) failures.push('a retired socket closed its replacement');
    if (api.url !== replacementURL || api.connectionState !== 'handshaking')
      failures.push('a retired socket changed the replacement connection state');
    if (elementFor('status').textContent !== statusBefore) failures.push('a retired socket changed the replacement status');
    if (elementFor('debug').dataset.rx !== readsBefore) failures.push('a retired socket delivered bytes to Core');
    try { replacement.onmessage(refusedFrame); }
    catch (error) { failures.push(`the current socket's protocol-fault callback threw: ${error.message}`); }
    if (replacement.closeCalls !== 1) failures.push('a current protocol fault did not close exactly its own socket');
    if (!elementFor('status').textContent.includes('protocol fault')) failures.push('a current protocol fault was hidden');
    api.detach();
  }

  // --- the connect rule -------------------------------------------------------
  //
  // The pairing must not be written at admission, before the rule reads it:
  // `decideAttach` would see the session this handshake had just made and could
  // only ever confirm the session it was already on. What that costs a person is
  // a fresh tab opening a new shell instead of returning to the one they left.
  //
  // Asserted on the WRITE and not on the value. A value comparison cannot see the
  // defect on a host with no record yet — a write of an empty record
  // removes a key that was never there, so before and after are both absent and
  // the check passes while the page is wrong.
  //
  // Driven through a host that answers: the Welcome is built to the layout
  // putWelcome in Messages.cpp writes, which is the source of truth, and names
  // the session the Greet asked for.
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
    const identity = (low, high) => [...littleEndian(low, 8), ...littleEndian(high, 8)];
    // This section needs its own live handshake, not the retired callback left
    // behind by the detach assertions above.
    const firstFrame = sentFrames.length;
    window.ubiquitty.connect({ url: 'ws://127.0.0.1:0/pairing', sessionID: 4242 });
    await new Promise((resolve) => setTimeout(resolve, 60));
    if (!lastSocket || !lastSocket.onmessage) {
      failures.push('no socket with a message handler — the connect rule could not be driven');
    } else {
      const touchesBefore = hostRecordTouches.length;
      const greet = lastGreet(sentFrames.slice(firstFrame));
      if (!greet) throw new Error('the fixture expected a Greet');
      const primary = greet.clientInstance;
      lastSocket.onmessage({ data: Uint8Array.from([
        ...typedWelcome(greet), ...typedFrame(7, 0, [...variable(1), ...identity(4242, fixtureDaemonInstanceID)]),
      ]) });
      // Hidden, the fixture holds every animation frame, so the bell has to be
      // reported without one.
      document.visibilityState = 'hidden';
      listeners.get('document:visibilitychange')();
      // Typed Bell: generation zero depends on the initial picture; sequence one
      // belongs to this exact bound pane and the client elected by its Greet.
      const bell = [...littleEndian(0, 8), ...littleEndian(1, 8), ...primary, 0, ...littleEndian(1, 4)];
      const packet = [...littleEndian(0, 8), ...littleEndian(1, 8), ...littleEndian(0, 2), ...bell];
      lastSocket.onmessage({ data: typedFrame(50, 1, packet) });
      if (!document.title.startsWith('🔔 ')) {
        failures.push('a hidden tab did not report the host bell without an animation frame');
      }
      document.visibilityState = 'visible';
      listeners.get('document:visibilitychange')();
      if (document.title.startsWith('🔔 ')) {
        failures.push('returning to the tab did not clear its unheard bell');
      }
      const written = hostRecordTouches.slice(touchesBefore);
      // No listing has arrived, so the rule has not run and nothing may have
      // moved the record it is going to read.
      if (written.length) {
        failures.push(
          'the pairing was written at the Welcome, before the connect rule read it: '
            + `${written.join(', ')} — the rule then reads back the session this `
            + 'handshake just made and confirms the one it is already on'
        );
      }
    }
  }

  // --- the session panel ------------------------------------------------------
  //
  // The panel is the one part of this page no C++ test reaches: WebTerminal
  // answers what the rows should say, and the drawing of them is JavaScript. A
  // row that dropped a fact, a Terminate that fired on its first click, or a
  // refusal shown as this page's own words rather than the host's would all pass
  // every test that existed before this one.
  //
  // A correlated Result promises exact structure and facts revisions. The page
  // must wait for those records, then draw Core's outline of the tree they make:
  // a workspace of one pane is one row standing for its pane.
  {
    const AT_PROMPT = 0x01;
    const ENDS_WHEN_DETACHED = 0x02;
    const rows = [
      {
        id: 7, columns: 120, rows: 40, flags: 0, title: 'vim README.md',
        cwd: '~/Projects/ubiquitty', process: 'vim',
        workspaceID: 3, workspaceName: 'review', attendees: 2, humans: 1,
      },
      {
        id: 9, columns: 80, rows: 24, flags: AT_PROMPT | ENDS_WHEN_DETACHED, title: 'zsh',
        cwd: '/home/someone', process: 'zsh',
        workspaceID: 0, workspaceName: '', attendees: 0, humans: 0,
      },
    ];
    // A connection of this section's own. By here the file has driven a refusal
    // and an embedder detach through the page, and a listing fed into whatever
    // that left is a listing fed into a state no person is ever in.
    const PANEL_HOST = 'ws://127.0.0.1:0/panel';
    if (globalThis.window && window.ubiquitty && window.ubiquitty.connect) {
      window.ubiquitty.connect({ url: PANEL_HOST });
      await new Promise((resolve) => setTimeout(resolve, 60));
      if (lastSocket && lastSocket.onmessage) {
        lastSocket.onmessage({ data: typedWelcome(lastGreet(sentFrames), 31) });
        await new Promise((resolve) => setTimeout(resolve, 80));
      }
    }
    let requestID = '';
    if (globalThis.window && window.ubiquitty && window.ubiquitty.requestSessions) {
      const before = sentFrames.length;
      window.ubiquitty.requestSessions();
      await new Promise((resolve) => setTimeout(resolve, 60));
      requestID = directoryCalls(sentFrames.slice(before)).at(-1)?.id || '';
    }
    if (!requestID) {
      failures.push('the page sent no typed directory Call, so its answer could not be built');
    }

    const panel = document.getElementById('session-rows');
    // What the page DECODED, straight from the event it fires for embedders.
    // Without this, "no rows" cannot be told from "no listing got through", and
    // the status line is no help: an earlier section in this file feeds an
    // AUTH_DENIED, so its refusal is still standing here.
    let decodedOutline = null;
    const outlineListener = window.addEventListener
      ? (event) => { decodedOutline = (event && event.detail) || { rows: [] }; }
      : null;
    if (outlineListener) window.addEventListener('ubiquitty-outline', outlineListener);
    if (!lastSocket || !lastSocket.onmessage) {
      failures.push('no socket with a message handler — the session panel could not be fed');
    } else {
      lastSocket.onmessage({ data: directoryAnswer(requestID, rows) });
      await new Promise((resolve) => setTimeout(resolve, 60));
      if (decodedOutline !== null && decodedOutline.rows.length !== 0)
        failures.push('the directory promise drew rows before its records arrived');
      const callsBeforeRecords = directoryCalls(sentFrames).length;
      for (const record of directoryRecords(rows)) lastSocket.onmessage({ data: record });
      if (directoryCalls(sentFrames).length !== callsBeforeRecords)
        failures.push('a directory record repeated the initial subscription');
      await new Promise((resolve) => setTimeout(resolve, 150));

      const drawn = panel.children || [];
      if (drawn.length !== rows.length) {
        // The page's own verdict on the bytes, because "no rows" has two very
        // different causes: a listing it rejected, and a listing it drew nothing
        // for. The first shows here as a protocol fault.
        const decoded = decodedOutline === null ? 'no outline reached the page' : `${decodedOutline.rows.length} decoded`;
        failures.push(
          `the panel drew ${drawn.length} row(s) for a host of ${rows.length} one-pane workspaces — ${decoded}`
        );
      } else {
        // Read as one string per row, because which span carries which fact is
        // outline.js's business and its own test pins that.
        const textOf = (element) => {
          const own = element.textContent || '';
          const kids = (element.children || []).map(textOf).join(' ');
          return `${own} ${kids}`.trim();
        };
        const named = drawn.find((row) => /review/.test(textOf(row)));
        const unnamed = drawn.find((row) => row !== named);
        if (!named) {
          failures.push(`no row is the review workspace — the panel drew: ${drawn.map(textOf).join(' | ')}`);
        } else {
          for (const wanted of ['review', '~/Projects/ubiquitty', '120x40']) {
            if (!textOf(named).includes(wanted))
              failures.push(`the review row does not show ${JSON.stringify(wanted)} — it drew: ${textOf(named)}`);
          }
        }
        if (unnamed) {
          for (const wanted of ['/home/someone', '80x24', 'ends when detached']) {
            if (!textOf(unnamed).includes(wanted))
              failures.push(`the unnamed row does not show ${JSON.stringify(wanted)} — it drew: ${textOf(unnamed)}`);
          }
        }

        // The destructive action asks Core's question first. A Terminate that
        // sent on one click would end somebody's shell on a mis-click, and the
        // question is the whole of what stands between.
        const actions = named && (named.children || []).find((child) => child.className === 'actions');
        const terminate = ((actions && actions.children) || [])
          .find((child) => /^Terminate /.test(((child.attributes || {})['aria-label']) || ''));
        const question = ((actions && actions.children) || []).find((child) => child.className === 'question');
        if (!terminate || !question) {
          failures.push('the review row offers no Terminate carrying its own name, or nowhere to ask');
        } else {
          const framesBefore = sentFrames.length;
          terminate.handlers.get('click')();
          if (sentFrames.length !== framesBefore) {
            failures.push('the first click on Terminate sent a frame — nothing was asked');
          }
          const asked = textOf(question);
          if (question.hidden || !/Terminate review/.test(asked) || !/Running: vim/.test(asked)) {
            failures.push(`Terminate did not ask Core's question naming the workspace and what runs in it — it reads ${JSON.stringify(asked)}`);
          }
          const answers = (question.children || []).filter((child) => child.dataset && child.dataset.role);
          const keep = answers.find((child) => child.dataset.role === 'safeDefault');
          const end = answers.find((child) => child.dataset.role === 'destructive');
          if (!keep || !end) {
            failures.push('the question offers no safe answer and destructive answer');
          } else {
            keep.handlers.get('click')();
            if (sentFrames.length !== framesBefore || !question.hidden)
              failures.push('keeping the workspace sent a frame or left the question up');
            terminate.handlers.get('click')();
            const endAgain = (question.children || []).find((child) => child.dataset && child.dataset.role === 'destructive');
            endAgain.handlers.get('click')();
            if (sentFrames.length === framesBefore) {
              failures.push('answering the question yes sent nothing — the ask cannot be completed');
            }
            const operation = directoryCalls(sentFrames.slice(framesBefore), 'session.terminate').at(-1);
            if (!operation || operation.params?.session !== 7 || typeof operation.id !== 'string') {
              failures.push('Terminate did not send one correlated typed call for the workspace\'s session');
            } else {
              const response = JSON.stringify({ jsonrpc: '2.0', id: operation.id, result: { session: 7, outcome: 'denied' } });
              lastSocket.onmessage({ data: typedFrame(14, 0, [0, ...textBytes(response)]) });
              await new Promise((resolve) => setTimeout(resolve, 60));
              if (!/declined/.test(textOf(elementFor('sessions-outcome')))) {
                failures.push('the exact typed denial did not settle the named termination');
              }
            }
          }
        }
      }
    }
  }
}

if (failures.length) {
  console.error('page-smoke: FAILED');
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
console.log(`page-smoke: ok (${phase}; ${paints} paints, ${listeners.size} listeners, ${wiring.length} wirings)`);
process.exit(0);
