// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../../Source/Platform/Web/fonts.js', import.meta.url), 'utf8');
const { fontCoverage } = await import(
    `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`
);
const coverage = async (name) => {
    const bytes = await readFile(new URL(`../../Resources/fonts/${name}`, import.meta.url));
    return fontCoverage(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
};
const nerd = await coverage('SymbolsNerdFontMono-Regular.ttf');
for (const code of [0xe5fa, 0xe700, 0xea60, 0xf013, 0xf101, 0xf0001])
    assert.equal(nerd(code), true, code.toString(16));
for (const code of [0x41, 0x10ffff, -1, 0x110000, NaN, 1.5]) assert.equal(nerd(code), false, String(code));
const mono = await coverage('JetBrainsMono[wght].ttf');
for (const code of [0x41, 0x42, 0x20, 0x2500]) assert.equal(mono(code), true);
assert.equal(mono(0xf0001), false);
for (const length of [0, 4, 12, 32]) assert.throws(() => fontCoverage(new ArrayBuffer(length)));
console.log('font-coverage: bundled BMP/supplementary icons, primary coverage and malformed tables pass');
