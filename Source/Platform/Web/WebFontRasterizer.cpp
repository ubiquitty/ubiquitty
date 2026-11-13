// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Web/WebFontRasterizer.h"
#include "Core/ClusterPool.h"

#include "Core/Rendering/CellLayout.h"
#include "Core/Rendering/FontMetrics.h"
#include "Core/Rendering/GlyphBackendTypes.h"
#include "Core/Rendering/GlyphTiling.h"
#include "Core/Rendering/RuleGeometry.h"
#include "Core/Rendering/SizedMaster.h"

#include "Core/Rendering/Font/ScriptClassifier.h"
#include "Core/Unicode/UTF8Decoder.h"
#include "Core/Unicode/Width.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <span>
#include <string>

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#endif

namespace Ubiquitty::Web {

namespace {

#ifdef __EMSCRIPTEN__

// The measuring and drawing surface. One canvas serves every glyph: it is sized
// to the largest slot asked for and reused, because creating one per glyph would
// allocate a backing store per cache miss.
//
// `alpha: true` and a white fill: the coverage this seam wants is the alpha
// channel, so drawing opaque white on transparent black makes the read-back a
// straight channel extract rather than a luminance conversion that would bake in
// a gamma the other rasterizers do not apply.
// clang-format off
// The configured family, quoted for CSS, as a string the caller frees.
//
// Quoting happens here and the result is published as `ubiquittyFontFamilyCSS`:
// every other site reads that rather than repeating the rule, so the
// specification the inventory probes and the one the rasterizer draws with
// cannot drift apart.
//
// Recomputed on every call rather than computed once. The page changes
// `ubiquittyFontFamily` at run time in two places — OSC 50 through
// applyPendingFontFamily, and the Beam font palette — and each then rebuilds the
// font stack, which constructs a rasterizer that asks here. A value kept from
// the first call outlives the family it was quoted from, so every later rebuild
// measures and draws the face the page opened with and the new family is
// discarded in silence. The quoting is a few string operations once per font
// rebuild, not per glyph, so there is nothing here worth the staleness.
// clang-format off
EM_JS(int, webFontPrimaryFamily, (char* out, int capacity), {
    {
        const family = Module.ubiquittyFontFamily;
        if (!family)
            return 0;
        // A name that is not a valid unquoted CSS identifier makes the whole
        // font shorthand unparseable, and the canvas setter ignores an
        // unparseable value in silence. A name the embedder already quoted, or a
        // list, is left alone: quoting those would create that invalid value.
        //
        // A generic is a KEYWORD, not a name, and quoting one turns it into a
        // request for a family literally called "monospace" — which no system
        // has, so the measurement fails and the terminal falls back to its
        // bundled bitmap face, taking the colour atlas with it.
        const genericFamilies = [
            "serif", "sans-serif", "monospace", "cursive", "fantasy",
            "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace",
            "ui-rounded", "math", "emoji", "fangsong",
        ];
        const quoteCharacter = "\"";
        const leaveAlone = family.indexOf(",") >= 0
            || family.indexOf(quoteCharacter) >= 0 || family.indexOf("'") >= 0
            || genericFamilies.indexOf(family.trim().toLowerCase()) >= 0;
        Module.ubiquittyFontFamilyCSS = leaveAlone ? family : quoteCharacter + family + quoteCharacter;
    }
    // Written byte by byte rather than through a runtime string helper: those
    // exist only when EXPORTED_RUNTIME_METHODS names them, and a host that
    // trimmed one would fail here at run time rather than at link.
    const bytes = new TextEncoder().encode(Module.ubiquittyFontFamilyCSS);
    if (bytes.length + 1 > capacity)
        return 0;
    HEAPU8.set(bytes, out);
    HEAPU8[out + bytes.length] = 0;
    return bytes.length;
});
// clang-format on

// clang-format off
EM_JS(int, webFontMeasure, (int pixelSize, int firstCharacter, int characterCount, double* advancesOut, int* ascentOut, int* descentOut, int* xHeightOut), {
    const family = Module.ubiquittyFontFamilyCSS;
    // No family, or no DOM to draw into: a worker or a non-browser host can
    // still run the terminal, and it takes the fallback rather than throwing
    // out of a synchronous call the C++ side cannot catch.
    if (!family || typeof document === 'undefined')
        return 0;
    if (!Module.ubiquittyFontCanvas) {
        Module.ubiquittyFontCanvas = document.createElement('canvas');
        Module.ubiquittyFontContext = Module.ubiquittyFontCanvas.getContext('2d', { alpha : true, willReadFrequently : true });
    }
    const context = Module.ubiquittyFontContext;
    // A context that cannot be read back is not a context this seam can use.
    // Coverage comes from getImageData, so a host whose canvas answers
    // getContext but not that — a stub DOM, a worker shim — must take the
    // fallback here rather than throw out of a synchronous call from wasm that
    // the C++ side has no way to catch. Testing for `document` alone answers a
    // narrower question than the one being asked.
    if (!context || typeof context.getImageData !== 'function' || typeof context.measureText !== 'function')
        return 0;
    // Text pictographs can come from a proportional symbol face, even when the
    // grid font is monospace. Fit the complete outline into Core's text cell,
    // preserving its aspect ratio. This runs only when filling an atlas slot.
    Module.ubiquittyDrawTextPictograph = (text, baseline, width, height, across = 1, down = 1) => {
        text = text.replace(/\uFE0F/g, "\uFE0E");
        if (Array.from(text).length === 1) text += "\uFE0E";
        const ink = context.measureText(text);
        const inkWidth = ink.actualBoundingBoxLeft + ink.actualBoundingBoxRight;
        let fit = inkWidth > 0 ? Math.min(1, width / (inkWidth * across)) : 1;
        const inkHeight = ink.actualBoundingBoxAscent + ink.actualBoundingBoxDescent;
        if (inkHeight > 0) fit = Math.min(fit, height / (inkHeight * down));
        const scaleX = across * fit, scaleY = down * fit;
        const x = (width - inkWidth * scaleX) / 2 + ink.actualBoundingBoxLeft * scaleX;
        const y = Math.max(ink.actualBoundingBoxAscent * scaleY,
            Math.min(baseline, height - ink.actualBoundingBoxDescent * scaleY));
        context.setTransform(scaleX, 0, 0, scaleY, x, y);
        context.fillText(text, 0, 0);
        context.setTransform(1, 0, 0, 1, 0, 0);
    };
    context.font = `${pixelSize}px ${family}`;
    // Read back rather than trust the write. The setter's silence is the failure
    // mode; the getter returns the value in force, so a specification that did
    // not take is visible here and nowhere else.
    if (!context.font.includes(`${pixelSize}px`))
        return 0;
    // A terminal needs one advance for every cell, so every advance in the
    // sample is measured rather than assumed. Which one the cell is, and whether
    // the spread means the browser handed back a proportional face instead of
    // the family asked for, are both read on the C++ side out of Core — this
    // side reports and does not judge.
    for (let i = 0; i < characterCount; ++i) {
        const width = context.measureText(String.fromCodePoint(firstCharacter + i)).width;
        // A width the browser cannot produce is reported absent rather than as a
        // zero-width cell; Core skips it.
        setValue(advancesOut + i * 8, width > 0 ? width : 0, 'double');
    }
    // actualBoundingBox is per-string; fontBoundingBox is the face's own, which
    // is what a cell must be sized to so every glyph in the run shares a baseline.
    const metrics = context.measureText('M');
    const ascent = Math.ceil(metrics.fontBoundingBoxAscent || pixelSize * 0.8);
    const descent = Math.ceil(metrics.fontBoundingBoxDescent || pixelSize * 0.2);
    // `actualBoundingBoxAscent` over a lowercase x is the height of its ink,
    // which is what an x-height is. Reported as zero when the face declines;
    // the stand-in is Core's to choose.
    const xHeight = Math.round(context.measureText('x').actualBoundingBoxAscent || 0);
    setValue(xHeightOut, xHeight > 0 ? xHeight : 0, 'i32');
    setValue(ascentOut, ascent, 'i32');
    setValue(descentOut, descent, 'i32');
    return 1;
});
// clang-format on

// An EM_JS body is a macro argument, so it passes through the C preprocessor
// before it is ever JavaScript: `''` is an empty character constant there and
// warns under -Winvalid-pp-token. Double quotes carry the same meaning to JS
// and none to the preprocessor.
//
// Draws one code point and writes its alpha into `coverageOut`.
//
// Returns 0 when the face has no glyph. A browser answers a missing glyph with
// its notdef box rather than an error, so the check is that the drawn advance
// matches the face's own — a fallback face substituting for a missing glyph
// almost always advances differently, and a notdef box always does.
// clang-format off
EM_JS(int, webFontMeasureGlyph, (const char* familyPtr, int codePoint, double pixelSize, int cssWeight, int isItalic, double* bounds), {
    const context = Module.ubiquittyFontContext;
    if (!context)
        return 0;
    context.font = `${isItalic ? "italic " : ""}${cssWeight} ${pixelSize}px ${UTF8ToString(familyPtr)}`;
    context.textBaseline = 'alphabetic';
    context.textAlign = 'left';
    const metrics = context.measureText(String.fromCodePoint(codePoint));
    HEAPF64[bounds >> 3] = -metrics.actualBoundingBoxDescent;
    HEAPF64[(bounds >> 3) + 1] = metrics.actualBoundingBoxAscent + metrics.actualBoundingBoxDescent;
    HEAPF64[(bounds >> 3) + 2] = metrics.actualBoundingBoxLeft + metrics.actualBoundingBoxRight;
    return Number.isFinite(metrics.actualBoundingBoxAscent) ? 1 : 0;
});

EM_JS(int, webFontDrawGlyph, (const char* familyPtr, int codePoint, double pixelSize, double horizontalScale, double verticalScale, int cssWeight, int isItalic, double penX, double baseline, int slotWidth, int slotHeight, int isTextPictograph, std::uint8_t* coverageOut), {
    const family = UTF8ToString(familyPtr);
    if (!family || !Module.ubiquittyFontContext)
        return 0;
    const canvas = Module.ubiquittyFontCanvas;
    const context = Module.ubiquittyFontContext;
    if (canvas.width < slotWidth || canvas.height < slotHeight) {
        canvas.width = Math.max(canvas.width, slotWidth);
        canvas.height = Math.max(canvas.height, slotHeight);
    }
    // The family the caller routed to, drawn with the weight the pen asked for so
    // bold text is the face's own rather than a synthetic smear.
    //
    // The caller decides which family this is — `Rendering::Font::FontFallbackPolicy`
    // picked it and `WebFontInventory` probed it. A fallback chain written here
    // would decide the same question a second time and in a different order, and
    // it would hide the answer the policy needs: a stack resolved by the browser
    // reports that something drew, never which family drew it.
    //
    // This is the only place style and weight are set. `WebFontInventory` answers
    // one family handle for every style — a browser selects a member by CSS
    // rather than by family — so a face that never reaches this line is a face
    // the page never draws, and bold and italic cells come back upright and
    // regular while every route and every atlas key still distinguishes them.
    //
    // The weight is a CSS weight the caller resolved through Core, not the SGR
    // 1:n value the rest of the seam carries. Those two share no range: every
    // SGR weight is below 8, so a comparison against 700 here answers false for
    // all of them and for bold.
    context.font = `${isItalic ? "italic " : ""}${cssWeight} ${pixelSize}px ${family}`;
    // An unparseable specification leaves the previous face in force, and the
    // setter says nothing. The getter reports what is actually set.
    const drawnSize = context.font.match(/(?:^| )([0-9.]+)px /);
    // Gecko serializes the computed size on its 1/60 CSS-pixel grid.
    if (!drawnSize || Math.abs(Number(drawnSize[1]) - pixelSize) > 1.0 / 60)
        return 0;
    // Every property this draw depends on is set here, none inherited. The 2D
    // context is created once and shared by every raster on this seam, so a
    // property another entry point set persists into this one: the colour path
    // draws centred, and a glyph rasterised after an emoji inherited that and
    // landed half an advance to the left — in the ATLAS, so it stayed wrong for
    // as long as the slot did.
    context.textBaseline = 'alphabetic';
    context.textAlign = 'left';
    context.clearRect(0, 0, slotWidth, slotHeight);
    context.fillStyle = '#fff';
    const text = String.fromCodePoint(codePoint);
    if (!isTextPictograph && !context.measureText(text).width && codePoint !== 32)
        return 0;
    // A sized master's stretch across is the outline's, applied before the
    // fill rasterises it, never a resample of the drawn pixels. The pen is in
    // the unstretched space, so the stretch carries it too.
    if (isTextPictograph) {
        Module.ubiquittyDrawTextPictograph(text, baseline, slotWidth, slotHeight, horizontalScale, verticalScale);
    } else {
        context.setTransform(horizontalScale, 0, 0, verticalScale, 0, 0);
        context.fillText(text, penX, baseline / verticalScale);
        context.setTransform(1, 0, 0, 1, 0, 0);
    }
    const pixels = context.getImageData(0, 0, slotWidth, slotHeight).data;
    // Alpha only: the fill is opaque white, so alpha is the coverage.
    for (let i = 0, at = coverageOut; i < slotWidth * slotHeight; ++i, ++at)
        HEAPU8[at] = pixels[i * 4 + 3];
    return 1;
});
// clang-format on

// Rasterize a grapheme in one shaping operation; combining marks have no
// independent advance and must be placed by the face against their base.
// clang-format off
EM_JS(int, webFontDrawCluster, (const char* familyPtr, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, int isItalic, int baseline, int slotWidth, int slotHeight, int isTextPictograph, std::uint8_t* coverageOut), {
    const family = UTF8ToString(familyPtr);
    const canvas = Module.ubiquittyFontCanvas;
    const context = Module.ubiquittyFontContext;
    if (!family || !context || count <= 0 || slotWidth <= 0 || slotHeight <= 0)
        return 0;
    if (canvas.width < slotWidth || canvas.height < slotHeight) {
        canvas.width = Math.max(canvas.width, slotWidth);
        canvas.height = Math.max(canvas.height, slotHeight);
    }
    let text = "";
    for (let index = 0; index < count; ++index)
        text += String.fromCodePoint(HEAPU32[(codePoints >> 2) + index]);
    context.setTransform(1, 0, 0, 1, 0, 0);
    context.font = `${isItalic ? "italic " : ""}${cssWeight} ${pixelSize}px ${family}`;
    context.textBaseline = "alphabetic";
    context.textAlign = "left";
    context.clearRect(0, 0, slotWidth, slotHeight);
    context.fillStyle = "#fff";
    const base = HEAPU32[codePoints >> 2];
    const cursive = (base >= 0xFB50 && base <= 0xFDFF) || (base >= 0xFE70 && base <= 0xFEFC);
    if (isTextPictograph) {
        Module.ubiquittyDrawTextPictograph(text, baseline, slotWidth, slotHeight);
    } else {
        const advance = context.measureText(text).width;
        if (cursive && advance > 0) context.scale(slotWidth / advance, 1);
        context.fillText(text, 0, baseline);
        context.setTransform(1, 0, 0, 1, 0, 0);
    }
    const pixels = context.getImageData(0, 0, slotWidth, slotHeight).data;
    for (let index = 0; index < slotWidth * slotHeight; ++index)
        HEAPU8[coverageOut + index] = pixels[index * 4 + 3];
    return 1;
});
// clang-format on

// Measures a proportional run and reports each code point's natural advance.
//
// The browser has no glyph indices to give, so the seam's `glyph` field carries
// the CODE POINT for this rasterizer — `rasteriseProportionalRun` below is the
// only reader, and it draws by code point. That is what the seam's own wording
// licenses: a face-local index is meaningless outside the face that shaped it,
// and for a canvas the face's index space is Unicode.
//
// No substitution, and the count therefore equals the input's. Canvas exposes
// no shaping API — `measureText` reports a run's width and nothing about the
// glyphs inside it — so a ligature the face carries is drawn by `fillText`
// across the whole run and measured across it, but cannot be reported here as
// one glyph over two clusters. Advances are per code point and sum to the run.
// clang-format off
EM_JS(int, webFontMeasureProportional, (const char* familyPtr, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, double* advancesOut), {
    const family = UTF8ToString(familyPtr);
    if (!family || !Module.ubiquittyFontContext || count <= 0)
        return 0;
    const context = Module.ubiquittyFontContext;
    context.font = `${cssWeight} ${pixelSize}px ${family}`;
    if (!context.font.includes(`${pixelSize}px`))
        return 0;
    context.textBaseline = 'alphabetic';
    context.textAlign = 'left';
    // Measured one code point at a time rather than cumulatively: a cumulative
    // measure differences two rounded widths, and the error accumulates across
    // a long run in the direction the browser happens to round.
    for (let i = 0; i < count; ++i) {
        const codePoint = HEAPU32[(codePoints >> 2) + i];
        const width = context.measureText(String.fromCodePoint(codePoint)).width;
        HEAPF64[(advancesOut >> 3) + i] = width;
    }
    return count;
});
// clang-format on

// Draws a placed proportional run into a coverage strip.
//
// One `fillText` per glyph at the offset the caller placed it, rather than one
// over the whole string: the caller owns the pen, and a single call would place
// the text by the browser's own advances — the same numbers, but applied where
// the browser decided rather than where the layout did, which is a different
// picture the moment a cell boundary rounds.
// clang-format off
EM_JS(int, webFontDrawProportional, (const char* familyPtr, const std::uint32_t* codePoints, const double* offsetsX, const double* offsetsY, int count, int pixelSize, double horizontalScale, int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut), {
    const family = UTF8ToString(familyPtr);
    if (!family || !Module.ubiquittyFontContext || count <= 0 || stripWidth <= 0 || stripHeight <= 0)
        return 0;
    const canvas = Module.ubiquittyFontCanvas;
    const context = Module.ubiquittyFontContext;
    if (canvas.width < stripWidth || canvas.height < stripHeight) {
        canvas.width = Math.max(canvas.width, stripWidth);
        canvas.height = Math.max(canvas.height, stripHeight);
    }
    context.font = `${cssWeight} ${pixelSize}px ${family}`;
    if (!context.font.includes(`${pixelSize}px`))
        return 0;
    // Every property the draw depends on is set here, none inherited: this
    // context is shared with the colour path, which draws centred.
    context.textBaseline = 'alphabetic';
    context.textAlign = 'left';
    context.clearRect(0, 0, stripWidth, stripHeight);
    context.fillStyle = '#fff';
    // A run doubled across is the face's outlines stretched about the
    // strip's left edge; the pens are the layout's, so they are divided back.
    const across = horizontalScale > 0 ? horizontalScale : 1;
    context.setTransform(across, 0, 0, 1, 0, 0);
    for (let i = 0; i < count; ++i) {
        const codePoint = HEAPU32[(codePoints >> 2) + i];
        const x = HEAPF64[(offsetsX >> 3) + i] / across;
        // y is up in the seam and down on a canvas, so the offset subtracts.
        const y = baseline - HEAPF64[(offsetsY >> 3) + i];
        context.fillText(String.fromCodePoint(codePoint), x, y);
    }
    context.setTransform(1, 0, 0, 1, 0, 0);
    const pixels = context.getImageData(0, 0, stripWidth, stripHeight).data;
    for (let i = 0, at = coverageOut; i < stripWidth * stripHeight; ++i, ++at)
        HEAPU8[at] = pixels[i * 4 + 3];
    return 1;
});
// clang-format on

// Shapes a run of grid text by drawing it, and reports each code point's
// advance and whether the face drew it in another form.
//
// The run is drawn as one string in the top band, where the browser shapes it
// with the registered face's features, and its characters one at a time in the
// bottom band at the pens the run has without substitution, which is the
// per-cell picture. Each column belongs to the cell whose advance holds its
// middle, and a cell is reported when any of its columns differs between the
// bands by more than rounding: a substituted form moves whole strokes.
//
// The pens are the characters' own advances, summed. A programming face keeps
// one glyph per cell whatever it substitutes, so the run's pens are its
// characters' pens and the bands agree column for column wherever the face
// changed nothing. Kerning is off in both bands, because an unshaped run kerns
// nothing and a kerned pair would read as a substitution.
// clang-format off
EM_JS(int, webFontShapeRun, (const char* familyPtr, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, int bandHeight, int baseline, double* advancesOut, std::uint8_t* contextualFormsOut), {
    const family = UTF8ToString(familyPtr);
    const canvas = Module.ubiquittyFontCanvas;
    const context = Module.ubiquittyFontContext;
    if (!family || !context || count <= 0 || bandHeight <= 0)
        return 0;
    // Stated again after a resize, because sizing a canvas resets its
    // context's state.
    const prepare = () => {
        context.setTransform(1, 0, 0, 1, 0, 0);
        context.font = `${cssWeight} ${pixelSize}px ${family}`;
        context.textBaseline = 'alphabetic';
        context.textAlign = 'left';
        if ('fontKerning' in context)
            context.fontKerning = 'none';
    };
    prepare();
    if (!context.font.includes(`${pixelSize}px`))
        return 0;
    const characters = [];
    const pens = new Float64Array(count + 1);
    for (let i = 0; i < count; ++i) {
        characters.push(String.fromCodePoint(HEAPU32[(codePoints >> 2) + i]));
        const advance = context.measureText(characters[i]).width;
        HEAPF64[(advancesOut >> 3) + i] = advance;
        HEAPU8[contextualFormsOut + i] = 0;
        pens[i + 1] = pens[i] + advance;
    }
    if (count === 1)
        return 1;
    // An em either side holds the ink a glyph throws past its advance.
    const pad = pixelSize;
    const width = Math.ceil(pens[count] + 2 * pad);
    const height = 2 * bandHeight;
    if (canvas.width < width || canvas.height < height) {
        canvas.width = Math.max(canvas.width, width);
        canvas.height = Math.max(canvas.height, height);
        prepare();
    }
    context.clearRect(0, 0, width, height);
    context.fillStyle = '#fff';
    // Each band clipped to itself, so a descender in one is not read as ink
    // in the other.
    const inBand = (top, draw) => {
        context.save();
        context.beginPath();
        context.rect(0, top, width, bandHeight);
        context.clip();
        draw();
        context.restore();
    };
    inBand(0, () => context.fillText(characters.join(""), pad, baseline));
    inBand(bandHeight, () => {
        for (let i = 0; i < count; ++i)
            context.fillText(characters[i], pad + pens[i], bandHeight + baseline);
    });
    const pixels = context.getImageData(0, 0, width, height).data;
    const tolerance = 16;
    const isolatedOffset = bandHeight * width * 4;
    let cell = 0;
    for (let x = 0; x < width; ++x) {
        const middle = x + 0.5 - pad;
        while (cell + 1 < count && middle >= pens[cell + 1])
            ++cell;
        if (HEAPU8[contextualFormsOut + cell])
            continue;
        for (let y = 0; y < bandHeight; ++y) {
            const at = (y * width + x) * 4 + 3;
            if (Math.abs(pixels[at] - pixels[at + isolatedOffset]) > tolerance) {
                HEAPU8[contextualFormsOut + cell] = 1;
                break;
            }
        }
    }
    return count;
});
// clang-format on

// Draws a shaped run into a coverage strip, each glyph at the pen the caller
// placed it on.
//
// The whole run is drawn once per glyph rather than once per strip, so the face
// draws every glyph in the context it was shaped in: each draw is moved so its
// glyph lands on its placed pen, and clipped to the columns between that pen and
// the next. Consecutive glyphs whose placed pens sit the same distance from
// their natural ones share a draw, which is every glyph of a face whose advance
// is the cell's. The outermost draws keep the strip's edges, where a run's end
// glyphs throw their overhang.
// clang-format off
EM_JS(int, webFontDrawShapedRun, (const char* familyPtr, const std::uint32_t* codePoints, const double* naturalPensX, const double* placedPensX, int count, int pixelSize, int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut), {
    const family = UTF8ToString(familyPtr);
    const canvas = Module.ubiquittyFontCanvas;
    const context = Module.ubiquittyFontContext;
    if (!family || !context || count <= 0 || stripWidth <= 0 || stripHeight <= 0)
        return 0;
    if (canvas.width < stripWidth || canvas.height < stripHeight) {
        canvas.width = Math.max(canvas.width, stripWidth);
        canvas.height = Math.max(canvas.height, stripHeight);
    }
    context.setTransform(1, 0, 0, 1, 0, 0);
    context.font = `${cssWeight} ${pixelSize}px ${family}`;
    if (!context.font.includes(`${pixelSize}px`))
        return 0;
    context.textBaseline = 'alphabetic';
    context.textAlign = 'left';
    // Unkerned, as the shaping measured the natural pens.
    if ('fontKerning' in context)
        context.fontKerning = 'none';
    context.clearRect(0, 0, stripWidth, stripHeight);
    context.fillStyle = '#fff';
    let text = "";
    for (let i = 0; i < count; ++i)
        text += String.fromCodePoint(HEAPU32[(codePoints >> 2) + i]);
    const natural = (i) => HEAPF64[(naturalPensX >> 3) + i];
    const placed = (i) => HEAPF64[(placedPensX >> 3) + i];
    for (let first = 0; first < count;) {
        const shift = placed(first) - natural(first);
        let last = first;
        while (last + 1 < count && placed(last + 1) - natural(last + 1) === shift)
            ++last;
        const left = first === 0 ? 0 : placed(first);
        const right = last === count - 1 ? stripWidth : placed(last + 1);
        if (right > left) {
            context.save();
            context.beginPath();
            context.rect(left, 0, right - left, stripHeight);
            context.clip();
            context.fillText(text, shift, baseline);
            context.restore();
        }
        first = last + 1;
    }
    const pixels = context.getImageData(0, 0, stripWidth, stripHeight).data;
    for (let i = 0, at = coverageOut; i < stripWidth * stripHeight; ++i, ++at)
        HEAPU8[at] = pixels[i * 4 + 3];
    return 1;
});
// clang-format on

// Draws a cluster in its own colours and writes RGBA into `pixelsOut`.
//
// The fill style is set and then ignored: a colour font's own layers carry their
// colours, which is what makes this different from the coverage path rather than
// a wider read of it. A face with no colour for the cluster draws in the fill
// instead, and that is the case the alpha scan below rejects — a monochrome
// emoji on the colour sheet would be the same grey glyph the mono path already
// produces, taking a slot to do it.
//
// The glyph is centred in the square slot and drawn at the slot's own size, not
// the cell's: the sheet's slot is the cell HEIGHT on both axes, so an emoji sized
// to the cell width would sit in the corner of its box.
// clang-format off
EM_JS(int, webFontDrawColorCluster, (const char* familyPtr, const std::uint32_t* codePoints, int count, int slotInPixels, std::uint8_t* pixelsOut), {
    const family = UTF8ToString(familyPtr);
    if (!family || !Module.ubiquittyFontContext || count <= 0 || slotInPixels <= 0)
        return 0;
    const canvas = Module.ubiquittyFontCanvas;
    const context = Module.ubiquittyFontContext;
    if (canvas.width < slotInPixels || canvas.height < slotInPixels) {
        canvas.width = Math.max(canvas.width, slotInPixels);
        canvas.height = Math.max(canvas.height, slotInPixels);
    }
    let text = "";
    for (let i = 0; i < count; ++i)
        text += String.fromCodePoint(HEAPU32[(codePoints >> 2) + i]);
    // The family the caller routed to. `cascadeForRun` tries the emoji stack
    // ahead of the terminal face, because a face carrying a monochrome glyph for
    // the lead code point would otherwise win and the colour would never be
    // reached.
    context.font = `${Math.round(slotInPixels * 0.86)}px ${family}`;
    if (!context.font.includes("px"))
        return 0;
    // Centred in both axes, and stated in full for the reason above rather than
    // relying on what the previous caller left behind.
    context.textBaseline = 'middle';
    context.textAlign = 'center';
    context.clearRect(0, 0, slotInPixels, slotInPixels);
    context.fillStyle = '#fff';
    if (!context.measureText(text).width)
        return 0;
    context.fillText(text, slotInPixels / 2, slotInPixels / 2);
    const pixels = context.getImageData(0, 0, slotInPixels, slotInPixels).data;
    // White is what a face with no colour for this cluster leaves, because that
    // is the fill. Any pixel that is opaque and not white is colour the face
    // supplied, so the scan asks for one and declines otherwise — a decline sends
    // the cluster back to the mono path, which is where a monochrome glyph
    // belongs.
    let hasColor = false;
    for (let i = 0; i < slotInPixels * slotInPixels; ++i) {
        const at = i * 4;
        if (pixels[at + 3] > 8 && (pixels[at] < 248 || pixels[at + 1] < 248 || pixels[at + 2] < 248)) {
            hasColor = true;
            break;
        }
    }
    if (!hasColor)
        return 0;
    HEAPU8.set(pixels, pixelsOut);
    return 1;
});
// clang-format on

#else

// Off-target: no host text engine, so every glyph goes to the fallback. This
// keeps the file compiling for the tests that drive the frontend natively.
#if UBIQUITTY_ENABLE_TEST_HOOKS
// Null hooks keep the absent-host default; an installed set is the stand-in
// engine the ForTest seam in the header describes.
ForTest::WebFontHost s_webFontHost {};
int webFontMeasureGlyph(const char*, int, double, int, int, double*) { return 0; }
int webFontPrimaryFamily(char* familyOut, int capacity) { return s_webFontHost.primaryFamily ? s_webFontHost.primaryFamily(familyOut, capacity) : 0; }
int webFontMeasure(int pixelSize, int firstCharacter, int characterCount, double* advances, int* ascent, int* descent, int* xHeight)
{
    return s_webFontHost.measure ? s_webFontHost.measure(pixelSize, firstCharacter, characterCount, advances, ascent, descent, xHeight) : 0;
}
int webFontDrawGlyph(const char* family, int codePoint, double pixelSize, double horizontalScale, double verticalScale, int cssWeight, int isItalic, double penX, double baseline, int slotWidth, int slotHeight, int isTextPictograph, std::uint8_t* coverageOut)
{
    return s_webFontHost.drawGlyph ? s_webFontHost.drawGlyph(family, codePoint, pixelSize, horizontalScale, verticalScale, cssWeight, isItalic, penX, baseline, slotWidth, slotHeight, isTextPictograph, coverageOut) : 0;
}
int webFontDrawCluster(const char* family, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, int isItalic, int baseline, int slotWidth, int slotHeight, int isTextPictograph, std::uint8_t* coverageOut)
{
    return s_webFontHost.drawCluster ? s_webFontHost.drawCluster(family, codePoints, count, pixelSize, cssWeight, isItalic, baseline, slotWidth, slotHeight, isTextPictograph, coverageOut) : 0;
}
int webFontDrawColorCluster(const char* family, const std::uint32_t* codePoints, int count, int slotInPixels, std::uint8_t* pixelsOut)
{
    return s_webFontHost.drawColorCluster ? s_webFontHost.drawColorCluster(family, codePoints, count, slotInPixels, pixelsOut) : 0;
}
int webFontMeasureProportional(const char* family, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, double* advancesOut)
{
    return s_webFontHost.measureProportional ? s_webFontHost.measureProportional(family, codePoints, count, pixelSize, cssWeight, advancesOut) : 0;
}
int webFontDrawProportional(const char* family, const std::uint32_t* codePoints, const double* offsetsX, const double* offsetsY, int count, int pixelSize, double horizontalScale, int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut)
{
    return s_webFontHost.drawProportional
        ? s_webFontHost.drawProportional(family, codePoints, offsetsX, offsetsY, count, pixelSize, horizontalScale, cssWeight, baseline, stripWidth, stripHeight, coverageOut)
        : 0;
}
int webFontShapeRun(const char* family, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, int bandHeight, int baseline, double* advancesOut, std::uint8_t* contextualFormsOut)
{
    return s_webFontHost.shapeRun
        ? s_webFontHost.shapeRun(family, codePoints, count, pixelSize, cssWeight, bandHeight, baseline, advancesOut, contextualFormsOut)
        : 0;
}
int webFontDrawShapedRun(const char* family, const std::uint32_t* codePoints, const double* naturalPensX, const double* placedPensX, int count, int pixelSize, int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut)
{
    return s_webFontHost.drawShapedRun
        ? s_webFontHost.drawShapedRun(family, codePoints, naturalPensX, placedPensX, count, pixelSize, cssWeight, baseline, stripWidth, stripHeight, coverageOut)
        : 0;
}
#else
int webFontPrimaryFamily(char*, int) { return 0; }
int webFontMeasureGlyph(const char*, int, double, int, int, double*) { return 0; }
int webFontMeasure(int, int, int, double*, int*, int*, int*) { return 0; }
int webFontDrawGlyph(const char*, int, double, double, double, int, int, double, double, int, int, int, std::uint8_t*) { return 0; }
int webFontDrawCluster(const char*, const std::uint32_t*, int, int, int, int, int, int, int, int, std::uint8_t*) { return 0; }
int webFontDrawColorCluster(const char*, const std::uint32_t*, int, int, std::uint8_t*) { return 0; }
int webFontMeasureProportional(const char*, const std::uint32_t*, int, int, int, double*) { return 0; }
int webFontDrawProportional(const char*, const std::uint32_t*, const double*, const double*, int, int, double, int, int, int, int, std::uint8_t*) { return 0; }
int webFontShapeRun(const char*, const std::uint32_t*, int, int, int, int, int, double*, std::uint8_t*) { return 0; }
int webFontDrawShapedRun(const char*, const std::uint32_t*, const double*, const double*, int, int, int, int, int, int, std::uint8_t*) { return 0; }
#endif

#endif

/// The configured family, quoted for CSS.
///
/// - Returns: The family, empty when the embedder installed none.
std::string primaryFamily()
{
    // A CSS font-family list, not a path: 256 bytes is far past any real family
    // name, and a longer one takes the empty answer rather than a truncated
    // specification that would name a different face.
    std::array<char, 256> buffer {};
    const int length = webFontPrimaryFamily(buffer.data(), static_cast<int>(buffer.size()));
    if (length <= 0)
        return {};
    return { buffer.data(), static_cast<std::size_t>(length) };
}

}

WebFontRasterizer::WebFontRasterizer(GlyphRasterizer& fallback, int pixelSize, int lineSpacingInPixels, int trackingInPixels, const Rendering::Font::FontFallbackPreferences& preferences, int deviceScale, std::string fontVariations, Rendering::Font::WeightSettings weights, RunSubstitution runSubstitution)
    : m_fallback(fallback)
    , m_inventory(primaryFamily())
    , m_preferences(preferences)
    , m_pixelSize(pixelSize > 0 ? pixelSize : 1)
    , m_deviceScale(deviceScale > 0 ? deviceScale : 1)
    , m_userAxes(Rendering::parseFontVariationSpecification(fontVariations))
    , m_weights(weights)
    , m_runSubstitution(runSubstitution)
{
    int ascent = 0;
    int descent = 0;
    int xHeight = 0;
    std::array<double, Rendering::FontMetrics::probeCharacterCount> sampled {};
    const bool didMeasure = webFontMeasure(m_pixelSize, static_cast<int>(Rendering::FontMetrics::firstProbeCharacter),
                                Rendering::FontMetrics::probeCharacterCount, sampled.data(), &ascent, &descent, &xHeight)
        != 0;
    const Rendering::FontMetrics::FacePitch pitch = Rendering::FontMetrics::facePitch(sampled);
    const int advance = static_cast<int>(std::lround(Rendering::FontMetrics::cellAdvance(pitch, sampled)));
    // A browser given a family it does not have answers with its proportional
    // default and reports success, so the measurement alone cannot tell the two
    // apart. `validateFamily` can: it draws a sample in the family and in the
    // fallback and compares, and answers invalid when they match. Asking it is
    // what lets the advances be read as a measurement rather than as a
    // substitution test — a face whose glyphs are genuinely uneven is a face the
    // user chose, and it gets a grid as wide as its widest glyph rather than a
    // refusal.
    //
    // `primaryFont` is the wrong question here even though it names the right
    // family: it interns unconditionally, so it answers valid for a family the
    // host does not have.
    const std::string family = primaryFamily();
    const Rendering::Font::FontHandle resolved = family.empty()
        ? Rendering::Font::FontHandle {}
        : m_inventory.validateFamily(Rendering::Font::FontFamilyRequest { family });
    m_isAvailable = didMeasure && advance > 0 && resolved.isValid();
    m_facePitch = pitch;
    m_primaryFamily = family;
    if (!m_isAvailable) {
        m_metrics = m_fallback.cellMetrics();
        m_overhang = m_fallback.glyphOverhang();
        m_face = m_fallback.faceMetrics();
        return;
    }

    const Rendering::CellLayout layout
        = Rendering::cellLayout(static_cast<float>(ascent), static_cast<float>(descent), lineSpacingInPixels);
    m_metrics = Rendering::CellMetrics {};
    // The pitch, tracking folded in by Core's rule, as the FreeType and
    // CoreText arms fold it; the glyph keeps the face's own advance.
    m_metrics.cellWidth = static_cast<float>(Rendering::FontMetrics::trackedCellAdvance(advance, trackingInPixels));
    m_metrics.xHeight = Rendering::xHeightForStrike(static_cast<float>(xHeight), static_cast<float>(ascent));
    m_metrics.cellHeight = layout.cellHeight;
    m_metrics.baselineFromTop = layout.baselineFromTop;
    m_face.fontSize = m_pixelSize;
    m_face.ascent = static_cast<float>(ascent);
    m_face.descent = static_cast<float>(descent);
    m_face.lineGapTopInPixels = layout.lineGapTop;
    // The face rule policy (RuleGeometry.h) with what the browser can tell
    // this arm: the descent, which places the rule; no underline weight
    // reaches a canvas, so the stroke keeps the size-only rule.
    Rendering::RuleFaceMetrics faceRules;
    faceRules.descent = static_cast<float>(descent);
    const Rendering::RuleGeometry rules = Rendering::ruleGeometry(static_cast<float>(m_pixelSize), static_cast<float>(m_deviceScale), faceRules);
    m_metrics.underlineDrop = rules.underlineDrop;
    m_metrics.underlineThickness = rules.underlineThickness;
    m_metrics.underlineCurlyThickness = rules.curlyThickness;
    m_metrics.strikeThickness = rules.strikeThickness;
    // A straight rule rises off the baseline by half a device pixel per 12 of
    // type, which is what macOS draws (FontGeometry.swift: 0.5 * deviceScale *
    // fontSize / 12, with its font size in points and this one already in device
    // pixels, so the two scale terms cancel). Leaving it at zero draws the rule
    // ON the baseline while the same text on the Unifont fallback lifts — within
    // one frontend, decided by whether the page's font loaded.
    m_metrics.underlineStrokeLift = static_cast<float>(m_pixelSize) / 24.0f;
}

namespace {

// The CSS weight a cell draws at.
//
// A browser has no axis to place by hand: naming the weight on the 2D context
// is how a variable face is instanced and how a static family's member is
// picked, and the page's `@font-face` declares the range that makes the first
// of those possible. Which number to name is Core's rule (`weightForFace`), not
// this file's — the same one every other arm applies — so a run drawn bold here
// and regular there cannot happen.
int cssWeightFor(Rendering::FontFace face, std::uint32_t sgrWeight, const Rendering::FontVariationSettings& userAxes, Rendering::Font::WeightSettings weights)
{
    const std::uint8_t sgr = static_cast<std::uint8_t>(sgrWeight > 7 ? 0 : sgrWeight);
    for (const Rendering::FontVariationSetting& axis : userAxes) {
        if (axis.tag == "wght") {
            weights.uprightVariation = axis.value;
            break;
        }
    }
    // The browser drops an out-of-range shorthand, including its family.
    const double weight = Rendering::Font::weightForFace(face, sgr, weights);
    return static_cast<int>(std::clamp(weight, 1.0, 1000.0));
}

// The longest run `shapeTextRun` draws: past every run the strip sheet asks for
// — a chunk, its context on both sides and a flanking space at each end — and
// past the participation probe. A longer one is refused rather than drawn across
// a canvas as wide as it.
constexpr std::size_t maxShapedRunLength = 64;
static_assert(static_cast<std::size_t>(Rendering::ligatureMaxCells + 2 * Rendering::ligatureContextCells + 2) <= maxShapedRunLength);
static_assert(std::char_traits<char>::length(Rendering::ligatureHealingProbe) <= maxShapedRunLength);

} // namespace

WebFontRasterizer::RunSubstitution WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures ligatures, const std::string& featureSpecification)
{
    if (ligatures == Rendering::Ligatures::Enabled)
        return RunSubstitution::Possible;
    // Every entry of the suppression is zero, and the reader's specification
    // follows it naming each tag once, at its last value: an entry that is not
    // zero is a feature the descriptor turns on over the suppression.
    const Rendering::FontFeatureSettings resolved = Rendering::resolveFontFeatures(ligatures, featureSpecification);
    const bool hasEnabledFeature = std::ranges::any_of(resolved, [](const Rendering::FontFeatureSetting& setting) { return setting.value != 0; });
    return hasEnabledFeature ? RunSubstitution::Possible : RunSubstitution::Suppressed;
}

int WebFontRasterizer::shapeTextRun(std::span<const std::uint32_t> codePoints, std::uint32_t weight, std::span<ShapedGlyph> glyphsOut)
{
    const std::size_t count = codePoints.size();
    if (!hasLigatureShaping() || m_primaryFamily.empty() || count == 0 || count > maxShapedRunLength || glyphsOut.size() < count)
        return 0;
    // The code point is the glyph's name here and the browser is handed it as
    // text, so a value that is no scalar has neither.
    if (!std::ranges::all_of(codePoints, [](std::uint32_t codePoint) { return codePoint != 0 && Unicode::isScalarValue(codePoint); }))
        return 0;
    // Upright, as the FreeType arm shapes: the seam carries a weight and no
    // face, so the weight reaches the face through Core's rule for the regular
    // one.
    const int cssWeight = cssWeightFor(Rendering::FontFace::Regular, weight, m_userAxes, m_weights);
    const int runLength = static_cast<int>(count);

    if (count == 1) {
        // The isolated mapping itself: drawn alone a character is its own
        // form, so there is nothing to compare, and the run a strip draws from
        // stays the one shaped before it.
        double advance = 0.0;
        if (webFontMeasureProportional(m_primaryFamily.c_str(), codePoints.data(), 1, m_pixelSize, cssWeight, &advance) != 1)
            return 0;
        ShapedGlyph& glyph = glyphsOut[0];
        glyph = {};
        glyph.glyph = codePoints[0];
        glyph.advanceInPixels = static_cast<int>(std::lround(advance));
        return 1;
    }

    m_shapedRunAdvances.assign(count, 0.0);
    m_shapedRunContextualForms.assign(count, 0);
    // The comparison reads the cell box, on the mono slot's baseline: ink a
    // strip cannot show is not a difference worth a strip.
    const int bandHeight = std::max(1, static_cast<int>(m_metrics.cellHeight));
    const int baseline = std::min(static_cast<int>(m_metrics.baselineFromTop), bandHeight);
    if (webFontShapeRun(m_primaryFamily.c_str(), codePoints.data(), runLength, m_pixelSize, cssWeight, bandHeight, baseline,
            m_shapedRunAdvances.data(), m_shapedRunContextualForms.data())
        != runLength) {
        m_shapedRun.clear();
        return 0;
    }
    m_shapedRun.assign(codePoints.begin(), codePoints.end());
    m_shapedRunCSSWeight = cssWeight;
    for (std::size_t index = 0; index < count; ++index) {
        ShapedGlyph& glyph = glyphsOut[index];
        glyph = {};
        glyph.glyph = codePoints[index] | (m_shapedRunContextualForms[index] != 0 ? contextualFormBit : 0u);
        glyph.advanceInPixels = static_cast<int>(std::lround(m_shapedRunAdvances[index]));
        glyph.cluster = static_cast<int>(index);
    }
    return runLength;
}

bool WebFontRasterizer::rasteriseShapedRun(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut)
{
    if (!hasLigatureShaping() || glyphs.empty() || glyphs.size() != m_shapedRun.size() || stripWidthInPixels <= 0 || stripHeightInPixels <= 0)
        return false;
    // The dimensions and the buffer are two statements of one fact, and only
    // this side can compare them.
    if (coverageOut.size() != static_cast<std::size_t>(stripWidthInPixels) * static_cast<std::size_t>(stripHeightInPixels))
        return false;

    m_shapedRunNaturalPensX.resize(glyphs.size());
    m_shapedRunPlacedPensX.resize(glyphs.size());
    // The seam's pen walk, as the FreeType arm takes it: a glyph stands where
    // its predecessors' advances left the pen, moved by its own offset. The
    // natural pen is where the browser's own shaping of the run puts it.
    double naturalPen = 0.0;
    std::int64_t pen = 0;
    for (std::size_t index = 0; index < glyphs.size(); ++index) {
        const ShapedGlyph& glyph = glyphs[index];
        if (glyph.cluster != static_cast<int>(index) || (glyph.glyph & ~contextualFormBit) != m_shapedRun[index])
            return false;
        m_shapedRunNaturalPensX[index] = naturalPen;
        m_shapedRunPlacedPensX[index] = static_cast<double>(pen + glyph.offsetXInPixels);
        naturalPen += m_shapedRunAdvances[index];
        pen += glyph.advanceInPixels;
    }

    // The mono slot's baseline, clamped the way `rasterizeGlyph` clamps it,
    // so a cell the face left alone draws in the strip what it draws alone.
    const int baseline = std::min(static_cast<int>(m_metrics.baselineFromTop), stripHeightInPixels);
    return webFontDrawShapedRun(m_primaryFamily.c_str(), m_shapedRun.data(), m_shapedRunNaturalPensX.data(), m_shapedRunPlacedPensX.data(),
               static_cast<int>(glyphs.size()), m_pixelSize, m_shapedRunCSSWeight, baseline, stripWidthInPixels, stripHeightInPixels, coverageOut.data())
        != 0;
}

Rendering::Font::FontStyle WebFontRasterizer::styleForFace(Rendering::FontFace face)
{
    switch (face) {
    case Rendering::FontFace::Bold:
        return Rendering::Font::FontStyle::Bold;
    case Rendering::FontFace::Italic:
        return Rendering::Font::FontStyle::Italic;
    case Rendering::FontFace::BoldItalic:
        return Rendering::Font::FontStyle::BoldItalic;
    case Rendering::FontFace::Regular:
        break;
    }
    return Rendering::Font::FontStyle::Regular;
}

int WebFontRasterizer::shapeProportionalRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face,
    std::span<Ubiquitty::ProportionalShapedGlyph> glyphsOut)
{
    if (!m_isAvailable || codePoints.empty() || glyphsOut.size() < codePoints.size())
        return 0;

    const char* proportionalFamily = m_proportionalFamily.c_str();
    const int cssWeight = face == Rendering::FontFace::Bold || face == Rendering::FontFace::BoldItalic ? 700 : 400;

    m_proportionalAdvances.assign(codePoints.size(), 0.0);
    if (webFontMeasureProportional(proportionalFamily, codePoints.data(), static_cast<int>(codePoints.size()), m_proportionalPixelSize > 0 ? m_proportionalPixelSize : m_pixelSize,
            cssWeight, m_proportionalAdvances.data())
        != static_cast<int>(codePoints.size()))
        return 0;

    // The pen is the caller's, so only the advance travels: the seam places
    // glyphs from offsets the layout owns, and a pen accumulated here would be
    // a second placement competing with it.
    for (std::size_t index = 0; index < codePoints.size(); ++index) {
        Ubiquitty::ProportionalShapedGlyph& glyph = glyphsOut[index];
        glyph = {};
        // The code point stands in for a face-local index, which a canvas has
        // none of. `rasteriseProportionalRun` is the only reader.
        glyph.glyph = codePoints[index];
        glyph.advanceInPixels = static_cast<float>(m_proportionalAdvances[index]);
        glyph.cluster = static_cast<int>(index);
    }
    return static_cast<int>(codePoints.size());
}

int WebFontRasterizer::shapePrimaryRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::uint32_t weight,
    std::span<Ubiquitty::ProportionalShapedGlyph> glyphsOut)
{
    if (!m_isAvailable || m_primaryFamily.empty() || codePoints.empty() || glyphsOut.size() < codePoints.size())
        return 0;
    const int cssWeight = cssWeightFor(face, weight, m_userAxes, m_weights);
    m_proportionalAdvances.assign(codePoints.size(), 0.0);
    if (webFontMeasureProportional(m_primaryFamily.c_str(), codePoints.data(), static_cast<int>(codePoints.size()), m_pixelSize,
            cssWeight, m_proportionalAdvances.data())
        != static_cast<int>(codePoints.size()))
        return 0;
    for (std::size_t index = 0; index < codePoints.size(); ++index) {
        Ubiquitty::ProportionalShapedGlyph& glyph = glyphsOut[index];
        glyph = {};
        glyph.glyph = codePoints[index];
        glyph.advanceInPixels = static_cast<float>(m_proportionalAdvances[index]);
        glyph.cluster = static_cast<std::uint16_t>(index);
    }
    return static_cast<int>(codePoints.size());
}

bool WebFontRasterizer::rasteriseProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face,
    int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut)
{
    if (!m_isAvailable || glyphs.empty() || stripWidthInPixels <= 0 || stripHeightInPixels <= 0)
        return false;
    if (coverageOut.size() < static_cast<std::size_t>(stripWidthInPixels) * static_cast<std::size_t>(stripHeightInPixels))
        return false;

    const char* proportionalFamily = m_proportionalFamily.c_str();
    const int cssWeight = face == Rendering::FontFace::Bold || face == Rendering::FontFace::BoldItalic ? 700 : 400;

    // Three parallel arrays rather than the seam's struct, because the EM_JS
    // boundary takes scalars and pointers: a struct crossing it would need its
    // layout restated in JavaScript, which is a second definition of a type the
    // seam already owns.
    m_proportionalCodePoints.clear();
    m_proportionalOffsetsX.clear();
    m_proportionalOffsetsY.clear();
    m_proportionalCodePoints.reserve(glyphs.size());
    m_proportionalOffsetsX.reserve(glyphs.size());
    m_proportionalOffsetsY.reserve(glyphs.size());
    for (const Ubiquitty::ProportionalShapedGlyph& glyph : glyphs) {
        m_proportionalCodePoints.push_back(glyph.glyph);
        m_proportionalOffsetsX.push_back(glyph.offsetXInPixels);
        m_proportionalOffsetsY.push_back(glyph.offsetYInPixels);
    }

    // Clamped into the strip for the same reason the single-glyph path clamps:
    // a strip shorter than the cell places the baseline outside it and draws
    // nothing.
    const int baseline = std::min(static_cast<int>(m_metrics.baselineFromTop), stripHeightInPixels);
    return webFontDrawProportional(proportionalFamily, m_proportionalCodePoints.data(), m_proportionalOffsetsX.data(),
               m_proportionalOffsetsY.data(), static_cast<int>(glyphs.size()), m_proportionalPixelSize > 0 ? m_proportionalPixelSize : m_pixelSize, 1.0, cssWeight, baseline,
               stripWidthInPixels, stripHeightInPixels, coverageOut.data())
        != 0;
}

bool WebFontRasterizer::rasteriseSizedProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face,
    const Rendering::SizedMaster& master, int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut)
{
    if (master.isIdentity())
        return rasteriseProportionalRun(glyphs, face, stripWidthInPixels, stripHeightInPixels, coverageOut);
    if (!m_isAvailable || glyphs.empty() || !master.scale.isWhole() || stripWidthInPixels <= 0 || stripHeightInPixels <= 0)
        return false;
    if (coverageOut.size() < static_cast<std::size_t>(stripWidthInPixels) * static_cast<std::size_t>(stripHeightInPixels))
        return false;

    const char* proportionalFamily = m_proportionalFamily.c_str();
    const int cssWeight = face == Rendering::FontFace::Bold || face == Rendering::FontFace::BoldItalic ? 700 : 400;
    m_proportionalCodePoints.clear();
    m_proportionalOffsetsX.clear();
    m_proportionalOffsetsY.clear();
    for (const Ubiquitty::ProportionalShapedGlyph& glyph : glyphs) {
        m_proportionalCodePoints.push_back(glyph.glyph);
        m_proportionalOffsetsX.push_back(glyph.offsetXInPixels);
        m_proportionalOffsetsY.push_back(glyph.offsetYInPixels);
    }
    // The face drawn at the master's size, a vector face at real resolution
    // where a stretch would resample its pixels, on the strip's baseline
    // taken `scale` times; offsets are already the master's.
    const int scale = master.scale.whole();
    const int baseline = std::min(scale * static_cast<int>(m_metrics.baselineFromTop), stripHeightInPixels);
    return webFontDrawProportional(proportionalFamily, m_proportionalCodePoints.data(), m_proportionalOffsetsX.data(),
               m_proportionalOffsetsY.data(), static_cast<int>(glyphs.size()), (m_proportionalPixelSize > 0 ? m_proportionalPixelSize : m_pixelSize) * scale, master.horizontalScale, cssWeight, baseline,
               stripWidthInPixels, stripHeightInPixels, coverageOut.data())
        != 0;
}

std::string WebFontRasterizer::familyForCluster(const std::uint32_t* codePoints, int count, Rendering::FontFace face, std::uint32_t weight, Rendering::Font::Presentation presentation)
{
    using namespace Rendering::Font;

    FontFallbackPolicy policy(m_inventory, { m_caches.han, m_caches.script, m_caches.generic, m_caches.emoji, m_caches.symbol, m_caches.rangeMap, m_caches.negative });
    FontRequest request;
    request.codePoints = std::span<const std::uint32_t>(codePoints, static_cast<std::size_t>(count));
    // The browser must probe the same text form that the coverage draw uses.
    // SGR can override an explicit emoji selector in the stored cluster.
    std::array<std::uint32_t, clusterPoolMaximumCodePoints + 1> presented;
    if (presentation == Presentation::Text && Unicode::isExtendedPictographic(codePoints[0])) {
        if (count > clusterPoolMaximumCodePoints)
            return {};
        std::copy_n(codePoints, count, presented.begin());
        std::replace(presented.begin(), presented.begin() + count, Unicode::Width::variationSelector16, Unicode::Width::variationSelector15);
        if (count == 1)
            presented[count++] = Unicode::Width::variationSelector15;
        request.codePoints = std::span<const std::uint32_t>(presented.data(), static_cast<std::size_t>(count));
    }
    request.script = classifyScript(codePoints[0]);
    request.presentation = presentation;
    request.style = styleForFace(face);
    request.variableWeight = static_cast<std::uint8_t>(weight > 255 ? 255 : weight);
    // Routing asks which face suits the glyph, not how a terminal places it,
    // so an ambiguous code point routes as the narrow glyph it is by default.
    request.width = Unicode::Width::forCodePoint(codePoints[0], Unicode::Width::AmbiguousWidth::Narrow) == 2 ? CellWidthClass::Wide : CellWidthClass::Narrow;

    const GlyphRoute route = policy.route(request, m_preferences);
    if (isMissing(route))
        return {};
    return std::string(m_inventory.familyName(route.font));
}

bool WebFontRasterizer::rasterizeGlyph(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, int slotWidth, int slotHeight, std::uint8_t* coverageOut)
{
    if (!m_isAvailable || slotWidth <= 0 || slotHeight <= 0 || !coverageOut)
        return m_fallback.rasterizeGlyph(codePoint, face, weight, slotWidth, slotHeight, coverageOut);

    if (Rendering::tilesOnTextPen(codePoint) && rasterizeTilingGlyph(codePoint, face, weight, {}, slotWidth, slotHeight, coverageOut))
        return true;

    // Which family draws this is Core's decision, resolved here rather than at
    // the seam: `GlyphRasterizer` passes a code point and no font, exactly as
    // macOS's rasterise methods do before calling copyFontForCodePoint.
    const std::string family = familyForCluster(&codePoint, 1, face, weight, Rendering::Font::Presentation::Text);
    if (family.empty())
        return m_fallback.rasterizeGlyph(codePoint, face, weight, slotWidth, slotHeight, coverageOut);

    // The baseline sits where the metrics put it, clamped into the slot: a slot
    // shorter than the cell — which the overflow pass can ask for — would
    // otherwise place the baseline outside it and draw nothing.
    const int baseline = std::min(static_cast<int>(m_metrics.baselineFromTop), slotHeight);
    // Drawn at the slot's left edge: a letter of a proportional primary face
    // is placed on screen by the row's layout, which puts the slot at its pen.
    const int cssWeight = cssWeightFor(face, weight, m_userAxes, m_weights);
    double horizontalScale = 1.0;
    // Core's display row has already selected the Arabic contextual forms.
    // Their joining edges occupy the cell's advance, including when the
    // browser's fallback face has a narrower proportional advance.
    const bool isCursiveForm = (codePoint >= 0xFB50 && codePoint <= 0xFDFF) || (codePoint >= 0xFE70 && codePoint <= 0xFEFC);
    if (isCursiveForm) {
        double advance = 0.0;
        if (webFontMeasureProportional(family.c_str(), &codePoint, 1, m_pixelSize, cssWeight, &advance) == 1 && advance > 0.0)
            horizontalScale = static_cast<double>(slotWidth) / advance;
    }
    if (webFontDrawGlyph(family.c_str(), static_cast<int>(codePoint), m_pixelSize, horizontalScale, 1.0, cssWeight, Rendering::isItalic(face) ? 1 : 0,
            0.0, baseline, slotWidth, slotHeight, Unicode::isExtendedPictographic(codePoint), coverageOut))
        return true;

    // No glyph in the host's face. Box drawing, powerline separators and the
    // symbol ranges are the common case, and the fallback carries all of them.
    return m_fallback.rasterizeGlyph(codePoint, face, weight, slotWidth, slotHeight, coverageOut);
}

bool WebFontRasterizer::rasterizeCluster(const std::uint32_t* codePoints, int count, Rendering::FontFace face, std::uint32_t weight, int slotWidth, int slotHeight, std::uint8_t* coverageOut)
{
    if (!m_isAvailable || !codePoints || count <= 0 || slotWidth <= 0 || slotHeight <= 0 || !coverageOut)
        return m_fallback.rasterizeCluster(codePoints, count, face, weight, slotWidth, slotHeight, coverageOut);
    const std::string family = familyForCluster(codePoints, count, face, weight, Rendering::Font::Presentation::Text);
    const int baseline = std::min(static_cast<int>(m_metrics.baselineFromTop), slotHeight);
    if (!family.empty() && webFontDrawCluster(family.c_str(), codePoints, count, m_pixelSize, cssWeightFor(face, weight, m_userAxes, m_weights), Rendering::isItalic(face) ? 1 : 0, baseline, slotWidth, slotHeight, Unicode::isExtendedPictographic(codePoints[0]), coverageOut))
        return true;
    return m_fallback.rasterizeCluster(codePoints, count, face, weight, slotWidth, slotHeight, coverageOut);
}

bool WebFontRasterizer::rasterizeColorCluster(const std::uint32_t* codePoints, int count, int slotInPixels, std::uint8_t* pixelsOut)
{
    if (!m_isAvailable || !codePoints || count <= 0 || slotInPixels <= 0 || !pixelsOut)
        return false;
    if (count > clusterPoolMaximumCodePoints)
        return false;
    // Core selected the colour pass from the stored cell presentation. Give
    // the browser a matching selector even when SGR overrides a text selector.
    std::array<std::uint32_t, clusterPoolMaximumCodePoints + 1> presented;
    std::copy_n(codePoints, count, presented.begin());
    for (int index = 0; index < count; ++index) {
        if (presented[index] == Unicode::Width::variationSelector15)
            presented[index] = Unicode::Width::variationSelector16;
    }
    if (count == 1 && Unicode::isExtendedPictographic(presented[0]) && !Unicode::Width::isEmojiPresentation(presented[0]))
        presented[count++] = Unicode::Width::variationSelector16;
    const std::string family = familyForCluster(presented.data(), count, Rendering::FontFace::Regular, 400, Rendering::Font::Presentation::Emoji);
    if (family.empty())
        return false;
    return webFontDrawColorCluster(family.c_str(), presented.data(), count, slotInPixels, pixelsOut) != 0;
}

bool WebFontRasterizer::rasterizeSizedMaster(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, const Rendering::SizedMaster& master, int slotWidth, int slotHeight, std::uint8_t* coverageOut)
{
    if (master.isIdentity())
        return rasterizeGlyph(codePoint, face, weight, slotWidth, slotHeight, coverageOut);
    if (!m_isAvailable)
        return GlyphRasterizer::rasterizeSizedMaster(codePoint, face, weight, master, slotWidth, slotHeight, coverageOut);

    if (Rendering::tilesOnTextPen(codePoint) && rasterizeTilingGlyph(codePoint, face, weight, master, slotWidth, slotHeight, coverageOut))
        return true;

    // Re-rasterize at the master's size. A vector face gains real resolution
    // here, where the base implementation's nearest-neighbour would double
    // pixels. A fraction is drawn at its own size, which CSS takes as a
    // fractional pixel size; a whole scale stays a whole size. A
    // browser face reports no width axis, so a doubled row's master is the
    // face stretched across by the whole doubling Core selected. The pen is
    // Core's (sizedMasterPen), as on every arm: the glyph's advance centred in
    // the master and moved by the master's shift, in the unstretched space the
    // stretch carries it from. The baseline is Core's too, moved down by the
    // shift and not rounded (sizedMasterBaselineFromTop): the canvas draws text
    // at a fractional baseline, and each band's shift is its own.
    const Rendering::RasterScale scale = master.scale;
    const double scaledSize = scale.isWhole() ? static_cast<double>(m_pixelSize * scale.whole()) : m_pixelSize * scale.value();
    const double baseline = std::min(Rendering::sizedMasterBaselineFromTop(static_cast<double>(static_cast<int>(m_metrics.baselineFromTop)), master), static_cast<double>(slotHeight));
    const std::string family = familyForCluster(&codePoint, 1, face, weight, Rendering::Font::Presentation::Text);
    const int cssWeight = cssWeightFor(face, weight, m_userAxes, m_weights);
    if (!family.empty()) {
        // The advance the browser draws this glyph at, measured at the face's own
        // size and carried to the master's. A browser that cannot measure it
        // leaves the glyph's advance the slot's, so only the shift places it.
        double advanceInPixels = static_cast<double>(slotWidth);
        double measured = 0.0;
        if (webFontMeasureProportional(family.c_str(), &codePoint, 1, m_pixelSize, cssWeight, &measured) == 1 && measured > 0.0)
            advanceInPixels = measured * scale.value() * master.horizontalScale;
        const Rendering::SubpixelPhase pen = Rendering::sizedMasterPen(slotWidth, advanceInPixels, master);
        const double penX = (static_cast<double>(pen.snappedPenX) + static_cast<double>(pen.phase) / Rendering::sizedMasterPenGrid) / master.horizontalScale;
        if (webFontDrawGlyph(family.c_str(), static_cast<int>(codePoint), scaledSize, master.horizontalScale, 1.0, cssWeight, Rendering::isItalic(face) ? 1 : 0,
                penX, baseline, slotWidth, slotHeight, Unicode::isExtendedPictographic(codePoint), coverageOut))
            return true;
    }
    return GlyphRasterizer::rasterizeSizedMaster(codePoint, face, weight, master, slotWidth, slotHeight, coverageOut);
}

bool WebFontRasterizer::rasterizeTilingGlyph(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight,
    const Rendering::SizedMaster& master, int slotWidth, int slotHeight, std::uint8_t* coverageOut)
{
    const auto donor = Rendering::stemDonor(codePoint);
    const std::uint32_t drawn = donor ? donor : codePoint;
    const auto family = familyForCluster(&drawn, 1, face, weight, Rendering::Font::Presentation::Text);
    if (family.empty())
        return false;
    double size = m_pixelSize * master.scale.value();
    const int cssWeight = cssWeightFor(face, weight, m_userAxes, m_weights);
    const int cellHeight = std::min(slotHeight, master.scale.scaled(static_cast<int>(m_metrics.cellHeight)));
    const int marginY = (slotHeight - cellHeight) / 2;
    const int marginX = std::max(0, (slotWidth - master.horizontalMagnification().scaled(static_cast<int>(m_metrics.cellWidth))) / 2);
    std::array<double, 3> bounds {};
    (void)webFontMeasureGlyph(family.c_str(), static_cast<int>(drawn), size, cssWeight, Rendering::isItalic(face), bounds.data());
    // Math faces can advance several cells for one assembly piece. Fit the
    // face uniformly before Core places its joining edge, or the diagonal's
    // joining tip can lie entirely outside the narrow atlas slot.
    const double availableWidth = (slotWidth - marginX * 2) / master.horizontalScale;
    if (bounds[2] > availableWidth + 0.5 && availableWidth > 0) {
        size *= availableWidth / bounds[2];
        (void)webFontMeasureGlyph(family.c_str(), static_cast<int>(drawn), size, cssWeight, Rendering::isItalic(face), bounds.data());
    }
    const auto fit = Rendering::fitTilingGlyph(drawn, bounds[0], bounds[1], slotHeight - marginY - cellHeight, cellHeight);
    const double baseline = fit.isApplicable ? slotHeight - fit.baseline * fit.verticalScale
                                             : Rendering::sizedMasterBaselineFromTop(m_metrics.baselineFromTop, master);
    if (!webFontDrawGlyph(family.c_str(), static_cast<int>(drawn), size, master.horizontalScale,
            fit.isApplicable ? fit.verticalScale : 1.0, cssWeight, Rendering::isItalic(face),
            marginX / master.horizontalScale, baseline, slotWidth, slotHeight, 0, coverageOut))
        return false;
    Rendering::TilingCoverage({ coverageOut, static_cast<std::size_t>(slotWidth) * slotHeight },
        slotWidth, slotHeight, marginX, slotWidth - marginX, marginY, marginY + cellHeight)
        .finish(codePoint, drawn);
    return true;
}

#if !defined(__EMSCRIPTEN__) && UBIQUITTY_ENABLE_TEST_HOOKS
namespace ForTest {
void installWebFontHost(const WebFontHost& host) { s_webFontHost = host; }
} // namespace ForTest
#endif

} // namespace Ubiquitty::Web
