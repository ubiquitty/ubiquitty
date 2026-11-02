// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// reload-resume.mjs — the page across a reload, against a live host.
//
// Two node processes stand for one tab loaded twice; the tab's session storage
// is carried between them in a file, as the browser keeps it across a reload.
// The first page attaches, puts a marker on the screen, starts a line that
// prints with no input after the record was last written and another that
// prints while no page is attached, and is hidden and unloaded. The second
// page installs the stored record before its first socket exists, says it is
// reconnecting over the stored picture, greets as the same client instance,
// and is attached to the same session; Core rewrites the record for the fresh
// secret. That the host continues with a diff rather than a checkpoint is
// asserted in C++ (test_web_terminal: aReloadedPageDrawsItsStoredPictureFirst
// AndResumesDiffed); this probe asserts the page's half: the storage keys,
// the order, and the identity.
//
//   UBQ_ATTACH_URL=ws://… UBQ_ATTACH_TOKEN=… node Tests/Web/reload-resume.mjs <dist>
//
// Run through Tests/test-web-live-probe.sh, which stands up the host. With no
// UBQ_RELOAD_PHASE the probe runs both pages itself, one process each.

import { spawnSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { installStubDom, elementFor, listeners } from './stub-dom.mjs';

const dist = path.resolve(process.argv[2] ?? 'build/web-dist');
const attachUrl = process.env.UBQ_ATTACH_URL;
const token = process.env.UBQ_ATTACH_TOKEN || '';
if (!attachUrl) {
  console.error('usage: UBQ_ATTACH_URL=ws://… [UBQ_ATTACH_TOKEN=…] node Tests/Web/reload-resume.mjs <dist>');
  process.exit(2);
}
if (!process.env.UBQ_RELOAD_PHASE) {
  const directory = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'ubq-reload-'));
  let status = 0;
  for (const phase of ['first', 'second']) {
    const run = spawnSync(process.execPath, [fileURLToPath(import.meta.url), dist], {
      stdio: 'inherit',
      env: { ...process.env, UBQ_RELOAD_PHASE: phase, UBQ_RELOAD_STORAGE: path.join(directory, 'session-storage.json') },
    });
    if (run.status !== 0) { status = 1; break; }
  }
  fs.rmSync(directory, { recursive: true, force: true });
  process.exit(status);
}
const storageFile = process.env.UBQ_RELOAD_STORAGE;
const phase = process.env.UBQ_RELOAD_PHASE;

installStubDom(dist);
const stored = fs.existsSync(storageFile) ? JSON.parse(fs.readFileSync(storageFile, 'utf8')) : [];
for (const [key, value] of stored) sessionStorage.setItem(key, value);

const failures = [];
const check = (ok, what) => {
  console.log(`reload-resume ${phase}: ${ok ? '' : 'FAILED: '}${what}`);
  if (!ok) failures.push(what);
};

// The status line at the moment the page builds its first socket: the order
// the stored picture and the connection come in.
const opened = [];
let statusAtFirstSocket = null;
const RealWebSocket = globalThis.WebSocket;
globalThis.WebSocket = class extends RealWebSocket {
  constructor(...a) {
    if (statusAtFirstSocket === null) statusAtFirstSocket = elementFor('status').textContent;
    super(...a);
    this.binaryType = 'arraybuffer';
    opened.push(this);
  }
};

const resumeKey = `ubiquitty.resume.${attachUrl}`;
const clientKey = `ubiquitty.client.${attachUrl}`;
const storedRecord = sessionStorage.getItem(resumeKey);
const storedClient = sessionStorage.getItem(clientKey);

window.location = { search: `?attach=${encodeURIComponent(attachUrl)}&token=${encodeURIComponent(token)}` };
globalThis.location = window.location;
await import(`${path.join(dist, 'terminal.js')}?reload-${phase}`);
await new Promise((resolve) => setTimeout(resolve, 4000));

const state = () => ({ connectionState: window.ubiquitty ? window.ubiquitty.connectionState : 'none', sessionID: window.ubiquitty ? window.ubiquitty.sessionID : 0 });
const keydown = listeners.get('ime:keydown');
const press = (key, code) => keydown({
  key, code, keyCode: 0, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false,
  isComposing: false, preventDefault() {}, stopPropagation() {},
});

if (phase === 'first') {
  check(storedRecord === null && storedClient === null, 'the tab started with nothing stored');
  check(state().connectionState === 'attached', `the page attached (${JSON.stringify(state())})`);
  check(/^[0-9a-f]{32}$/.test(sessionStorage.getItem(clientKey) || ''), 'the window kept its client instance');
  check(Boolean(sessionStorage.getItem(resumeKey)), 'the record was written at the Welcome, before any input');
  for (const character of "echo BEFORE-THE-REL''OAD; (sleep 1; echo SHOWN-BEFORE-UNLOA''DING; sleep 3; echo WHILE-THE-PAGE-WAS-GO''NE) &") press(character, '');
  press('Enter', 'Enter');
  // The record is written as input goes out, and not for output alone: past
  // the line that prints a second after the last key, the picture on screen
  // is newer than the stored one.
  await new Promise((resolve) => setTimeout(resolve, 2000));
  const beforeUnloading = sessionStorage.getItem(resumeKey);
  // The tab is hidden and unloaded: the record keeps the newest picture.
  const pagehide = listeners.get('window:pagehide');
  check(Boolean(pagehide), 'the page listens for being unloaded');
  if (pagehide) pagehide({});
  check(sessionStorage.getItem(resumeKey) !== beforeUnloading, 'unloading stored the newer picture');
  fs.writeFileSync(storageFile, JSON.stringify([...sessionStorage.store.entries()]));
  for (const socket of opened) socket.close();
} else {
  check(Boolean(storedRecord) && Boolean(storedClient), 'the reloaded tab holds a record and an instance');
  check(statusAtFirstSocket === 'reconnecting…', `the stored picture was up before the first socket (status "${statusAtFirstSocket}")`);
  check(state().connectionState === 'attached', `the page attached (${JSON.stringify(state())})`);
  check(sessionStorage.getItem(clientKey) === storedClient, 'the page kept the stored client instance');
  const rewritten = sessionStorage.getItem(resumeKey);
  check(Boolean(rewritten) && rewritten !== storedRecord, 'the record was rewritten for the fresh secret');
  for (const character of 'exit') press(character, '');
  press('Enter', 'Enter');
  await new Promise((resolve) => setTimeout(resolve, 1500));
  for (const socket of opened) socket.close();
}

process.exit(failures.length === 0 ? 0 : 1);
