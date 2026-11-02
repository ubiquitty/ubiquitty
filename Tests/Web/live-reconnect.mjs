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

const dist = path.resolve(process.argv[2] ?? 'build/web-dist');
if (!fs.existsSync(path.join(dist, 'terminal.js'))) {
  console.error(`page-smoke: no built page at ${dist} — run Scripts/build-web.sh first`);
  process.exit(2);
}

// --- The stub DOM ---------------------------------------------------------
//
// One file for every probe here; see Tests/Web/stub-dom.mjs for what a copy per
// probe costs when the copies drift: a page that throws inside a stale fixture
// reads as a page that never opens a socket.
import { installStubDom, elementFor, elements, listeners, paints } from './stub-dom.mjs';

installStubDom(dist);


// --- The run --------------------------------------------------------------

const failures = [];
process.on('uncaughtException', (error) => failures.push(`uncaught: ${error.message}`));
process.on('unhandledRejection', (error) => failures.push(`unhandled rejection: ${error && error.message}`));


// --- live reconnect, real socket, real timers --------------------------------
//
// page-smoke proves a second socket is CONSTRUCTED after a close, against a
// stub. This proves the reattach LANDS against a running host: same session id,
// a live socket again, host bytes flowing.
//
// Headless Chrome cannot answer this. --virtual-time-budget fast-forwards
// timers but does not advance real network I/O, so the handshake never
// completes and the close never fires: the page sits at "attached —
// handshaking" and the probe reports a failure that is entirely its own.
// Env rather than argv: the stub head this file is built on already takes the
// dist directory as argv[2].
const attachUrl = process.env.UBQ_ATTACH_URL;
const token = process.env.UBQ_ATTACH_TOKEN;
if (!attachUrl) {
  console.error('usage: UBQ_ATTACH_URL=ws://… [UBQ_ATTACH_TOKEN=…] node Tests/Web/live-reconnect.mjs');
  process.exit(2);
}

const opened = [];
const RealWebSocket = globalThis.WebSocket;
globalThis.WebSocket = class extends RealWebSocket {
  constructor(...a) { super(...a); this.binaryType = 'arraybuffer'; opened.push(this); }
};

window.location = { search: `?attach=${encodeURIComponent(attachUrl)}&token=${encodeURIComponent(token || '')}` };
globalThis.location = window.location;

await import(`${path.join(dist, 'terminal.js')}?live`);
await new Promise((r) => setTimeout(r, 4000));

const before = opened.length;
// The tab's session id, by its own key: the tab keeps other records beside it.
const sessionKey = () => [...sessionStorage.store.keys()].find((key) => key.startsWith('ubiquitty.session.')) || '';
const sessionBefore = sessionStorage.getItem(sessionKey());
if (before === 0) { console.error('live-reconnect: the page never opened a socket'); process.exit(1); }

opened[opened.length - 1].close();
await new Promise((r) => setTimeout(r, 8000));

const sessionAfter = sessionStorage.getItem(sessionKey());
const live = opened.filter((s) => s.readyState === 1).length;
const verdict = {
  socketsOpened: opened.length, before, liveNow: live,
  session: sessionBefore, sessionAfter,
};
if (opened.length > before && live > 0 && sessionAfter === sessionBefore) {
  console.log('live-reconnect: RECONNECTED', JSON.stringify(verdict));
  process.exit(0);
}
console.error('live-reconnect: FAILED', JSON.stringify(verdict));
process.exit(1);
