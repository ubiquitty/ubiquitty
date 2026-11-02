// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Pure compositor adapter: no DOM, wasm, host, socket, process or timer.
import assert from 'node:assert/strict';
import { placePicture, viewportPoint } from '../../Source/Platform/Web/picture.js';

for (const deviceScale of [1, 1.5, 2, 3]) {
  const canvas = { style: {} };
  const extent = { width: 1000 * deviceScale, height: 600 * deviceScale };
  const fit = { scale: 0.4, originX: 0, originY: 30 * deviceScale };
  placePicture(canvas, extent, fit, deviceScale);
  assert.deepEqual(canvas.style, { left: '0px', top: '30px', width: '400px', height: '240px' });
  const pan = { scale: 1, originX: -410 * deviceScale, originY: -120 * deviceScale };
  placePicture(canvas, extent, pan, deviceScale);
  assert.deepEqual(canvas.style, { left: '-410px', top: '-120px', width: '1000px', height: '600px' });
  const letterbox = { scale: 1, originX: -300 * deviceScale, originY: -150 * deviceScale };
  placePicture(canvas, extent, letterbox, deviceScale);
  assert.deepEqual(canvas.style, { left: '-300px', top: '-150px', width: '1000px', height: '600px' });
  placePicture(canvas, extent, { scale: 1, originX: 0, originY: 0 }, deviceScale);
  assert.deepEqual(canvas.style, { left: '0px', top: '0px', width: '1000px', height: '600px' });
  // The pointer's basis is the viewport, not the already translated/scaled
  // canvas. Core receives this point and applies the shared inverse once.
  const viewport = { getBoundingClientRect: () => ({ left: 6, top: 9 }) };
  assert.deepEqual(viewportPoint({ clientX: 328, clientY: 203 }, viewport, deviceScale),
    { x: 322 * deviceScale, y: 194 * deviceScale });
  assert.deepEqual(extent, { width: 1000 * deviceScale, height: 600 * deviceScale });
}
console.log('picture-placement: all policies and backing scales passed');
