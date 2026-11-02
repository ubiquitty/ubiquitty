// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Exercise the page's actual clipboard functions without a display, WASM build,
// or access to the machine clipboard. Promise resolution is controlled by each
// fixture; the browser API is an in-memory sink.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../../Source/Platform/Web/terminal.js', import.meta.url), 'utf8');

function pageFunction(name) {
  const marker = `  function ${name}(`;
  const begin = source.indexOf(marker);
  assert.notEqual(begin, -1, `missing production function ${name}`);
  assert.equal(source.indexOf(marker, begin + marker.length), -1, `ambiguous production function ${name}`);
  const end = source.indexOf('\n  }', begin);
  assert.notEqual(end, -1, `missing production function end ${name}`);
  return source.slice(begin, end + '\n  }'.length);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((accept, refuse) => { resolve = accept; reject = refuse; });
  return { promise, resolve, reject };
}

function fixture() {
  const state = { text: null, items: [], writes: [], textWrites: [], logs: [], pending: [] };
  const heap = new Uint8Array(1024);
  const context = vm.createContext({
    Blob,
    ClipboardItem: class {
      constructor(blobs) { this.blobs = blobs; }
    },
    module: { HEAPU8: heap },
    navigator: {
      clipboard: {
        write(items) {
          const result = deferred();
          state.writes.push(items);
          state.pending.push(result);
          return result.promise;
        },
        writeText(text) {
          const result = deferred();
          state.textWrites.push(text);
          state.pending.push(result);
          return result.promise;
        },
        read() { assert.fail('the write fixture must not read the clipboard'); },
      },
    },
    hasPendingClipboardWrite: () => state.text !== null,
    pendingClipboardWrite: () => state.text,
    takeClipboardWrite: () => { state.text = null; },
    pendingClipboardItemCount: () => state.items.length,
    clipboardItemMime: (index) => state.items[index].mime,
    clipboardItemLength: (index) => state.items[index].bytes.length,
    clipboardItemBytes: (index) => state.items[index].offset,
    takeClipboardItems: () => { state.items = []; },
    wantsClipboardRead: () => false,
    pumpClipboardServe: () => {},
    debugLog: (message) => state.logs.push(message),
  });
  vm.runInContext(`
    let clipboardWriteInFlight = false;
    let clipboardReadInFlight = false;
    const clipboardItemTypes = ['text/plain', 'text/html', 'image/png'];
    ${pageFunction('writeTypedClipboardItems')}
    ${pageFunction('pumpClipboard')}
    globalThis.pump = pumpClipboard;
  `, context, { filename: 'terminal.js clipboard functions' });
  return {
    state,
    heap,
    pump: () => context.pump(),
    stage(text, items = []) {
      state.text = text;
      let offset = 0;
      state.items = items.map(({ mime, bytes }) => {
        heap.set(bytes, offset);
        const item = { mime, bytes, offset };
        offset += bytes.length;
        return item;
      });
    },
  };
}

// Drain promise chains, not a wall-clock delay or a page animation frame.
async function settle() {
  await new Promise((resolve) => setImmediate(resolve));
}

{
  const f = fixture();
  f.pump();
  f.pump();
  assert.equal(f.state.pending.length, 0, 'no staged operation must not access the clipboard');
  f.stage('');
  f.pump();
  f.pump();
  assert.deepEqual(f.state.textWrites, [''], 'an explicit clear writes empty text exactly once');
  f.state.pending[0].resolve();
  await settle();
  f.pump();
  assert.equal(f.state.pending.length, 1, 'a completed clear must not be repeated');
}

{
  const f = fixture();
  f.stage('first', [{ mime: 'image/png', bytes: Uint8Array.of(0, 255, 1) }]);
  f.pump();
  assert.equal(f.state.items.length, 0);
  assert.equal(f.state.text, null);
  f.stage('second', [{ mime: 'text/html', bytes: Uint8Array.of(60, 98, 62) }]);
  f.pump();
  assert.equal(f.state.writes.length, 1, 'only one browser write may be in flight');
  const pixels = f.state.writes[0][0].blobs['image/png'];
  assert.deepEqual(Array.from(new Uint8Array(await pixels.arrayBuffer())), [0, 255, 1],
    'the first Blob must own bytes before later staging overwrites WASM memory');
  f.state.pending[0].reject(new Error('fixture typed denial'));
  await settle();
  assert.deepEqual(f.state.textWrites, ['first'], 'fallback belongs to the original operation');
  assert.equal(f.state.text, 'second', 'rejection must not consume the next operation');
  f.pump();
  assert.equal(f.state.writes.length, 1, 'fallback completion still owns the in-flight guard');
  f.state.pending[1].resolve();
  await settle();
  assert.equal(f.state.text, 'second', 'old completion must not erase newer staging');
  f.pump();
  assert.equal(f.state.writes.length, 2);
  assert.equal(f.state.text, null);
  assert.ok(f.state.writes[1][0].blobs['text/html']);
  f.state.pending[2].resolve();
  await settle();
  f.pump();
  assert.equal(f.state.pending.length, 3, 'typed success must not also write the fallback');
}

{
  const f = fixture();
  f.stage(null, [{ mime: 'image/png', bytes: Uint8Array.of(3, 2, 1) }]);
  f.pump();
  f.state.pending[0].reject(new Error('fixture image denial'));
  await settle();
  assert.deepEqual(f.state.textWrites, [], 'an image-only refusal must not clear the clipboard');
  f.stage('next');
  f.pump();
  assert.deepEqual(f.state.textWrites, ['next'], 'a refused write must release its in-flight guard');
  f.state.pending[1].reject(new Error('fixture text denial'));
  await settle();
  f.pump();
  assert.equal(f.state.pending.length, 2, 'refusal is not an implicit retry');
  assert.equal(f.state.logs.length, 2);
}

{
  const f = fixture();
  f.stage('fallback', [{ mime: 'application/octet-stream', bytes: Uint8Array.of(0, 1) }]);
  f.pump();
  assert.equal(f.state.writes.length, 0, 'unsupported browser MIME must not invoke typed write');
  assert.deepEqual(f.state.textWrites, ['fallback']);
  assert.equal(f.state.items.length, 0);
  f.state.pending[0].resolve();
  await settle();
}

console.log('web clipboard promises: 4 scenarios passed');
