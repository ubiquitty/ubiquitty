// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { installStubDom, makeFontSet } from './stub-dom.mjs';

installStubDom(fileURLToPath(new URL('../../Source/Platform/Web/', import.meta.url)));
const fontSet = document.fonts;
const source = await readFile(new URL('../../Source/Platform/Web/rich-text.js', import.meta.url), 'utf8');
const { FontCatalog, RichTextRenderer } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const first = new RichTextRenderer(document);
const second = new RichTextRenderer(document);
let measurements = 0;
const measureText = first.context.measureText.bind(first.context);
first.context.measureText = (text) => {
    ++measurements;
    return measureText(text);
};
let notifications = 0;
first.onConfigurationChanged = () => ++notifications;
const original = first.metrics('sans-serif', 0);
const measured = measurements;
assert.equal(first.metrics('sans-serif', 0), original);
assert.equal(measurements, measured);
const firstGeneration = first.fontGeneration;
const secondGeneration = second.fontGeneration;
fontSet.dispatchEvent(new Event('loadingdone'));
assert.notEqual(first.fontGeneration, firstGeneration);
assert.notEqual(second.fontGeneration, secondGeneration);
assert.equal(notifications, 1);
const renewed = first.metrics('sans-serif', 0);
assert.deepEqual(renewed, original);
assert.notEqual(renewed, original);
assert.ok(measurements > measured);
const siblingGeneration = second.fontGeneration;
first.features = '"liga" 0';
assert.equal(notifications, 2);
assert.equal(second.fontGeneration, siblingGeneration);
first.features = '"liga" 0';
assert.equal(notifications, 2);
const retiredGeneration = first.fontGeneration;
first.dispose();
fontSet.dispatchEvent(new Event('loadingerror'));
assert.equal(first.fontGeneration, retiredGeneration);
assert.notEqual(second.fontGeneration, siblingGeneration);
assert.equal(notifications, 2);
second.dispose();

const exposed = await new FontFace('標本 字体 🦉', new ArrayBuffer(0)).load();
fontSet.add(exposed);
fontSet.add(new FontFace('Unloaded family', new ArrayBuffer(0)));
fontSet.add(await new FontFace(' Bad edge', new ArrayBuffer(0)).load());
fontSet.add(await new FontFace('界'.repeat(86), new ArrayBuffer(0)).load());
const permission = new EventTarget();
permission.state = 'granted';
let systemRequests = 0;
const platform = {
    queryLocalFonts() {
        ++systemRequests;
        return Promise.resolve([{ family: 'System font' }, { family: 'System font' }, { family: 'Another family' }]);
    },
    navigator: { permissions: { query: async () => permission } },
};
const catalog = new FontCatalog(document, platform);
assert.equal(systemRequests, 0, 'reading a catalog must never request local-font permission');
assert.equal(catalog.scope, 1, 'loaded page fonts are an exposed subset, not a system inventory');
assert.deepEqual(catalog.families, ['標本 字体 🦉']);
assert.equal(document.fonts.check('16px "Unloaded family"'), true);
assert.ok(!catalog.families.includes('Unloaded family'), 'check() success does not prove a font is available');
const stableRevision = catalog.revision;
catalog.refresh();
assert.equal(catalog.revision, stableRevision, 'unchanged inventory keeps paging stable');
const third = new RichTextRenderer(document, new Map(), catalog);
const beforeGrant = third.fontGeneration;
await catalog.requestSystemFonts();
assert.equal(systemRequests, 1);
assert.equal(catalog.scope, 2);
assert.deepEqual(catalog.families, ['Another family', 'System font', '標本 字体 🦉']);
assert.notEqual(third.fontGeneration, beforeGrant, 'granting inventory invalidates the pane publication');
const element = document.createElement('span');
third.applyStyle(element, { family: 2, name: '標本 字体 🦉', size: 12, bits: 3 }, ['sans-serif', 'serif', 'monospace']);
assert.equal(element.style.fontFamily, '"標本 字体 🦉", monospace');
assert.equal(element.style.fontWeight, '700');
assert.equal(element.style.fontStyle, 'italic');
third.applyStyle(element, { family: 2, name: 'Imaginary Installed Font', size: 12, bits: 3 }, ['sans-serif', 'serif', 'monospace']);
assert.equal(element.style.fontFamily, 'monospace', 'an unexposed guessed name uses the declared class');
const paintingFonts = makeFontSet();
catalog.addFontSet(paintingFonts);
assert.ok(paintingFonts.has(exposed), 'measurement and painting documents share the real loaded face');
assert.ok(catalog.families.includes('標本 字体 🦉'));
catalog.removeFontSet(paintingFonts);
const beforeNewStyle = third.fontGeneration;
fontSet.add(await new FontFace('標本 字体 🦉', new ArrayBuffer(0)).load());
catalog.refresh();
assert.notEqual(third.fontGeneration, beforeNewStyle, 'a new face with an existing family invalidates native shaping');
const beforeRevocation = third.fontGeneration;
permission.state = 'denied';
permission.dispatchEvent(new Event('change'));
assert.equal(catalog.scope, 1);
assert.deepEqual(catalog.families, ['標本 字体 🦉']);
assert.notEqual(third.fontGeneration, beforeRevocation);
assert.equal(systemRequests, 1, 'revocation must not automatically prompt again');
platform.queryLocalFonts = async () => { throw new Error('Permission denied'); };
await assert.rejects(catalog.requestSystemFonts(), /Permission denied/);
assert.equal(catalog.scope, 1, 'denial preserves the honest exposed inventory');
let completeEnumeration;
permission.state = 'granted';
platform.queryLocalFonts = () => new Promise((resolve) => { completeEnumeration = resolve; });
const pendingEnumeration = catalog.requestSystemFonts();
permission.state = 'denied';
permission.dispatchEvent(new Event('change'));
completeEnumeration([{ family: 'Late private family' }]);
assert.equal(await pendingEnumeration, false);
assert.equal(catalog.scope, 1, 'a late asynchronous result cannot restore a revoked inventory');
assert.ok(!catalog.families.includes('Late private family'));
let completePermission;
const pendingPermissionCatalog = new FontCatalog(document, {
    queryLocalFonts: async () => [{ family: 'Disposed private family' }],
    navigator: { permissions: { query: () => new Promise((resolve) => { completePermission = resolve; }) } },
});
const pendingPermission = pendingPermissionCatalog.requestSystemFonts();
await Promise.resolve();
pendingPermissionCatalog.dispose();
completePermission(permission);
assert.equal(await pendingPermission, false);
assert.equal(pendingPermissionCatalog.permission, undefined, 'disposal must prevent a late permission listener from being registered');
const revokedBeforeWatch = new FontCatalog(document, {
    queryLocalFonts: async () => [{ family: 'Revoked private family' }],
    navigator: { permissions: { query: async () => ({ state: 'prompt', addEventListener() {}, removeEventListener() {} }) } },
});
assert.equal(await revokedBeforeWatch.requestSystemFonts(), false);
assert.equal(revokedBeforeWatch.scope, 1, 'revocation before the permission watcher exists must not expose system inventory');
revokedBeforeWatch.dispose();
for (const family of ['"A\\20 B"', '"Quote \\" and \\\\ name"', '"Astral \\1f989 "', '\ue000', '\u{10000}'])
    fontSet.add(await new FontFace(family, new ArrayBuffer(0)).load());
catalog.refresh();
assert.ok(catalog.families.includes('"A\\20 B"'));
assert.ok(catalog.families.includes('"Quote \\" and \\\\ name"'));
assert.ok(catalog.families.includes('"Astral \\1f989 "'));
assert.ok(!catalog.families.includes('A B'), 'literal family names must not be reinterpreted as CSS escapes');
assert.ok(catalog.families.indexOf('\ue000') < catalog.families.indexOf('\u{10000}'), 'catalog order is UTF-8 bytes, not UTF-16 code units');
third.dispose();
catalog.dispose();
console.log('rich-text-invalidation: font events, equal metrics, pane-local revisions, real inventory, permission boundaries and disposal pass');
