// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// refused-reconnect.mjs — a host that says no does not get asked four times a
// second.
//
// The page reconnects on a backoff that doubles to five seconds, and resets that
// backoff when a connection completes its handshake. Which means the reset has
// to be keyed on something the current connection makes true and its predecessor
// does not, or a refused reconnect resets the backoff it exists to grow and the
// page retries at 250 ms for as long as the host keeps refusing.
//
// The trap is that the session id looks like that signal and is not. Core keeps
// it across a reconnect on purpose — it separates "never attached" from
// "attached, then dropped", and it is what the next HELLO asks to reattach to —
// so between building a HELLO and receiving its answer the accessor still holds
// the id of the connection before. A refused reconnect reading it first adopts a
// session the host has just declined to give it, resets the backoff, and writes
// the dead id to localStorage for the next attempt to ask for.
//
// So the probe refuses. It attaches, revokes the token underneath the page, and
// drops the socket. Every reconnect from there is answered AUTH_DENIED, and what
// is measured is how many the page makes: a backoff that grows fits about six
// into ten seconds, and one that resets fits forty.
//
// The count, not the timing of any one attempt. A machine under load delays a
// single reconnect and would fail an assertion about when the third arrived; it
// does not turn forty attempts into six.
//
//   UBQ_ATTACH_URL=ws://… UBQ_ATTACH_TOKEN=… UBQ_HOST_BINARY=… UBIQUITTY_HOME=… \
//     node Tests/Web/refused-reconnect.mjs [dist-dir]

import fs from 'fs';
import path from 'path';
import { execFileSync } from 'child_process';

const dist = path.resolve(process.argv[2] ?? 'build/web-dist');
if (!fs.existsSync(path.join(dist, 'terminal.js'))) {
  console.error(`refused-reconnect: no built page at ${dist} — run Scripts/build-web.sh first`);
  process.exit(2);
}

// --- The stub DOM ---------------------------------------------------------
//
// One file for every probe here; see Tests/Web/stub-dom.mjs for what a copy per
// probe cost when the copies drifted.
import { installStubDom } from './stub-dom.mjs';

installStubDom(dist);

const attachUrl = process.env.UBQ_ATTACH_URL;
const token = process.env.UBQ_ATTACH_TOKEN;
const hostBinary = process.env.UBQ_HOST_BINARY;
const hostHome = process.env.UBIQUITTY_HOME;
if (!attachUrl || !token || !hostBinary || !hostHome) {
  console.error('usage: UBQ_ATTACH_URL=ws://… UBQ_ATTACH_TOKEN=… UBQ_HOST_BINARY=… '
    + 'UBIQUITTY_HOME=… node Tests/Web/refused-reconnect.mjs [dist-dir]');
  process.exit(2);
}

// Every socket the page opened, with the moment it was opened. The page is the
// only thing constructing these, so the array is its reconnect record.
const opened = [];
const start = Date.now();
const RealWebSocket = globalThis.WebSocket;
globalThis.WebSocket = class extends RealWebSocket {
  constructor(...a) {
    super(...a);
    this.binaryType = 'arraybuffer';
    opened.push({ socket: this, atMilliseconds: Date.now() - start });
  }
};

window.location = { search: `?attach=${encodeURIComponent(attachUrl)}&token=${encodeURIComponent(token)}` };
globalThis.location = window.location;

await import(`${path.join(dist, 'terminal.js')}?refused`);
await new Promise((r) => setTimeout(r, 4000));

if (opened.length === 0) {
  console.error('refused-reconnect: the page never opened a socket');
  process.exit(1);
}
const sessionKey = [...localStorage.store.keys()].find((k) => k.startsWith('ubiquitty.host.'));
const sessionWhileAllowed = sessionKey ? localStorage.getItem(sessionKey) : null;
if (!sessionWhileAllowed) {
  console.error('refused-reconnect: the page never attached, so there is no refusal to observe');
  process.exit(1);
}

// Revoke underneath the page. The daemon and the session stay up: what changes
// is that this page's token no longer authenticates, which is the common shape
// — a token revoked or expired while a laptop was asleep — and it refuses
// without the session vanishing, so the id the page holds stays plausible.
const listing = execFileSync(hostBinary, ['token', 'list'], {
  env: { ...process.env, UBIQUITTY_HOME: hostHome }, encoding: 'utf8',
});
const ids = listing.split('\n').slice(1).map((l) => l.trim().split(/\s+/)[0]).filter(Boolean);
for (const id of ids)
  execFileSync(hostBinary, ['token', 'revoke', id], { env: { ...process.env, UBIQUITTY_HOME: hostHome } });

const refusalWindowMilliseconds = 10000;
const beforeRefusals = opened.length;
opened[opened.length - 1].socket.close();
await new Promise((r) => setTimeout(r, refusalWindowMilliseconds));

const attempts = opened.length - beforeRefusals;
const sessionAfter = sessionKey ? localStorage.getItem(sessionKey) : null;

// Six is what a doubling backoff from 250 ms reaches in ten seconds, with room
// for a machine that ran a couple early. Forty is what 250 ms flat reaches. The
// threshold sits far from both rather than next to either.
const attemptsThatFitABackoff = 12;
const verdict = {
  attemptsWhileRefused: attempts,
  budget: attemptsThatFitABackoff,
  openedAtMilliseconds: opened.slice(beforeRefusals).map((o) => o.atMilliseconds),
  sessionWhileAllowed,
  sessionAfter,
};

if (attempts === 0) {
  console.error('refused-reconnect: the page stopped reconnecting entirely, so the backoff is '
    + 'not what this measured', JSON.stringify(verdict));
  process.exit(1);
}
if (attempts > attemptsThatFitABackoff) {
  console.error('refused-reconnect: FAILED — the page retried a refusing host '
    + `${attempts} times in ${refusalWindowMilliseconds / 1000}s, which is the backoff resetting `
    + 'on a handshake that never completed', JSON.stringify(verdict));
  process.exit(1);
}
console.log(`refused-reconnect: ok (${attempts} attempt(s) in ${refusalWindowMilliseconds / 1000}s `
  + 'against a host refusing every one, so the backoff grew)', JSON.stringify(verdict));
process.exit(0);
