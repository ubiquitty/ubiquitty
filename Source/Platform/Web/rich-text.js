// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RTF parsing, paragraph policy, fit, selection and hit testing stay in Core.
// The browser contributes native line breaking, shaping and grapheme carets,
// then presents retained lines at the positions Core captures for the frame.
const units = (value) => Math.round(value * 4096);
const rgb = (color) => `rgb(${color.join(' ')})`;
const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

// FontFaceSet exposes fonts actually loaded by the page. System inventory is
// separate: only a local user's explicit action may request Local Font Access.
// Renderers and OSC callbacks read this snapshot synchronously and never prompt.
export class FontCatalog extends EventTarget {
    constructor(measureDocument = document, platform = measureDocument.defaultView || globalThis) {
        super();
        this.platform = platform;
        this.sourceFonts = measureDocument.fonts;
        this.fontSets = new Map();
        this.loadedFaces = new Map();
        this.systemFamilies = null;
        this.systemRequestRevision = 0;
        this.families = [];
        this.scope = 1;
        this.revision = 1;
        this.addFontSet(measureDocument.fonts);
    }

    addFontSet(fonts) {
        if (!fonts) return;
        const held = this.fontSets.get(fonts);
        if (held) {
            ++held.references;
            return;
        }
        const changed = () => this.refresh(true);
        this.fontSets.set(fonts, { references: 1, changed });
        fonts.addEventListener?.('loadingdone', changed);
        fonts.addEventListener?.('loadingerror', changed);
        this.refresh();
    }

    removeFontSet(fonts) {
        const held = this.fontSets.get(fonts);
        if (!held || --held.references) return;
        fonts.removeEventListener?.('loadingdone', held.changed);
        fonts.removeEventListener?.('loadingerror', held.changed);
        this.fontSets.delete(fonts);
        this.refresh();
    }

    refresh(force = false) {
        const names = new Set(this.systemFamilies || []);
        const fontSets = [...this.fontSets.keys()].filter((fonts) => typeof fonts[Symbol.iterator] === 'function');
        const loaded = typeof this.sourceFonts?.[Symbol.iterator] === 'function'
            ? [...this.sourceFonts].filter((face) => face.status === 'loaded') : [];
        const loadedFaces = new Map(loaded.map((face) => [face, JSON.stringify([
            face.family, face.style, face.weight, face.stretch, face.unicodeRange,
            face.featureSettings, face.variationSettings, face.ascentOverride, face.descentOverride, face.lineGapOverride,
        ])]));
        const facesChanged = loadedFaces.size !== this.loadedFaces.size
            || [...loadedFaces].some(([face, signature]) => this.loadedFaces.get(face) !== signature);
        this.loadedFaces = loadedFaces;
        // Measurement can live in the parent document while painting lives in
        // an iframe. Transfer loaded script-created faces to both. CSS-connected
        // faces cannot be moved; advertise those only when every document has
        // the family, so a discovered font is usable for measurement and paint.
        for (const fonts of fontSets) {
            for (const face of loaded) {
                if (fonts.has?.(face)) continue;
                try { fonts.add(face); } catch { /* CSS-connected face in another document. */ }
            }
        }
        // FontFace.family is the literal matching name, including quotes or
        // backslashes supplied through the JS API. CSS-connected faces already
        // expose the parsed name; interpreting escapes again changes identity.
        const exposed = fontSets.map((fonts) => new Set([...fonts].filter((face) => face.status === 'loaded').map((face) => face.family)));
        for (const family of new Set(loaded.map((face) => face.family))) {
            if (exposed.every((families) => families.has(family))) names.add(family);
        }
        const encoder = new TextEncoder();
        const entries = [...names].filter((name) => typeof name === 'string' && name.length && !name.startsWith(' ') && !name.endsWith(' ')
            && !/[\u0000-\u001f\u007f-\u009f\ud800-\udfff]/u.test(name) && encoder.encode(name).length <= 255)
            .map((name) => ({ name, bytes: encoder.encode(name) }));
        entries.sort((left, right) => {
            for (let index = 0; index < Math.min(left.bytes.length, right.bytes.length); ++index) {
                if (left.bytes[index] !== right.bytes[index]) return left.bytes[index] - right.bytes[index];
            }
            return left.bytes.length - right.bytes.length;
        });
        const families = entries.map((entry) => entry.name);
        const scope = this.systemFamilies === null ? 1 : 2;
        if (!force && !facesChanged && scope === this.scope && families.length === this.families.length
            && families.every((family, index) => family === this.families[index])) return;
        this.families = families;
        this.byName = new Map();
        for (const family of families) {
            if (!this.byName.has(family.toLowerCase())) this.byName.set(family.toLowerCase(), family);
        }
        this.scope = scope;
        this.revision = (this.revision + 1) >>> 0 || 1;
        this.dispatchEvent(new Event('change'));
    }

    get canRequestSystemFonts() {
        return typeof this.platform.queryLocalFonts === 'function';
    }

    family(name) {
        return this.byName?.get(name.toLowerCase()) || '';
    }

    async requestSystemFonts() {
        if (!this.canRequestSystemFonts) return false;
        const requestRevision = ++this.systemRequestRevision;
        // Invoke before any await: the native API requires transient activation.
        const pending = this.platform.queryLocalFonts();
        const faces = await pending;
        if (requestRevision !== this.systemRequestRevision) return false;
        if (!this.permission && this.platform.navigator?.permissions) {
            try {
                const permission = await this.platform.navigator.permissions.query({ name: 'local-fonts' });
                if (requestRevision !== this.systemRequestRevision) return false;
                this.permission = permission;
                this.permissionChanged = () => {
                    if (this.permission.state === 'granted') return;
                    ++this.systemRequestRevision;
                    this.systemFamilies = null;
                    this.refresh(true);
                };
                this.permission.addEventListener('change', this.permissionChanged);
            } catch {
                // Enumeration can be supported even when permission introspection is absent.
            }
        }
        if (requestRevision !== this.systemRequestRevision) return false;
        this.systemFamilies = this.permission && this.permission.state !== 'granted' ? null : faces.map((face) => face.family);
        this.refresh(true);
        return this.systemFamilies !== null;
    }

    dispose() {
        ++this.systemRequestRevision;
        for (const [fonts, held] of this.fontSets) {
            fonts.removeEventListener?.('loadingdone', held.changed);
            fonts.removeEventListener?.('loadingerror', held.changed);
        }
        this.fontSets.clear();
        this.permission?.removeEventListener('change', this.permissionChanged);
    }
}

export class RichTextRenderer {
    constructor(measureDocument = document, metricsCache = new Map(), fontCatalog = null) {
        this.measureRoot = measureDocument.createElement('div');
        this.measureRoot.setAttribute('aria-hidden', 'true');
        this.measureRoot.style.cssText =
            'position:fixed;left:-100000px;top:0;visibility:hidden;pointer-events:none;contain:layout style paint;width:max-content;max-width:none;font-synthesis:none';
        measureDocument.body.append(this.measureRoot);
        this.canvas = measureDocument.createElement('canvas');
        this.context = this.canvas.getContext('2d');
        this.layers = new Map();
        this.metricsCache = metricsCache;
        this.fontGeneration = 1;
        this.ownsFontCatalog = !fontCatalog;
        this.fontCatalog = fontCatalog || new FontCatalog(measureDocument);
        this.fontSets = [...new Set([measureDocument.fonts, document.fonts].filter(Boolean))];
        this.fontsChanged = () => this.invalidateFonts();
        for (const fonts of this.fontSets) this.fontCatalog.addFontSet(fonts);
        this.fontCatalog.addEventListener('change', this.fontsChanged);
        this.root = document.createElement('div');
        this.root.setAttribute('aria-hidden', 'true');
        this.root.style.cssText =
            'position:absolute;left:0;top:0;pointer-events:none;user-select:none;transform-origin:0 0;overflow:hidden;font-synthesis:none';
    }

    dispose() {
        this.isDisposed = true;
        this.fontCatalog.removeEventListener('change', this.fontsChanged);
        for (const fonts of this.fontSets) this.fontCatalog.removeFontSet(fonts);
        if (this.ownsFontCatalog) this.fontCatalog.dispose();
        this.onConfigurationChanged = null;
        this.measureRoot.remove();
        this.root.remove();
        this.layers.clear();
    }

    invalidateFonts() {
        if (this.isDisposed) return;
        this.fontGeneration = (this.fontGeneration + 1) >>> 0 || 1;
        this.metricsCache.clear();
        this.lastFrame = null;
        this.onConfigurationChanged?.();
    }

    get features() {
        return this.fontFeatures || '';
    }

    set features(value) {
        if (this.features === value) return;
        this.fontFeatures = value;
        this.invalidateFonts();
    }

    metrics(family, bits) {
        const key = `${family}:${bits}`;
        if (this.metricsCache.has(key)) return this.metricsCache.get(key);
        const context = this.context;
        context.font = `${bits & 2 ? 'italic ' : ''}${bits & 1 ? 700 : 400} 32px ${family}`;
        context.textBaseline = 'alphabetic';
        const sample = context.measureText('Hg');
        const ascent = sample.fontBoundingBoxAscent ?? sample.actualBoundingBoxAscent;
        const descent = sample.fontBoundingBoxDescent ?? sample.actualBoundingBoxDescent;
        const values = [
            ascent / 32,
            descent / 32,
            (ascent + descent) / 32,
            context.measureText('n').width / 32,
        ];
        for (let point = 0x20; point <= 0x24f; point++)
            values.push(context.measureText(String.fromCodePoint(point)).width / 32);
        if (this.metricsCache.size >= 128) this.metricsCache.delete(this.metricsCache.keys().next().value);
        this.metricsCache.set(key, values);
        return values;
    }

    applyStyle(element, style, families) {
        const fallback = families[style.family];
        const family = style.name ? this.fontCatalog.family(style.name) : '';
        element.style.fontFamily = family ? `${JSON.stringify(family)}, ${fallback}` : fallback;
        element.style.fontFeatureSettings = this.features || 'normal';
        element.style.fontSize = `${style.size}px`;
        element.style.fontWeight = style.bits & 1 ? '700' : '400';
        element.style.fontStyle = style.bits & 2 ? 'italic' : 'normal';
        element.style.textDecorationLine =
            [style.bits & 4 ? 'underline' : '', style.bits & 8 ? 'line-through' : '']
                .filter(Boolean)
                .join(' ') || 'none';
        element.style.color = style.color ? rgb(style.color) : 'inherit';
    }

    textElement(model, first, end, { wrap = false, width, indent = 0, shift = 0 } = {}) {
        const element = document.createElement('div');
        element.style.cssText = `position:relative;display:inline-block;white-space:${wrap ? 'pre-wrap' : 'pre'};overflow-wrap:anywhere;line-height:normal;vertical-align:top;unicode-bidi:plaintext;text-align:start;letter-spacing:normal;word-spacing:normal;padding:0;border:0;margin:0`;
        const initial =
            model.styles.find((style) => style.first <= first && style.end > first) || model.styles[0];
        this.applyStyle(element, { ...initial, color: null, bits: initial.bits & 3 }, model.families);
        if (wrap) {
            element.style.width = `${Math.max(0, width)}px`;
            element.style.textIndent = `${indent}px`;
        } else if (shift) {
            element.style.textIndent = `${shift}px`;
        }
        element.style.tabSize = `${model.tabWidth || 64}px`;
        const points = [];
        for (const style of model.styles) {
            const start = Math.max(first, style.first),
                stop = Math.min(end, style.end);
            if (start >= stop) continue;
            const span = document.createElement('span');
            this.applyStyle(span, style, model.families);
            const content = model.text
                .slice(start, stop)
                .map((point) => (point === 0x2028 ? '\n' : String.fromCodePoint(point)))
                .join('');
            const node = document.createTextNode(content);
            span.append(node);
            element.append(span);
            let offset = 0;
            for (let index = start; index < stop; index++) {
                points[index - first] = { node, offset };
                offset += model.text[index] > 0xffff ? 2 : 1;
            }
            points[stop - first] = { node, offset };
        }
        return { element, points };
    }

    graphemes(model, first, end) {
        const scalars = model.text.slice(first, end),
            text = String.fromCodePoint(...scalars);
        const offsets = new Map();
        let offset = 0;
        scalars.forEach((point, index) => {
            offsets.set(offset, first + index);
            offset += point > 0xffff ? 2 : 1;
        });
        offsets.set(offset, end);
        return [...segmenter.segment(text)].map(({ index, segment }) => ({
            first: offsets.get(index),
            end: offsets.get(index + segment.length),
            break: segment === '\n' || segment === '\u2028',
        }));
    }

    range(points, first, end) {
        const range = points[first].node.ownerDocument.createRange();
        range.setStart(points[first].node, points[first].offset);
        range.setEnd(points[end].node, points[end].offset);
        return range;
    }

    // A line holding a tab is set on the content box's tab grid, as Core's
    // table layout and the native shapers set it. Its element starts at the
    // grid's origin and its text is indented to the line's indent, since tab
    // stops are measured from the element's edge. A hanging first line's grid
    // starts a whole number of stops left of the left indent and no further
    // right than its text, so its first tab stops at the indent and no pen
    // position is negative, where a stop would be skipped. Carets and the
    // width are measured from where the text starts.
    line(model, first, end, { indent = 0, hanging = 0 } = {}) {
        // A trailing line separator contributes a selectable zero-width span, not
        // another visible line in this retained line element.
        let shownEnd = end;
        while (shownEnd > first && [10, 0x2028].includes(model.text[shownEnd - 1])) shownEnd--;
        const hasTab = model.text.slice(first, shownEnd).includes(9);
        const tabWidth = model.tabWidth || 64;
        const gridOrigin = hanging > indent ? hanging - tabWidth * Math.ceil((hanging - indent) / tabWidth) : 0;
        const shift = hasTab ? indent - gridOrigin : 0;
        const text = this.textElement(model, first, Math.max(first, shownEnd), { shift });
        const marker = document.createElement('span');
        marker.style.cssText =
            'display:inline-block;width:0;height:0;padding:0;border:0;margin:0;vertical-align:baseline';
        text.element.append(marker);
        this.measureRoot.append(text.element);
        const rect = text.element.getBoundingClientRect();
        const baseline = marker.getBoundingClientRect().top - rect.top;
        const textLeft = rect.left + shift;
        // The element's own width counts its indent, so a tab line's width is
        // its glyphs' extent from where its text starts.
        const width = hasTab
            ? this.range(text.points, 0, shownEnd - first).getBoundingClientRect().right - textLeft
            : rect.width;
        return { ...text, rect, baseline, marker, shownEnd, shift, textLeft, width };
    }

    shape(model) {
        if (model.text.length > 4096 || model.styles.length > 512) return null;
        const lines = [],
            spans = [];
        try {
            for (const [first, end, width, indent, rest = 0, hanging = 0] of model.paragraphs) {
                const text = this.textElement(model, first, end, { wrap: !model.clip, width, indent });
                this.measureRoot.append(text.element);
                const groups = [];
                for (const cluster of this.graphemes(model, first, end)) {
                    const range = this.range(text.points, cluster.first - first, cluster.end - first);
                    const rect = range.getBoundingClientRect();
                    let group = groups.at(-1);
                    if (
                        !group ||
                        group.broken ||
                        (!cluster.break &&
                            Math.min(rect.bottom, group.bottom) - Math.max(rect.top, group.top) < 1)
                    ) {
                        group = {
                            first: cluster.first,
                            end: cluster.end,
                            top: rect.top,
                            bottom: rect.bottom,
                            broken: false,
                            clusters: [],
                        };
                        groups.push(group);
                    }
                    group.end = cluster.end;
                    group.clusters.push(cluster);
                    group.broken = cluster.break;
                }
                text.element.remove();
                for (const group of groups) {
                    // `indent` is the first line's indent past the others'.
                    const startsParagraph = group.first === first;
                    const line = this.line(model, group.first, group.end, {
                        indent: startsParagraph ? rest + indent : rest,
                        hanging: startsParagraph ? hanging : 0,
                    });
                    const lineIndex = lines.length;
                    lines.push([
                        group.first,
                        group.end,
                        units(line.rect.height),
                        units(line.baseline),
                        units(line.width),
                    ]);
                    for (const cluster of group.clusters) {
                        let leading = line.width,
                            trailing = leading;
                        if (!cluster.break) {
                            const range = this.range(
                                line.points,
                                cluster.first - group.first,
                                cluster.end - group.first,
                            );
                            const rect = range.getBoundingClientRect();
                            const start = range.cloneRange(),
                                finish = range.cloneRange();
                            start.collapse(true);
                            finish.collapse(false);
                            const startRect = start.getBoundingClientRect(),
                                endRect = finish.getBoundingClientRect();
                            const hasCarets =
                                startRect.height > 0 &&
                                endRect.height > 0 &&
                                Math.abs(startRect.left - endRect.left) > 0.01;
                            leading = (hasCarets ? startRect.left : rect.left) - line.textLeft;
                            trailing = (hasCarets ? endRect.left : rect.right) - line.textLeft;
                        }
                        spans.push([cluster.first, cluster.end, lineIndex, units(leading), units(trailing)]);
                    }
                    line.element.remove();
                }
            }
            const geometry = [lines.length, spans.length, ...lines.flat(), ...spans.flat()];
            return geometry.every((value) => Number.isInteger(value) && value >= 0 && value < 0x7fffffff) ? geometry : null;
        } finally {
            this.measureRoot.replaceChildren();
        }
    }

    present(frame, canvas, scale) {
        const signature = JSON.stringify([
            frame,
            canvas.width,
            canvas.height,
            canvas.style.left,
            canvas.style.top,
            scale,
        ]);
        if (signature === this.lastFrame) return;
        this.lastFrame = signature;
        const visible = new Set();
        for (const block of frame.blocks) {
            visible.add(block.id);
            let entry = this.layers.get(block.id);
            if (!entry) {
                const element = document.createElement('div');
                element.style.cssText = 'position:absolute;overflow:hidden';
                this.root.append(element);
                entry = { element, key: '' };
                this.layers.set(block.id, entry);
            }
            const [left, top, width, height] = block.rect;
            Object.assign(entry.element.style, {
                left: `${left}px`,
                top: `${top}px`,
                width: `${width}px`,
                height: `${height}px`,
                color: rgb(block.color),
            });
            // A union of the host's surviving cell rectangles, after partial erases.
            entry.element.style.clipPath = block.clips.length
                ? `path('${block.clips.map(([x, y, w, h]) => `M${x} ${y}h${w}v${h}h${-w}Z`).join(' ')}')`
                : 'none';
            if (block.document) {
                entry.key = block.key;
                const model = { ...block.document, families: frame.families };
                const background = document.createElement('div'),
                    text = document.createElement('div');
                background.style.cssText = 'position:absolute;inset:0;z-index:0';
                text.style.cssText = 'position:absolute;inset:0;z-index:2';
                const [sx, sy] = block.scale;
                for (const cluster of model.clusters) {
                    const style = model.styles[cluster[7]];
                    if (!style.background) continue;
                    const rect = document.createElement('div');
                    Object.assign(rect.style, {
                        position: 'absolute',
                        left: `${Math.round(cluster[2] * sx)}px`,
                        top: `${Math.round(cluster[5] * sy)}px`,
                        width: `${Math.round((cluster[2] + cluster[4]) * sx) - Math.round(cluster[2] * sx)}px`,
                        height: `${Math.round((cluster[5] + cluster[6]) * sy) - Math.round(cluster[5] * sy)}px`,
                        background: rgb(style.background),
                    });
                    background.append(rect);
                }
                const lines = model.lines.length
                    ? model.lines
                    : model.clusters.map((cluster) => cluster.slice(0, 4));
                for (const [first, end, x, baseline, indent = 0, hanging = 0] of lines) {
                    let source = model;
                    if (first === end)
                        source = {
                            ...model,
                            text: [0x2026],
                            styles: [{ ...model.styles.at(-1), first: 0, end: 1 }],
                        };
                    // Set through the same tab grid it was measured on, so its
                    // text starts at Core's origin for the line.
                    const line =
                        first === end ? this.line(source, 0, 1) : this.line(source, first, end, { indent, hanging });
                    line.marker.remove();
                    Object.assign(line.element.style, {
                        position: 'absolute',
                        left: `${(x - line.shift) * sx}px`,
                        top: `${(baseline - line.baseline) * sy}px`,
                        transformOrigin: '0 0',
                        transform: `scale(${sx},${sy})`,
                    });
                    text.append(line.element);
                }
                entry.element.replaceChildren(background, text);
            }
        }
        for (const [id, entry] of this.layers)
            if (!visible.has(id)) {
                entry.element.remove();
                this.layers.delete(id);
            }
        for (const mark of this.root.querySelectorAll('[data-highlight]')) mark.remove();
        for (const block of frame.blocks) {
            const entry = this.layers.get(block.id);
            const [left, top, width, height] = block.rect;
            for (const [x, y, w, h, r, g, b, a] of frame.highlights) {
                if (x + w <= left || x >= left + width || y + h <= top || y >= top + height) continue;
                const highlight = document.createElement('div');
                highlight.dataset.highlight = '';
                Object.assign(highlight.style, {
                    position: 'absolute',
                    left: `${x - left}px`,
                    top: `${y - top}px`,
                    width: `${w}px`,
                    height: `${h}px`,
                    background: `rgb(${r * 255} ${g * 255} ${b * 255} / ${a})`,
                    zIndex: frame.selectionBehind ? '1' : '3',
                });
                entry.element.append(highlight);
            }
        }
        this.caret?.remove();
        if (frame.caret) {
            const [x, y, w, h, r, g, b, a, stroke] = frame.caret;
            const caret = document.createElement('div');
            const color = `rgb(${r * 255} ${g * 255} ${b * 255} / ${a})`;
            Object.assign(caret.style, {
                position: 'absolute',
                boxSizing: 'border-box',
                left: `${x}px`,
                top: `${y}px`,
                width: `${w}px`,
                height: `${h}px`,
                zIndex: '4',
                ...(stroke > 0 ? { border: `${stroke}px solid ${color}` } : { background: color }),
            });
            this.root.append(caret);
            this.caret = caret;
        }
        // Terminal chrome is already in the canvas. Cut its rectangles out of
        // the text overlay so Beam and transient hints remain above the block.
        let visibleRects = [[0, 0, canvas.width, canvas.height]];
        for (const [ox, oy, ow, oh] of frame.occlusions || []) {
            visibleRects = visibleRects.flatMap(([x, y, w, h]) => {
                const left = Math.max(x, ox),
                    top = Math.max(y, oy);
                const right = Math.min(x + w, ox + ow),
                    bottom = Math.min(y + h, oy + oh);
                if (right <= left || bottom <= top) return [[x, y, w, h]];
                return [
                    [x, y, w, top - y],
                    [x, bottom, w, y + h - bottom],
                    [x, top, left - x, bottom - top],
                    [right, top, x + w - right, bottom - top],
                ].filter((rect) => rect[2] > 0 && rect[3] > 0);
            });
        }
        this.root.style.clipPath = frame.occlusions?.length
            ? `path('${visibleRects.map(([x, y, w, h]) => `M${x} ${y}h${w}v${h}h${-w}Z`).join(' ')}')`
            : 'none';
        this.root.style.left = canvas.style.left;
        this.root.style.top = canvas.style.top;
        this.root.style.width = `${canvas.width}px`;
        this.root.style.height = `${canvas.height}px`;
        this.root.style.transform = `scale(${scale})`;
    }
}
