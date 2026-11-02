// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// stub-dom.mjs — the browser surface the built page touches, stood up in node.
//
// The page is the one frontend no C++ test can reach: WebTerminal is portable
// and runs under ctest, but terminal.js runs only in a browser. A bundle with a
// `const` bound below its first reader throws on the first paint with every C++
// test green, because presence is not execution.
//
// Standing the page up takes about twenty browser calls, which is cheaper to
// stand in for than to add jsdom to a repository with no node dependencies. The
// cost is in doing it once for every probe: a copy inside each one drifts. One
// copy that lacks a localStorage or a CustomEvent another has gained throws a
// TypeError inside its own stub, and reports it as "the page never opened a
// socket" — which is also what a broken page looks like, so nobody reads it as
// a fixture problem.
//
// One stub means a page path reaching for something absent throws the same way
// for every probe. The probes then differ in what they assert and never in what
// they believe a browser to be.
//
// Each element records what the page did to it, so a probe can ask whether the
// page got far enough rather than trusting that no throw means it did. A page
// that dies silently and a page that never starts look identical from outside.

import fs from 'fs';
import path from 'path';

/// How many times the page blitted a frame through putImageData.
///
/// A live binding rather than a getter: a probe reads it after awaiting, and the
/// count it wants is the one at that moment.
export let paints = 0;

/// Every listener the page registered, keyed `<element id>:<event type>`.
export const listeners = new Map();

/// Every element the page asked for by id, so a probe can read what was written.
export const elements = new Map();

/// Every write and removal of a `ubiquitty.host.` record, in order.
///
/// The touches rather than the values: a probe asking when the page wrote a
/// record cannot see a write that stored what was already there, nor a removal
/// of a key that was never set.
export const hostRecordTouches = [];

/// Returns the stub element with this id, creating it on first ask.
///
/// - Parameters:
///   - id: The element id the page passes to getElementById.
/// - Returns: The stub element, the same object on every later call.
function makeElement(id) {
  const style = {};
  return {
    id,
    style,
    hidden: false,
    value: '',
    textContent: '',
    width: 0,
    height: 0,
    dataset: {},
    addEventListener(type, handler) {
      listeners.set(`${id}:${type}`, handler);
      // Also on the element. The map above is keyed by id, and every element the
      // page creates shares one — `created:button` for all of them — so a test
      // driving one row's controls cannot address them through it.
      this.handlers = this.handlers || new Map();
      this.handlers.set(type, handler);
    },
    removeEventListener() {},
    focus() {},
    blur() {},
    // What the session panel draws with. Absent, `renderSessions` throws the
    // moment a listing arrives, and the panel is the one part of this page a
    // C++ test cannot reach at all.
    replaceChildren(...children) { this.children = children; },
    append(...children) { this.children = [...(this.children || []), ...children]; },
    querySelectorAll() { return []; },
    remove() {},
    setAttribute(name, value) { this.attributes = { ...(this.attributes || {}), [name]: value }; },
    getAttribute(name) { return (this.attributes || {})[name] ?? null; },
    removeAttribute(name) { if (this.attributes) delete this.attributes[name]; },
    // The rect FOLLOWS the inline offset, because that is the whole of why the
    // pointer path needs no padding correction: `pointerCell` measures from this
    // rect, so an inset the element itself carries is already in it. A stub
    // pinned at 0,0 agrees with a page that insets the element and with one that
    // insets the drawing inside it, and only the first has working clicks.
    getBoundingClientRect: () => ({
      left: parseFloat(style.left ?? style.inset) || 0,
      top: parseFloat(style.top ?? style.inset) || 0,
      width: 800,
      height: 600,
    }),
    getContext(kind) {
      if (kind !== '2d') return null; // no WebGL here: the CPU path is the one under test
      // The font the caller last set, because `measureText` has to answer about
      // it. A context that reports one size and measures at another is not a
      // thinner canvas, it is an inconsistent one: the rasterizer derives the
      // cell from the measurement and the raster is drawn at the size, so the
      // two disagree by whatever factor separates them and every geometry
      // assertion downstream fails on a page doing nothing wrong.
      let font = '16px monospace';
      return {
        canvas: { width: 800, height: 600 },
        putImageData() { ++paints; },
        createImageData: (w, h) => ({ data: new Uint8ClampedArray(w * h * 4), width: w, height: h }),
        fillRect() {}, clearRect() {}, drawImage() {}, setTransform() {}, scale() {},
        // Half the em: 8 at the default 16px, the advance the probes'
        // measurements assume, rather than an imitation of a real face — a
        // monospace advance is nearer 0.6em, and adopting that would move
        // numbers this fixture is not testing. What the fixture owes its
        // callers is that the measurement TRACKS the font, not that it matches
        // any one font.
        measureText: (text) => {
          const size = parseFloat(/(\d+(?:\.\d+)?)px/.exec(font)?.[1]) || 16;
          return { width: size * 0.5 * String(text ?? '').length, fontBoundingBoxAscent: size * .75, fontBoundingBoxDescent: size * .25,
            actualBoundingBoxAscent: size * .75, actualBoundingBoxDescent: size * .25 };
        },
        fillText() {}, save() {}, restore() {},
        set font(v) { font = String(v); }, get font() { return font; },
        set fillStyle(_v) {}, get fillStyle() { return '#000'; },
      };
    },
  };
}

export function elementFor(id) {
  if (!elements.has(id)) elements.set(id, makeElement(id));
  return elements.get(id);
}

export function makeFontSet() {
  const faces = new Set();
  return Object.assign(new EventTarget(), {
    ready: Promise.resolve(),
    add(face) { faces.add(face); return this; },
    has(face) { return faces.has(face); },
    delete(face) { return faces.delete(face); },
    [Symbol.iterator]() { return faces[Symbol.iterator](); },
    load: () => Promise.resolve(), check: () => true,
  });
}

/// Installs the stub browser onto globalThis.
///
/// Call once, before importing the built page: the page reads these at module
/// scope, so anything installed afterwards is installed too late.
///
/// - Parameters:
///   - dist: Directory holding the built page, whose wasm the stub fetch serves.
export function installStubDom(dist) {
  // A hidden document gets no animation frames: a browser holds them until the
  // page is shown again, and the page's hidden-tab paths are written against
  // exactly that. The fixture holds them the same way, so a probe asks for a
  // hidden tab by setting `document.visibilityState` and never by replacing
  // requestAnimationFrame — a replacement that drops the frame rather than
  // holding it leaves the page waiting on a paint that never comes.
  let visibilityState = 'visible';
  let lastFrameID = 0;
  const pendingFrames = new Map();
  const deliverFrame = (id) => {
    const frame = pendingFrames.get(id);
    if (!frame) return;
    pendingFrames.delete(id);
    frame.callback(performance.now());
  };
  const scheduleFrame = (id) => {
    pendingFrames.get(id).timer = setTimeout(() => deliverFrame(id), 0);
  };



  globalThis.document = {
    getElementById: elementFor,
    // The font rasterizer measures glyphs by drawing into a canvas it creates
    // itself, so this has to answer with something measurable.
    createElement: (tag) => makeElement(`created:${tag}`),
    // A real body carries a style object, and the page writes the terminal's
    // background onto it. A stub thinner than the thing it stands for turns a
    // working line into a TypeError that reads as a page defect.
    body: { append() {}, appendChild() {}, removeChild() {}, style: {} },
    documentElement: makeElement('html'),
    title: '',
    get visibilityState() { return visibilityState; },
    set visibilityState(state) {
      visibilityState = state;
      if (state === 'hidden') return;
      for (const [id, frame] of pendingFrames) {
        if (frame.timer === null) scheduleFrame(id);
      }
    },
    hasFocus: () => true,
    fullscreenElement: null,
    exitFullscreen: () => Promise.resolve(),
    addEventListener(type, handler) { listeners.set(`document:${type}`, handler); },
    fonts: makeFontSet(),
  };
  globalThis.FontFace = class FontFace {
    constructor(family) { this.family = family; this.status = 'unloaded'; }
    async load() { this.status = 'loaded'; return this; }
  };

  // dispatchEvent and CustomEvent are here because the page reports the host's
  // session list through one. The path needs an attach to run, which this smoke
  // test does not do — a stub thinner than the browser would turn that line into a
  // TypeError the moment anything did, the same way an absent localStorage hides
  // a broken recall.
  globalThis.CustomEvent = class CustomEvent {
    constructor(type, options) {
      this.type = type;
      this.detail = options?.detail;
    }
  };
  globalThis.window = {
    devicePixelRatio: 2,
    innerWidth: 800,
    innerHeight: 600,
    addEventListener(type, handler) { listeners.set(`window:${type}`, handler); },
    dispatchEvent: () => true,
    open: () => null,
    location: { search: '' },
  };
  globalThis.location = window.location;
  // node defines navigator as a getter-only property, so it is replaced rather
  // than assigned.
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: {
      clipboard: { readText: () => Promise.resolve(''), writeText: () => Promise.resolve() },
      keyboard: { getLayoutMap: () => Promise.reject(new Error('no layout map')) },
    },
  });
  globalThis.sessionStorage = {
    store: new Map(),
    getItem(k) { return this.store.has(k) ? this.store.get(k) : null; },
    setItem(k, v) { this.store.set(k, String(v)); },
    removeItem(k) { this.store.delete(k); },
  };
  // Without localStorage a broken recall is invisible: a recall helper that throws
  // a temporal-dead-zone ReferenceError and whose own try/catch returns '' is
  // indistinguishable from "nothing stored", which is also what an absent
  // localStorage produces. The stub is what makes the two distinguishable.
  // Every touch of a host record is logged, not just its value. The connect-rule
  // section below needs the moment the page wrote one, and a value comparison
  // cannot see a write that stores what was already there — or, on a host with no
  // record yet, a removal of a key that never existed.
  globalThis.localStorage = {
    store: new Map(),
    getItem(k) { return this.store.has(k) ? this.store.get(k) : null; },
    setItem(k, v) {
      if (String(k).startsWith('ubiquitty.host.')) hostRecordTouches.push(`set ${k}`);
      this.store.set(k, String(v));
    },
    removeItem(k) {
      if (String(k).startsWith('ubiquitty.host.')) hostRecordTouches.push(`remove ${k}`);
      this.store.delete(k);
    },
  };
  // The CPU path blits through an ImageData, which node does not define.
  globalThis.ImageData = class ImageData {
    constructor(data, width, height) {
      this.data = data;
      this.width = width;
      this.height = height;
    }
  };
  globalThis.requestAnimationFrame = (callback) => {
    const id = ++lastFrameID;
    pendingFrames.set(id, { callback, timer: null });
    if (visibilityState !== 'hidden') scheduleFrame(id);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => {
    const frame = pendingFrames.get(id);
    if (!frame) return;
    clearTimeout(frame.timer);
    pendingFrames.delete(id);
  };
  // Absent on purpose: the page must handle a browser without it, and asserting
  // that costs nothing here.
  globalThis.Notification = undefined;

  // The module fetches its own wasm; serve it from the staged directory.
  globalThis.fetch = async (u) => {
    const leaf = String(u).replace(/^file:\/\//, '').split('/').pop();
    const bytes = fs.readFileSync(path.join(dist, String(u).includes('/fonts/') ? 'fonts' : '', decodeURIComponent(leaf)));
    return { ok: true, arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), headers: { get: () => 'application/wasm' } };
  };
}
