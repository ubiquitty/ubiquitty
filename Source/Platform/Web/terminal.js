// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// The page half of the browser frontend.
//
// Owns the canvas, the frame loop, byte delivery and the window geometry, and
// nothing else. Colour, layout, attributes and coverage arrive resolved from
// Core — the renderer macOS and Linux draw through — so a second paint model
// here would drift the moment either side changed.
//
// A window resize is a terminal resize: the grid is recomputed and handed down,
// and the rewrap that comes back is the one every other frontend gets.

import createModule from './ubiquitty.js';
import { loadTerminalFonts, prepareFont } from './fonts.js';
import { RichTextRenderer } from './rich-text.js';
import { WebGLRenderer, assertInstanceStrides } from './webgl.js';
import { placePicture as placeTerminalPicture, viewportPoint } from './picture.js';
import { renderOutlineRows } from './outline.js';

const canvas = document.getElementById('screen');
const screenViewport = document.getElementById('screen-viewport');
const status = document.getElementById('status');
// A canvas commits to one context kind for its lifetime, so the 2d context is
// taken only if WebGL2 was refused — asking for it up front would guarantee
// the GPU path never starts.
let context = null;
const debugPanel = document.getElementById('debug');
// The input method's composition target. Declared here beside the other elements
// rather than beside the handlers that use it: the first paint runs before those
// handlers are installed, and a `const` referenced before its declaration is a
// ReferenceError that kills the page on load rather than a missing feature.
const ime = document.getElementById('ime');
// Core's notice while some of what was typed may not have reached the host.
const inputInDoubt = document.getElementById('input-in-doubt');
const inputInDoubtMessageLine = document.getElementById('input-in-doubt-message');
const inputInDoubtDetailLine = document.getElementById('input-in-doubt-detail');
const inputInDoubtDiscard = document.getElementById('input-in-doubt-discard');
const inputInDoubtSendAgain = document.getElementById('input-in-doubt-send-again');

function focusTerminal() {
  ime.focus({ preventScroll: true });
}
const debugOn = new URLSearchParams(location.search).get('debug') === '1';
if (debugOn) debugPanel.hidden = false;

// Bulk traffic is a rate, not a log: one line per 8KB read buries the handshake
// and the denials, which are the lines anyone actually reads.
let rxBytes = 0;
let rxFrames = 0;
function countBytes(n) {
  rxBytes += n;
  rxFrames += 1;
  if (debugOn) debugPanel.dataset.rx = `${rxFrames} reads, ${(rxBytes / 1024).toFixed(1)} KiB`;
}

function debugLog(line) {
  if (!debugOn) return;
  debugPanel.textContent += line + '\n';
  debugPanel.scrollTop = debugPanel.scrollHeight;
}

// Unifont is 8x16 device pixels at scale 1, which reads as a hairline on a
// Retina display. The raster scale is an integer — a fractional one would
// resample glyphs the rasterizer drew crisp — so the display's own factor sets
// the floor and 1.5 lifts it to a comfortable size from there.
// Device pixels per logical pixel. The raster is produced at this scale so a
// glyph is sharp on a retina display; anything above it is not sharpness, it is
// a bigger font.
const GLYPH_SCALE = Math.max(1, Math.round(
  Number(new URLSearchParams(location.search).get('scale')) || (window.devicePixelRatio || 1)));

// The cell Core actually derives from the active face, in device pixels. The
// page cannot compute it: it depends on the font's own advance and vertical
// metrics, which only the rasterizer has read. Unifont's 8x16 is the value
// before the first create() and the fallback when no face is available -- and
// because those agreed for as long as no real font ever loaded, the page could
// carry its own copy of this number without anyone noticing it was a guess.
let cellPx = { width: 8 * GLYPH_SCALE, height: 16 * GLYPH_SCALE };

// Hands Core the page's configuration bytes, if any are served beside it.
//
// `config.toml` relative to the document, so a deployment chooses whether to
// publish one and Core decides what the bytes mean. No parsing here: the page
// does not know what a setting is, which is why adding one needs no page change.
async function deliverPreferences(module) {
  // Only the FETCH is allowed to fail quietly. A deployment that serves no
  // config.toml is ordinary and Core's defaults are right for it, so a 404, an
  // offline page or a refused request all mean "no configuration" and nothing
  // more.
  let bytes;
  try {
    const response = await fetch('config.toml', { cache: 'no-cache' });
    if (!response.ok)
      return;
    bytes = new Uint8Array(await response.arrayBuffer());
  } catch {
    return;
  }
  if (bytes.length === 0)
    return;
  // The handover is not allowed to fail quietly. Wrapped in the same try as the
  // fetch, a dropped runtime method reads as "no config served": the page opens,
  // every setting silently answers its default, and the deployment's own file is
  // the thing nobody suspects. Let it throw — an unhandled error in the console
  // is the difference between a bug that is found and one that is lived with.
  const buffer = module._malloc(bytes.length);
  try {
    module.HEAPU8.set(bytes, buffer);
    module.ccall('ubiquittyWebSetPreferenceBlob', null,
      ['string', 'number', 'number'], ['config', buffer, bytes.length]);
  } finally {
    module._free(buffer);
  }
}

async function main(module) {
  assertInstanceStrides(module);
  const params = new URLSearchParams(location.search);
  const workspaceView = window.frameElement?.dataset.workspaceView ?? params.get('workspaceView');
  const hostCalls = new Map();
  let nextHostCall = 1;
  function settleHostCalls() {
    for (;;) {
      const text = module.ccall('ubiquittyWebTakeHostCallResultJSON', 'string', [], []);
      if (!text) break;
      const answer = JSON.parse(text);
      const pending = hostCalls.get(answer.id);
      if (!pending) continue;
      clearTimeout(pending.timer);
      hostCalls.delete(answer.id);
      if (answer.error) pending.reject(new Error(answer.error.message));
      else pending.resolve(answer.result);
    }
  }

  const create = module.cwrap('ubiquittyWebCreate', null, ['number', 'number', 'number']);
  const feedFromHost = module.cwrap('ubiquittyWebFeedFromHost', 'number', ['number', 'number']);
  const searchLiteral = module.cwrap('ubiquittyWebSearchLiteral', 'number', ['string']);
  const pumpSearch = module.cwrap('ubiquittyWebPumpSearch', 'number', []);
  const searchStatusJSON = module.cwrap('ubiquittyWebSearchStatusJSON', 'string', []);
  const stepSearch = module.cwrap('ubiquittyWebStepSearch', 'number', ['number']);
  const buildHello = module.cwrap('ubiquittyWebBuildHello', 'number', ['string', 'number', 'number', 'string', 'number']);
  const sessionID = module.cwrap('ubiquittyWebSessionID', 'number', []);
  const restoreResume = module.cwrap('ubiquittyWebRestoreResume', 'string', ['string', 'string']);
  const persistResume = module.cwrap('ubiquittyWebPersistResume', null, []);
  const showsRestoredPicture = module.cwrap('ubiquittyWebShowsRestoredPicture', 'number', []);
  const hostIsOptimised = module.cwrap('ubiquittyWebHostIsOptimised', 'number', []);
  const hostNotice = module.cwrap('ubiquittyWebHostNotice', 'string', []);
  const inputInDoubtMessage = module.cwrap('ubiquittyWebInputInDoubtMessage', 'string', []);
  const inputInDoubtDetail = module.cwrap('ubiquittyWebInputInDoubtDetail', 'string', []);
  const inputInDoubtResendButton = module.cwrap('ubiquittyWebInputInDoubtResendButton', 'string', []);
  const inputInDoubtDiscardButton = module.cwrap('ubiquittyWebInputInDoubtDiscardButton', 'string', []);
  const resendInputInDoubt = module.cwrap('ubiquittyWebResendInputInDoubt', 'number', []);
  const discardInputInDoubt = module.cwrap('ubiquittyWebDiscardInputInDoubt', 'number', []);
  const setFontVariations = module.cwrap('ubiquittyWebSetFontVariations', null, ['string']);
  const fontVariationSettingsCSS = module.cwrap('ubiquittyWebFontVariationSettingsCSS', 'string', []);
  const fontFeatureSettingsCSS = module.cwrap('ubiquittyWebFontFeatureSettingsCSS', 'string', []);
  // capabilityControl, both halves. The frames are built here and decoded in
  // Core; the page holds no protocol knowledge, the same as everywhere else on
  // this boundary. What ending something costs is Core's question, and who may
  // end a session is the daemon's gate to answer — a requester attached to it
  // terminates directly, anyone else waits on the human on it — so the page
  // asks, sends with the token the answer carries, and reports the verdict.
  const buildListSessions = module.cwrap('ubiquittyWebBuildListSessions', 'number', []);
  const hostAnswerGeneration = module.cwrap('ubiquittyWebHostAnswerGeneration', 'number', []);
  // The host's outline: its workspaces, windows, tabs and panes as rows Core
  // has already decided. The page subscribes once per connection and reads the
  // rows when the generation moves; it chooses only what is closed and what is
  // searched for.
  const subscribeHostListing = module.cwrap('ubiquittyWebSubscribeHostListing', 'number', []);
  const hostOutlineGeneration = module.cwrap('ubiquittyWebHostOutlineGeneration', 'number', []);
  const isHostListingRefused = module.cwrap('ubiquittyWebIsHostListingRefused', 'number', []);
  const hostOutlineJSON = module.cwrap('ubiquittyWebHostOutlineJSON', 'string', ['string']);
  const collapseHostOutlineRow = module.cwrap('ubiquittyWebCollapseHostOutlineRow', 'number', ['string']);
  const expandHostOutlineRow = module.cwrap('ubiquittyWebExpandHostOutlineRow', 'number', ['string']);
  const collapseRecordedHostOutlineRow = module.cwrap('ubiquittyWebCollapseRecordedHostOutlineRow', 'number', ['number', 'number', 'number', 'number']);
  const expandRecordedHostOutlineRow = module.cwrap('ubiquittyWebExpandRecordedHostOutlineRow', 'number', ['number', 'number', 'number', 'number']);
  const hostDestructiveConfirmationJSON = module.cwrap('ubiquittyWebHostDestructiveConfirmationJSON', 'string', ['number', 'string', 'string']);
  const buildConfirmedTerminate = module.cwrap('ubiquittyWebBuildConfirmedTerminate', 'number', ['number', 'string', 'number']);
  const owedTerminateCount = module.cwrap('ubiquittyWebOwedTerminateCount', 'number', []);
  const buildOwedTerminate = module.cwrap('ubiquittyWebBuildOwedTerminate', 'number', []);
  const hostTerminateRefusal = module.cwrap('ubiquittyWebHostTerminateRefusal', 'string', []);
  const terminateGeneration = module.cwrap('ubiquittyWebTerminateGeneration', 'number', []);
  const terminateOutcome = module.cwrap('ubiquittyWebTerminateOutcome', 'number', []);
  const terminateSessionID = module.cwrap('ubiquittyWebTerminateSessionID', 'number', []);
  const terminateGraceMilliseconds = module.cwrap('ubiquittyWebTerminateGraceMilliseconds', 'number', []);
  const terminateConsentMilliseconds = module.cwrap('ubiquittyWebTerminateConsentMilliseconds', 'number', []);
  const noteTerminateGraceElapsed = module.cwrap('ubiquittyWebNoteTerminateGraceElapsed', null, []);
  const noteTerminateDeadlineElapsed = module.cwrap('ubiquittyWebNoteTerminateDeadlineElapsed', null, []);
  const noteTerminateTransportLost = module.cwrap('ubiquittyWebNoteTerminateTransportLost', null, []);
  // The connect rule, which is Core's and not this file's: the page hands over
  // the bytes it kept for a host, asks what to do with them, and writes back
  // whatever the ask left. It never reads inside the bytes.
  const loadHostRecord = module.cwrap('ubiquittyWebLoadHostRecord', null, ['string', 'number', 'number']);
  const decideAttach = module.cwrap('ubiquittyWebDecideAttach', 'number', ['string', 'string']);
  const decidedSessionID = module.cwrap('ubiquittyWebDecidedSessionID', 'number', []);
  const decidedWorkspaceName = module.cwrap('ubiquittyWebDecidedWorkspaceName', 'string', []);
  const rememberHostSession = module.cwrap('ubiquittyWebRememberHostSession', null, ['string', 'number', 'string']);
  const forgetHostSession = module.cwrap('ubiquittyWebForgetHostSession', null, ['string']);
  const hostRecordBytes = module.cwrap('ubiquittyWebHostRecordBytes', 'number', ['string']);
  const hostRecordLength = module.cwrap('ubiquittyWebHostRecordLength', 'number', ['string']);
  // `Session::AttachPlan`'s ordinals, named rather than restated: a plan is a
  // number this file compares and never a number it decides, so the five come
  // from the wasm and nothing here says what they are.
  const attachPlanAttachByID = module.cwrap('ubiquittyWebAttachPlanAttachByID', 'number', []);
  const attachPlanCreateNamed = module.cwrap('ubiquittyWebAttachPlanCreateNamed', 'number', []);
  const attachPlanAttachNamed = module.cwrap('ubiquittyWebAttachPlanAttachNamed', 'number', []);
  const attachPlanChooseFromList = module.cwrap('ubiquittyWebAttachPlanChooseFromList', 'number', []);
  const attachPlanCreateNew = module.cwrap('ubiquittyWebAttachPlanCreateNew', 'number', []);
  // Read on first use rather than at binding time. These five answer a constant
  // and touch no terminal, so calling them up here would work — but a cwrap
  // invoked where it is bound is invisible to check-web-init-order, and a
  // binding that looks like every other one has to behave like every other one.
  let attachPlanOrdinals = null;
  function attachPlans() {
    if (!attachPlanOrdinals) {
      attachPlanOrdinals = {
        attachByID: attachPlanAttachByID(),
        createNamed: attachPlanCreateNamed(),
        attachNamed: attachPlanAttachNamed(),
        chooseFromList: attachPlanChooseFromList(),
        createNew: attachPlanCreateNew(),
      };
    }
    return attachPlanOrdinals;
  }
  // WebTerminal::TerminateOutcome's ordinals, which are Core's
  // Session::TerminateOutcome numbers. `pending` is the web arm's alone and
  // takes a value no Core outcome occupies, so a page holding a row before it
  // asks anything cannot read as a destroy. Restated here rather than exported
  // one accessor per case, and pinned by
  // `theTerminateOutcomeOrdinalsAreTheOnesThePageReads` in
  // Tests/Platform/test_web_terminal.cpp — a renumbering fails there instead of
  // silently relabelling a row "denied" when the host said "refused".
  const TERMINATE = { terminated: 0, denied: 1, timedOut: 2, failed: 3, refused: 4, pending: 255 };
  // `Runtime::DestructiveRequest`'s values, the request Core's question is
  // asked about.
  const DESTRUCTIVE = { closeWindow: 1, terminateSession: 2, terminateWorkspace: 3 };
  // DECSET 7403 — relative pointer lock, the mode a mouselook client sets.
  //
  // The browser's Pointer Lock API is the same arrangement macOS gets from
  // CGAssociateMouseAndMouseCursorPosition: the cursor is hidden and captured,
  // and motion arrives as a signed per-report DELTA in movementX/movementY.
  // That delta is exactly what Core's encoder wants as pixelX/pixelY — it
  // applies the 0x8000 bias itself — so the page passes it through untouched.
  //
  // Declared here, above paint(), because paint() reconciles the lock every
  // frame. A `const` or `let` for this sitting down with the other mouse code
  // is in its temporal dead zone at the first frame: the module throws
  // ReferenceError and dies before registering a single listener.
  const pointerLockActive = module.cwrap('ubiquittyWebPointerLockActive', 'number', []);
  // Pointer lock is decided in Core: the page reports the facts only it sees —
  // whether it is focused, whether the Pointer Lock API grab is held, which
  // modifiers are down — and executes the verdicts. The break-out chord's
  // arming rule, hold and abort are the ladder's; the page books the one
  // wake-up Core names and asks then.
  const pointerLockVerdict = module.cwrap('ubiquittyWebPointerLockVerdict', 'number', ['number']);
  const notePointerLockGrab = module.cwrap('ubiquittyWebNotePointerLockGrab', null, ['number']);
  const notePointerLockChord = module.cwrap('ubiquittyWebNotePointerLockChord', null, ['number', 'number', 'number', 'number', 'number']);
  const tickPointerLockChord = module.cwrap('ubiquittyWebTickPointerLockChord', 'number', ['number', 'number', 'number', 'number', 'number']);
  const pointerLockChordTicksUntilDeadline = module.cwrap('ubiquittyWebPointerLockChordTicksUntilDeadline', 'number', []);
  // The wire version the build speaks, read from Core rather than retyped
  // here or in a fixture: a retyped number drifts at the next bump.
  const wireVersion = module.cwrap('ubiquittyWebWireVersion', 'number', []);
  // The build's version and identity are Core's strings, shown as they are.
  const appVersion = module.cwrap('ubiquittyWebAppVersion', 'string', []);
  const buildIdentity = module.cwrap('ubiquittyWebBuildIdentity', 'string', []);
  // The modifiers as of the last key event: a browser has no live modifier
  // query, so the chord's deadline ask uses what the last edge reported.
  let chordKeys = [0, 0, 0, 0, 0];
  let chordTickBooked = false;
  function reportPointerLockChord(event, isAnyKey) {
    chordKeys = [event.ctrlKey ? 1 : 0, event.metaKey ? 1 : 0, event.shiftKey ? 1 : 0, event.altKey ? 1 : 0, isAnyKey];
    notePointerLockChord(...chordKeys);
    bookPointerLockChordTick();
  }
  function bookPointerLockChordTick() {
    const ticks = pointerLockChordTicksUntilDeadline();
    if (ticks <= 0 || chordTickBooked) return;
    chordTickBooked = true;
    // One tick past the deadline, so the ask lands on its far side.
    setTimeout(() => {
      chordTickBooked = false;
      if (tickPointerLockChord(...chordKeys) !== 0) {
        // Core cleared the mode; this releases the grab it decided on.
        if (document.pointerLockElement) document.exitPointerLock();
        paint();
      } else {
        bookPointerLockChordTick();
      }
    }, ((ticks + 1) * 1000) / 60);
  }
  // How long the reserved-gesture hint Core is showing has left, in 60 Hz
  // ticks. The page owes one repaint at that tick so the lesson fades without
  // a frame of its own; the words and the clock are Core's.
  const serviceDisplayIdle = module.cwrap('ubiquittyWebServiceDisplayIdle', 'number', []);
  let displayIdleTimer = 0;
  function bookDisplayIdle() {
    const ticks = serviceDisplayIdle();
    if (ticks < 0) {
      clearTimeout(displayIdleTimer);
      displayIdleTimer = 0;
    } else if (!displayIdleTimer) {
      displayIdleTimer = setTimeout(() => { displayIdleTimer = 0; paint(); }, Math.max(1, ticks) * 1000 / 60);
    }
  }
  const hintTicksUntilExpiry = module.cwrap('ubiquittyWebHintTicksUntilExpiry', 'number', []);
  // Which words a lesson uses for the modifiers is decided by the keyboard
  // in front of the reader: a Mac prints ⌘ on the key, a Windows keyboard a
  // Windows logo, a Linux desktop calls its logo key Super. The page reports
  // the platform (1 Mac, 2 Windows, 0 the rest); Core keeps the words.
  const setModifierVocabulary = module.cwrap('ubiquittyWebSetModifierVocabulary', null, ['number']);
  function modifierVocabularyForPlatform(platform) {
    if (/^Mac|iPhone|iPad|iPod/i.test(platform)) return 1;
    if (/^Win/i.test(platform)) return 2;
    return 0;
  }
  let hintRepaintBooked = false;
  function bookHintRepaint() {
    const ticks = hintTicksUntilExpiry();
    if (ticks <= 0 || hintRepaintBooked) return;
    hintRepaintBooked = true;
    // One tick past the expiry, so the frame lands on its far side.
    setTimeout(() => { hintRepaintBooked = false; paint(); }, ((ticks + 1) * 1000) / 60);
  }
  // Row<<16|column and y<<16|x — Core's pointToCell / pointToDevicePixel,
  // packed because a struct has no cwrap shape. Unpacked in pointerCell().
  const pointerCellPacked = module.cwrap('ubiquittyWebPointerCellPacked', 'number', ['number', 'number']);
  const pointerXInCells = module.cwrap('ubiquittyWebPointerXInCells', 'number', ['number', 'number']);
  const pointerPixelPacked = module.cwrap('ubiquittyWebPointerPixelPacked', 'number', ['number', 'number']);
  const cursorCellX = module.cwrap('ubiquittyWebCursorCellX', 'number', []);
  const cursorCellY = module.cwrap('ubiquittyWebCursorCellY', 'number', []);
  function reconcilePointerLock(canvasElement) {
    // The application's ask and the page's standing to answer it, decided in
    // Core; the page supplies the one fact Core cannot see. Whether the grab
    // is held is the browser's own answer, read fresh: a copy kept here and
    // set on the request would say "held" after a refusal for want of a user
    // gesture, and the next click's retry would never come.
    const wanted = pointerLockVerdict(document.hasFocus() ? 1 : 0) !== 0;
    const holding = document.pointerLockElement === canvasElement;
    if (wanted === holding) return;
    if (wanted) {
      // May be refused outside a user gesture; the next click re-tries, which
      // is the contract every browser game lives with. A refusal arrives
      // either as a synchronous throw or, on the browsers that return a
      // Promise from this call, as a rejection -- caught here too, so it
      // never surfaces as an unhandled rejection the same retry contract
      // already covers.
      try {
        const request = canvasElement.requestPointerLock();
        if (request && typeof request.catch === 'function') request.catch(() => {});
      } catch { /* retried on the next click */ }
    } else {
      document.exitPointerLock();
    }
  }

  // The chosen theme, kept across reloads.
  //
  // Declared ABOVE its first use, which is the restore just after create(). It
  // sat below, and a `function` declaration hoists while the `const` it closes
  // over does not — so calling it early threw a temporal-dead-zone
  // ReferenceError INSIDE the try/catch below, which returned '' and looked
  // exactly like "nothing stored". The theme was saved correctly every time and
  // never restored once.
  //
  // The catch names its error rather than swallowing everything. A storage
  // failure is a DOMException from a browser in private mode; anything else is a
  // bug in this file, and the last one hid here for a release.
  //
  // localStorage and not sessionStorage: a session is tab-scoped, which is the
  // lifetime a shell gets here, while a theme is a preference that outlives any
  // one tab — so the theme cannot live in the session's store.
  //
  // Stored by NAME. An index is a position in Core's theme table, so adding or
  // reordering one would make a stored index name a different theme — silently,
  // and only for people who had already chosen.
  const THEME_KEY = 'ubiquitty.theme';
  const storageIsUnavailable = (error) => error instanceof Error && error.name === 'SecurityError';
  function rememberTheme(name) {
    try {
      if (name) localStorage.setItem(THEME_KEY, name);
      else localStorage.removeItem(THEME_KEY);
    } catch (error) {
      if (!storageIsUnavailable(error)) debugLog(`theme store failed: ${error && error.message}`);
    }
  }
  function recallTheme() {
    try {
      return localStorage.getItem(THEME_KEY) || '';
    } catch (error) {
      if (!storageIsUnavailable(error)) debugLog(`theme recall failed: ${error && error.message}`);
      return '';
    }
  }

  const toggleBeam = module.cwrap('ubiquittyWebToggleBeam', 'number', []);
  const setBeamSurface = module.cwrap('ubiquittyWebSetBeamSurface', 'number', ['string']);
  const setFontOptions = module.cwrap('ubiquittyWebSetFontOptions', 'number', ['string', 'number']);
  const currentThemeName = module.cwrap('ubiquittyWebCurrentThemeName', 'string', []);
  const setThemeByName = module.cwrap('ubiquittyWebSetThemeByName', 'number', ['string']);
  const isBeamOpen = module.cwrap('ubiquittyWebIsBeamOpen', 'number', []);
  const keyCodeForNameUncached = module.cwrap('ubiquittyWebKeyCodeForName', 'number', ['string']);
  // Memoised because a 'string' cwrap copies into the wasm heap on every call,
  // and this one sits on the keydown path. The answer is a constant for a given
  // name, so the cache cannot go stale; it holds what Core answered rather than
  // a second copy of the table, which is the distinction that matters here.
  const keyCodeCache = new Map();
  function keyCodeForName(name) {
    if (!name) return 0;
    let code = keyCodeCache.get(name);
    if (code === undefined) {
      code = keyCodeForNameUncached(name);
      keyCodeCache.set(name, code);
    }
    return code;
  }
  const keyModifiersOf = module.cwrap('ubiquittyWebKeyModifiers', 'number', ['number', 'number', 'number', 'number']);
  const feedBeamKey = module.cwrap('ubiquittyWebFeedBeamKey', 'number', ['number', 'number', 'number', 'number']);
  const takeBeamCommand = module.cwrap('ubiquittyWebTakeBeamCommand', 'string', []);
  const terminalTitle = module.cwrap('ubiquittyWebTitle', 'string', []);
  const pendingNotificationTitle = module.cwrap('ubiquittyWebPendingNotificationTitle', 'string', []);
  const pendingNotificationBody = module.cwrap('ubiquittyWebPendingNotificationBody', 'string', []);
  const pendingNotificationTag = module.cwrap('ubiquittyWebPendingNotificationTag', 'string', []);
  const takeNotification = module.cwrap('ubiquittyWebTakeNotification', null, []);
  const setFocus = module.cwrap('ubiquittyWebSetFocus', null, ['number']);
  const buildFocusChanged = module.cwrap('ubiquittyWebBuildFocusChanged', 'number', []);
  const cursorRow = module.cwrap('ubiquittyWebCursorRow', 'number', []);
  const cursorColumn = module.cwrap('ubiquittyWebCursorColumn', 'number', []);
  const pendingFontFamily = module.cwrap('ubiquittyWebPendingFontFamily', 'string', []);
  const takeFontFamily = module.cwrap('ubiquittyWebTakeFontFamily', null, []);
  const rebuildFont = module.cwrap('ubiquittyWebRebuildFont', null, []);
  const takePendingHostFrame = module.cwrap('ubiquittyWebTakePendingHostFrame', 'number', ['number']);
  const screenTickDelay = module.cwrap('ubiquittyWebScreenTickDelay', 'number', []);
  const buildInput = module.cwrap('ubiquittyWebBuildInput', 'number', ['number', 'number']);
  const buildPastePush = module.cwrap('ubiquittyWebBuildPastePush', 'number', ['string', 'number', 'number']);
  const buildPaste = module.cwrap('ubiquittyWebBuildPaste', 'number', ['number', 'number']);
  const reportsKeyPositions = module.cwrap('ubiquittyWebReportsKeyPositions', 'number', []);
  const reportsPasteEvents = module.cwrap('ubiquittyWebReportsPasteEvents', 'number', []);
  const buildPasteNotification = module.cwrap('ubiquittyWebBuildPasteNotification', 'number', ['string']);
  const buildResize = module.cwrap('ubiquittyWebBuildResize', 'number', ['number', 'number']);
  const frameLength = module.cwrap('ubiquittyWebFrameLength', 'number', []);
  const isAttached = module.cwrap('ubiquittyWebIsAttached', 'number', []);
  const resize = module.cwrap('ubiquittyWebResize', null, ['number', 'number']);
  const feedBytes = module.cwrap('ubiquittyWebFeed', null, ['number', 'number']);
  const render = module.cwrap('ubiquittyWebRender', 'number', []);
  const imageWidth = module.cwrap('ubiquittyWebImageWidth', 'number', []);
  const imageHeight = module.cwrap('ubiquittyWebImageHeight', 'number', []);

  const buildFrame = module.cwrap('ubiquittyWebBuildFrame', 'number', []);
  const isFrameWithheld = module.cwrap('ubiquittyWebIsFrameWithheld', 'number', []);
  const cellInstances = module.cwrap('ubiquittyWebCellInstances', 'number', []);
  const cellInstanceCount = module.cwrap('ubiquittyWebCellInstanceCount', 'number', []);
  const glyphInstances = module.cwrap('ubiquittyWebGlyphInstances', 'number', []);
  const glyphInstanceCount = module.cwrap('ubiquittyWebGlyphInstanceCount', 'number', []);
  const cursorTierGlyphCount = module.cwrap('ubiquittyWebCursorTierGlyphCount', 'number', []);
  const wideGlyphInstances = module.cwrap('ubiquittyWebWideGlyphInstances', 'number', []);
  const wideGlyphInstanceCount = module.cwrap('ubiquittyWebWideGlyphInstanceCount', 'number', []);
  const wideAtlasPixels = module.cwrap('ubiquittyWebWideAtlasPixels', 'number', []);
  const wideAtlasWidth = module.cwrap('ubiquittyWebWideAtlasWidth', 'number', []);
  const wideAtlasHeight = module.cwrap('ubiquittyWebWideAtlasHeight', 'number', []);
  const proportionalGlyphInstances = module.cwrap('ubiquittyWebProportionalGlyphInstances', 'number', []);
  const proportionalGlyphInstanceCount = module.cwrap('ubiquittyWebProportionalGlyphInstanceCount', 'number', []);
  const proportionalAtlasPixels = module.cwrap('ubiquittyWebProportionalAtlasPixels', 'number', []);
  const proportionalAtlasWidth = module.cwrap('ubiquittyWebProportionalAtlasWidth', 'number', []);
  const proportionalAtlasHeight = module.cwrap('ubiquittyWebProportionalAtlasHeight', 'number', []);
  const proportionalAtlasGeneration = module.cwrap('ubiquittyWebProportionalAtlasGeneration', 'number', []);
  const proportionalStripInstances = module.cwrap('ubiquittyWebProportionalStripInstances', 'number', []);
  const proportionalStripInstanceCount = module.cwrap('ubiquittyWebProportionalStripInstanceCount', 'number', []);
  const proportionalStripAtlasPixels = module.cwrap('ubiquittyWebProportionalStripAtlasPixels', 'number', []);
  const proportionalStripAtlasWidth = module.cwrap('ubiquittyWebProportionalStripAtlasWidth', 'number', []);
  const proportionalStripAtlasHeight = module.cwrap('ubiquittyWebProportionalStripAtlasHeight', 'number', []);
  const proportionalStripAtlasIsDirty = module.cwrap('ubiquittyWebProportionalStripAtlasIsDirty', 'number', []);
  const didUploadProportionalStripAtlas = module.cwrap('ubiquittyWebDidUploadProportionalStripAtlas', null, []);
  const ligatureGlyphInstances = module.cwrap('ubiquittyWebLigatureGlyphInstances', 'number', []);
  const ligatureGlyphInstanceCount = module.cwrap('ubiquittyWebLigatureGlyphInstanceCount', 'number', []);
  const ligatureAtlasPixels = module.cwrap('ubiquittyWebLigatureAtlasPixels', 'number', []);
  const ligatureAtlasWidth = module.cwrap('ubiquittyWebLigatureAtlasWidth', 'number', []);
  const ligatureAtlasHeight = module.cwrap('ubiquittyWebLigatureAtlasHeight', 'number', []);
  const ligatureAtlasIsDirty = module.cwrap('ubiquittyWebLigatureAtlasIsDirty', 'number', []);
  const didUploadLigatureAtlas = module.cwrap('ubiquittyWebDidUploadLigatureAtlas', null, []);
  const fontResourceGeneration = module.cwrap('ubiquittyWebFontResourceGeneration', 'number', []);
  const setDrawsSizedText = module.cwrap('ubiquittyWebSetDrawsSizedText', null, ['number']);
  const setDrawsProportionalText = module.cwrap('ubiquittyWebSetDrawsProportionalText', null, ['number']);
  const colorGlyphInstances = module.cwrap('ubiquittyWebColorGlyphInstances', 'number', []);
  const colorGlyphInstanceCount = module.cwrap('ubiquittyWebColorGlyphInstanceCount', 'number', []);
  // The cursor tier's tails per stream: drawn as a layer after every head.
  const cursorTierCellCount = module.cwrap('ubiquittyWebCursorTierCellCount', 'number', []);
  const cursorTierWideGlyphCount = module.cwrap('ubiquittyWebCursorTierWideGlyphCount', 'number', []);
  const cursorTierProportionalGlyphCount = module.cwrap('ubiquittyWebCursorTierProportionalGlyphCount', 'number', []);
  const cursorTierProportionalStripCount = module.cwrap('ubiquittyWebCursorTierProportionalStripCount', 'number', []);
  const cursorTierLigatureGlyphCount = module.cwrap('ubiquittyWebCursorTierLigatureGlyphCount', 'number', []);
  const cursorTierColorGlyphCount = module.cwrap('ubiquittyWebCursorTierColorGlyphCount', 'number', []);
  const cursorTierDecorationCount = module.cwrap('ubiquittyWebCursorTierDecorationCount', 'number', []);
  const colorAtlasPixels = module.cwrap('ubiquittyWebColorAtlasPixels', 'number', []);
  const colorAtlasWidth = module.cwrap('ubiquittyWebColorAtlasWidth', 'number', []);
  const colorAtlasHeight = module.cwrap('ubiquittyWebColorAtlasHeight', 'number', []);
  const atlasPixels = module.cwrap('ubiquittyWebAtlasPixels', 'number', []);
  const atlasWidth = module.cwrap('ubiquittyWebAtlasWidth', 'number', []);
  const atlasHeight = module.cwrap('ubiquittyWebAtlasHeight', 'number', []);
  const decorationInstances = module.cwrap('ubiquittyWebDecorationInstances', 'number', []);
  const decorationInstanceCount = module.cwrap('ubiquittyWebDecorationInstanceCount', 'number', []);
  const overlayInstances = module.cwrap('ubiquittyWebOverlayInstances', 'number', []);
  const overlayInstanceCount = module.cwrap('ubiquittyWebOverlayInstanceCount', 'number', []);
  const boxFillInstances = module.cwrap('ubiquittyWebBoxFillInstances', 'number', []);
  const boxFillInstanceCount = module.cwrap('ubiquittyWebBoxFillInstanceCount', 'number', []);
  const frameUsesBitmapFace = module.cwrap('ubiquittyWebFrameUsesBitmapFace', 'number', []);
  const cursorTierBoxFillCount = module.cwrap('ubiquittyWebCursorTierBoxFillCount', 'number', []);
  const frameRequiresCPUCompositing = module.cwrap('ubiquittyWebFrameRequiresCPUCompositing', 'number', []);
  const monoAtlasGeneration = module.cwrap('ubiquittyWebMonoAtlasGeneration', 'number', []);
  const wideAtlasGeneration = module.cwrap('ubiquittyWebWideAtlasGeneration', 'number', []);
  const colorAtlasGeneration = module.cwrap('ubiquittyWebColorAtlasGeneration', 'number', []);
  const cellWidthPx = module.cwrap('ubiquittyWebCellWidth', 'number', []);
  const cellHeightPx = module.cwrap('ubiquittyWebCellHeight', 'number', []);
  const terminalColumns = module.cwrap('ubiquittyWebColumns', 'number', []);
  const terminalRows = module.cwrap('ubiquittyWebRows', 'number', []);
  const setPresentationViewport = module.cwrap('ubiquittyWebSetPresentationViewport', null, ['number', 'number']);
  const presentationScale = module.cwrap('ubiquittyWebPresentationScale', 'number', []);
  const presentationOriginX = module.cwrap('ubiquittyWebPresentationOriginX', 'number', []);
  const presentationOriginY = module.cwrap('ubiquittyWebPresentationOriginY', 'number', []);
  const backgroundColor = module.cwrap('ubiquittyWebBackgroundColor', 'number', []);
  const paddingCss = module.cwrap('ubiquittyWebPadding', 'number', []);
  const setPaddingCss = module.cwrap('ubiquittyWebSetPadding', null, ['number']);
  const gridColumnsFor = module.cwrap('ubiquittyWebGridColumns', 'number', ['number', 'number', 'number']);
  const gridRowsFor = module.cwrap('ubiquittyWebGridRows', 'number', ['number', 'number', 'number']);

  // The window decides the geometry; the grid is inferred from it — by Core,
  // which already divides a viewport by a cell for macOS and GTK. The page held
  // its own floor(viewport / cell), and two spellings of one rule is where the
  // frontends disagree about the same window.
  //
  // Device pixels, with the ratio passed alongside: the padding is stated in CSS
  // pixels, and an inset applied in the wrong unit looks right at scale 1 and
  // half-size on a retina display.
  function gridForWindow() {
    const ratio = window.devicePixelRatio || 1;
    const width = window.innerWidth * ratio;
    const height = window.innerHeight * ratio;
    const padding = paddingCss() * ratio;
    setPresentationViewport(Math.max(0, width - 2 * padding), Math.max(0, height - 2 * padding));
    return { columns: gridColumnsFor(width, height, ratio), rows: gridRowsFor(width, height, ratio) };
  }

  // One compositor transform over the complete Core picture, shared by both
  // canvas backends. The viewport clips it without reflowing the host grid.
  function placePicture(width, height) {
    const ratio = window.devicePixelRatio || 1;
    placeTerminalPicture(canvas, { width, height }, { scale: presentationScale(),
      originX: presentationOriginX(), originY: presentationOriginY() }, ratio);
  }

  // The chosen padding, kept across reloads for the reason the theme is: it is a
  // preference rather than session state. Stored as the NUMBER Core accepted
  // (read back after setting, since Core clamps to the schema), so a stored
  // value can never be one the terminal would refuse on the next load.
  const PADDING_KEY = 'ubiquitty.padding';
  function rememberPadding(cssPixels) {
    try {
      localStorage.setItem(PADDING_KEY, String(cssPixels));
    } catch (error) {
      if (!storageIsUnavailable(error)) debugLog(`padding store failed: ${error && error.message}`);
    }
  }
  // Core's own default when nothing is stored, and when what is stored is not a
  // number — a corrupted entry must not become a padding of NaN, which lays the
  // canvas out at a position the browser resolves to zero without saying so.
  function recallPadding() {
    try {
      const stored = localStorage.getItem(PADDING_KEY);
      if (stored === null) return paddingCss();
      const value = Number(stored);
      return Number.isFinite(value) ? value : paddingCss();
    } catch (error) {
      if (!storageIsUnavailable(error)) debugLog(`padding recall failed: ${error && error.message}`);
      return paddingCss();
    }
  }

  // Padding belongs to the clipped viewport. Core maps a pointer from that
  // viewport back through the complete picture's local transform.
  // The page paints everywhere the grid does not — the padding, and the sub-cell
  // remainder a window that is not a whole number of cells leaves. The colour is
  // the terminal's, read rather than held: the stylesheet's own value was Core's
  // default copied by hand, which is correct until the first theme is applied
  // and then draws a frame in the old theme around a grid in the new one.
  // Re-read after every frame as well as on a theme change, because the ground
  // also moves with the terminal's own state: DECSCNM swaps it, and the margin
  // the page paints has to swap with the grid or a reversed screen sits in an
  // unreversed border. The DOM is written only when the value moved.
  let appliedBackground = -1;
  function applyBackgroundColor() {
    const color = backgroundColor();
    if (color === appliedBackground) return;
    appliedBackground = color;
    document.body.style.background = `#${color.toString(16).padStart(6, '0')}`;
  }

  function applyPadding(cssPixels, { remember = true } = {}) {
    setPaddingCss(cssPixels);
    // Read back rather than trusting the argument: Core clamps to the schema, so
    // this is what the terminal actually holds, and the page draws that.
    const inset = paddingCss();
    screenViewport.style.inset = `${inset}px`;
    if (remember) rememberPadding(inset);
    return inset;
  }

  // The face the rasterizer draws with, named before the terminal exists: the
  // cell geometry is measured once at construction, so a font installed later
  // would be measured against a grid already laid out for the fallback.
  //
  // `?font=` picks it; absent, the terminal renders with the built-in fallback,
  // which is a complete face rather than a degraded one — it carries the box
  // drawing and symbol coverage a text face usually lacks.
  // The house face by default, as every other frontend uses it. `?font=` picks
  // another; `?font=` empty asks for the built-in fallback, which is a complete
  // face rather than a degraded one — it carries the box drawing and symbol
  // coverage a text face usually lacks.
  module.ubiquittyFontCoverage = await loadTerminalFonts();
  const richText = new RichTextRenderer(module.ubiquittyMeasurementDocument || document, module.ubiquittyFontMetricsCache, module.ubiquittyFontCatalog);
  module.ubiquittyRichText = richText;
  screenViewport.append(richText.root);
  const richTextFrame = module.cwrap('ubiquittyWebRichTextFrameJSON', 'string', []);
  function paintRichText() {
    richText.present(JSON.parse(richTextFrame()), canvas, presentationScale() / (window.devicePixelRatio || 1));
  }
  const requestedFont = window.frameElement?.dataset.fontFamily ?? (params.has('font') ? params.get('font') : 'JetBrains Mono');
  // Unused CSS faces load lazily. Routing probes run synchronously, so all
  // declared fallback faces must be available before the first glyph lookup.
  if (document.fonts && typeof document.fonts[Symbol.iterator] === 'function') {
    await Promise.all(Array.from(document.fonts, async face => {
      try {
        await face.load();
      } catch (error) {
        debugLog(`font load failed for ${face.family}: ${error.message}`);
      }
    }));
  }
  if (requestedFont) {
    // A face the browser has not finished loading measures as absent, so the
    // terminal would silently lay out for the fallback. Waiting is the
    // difference between "the font is missing" and "the font is not ready yet".
    if (document.fonts && document.fonts.load) {
      try {
        await document.fonts.load(`${16 * GLYPH_SCALE}px ${requestedFont}`);
      } catch (error) {
        debugLog(`font load failed: ${error.message}`);
      }
    }
    module.ubiquittyFontFamily = requestedFont;
    debugLog(`font: ${requestedFont}`);
  }

  // The palette shares the same real inventory as OSC discovery. FontFaceSet
  // check() also succeeds for unknown names that fall back, so it cannot prove
  // that a candidate is installed.
  richText.fontCatalog.refresh();
  // A placeholder, not a measurement. create() is what makes the terminal that
  // answers every geometry question — the cell the loaded face derives, the
  // padding, the division itself — so asking before it exists gets zeros, and a
  // grid of zero rows is a terminal nothing can draw in.
  //
  // The fit below is where the real grid comes from. 80x24 rather than something
  // plausibly small, so a fit that failed to run shows as the classic default
  // sitting in the corner of the window instead of passing for a tight window.
  let grid = { rows: 24, columns: 80 };
  // Configuration, before create() because Core acquires it once on first use.
  //
  // A page has no file, so the bytes are fetched and handed over under a name;
  // Core parses them with the same reader a desktop uses on config.toml, and the
  // page reads none of it. That is the whole of this frontend's involvement in
  // settings: fetch, hand over, let Core answer every key. Threading values in
  // one at a time is what left 129 of them unreachable here while four were
  // carried by hand.
  //
  // Absent is not an error. A deployment with no config.toml beside the page is
  // the common case and Core's defaults are the right answer for it, so a 404 or
  // a refused fetch leaves the terminal on defaults rather than failing to open.
  await deliverPreferences(module);
  create(grid.rows, grid.columns, GLYPH_SCALE);
  // This page's renderer draws sized blocks and, through its proportional
  // atlas, proportional runs; a bare module leaves both facts off.
  setDrawsSizedText(1);
  setDrawsProportionalText(1);
  // After create(): the terminal that holds the fact exists only from here.
  setModifierVocabulary(modifierVocabularyForPlatform(navigator.platform || ''));
  cellPx = { width: cellWidthPx(), height: cellHeightPx() };
  debugLog(`cell ${cellPx.width}x${cellPx.height}px`);

  // `?variations=` — the font.variations axis list, handed over as written. The
  // grammar is parsed on the C++ side out of Core, so the page never learns a
  // second spelling of it and the two cannot disagree about what a token means.
  //
  // After create() with the rest of the setters, and for the same reason: the
  // export answers on a terminal that does not exist yet by doing nothing, so an
  // early call is discarded in silence.
  //
  // A `wght` here reaches the upright cell only — below an SGR weight and below
  // the bold face, which is the ordering the native arms apply. The other axes
  // need a registered face carrying font-variation-settings, because a canvas
  // font shorthand cannot name an axis; until the page builds one they are
  // parsed and dropped rather than drawn.
  if (params.has('variations')) {
    const variations = params.get('variations');
    setFontVariations(variations);
    debugLog(`variations: ${variations}`);
  }
  // The configuration's `font.ligatures` and `font.features` reach the face the
  // same way the axes do, as descriptors on a registered face, and the browser
  // shapes with that face: drawn in the plain family, a configuration that
  // turned a feature off would still see it applied.
  if (requestedFont) await applyFontVariationAlias(requestedFont);

  // After create(). Both of these reach a terminal that does not exist before
  // it, and the exports answer 0 rather than throwing — so calling them early
  // is silent: the font list is discarded, "Choose Font" never appears, and
  // nothing anywhere says why.
  function publishFontOptions() {
    const availableFonts = richText.fontCatalog.families;
    const current = availableFonts.indexOf(requestedFont);
    setFontOptions(availableFonts.join('\n'), current);
    debugLog(`fonts available: ${availableFonts.length}`);
  }
  publishFontOptions();

  // ?beam=native|in-terminal|auto, parsed by Core's own config reader. The
  // browser has no native palette yet, so every value draws in the grid today —
  // the parameter is here so the setting is exercised from the page rather than
  // only from a test, and rejects a typo instead of silently meaning "auto".
  //
  // After create(), like everything else that reaches the terminal. This sat a
  // hundred lines above it and was discarded on every load: -1 now says so
  // rather than the page blaming the value.
  if (params.has('beam')) {
    const accepted = setBeamSurface(params.get('beam'));
    if (accepted === 0)
      console.warn(`[ubiquitty] unrecognized ?beam=${params.get('beam')}; leaving the configured surface alone`);
    else if (accepted < 0)
      console.warn('[ubiquitty] ?beam= was applied before the terminal existed — this is a bug in terminal.js, not in the value');
  }

  // Restore the theme the user last chose. An unknown name — a theme removed
  // from Core since — leaves the palette alone and clears the stored value,
  // rather than falling back to a default the user did not pick.
  let lastKnownTheme = '';
  const savedTheme = recallTheme();
  if (savedTheme) {
    if (setThemeByName(savedTheme)) {
      lastKnownTheme = savedTheme;
      debugLog(`theme restored: ${savedTheme}`);
    } else {
      rememberTheme('');
      debugLog(`theme "${savedTheme}" is no longer known; cleared`);
    }
  }
  applyBackgroundColor();
  applyPadding(recallPadding());
  const fitted = gridForWindow();
  if (fitted.rows !== grid.rows || fitted.columns !== grid.columns) {
    grid = fitted;
    resize(grid.rows, grid.columns);
    debugLog(`fitted to ${grid.columns}x${grid.rows} for the real cell`);
  }

  // Both paths draw the same instance stream: the GPU composites it, the CPU
  // composites it and blits the image. An absent WebGL2 costs speed, not
  // output.
  //
  // ?gpu=0 skips the WebGL2 context entirely rather than skipping the GPU
  // paint. A canvas holds one context type for its lifetime, so a canvas that
  // has been given webgl2 answers getContext('2d') with null forever — the CPU
  // path cannot fall back onto a canvas the GPU path has already claimed.
  const useGPU = params.get('gpu') !== '0';
  let renderer = null;
  let contextControl = null;
  let isViewVisible = true;
  let isContextSuspended = false;
  let hasLostContext = false;
  // Why the CPU path is running, when it is. Shown in the status line rather
  // than logged: the fallback is permanent and costs 72x the GPU build — 29ms
  // against 0.41ms at a full-screen grid — so a page that silently takes it runs
  // at a quarter of the frame rate for the rest of its life with the reason
  // behind a query parameter nobody thinks to add. `?gpu=0` is a choice and says
  // so; a context that failed is a fault and has to read as one.
  let cpuReason = '';
  if (useGPU) {
    try {
      renderer = new WebGLRenderer(canvas);
      contextControl = renderer.gl.getExtension('WEBGL_lose_context');
      debugLog('WebGL2: cell pass active');
    } catch (error) {
      cpuReason = error.message;
      debugLog(`${cpuReason}; compositing on the CPU`);
    }
  } else {
    cpuReason = 'gpu=0';
    debugLog('WebGL2 disabled by ?gpu=0 — compositing on the CPU');
  }

  let localProgram = null;
  const encoder = new TextEncoder();
  function feed(text) {
    const bytes = encoder.encode(text);
    const buffer = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, buffer);
    feedBytes(buffer, bytes.length);
    module._free(buffer);
  }

  // OSC 52, pumped once per frame. Both directions are promises here and
  // synchronous in Core, so neither can be answered where it is asked: a write
  // waits to be taken, a read waits to be told.
  //
  // A clipboard write needs a user gesture in some browsers and will reject
  // without one. That rejection is the browser's policy, not an error to retry —
  // the text is taken either way, because re-offering it every frame would fire
  // a permission prompt on a loop.
  let clipboardReadInFlight = false;
  let clipboardWriteInFlight = false;
  // Declared above pumpClipboard rather than with the other entry points: these
  // are `const`, paint() calls pumpClipboard, and paint() runs once at module
  // scope during setup. A const read before its initializer is a ReferenceError
  // at load, not a missing frame -- the page renders nothing and the console
  // says "cannot access before initialization".
  const pendingClipboardWrite = module.cwrap('ubiquittyWebPendingClipboardWrite', 'string', []);
  const hasPendingClipboardWrite = module.cwrap('ubiquittyWebHasPendingClipboardWrite', 'number', []);
  const takeClipboardWrite = module.cwrap('ubiquittyWebTakeClipboardWrite', null, []);
  const wantsClipboardRead = module.cwrap('ubiquittyWebWantsClipboardRead', 'number', []);
  const provideClipboardRead = module.cwrap('ubiquittyWebProvideClipboardRead', null, ['string']);
  const clipboardReadNeedsConfirmation = module.cwrap('ubiquittyWebClipboardReadNeedsConfirmation', 'number', []);
  const pendingClipboardItemCount = module.cwrap('ubiquittyWebPendingClipboardItemCount', 'number', []);
  const clipboardItemMime = module.cwrap('ubiquittyWebClipboardItemMime', 'string', ['number']);
  const clipboardItemBytes = module.cwrap('ubiquittyWebClipboardItemBytes', 'number', ['number']);
  const clipboardItemLength = module.cwrap('ubiquittyWebClipboardItemLength', 'number', ['number']);
  const takeClipboardItems = module.cwrap('ubiquittyWebTakeClipboardItems', null, []);
  const beginClipboardReadItems = module.cwrap('ubiquittyWebBeginClipboardReadItems', null, []);
  const addClipboardReadItem = module.cwrap('ubiquittyWebAddClipboardReadItem', null, ['string', 'number', 'number']);
  // Serving the other direction: a program on the HOST asked for a clipboard
  // its machine does not have, and this browser's is the answer. Declared in
  // this block for the same dead-zone reason as its neighbours — pumpClipboard
  // reads them and paint() calls it once during setup.
  const pendingClipboardServeID = module.cwrap('ubiquittyWebPendingClipboardServeID', 'number', []);
  const pendingClipboardServeWantsTypes = module.cwrap('ubiquittyWebPendingClipboardServeWantsTypes', 'number', []);
  const pendingClipboardServeMime = module.cwrap('ubiquittyWebPendingClipboardServeMime', 'string', []);
  const beginClipboardServeItems = module.cwrap('ubiquittyWebBeginClipboardServeItems', null, []);
  const addClipboardServeItem = module.cwrap('ubiquittyWebAddClipboardServeItem', null, ['string', 'number', 'number']);
  const buildClipboardServeAnswer = module.cwrap('ubiquittyWebBuildClipboardServeAnswer', 'number', ['number']);
  let clipboardServeInFlight = false;

  // The types the Async Clipboard API accepts in a ClipboardItem. Anything
  // else rejects the whole write, so an unsupported flavour is left to the
  // text fallback rather than sinking the item that carries it.
  const clipboardItemTypes = ['text/plain', 'text/html', 'image/png'];

  // A typed set staged by the program, written whole where the browser
  // allows it. The text also rides the plain string staging, so a browser
  // (or a rejection) that refuses the typed write still lands the text.
  function writeTypedClipboardItems(fallback) {
    const count = pendingClipboardItemCount();
    if (count === 0) {
      return null;
    }
    const blobs = {};
    for (let i = 0; i < count; i += 1) {
      const mime = clipboardItemMime(i).split(';')[0];
      if (!clipboardItemTypes.includes(mime) || blobs[mime]) {
        continue;
      }
      const length = clipboardItemLength(i);
      const bytes = module.HEAPU8.slice(clipboardItemBytes(i), clipboardItemBytes(i) + length);
      blobs[mime] = new Blob([bytes], { type: mime });
    }
    takeClipboardItems();
    if (Object.keys(blobs).length === 0) {
      return null; // nothing the API accepts: the text fallback owns it
    }
    return navigator.clipboard.write([new ClipboardItem(blobs)])
      .catch((error) => {
        debugLog(`typed clipboard write refused: ${error.message}`);
        if (fallback !== null) return navigator.clipboard.writeText(fallback);
        return undefined;
      });
  }

  // Read the typed picture where the browser offers one, and answer with
  // both halves: each supported payload, then the text that completes the
  // query. Any refusal falls back to the plain text read, which answers
  // with the empty string rather than leaving the program waiting.
  function readTypedClipboard(answer) {
    navigator.clipboard.read()
      .then(async (items) => {
        beginClipboardReadItems();
        let text = '';
        for (const item of items) {
          for (const type of item.types) {
            if (!clipboardItemTypes.includes(type)) {
              continue;
            }
            const blob = await item.getType(type);
            const bytes = new Uint8Array(await blob.arrayBuffer());
            const buffer = module._malloc(bytes.length || 1);
            module.HEAPU8.set(bytes, buffer);
            addClipboardReadItem(type, buffer, bytes.length);
            module._free(buffer);
            if (type === 'text/plain') {
              text = new TextDecoder().decode(bytes);
            }
          }
        }
        answer(text);
      })
      .catch(() => navigator.clipboard.readText()
        .then((text) => {
          beginClipboardReadItems();
          answer(text);
        })
        .catch((error) => {
          debugLog(`clipboard read refused: ${error.message}`);
          beginClipboardReadItems();
          answer('');
        }));
  }

  // Ask before reading, when Core says the read policy is Prompt.
  //
  // The browser's own permission prompt is not this gate: it is asked once per
  // origin and then remembered, so after the first grant every later read by any
  // program is silent. Core's policy is per read, which is the difference between
  // "this page may use the clipboard" and "this program may have it now".
  //
  // Built here rather than with window.confirm: pumpClipboard runs inside paint(),
  // and confirm() blocks the event loop, so the terminal would freeze mid-frame
  // for as long as the dialog is up.
  function askClipboardRead() {
    return new Promise((resolve) => {
      const backdrop = document.createElement('div');
      backdrop.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.55);'
        + 'display:flex;align-items:center;justify-content:center;z-index:2147483647;'
        + 'font:14px system-ui,-apple-system,sans-serif;';
      const panel = document.createElement('div');
      panel.style.cssText = 'background:#1e1e1e;color:#eee;padding:20px 22px;border-radius:8px;'
        + 'max-width:32em;box-shadow:0 8px 32px rgba(0,0,0,0.5);';
      const message = document.createElement('div');
      message.textContent = 'A program running in this terminal is asking to read your clipboard.';
      message.style.cssText = 'margin-bottom:16px;line-height:1.45;';
      const row = document.createElement('div');
      row.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;';
      const deny = document.createElement('button');
      deny.textContent = 'Deny';
      const allow = document.createElement('button');
      allow.textContent = 'Allow';
      for (const button of [deny, allow]) {
        button.style.cssText = 'padding:6px 14px;border-radius:5px;border:1px solid #555;'
          + 'background:#2d2d2d;color:#eee;cursor:pointer;font:inherit;';
      }
      row.append(deny, allow);
      panel.append(message, row);
      backdrop.append(panel);

      // One resolution, whichever way it arrives. A second click after the panel
      // is gone would answer a request that has already been completed.
      let settled = false;
      const finish = (approved) => {
        if (settled) {
          return;
        }
        settled = true;
        backdrop.remove();
        document.removeEventListener('keydown', onKey, true);
        resolve(approved);
      };
      function onKey(event) {
        if (event.key === 'Escape') {
          event.preventDefault();
          finish(false);
        }
      }
      // Escape denies, and so does clicking away: the safe answer is the one a
      // user reaches by dismissing something they did not ask for.
      backdrop.addEventListener('click', (event) => {
        if (event.target === backdrop) {
          finish(false);
        }
      });
      document.addEventListener('keydown', onKey, true);
      deny.addEventListener('click', () => finish(false));
      allow.addEventListener('click', () => finish(true));
      document.body.append(backdrop);
      deny.focus(); // the default is refusal, including for a stray Enter
    });
  }

  function pumpClipboard() {
    // The typed set first: when the browser takes it, the text rode along
    // inside it and the string staging is consumed with it.
    if (!clipboardWriteInFlight) {
      const write = hasPendingClipboardWrite() ? pendingClipboardWrite() : null;
      // Consume this exact staged operation before awaiting browser promises;
      // its completion must not erase a newer write staged in the meantime.
      const operation = writeTypedClipboardItems(write);
      takeClipboardWrite();
      const pending = operation || (write !== null ? navigator.clipboard.writeText(write) : null);
      if (pending) {
        clipboardWriteInFlight = true;
        pending.catch((error) => debugLog(`clipboard write refused: ${error.message}`))
          .finally(() => { clipboardWriteInFlight = false; });
      }
    }
    // One read at a time. This runs per frame, so without the guard a pending
    // request would fire a fresh permission prompt on every frame until the
    // first resolved.
    if (wantsClipboardRead() && !clipboardReadInFlight) {
      clipboardReadInFlight = true;
      const answer = (text) => {
        clipboardReadInFlight = false;
        provideClipboardRead(text);
        paint();
      };
      const read = () => readTypedClipboard(answer);
      // Confirm first when Core asks for it, and read only on approval. A denial
      // answers empty, which is the same reply Core sends for a Deny policy: the
      // program learns nothing and is not left waiting.
      if (clipboardReadNeedsConfirmation()) {
        askClipboardRead().then((approved) => (approved ? read() : answer('')));
      } else {
        read();
      }
    }
    pumpClipboardServe();
  }

  // The other direction: a program on the HOST asked for a clipboard its
  // machine does not have — a headless box runs no display server — and this
  // browser's is what answers.
  //
  // Answered without a prompt, because the prompt already happened: the page
  // claims ClipboardServe in its Greet only when it opted in, and that opt-in
  // is a person naming this channel and opening it. A confirmation per xclip
  // would be answered by reflex within a day, which trains people past the
  // dialog that matters rather than protecting anything. A page that has not
  // opted in never claims the bit, so the host never asks and this never runs.
  //
  // The wire's status values, which are Core's and not this file's to invent:
  // 0 OK, 1 empty, 2 refused, 3 too large.
  function pumpClipboardServe() {
    // One at a time, like the read above: this runs per frame, and without the
    // guard a pending request would fire a fresh permission prompt on every
    // frame until the first resolved.
    if (!pendingClipboardServeID() || clipboardServeInFlight) return;
    clipboardServeInFlight = true;

    const send = (status) => {
      clipboardServeInFlight = false;
      const base = buildClipboardServeAnswer(status);
      if (base) sendFrame(base);
    };
    const wantsTypes = pendingClipboardServeWantsTypes() !== 0;
    // Read before the await: the request is dropped when the answer is framed,
    // and by then this would read the next one's, or 0. What these read is the
    // oldest unanswered question, and a question arriving during the read
    // queues behind it rather than displacing it, so the answer below is framed
    // under the same id these two describe.
    const wanted = wantsTypes ? '' : pendingClipboardServeMime();

    navigator.clipboard.read()
      .then(async (items) => {
        beginClipboardServeItems();
        let served = false;
        for (const item of items) {
          for (const type of item.types) {
            // A type list answers with names and no bytes: the asking tool is
            // `xclip -o -t TARGETS`, which throws any payload away.
            if (wantsTypes) {
              addClipboardServeItem(type, 0, 0);
              served = true;
              continue;
            }
            // Parameters are part of the name on the wire but not of the
            // match, and case is not either — the same rule the macOS
            // pasteboard applies, because a host program asking for
            // image/png;base64 means the same payload both places.
            if (type.split(';')[0].toLowerCase() !== wanted.split(';')[0].toLowerCase()) continue;
            const bytes = new Uint8Array(await (await item.getType(type)).arrayBuffer());
            const buffer = module._malloc(bytes.length || 1);
            module.HEAPU8.set(bytes, buffer);
            addClipboardServeItem(type, buffer, bytes.length);
            module._free(buffer);
            served = true;
            break;
          }
          if (served && !wantsTypes) break;
        }
        // Empty rather than refused when the clipboard holds nothing of that
        // type: the difference is "there is no PNG here" against "this page
        // will not tell you", and a tool can act on the first.
        send(served ? 0 : 1);
      })
      .catch((error) => {
        // The browser refused the read — no permission, or no user gesture in
        // a browser that demands one. Refused rather than silence: the program
        // that asked is blocked on a reply, and one it can see beats a wait it
        // cannot end.
        debugLog(`clipboard serve refused: ${error.message}`);
        beginClipboardServeItems();
        send(2);
      });
  }

  // Counted here rather than inside a renderer, so the CPU and GPU paths are
  // measured by the same clock and ?gpu=0 is an A/B rather than two numbers
  // that were never comparable.
  // Declared here, above every reader. A `let` is in its temporal dead zone
  // until its declaration is EVALUATED, not merely hoisted, so a reader that
  // runs first throws ReferenceError and kills the page before it draws.
  // Tests/Web/page-smoke.mjs catches it.
  let socket = null;

  // The host's verdict on this attach, and the same dead-zone rule: every writer
  // of the status line below reads it. A verdict outranks whatever the page
  // would otherwise print, because the two events that erase it arrive within a
  // frame of it — a refused attach drops the connection, so the reconnect
  // countdown would replace the one line saying why the screen is empty, and the
  // half-second frame tick would replace it with a cell count. Core owns the
  // wording; this owns only that it reaches the screen.
  let hostVerdict = '';
  function showStatus(text) { status.textContent = hostVerdict || text; }

  // An unoptimised host is indistinguishable from a slow one from here — the
  // frames arrive less often. A build directory a test run reconfigured, or a
  // daemon still executing a pre-rebuild binary, leaves every gate green,
  // because neither is a defect in the tree. The host says when it is
  // unoptimised, so the page says. Only while attached: a standalone page has
  // no host to report on.
  function hostWarning() {
    return (socket && !hostIsOptimised()) ? ' — HOST IS UNOPTIMISED' : '';
  }

  function countFrame() {
    frameCount++;
    const now = performance.now();
    if (now - fpsSince < 500) return;
    fps = Math.round((frameCount * 1000) / (now - fpsSince));
    frameCount = 0;
    fpsSince = now;
    if (statusText || hostVerdict) showStatus(statusText);
    const elapsed = now - feedWindowSince;
    const mib = feedBytesTotal / (1024 * 1024);
    feedRate = `feed ${Math.round((msFeed / elapsed) * 100)}% ${(mib / (elapsed / 1000)).toFixed(1)}MiB/s`;
    msFeed = 0;
    feedBytesTotal = 0;
    feedWindowSince = now;
  }

  // The browser tab is this frontend's title bar, so OSC 0/2 lands there. Read
  // per paint and written only on a change: assigning document.title is cheap
  // but not free, and a shell that rewrites its title per prompt would otherwise
  // touch it on every frame.
  const BASE_TITLE = document.title;
  let shownTitle = '';
  // Fit the grid to the window and tell the host, when there is one. The window,
  // the cell and the padding each change what fits, and all of them end here: a
  // fit that reached the local grid without reaching the host leaves the shell
  // drawing for a size the page no longer has.
  function refitGrid() {
    const fitted = gridForWindow();
    if (fitted.rows === grid.rows && fitted.columns === grid.columns) return false;
    grid = fitted;
    resize(grid.rows, grid.columns);
    if (socket) sendFrame(buildResize(grid.rows, grid.columns));
    return true;
  }

  // OSC 50 asked for a family. The rasterizer reads Module.ubiquittyFontFamily,
  // which only this side owns, so Core stages the request and the page applies
  // it — then the stack has to be rebuilt, because the metrics it cached belong
  // to the family that was just replaced.
  // The axes a canvas font shorthand cannot name — everything but `wght` —
  // reach the raster only through a face that already carries them. So one is
  // built: FontFaces over the same sources, under a derived family name, with
  // the axes as their `variationSettings` descriptor. The terminal is then told
  // to draw with that name.
  //
  // The alias is what makes this work at all. A descriptor cannot be added to a
  // family the page has already served without replacing it, and replacing it
  // would apply the axes to every use of that family on the page rather than to
  // the terminal.
  //
  // Weight is not among the axes: a `font-variation-settings`
  // descriptor outranks `font-weight` for the axis it names, so a weight here
  // would pin every cell to one and the SGR tier and the bold face would both
  // stop moving. It travels per glyph instead.
  //
  // `prepareFont` builds the faces, the one route `configure` takes too: every
  // style of the family under the alias, from `local()` for a family the
  // machine has and from the served files for the bundled one. A single
  // upright face under the alias would leave bold and italic cells to the
  // browser's synthesis.
  async function applyFontVariationAlias(family) {
    const settings = fontVariationSettingsCSS();
    // `font.features` rides the same face rather than a second one: a cell is
    // drawn in one family, so two aliases would mean the later registration
    // silently discarding the earlier one's descriptor. The browser is this
    // arm's shaper — the rasterizer shapes grid text by drawing it in this
    // face — and a FontFace descriptor is the only place to name a feature.
    const features = fontFeatureSettingsCSS();
    if (!settings && !features) return;
    if (typeof FontFace === 'undefined' || !document.fonts) {
      debugLog(`font descriptors: no FontFace here, ${settings || ''} ${features || ''} not applied`);
      return;
    }
    // In this document and in the one a shared module rasterizes in, as
    // `configure` registers them.
    const [alias] = await Promise.all([
      prepareFont(family, features, settings, module.ubiquittyFontCoverage),
      module.ubiquittyPrepareFont?.(family, features, settings, module.ubiquittyFontCoverage),
    ]);
    if (alias === family) {
      // Left on the plain family rather than switched to one that did not load:
      // a terminal drawing the face it already had is the smaller loss.
      debugLog(`font descriptors: no face for ${family} loaded, nothing applied`);
      return;
    }
    module.ubiquittyFontFamily = alias;
    debugLog(`font descriptors: drawing with ${alias} at ${settings || '-'} / ${features || '-'}`);
    // The same three steps applyPendingFontFamily takes, and for the same
    // reason: the size has not changed, so setFontSize would decline, and the
    // metrics the renderer holds belong to the family just replaced.
    rebuildFont();
    cellPx = { width: cellWidthPx(), height: cellHeightPx() };
    refitGrid();
  }

  function applyPendingFontFamily() {
    const family = pendingFontFamily();
    if (!family) return;
    takeFontFamily();
    module.ubiquittyFontFamily = family;
    debugLog(`OSC 50: font family -> ${family}`);
    // An explicit rebuild: the size has not changed, so setFontSize would
    // decline, and the cached metrics belong to the family just replaced.
    rebuildFont();
    cellPx = { width: cellWidthPx(), height: cellHeightPx() };
    refitGrid();
  }

  // OSC 9 / OSC 777. Taken whether or not it can be shown: a notification the
  // page cannot raise is still spent, and re-offering it every frame would queue
  // one per paint the moment permission is granted.
  //
  // Permission is never REQUESTED here — a prompt raised from a paint is the
  // pattern browsers block, and one a program can trigger at will is worse than
  // useless. The page asks on a keystroke instead, which is a user gesture.
  let notificationPermissionAsked = false;
  function requestNotificationPermissionOnce() {
    if (notificationPermissionAsked || typeof Notification === 'undefined') return;
    notificationPermissionAsked = true;
    if (Notification.permission !== 'default') return;
    Notification.requestPermission().catch(() => {});
  }

  function showPendingNotification() {
    // Core composed the heading and the text, and names the notification: one
    // shown under a tag a standing one holds replaces it.
    const title = pendingNotificationTitle();
    const body = pendingNotificationBody();
    const tag = pendingNotificationTag();
    if (!title && !body) return;
    takeNotification();
    if (typeof Notification === 'undefined' || Notification.permission !== 'granted') {
      debugLog(`notification suppressed (permission ${typeof Notification === 'undefined' ? 'unavailable' : Notification.permission}): ${title || body}`);
      return;
    }
    try {
      new Notification(title || 'Ubiquitty', { body, tag });
    } catch (e) {
      debugLog(`notification refused: ${e.message}`);
    }
  }

  function syncDocumentTitle() {
    const next = terminalTitle() || '';
    if (next === shownTitle) return;
    shownTitle = next;
    document.title = next || BASE_TITLE;
  }

  let searchPumpQueued = false;
  let isSearchOpen = false;
  let searchPaintQueued = false;
  let publishedSearchJSON = '';

  function publishSearch() {
    const encoded = searchStatusJSON();
    if (encoded === publishedSearchJSON) return;
    publishedSearchJSON = encoded;
    if (socket) sendOwedHostFrames();
    window.dispatchEvent(new CustomEvent('ubiquitty-search', { detail: JSON.parse(encoded) }));
    if (searchPaintQueued) return;
    searchPaintQueued = true;
    requestAnimationFrame(() => {
      searchPaintQueued = false;
      paint();
    });
  }

  function queueSearchPump() {
    if (searchPumpQueued) return;
    searchPumpQueued = true;
    const run = () => {
      searchPumpQueued = false;
      const hasMore = pumpSearch();
      publishSearch();
      if (hasMore) queueSearchPump();
    };
    if (typeof window.requestIdleCallback === 'function')
      window.requestIdleCallback(run, { timeout: 100 });
    else
      setTimeout(run, 0);
  }

  function paint() {
    if (isSearchOpen) queueSearchPump();
    bookDisplayIdle();
    pumpClipboard();
    // Per frame: the mode is set by an escape sequence off the host stream, and
    // there is no other moment the page reliably sees it change.
    reconcilePointerLock(canvas);
    bookHintRepaint();
    // DECSET 2026: a program is mid-composition. Asked here rather than inside
    // a renderer because the CPU raster has no opinion about it — a frame
    // withheld from the instance path and then drawn by the raster was never
    // withheld. The canvas already holds the last complete frame, so showing
    // nothing new is the correct output.
    syncDocumentTitle();
    applyPendingFontFamily();
    showPendingNotification();
    if (isFrameWithheld() || renderer?.gl.isContextLost()) return;
    // Which path drew is COUNTED, not sampled. `statusText` is one variable that
    // both paths write and the half-second tick flushes, so a session mixing them
    // prints whichever happened to paint as the tick passed — and reads as "on the
    // GPU path" while most frames took the raster. paintOnGPU returns false PER
    // FRAME (an inline image is enough), so a live renderer is not evidence that
    // any frame used it. Five investigations died on that ambiguity.
    if (renderer && paintOnGPU()) { paintRichText(); positionIME(); ++gpuFrames; countFrame(); return; }
    if (!renderer) buildFrame();
    paintOnCPU();
    paintRichText();
    positionIME();
    ++cpuFrames;
    countFrame();
  }

  // Upload only when the atlas actually changed: a frame that faulted no new
  // glyph is the common case once the screen settles, and re-uploading the whole
  // coverage texture per frame would spend more time than the draw.
  // One per sheet. A single counter for all three re-sends every sheet whenever
  // any one of them faults, and the colour sheet is four bytes per pixel where
  // the other two are one — so a mono glyph faulting re-sent megabytes of emoji
  // that had not changed.
  let uploadedMonoGeneration = -1;
  let uploadedWideGeneration = -1;
  let uploadedProportionalGeneration = -1;
  let uploadedColorGeneration = -1;
  let uploadedFontResourceGeneration = -1;
  // Hidden workspace tabs retain Core state without occupying a browser GPU
  // context. A restored context has no textures, even when Core's atlas epochs
  // are unchanged, so all sheets must be uploaded to its new renderer.
  canvas.addEventListener('webglcontextlost', event => {
    event.preventDefault();
    hasLostContext = true;
    if (isViewVisible && isContextSuspended)
      restoreContext();
  });
  canvas.addEventListener('webglcontextrestored', () => {
    hasLostContext = false;
    isContextSuspended = false;
    renderer = new WebGLRenderer(canvas);
    contextControl = renderer.gl.getExtension('WEBGL_lose_context');
    uploadedFontResourceGeneration = -1;
    if (isViewVisible) paint();
    else suspendContext();
  });
  function suspendContext() {
    if (contextControl && !renderer.gl.isContextLost()) {
      isContextSuspended = true;
      contextControl.loseContext();
    }
  }
  function restoreContext() {
    // WebKit admits restoration only after the loss event has finished dispatching.
    setTimeout(() => {
      if (isViewVisible && hasLostContext && isContextSuspended)
        contextControl?.restoreContext();
    }, 0);
  }
  // Instrumentation, not decoration: every previous judgement about this
  // renderer's speed was made by eye.
  let atlasUploads = 0;
  let msBuild = 0;
  let msDraw = 0;
  let statusText = '';
  let msFeed = 0;
  let feedBytesTotal = 0;
  let feedWindowSince = performance.now();
  let feedRate = '';
  let frameCount = 0;
  // Cumulative since load, not per window: a fallback that fires occasionally is
  // a different bug from one that fires always, and a rate hides the difference.
  let gpuFrames = 0;
  let cpuFrames = 0;
  let msUpload = 0;
  let fps = 0;
  let fpsSince = performance.now();

  function paintOnGPU() {
    // Four phases, timed separately, because "the renderer is slow" is not a
    // finding: the build is wasm walking the grid, the resize is the canvas, the
    // upload is the heap crossing into GL buffers, and the draw is the GPU. They
    // have different fixes and the only way to tell them apart is to time them
    // apart. The resize rides the upload's span — it is rare and adjacent.
    const tBuild = performance.now();
    if (!buildFrame()) return false;
    msBuild = performance.now() - tBuild;
    applyBackgroundColor();
    // Pictures and Tek's storage tube have no browser GPU pass yet. Core's
    // CPU compositor draws them, including an empty active tube that must
    // cover the text grid beneath it.
    if (frameRequiresCPUCompositing()) return false;
    const count = cellInstanceCount();
    if (count <= 0) return false;

    const cellWidth = cellWidthPx();
    const cellHeight = cellHeightPx();
    const width = terminalColumns() * cellWidth;
    const height = terminalRows() * cellHeight;
    if (width <= 0 || height <= 0) return false;
    placePicture(width, height);

    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }

    // Timed, because the comment above says three phases are measured apart and
    // this one was not: the canvas resize and the atlas upload sat between
    // msBuild closing and tDraw opening, so a cost here was invisible in a
    // readout that claimed to account for the frame. An unmeasured span inside
    // an instrument that says it measures everything is worse than no
    // instrument — it answers the question wrongly instead of declining to.
    const tUpload = performance.now();
    const fontGeneration = fontResourceGeneration();
    if (fontGeneration !== uploadedFontResourceGeneration) {
      uploadedMonoGeneration = -1;
      uploadedWideGeneration = -1;
      uploadedProportionalGeneration = -1;
      uploadedColorGeneration = -1;
      uploadedFontResourceGeneration = fontGeneration;
    }
    const atlasBase = atlasPixels();
    const aWidth = atlasWidth();
    const aHeight = atlasHeight();
    // Each sheet against its own counter. Core bumps the one whose pixels it
    // wrote, so a mono fault leaves the wide and colour textures alone — and
    // none of them goes stale, because a sheet that did change moves its own
    // counter and is re-sent on this same frame.
    let didUploadAtlas = false;
    const monoGeneration = monoAtlasGeneration();
    if (atlasBase && aWidth > 0 && aHeight > 0 && monoGeneration !== uploadedMonoGeneration) {
      renderer.uploadAtlas(module.HEAPU8.subarray(atlasBase, atlasBase + aWidth * aHeight), aWidth, aHeight);
      uploadedMonoGeneration = monoGeneration;
      didUploadAtlas = true;
    }
    const wideAtlasBase = wideAtlasPixels();
    const wWidth = wideAtlasWidth();
    const wHeight = wideAtlasHeight();
    const wideGeneration = wideAtlasGeneration();
    if (wideAtlasBase && wWidth > 0 && wHeight > 0 && wideGeneration !== uploadedWideGeneration) {
      renderer.uploadWideAtlas(module.HEAPU8.subarray(wideAtlasBase, wideAtlasBase + wWidth * wHeight), wWidth, wHeight);
      uploadedWideGeneration = wideGeneration;
      didUploadAtlas = true;
    }
    const proportionalAtlasBase = proportionalAtlasPixels();
    const proportionalWidth = proportionalAtlasWidth();
    const proportionalHeight = proportionalAtlasHeight();
    const proportionalGeneration = proportionalAtlasGeneration();
    if (proportionalAtlasBase && proportionalWidth > 0 && proportionalHeight > 0
        && proportionalGeneration !== uploadedProportionalGeneration) {
      renderer.uploadProportionalAtlas(module.HEAPU8.subarray(proportionalAtlasBase,
        proportionalAtlasBase + proportionalWidth * proportionalHeight), proportionalWidth, proportionalHeight);
      uploadedProportionalGeneration = proportionalGeneration;
      didUploadAtlas = true;
    }
    const proportionalStripAtlasBase = proportionalStripAtlasPixels();
    const proportionalStripWidth = proportionalStripAtlasWidth();
    const proportionalStripHeight = proportionalStripAtlasHeight();
    if (proportionalStripAtlasBase && proportionalStripWidth > 0 && proportionalStripHeight > 0
        && proportionalStripAtlasIsDirty()) {
      renderer.uploadProportionalStripAtlas(module.HEAPU8.subarray(proportionalStripAtlasBase,
        proportionalStripAtlasBase + proportionalStripWidth * proportionalStripHeight),
        proportionalStripWidth, proportionalStripHeight);
      didUploadProportionalStripAtlas();
      didUploadAtlas = true;
    }
    const ligatureAtlasBase = ligatureAtlasPixels();
    const ligatureWidth = ligatureAtlasWidth();
    const ligatureHeight = ligatureAtlasHeight();
    if (ligatureAtlasBase && ligatureWidth > 0 && ligatureHeight > 0 && ligatureAtlasIsDirty()) {
      renderer.uploadLigatureAtlas(module.HEAPU8.subarray(ligatureAtlasBase,
        ligatureAtlasBase + ligatureWidth * ligatureHeight), ligatureWidth, ligatureHeight);
      didUploadLigatureAtlas();
      didUploadAtlas = true;
    }
    // Four bytes per pixel where the other two are one — the subarray length is
    // the difference, and getting it wrong uploads a quarter of the sheet and
    // stretches it over the whole texture.
    const colorAtlasBase = colorAtlasPixels();
    const cWidth = colorAtlasWidth();
    const cHeight = colorAtlasHeight();
    const colorGeneration = colorAtlasGeneration();
    if (colorAtlasBase && cWidth > 0 && cHeight > 0 && colorGeneration !== uploadedColorGeneration) {
      renderer.uploadColorAtlas(module.HEAPU8.subarray(colorAtlasBase, colorAtlasBase + cWidth * cHeight * 4), cWidth, cHeight);
      uploadedColorGeneration = colorGeneration;
      didUploadAtlas = true;
    }
    if (didUploadAtlas)
      atlasUploads++;
    msUpload = performance.now() - tUpload;

    const cellBase = cellInstances();
    if (!cellBase) return false;
    const decorationBase = decorationInstances();
    const decorationCount = decorationInstanceCount();
    const overlayBase = overlayInstances();
    const overlayCount = overlayInstanceCount();
    const boxFillBase = boxFillInstances();
    const boxFillCount = boxFillInstanceCount();
    const glyphBase = glyphInstances();
    const glyphCount = glyphInstanceCount();
    const wideBase = wideGlyphInstances();
    const wideCount = wideGlyphInstanceCount();
    const proportionalBase = proportionalGlyphInstances();
    const proportionalCount = proportionalGlyphInstanceCount();
    const proportionalStripBase = proportionalStripInstances();
    const proportionalStripCount = proportionalStripInstanceCount();
    const ligatureBase = ligatureGlyphInstances();
    const ligatureCount = ligatureGlyphInstanceCount();
    const colorGlyphBase = colorGlyphInstances();
    const colorGlyphCount = colorGlyphInstanceCount();

    // Views onto the wasm heap rather than copies: bufferData reads them
    // synchronously, so nothing can move underneath.
    const tDraw = performance.now();
    renderer.drawFrame({
      cellBytes: module.HEAPU8.subarray(cellBase, cellBase + count * 64),
      cellCount: count,
      decorationBytes: decorationCount > 0 ? module.HEAPU8.subarray(decorationBase, decorationBase + decorationCount * 160) : null,
      decorationCount,
      overlayBytes: overlayCount > 0 ? module.HEAPU8.subarray(overlayBase, overlayBase + overlayCount * 112) : null,
      overlayCount,
      boxFillBytes: boxFillCount > 0 ? module.HEAPU8.subarray(boxFillBase, boxFillBase + boxFillCount * 112) : null,
      boxFillCount,
      isBitmapFace: Boolean(frameUsesBitmapFace()),
      glyphBytes: glyphCount > 0 ? module.HEAPU8.subarray(glyphBase, glyphBase + glyphCount * 64) : null,
      glyphCount,
      wideGlyphBytes: wideCount > 0 ? module.HEAPU8.subarray(wideBase, wideBase + wideCount * 64) : null,
      wideGlyphCount: wideCount,
      proportionalGlyphBytes: proportionalCount > 0 ? module.HEAPU8.subarray(proportionalBase, proportionalBase + proportionalCount * 64) : null,
      proportionalGlyphCount: proportionalCount,
      proportionalStripBytes: proportionalStripCount > 0 ? module.HEAPU8.subarray(proportionalStripBase, proportionalStripBase + proportionalStripCount * 64) : null,
      proportionalStripCount,
      ligatureGlyphBytes: ligatureCount > 0 ? module.HEAPU8.subarray(ligatureBase, ligatureBase + ligatureCount * 64) : null,
      ligatureGlyphCount: ligatureCount,
      colorGlyphBytes: colorGlyphCount > 0 ? module.HEAPU8.subarray(colorGlyphBase, colorGlyphBase + colorGlyphCount * 64) : null,
      colorGlyphCount,
      cursorTier: {
        cellCount: cursorTierCellCount(),
        glyphCount: cursorTierGlyphCount(),
        wideGlyphCount: cursorTierWideGlyphCount(),
        proportionalGlyphCount: cursorTierProportionalGlyphCount(),
        proportionalStripCount: cursorTierProportionalStripCount(),
        ligatureGlyphCount: cursorTierLigatureGlyphCount(),
        colorGlyphCount: cursorTierColorGlyphCount(),
        decorationCount: cursorTierDecorationCount(),
        boxFillCount: cursorTierBoxFillCount(),
      },
      cellWidth, cellHeight, width, height,
    });
    // The atlas upload and the paint are the two costs worth watching, and both
    // were invisible: an atlas whose generation moves every frame re-uploads a
    // texture the size of every slot it holds, which looks exactly like a slow
    // renderer from outside. `u` counts uploads since load — a number that
    // keeps climbing while the screen is still is the thrash.
    msDraw = performance.now() - tDraw;
    // Composed here, written on the half-second tick. Assigning textContent
    // every frame forces a style recalculation, which would make the readout
    // part of what it is reporting.
    statusText = `${terminalColumns()}x${terminalRows()} — ${width}x${height}px — WebGL2 `
      + `${count}c/${decorationCount}d/${overlayCount}o — ${fps}fps `
      + `— build ${msBuild.toFixed(1)} upload ${msUpload.toFixed(1)} draw ${msDraw.toFixed(1)}ms `
      + `— gpu${gpuFrames}/cpu${cpuFrames} — ${feedRate} — u${atlasUploads}${hostWarning()}`
      + (debugPanel.dataset.rx ? ` — ${debugPanel.dataset.rx}` : '');
    return true;
  }

  function paintOnCPU() {
    const base = render();
    if (!base) return;
    applyBackgroundColor();
    const width = imageWidth();
    const height = imageHeight();
    if (width <= 0 || height <= 0) return;
    placePicture(width, height);
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      // Present at exactly one device pixel per rendered pixel. Sizing the
      // element in CSS pixels rather than letting it fill the viewport is what
      // stops the browser scaling the old image while the window is mid-drag:
      // the grid only ever changes in whole cells, and the leftover strip is
      // background rather than a stretched row.
    }
    // A view onto the wasm heap. No per-pixel work here: Core already
    // composited with the same mix() the GPU backends use.
    const tBlit = performance.now();
    // A VIEW over the wasm heap, not a copy of it. `new Uint8ClampedArray(x)`
    // where x is a typed array allocates and copies a whole frame's pixels
    // that are already contiguous and already the right bytes. The
    // (buffer, byteOffset, length) form aliases instead.
    //
    // Rebuilt every frame rather than cached: growing the wasm heap detaches its
    // ArrayBuffer, and a view held across that grows a zero length rather than
    // faulting. putImageData reads synchronously and keeps nothing, so aliasing
    // the heap is safe for exactly as long as this call.
    const pixels = new Uint8ClampedArray(module.HEAPU8.buffer, base, width * height * 4);
    if (renderer) {
      renderer.presentRGBA(pixels, width, height);
    } else {
      if (!context) context = canvas.getContext('2d');
      if (!context) {
        status.textContent = 'Could not create a canvas renderer';
        return;
      }
      context.putImageData(new ImageData(pixels, width, height), 0, 0);
    }
    msDraw = performance.now() - tBlit;
    // A frame-by-frame fallback (an inline image, which the GPU path has no pass
    // for) is not the same as never having had a renderer, and the two want
    // different fixes — so the line says which.
    const why = cpuReason || (renderer ? 'no GPU pass for this frame' : 'no renderer');
    statusText = `${grid.columns}x${grid.rows} — ${width}x${height}px — CPU (${why}) — ${fps}fps `
      + `— raster ${msDraw.toFixed(1)}ms — gpu${gpuFrames}/cpu${cpuFrames} — ${feedRate}${hostWarning()}`
      + (debugPanel.dataset.rx ? ` — ${debugPanel.dataset.rx}` : '');
  }

  // A window resize is a terminal resize: Core rewraps the scrollback, so the
  // text reflows the way it does on every other frontend.
  let pending = 0;
  function reflow() {
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(() => {
      // Attached, refitGrid tells the host too: it owns the PTY, so the reflow
      // that comes back is the host's rather than a local guess.
      refitGrid();
      // Even a sub-cell resize changes Fit/Pan placement and the clip.
      paint();
    });
  }
  window.addEventListener('resize', reflow);

  // The standalone banner, and only when standalone: attached, the grid belongs
  // to the host's PTY and anything written here is a local scribble the host
  // never sent. It also outlives the attach — a shell that has not printed yet
  // leaves the banner on screen, which reads as "the attach did nothing".
  if (!params.get('attach') && !workspaceView) {
    feed('\x1b[1;32mUbiquitty\x1b[0m running in the browser.\r\n');
    feed('Portable Core, \x1b[4mno JavaScript renderer\x1b[0m.\r\n\r\n');
    feed('  \x1b[38;5;110m┌───────────────┐\x1b[0m\r\n');
    feed('  \x1b[38;5;110m│\x1b[0m box drawing   \x1b[38;5;110m│\x1b[0m\r\n');
    feed('  \x1b[38;5;110m└───────────────┘\x1b[0m\r\n\r\n');
    feed('  Resize the window — the reflow is Core\'s, not the page\'s.\r\n');
  }
  paint();

  // --- Attached mode -------------------------------------------------------
  //
  // The page owns the socket; Core owns the protocol. SyncClientCore is
  // transport-free, so JavaScript only moves bytes: what the socket delivers
  // goes to feedFromHost, and what build* produces goes on the wire. No framing,
  // no parsing, no protocol knowledge here — that all compiled into the wasm.

  function sendFrame(base) {
    if (!base || !socket || socket.readyState !== WebSocket.OPEN) return;
    const length = frameLength();
    if (length <= 0) return;
    // Copy out of the heap: send() is async and the buffer is reused by the
    // next build call.
    socket.send(module.HEAPU8.slice(base, base + length));
  }

  // Shows Core's notice while some of what was typed may not have reached the
  // host, and takes it down once nothing awaits the person's answer. Read as
  // a standing value after every feed, the way the host's verdict is. The
  // notice is a region, not a dialog: the terminal keeps the keyboard, and
  // what is typed waits behind the input in doubt.
  function updateInputInDoubt() {
    const message = inputInDoubtMessage();
    if (!message) {
      inputInDoubt.hidden = true;
      return;
    }
    if (inputInDoubt.hidden) debugLog(`input in doubt — ${message}`);
    inputInDoubtMessageLine.textContent = message;
    inputInDoubtDetailLine.textContent = inputInDoubtDetail();
    inputInDoubtSendAgain.textContent = inputInDoubtResendButton();
    inputInDoubtDiscard.textContent = inputInDoubtDiscardButton();
    inputInDoubt.hidden = false;
  }

  // The two answers reach Core only from these buttons: sending again can run
  // a command twice, so nothing sends it unasked.
  function answerInputInDoubt(answer) {
    sendFrame(answer());
    updateInputInDoubt();
    focusTerminal();
  }
  inputInDoubtSendAgain.addEventListener('click', () => answerInputInDoubt(resendInputInDoubt));
  inputInDoubtDiscard.addEventListener('click', () => answerInputInDoubt(discardInputInDoubt));

  // Sends what the screen plane owes the host, then arms one timer for the
  // acknowledgement it will owe next: Core holds an acknowledgement a few
  // milliseconds to cover several updates with it.
  let owedFramesTimer = null;
  function sendOwedHostFrames() {
    const owed = takePendingHostFrame(Math.min(0x7fffffff, socket ? socket.bufferedAmount : 0));
    if (owed) sendFrame(owed);
    if (owedFramesTimer !== null) return;
    const delay = screenTickDelay();
    if (delay < 0) return;
    owedFramesTimer = setTimeout(() => {
      owedFramesTimer = null;
      sendOwedHostFrames();
    }, delay);
  }

  // --- The host's sessions -------------------------------------------------
  //
  // Which sessions the host holds, so a row can attach one — for the list this
  // page draws and for a sidebar embedding it. The reply is asynchronous and
  // lands on a frame carrying nothing else, so the generation is polled where
  // host bytes are fed and the list is read only when it moves. A terminate
  // settles the same way, on its own generation.

  // The generation this page has already reported. Compared rather than reset,
  // so a reconnect that re-asks is one more answer and not a special case.
  let reportedAnswerGeneration = 0;
  let reportedTerminateGeneration = 0;

  // Asks the host to enumerate its sessions. Discarded while detached — there is
  // no host to answer, and sendFrame drops it rather than queueing a query whose
  // answer would describe a connection that has since been replaced.
  function requestSessions() {
    const frame = buildListSessions();
    if (!frame) return false;
    sendFrame(frame);
    return true;
  }

  // Subscribes this connection to the host's outline. The rows arrive as
  // 'ubiquitty-outline' once the host has described itself, and again whenever
  // anything on the host changes. Answers false while there is no connection
  // the host has welcomed, and a new connection has to ask again.
  let reportedOutlineGeneration = 0;
  function requestOutline() {
    if (!subscribeHostListing()) return false;
    sendOwedHostFrames();
    return true;
  }

  // The outline as the page draws it: `rows` in order, each with its title,
  // depth, status, colours and whether it is open. One JSON text a call,
  // because Core writes the rows and the page decides nothing about them.
  function readOutline(query = '') {
    const outline = JSON.parse(hostOutlineJSON(query));
    outline.refused = isHostListingRefused() !== 0;
    return outline;
  }

  // Closes or opens one row and reports the outline again. A row is named by
  // its `id`, or by its `recorded` member where a restorable workspace's
  // window or tab has none.
  function setOutlineRowOpen(row, open) {
    const recorded = row.recorded;
    const level = recorded ? (recorded.level === 'window' ? 1 : 2) : 0;
    const changed = row.id
      ? (open ? expandHostOutlineRow(row.id) : collapseHostOutlineRow(row.id))
      : recorded && (open ? expandRecordedHostOutlineRow(recorded.workspace, level, recorded.window, recorded.tab)
        : collapseRecordedHostOutlineRow(recorded.workspace, level, recorded.window, recorded.tab));
    if (changed) window.dispatchEvent(new CustomEvent('ubiquitty-outline', { detail: readOutline() }));
    return Boolean(changed);
  }

  function reportOutlineIfChanged() {
    const generation = hostOutlineGeneration();
    if (generation === reportedOutlineGeneration) return;
    reportedOutlineGeneration = generation;
    const outline = readOutline();
    // The page's own panel is drawn from the same rows an embedder gets, and
    // before the event, so a listener that reads the DOM sees it built.
    renderSessionPanel(outline);
    window.dispatchEvent(new CustomEvent('ubiquitty-outline', { detail: outline }));
  }

  // Follows the connect rule once the host has described itself. A host holding
  // nothing is an answer — every session ended — which is why the generation
  // and not the rows decides.
  function followConnectRuleIfAnswered() {
    const generation = hostAnswerGeneration();
    if (generation === reportedAnswerGeneration) return;
    reportedAnswerGeneration = generation;
    // Last, because it may reconnect: the rule reads the tree this answer just
    // delivered, and the panel has to have drawn it first.
    followConnectRule();
  }

  // A reload should reattach to the shell it left. The host reattaches a
  // session whose id a Greet carries, so the page keeps that id per tab and per
  // host: sessionStorage ends with the tab, which is the lifetime a window's
  // session should have, and keying by URL stops one host's id reaching another.
  const sessionKeyFor = (url) => `ubiquitty.session.${url}`;
  function recallSession(url) {
    try { return Number(sessionStorage.getItem(sessionKeyFor(url))) || 0; } catch { return 0; }
  }
  function rememberSession(url, id) {
    try { sessionStorage.setItem(sessionKeyFor(url), String(id)); } catch { /* private mode */ }
  }

  // --- The window across a reload -------------------------------------------
  //
  // The window's client instance and its resume record, both per tab and per
  // host for the reason the session id is. Core owns the record — its shape,
  // when it is written and when it is purged — and writes it into the tab's
  // session storage synchronously through the slot it was given; the page only
  // names the keys and hands the stored instance back. Installed once, before
  // the first greeting, so the stored picture is painted before any packet and
  // the greeting resumes the attachment the window held.
  const resumeKeyFor = (url) => `ubiquitty.resume.${url}`;
  const clientKeyFor = (url) => `ubiquitty.client.${url}`;
  let isResumeInstalled = false;
  function installResume(url) {
    if (isResumeInstalled) return;
    isResumeInstalled = true;
    let stored = '';
    try { stored = sessionStorage.getItem(clientKeyFor(url)) || ''; } catch { return; }
    const instance = restoreResume(resumeKeyFor(url), stored);
    if (!instance) return;
    try { sessionStorage.setItem(clientKeyFor(url), instance); } catch { /* private mode */ }
    if (showsRestoredPicture()) {
      showStatus('reconnecting…');
      paint();
    }
  }
  // Hidden or unloaded, the window stores the newest picture it holds. A tab
  // that is only hidden may never come back, and pagehide is the last event a
  // closing or reloading page is sure to see.
  window.addEventListener('pagehide', () => persistResume());
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') persistResume();
  });

  // --- The pairing this host was last attached on --------------------------
  //
  // Beside the tab-scoped recall above rather than instead of it. They answer
  // different questions: a tab's own session is what a RELOAD returns to, and
  // the per-host record is what a FRESH tab has where it would otherwise have
  // nothing. So the tab store stays and this one is added, in localStorage,
  // which is the only store that outlives the tab.
  //
  // The bytes are Core's record and opaque here — one code unit per byte,
  // written with String.fromCharCode rather than JSON because the record holds
  // a zero byte and a length-prefixed name, and a text encoding that
  // reinterprets either of those hands back a record that decodes to nothing.
  const hostRecordKeyFor = (url) => `ubiquitty.host.${url}`;

  function loadStoredHostRecord(url) {
    let stored = '';
    try { stored = localStorage.getItem(hostRecordKeyFor(url)) || ''; } catch { return; }
    // Nothing stored is handed over as nothing, not skipped: a record left in
    // the wasm by a previous host would otherwise stand in for this one's.
    if (!stored) { loadHostRecord(url, 0, 0); return; }
    const buffer = module._malloc(stored.length);
    try {
      for (let index = 0; index < stored.length; ++index)
        module.HEAPU8[buffer + index] = stored.charCodeAt(index) & 0xff;
      loadHostRecord(url, buffer, stored.length);
    } finally {
      module._free(buffer);
    }
  }

  function storeHostRecord(url) {
    const base = hostRecordBytes(url);
    const length = hostRecordLength(url);
    let stored = '';
    for (let index = 0; index < length; ++index)
      stored += String.fromCharCode(module.HEAPU8[base + index]);
    try {
      if (stored) localStorage.setItem(hostRecordKeyFor(url), stored);
      else localStorage.removeItem(hostRecordKeyFor(url));
    } catch { /* private mode */ }
  }

  // Sessions persist unless this host explicitly opts into ending on detach.
  const keepUnnamedKeyFor = (url) => `ubiquitty.keepunnamed.${url}`;
  function keepsUnnamedSessions(url) {
      try {
          return localStorage.getItem(keepUnnamedKeyFor(url)) !== '0';
      } catch {
          return true;
      }
  }
  function setKeepsUnnamedSessions(url, keeps) {
    try { localStorage.setItem(keepUnnamedKeyFor(url), keeps ? '1' : '0'); } catch { /* private mode */ }
  }

  // --- The session panel ---------------------------------------------------
  //
  // The host's outline — its workspaces, windows, tabs and panes — as the rows
  // Core decided (`outline.js` draws them), a title per row that opens what
  // the row stands for, and a Terminate that asks Core's question before it
  // acts.
  //
  // No product logic here. Which session a connect lands on is Core's rule
  // over the host's tree (`decideAttach` below), what each row says and what
  // opening it reaches are Core's outline, what ending it costs is Core's
  // question, and the outcome of a terminate is Core's classification of the
  // frames. This file draws, forwards a click, and shows the question in
  // place.
  const sessionsPanel = document.getElementById('sessions');
  const sessionRows = document.getElementById('session-rows');
  const sessionsEmpty = document.getElementById('sessions-empty');
  const sessionsOutcome = document.getElementById('sessions-outcome');
  const sessionsOpen = document.getElementById('sessions-open');
  const newSessionButton = document.getElementById('new-session');
  const refreshSessionsButton = document.getElementById('refresh-sessions');
  const hideSessionsButton = document.getElementById('hide-sessions');
  const keepUnnamedBox = document.getElementById('keep-unnamed');

  // The panel is raised by the person asking for it and by the connect rule when
  // it says the choice is theirs — never by a list arriving. A reply lands after
  // every attach and after every terminate, and a panel that rose on each of
  // them would cover the shell somebody is typing in.
  function setSessionsPanelShown(shown) {
    sessionsPanel.hidden = !shown;
    // The reopen button exists only while there is a host to list. It and the
    // panel are never both up: one is the other's absence.
    sessionsOpen.hidden = shown || !attachArgs;
    if (!shown) {
      disarmTerminate();
      focusTerminal();
    }
  }

  function showTerminateOutcome(text) {
    sessionsOutcome.textContent = text;
    debugLog(text);
  }

  // The names the last drawn outline gave each session a row opens, by id. A
  // terminate outcome arrives on a frame that names only the id, and the
  // person who asked was looking at a name.
  const lastSessionNames = new Map();

  // The number in an identity the outline writes as `kind:number`.
  const identityNumber = (identity) => Number(String(identity || '').split(':')[1]) || 0;

  // What ending a row asks the host for, and about what: a workspace's row
  // ends its sessions, a pane's row or one standing for a pane ends that
  // pane's session. Nothing for a workspace nothing runs in, or for a window
  // or tab of several panes.
  function endingOf(row) {
    if (!row.id || row.state === 'restorable') return null;
    if (row.level === 'workspace') return { request: DESTRUCTIVE.terminateWorkspace, target: row.id };
    if (row.level === 'pane') return { request: DESTRUCTIVE.terminateSession, target: row.id };
    const pane = (row.own || []).find((level) => String(level.id).startsWith('pane:'));
    return pane ? { request: DESTRUCTIVE.terminateSession, target: pane.id } : null;
  }

  function renderSessionPanel(outline) {
    // A question cannot survive the render: every button is about to be
    // replaced by a different node, possibly for a different row.
    disarmTerminate();
    lastSessionNames.clear();
    const rows = outline.rows || [];
    for (const row of rows) {
      const session = identityNumber(row.open && row.open.session);
      if (session && !lastSessionNames.has(session)) lastSessionNames.set(session, row.title);
    }
    sessionsEmpty.hidden = rows.length > 0 || hostAnswerGeneration() === 0;
    renderOutlineRows(document, sessionRows, rows, {
      toggle: (row) => setOutlineRowOpen(row, !row.expanded),
      open: (row) => attachRow(row),
      rowActions: (row) => {
        const ending = endingOf(row);
        if (!ending) return [];
        const terminateButton = document.createElement('button');
        terminateButton.type = 'button';
        terminateButton.textContent = 'Terminate';
        // The label says which row it acts on. Twenty buttons all reading
        // "Terminate" are one button read twenty times to anyone not looking
        // at the row beside them.
        terminateButton.setAttribute('aria-label', `Terminate ${row.title}`);
        // Where Core's question appears while it waits for an answer.
        const question = document.createElement('span');
        question.className = 'question';
        question.hidden = true;
        terminateButton.addEventListener('click', () => askToEnd(question, row, ending));
        return [terminateButton, question];
      },
    });
  }

  // --- Terminate -----------------------------------------------------------
  //
  // The destructive action asks first, in place, in Core's words: the button's
  // row gains Core's question and its two answers. Not window.confirm: it
  // blocks the event loop, which is the same reason the clipboard prompt above
  // is built rather than called, and a blocked loop here would stall the
  // socket that is meant to answer. The question takes itself away after a
  // while, because one left on screen is one somebody else answers.
  const terminateQuestionMilliseconds = 8000;
  let openQuestion = null;
  let openQuestionTimer = null;

  function disarmTerminate() {
    if (openQuestionTimer) {
      clearTimeout(openQuestionTimer);
      openQuestionTimer = null;
    }
    if (openQuestion) {
      openQuestion.replaceChildren();
      openQuestion.hidden = true;
      openQuestion = null;
    }
  }

  function askToEnd(asked, row, ending) {
    disarmTerminate();
    const hostName = attachArgs ? attachArgs.url : '';
    const question = JSON.parse(hostDestructiveConfirmationJSON(ending.request, ending.target, hostName));
    if (!question.token) {
      showTerminateOutcome(`${row.title} — ${question.whyNot || 'nothing to ask'}`);
      return;
    }
    asked.replaceChildren();
    asked.setAttribute('role', 'group');
    asked.setAttribute('aria-label', question.title);
    const title = document.createElement('p');
    title.className = 'question-title';
    title.textContent = question.title;
    const body = document.createElement('p');
    body.className = 'question-body';
    body.textContent = question.body;
    asked.append(title, body);
    // The two in the order Core lists them, the safe one first and focused.
    let safe = null;
    for (const answer of question.buttons) {
      const element = document.createElement('button');
      element.type = 'button';
      element.textContent = answer.title;
      element.dataset.role = answer.role;
      element.addEventListener('click', () => {
        disarmTerminate();
        if (answer.role === 'destructive') terminateRow(row, ending, question.token);
      });
      asked.append(element);
      if (!safe) safe = element;
    }
    asked.hidden = false;
    openQuestion = asked;
    safe?.focus();
    openQuestionTimer = setTimeout(disarmTerminate, terminateQuestionMilliseconds);
  }

  // The two waits Core sizes, run on the page's clock because the wasm holds no
  // timer. What an elapsed wait MEANS stays in WebTerminal, which is why these
  // report the wait rather than deciding an outcome here.
  let terminateGraceTimer = null;
  let terminateDeadlineTimer = null;

  function clearTerminateTimers() {
    if (terminateGraceTimer) {
      clearTimeout(terminateGraceTimer);
      terminateGraceTimer = null;
    }
    if (terminateDeadlineTimer) {
      clearTimeout(terminateDeadlineTimer);
      terminateDeadlineTimer = null;
    }
  }

  function terminateRow(row, ending, token) {
    // A closed socket cannot carry the correlated operation.
    if (connectionState() !== 'attached') {
      showTerminateOutcome(`${row.title} — not asked: this page is not attached to the host`);
      return;
    }
    const base = buildConfirmedTerminate(ending.request, ending.target, token);
    if (!base) {
      showTerminateOutcome(`${row.title} — not asked: ${hostTerminateRefusal() || 'nothing was sent'}`);
      return;
    }
    sendTerminateFrame(base);
    showTerminateOutcome(`${row.title} — asked the host to end it`);
  }

  // Sends one session's terminate and arms its waits. A confirmed workspace
  // ends one session at a time, each sent as the one before it settles.
  function sendTerminateFrame(base) {
    clearTerminateTimers();
    sendFrame(base);
    terminateGraceTimer = setTimeout(() => {
      terminateGraceTimer = null;
      noteTerminateGraceElapsed();
      if (reportTerminateIfSettled()) return;
      // An unanswered operation may still be waiting on consent or transport.
      // Only its exact result establishes success; this wait can time out.
      terminateDeadlineTimer = setTimeout(() => {
        terminateDeadlineTimer = null;
        noteTerminateDeadlineElapsed();
        reportTerminateIfSettled();
      }, terminateConsentMilliseconds());
    }, terminateGraceMilliseconds());
  }

  // The five answers, worded apart. A refusal carries the host's own reason and
  // is never asked again — the ask was refused, so repeating it is refused too.
  //
  // Named by the row and by the id: the name is what the person clicked, and by
  // the time an answer lands the session it names may be gone from the outline.
  function wordTerminateOutcome(id, outcome) {
    const named = lastSessionNames.has(id) ? `${lastSessionNames.get(id)} (session ${id})` : `session ${id}`;
    switch (outcome) {
      case TERMINATE.terminated: return `${named} — terminated`;
      case TERMINATE.denied: return `${named} — a person on it declined`;
      case TERMINATE.timedOut: return `${named} — nobody on it answered in time`;
      case TERMINATE.refused: return `${named} — the host refused: ${hostNotice() || 'no reason given'}`;
      case TERMINATE.failed: return `${named} — no confirmed result from the host`;
      default: return `${named} — waiting for the host`;
    }
  }

  // Reports a settled terminate once, and says whether it did — the grace path
  // arms the longer wait only when nothing has settled. The generation decides
  // and not the value: two rows refused in a row are two answers, and comparing
  // outcomes would read the second as nothing having happened.
  function reportTerminateIfSettled() {
    const generation = terminateGeneration();
    if (generation === reportedTerminateGeneration) return false;
    reportedTerminateGeneration = generation;
    clearTerminateTimers();
    showTerminateOutcome(wordTerminateOutcome(terminateSessionID(), terminateOutcome()));
    // The next session a confirmed workspace still owes, sent as this one
    // settles.
    if (owedTerminateCount() > 0) {
      const next = buildOwedTerminate();
      if (next) sendTerminateFrame(next);
    }
    // However it settled, the outline the row came from now describes the
    // host as it was before the ask.
    requestSessions();
    return true;
  }

  // --- Attaching from a row ------------------------------------------------
  //
  // A Greet fixes the session for the life of the connection — no frame moves a
  // live one to another session — so attaching from a row is a reconnect, the
  // same path a reload takes. What it reaches is the row's own opening, as
  // Core's outline gives it.
  function attachRow(row) {
    if (!attachArgs) return;
    const open = row.open || { how: 'cannot' };
    if (open.how === 'cannot') {
      showTerminateOutcome(`${row.title} — ${open.whyNot || 'cannot be opened'}`);
      return;
    }
    setSessionsPanelShown(false);
    connect({
      url: attachArgs.url,
      token: attachArgs.token,
      // A workspace the host would restore is reached by its name, which
      // recreates it; anything else by the session the row opens.
      sessionID: open.how === 'restore' ? 0 : identityNumber(open.session),
      workspaceName: open.workspaceName || '',
    });
  }

  function createNewSession() {
    if (!attachArgs) return;
    setSessionsPanelShown(false);
    connect({
      url: attachArgs.url,
      token: attachArgs.token,
      sessionID: 0,
      workspaceName: '',
      endsWhenDetached: !keepsUnnamedSessions(attachArgs.url),
    });
  }

  // The connect rule is Core's, and it takes the host's sessions — which this
  // page does not have until a list answers. So the first Greet goes out on the
  // tab's own recall (a reload returns to its shell) and the rule gets its say
  // when the list lands.
  //
  // Once per page load, not once per connection: a host that keeps answering
  // with an id other than the one asked for would otherwise be a reconnect
  // loop, and the second answer is not more right than the first.
  let hasFollowedConnectRule = false;
  let pendingHostPairing = null;

  /// Writes the pairing this connection made, once nothing is still reading the
  /// one it replaces. Safe to call more than once; the second is a no-op.
  function commitPendingHostPairing() {
    if (!pendingHostPairing) return;
    const { url, id, workspaceName } = pendingHostPairing;
    pendingHostPairing = null;
    rememberHostSession(url, id, workspaceName);
    storeHostRecord(url);
  }

  function followConnectRule() {
    if (hasFollowedConnectRule || !attachArgs || !attachedSession) return;
    hasFollowedConnectRule = true;
    const plans = attachPlans();
    const plan = decideAttach(attachArgs.url, attachArgs.workspaceName || '');
    const wantedID = plan === plans.attachByID ? decidedSessionID() : 0;
    const wantedName = plan === plans.attachByID ? decidedWorkspaceName() : '';
    // The rule has read; the record can move on. Before the returns below, so
    // that every plan writes it and not only the one that reconnects.
    commitPendingHostPairing();
    if (plan === plans.chooseFromList) {
      // The list this reply delivered is already drawn, so the panel it raises
      // is showing the answer the rule read.
      setSessionsPanelShown(true);
      return;
    }
    if (plan !== plans.attachByID) return;
    // CreateNamed, AttachNamed and CreateNew are already decided by the Greet
    // that is up: the name rode on it and the host attached or created under
    // it, and an unnamed create is the session this connection is on.
    if (!wantedID || wantedID === attachedSession) return; // already there
    connect({
      url: attachArgs.url,
      token: attachArgs.token,
      sessionID: wantedID,
      workspaceName: wantedName,
    });
  }

  newSessionButton.addEventListener('click', createNewSession);
  refreshSessionsButton.addEventListener('click', () => { disarmTerminate(); requestSessions(); });
  hideSessionsButton.addEventListener('click', () => setSessionsPanelShown(false));
  sessionsOpen.addEventListener('click', () => {
    // Shown from what the last reply left, and refreshed into: a panel that
    // waited for a round trip would open empty on a host that is right there.
    setSessionsPanelShown(true);
    requestSessions();
  });
  keepUnnamedBox.addEventListener('change', () => {
    if (attachArgs) setKeepsUnnamedSessions(attachArgs.url, keepUnnamedBox.checked);
  });
  // Escape dismisses, the same answer the clipboard prompt gives it. Bound on
  // the panel rather than the document: the terminal's own Escape is a key the
  // shell is owed, and only a panel that has focus may take it.
  sessionsPanel.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    setSessionsPanelShown(false);
  });

  // Opt-in: claiming it hands every process on the host a way to read what
  // was copied in this browser. Any of them can run xclip while the session is
  // open, so it is a decision someone makes rather than one a default makes
  // for them.
  const wantsClipboardServing = params.get('serveclipboard') === '1';

  // Reconnect state. A dropped socket must not leave the page dead until a
  // reload — the status would read "detached" with nothing ever trying again,
  // which on a laptop that slept for a minute is the whole terminal gone.
  let reconnectAttempt = 0;
  let reconnectTimer = null;
  let attachArgs = null;

  // Whether the grid on screen belongs to a host.
  //
  // Latched by the first connect() and never cleared, because the mirror stays
  // on screen after the socket goes: feeding a keystroke into it forks the
  // baseline the host's next Update patches against, and a detach does not
  // give the page back ownership of the cells the host wrote. A standalone page
  // — no ?attach=, no connect() — is the terminal itself and must still echo,
  // which is the other half of the same rule.
  let isMirroringHost = false;

  // The session this connection is attached to, 0 until its Welcome grants
  // admission (and its exact consent approval arrives when one is required),
  // 0 again once it is taken down.
  //
  // The page's own rather than Core's isAttached(): the page needs the id, not
  // the bit, because the id is what it persists and hands back on the next
  // Greet. Core's session id is the host's answer to the last handshake and
  // stands until the next one replaces it, so it cannot serve as the signal
  // that this connection completed its own.
  let attachedSession = 0;

  // Backoff capped at 5s rather than a capped NUMBER of attempts: a host that
  // comes back after ten minutes should be picked up without the user knowing
  // to reload. The session id is persisted, so each attempt reattaches to the
  // same session rather than starting a new shell.
  function scheduleReconnect() {
    // Not while one is already open: a spurious close on a socket that has
    // been replaced would otherwise open a second connection to the same
    // session, and the host would see two clients fighting over one grid.
    if (!attachArgs || reconnectTimer || socket) return;
    const delay = Math.min(250 * 2 ** reconnectAttempt, 5000);
    reconnectAttempt += 1;
    showStatus(`detached — reconnecting in ${(delay / 1000).toFixed(1)}s`);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      showStatus('reconnecting…');
      attach();
    }, delay);
  }

  // Opens the connection `attachArgs` describes.
  //
  // Takes no parameters: attachArgs is the whole intent of a connection — url,
  // token, the workspace to attach under, what becomes of a session this Greet
  // creates — and a second copy of half of it in arguments is the copy that
  // goes stale across a reconnect.
  function attach() {
    // Read once, into the closure this connection's handlers share. attachArgs
    // is replaced by the next connect(), and a handler still in flight that read
    // it live would report the connection it belongs to against the one that
    // replaced it.
    const { url, token } = attachArgs;
    const workspaceName = attachArgs.workspaceName || '';
    const endsWhenDetached = attachArgs.endsWhenDetached === true;
    const connection = new WebSocket(url);
    socket = connection;
    const priorSession = workspaceView ? 0 : recallSession(url);
    // This connection has not been acknowledged yet, whatever the last one
    // reached. A reconnect builds a second closure over the same page state, so
    // the handshake flag cannot live in the closure — read from outside, a stale
    // one reports a page mid-handshake as attached to the session it lost.
    attachedSession = 0;
    let requestedDirectory = false;

    socket.binaryType = 'arraybuffer';
    // Repaint on a frame budget rather than per message: a burst of reads is one
    // screen, and painting each would render the same grid many times.
    let paintPending = false;
    function schedulePaint() {
      if (paintPending) return;
      paintPending = true;
      requestAnimationFrame(() => { paintPending = false; paint(); });
    }
    attach.schedulePaint = schedulePaint;
    socket.onopen = () => {
      if (socket !== connection) return;
      showStatus('attached — handshaking');
      debugLog(`connected to ${url}`);
      // The workspace name and the lifetime ride Greet because the host
      // reads them only where it CREATES: a reattach observes the session it
      // finds, so sending them on every handshake states the intent once and
      // costs a reattach nothing.
      const helloBase = buildHello(token || '', priorSession, wantsClipboardServing ? 1 : 0,
        workspaceName, endsWhenDetached ? 1 : 0);
      debugLog(`Greet ${frameLength()} bytes, token ${token ? token.length : 0} chars, ${grid.columns}x${grid.rows}, ${priorSession ? `reattaching session ${priorSession}` : 'new session'}, ${workspaceName ? `workspace ${workspaceName}` : 'unnamed workspace'}, ${endsWhenDetached ? 'ends when detached' : 'persists'}, ${wantsClipboardServing ? 'serving this browser\'s clipboard' : 'clipboard not served'}`);
      sendFrame(helloBase);
      // After Greet, and only after: the frames share one scratch buffer, so
      // building this first would have overwritten the handshake it precedes.
      // The true state rather than an assumption — a page opened in a background
      // tab would otherwise make the program's first focus report a wrong one.
      sendFrame(buildFocusChanged());
    };
    socket.onmessage = (event) => {
      // A queued callback may outlive detach/reconnect. Its bytes and faults
      // belong only to the transport that installed it, never its replacement.
      if (socket !== connection) return;
      const bytes = new Uint8Array(event.data);
      countBytes(bytes.length);
      // Timed because the frame timings said the renderer is free: at 0-1ms of
      // build and draw against a 40ms frame, the cost is on this path and not
      // that one. A read arrives on the same thread that paints, so time spent
      // here is frame time whether or not it looks like rendering.
      const tFeed = performance.now();
      const buffer = module._malloc(bytes.length);
      module.HEAPU8.set(bytes, buffer);
      const ok = feedFromHost(buffer, bytes.length);
      module._free(buffer);
      msFeed += performance.now() - tFeed;
      feedBytesTotal += bytes.length;
      if (socket !== connection) return;
      if (!ok) {
        // A host that refuses the attach ends the connection with a Bye that
        // Core words as a new standing verdict. Bytes Core could not read leave
        // the verdict this page already shows, and are a protocol fault.
        const refusal = hostNotice();
        if (refusal && refusal !== hostVerdict) {
          hostVerdict = refusal;
          debugLog(`host verdict — ${refusal}`);
          showStatus(statusText);
        } else {
          status.textContent = 'protocol fault — connection dropped';
        }
        connection.close();
        return;
      }
      // Hidden tabs suspend animation frames, but their title must still report bells.
      syncDocumentTitle();
      // The host's verdict on this attach — held for consent, or refused. Core
      // decodes the frame and words the reason; the page reads the standing
      // value rather than watching for a frame, so a verdict that arrives in the
      // same read as other frames is not missed. A hold delivers no checkpoint, so
      // this line is the only thing separating "a person has to allow you" from
      // a host that is down — and the person who can allow it is at another
      // screen, with nothing telling them to look.
      const verdict = hostNotice();
      if (verdict !== hostVerdict) {
        hostVerdict = verdict;
        if (verdict) debugLog(`host verdict — ${verdict}`);
        showStatus(statusText);
      }
      // Welcome selects the id, but only the granted Welcome/consent transition
      // admits it. Read it until that boundary and not per message thereafter.
      // A host that cannot honour a saved numeric selection refuses it rather
      // than silently creating a replacement shell.
      //
      // isAttached() gates the read, and sessionID() alone cannot: the id is the
      // host's answer to the LAST handshake and stands across a reconnect by
      // design, since it is what separates "never attached" from "attached, then
      // dropped". The admission predicate is per connection — resetForReconnect
      // clears it and leaves the id — so a refused reconnect that reads the id
      // first would adopt a session the host just declined to give it. The
      // current screen-admission predicate additionally keeps a pending consent
      // from becoming an attached page or a persisted session selection.
      if (!attachedSession && isAttached()) {
        const id = sessionID();
        if (id) {
          attachedSession = id;
          // The backoff resets here and not on socket.onopen. A socket that
          // opens and is then refused — a stale token against a restarted host
          // is the common one — would otherwise reset the backoff on every
          // cycle and retry at 250ms forever, which is a tight loop that reads
          // as "detached — reconnecting" flickering and never settling.
          reconnectAttempt = 0;
          rememberSession(url, id);
          // The pairing is written from the id the host PINNED and never from
          // the one that was asked for: a host that could not honour a reattach
          // answers with a different session, and a record naming the session
          // that was wanted describes a shell that no longer exists.
          // Stashed, not written. The connect rule below reads the record this
          // page ARRIVED with, and writing the session this handshake just made
          // would answer the rule's question before it is asked: decideAttach
          // would see the new id as the remembered one and confirm the session
          // it is already on, which is every plan except the one that matters.
          // Committed once the rule has read, and on close so a page that never
          // gets a listing still remembers where it was.
          pendingHostPairing = { url, id, workspaceName };
          debugLog(`session ${id} ${id === priorSession ? 'reattached' : 'created'}`);
        }
      }
      // Welcome can await exact own-consent approval. Retry only until
      // this connection has admitted its initial directory subscription.
      if (isAttached() && !requestedDirectory)
        requestedDirectory = requestSessions();
      // The screen plane's acknowledgements and resyncs. The host paces this
      // page by what it acknowledged, so an acknowledgement held unsent stops
      // the screen once the host's window fills.
      sendOwedHostFrames();
      // After the frames above, because they share one scratch buffer: reading
      // the list touches no frame, and asking again would overwrite whatever is
      // still waiting to be sent.
      // Before the list: an outstanding terminate settles on its exact result
      // or a refusal, and reporting it first is what lets the list
      // it then asks for be the one the page draws.
      reportTerminateIfSettled();
      reportOutlineIfChanged();
      if (!workspaceView) followConnectRuleIfAnswered();
      settleHostCalls();
      if (workspaceView) window.dispatchEvent(new CustomEvent('ubiquitty-workspace-frame'));
      updateInputInDoubt();
      schedulePaint();
    };
    socket.onerror = () => {
      if (socket === connection) showStatus('socket error — is Scripts/web-proxy.py running?');
    };
    socket.onclose = (e) => {
      if (socket !== connection) return;
      debugLog(`socket closed (code ${e.code})`);
      socket = null;
      for (const pending of hostCalls.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error('Connection lost before the host answered. Check the workspace before retrying.'));
      }
      hostCalls.clear();
      // A lost socket leaves the operation unconfirmed. Silent on a settled
      // one, so an ordinary detach reports nothing.
      noteTerminateTransportLost();
      reportTerminateIfSettled();
      // A page that never got a listing — a host that grants no Control — has
      // no rule to run and would otherwise forget where it was.
      commitPendingHostPairing();
      // Every close retries, including the protocol-fault close above: a fault
      // is a reason to resynchronise from a fresh snapshot, which is exactly
      // what reattaching does, and treating it as fatal leaves the user with a
      // dead page and no way back short of a reload.
      scheduleReconnect();
    };
  }

  // --- The embedder API ----------------------------------------------------
  //
  // A host page that frames this terminal — a sidebar of servers, a tab strip —
  // drives the connection through window.ubiquitty rather than through the URL:
  // switching session means attaching to another one in the same page, and a
  // query string is read once at load.
  //
  // The three entry points below are the whole of it, and ?attach= is one CALLER
  // of them rather than a second route into attach(). Two ways to connect is the
  // fork this rule exists to prevent: the query path and the embedder path would
  // each acquire their own idea of the reconnect state, and the bug would be that
  // switching sessions works while the reload after it comes back to the wrong
  // shell.

  // Where this page stands in the attach lifecycle, as one word.
  //
  // 'detached'      nothing open and nothing being retried
  // 'connecting'    a socket is opening
  // 'handshaking'   the socket is open, screen admission is not granted yet
  // 'attached'      screen admission is granted, `sessionID` is the session
  // 'reconnecting'  the socket dropped and a retry is armed
  //
  // Derived from the socket and the timer rather than stored. A stored copy is a
  // second answer to the same question, and the one that goes stale is the one
  // the sidebar draws.
  function connectionState() {
    if (!socket) return reconnectTimer ? 'reconnecting' : 'detached';
    if (socket.readyState !== WebSocket.OPEN) return 'connecting';
    return isAttached() ? 'attached' : 'handshaking';
  }

  // Close the connection and stop retrying it.
  //
  // Everything the reconnect path reads is cleared before the socket is closed:
  // onclose calls scheduleReconnect, and a close this page asked for must not
  // resurrect what it is taking down.
  function detach() {
    for (const pending of hostCalls.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error('Connection changed before the host answered. Check the workspace before retrying.'));
    }
    hostCalls.clear();
    const isSocketLive = Boolean(socket || reconnectTimer);
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    attachArgs = null;
    attachedSession = 0;
    // The panel acts on a host, so it goes down with the connection to one.
    clearTerminateTimers();
    setSessionsPanelShown(false);
    sessionsOpen.hidden = true;
    // A verdict outranks every other line on the status bar, which is what keeps
    // a refusal from being erased by the reconnect countdown a quarter-second
    // later. It belongs to the connection that earned it and cannot outlive one:
    // carried across, it explains the previous session's refusal over the next
    // session's screen.
    hostVerdict = '';
    const closing = socket;
    socket = null;
    if (closing) {
      closing.onopen = null;
      closing.onmessage = null;
      closing.onerror = null;
      closing.onclose = null;
      closing.close();
    }
    if (isSocketLive) showStatus('detached');
  }

  // Attach to a session, replacing whatever this page is attached to.
  //
  // `url` is the WebSocket the router answers on and `token` the capability the
  // host will check. `sessionID` names the session to reattach to: 0 asks for a
  // new one, and ABSENT means whatever this url last answered with — which is
  // what a reload wants and what ?attach= relies on.
  //
  // `workspaceName` attaches to the session bearing that name and creates one
  // under it when nothing does, and `endsWhenDetached` asks the host to end the
  // session this handshake creates when its last human leaves. The host reads
  // both only on a create, so both are inert on a reattach.
  //
  // The requested id goes through the same per-url store the reconnect path
  // recalls from, so an embedder's choice survives a dropped socket instead of
  // reaching only the first Greet. The host's answer overwrites it, so a session
  // the host could not honour is not asked for twice.
  //
  // Throws on a missing url rather than returning: a page told to attach to
  // nothing sits detached with an empty grid and nothing on screen saying why,
  // and that is the shape an embedder passing an unresolved variable produces.
  function connect(options) {
    const settings = options || {};
    const url = typeof settings.url === 'string' ? settings.url : '';
    if (!url) throw new TypeError('ubiquitty.connect: no url — pass the WebSocket the host is reachable on');
    detach();
    if (settings.sessionID !== undefined && settings.sessionID !== null)
      rememberSession(url, Math.max(0, Math.trunc(Number(settings.sessionID)) || 0));
    isMirroringHost = true;
    if (workspaceView) {
      persistResume();
      module.ccall('ubiquittyWebCreateWorkspace', null, ['number', 'number', 'number'], [grid.rows, grid.columns, GLYPH_SCALE]);
      setDrawsSizedText(1);
      setDrawsProportionalText(1);
      setModifierVocabulary(modifierVocabularyForPlatform(navigator.platform || ''));
      isResumeInstalled = false;
      module.ccall('ubiquittyWebSetWorkspaceID', null, ['number'], [settings.workspaceID || 0]);
    }
    // A connect is not a retry of the connection it replaces: leaving the counter
    // where the last failure left it would announce a five-second wait on the
    // first drop of a freshly opened session.
    reconnectAttempt = 0;
    attachArgs = {
      url,
      token: typeof settings.token === 'string' ? settings.token : '',
      // The name a saved host predefines, or the one a row was attached under.
      // Empty is an unnamed session, which is what a caller that names none
      // asks for.
      workspaceName: typeof settings.workspaceName === 'string' ? settings.workspaceName : '',
      // Ephemeral only when the caller says so. A reattach and a named
      // workspace both persist, so the default here is the safe one and the
      // New Session control is what opts a one-off out of it.
      endsWhenDetached: settings.endsWhenDetached === true,
    };
    // The host's own record, handed to Core before anything asks it to decide.
    loadStoredHostRecord(url);
    installResume(workspaceView ? `${url}#workspace=${settings.workspaceID || 0}&name=${encodeURIComponent(attachArgs.workspaceName)}` : url);
    // ?keepunnamed= writes the per-host setting rather than standing beside it,
    // so the checkbox and the query string cannot disagree about one host.
    if (params.has('keepunnamed')) setKeepsUnnamedSessions(url, params.get('keepunnamed') === '1');
    // A caller silent on the lifetime gets the host's own answer, read after
    // the query string has been applied. The page's own load-time connect is
    // one such caller, and it creates the session on a first visit — so
    // leaving the
    // default here meant every bookmarked host kept its unnamed sessions while
    // its own checkbox, drawn from the same setting a line below, said it did
    // not. A named workspace is the host's to keep either way.
    if (typeof settings.endsWhenDetached !== 'boolean') {
      attachArgs.endsWhenDetached = !attachArgs.workspaceName && !keepsUnnamedSessions(url);
    }
    keepUnnamedBox.checked = keepsUnnamedSessions(url);
    sessionsOpen.hidden = false;
    attach();
  }

  // The half of window.ubiquitty that needs the terminal. Installed here, below
  // attach(), because these close over the socket, the reconnect state and the
  // wasm exports; the handle itself is created at module scope, where an embedder
  // can reach it before the wasm has finished loading.
  //
  // Assigning a module-scope `let` from inside main() is sound because main()
  // runs off the wasm factory's promise, so module scope has already finished —
  // the binding is live. Called from module scope it would be a temporal-dead-zone
  // ReferenceError, which in this file has meant a page that never draws.
  let configureGeneration = 0;
  embedderImplementation = {
    connect,
    detach,
    focus: focusTerminal,
    configure(options = {}) {
      const sequence = ++configureGeneration;
      for (const key of ['fontSize', 'lineSpacing', 'padding']) {
        if (options[key] !== undefined && (!Number.isFinite(options[key])
            || options[key] < (key === 'fontSize' ? 6 : 0) || options[key] > 100))
          throw new TypeError(`ubiquitty.configure: invalid ${key}`);
      }

      if (options.preferences !== undefined && !module.ccall('ubiquittyWebSetRenderingPreferences', 'number', ['string'], [JSON.stringify(options.preferences)]))
        throw new TypeError('ubiquitty.configure: invalid rendering preference');
      if (options.fontFamily !== undefined) {
        if (typeof options.fontFamily !== 'string' || !options.fontFamily.trim() || options.fontFamily.length > 256 || /[\r\n]/.test(options.fontFamily))
          throw new TypeError('ubiquitty.configure: invalid font family');
      }
      return (async () => {
      if (options.fontFamily !== undefined) {
        const features = fontFeatureSettingsCSS(), variations = fontVariationSettingsCSS();
        const [family] = await Promise.all([
          prepareFont(options.fontFamily, features, variations, module.ubiquittyFontCoverage),
          module.ubiquittyPrepareFont?.(options.fontFamily, features, variations, module.ubiquittyFontCoverage),
        ]);
        if (sequence !== configureGeneration) return;
        module.ubiquittyFontFamily = family;
        rebuildFont();
      }
      if (options.fontSize !== undefined)
        module.ccall('ubiquittyWebSetFontSize', null, ['number'], [options.fontSize]);
      if (options.lineSpacing !== undefined)
        module.ccall('ubiquittyWebSetLineSpacing', null, ['number'], [options.lineSpacing]);
      if (options.padding !== undefined) applyPadding(options.padding, { remember: false });
      if (options.theme === '') {
        module.ccall('ubiquittyWebFollowHostTheme', null, [], []);
        lastKnownTheme = '';
      } else if (options.theme !== undefined) {
        if (typeof options.theme !== 'string' || !setThemeByName(options.theme))
          throw new TypeError('ubiquitty.configure: unknown theme');
        lastKnownTheme = options.theme;
      }
      richText.features = fontFeatureSettingsCSS();
      cellPx = { width: cellWidthPx(), height: cellHeightPx() };
      refitGrid();
      applyBackgroundColor();
      paint();
      })();
    },
    setLocalProgram(program) {
      if (isMirroringHost) throw new Error('ubiquitty.setLocalProgram: the host owns this terminal');
      if (program !== null && (typeof program?.input !== 'function' || typeof program?.paste !== 'function'))
        throw new TypeError('ubiquitty.setLocalProgram expects input and paste callbacks, or null');
      localProgram = program;
    },
    feed(text) {
      if (isMirroringHost) throw new Error('ubiquitty.feed: the host owns this terminal');
      if (typeof text !== 'string') throw new TypeError('ubiquitty.feed expects text');
      feed(text);
      paint();
    },
    clear() { performAction(isMirroringHost ? ACTION.clearBuffer : ACTION.clearScrollback); },
    repaint() { updateInputInDoubt(); sendOwedHostFrames(); paint(); },
    attachWorkspace(id, transport) {
      if (!workspaceView || !Number.isInteger(id) || id <= 0)
        throw new Error('A workspace pane needs its host session identity.');
      isMirroringHost = true;
      attachedSession = id;
      socket = transport;
      sendFrame(buildResize(grid.rows, grid.columns));
      sendOwedHostFrames();
      paint();
    },
    setVisible(visible) {
      isViewVisible = !!visible;
      if (!isViewVisible) suspendContext();
      else if (hasLostContext && isContextSuspended)
        restoreContext();
      module.ccall('ubiquittyWebSetWorkspacePaneVisible', null, ['number'], [visible ? 1 : 0]);
      sendOwedHostFrames();
    },
    sendTransport(bytes) {
      if (!socket || socket.readyState !== WebSocket.OPEN) return false;
      socket.send(bytes);
      return true;
    },
    bufferedAmount: () => socket?.bufferedAmount || 0,
    workspaceTree: () => JSON.parse(module.ccall('ubiquittyWebHostWorkspaceJSON', 'string', [], [])),
    settingsCatalog: () => JSON.parse(module.ccall('ubiquittyWebSettingsCatalogJSON', 'string', [], [])),
    connectionNotice: () => hostNotice(),
    hostCall(method, parameters = {}) {
      if (connectionState() !== 'attached') return Promise.reject(new Error('Connect to the host first.'));
      if (hostCalls.size >= 16) return Promise.reject(new Error('Wait for the host to answer the pending operations.'));
      const id = nextHostCall++;
      return new Promise((resolve, reject) => {
        const key = `ubiquitty.web-call.${id}`;
        const timer = setTimeout(() => {
          hostCalls.delete(key);
          reject(new Error('The host has not answered. The operation may still complete; check the workspace before retrying.'));
        }, 60000);
        hostCalls.set(key, { resolve, reject, timer });
        const base = module.ccall('ubiquittyWebBuildHostCall', 'number', ['string', 'string', 'number'], [method, JSON.stringify(parameters), id]);
        const refusal = module.ccall('ubiquittyWebHostCallRefusal', 'string', [], []);
        if (refusal) { clearTimeout(timer); hostCalls.delete(key); reject(new Error(refusal)); return; }
        sendFrame(base);
        sendOwedHostFrames();
      });
    },
    readMetadata: () => JSON.parse(module.ccall('ubiquittyWebProgramMetadataJSON', 'string', [], [])),
    capture: () => JSON.parse(module.ccall('ubiquittyWebCaptureProgramState', 'string', [], [])),
    snapshot() {
      // Copy the CPU raster, including when the visible canvas belongs to WebGL.
      // A returned frame survives the next paint and any wasm memory growth.
      const base = render();
      const width = imageWidth(), height = imageHeight();
      return { width, height, scale: GLYPH_SCALE,
        pixels: new Uint8ClampedArray(module.HEAPU8.slice(base, base + width * height * 4)) };
    },
    search(literal) {
      if (typeof literal !== 'string') throw new TypeError('ubiquitty.search expects text');
      if (!searchLiteral(literal)) throw new Error('ubiquitty.search could not start');
      isSearchOpen = literal.length > 0;
      queueSearchPump();
      publishSearch();
      return JSON.parse(searchStatusJSON());
    },
    readSearchStatus: () => JSON.parse(searchStatusJSON()),
    stepSearch(direction) {
      if (direction !== 'older' && direction !== 'newer')
        throw new TypeError('ubiquitty.stepSearch expects older or newer');
      const didStep = !!stepSearch(direction === 'older' ? 1 : -1);
      publishSearch();
      return didStep;
    },
    readState: () => ({
      connectionState: connectionState(),
      sessionID: attachedSession,
      url: attachArgs ? attachArgs.url : '',
      wireVersion: wireVersion(),
      appVersion: appVersion(),
      buildIdentity: buildIdentity(),
    }),
    // A sidebar of servers lives outside this frontend and is nobody's business
    // here; what it cannot supply itself is what the host holds, which only a
    // client that speaks the protocol can ask. The answer is the host's
    // outline: every level of what it holds, as rows to draw.
    // `requestSessions` asks the host again, `requestOutline` subscribes this
    // connection, `readOutline` reads the rows for a search, and
    // `setOutlineRowOpen` closes or opens one; `ubiquitty-outline` fires on the
    // window whenever the rows change.
    //
    // The query half only, though the page itself terminates: an embedder's
    // destroy would arrive with no question behind it, and the ask this page
    // sends is one a person answered on the row it names. An embedder that
    // wants the panel's behaviour gets the panel.
    requestSessions,
    requestOutline,
    readOutline,
    setOutlineRowOpen,
  };

  // ?attach=ws://host:port turns the page into a real client; without it the
  // page stays a local terminal fed from JavaScript until an embedder connects.
  //
  // ?workspace=name attaches to the session bearing that name and creates one
  // under it when nothing does — one ask, either outcome, which is what
  // `tmux new-session -A -s` does and what a bookmarked host wants.
  const attachUrl = params.get('attach');
  if (attachUrl) {
    connect({
      url: attachUrl,
      token: params.get('token'),
      workspaceName: params.get('workspace') || '',
    });
  }

  // --- Keyboard ------------------------------------------------------------
  //
  // The page translates a browser KeyboardEvent into the shape Core's keymap
  // takes — a key code, modifier bits, and the code point the key produced — and
  // decides nothing else. Whether Escape is ESC or CSI 27 u, whether an arrow is
  // CSI A or SS3 A, what Ctrl-C or Alt-f become: all of that depends on live
  // terminal modes the page cannot see, and is answered by the same encoder the
  // macOS and Linux frontends call.
  //
  // This is the same job UBTerminalView does for NSEvent. Translating the host's
  // event shape is a frontend's work; deciding the bytes is not.
  const buildKeyEvent = module.cwrap('ubiquittyWebBuildKeyEvent', 'number', ['number', 'number', 'number', 'number', 'number', 'number']);
  const echoKeyEvent = module.cwrap('ubiquittyWebFeedKeyEvent', 'number', ['number', 'number', 'number', 'number', 'number', 'number']);
  const encodeLocalKeyEvent = module.cwrap('ubiquittyWebEncodeLocalKeyEvent', 'number',
    ['number', 'number', 'number', 'number', 'number', 'number', 'number', 'number']);
  function feedKeyEvent(...facts) {
    if (!localProgram) return echoKeyEvent(...facts);
    const buffer = module._malloc(64);
    try {
      const length = encodeLocalKeyEvent(...facts, buffer, 64);
      if (length > 0) localProgram.input(module.HEAPU8.slice(buffer, buffer + length));
      return length > 0;
    } finally {
      module._free(buffer);
    }
  }

  // What the *active* layout produces for each physical key, unmodified.
  //
  // Neither browser field answers that alone. `KeyboardEvent.code` labels a
  // physical position in US-QWERTY, so on Dvorak the key marked `KeyF` types
  // `u`; `KeyboardEvent.key` is the right character but carries any modifier the
  // OS already folded in, turning Option+F into U+0192. The layout map takes a
  // position and returns the layout's character with no modifier applied.
  //
  // Absent in some browsers. Without it an unmodified key still resolves from
  // `event.key`; only a modified key on a non-US layout degrades, to the US
  // physical position.
  let layoutMap = null;
  if (navigator.keyboard && navigator.keyboard.getLayoutMap) {
    navigator.keyboard.getLayoutMap().then((map) => {
      layoutMap = map;
      debugLog(`keyboard layout map: ${map.size} keys`);
    }).catch(() => { debugLog('keyboard layout map unavailable; using event.key'); });
  }

  const clearScrollback = module.cwrap('ubiquittyWebClearScrollback', null, []);
  const selectAll = module.cwrap('ubiquittyWebSelectAll', null, []);
  const scrollToTop = module.cwrap('ubiquittyWebScrollToTop', null, []);
  const stepFontSize = module.cwrap('ubiquittyWebStepFontSize', null, ['number']);
  const resetFontSize = module.cwrap('ubiquittyWebResetFontSize', null, []);
  const clearSelectionForUserInput = module.cwrap('ubiquittyWebClearSelectionForUserInput', 'number', []);
  const buildClearBuffer = module.cwrap('ubiquittyWebBuildClearBuffer', 'number', []);
  const addKeybinding = module.cwrap('ubiquittyWebAddKeybinding', 'number', ['string', 'string']);
  const resolveBinding = module.cwrap('ubiquittyWebResolveBinding', 'number', ['number', 'number', 'number']);
  const bindingBytes = module.cwrap('ubiquittyWebBindingBytes', 'number', []);
  const ACTION = {
    sendBytes: module.cwrap('ubiquittyWebActionSendBytes', 'number', [])(),
    copy: module.cwrap('ubiquittyWebActionCopy', 'number', [])(),
    paste: module.cwrap('ubiquittyWebActionPaste', 'number', [])(),
    clearScrollback: module.cwrap('ubiquittyWebActionClearScrollback', 'number', [])(),
    clearBuffer: module.cwrap('ubiquittyWebActionClearBuffer', 'number', [])(),
    selectAll: module.cwrap('ubiquittyWebActionSelectAll', 'number', [])(),
    toggleFullscreen: module.cwrap('ubiquittyWebActionToggleFullscreen', 'number', [])(),
    increaseFontSize: module.cwrap('ubiquittyWebActionIncreaseFontSize', 'number', [])(),
    decreaseFontSize: module.cwrap('ubiquittyWebActionDecreaseFontSize', 'number', [])(),
    resetFontSize: module.cwrap('ubiquittyWebActionResetFontSize', 'number', [])(),
    scrollLineUp: module.cwrap('ubiquittyWebActionScrollLineUp', 'number', [])(),
    scrollLineDown: module.cwrap('ubiquittyWebActionScrollLineDown', 'number', [])(),
    scrollPageUp: module.cwrap('ubiquittyWebActionScrollPageUp', 'number', [])(),
    scrollPageDown: module.cwrap('ubiquittyWebActionScrollPageDown', 'number', [])(),
    scrollToTop: module.cwrap('ubiquittyWebActionScrollToTop', 'number', [])(),
    scrollToBottom: module.cwrap('ubiquittyWebActionScrollToBottom', 'number', [])(),
    toggleBeam: module.cwrap('ubiquittyWebActionToggleBeam', 'number', [])(),
  };

  // The Cmd shortcuts a terminal is expected to have. Written as config [keys]
  // lines and parsed by Core, so the page states no binding syntax of its own.
  //
  // Which of these actually arrive is the browser's call, not ours: Cmd+L,
  // Cmd+T, Cmd+W and friends are reserved by the browser chrome and never reach
  // a page. Cmd+K does, so clear-scrollback works; a user who wants the others
  // can bind them to a combination the browser leaves alone.
  for (const [spec, action] of [
    ['cmd+k', 'clear'],
    ['cmd+v', 'paste'],
    ['cmd+c', 'copy'],
    ['cmd+a', 'select_all'],
    // The palette. Cmd+P is what every editor uses for it and what a browser
    // leaves alone; Core parses the spec and names the action, so this file
    // states no binding syntax of its own.
    ['cmd+p', 'toggle_beam'],
    // The chords a terminal is expected to have for history. Shift+Home/End and
    // Shift+PageUp/PageDown are the combinations a browser leaves alone.
    ['shift+up', 'scroll_line_up'],
    ['shift+down', 'scroll_line_down'],
    ['shift+pageup', 'scroll_page_up'],
    ['shift+pagedown', 'scroll_page_down'],
    // The chord macOS uses; F11 belongs to the browser and never arrives.
    ['cmd+ctrl+f', 'toggle_fullscreen'],
    // Cmd+plus/minus/0, the chords every terminal and every browser uses. The
    // browser's own page zoom is a different thing and stays on ctrl.
    ['cmd+=', 'increase_font_size'],
    ['cmd+-', 'decrease_font_size'],
    ['cmd+0', 'reset_font_size'],
    ['shift+home', 'scroll_to_top'],
    ['shift+end', 'scroll_to_bottom'],
  ]) {
    if (!addKeybinding(spec, action)) debugLog(`binding rejected: ${spec}`);
  }

  // The code point the standard layout carries at this physical position — the
  // Kitty protocol's base-layout key. Reported alongside the layout key so a
  // program that wants position rather than letter can have it, and used as the
  // fallback when no layout map is available.
  function baseLayoutKeyFromCode(code) {
    if (!code) return 0;
    if (code.length === 4 && code.startsWith('Key'))
      return code.charCodeAt(3) + 32; // KeyF -> 'f'
    if (code.length === 6 && code.startsWith('Digit'))
      return code.charCodeAt(5);      // Digit4 -> '4'
    switch (code) {
      case 'Space': return 32;
      case 'Minus': return 45;
      case 'Equal': return 61;
      case 'BracketLeft': return 91;
      case 'Backslash': return 92;
      case 'BracketRight': return 93;
      case 'Semicolon': return 59;
      case 'Quote': return 39;
      case 'Backquote': return 96;
      case 'Comma': return 44;
      case 'Period': return 46;
      case 'Slash': return 47;
      default: return 0;
    }
  }

  const physicalKeysDown = new Set();
  const physicalNamedKeys = Object.freeze({
    Enter: 1, NumpadEnter: 2, Tab: 3, Backspace: 4, Delete: 5, Escape: 6, Insert: 7,
    ArrowLeft: 8, ArrowRight: 9, ArrowUp: 10, ArrowDown: 11, Home: 12, End: 13,
    PageUp: 14, PageDown: 15, NumpadDecimal: 38, NumpadDivide: 39,
    NumpadMultiply: 40, NumpadSubtract: 41, NumpadAdd: 42, NumpadEqual: 43,
    ShiftLeft: 44, ShiftRight: 45, ControlLeft: 46, ControlRight: 47,
    AltLeft: 48, AltRight: 49, MetaLeft: 50, MetaRight: 51,
    Space: 0x12c, Minus: 0x12d, Equal: 0x12e, BracketLeft: 0x12f,
    BracketRight: 0x130, Backslash: 0x131, Semicolon: 0x133, Quote: 0x134,
    Backquote: 0x135, Comma: 0x136, Period: 0x137, Slash: 0x138,
    CapsLock: 0x139, IntlBackslash: 0x164,
  });
  function physicalKey(event) {
    const code = event.code || '';
    if (/^Key[A-Z]$/.test(code)) return 0x104 + code.charCodeAt(3) - 65;
    if (/^Digit[0-9]$/.test(code)) return 0x11e + ((Number(code[5]) + 9) % 10);
    if (/^Numpad[0-9]$/.test(code)) return 28 + Number(code[6]);
    if (/^F([1-9]|1[0-2])$/.test(code)) return 15 + Number(code.slice(1));
    return physicalNamedKeys[code] || 0;
  }
  function positionModifiers(event) {
    let bits = event.getModifierState?.('CapsLock') ? 4 : 0;
    for (const [code, bit] of [
      ['ShiftLeft', 1], ['ShiftRight', 2], ['ControlLeft', 8], ['ControlRight', 8],
      ['AltLeft', 16], ['AltRight', 32], ['MetaLeft', 64], ['MetaRight', 128],
    ]) if (physicalKeysDown.has(code)) bits |= bit;
    if (event.shiftKey && !(bits & 3)) bits |= 1;
    if (event.ctrlKey) bits |= 8;
    if (event.altKey && !(bits & 0x30)) bits |= 16;
    return keyModifiers(event) | (bits << 8);
  }
  ime.addEventListener('blur', () => physicalKeysDown.clear());

  function keyModifiers(event) {
    return keyModifiersOf(event.shiftKey ? 1 : 0, event.altKey ? 1 : 0,
      event.ctrlKey ? 1 : 0, event.metaKey ? 1 : 0);
  }

  // Sends text to the host when attached, or feeds it locally when not. The two
  // callers below both need it, and neither should know which mode it is in.

  // A composition is in flight: the keystrokes belong to the input method, not
  // to the terminal, and forwarding them would send the romaji as well as the
  // kana it becomes. KeyboardEvent.isComposing covers the keydown path; this
  // flag covers compositionend itself, which fires before the last keyup.
  let composing = false;
  ime.addEventListener('compositionstart', () => { composing = true; });
  ime.addEventListener('compositionend', (event) => {
    composing = false;
    // The composed result, once. Cleared immediately so the next composition
    // starts from an empty element rather than accumulating.
    const text = event.data || '';
    ime.value = '';
    if (text && !reportsKeyPositions()) sendText(text);
  });
  // Text that arrived without a composition — an Android soft keyboard, a
  // dictation insert, a paste into the element — still has to reach the host.
  // Composition results are skipped here because compositionend already sent
  // them, and inputType tells the two apart.
  ime.addEventListener('input', (event) => {
    if (composing || event.isComposing) return;
    if (reportsKeyPositions()) { ime.value = ''; return; }
    const text = ime.value;
    ime.value = '';
    if (!text) return;
    if (event.inputType && event.inputType.startsWith('insertCompositionText')) return;
    sendText(text);
  });

  // The composition popup is placed by the browser at the element, so the
  // element follows the terminal cursor. Without this the candidate window sits
  // wherever the element was laid out and reads as belonging to another app.
  function positionIME() {
    const box = screenViewport.getBoundingClientRect();
    const ratio = window.devicePixelRatio || 1;
    // Signed floating-point origins also cover a clipped Fit/Pan picture.
    ime.style.left = `${box.left + cursorCellX() / ratio}px`;
    ime.style.top = `${box.top + cursorCellY() / ratio}px`;
    ime.style.height = `${cellPx.height * presentationScale() / ratio}px`;
  }

  // Pasted text, not typed text: the two differ in what a terminal is allowed to
  // do with them, and Core owns that difference.
  function sendPasteNotification(types) {
    if (!reportsPasteEvents()) return false;
    const base = buildPasteNotification([...new Set(types)].join(' '));
    if (base && socket) sendFrame(base);
    return true;
  }

  function pasteImage(bytes) {
    const buffer = module._malloc(bytes.length);
    try {
      module.HEAPU8.set(bytes, buffer);
      sendFrame(buildPastePush('image/png', buffer, bytes.length));
    } finally {
      module._free(buffer);
    }
  }

  function sendPaste(text) {
    // A local program receives the same paste intent as a host, separately from
    // encoded keys. It owns paste handling; clipboard text is never echoed as VT.
    if (!isMirroringHost && localProgram) { localProgram.paste(text); return; }
    if (isMirroringHost && !socket) return;
    const bytes = encoder.encode(text);
    if (bytes.length === 0) return;
    const buffer = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, buffer);
    const base = buildPaste(buffer, bytes.length);
    module._free(buffer);
    if (!base) return;
    if (socket) sendFrame(base);
    else {
      // Detached, the same bytes are fed back through the local parser, so a
      // page with no host still shows what a paste would do.
      const length = frameLength();
      const payload = module.HEAPU8.slice(base + 5, base + length);
      const p = module._malloc(payload.length);
      module.HEAPU8.set(payload, p);
      feedBytes(p, payload.length);
      module._free(p);
      paint();
    }
  }

  function sendText(text) {
    if (isMirroringHost && !socket) return;
    if (!isMirroringHost && localProgram) { localProgram.input(encoder.encode(text)); return; }
    const bytes = encoder.encode(text);
    if (bytes.length === 0) return;
    const buffer = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, buffer);
    if (socket) sendFrame(buildInput(buffer, bytes.length));
    else { feedBytes(buffer, bytes.length); paint(); }
    module._free(buffer);
  }

  const ACTION_NAME = Object.fromEntries(Object.entries(ACTION).map(([name, value]) => [value, name]));

  // A Beam action id is Core's action TOKEN — the same string [keys] takes in
  // config.toml and the same one the palette was built from. The page maps it to
  // the action handle it already holds, so the two lists cannot name different
  // sets: a token Core grows and this page has no entry for is inert, and one
  // this page has an entry for and Core drops stops being offered.
  //
  // Anything unrecognised is ignored rather than defaulted: a typo in a token
  // should do nothing, not something.
  const BEAM_COMMANDS = {
    copy: () => ACTION.copy,
    paste: () => ACTION.paste,
    select_all: () => ACTION.selectAll,
    clear: () => ACTION.clearBuffer,
    clear_scrollback: () => ACTION.clearScrollback,
    increase_font_size: () => ACTION.increaseFontSize,
    decrease_font_size: () => ACTION.decreaseFontSize,
    reset_font_size: () => ACTION.resetFontSize,
    scroll_to_top: () => ACTION.scrollToTop,
    scroll_to_bottom: () => ACTION.scrollToBottom,
    scroll_line_up: () => ACTION.scrollLineUp,
    scroll_line_down: () => ACTION.scrollLineDown,
    scroll_page_up: () => ACTION.scrollPageUp,
    scroll_page_down: () => ACTION.scrollPageDown,
  };

  // A Beam row runs the same action a keybinding does — the palette is another
  // way to reach the actions, not a second implementation of them. An id with no
  // entry does nothing rather than defaulting to something: a typo should be
  // inert, and Core does not interpret these ids so it cannot catch one.
  function runBeamCommand(id) {
    // Padding is the one id Core has already APPLIED by the time it reaches
    // here: the value belongs to the terminal, and what is left is the window
    // geometry that follows from it, which is the page's. So it is not an
    // action — there is nothing left to run, only a canvas to inset and a grid
    // to re-fit.
    // Applied inside WebTerminal, like the padding and the theme: the size is the
    // terminal's, and what is left is the cell it derives and the grid that
    // follows — which is the page's. Same work the zoom actions do after a step.
    if (id === 'beam.fontSize') {
      cellPx = { width: cellWidthPx(), height: cellHeightPx() };
      refitGrid();
      debugLog(`font size: ${cellPx.width}x${cellPx.height}px cell`);
      paint();
      return;
    }
    if (id === 'beam.padding') {
      const inset = applyPadding(paddingCss());
      refitGrid();
      debugLog(`padding: ${inset}px`);
      paint();
      return;
    }
    // The spacing is baked into the cell the rasterizers report, so this is the
    // font-size sequence rather than the padding one: re-read the cell, then
    // re-fit the grid to it.
    if (id === 'beam.lineSpacing') {
      cellPx = { width: cellWidthPx(), height: cellHeightPx() };
      refitGrid();
      debugLog(`line spacing: ${cellPx.width}x${cellPx.height}px cell`);
      paint();
      return;
    }
    const lookup = BEAM_COMMANDS[id];
    if (lookup) performAction(lookup());
  }

  function performAction(action) {
    // A binding that fires can have no visible effect on the frame it fires in,
    // so the log is what distinguishes "did nothing" from "did not run".
    debugLog(`action: ${ACTION_NAME[action] || action}`);
    if (action === ACTION.clearBuffer) {
      // The host owns an attached pane's clear. Forward Core's typed request;
      // its resulting screen and history arrive through the ordinary updates.
      const base = buildClearBuffer();
      if (base && socket) sendFrame(base);
      paint();
      return;
    }
    if (action === ACTION.toggleBeam) {
      toggleBeam();
      paint();
      return;
    }
    // Scrolling by a line, a page, or to an end. A page is Core's rule, the
    // amount every other frontend's chord takes, and keeps a row of overlap;
    // positive moves back into history.
    const SCROLL_BY = {
      [ACTION.scrollLineUp]: () => scrollBy(1),
      [ACTION.scrollLineDown]: () => scrollBy(-1),
      [ACTION.scrollPageUp]: () => scrollBy(pageLines()),
      [ACTION.scrollPageDown]: () => scrollBy(-pageLines()),
      [ACTION.scrollToTop]: () => scrollToTop(),
      [ACTION.scrollToBottom]: () => scrollToBottom(),
    };
    if (SCROLL_BY[action]) {
      SCROLL_BY[action]();
      // A view moved into history the host has not sent owes a want.
      if (socket) sendOwedHostFrames();
      paint();
      return;
    }
    // Zooming changes the cell, so the grid that fits the window changes with
    // it — refit rather than repaint, and tell the host its new size.
    const ZOOM = {
      [ACTION.increaseFontSize]: () => stepFontSize(1),
      [ACTION.decreaseFontSize]: () => stepFontSize(-1),
      [ACTION.resetFontSize]: () => resetFontSize(),
    };
    if (ZOOM[action]) {
      ZOOM[action]();
      // The metrics came from the stack that was just replaced, so take them
      // again before fitting: a zoom changes the cell, which is what is measured.
      cellPx = { width: cellWidthPx(), height: cellHeightPx() };
      refitGrid();
      debugLog(`font ${cellPx.width}x${cellPx.height}px cell, ${grid.columns}x${grid.rows}`);
      paint();
      return;
    }
    if (action === ACTION.toggleFullscreen) {
      // The document rather than the canvas: fullscreening the canvas alone lets
      // the browser scale it, where fullscreening the page changes the viewport
      // and the existing resize handler re-fits the grid to it — which is how a
      // fullscreen terminal gets more rows rather than bigger pixels.
      // requestFullscreen needs a user gesture, and a keystroke is one.
      const target = document.documentElement;
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      else if (target.requestFullscreen) target.requestFullscreen().catch((e) => debugLog(`fullscreen refused: ${e.message}`));
      return;
    }
    if (action === ACTION.selectAll) {
      selectAll();
      paint();
      return;
    }
    if (action === ACTION.clearScrollback) {
      // Local whether attached or not: the history dropped is this client's.
      // The visible screen survives, because history is not the grid.
      clearScrollback();
      paint();
      return;
    }
    if (action === ACTION.copy) {
      // Copy is the selection's, not the program's: OSC 52 is a separate path
      // a program drives, and it goes through pumpClipboard.
      const text = selectionText();
      if (text) navigator.clipboard.writeText(text).catch((error) => debugLog(`clipboard write refused: ${error}`));
      return;
    }
    if (action === ACTION.paste) {
      // The clipboard read is a promise, so the paste lands a frame or two
      // later. Text goes through sendPaste, never sendText: Core neutralises
      // any fence already inside the clipboard, strips the control characters
      // that would make a shell execute pasted lines, and fences the body when
      // the application asked for that. An image with no text beside it — a
      // screenshot — starts a bounded upload to an attached host, which lands it as
      // a file and types the path; a detached page has nowhere to land it.
      navigator.clipboard.read()
        .then(async (items) => {
          if (sendPasteNotification(items.flatMap((item) => item.types))) return;
          for (const item of items) {
            if (item.types.includes('text/plain')) {
              const text = await (await item.getType('text/plain')).text();
              if (text) sendPaste(text);
              return;
            }
          }
          if (!socket) return;
          for (const item of items) {
            if (item.types.includes('image/png')) {
              pasteImage(new Uint8Array(await (await item.getType('image/png')).arrayBuffer()));
              return;
            }
          }
        })
        .catch(() => navigator.clipboard.readText()
          .then((text) => { if (text) sendPaste(text); })
          .catch((error) => debugLog(`paste refused: ${error.message}`)));
      return;
    }
    if (action === ACTION.sendBytes) {
      const base = bindingBytes();
      const length = frameLength();
      if (!base || length <= 0) return;
      if (socket) sendFrame(buildInput(base, length));
      else if (!isMirroringHost && localProgram) localProgram.input(module.HEAPU8.slice(base, base + length));
      else if (!isMirroringHost) { feedBytes(base, length); paint(); }
      return;
    }
    debugLog(`unhandled action ${action}`);
  }

  // The browser event -> (keyCode, baseLayoutKey, text) decode, shared by
  // keydown and keyup. A release has to resolve to the same key a press did or
  // the program sees a down for one key and an up for another; sharing the
  // decode is what guarantees that rather than two listeners agreeing by
  // inspection.
  function decodeKeyEvent(event) {
    let keyCode = keyCodeForName(event.key);
    let baseLayoutKey = 0;
    let text = 0;
    if (!keyCode) {
      const produced = event.key.length === 1 ? event.key.codePointAt(0) : 0;
      baseLayoutKey = baseLayoutKeyFromCode(event.code);
      if (!event.ctrlKey && !event.altKey) {
        keyCode = produced;
      } else {
        const mapped = layoutMap ? layoutMap.get(event.code) : undefined;
        if (mapped && mapped.length === 1) keyCode = mapped.codePointAt(0);
        else if (baseLayoutKey) keyCode = baseLayoutKey;
        else keyCode = produced;
      }
      text = (!event.ctrlKey && !event.altKey) ? produced : 0;
    }
    return keyCode || physicalKey(event) ? { keyCode, baseLayoutKey, text } : null;
  }

  // Native clipboard events carry the user's explicit clipboard gesture into
  // embedded documents without a second asynchronous permission request.
  ime.addEventListener('copy', (event) => {
    const text = selectionText();
    if (!text || !event.clipboardData) return;
    event.clipboardData.setData('text/plain', text);
    event.preventDefault();
  });
  ime.addEventListener('paste', (event) => {
    if (!event.clipboardData) return;
    event.preventDefault();
    if (sendPasteNotification(Array.from(event.clipboardData.types))) return;
    const text = event.clipboardData.getData('text/plain');
    if (text) { sendPaste(text); return; }
    if (!socket) return;
    const file = Array.from(event.clipboardData.files).find((item) => item.type === 'image/png');
    if (!file) return;
    const receivingSocket = socket;
    file.arrayBuffer().then((contents) => {
      if (socket !== receivingSocket) return;
      pasteImage(new Uint8Array(contents));
    }).catch((error) => debugLog(`paste refused: ${error.message}`));
  });

  // Key RELEASE. Kitty's REPORT_EVENTS clients want key-up, and the page cannot
  // tell whether the host's mode is on — so it reports every release and the
  // host's Core decides whether the program receives bytes. Standalone input
  // uses the local encoder. No replica-mode check belongs on this side.
  //
  // Not preventDefault()ed: a release the terminal ignores must still reach the
  // browser, or an IME composition that ends on key-up never completes.
  ime.addEventListener('keyup', (event) => {
    physicalKeysDown.delete(event.code);
    // A release of ⌃ or ⌘ is what disarms the break-out chord; every release
    // is reported so the ladder sees the modifiers as they are now.
    reportPointerLockChord(event, 0);
    const decoded = decodeKeyEvent(event);
    if (!decoded) return;
    const KEY_EVENT_RELEASE = 3; // Keys::KeyEventType::Release
    if (socket) {
      const frame = buildKeyEvent(decoded.keyCode, decoded.baseLayoutKey, positionModifiers(event), decoded.text, KEY_EVENT_RELEASE, physicalKey(event));
      if (frame) { event.preventDefault(); sendFrame(frame); }
    } else if (!isMirroringHost
        && feedKeyEvent(decoded.keyCode, decoded.baseLayoutKey, positionModifiers(event), decoded.text, KEY_EVENT_RELEASE, physicalKey(event))) {
      event.preventDefault();
      paint();
    }
  });

  ime.addEventListener('keydown', (event) => {
    physicalKeysDown.add(event.code);
    // Modifier edges also update the native pointer-lock escape chord.
    const isBareModifier = event.key === 'Shift' || event.key === 'Control' || event.key === 'Alt' || event.key === 'Meta';
    reportPointerLockChord(event, isBareModifier ? 0 : 1);
    if (isBareModifier) {
      if (socket) sendFrame(buildKeyEvent(0, 0, positionModifiers(event), 0, 1, physicalKey(event)));
      else if (!isMirroringHost) feedKeyEvent(0, 0, positionModifiers(event), 0, 1, physicalKey(event));
      return;
    }

    let keyCode = keyCodeForName(event.key);
    let baseLayoutKey = 0;
    let text = 0;
    if (!keyCode) {
      const produced = event.key.length === 1 ? event.key.codePointAt(0) : 0;
      baseLayoutKey = baseLayoutKeyFromCode(event.code);

      if (!event.ctrlKey && !event.altKey) {
        // Ordinary typing: `event.key` is the character produced, with shift and
        // layout already applied, so it is what gets sent. **Not** the layout
        // map, which answers the *unshifted* character for a physical key —
        // Shift+; would send `;` and Shift+a a lower-case letter.
        keyCode = produced;
      } else {
        // Ctrl or Alt is held, so the modifier has to fold into a key rather
        // than a character — and on macOS the system has already folded Option
        // into event.key, turning Option+F into U+0192. The layout map answers
        // what this physical key types in the user's own layout with no modifier
        // applied, which is what the fold needs.
        const mapped = layoutMap ? layoutMap.get(event.code) : undefined;
        if (mapped && mapped.length === 1) keyCode = mapped.codePointAt(0);
        else if (baseLayoutKey) keyCode = baseLayoutKey;
        else keyCode = produced;
      }

      // Associated text only when it *is* text: a modifier-transformed character
      // is not something a program reads as input.
      text = (!event.ctrlKey && !event.altKey) ? produced : 0;
    }
    if (!reportsKeyPositions() && (composing || event.isComposing)) return;
    if (!keyCode && !(reportsKeyPositions() && physicalKey(event))) return;

    const modifiers = keyModifiers(event);

    // Beam first, and only while it is open. Core decides which keys an open
    // palette owns and which reach the terminal — the alternative is this file
    // deciding, which is how three frontends end up disagreeing about whether
    // Escape closes the palette or reaches the program behind it.
    if (isBeamOpen() && feedBeamKey(keyCode, baseLayoutKey, modifiers, text)) {
      event.preventDefault();
      const command = takeBeamCommand();
      if (command) runBeamCommand(command);
      // A theme is applied inside WebTerminal rather than handed out as a
      // command, so the page learns about it by asking. Checked after every
      // Beam key because that is the only moment it can change.
      const theme = currentThemeName();
      if (theme && theme !== lastKnownTheme) {
        lastKnownTheme = theme;
        rememberTheme(theme);
        // The padding is painted by the page, so the colour behind the grid has
        // to follow the theme here too — otherwise the new theme's cells sit in
        // a frame the old theme left behind.
        applyBackgroundColor();
      }
      paint();
      return;
    }

    // Bindings resolve before encoding: a bound key is a command, not input.
    const action = resolveBinding(keyCode, baseLayoutKey, modifiers);
    if (action === -1) {
      // A leader key. Swallow it — encoding it would put a stray character in
      // the shell before the chord completes.
      event.preventDefault();
      return;
    }
    if (action !== 0) {
      const nativeClipboardChord = event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey
        && ((action === ACTION.paste && event.key.toLowerCase() === 'v')
          || (action === ACTION.copy && event.key.toLowerCase() === 'c'));
      if (nativeClipboardChord) return;
      event.preventDefault();
      performAction(action);
      return;
    }

    // An unbound Cmd combination stays with the browser: taking ⌘L or ⌘T would
    // break the surrounding application to no benefit.
    if (event.metaKey && !event.ctrlKey && !event.altKey) return;

    event.preventDefault();
    // A keystroke is a user gesture, which is the only context a browser will
    // take a permission request from. Asked once, and only once — a page that
    // re-asks on every key is one a user has already refused.
    requestNotificationPermissionOnce();
    // Typing returns to the live grid: a keystroke whose echo lands off-screen
    // reads as a dead terminal. Every terminal snaps back on input.
    scrollToBottom();
    // And drops any highlight, which would otherwise stand over content the
    // user has begun editing. Core owns the rule and reports whether anything
    // changed, so the common no-selection case costs no repaint.
    clearSelectionForUserInput();
    if (socket) {
      sendFrame(buildKeyEvent(keyCode, baseLayoutKey, positionModifiers(event), text, event.repeat ? 2 : 1, physicalKey(event)));
    } else if (!isMirroringHost && feedKeyEvent(keyCode, baseLayoutKey, positionModifiers(event), text, event.repeat ? 2 : 1, physicalKey(event))) {
      // STANDALONE only: with no host at all, the page is the terminal and the
      // same encoding fed straight back is what makes it usable.
      //
      // A page that has ever attached must not do this, socket or no socket. Its
      // grid is a mirror of the host's, and typing into the mirror forks it: the
      // host never saw those bytes, so the next Update is applied against a
      // baseline that no longer matches and patches the wrong cells. The gate is
      // the mirror flag rather than the live socket precisely because the two
      // moments the socket is absent — the reconnect gap, and after a detach —
      // are both moments the host's cells are still on screen.
      //
      // Dropped rather than buffered for replay. Replaying a burst of
      // keystrokes into a shell after an outage runs whatever they happen to
      // spell, and the user has no way to know what was still queued.
      paint();
    }
  });

  // --- Pointer -------------------------------------------------------------
  //
  // The browser reports a position, a button and the modifiers; everything
  // after that — which of DECSET 9/1000/1002/1003 is live, which coordinate
  // encoding applies, whether the event is a report, a locked delta, a locator
  // report, a hilite gesture or the page's own selection — is Core's, through
  // the same Input::routePointer the macOS, Linux and Swift frontends run. The
  // page contributes the pixel-to-cell division and applies the verdict.
  const pointer = module.cwrap('ubiquittyWebPointer', 'number', ['number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number']);
  const scroll = module.cwrap('ubiquittyWebScroll', 'number', ['number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number']);
  const pointerVerdict = module.cwrap('ubiquittyWebPointerVerdict', 'number', []);
  const linkAtCell = module.cwrap('ubiquittyWebLinkAtCell', 'string', ['number', 'number', 'number']);
  const pointerShape = module.cwrap('ubiquittyWebPointerShape', 'number', ['number', 'number', 'number', 'number']);
  const pointerShapeCount = module.cwrap('ubiquittyWebPointerShapeCount', 'number', []);
  const clearSelection = module.cwrap('ubiquittyWebClearSelection', null, []);
  const hasSelection = module.cwrap('ubiquittyWebHasSelection', 'number', []);
  const selectionText = module.cwrap('ubiquittyWebSelectionText', 'string', []);
  const scrollBy = module.cwrap('ubiquittyWebScrollBy', null, ['number']);
  const pageLines = module.cwrap('ubiquittyWebPageLines', 'number', []);
  const scrollToBottom = module.cwrap('ubiquittyWebScrollToBottom', null, []);

  // Ubiquitty::MousePointerShape in PAL/TerminalClients.h, in declaration order,
  // mapped to the CSS cursor nearest each. The shape is Core's ordered decision,
  // shared with macOS and Linux; the page only knows how to spell each one.
  //
  // Order is the whole contract and a wrong index is silent: with Pointer and
  // Text transposed, every cell of ordinary text draws the hand cursor that
  // says "this is a link". The length check below is what turns an insertion
  // into a console error instead of a wrong cursor.
  const CSS_CURSOR = [
    'default', 'pointer', 'text', 'vertical-text', 'crosshair', 'cell', 'move',
    'grab', 'grabbing', 'no-drop', 'not-allowed', 'alias', 'copy', 'help',
    'progress', 'wait', 'zoom-in', 'zoom-out', 'ew-resize', 'ns-resize',
    'nwse-resize', 'nesw-resize',
    'n-resize', 'ne-resize', 'e-resize', 'se-resize',
    's-resize', 'sw-resize', 'w-resize', 'nw-resize',
  ];
  if (CSS_CURSOR.length !== pointerShapeCount()) {
    debugLog(`pointer shapes: page has ${CSS_CURSOR.length}, Core has ${pointerShapeCount()} — cursors will be wrong`);
  }

  // The fact vocabulary, read from Core rather than restated: an enumeration
  // order spelled here is one that drifts.
  const readConstant = (name) => module.cwrap(name, 'number', [])();
  const MOUSE_PRESS = readConstant('ubiquittyWebPointerKindPress');
  const MOUSE_RELEASE = readConstant('ubiquittyWebPointerKindRelease');
  const MOUSE_MOTION = readConstant('ubiquittyWebPointerKindMotion');
  const BUTTON_NONE = readConstant('ubiquittyWebPointerButtonNone');
  // The browser orders buttons primary/middle/secondary.
  const POINTER_BUTTON = [
    readConstant('ubiquittyWebPointerButtonLeft'),
    readConstant('ubiquittyWebPointerButtonMiddle'),
    readConstant('ubiquittyWebPointerButtonRight'),
  ];
  const VERDICT_CONSUMED = readConstant('ubiquittyWebPointerVerdictConsumed');
  const VERDICT_NEEDS_DISPLAY = readConstant('ubiquittyWebPointerVerdictNeedsDisplay');
  const VERDICT_OPENED_GESTURE = readConstant('ubiquittyWebPointerVerdictOpenedGesture');
  const VERDICT_FINISHED_GESTURE = readConstant('ubiquittyWebPointerVerdictFinishedGesture');

  // Three rows per wheel notch — the step every terminal uses, and slow enough

  // The last cell the pointer was over, and whether the link modifier was held
  // there, so the link scan runs on a change rather than on every pixel of a
  // drag across one.
  let hovered = { row: -1, column: -1, modifier: 0 };
  let hoveredLink = '';
  // Command, or Ctrl on a keyboard with none: the modifier a reader holds to
  // open a link a plain click leaves alone, which Core names.
  const linkModifier = (event) => (event.metaKey || event.ctrlKey ? 1 : 0);
  // A local selection gesture Core opened on a press: its motion is a drag
  // fact, and the pointer shape stays the I-beam. Core's verdict, not a
  // page-side reading of the modes.
  let isDraggingSelection = false;
  // A secondary press Core took (a report, the locator) keeps the browser's
  // context menu from popping over an application that saw the click.
  let didConsumeSecondaryPress = false;

  function pointerCell(event) {
    const ratio = window.devicePixelRatio || 1;
    // Device pixels from the grid origin — the basis DECSET 1016 reports in and
    // the basis the cell division needs, so both come from one conversion. The
    // division, flooring and clamping are Core's, through the packed exports:
    // a hand-rolled copy here rounded where the native frontends floor, so the
    // same physical click reported a different pixel per frontend.
    const { x, y } = viewportPoint(event, screenViewport, ratio);
    const cell = pointerCellPacked(x, y);
    const pixel = pointerPixelPacked(x, y);
    return {
      column: cell & 0xffff,
      row: cell >> 16,
      pixelX: pixel & 0xffff,
      pixelY: pixel >> 16,
      // Where along the row the point is, unrounded: on a row set in a
      // proportional face, the letter under it and the fraction crossed.
      xInCells: pointerXInCells(x, y),
    };
  }

  // One event as a fact through Core's ladder. The verdict says what the page
  // does: prevent the browser's default when the event was taken,
  // repaint when the selection or a highlight changed, and track the local
  // gesture Core opened or finished. The bytes go to the host.
  const localPointerInput = module.cwrap('ubiquittyWebLocalPointerInput', 'number', []);
  const localPointerInputLength = module.cwrap('ubiquittyWebLocalPointerInputLength', 'number', []);
  function deliverLocalPointerInput() {
    if (isMirroringHost || !localProgram) return;
    const base = localPointerInput(), length = localPointerInputLength();
    if (base && length > 0) localProgram.input(module.HEAPU8.slice(base, base + length));
  }
  function routePointer(kind, button, event, isDragging) {
    const cell = pointerCell(event);
    // Under relative pointer lock Core reports the motion delta rather than a
    // position; the page hands it both and the mode decides.
    const deltaX = kind === MOUSE_MOTION ? (event.movementX | 0) : 0;
    const deltaY = kind === MOUSE_MOTION ? (event.movementY | 0) : 0;
    const base = pointer(kind, button, cell.row, cell.column, cell.pixelX, cell.pixelY, deltaX, deltaY,
      event.shiftKey ? 1 : 0, event.altKey ? 1 : 0, event.ctrlKey ? 1 : 0, event.metaKey ? 1 : 0,
      event.detail || 1, isDragging ? 1 : 0, cell.xInCells);
    const verdict = pointerVerdict();
    if (base && socket) sendFrame(base);
    else deliverLocalPointerInput();
    if (verdict & VERDICT_OPENED_GESTURE) isDraggingSelection = true;
    if (verdict & VERDICT_FINISHED_GESTURE) isDraggingSelection = false;
    if (verdict & VERDICT_NEEDS_DISPLAY) paint();
    if (verdict & VERDICT_CONSUMED) event.preventDefault();
    return verdict;
  }

  canvas.addEventListener('mousedown', (event) => {
    focusTerminal();
    // A primary click on a link opens it, and does not reach the program. What
    // counts as a link was already narrowed by Core's isLaunchableURLScheme, so
    // a `javascript:` URI a program wrote never arrives here — this listener
    // must not widen that, and window.open on an ungated URI would. An ssh,
    // sftp, ftp or ftps link opens only with the link modifier, so a click
    // holding a different one than the hover did asks Core again: the key can
    // go down after the pointer stopped moving.
    if (event.button === 0 && !pointerLockActive()) {
      const cell = pointerCell(event);
      const modifier = linkModifier(event);
      const isOverHoveredCell = cell.row === hovered.row && cell.column === hovered.column;
      const link = !isOverHoveredCell ? ''
        : modifier === hovered.modifier ? hoveredLink : linkAtCell(cell.row, cell.column, modifier);
      if (link) {
        event.preventDefault();
        window.open(link, '_blank', 'noopener,noreferrer');
        return;
      }
    }
    const verdict = routePointer(MOUSE_PRESS, POINTER_BUTTON[event.button] ?? BUTTON_NONE, event, false);
    if (event.button === 2) didConsumeSecondaryPress = (verdict & VERDICT_CONSUMED) !== 0;
  });
  canvas.addEventListener('mouseup', (event) => {
    routePointer(MOUSE_RELEASE, POINTER_BUTTON[event.button] ?? BUTTON_NONE, event, false);
  });
  canvas.addEventListener('mousemove', (event) => {
    if (isDraggingSelection) {
      routePointer(MOUSE_MOTION, POINTER_BUTTON[0], event, true);
      return;
    }
    // The shape is resolved on every motion, tracking or not: a link under a
    // tracking application still outranks the application's own affordance, and
    // that ordering is Core's to state rather than this listener's.
    const cell = pointerCell(event);
    const modifier = linkModifier(event);
    if (cell.row !== hovered.row || cell.column !== hovered.column || modifier !== hovered.modifier) {
      hovered = { row: cell.row, column: cell.column, modifier };
      hoveredLink = linkAtCell(cell.row, cell.column, modifier);
      canvas.style.cursor = CSS_CURSOR[pointerShape(hoveredLink ? 1 : 0, 0, 0, 0)] || 'default';
    }
    // A held button's motion is a drag fact; a plain move is a button-less
    // one, which any-event tracking (1003), the locator and a locked pointer
    // take and every other mode leaves alone.
    const held = event.buttons !== 0;
    const button = held ? (POINTER_BUTTON[event.button] ?? BUTTON_NONE) : BUTTON_NONE;
    routePointer(MOUSE_MOTION, button, event, held);
  });

  canvas.addEventListener('mouseleave', () => {
    hovered = { row: -1, column: -1, modifier: 0 };
    hoveredLink = '';
    canvas.style.cursor = 'default';
  });
  canvas.addEventListener('contextmenu', (event) => { if (didConsumeSecondaryPress) event.preventDefault(); });
  canvas.addEventListener('wheel', (event) => {
    // Core's wheel ladder: a report to a tracking host, cursor keys on the
    // alternate screen, or the local view, which Core moves itself. The
    // browser's deltaY grows toward newer content; the fact's grows toward
    // older. A pixel delta is a continuous surface; a line delta a notch.
    // deltaMode 1 is lines (a notched wheel); 0, the browser's default, is
    // pixels (a trackpad, normalised by the live cell height in Core).
    const cell = pointerCell(event);
    const isPrecise = event.deltaMode === 1 ? 0 : 1;
    const base = scroll(-(event.deltaX || 0), -(event.deltaY || 0), isPrecise, cell.row, cell.column, cell.pixelX, cell.pixelY,
      event.shiftKey ? 1 : 0, event.altKey ? 1 : 0, event.ctrlKey ? 1 : 0);
    const verdict = pointerVerdict();
    if (base && socket) sendFrame(base);
    else deliverLocalPointerInput();
    if (verdict & VERDICT_NEEDS_DISPLAY) paint();
    if (verdict & VERDICT_CONSUMED) event.preventDefault();
  }, { passive: false });

  // The IME element holds focus, not the canvas: an input method composes into
  // an editable element, and a canvas is not one. Every place that focuses the
  // terminal focuses this element, so keystrokes and compositions arrive at the
  // same element.
  if (window === window.top) focusTerminal();
  canvas.addEventListener('click', () => focusTerminal());
  // Focus drives three things at once: a program that enabled DEC 1004 hears
  // about it, the cursor draws hollow while the window is elsewhere, and a bell
  // only earns a notification when the user was not already looking. The window
  // events rather than the canvas's own: clicking the page chrome blurs the
  // canvas without the user having left the terminal.
  function reportFocus(focused) {
      setFocus(focused && document.visibilityState === 'visible' ? 1 : 0);
      // Attached, the program that enabled DEC 1004 runs against the HOST's
      // Terminal, so telling the local mirror is not telling it.
      if (socket)
          sendFrame(buildFocusChanged());
      paint();
  }
  window.addEventListener('focus', () => reportFocus(1));
  window.addEventListener('blur', () => reportFocus(0));
  document.addEventListener('visibilitychange', () => reportFocus(document.hasFocus() ? 1 : 0));
  // The grab is an OS fact only the page sees: reported on its edge, so the
  // lesson that names the way out stands for exactly as long as the trap.
  document.addEventListener('pointerlockchange', () => {
    notePointerLockGrab(document.pointerLockElement === canvas ? 1 : 0);
    paint();
  });
  setFocus(document.hasFocus() && document.visibilityState === 'visible' ? 1 : 0);
  // FontFaceSet changes can alter fallback shaping without changing a family
  // name or the grid's dimensions. Republish before the next native query.
  let isFontRefreshQueued = false;
  richText.onConfigurationChanged = () => {
    if (isFontRefreshQueued) return;
    isFontRefreshQueued = true;
    queueMicrotask(() => {
      isFontRefreshQueued = false;
      if (richText.isDisposed) return;
      publishFontOptions();
      rebuildFont();
      cellPx = { width: cellWidthPx(), height: cellHeightPx() };
      refitGrid();
      paint();
      sendOwedHostFrames();
    });
  };
}

// --- window.ubiquitty --------------------------------------------------------
//
// The embedder handle. A host page frames this terminal in an iframe or loads it
// as a module; either way it cannot reach into the closure, so the connection is
// driven from here.
//
//   await window.ubiquitty.ready;
//   window.ubiquitty.connect({ url: 'ws://…/ws', token: 't', sessionID: 0 });
//   window.ubiquitty.connectionState;  // 'attached' once the Welcome lands
//   window.ubiquitty.sessionID;        // what to pass to reattach to it
//   window.ubiquitty.requestSessions(); // asks the host again; 'ubiquitty-outline' when it answers
//   window.ubiquitty.requestOutline(); // 'ubiquitty-outline' when the host describes itself, and on every change
//   window.ubiquitty.outline('query'); // the rows to draw, optionally searched
//   window.ubiquitty.detach();
//
// Driving the connection and reading the host's session list are one handle
// because they are one question an embedder asks — which session, on which host —
// and a second global for the second half would be a name to keep in step.
//
// The methods that need the terminal live in main() and are installed into
// `embedderImplementation` when it runs. This half is created at MODULE scope,
// because the wasm factory resolves a turn or more after the import: an embedder
// reading window.ubiquitty on the tick it loaded the page would otherwise find
// nothing there and conclude the API does not exist. Until main() runs, every
// reader gets 'loading' and every caller gets an error naming the one thing that
// fixes it — an absent method reads as a feature that was never shipped.
//
// The state is READ THROUGH the implementation rather than copied onto this
// object, so there is one answer to "what is this page attached to" and no
// snapshot of it to go stale.
let embedderImplementation = {
  ...Object.fromEntries(['focus', 'configure', 'setLocalProgram', 'feed', 'clear', 'readMetadata', 'capture', 'snapshot']
    .map((name) => [name, () => { throw new Error(`ubiquitty.${name}: await window.ubiquitty.ready`); }])),
  search() { throw new Error('ubiquitty.search: await window.ubiquitty.ready'); },
  readSearchStatus() { throw new Error('ubiquitty.searchStatus: await window.ubiquitty.ready'); },
  stepSearch() { throw new Error('ubiquitty.stepSearch: await window.ubiquitty.ready'); },
  connect() { throw new Error('ubiquitty.connect: the terminal does not exist yet — await window.ubiquitty.ready'); },
  detach() { throw new Error('ubiquitty.detach: the terminal does not exist yet — await window.ubiquitty.ready'); },
  requestSessions() { throw new Error('ubiquitty.requestSessions: the terminal does not exist yet — await window.ubiquitty.ready'); },
  requestOutline() { throw new Error('ubiquitty.requestOutline: the terminal does not exist yet — await window.ubiquitty.ready'); },
  // Throws where readState answers 'loading', because an outline of no rows is
  // an ANSWER — every session on the host ended — and a page with no client
  // yet would be handing back that answer without having asked anyone.
  readOutline() { throw new Error('ubiquitty.outline: the terminal does not exist yet — await window.ubiquitty.ready'); },
  setOutlineRowOpen() { throw new Error('ubiquitty.setOutlineRowOpen: the terminal does not exist yet — await window.ubiquitty.ready'); },
  readState: () => ({ connectionState: 'loading', sessionID: 0, url: '', wireVersion: 0, appVersion: '', buildIdentity: '' }),
};

const workspaceViewID = window.frameElement?.dataset.workspaceView ?? new URLSearchParams(location.search).get('workspaceView');
const modulePromise = workspaceViewID !== null && window.parent !== window
  ? window.parent.ubiquittyWorkspace.createModule(Number(workspaceViewID)) : createModule();
const pageReadyPromise = modulePromise.then(main).then(() => window.ubiquitty);
pageReadyPromise.catch((error) => {
  status.textContent = `failed: ${error}`;
  console.error(error);
});

window.ubiquitty = {
  // Resolves with this object once the terminal exists, and rejects with what
  // killed the page. The rejection is reported above as well, so an embedder that
  // never reads `ready` still gets the reason on screen and in the console rather
  // than an unhandled rejection.
  ready: pageReadyPromise,
  repaint() { return embedderImplementation.repaint(); },
  attachWorkspace(id, transport) { return embedderImplementation.attachWorkspace(id, transport); },
  setVisible(visible) { return embedderImplementation.setVisible(visible); },
  sendTransport(bytes) { return embedderImplementation.sendTransport(bytes); },
  get bufferedAmount() { return embedderImplementation.bufferedAmount?.() || 0; },
  workspaceTree() { return embedderImplementation.workspaceTree(); },
  settingsCatalog() { return embedderImplementation.settingsCatalog(); },
  get connectionNotice() { return embedderImplementation.connectionNotice(); },
  hostCall(method, parameters) { return embedderImplementation.hostCall(method, parameters); },
  focus() { return embedderImplementation.focus(); },
  configure(options) { return embedderImplementation.configure(options); },
  setLocalProgram(program) { return embedderImplementation.setLocalProgram(program); },
  feed(text) { return embedderImplementation.feed(text); },
  clear() { return embedderImplementation.clear(); },
  get metadata() { return embedderImplementation.readMetadata(); },
  capture() { return embedderImplementation.capture(); },
  snapshot() { return embedderImplementation.snapshot(); },
  // Literal, case-sensitive search. An empty query clears it; progress and
  // completion arrive as ubiquitty-search events carrying searchStatus.
  search(literal) { return embedderImplementation.search(literal); },
  get searchStatus() { return embedderImplementation.readSearchStatus(); },
  stepSearch(direction) { return embedderImplementation.stepSearch(direction); },
  connect(options) { return embedderImplementation.connect(options); },
  detach() { return embedderImplementation.detach(); },
  requestSessions() { return embedderImplementation.requestSessions(); },
  requestOutline() { return embedderImplementation.requestOutline(); },
  outline(query) { return embedderImplementation.readOutline(query); },
  setOutlineRowOpen(row, open) { return embedderImplementation.setOutlineRowOpen(row, open); },
  get connectionState() { return embedderImplementation.readState().connectionState; },
  get sessionID() { return embedderImplementation.readState().sessionID; },
  get url() { return embedderImplementation.readState().url; },
  // The Sync protocol version this build speaks; 0 until the terminal exists.
  get wireVersion() { return embedderImplementation.readState().wireVersion; },
  // The build's version, "0.2.0.3", and what identifies the build beside it,
  // "1a2b3c4d, modified"; empty until the terminal exists.
  get appVersion() { return embedderImplementation.readState().appVersion; },
  get buildIdentity() { return embedderImplementation.readState().buildIdentity; },
};
