// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Exercises the actual Canvas bridges through Wasm and as extracted JavaScript.
// The minimal Wasm probe also supplies Core's fitting policy; no app is built.
// Run with em++ on PATH and UBQ_CORE_ROOT naming the matching Core checkout.

import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const core = process.env.UBQ_CORE_ROOT;
if (!core) throw new Error('UBQ_CORE_ROOT must name the matching Core checkout');
const cache = path.join(os.homedir(), '.cache/ms-playwright');
const browser = process.env.UBQ_CHROMIUM || fs.readdirSync(cache)
  .filter(name => name.startsWith('chromium-')).sort().reverse()
  .map(name => path.join(cache, name, 'chrome-linux64/chrome')).find(name => fs.existsSync(name));
if (!browser) throw new Error('Set UBQ_CHROMIUM to a headless Chromium executable');
const indic = process.env.UBQ_INDIC_FONT || spawnSync('fc-match', ['-f', '%{file}', 'Noto Sans Devanagari'], { encoding: 'utf8' }).stdout;
if (!indic || !fs.existsSync(indic) || !/Devanagari/i.test(indic))
  throw new Error('Set UBQ_INDIC_FONT to a Devanagari font fixture');
const cjk = process.env.UBQ_CJK_FONT || spawnSync('fc-match', ['-f', '%{file}', 'Noto Sans CJK JP'], { encoding: 'utf8' }).stdout;
if (!cjk || !fs.existsSync(cjk) || !/CJK/i.test(cjk))
  throw new Error('Set UBQ_CJK_FONT to a CJK font fixture');
const emoji = process.env.UBQ_EMOJI_FONT || spawnSync('fc-match', ['-f', '%{file}', 'Noto Color Emoji'], { encoding: 'utf8' }).stdout;
if (!emoji || !fs.existsSync(emoji) || !/emoji/i.test(emoji))
  throw new Error('Set UBQ_EMOJI_FONT to an emoji font fixture');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ubq-cluster-cell-fit-'));
const sourcePath = path.join(root, 'Source/Platform/Web/WebFontRasterizer.cpp');
const source = fs.readFileSync(sourcePath, 'utf8');
const names = ['webFontMeasureCluster', 'webFontDrawClusterInCell', 'webFontDrawCluster'];
const bodies = Object.fromEntries(names.map(name => {
  const start = source.indexOf(`EM_JS(int, ${name},`);
  const body = source.indexOf('), {', start) + 4;
  const end = source.indexOf('\n});', body);
  if (start < 0 || body < 4 || end < 0) throw new Error(`Cannot extract ${name}`);
  return [name, source.slice(body, end)];
}));
const probe = `#include ${JSON.stringify(sourcePath)}
namespace Ubiquitty::Web {
extern "C" {
EMSCRIPTEN_KEEPALIVE int clusterInitializeProbe(int size, double* advances, int* metrics)
{ return webFontMeasure(size, 32, 95, advances, metrics, metrics + 1, metrics + 2); }
EMSCRIPTEN_KEEPALIVE int clusterMeasureProbe(const char* family, const uint32_t* points, int count, int size, int weight, int italic, int pictograph, double* metrics)
{ return webFontMeasureCluster(family, points, count, size, weight, italic, pictograph, metrics); }
EMSCRIPTEN_KEEPALIVE int clusterDrawProbe(const char* family, const uint32_t* points, int count, int size, int weight, int italic, double phase, double left, double width, double across, double down, double pen, double baseline, int slotWidth, int slotHeight, int pictograph, uint8_t* coverage)
{ return webFontDrawClusterInCell(family, points, count, size, weight, italic, phase, left, width, across, down, pen, baseline, slotWidth, slotHeight, pictograph, coverage); }
EMSCRIPTEN_KEEPALIVE int clusterRawProbe(const char* family, const uint32_t* points, int count, int size, int weight, int italic, int baseline, int width, int height, int pictograph, uint8_t* coverage)
{ return webFontDrawCluster(family, points, count, size, weight, italic, baseline, width, height, pictograph, coverage); }
EMSCRIPTEN_KEEPALIVE void clusterFitProbe(double left, double right, double targetLeft, double width, double* result)
{ const auto fit = Rendering::fitClusterHorizontal(left, right, { targetLeft, width }); result[0] = fit.scaleX; result[1] = fit.translationX; }
}
}
`;
fs.writeFileSync(path.join(temporary, 'probe.cpp'), probe);
const exports = ['_malloc', '_free', '_clusterInitializeProbe', '_clusterMeasureProbe', '_clusterDrawProbe', '_clusterRawProbe', '_clusterFitProbe'];
const compile = spawnSync(process.env.EMXX || 'em++', ['-std=c++23', '-O1', '-fno-exceptions', '-fno-rtti', '-Wall', '-Wextra', '-Werror',
  `-I${path.join(root, 'Source')}`, `-I${path.join(core, 'Source')}`, path.join(temporary, 'probe.cpp'), '--no-entry',
  '-sMODULARIZE=1', '-sEXPORT_ES6=1', `-sEXPORTED_FUNCTIONS=${JSON.stringify(exports)}`,
  '-sEXPORTED_RUNTIME_METHODS=["HEAPU8","HEAPU32","HEAPF64","UTF8ToString"]', '-o', path.join(temporary, 'probe.mjs')], { encoding: 'utf8' });
fs.writeFileSync(path.join(temporary, 'compile.log'), `${compile.stdout || ''}${compile.stderr || ''}`);
if (compile.status !== 0) throw new Error(`Wasm bridge compile failed: ${temporary}/compile.log\n${compile.stderr || compile.error}`);

async function exercise(createModule, bridgeBodies) {
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const fontFiles = [['Fit Primary', '/primary.ttf'], ['Fit Marks', '/marks.ttf'], ['Fit Indic', '/indic.ttf'],
    ['Fit CJK', '/cjk.ttf'], ['Fit Emoji', '/emoji.ttf']];
  for (const [family, url] of fontFiles) {
    const font = new FontFace(family, `url(${url})`);
    document.fonts.add(await font.load());
  }
  await document.fonts.ready;
  const module = await createModule();
  const memory = module._malloc(65536);
  const familyPointer = memory;
  const pointsPointer = memory + 512;
  const metricsPointer = memory + 1024;
  const fitPointer = memory + 1152;
  const coveragePointer = memory + 4096;
  const family = '"Fit Primary", "Fit Marks", "Fit Indic", "Fit CJK", "Fit Emoji"';
  module.HEAPU8.set(new TextEncoder().encode(`${family}\0`), familyPointer);
  module.ubiquittyFontFamilyCSS = family;
  module.ubiquittyFontCanvas = document.createElement('canvas');
  module.ubiquittyFontContext = module.ubiquittyFontCanvas.getContext('2d', { willReadFrequently: true });
  assert(module._clusterInitializeProbe(32, memory + 2048, memory + 3072), 'initialize actual Canvas bridge');
  Object.assign(globalThis, { Module: module, HEAPU8: module.HEAPU8, HEAPU32: module.HEAPU32, HEAPF64: module.HEAPF64,
    UTF8ToString: () => family });
  const measure = new Function('familyPtr', 'codePoints', 'count', 'pixelSize', 'cssWeight', 'isItalic', 'isTextPictograph', 'metricsOut', bridgeBodies.webFontMeasureCluster);
  const draw = new Function('familyPtr', 'codePoints', 'count', 'pixelSize', 'cssWeight', 'isItalic', 'phaseInPixels', 'cellLeft', 'cellWidth',
    'horizontalScale', 'verticalScale', 'penX', 'baseline', 'slotWidth', 'slotHeight', 'isTextPictograph', 'coverageOut', bridgeBodies.webFontDrawClusterInCell);
  const drawRaw = new Function('familyPtr', 'codePoints', 'count', 'pixelSize', 'cssWeight', 'isItalic', 'baseline',
    'slotWidth', 'slotHeight', 'isTextPictograph', 'coverageOut', bridgeBodies.webFontDrawCluster);
  const reference = document.createElement('canvas');
  reference.width = 96;
  reference.height = 160;
  const painter = reference.getContext('2d', { willReadFrequently: true });
  const naturalExamples = ['漢́', '語⃝', '👩‍👩‍👧‍👧', 'Z̵̡̠̫͌̎͝'];
  const texts = ['क्षि', 'का', 'कि', 'ά', '❤️́', '\u0600❤️́', ...naturalExamples];
  assert(texts[0].codePointAt(0) === 0x915 && naturalExamples[0].codePointAt(0) === 0x6f22
    && naturalExamples[2].codePointAt(0) === 0x1f469 && naturalExamples[3].codePointAt(1) === 0x335,
  'test document preserves the intended Unicode scalars');
  const rawItalic = () => {
    module.HEAPU32.set([0x66, 0xfe0e, 0x200d], pointsPointer >> 2);
    assert(module._clusterRawProbe(familyPointer, pointsPointer, 3, 32, 400, 1, 32, 48, 64, 0, coveragePointer), 'raw italic draw');
    return module.HEAPU8.slice(coveragePointer, coveragePointer + 48 * 64);
  };
  const initialItalic = rawItalic();
  let comparisons = 0;
  let inkOverflowCases = 0;
  let advanceOverflowCases = 0;
  let opticalCases = 0;
  let naturalCases = 0;
  const preservedExamples = new Set();
  const measured = [];
  for (const text of texts) {
    const points = Array.from(text, character => character.codePointAt(0));
    module.HEAPU32.set(points, pointsPointer >> 2);
    const pictograph = text.includes('❤') || text.includes('👩') ? 1 : 0;
    const isWide = pictograph || text.startsWith('漢') || text.startsWith('語');
    for (const italic of [0, 1]) {
      const size = pictograph ? 256 : 32;
      const baseline = 96;
      module.ubiquittyFontContext.fontKerning = 'none';
      assert(module._clusterMeasureProbe(familyPointer, pointsPointer, points.length, size, 400, italic, pictograph, metricsPointer), 'Wasm Canvas measure');
      assert(module.ubiquittyFontContext.fontKerning === 'auto', 'measurement sets its own shaping state');
      const metrics = Array.from(module.HEAPF64.subarray(metricsPointer >> 3, (metricsPointer >> 3) + 5));
      measured.push({ text, italic, metrics });
      painter.font = `${italic ? 'italic ' : ''}400 ${size}px ${family}`;
      painter.textBaseline = 'alphabetic';
      painter.textAlign = 'left';
      painter.fontKerning = 'auto';
      const nativeInk = painter.measureText(pictograph ? text.replace(/\uFE0F/g, '\uFE0E') : text);
      const nativeMetrics = [nativeInk.width, -nativeInk.actualBoundingBoxLeft, nativeInk.actualBoundingBoxRight,
        -nativeInk.actualBoundingBoxAscent, nativeInk.actualBoundingBoxDescent];
      assert(metrics.every((value, index) => value === nativeMetrics[index]), 'complete native advance and ink metrics');
      assert(measure(familyPointer, pointsPointer, points.length, size, 400, italic, pictograph, metricsPointer), 'extracted Canvas measure');
      assert(metrics.every((value, index) => value === module.HEAPF64[(metricsPointer >> 3) + index]), 'extracted measurement matches actual Wasm bridge');
      for (const width of [8, 16, 24, metrics[0]]) {
        for (const phase of [0, 0.25, 0.75]) {
          const left = 8 + phase;
          const shouldFit = !isWide && metrics[0] > width;
          let across = 1, down = 1, pen = 0, y = baseline;
          if (pictograph) {
            const inkWidth = metrics[2] - metrics[1];
            const inkHeight = metrics[4] - metrics[3];
            const optical = Math.min(1, inkWidth > 0 ? 96 / inkWidth : 1, inkHeight > 0 ? 160 / inkHeight : 1);
            across = down = optical;
            if (optical < 1) ++opticalCases;
            pen = (96 - inkWidth * optical) / 2 - metrics[1] * optical;
            y = Math.max(-metrics[3] * optical, Math.min(baseline, 160 - metrics[4] * optical));
          }
          if (shouldFit) {
            const sourceLeft = phase + Math.min(0, metrics[1]);
            const sourceRight = phase + Math.max(metrics[0], metrics[2]);
            module._clusterFitProbe(sourceLeft, sourceRight, left, width, fitPointer);
            across = module.HEAPF64[fitPointer >> 3];
            pen = phase * across + module.HEAPF64[(fitPointer >> 3) + 1];
            if (['क्षि', 'का', 'कि'].includes(text)) ++advanceOverflowCases;
          } else {
            ++naturalCases;
            if (naturalExamples.includes(text)) preservedExamples.add(text);
            if (metrics[0] <= width && metrics[2] - Math.min(0, metrics[1]) > width) ++inkOverflowCases;
          }
          const args = [familyPointer, pointsPointer, points.length, size, 400, italic, phase, left, width, across, down, pen, y, 96, 160, pictograph, coveragePointer];
          const rawArgs = [familyPointer, pointsPointer, points.length, size, 400, italic, baseline, 96, 160, pictograph, coveragePointer];
          if (comparisons === 0) {
            module.ubiquittyFontCanvas.width = 32;
            module.ubiquittyFontCanvas.height = 32;
          }
          module.ubiquittyFontContext.fontKerning = shouldFit ? 'none' : 'auto';
          assert(shouldFit ? module._clusterDrawProbe(...args) : module._clusterRawProbe(...rawArgs), 'Wasm cluster draw');
          assert(module.ubiquittyFontContext.fontKerning === 'auto', 'drawing retains the measured shaping state after canvas growth');
          const actual = module.HEAPU8.slice(coveragePointer, coveragePointer + 96 * 160);
          module.ubiquittyFontContext.fontKerning = shouldFit ? 'none' : 'auto';
          assert(shouldFit ? draw(...args) : drawRaw(...rawArgs), 'extracted cluster draw');
          assert(module.ubiquittyFontContext.fontKerning === 'auto', 'drawing retains the measured shaping state without canvas growth');
          assert(actual.every((value, index) => value === module.HEAPU8[coveragePointer + index]), 'extracted drawing matches actual Wasm bridge');
          painter.setTransform(1, 0, 0, 1, 0, 0);
          painter.clearRect(0, 0, 96, 160);
          painter.font = `${italic ? 'italic ' : ''}400 ${size}px ${family}`;
          painter.textBaseline = 'alphabetic';
          painter.textAlign = 'left';
          painter.fillStyle = '#fff';
          painter.save();
          if (shouldFit) {
            painter.beginPath();
            painter.rect(left, 0, width, 160);
            painter.clip();
          }
          painter.setTransform(across, 0, 0, down, pen, y);
          painter.fillText(pictograph ? text.replace(/\uFE0F/g, '\uFE0E') : text, 0, 0);
          painter.restore();
          const expected = painter.getImageData(0, 0, 96, 160).data;
          let hasInk = false;
          for (let index = 0; index < actual.length; ++index) {
            assert(actual[index] === expected[index * 4 + 3], `${text}: whole shaped affine coverage`);
            const x = index % 96;
            if (shouldFit && (x + 1 <= left || x >= left + width)) assert(actual[index] === 0, `${text}: advance overflow stays contained`);
            hasInk ||= actual[index] !== 0;
          }
          assert(hasInk, `${text}: fitting retains ink`);
          ++comparisons;
        }
      }
    }
  }
  assert(inkOverflowCases > 0, `native overhang survives a fitting advance: ${JSON.stringify(measured)}`);
  assert(advanceOverflowCases > 0, 'real Indic advance overflow exercises whole-cluster fitting');
  assert(preservedExamples.size === naturalExamples.length, 'all reported examples preserve native coverage');
  assert(opticalCases > 0, 'text pictographs retain their existing optical scale');
  const finalItalic = rawItalic();
  assert(initialItalic.every((value, index) => value === finalItalic[index]), 'bounded drawing leaves raw italic coverage unchanged');
  module._free(memory);
  return { comparisons, naturalCases, inkOverflowCases, advanceOverflowCases, opticalCases,
    preservedExamples: [...preservedExamples], indicFixture: true, cjkFixture: true, emojiFixture: true, wasmBridge: true, extractedBridge: true };
}

const fonts = new Map([
  ['/primary.ttf', path.join(core, 'Resources/fonts/JetBrainsMono[wght].ttf')],
  ['/marks.ttf', path.join(core, 'Resources/fonts/NotoSans-Regular.ttf')],
  ['/indic.ttf', indic],
  ['/cjk.ttf', cjk],
  ['/emoji.ttf', emoji],
]);
const html = `<!doctype html><meta charset="utf-8"><pre id="result">pending</pre><script type="module">
import createModule from '/probe.mjs';
try { document.querySelector('#result').textContent = JSON.stringify(await (${exercise.toString()})(createModule, ${JSON.stringify(bodies)})); }
catch(error) { document.querySelector('#result').textContent = JSON.stringify({ error: error.stack || String(error) }); }
</script>`;
const server = http.createServer((request, response) => {
  fs.appendFileSync(path.join(temporary, 'requests.log'), `${request.url}\n`);
  if (request.url === '/') { response.setHeader('Content-Type', 'text/html; charset=utf-8'); response.end(html); return; }
  const file = fonts.get(request.url) || (request.url === '/probe.mjs' || request.url === '/probe.wasm' ? path.join(temporary, request.url.slice(1)) : null);
  if (!file) { response.writeHead(404).end(); return; }
  response.setHeader('Content-Type', request.url.endsWith('.mjs') ? 'text/javascript' : request.url.endsWith('.wasm') ? 'application/wasm' : 'font/ttf');
  fs.createReadStream(file).pipe(response);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let child;
let socket;
let timeout;
try {
  const profile = path.join(temporary, 'profile');
  child = spawn(browser, ['--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run', '--disable-extensions',
    '--disable-background-networking', '--disable-component-update', '--disable-sync', '--no-proxy-server',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank']);
  child.stderr.on('data', bytes => fs.appendFileSync(path.join(temporary, 'browser.log'), bytes));
  child.stdout.on('data', bytes => fs.appendFileSync(path.join(temporary, 'browser.stdout'), bytes));
  const exited = new Promise((resolve, reject) => { child.once('close', resolve); child.once('error', reject); });
  timeout = setTimeout(() => child.kill('SIGKILL'), 30000);
  const deadline = Date.now() + 25000;
  const portFile = path.join(profile, 'DevToolsActivePort');
  while (!fs.existsSync(portFile) && Date.now() < deadline) await delay(50);
  if (!fs.existsSync(portFile)) throw new Error(`Chromium has no DevTools endpoint: ${temporary}/browser.log`);
  const [port, endpoint] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
  socket = new WebSocket(`ws://127.0.0.1:${port}${endpoint}`);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  let nextID = 1;
  const pending = new Map();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  });
  socket.addEventListener('close', () => {
    for (const request of pending.values()) request.reject(new Error('Chromium DevTools closed'));
    pending.clear();
  });
  const call = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = nextID++;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params, sessionId }));
  });
  const target = await call('Target.createTarget', { url: `http://127.0.0.1:${server.address().port}/` });
  const { sessionId } = await call('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  let encoded;
  while (Date.now() < deadline) {
    const reply = await call('Runtime.evaluate', { expression: "document.querySelector('#result')?.textContent", returnByValue: true }, sessionId);
    encoded = reply.result?.value;
    if (encoded && encoded !== 'pending') break;
    await delay(100);
  }
  const document = await call('Runtime.evaluate', { expression: 'document.documentElement.outerHTML', returnByValue: true }, sessionId);
  fs.writeFileSync(path.join(temporary, 'browser.html'), document.result.value);
  if (!encoded || encoded === 'pending') throw new Error(`Chromium did not complete: ${temporary}/browser.log`);
  const result = JSON.parse(encoded);
  if (result.error) throw new Error(result.error);
  await call('Browser.close');
  await exited;
  console.log(`cluster-cell-fitting: ok ${JSON.stringify(result)}; artifacts ${temporary}`);
} finally {
  clearTimeout(timeout);
  socket?.close();
  child?.kill('SIGTERM');
  server.close();
}
