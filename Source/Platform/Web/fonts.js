// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Canvas fallback can draw a missing private-use glyph from an installed Nerd
// Font, making raster comparisons indistinguishable. For fonts we ship, ask
// their actual Unicode cmap instead of inferring coverage from that fallback.
export function fontCoverage(buffer) {
    if (buffer.byteLength < 12 || buffer.byteLength > 16 * 1024 * 1024) throw new Error('Invalid font size');
    const data = new DataView(buffer);
    const fits = (offset, length) =>
        Number.isSafeInteger(offset) && offset >= 0 && length >= 0 && offset + length <= data.byteLength;
    const count = data.getUint16(4);
    if (!fits(12, count * 16)) throw new Error('Invalid font directory');
    let cmap = 0,
        size = 0;
    for (let index = 0; index < count; index++) {
        const entry = 12 + index * 16;
        if (data.getUint32(entry) === 0x636d6170) {
            cmap = data.getUint32(entry + 8);
            size = data.getUint32(entry + 12);
            break;
        }
    }
    if (!cmap || !fits(cmap, size) || size < 4) throw new Error('Font has no Unicode cmap');
    const records = data.getUint16(cmap + 2),
        tables = [];
    if (4 + records * 8 > size) throw new Error('Invalid cmap directory');
    for (let index = 0; index < records; index++) {
        const record = cmap + 4 + index * 8,
            platform = data.getUint16(record),
            encoding = data.getUint16(record + 2);
        if (platform !== 0 && !(platform === 3 && (encoding === 1 || encoding === 10))) continue;
        const offset = data.getUint32(record + 4),
            table = cmap + offset;
        if (offset + 4 > size) continue;
        const format = data.getUint16(table);
        if (format === 12 && offset + 16 <= size) {
            const length = data.getUint32(table + 4),
                groups = data.getUint32(table + 12);
            if (length < 16 || offset + length > size || groups > (length - 16) / 12) continue;
            tables.push((code) => {
                let low = 0,
                    high = groups;
                while (low < high) {
                    const middle = (low + high) >>> 1,
                        at = table + 16 + middle * 12;
                    if (code < data.getUint32(at)) high = middle;
                    else if (code > data.getUint32(at + 4)) low = middle + 1;
                    else return data.getUint32(at + 8) + code - data.getUint32(at) !== 0;
                }
                return false;
            });
        } else if (format === 4 && offset + 16 <= size) {
            const length = data.getUint16(table + 2),
                segments = data.getUint16(table + 6) / 2;
            if (!Number.isInteger(segments) || length < 16 + segments * 8 || offset + length > size) continue;
            tables.push((code) => {
                if (code > 0xffff) return false;
                let low = 0,
                    high = segments;
                while (low < high) {
                    const middle = (low + high) >>> 1;
                    if (data.getUint16(table + 14 + middle * 2) < code) low = middle + 1;
                    else high = middle;
                }
                if (low === segments) return false;
                const start = data.getUint16(table + 16 + segments * 2 + low * 2);
                if (code < start) return false;
                const delta = data.getInt16(table + 16 + segments * 4 + low * 2);
                const at = table + 16 + segments * 6 + low * 2,
                    range = data.getUint16(at);
                if (!range) return ((code + delta) & 0xffff) !== 0;
                const glyphAt = at + range + (code - start) * 2;
                if (glyphAt + 2 > table + length) return false;
                const glyph = data.getUint16(glyphAt);
                return glyph !== 0 && ((glyph + delta) & 0xffff) !== 0;
            });
        }
    }
    if (!tables.length) throw new Error('Font has no supported Unicode cmap');
    return (code) =>
        Number.isInteger(code) && code >= 0 && code <= 0x10ffff && tables.some((has) => has(code));
}

let loading;
export function loadTerminalFonts() {
    if (!loading)
        loading = Promise.all(
            [
                ['JetBrains Mono', 'JetBrainsMono[wght].ttf', { weight: '100 800' }],
                ['JetBrains Mono', 'JetBrainsMono-Italic[wght].ttf', { weight: '100 800', style: 'italic' }],
                ['Symbols Nerd Font Mono', 'SymbolsNerdFontMono-Regular.ttf', {}],
            ].map(async ([family, file, descriptors]) => {
                const response = await fetch(new URL(`fonts/${file}`, import.meta.url));
                if (!response.ok) throw new Error(`Could not load ${family}: ${response.status}`);
                const bytes = await response.arrayBuffer();
                const face = await new FontFace(family, bytes, descriptors).load();
                document.fonts.add(face);
                return [family.toLowerCase(), fontCoverage(bytes)];
            }),
        ).then((entries) => new Map(entries));
    return loading;
}

// A FontFace descriptor is the Canvas API's route to OpenType features. Keep
// registrations in the rendering document and share them across workspace panes.
const featureFaces = new Map();
export async function prepareFont(family, features, variations, coverage) {
    if (!features && !variations) return family;
    const key = JSON.stringify([family, features, variations]);
    if (featureFaces.has(key)) return featureFaces.get(key);
    const pending = (async () => {
        const result = [];
        for (const raw of family.split(',')) {
            const name = raw.trim().replace(/^['"]|['"]$/g, '');
            if (['monospace', 'sans-serif', 'serif', 'ui-monospace', 'system-ui'].includes(name)) {
                result.push(raw);
                continue;
            }
            let hash = 2166136261;
            for (const character of key) hash = Math.imul(hash ^ character.charCodeAt(0), 16777619);
            const alias = `Ubiquitty face ${hash >>> 0}-${result.length}`;
            const loaded = [];
            for (const [italic, bold] of [
                [false, false],
                [true, false],
                [false, true],
                [true, true],
            ]) {
                const bundled = name === 'JetBrains Mono';
                if (bundled && bold) continue;
                const descriptors = { weight: bold ? '700' : '400', style: italic ? 'italic' : 'normal' };
                if (features) descriptors.featureSettings = features;
                if (variations) descriptors.variationSettings = variations;
                if (bundled) descriptors.weight = '100 800';
                const source = bundled
                    ? `url(${JSON.stringify(new URL(`fonts/JetBrainsMono${italic ? '-Italic' : ''}[wght].ttf`, import.meta.url).href)})`
                    : (italic || bold
                          ? [
                                `${name} ${bold ? 'Bold' : ''}${italic ? ' Italic' : ''}`.replace(/ +/g, ' '),
                                `${name.replace(/(?:-Regular)?$/, '').replace(/ /g, '')}-${bold ? 'Bold' : ''}${italic ? 'Italic' : ''}`,
                            ]
                          : [name]
                      )
                          .map((candidate) => `local(${JSON.stringify(candidate)})`)
                          .join(', ');
                try {
                    loaded.push(await new FontFace(alias, source, descriptors).load());
                } catch {
                    /* Try the next family in the user's cascade. */
                }
            }
            if (!loaded.length) {
                result.push(raw);
                continue;
            }
            for (const face of loaded) document.fonts.add(face);
            const has = coverage?.get(name.toLowerCase());
            if (has) coverage.set(alias.toLowerCase(), has);
            result.push(JSON.stringify(alias));
        }
        return result.join(', ');
    })();
    featureFaces.set(key, pending);
    return pending;
}
