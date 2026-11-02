// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Runs the actual page/WASM and WebSocket against an explicitly selected test
// host. The caller owns that host; this test never finds or starts a daemon.
// UBQ_ATTACH_URL=ws://... UBQ_ATTACH_TOKEN_FILE=/private/token node live-resize.mjs DIST
// UBQ_ATTACH_SESSION selects an existing task-owned session. With a token that
// lacks Drive, UBQ_RESIZE_EXPECT_DENIED=1 checks refusal without disconnect.
import fs from 'fs';
import path from 'path';
import { installStubDom, elementFor, listeners } from './stub-dom.mjs';

const dist = path.resolve(process.argv[2] ?? '');
const url = process.env.UBQ_ATTACH_URL;
const tokenFile = process.env.UBQ_ATTACH_TOKEN_FILE;
if (!url || !tokenFile || !fs.existsSync(path.join(dist, 'terminal.js')))
  throw new Error('live-resize requires an explicit test URL, token file and staged page');
const token = fs.readFileSync(tokenFile, 'utf8').trim();
const targetSession = Number(process.env.UBQ_ATTACH_SESSION || 0);
const expectsDenial = process.env.UBQ_RESIZE_EXPECT_DENIED === '1';
if (!Number.isInteger(targetSession) || targetSession < 0 || targetSession > 0xffffffff
    || (expectsDenial && targetSession === 0))
  throw new Error('denied resize requires an explicit existing task-owned session');
installStubDom(dist);
const sockets = [];
const closes = [];
const received = [];
const overrides = [];
const NativeWebSocket = globalThis.WebSocket;
globalThis.WebSocket = class extends NativeWebSocket {
  constructor(address) {
    super(address);
    sockets.push(this);
    this.addEventListener('close', event => closes.push(event.code));
    this.addEventListener('message', event => {
      const bytes = new Uint8Array(event.data);
      received.push({ bytes: bytes.length, prefix: Array.from(bytes.slice(0, 12)) });
    });
  }

  send(data) {
    const text = new TextDecoder().decode(data);
    for (const match of text.matchAll(/"method":"pane.overrideGeometry","params":\{"pane":\d+,"rows":(\d+),"columns":(\d+)\}/g))
      overrides.push({ rows: Number(match[1]), columns: Number(match[2]) });
    return super.send(data);
  }
};
window.location = { search: '?debug=1&keepunnamed=1' };
globalThis.location = window.location;
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
async function waitFor(predicate, description) {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(25);
  }
  throw new Error(`${description}: ${window.ubiquitty.connectionState}; ${elementFor('status').textContent}`);
}

try {
  await import(path.join(dist, 'terminal.js'));
  await window.ubiquitty.ready;
  window.ubiquitty.connect({ url, token, sessionID: targetSession });
  await waitFor(() => window.ubiquitty?.connectionState === 'attached', 'initial attach');
  const sessionID = window.ubiquitty.sessionID;
  const original = sockets[0];
  window.ubiquitty.requestSessions();
  await waitFor(() => window.ubiquitty.sessions().some(row => row.id === sessionID), 'initial listing');
  const initial = window.ubiquitty.sessions().find(row => row.id === sessionID);
  const sizes = [[1100, 720], [640, 480], [1280, 800], [800, 600]];
  for (const [width, height] of sizes) {
    const previousOverrides = overrides.length;
    window.innerWidth = width;
    window.innerHeight = height;
    listeners.get('window:resize')();
    await delay(800);
    window.ubiquitty.requestSessions();
    await delay(150);
    if (sockets.length !== 1 || original.readyState !== NativeWebSocket.OPEN
        || window.ubiquitty.connectionState !== 'attached' || window.ubiquitty.sessionID !== sessionID)
      throw new Error(`resize ${width}x${height} lost its original attachment`);
    const session = window.ubiquitty.sessions().find(row => row.id === sessionID);
    if (!session) throw new Error('the resized session is missing from the real host listing');
    const requested = overrides.at(-1);
    const expected = expectsDenial ? initial : requested;
    if (overrides.length <= previousOverrides || session.columns !== expected.columns || session.rows !== expected.rows)
      throw new Error(`host did not apply the exact authorized resize: ${JSON.stringify({ session, requested })}`);
    console.log(`live-resize: ${width}x${height} host=${session.columns}x${session.rows}`);
  }
  console.log(`live-resize: PASS (${sizes.length} ${expectsDenial ? 'refused' : 'applied'} resizes, one socket, session ${sessionID})`);
  window.ubiquitty.detach();
  process.exit(0);
} catch (error) {
  console.error(`live-resize: FAILED ${error.stack}`);
  console.error(JSON.stringify({ sockets: sockets.length, closes, overrides, received: received.slice(-8), status: elementFor('status').textContent }));
  console.error(elementFor('debug').textContent);
  window.ubiquitty?.detach();
  process.exit(1);
}
