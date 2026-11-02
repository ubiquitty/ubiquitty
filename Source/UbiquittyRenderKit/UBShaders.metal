// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

/*
 * UBShaders.metal — vertex + fragment stages for the terminal grid.
 *
 * Two pipelines share a uniform block.
 *
 * Glyph pass: one instanced draw covers the whole grid; each instance
 * is one cell. The vertex stage expands a unit quad into the cell's
 * screen rect from grid coordinates + cell metrics, carrying foreground
 * / background colors and the glyph's atlas UV rect. The fragment stage
 * samples the single-channel glyph atlas as a coverage mask and blends
 * foreground over background. A cell with no glyph (atlasTopLeft ==
 * atlasBottomRight) paints solid background. The atlas is an R8 coverage
 * texture: sampled value 1 == full ink.
 *
 * Overlay pass: a second instanced draw paints solid-color rectangles
 * (cursor block / underline / bar, later: selection highlight) in
 * absolute pixel coordinates over the glyph pass output, with standard
 * alpha blending.
 */

#include <metal_stdlib>
#include "../Core/Tek/BeamRaster.h"
using namespace metal;

struct Uniforms {
    float2 viewportSizeInPixels;   // drawable size in pixels
    float2 cellSizeInPixels;       // cell width / height in pixels
    float2 originInPixels;     // top-left of the grid in pixels (y measured from top)
    float  backgroundOpacity;    // cell-background alpha; <1 lets the desktop show through behind text
    float4 defaultBackground;    // terminal default background (linear-ready sRGB 0..1); pill corners fall back to it
    int    edgeToEdge;   // 1 = fullscreen content mode (DECSET 7402): glyphless cells paint the letterbox opaquely
    int    bitmapTier;   // 1 = the face is Core's embedded bitmap: procedural passes composite like the software renderer
};

struct CellInstance {
    float2 gridPos;      // (column, row)
    float  widthCells;   // 1 for narrow, 2 for wide lead
    float4 foreground;           // foreground RGBA, 0..1
    float4 background;           // background RGBA, 0..1
    float2 atlasTopLeft;     // glyph UV top-left (0..1); equals atlasBottomRight when blank
    float2 atlasBottomRight;     // glyph UV bottom-right
};

struct OverlayInstance {
    float2 topLeftInPixels;        // top-left pixel corner (y from top)
    float2 bottomRightInPixels;        // bottom-right pixel corner
    float4 color;        // RGBA, 0..1; alpha drives the blend
    float  cornerRadius; // >0 = rounded-rect corners, device px; 0 = sharp
    float  cornerStyle;  // 0 = circular arc, 1 = continuous (superellipse)
    float  strokeWidth;  // >0 = hollow outline of this width (device px); 0 = filled
    float  shadeDensity; // >0 = phase-locked ordered-dither shade at this density
    float  shapeKind;    // -1 = mosaic mask, >0 = analytic Powerline-separator SDF
    uint   usesBackgroundColors;
    float  foregroundCoverage;
    float4 plA;          // shape or mosaic parameters; triangle a,b / disc c,r / mask,columns,rows
    float4 plB;          // shape parameters; triangle c + strokeHalfY / disc sideSign + strokeHalfY
    float4 background;
};

// One decoration rule: a colored horizontal stroke (or box edge) drawn
// in the resolved underline / foreground color, independent of the glyph
// coverage atlas. topLeftInPixels/bottomRightInPixels is the stroke's pixel rect (y from top);
// `kind` selects the pattern the fragment paints inside it; `dashPeriodInPixels`
// carries the originating cell's width so dotted/dashed/curly patterns
// repeat once per cell regardless of how many cells a rule spans.
struct DecorationInstance {
    float2 topLeftInPixels;
    float2 bottomRightInPixels;
    float4 color;
    float  kind;         // DECO_* selector
    float  dashPeriodInPixels;     // cell advance in pixels (pattern period)
    float  thicknessInPixels;      // stroke thickness in pixels (curl/box use it)
    float  skipInk;      // 1 = cut the rule where glyph ink crosses it
    float2 inkTopLeft;       // glyph cell-box atlas UV; .y is the band v on both
    float2 inkBottomRight;       // ends, so the fragment samples coverage at the band
    float2 padInAtlas;        // skip-ink dilation radius in atlas UV units
    float2 pad1;              // .x tap count; .y base-8 self/left/right sheet selectors
    float2 glyphSlotTopLeftUV;       // glyph's full atlas-slot UV rect: dilation taps are
    float2 glyphSlotBottomRightUV;       // clamped to it so the disc can't bleed into a neighbour slot
    // Cross-cell skip-ink: the left/right neighbour glyphs, so a descender that
    // leans into this cell from the adjacent cell breaks this rule too. *Ink =
    // (cellBoxU min, max, band v top, bottom); *Box = (slot min.x,y, max.x,y).
    // An absent neighbour has .x>=.y in its box (zeroed), and is skipped.
    float4 leftInk;
    float4 leftBox;
    float4 rightInk;
    float4 rightBox;
};

// Decoration kinds. Solid (0.0) fills the rect — the else case in the
// fragment, so no named constant; the rest mask inside it.
constant float decorationDotted = 1.0;
constant float decorationDashed = 2.0;
constant float decorationCurly  = 3.0;

// Subpixel glyph pass: one instance per inked cell, positioned at an
// integer pixel origin with the glyph rasterised for the matching
// horizontal subpixel phase. Blitted 1:1 (no cell-stretch), alpha-
// blended over the background the cell pass already painted.
struct GlyphInstance {
    float2 originInPixels;     // pixel-snapped top-left
    float2 sizeInPixels;       // glyph quad size in pixels
    float4 foreground;           // foreground RGBA, 0..1
    float4 background;           // the cell background this glyph alpha-blends over
    float2 atlasTopLeft;     // glyph UV top-left
    float2 atlasBottomRight;     // glyph UV bottom-right
};

struct VertexOut {
    float4 position [[position]];
    float2 atlasUV;
    float4 foreground;
    float4 background;
    float  hasGlyph;
    // Below here: values derived from the instance and the uniforms alone, so
    // each is the same at every pixel the cell covers and the vertex stage owes
    // it once per quad instead of the fragment stage owing it per pixel.
    // INVARIANT: nothing that moves with the atlas coverage sample may be
    // folded in here — that is per-pixel by definition.
    float  alphaBase;    // backgroundOpacity, after the default-background translucency test
    // The glyph box the cell was given, in atlas pixels, so the coverage tap can
    // be held inside it. Flat: it is the instance's own rect, not a corner mix.
    float2 atlasBoxTopLeft [[flat]];
    float2 atlasBoxBottomRight [[flat]];
};

struct OverlayOut {
    float4 position [[position]];
    float4 color;
    float  bitmapTier [[flat]]; // Uniforms.bitmapTier, carried so the fragment needs no buffer of its own
    float2 localPixels;       // position relative to the quad centre (device px)
    float2 halfSizeInPixels;  // half the quad extent (device px)
    float  cornerRadius;
    float  cornerStyle;
    float  strokeWidth;
    float  shadeDensity;
    float  shapeKind;
    uint   usesBackgroundColors [[flat]];
    float  foregroundCoverage [[flat]];
    float4 background [[flat]];
    float4 plA;
    float4 plB;
    float2 cellLocalPixels;   // pixel within the cell quad, (0,0) top-left
    float2 cellSizePixels;    // cell quad size in device px (for unit↔px)
};

// Unit quad corners (two triangles) in 0..1 cell-local space.
constant float2 quadCorners[6] = {
    float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
    float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0),
};

// An atlas rect arrives in ATLAS PIXELS and `sample` wants normalized
// coordinates, so the division happens here — once per fragment, on the unit
// that has division to spare, rather than per cell on the CPU to produce a
// number the other backends would multiply straight back.
//
// `get_width`/`get_height` are uniform for the draw, so the reciprocal is
// hoisted rather than computed per tap.
static float2 atlasNormalized(texture2d<float> atlas, float2 positionInAtlasPixels)
{
    return positionInAtlasPixels / float2(atlas.get_width(), atlas.get_height());
}

// The coverage of the texel an atlas coordinate names, taken from inside one
// glyph box. This is the BITMAP tier's cell tap, and it is the reference's:
// SoftwareRenderer::compositeCell takes `int(u)` of the same interpolated
// coordinate — "the interpolated coordinate is the texel" — and the bitmap tier
// is the one every arm is held to that renderer for, byte for byte.
//
// The linear sampler returns a texel exactly at that texel's centre, so the
// floor is the whole of the difference, and it is inert wherever the quad and
// the box are the same size: a cell the width of its slot puts every fragment
// centre on a texel centre already. Where the two sizes differ — a magnified
// sized block, a cell narrowed by DECCOLM — the tap falls between two texels,
// and averaging them is a grey edge on a face that has no antialiaser.
//
// The box bounds it because a rasteriser is free to cut slots that touch: the
// bitmap tier's carry no margin, so the texel before a box is the neighbouring
// glyph's last column, and both the average above and the edge fragment's own
// rounding reach it. Half a neighbour drawn down the left of a cell is a stray
// stroke beside the letter, at whatever rows that neighbour happens to ink.
static float atlasTexelCoverage(texture2d<float> atlas, sampler atlasSampler,
    float2 positionInAtlasPixels, float2 boxTopLeft, float2 boxBottomRight)
{
    // Sized bands can end inside a texel. Clamp to texel centres so a
    // fractional crop cannot turn a nearest tap into a blended edge.
    const float2 texelCentre = clamp(floor(positionInAtlasPixels) + 0.5, floor(boxTopLeft) + 0.5, ceil(boxBottomRight) - 0.5);
    return atlas.sample(atlasSampler, atlasNormalized(atlas, texelCentre)).r;
}

// Pixel coords (y-down origin top-left) → clip space (y-up).
static float2 pixelsToNdc(float2 positionInPixels, float2 viewportSizeInPixels)
{
    float2 ndc;
    ndc.x = (positionInPixels.x / viewportSizeInPixels.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (positionInPixels.y / viewportSizeInPixels.y) * 2.0;
    return ndc;
}

// sRGB-encoded color (the 8-bit values we carry) → linear light. The
// render target is an _sRGB format, so the GPU re-encodes on write and
// blends in linear — coverage/alpha compositing is then gamma-correct,
// matching CoreText/AppKit. Fragments must therefore output LINEAR.
static float3 srgbToLinear(float3 c)
{
    return select(c / 12.92,
                  pow((c + 0.055) / 1.055, 2.4),
                  c > 0.04045);
}

// Linear light back to the sRGB-encoded value: the inverse of the above, for
// a pass that must read the byte the target already holds.
static float3 linearToSrgb(float3 c)
{
    return select(c * 12.92,
                  1.055 * pow(c, 1.0 / 2.4) - 0.055,
                  c > 0.0031308);
}

// The byte the software renderer writes when it composites a rule edge: the
// mix of the ENCODED channels, rounded half up (SoftwareRenderer.cpp's
// channelToByte, v * 255 + 0.5 truncated). Not the CoreGraphics text mix
// below, which truncates: that one reproduces CTLineDraw for a real font, this
// one reproduces the portable renderer for the bitmap tier, whose golden is
// that renderer's picture on every arm. The bias absorbs float error the same
// way the text mix's does, small enough never to cross a code.
static float3 softwareRuleMixByte(float3 destinationEncoded, float3 sourceEncoded, float alpha)
{
    float3 mixed = (destinationEncoded * (1.0 - alpha) + sourceEncoded * alpha) * 255.0;
    return floor(mixed + 0.5 + 1.0 / 1024.0) / 255.0;
}

// The byte the software renderer writes when it composites an overlay quad —
// selection, highlight, the cursor — over a cell: the integer mix
// (dst * (255 - a) + src * a + 127) / 255 on the encoded bytes, alpha first
// rounded to a byte (SoftwareRenderer.cpp mixCoverage; the Vulkan overlay
// shader spells the same sum). Every term is an integer held in a float, so
// the float arithmetic is exact and the floor is the integer division.
static float3 softwareOverlayMixByte(float3 destinationEncoded, float3 sourceEncoded, float alpha)
{
    float a = floor(alpha * 255.0 + 0.5);
    float3 d = round(destinationEncoded * 255.0);
    float3 c = round(sourceEncoded * 255.0);
    return floor((d * (255.0 - a) + c * a + 127.0) / 255.0) / 255.0;
}

// The destination a bitmap-tier fragment is handed when its pipeline cannot
// read the target. Framebuffer fetch is refused where the implementation does
// not support it, the iOS simulator among them; without a fallback the passes
// that read it never build and their draws leave the frame. Handed this, the
// bitmap tier returns its colour and coverage for the hardware to blend
// instead: exact for solid coverage, and in linear light rather than in the
// encoded bytes at a partial one.
constant float4 unreadDestination = float4(-1.0);

static bool destinationIsUnread(float4 destination)
{
    return destination.a < 0.0;
}

// The first of the two draws a focused match's pill takes where the target
// cannot be read: its shadow alone. The software renderer composites the
// shadow into the pixel and then the pill over that result; one blend cannot
// round both steps, so the encoded pass draws them as two.
constant float4 unreadShadowDestination = float4(-2.0);

static bool destinationIsShadowPass(float4 destination)
{
    return destination.a < -1.5;
}

// What an overlay fragment returns. A real font's pass hands the hardware a
// linear colour and its alpha to blend in linear light. The
// bitmap tier's pass blends nothing: the fragment reads the byte the target
// holds, mixes it as the software renderer does, and returns that byte
// decoded, opaque — the CPU leaves the alpha byte at 255.
static float4 overlayComposite(float bitmapTier, float3 rgbEncoded, float alpha, float4 destination)
{
    if (bitmapTier < 0.5)
        return float4(srgbToLinear(rgbEncoded), alpha);
    float a = floor(alpha * 255.0 + 0.5);
    if (destinationIsUnread(destination))
        return float4(srgbToLinear(round(rgbEncoded * 255.0) / 255.0), a / 255.0);
    if (a <= 0.0)
        return float4(destination.rgb, 1.0);
    if (a >= 255.0)
        return float4(srgbToLinear(round(rgbEncoded * 255.0) / 255.0), 1.0);
    float3 destinationEncoded = round(linearToSrgb(destination.rgb) * 255.0) / 255.0;
    return float4(srgbToLinear(softwareOverlayMixByte(destinationEncoded, rgbEncoded, alpha)), 1.0);
}

// A fragment that draws nothing: transparent for the blending pass, the
// destination itself for the bitmap tier's pass, which would otherwise store
// the zeros.
static float4 overlayKeepDestination(float bitmapTier, float4 destination)
{
    // The whole pixel, alpha included: the CPU skips such a pixel outright,
    // so its alpha byte is whatever the cell pass stored, not 255.
    return bitmapTier < 0.5 || destinationIsUnread(destination) ? float4(0.0, 0.0, 0.0, 0.0) : destination;
}

// The pixel the software renderer stores for a cell: its background and
// foreground as STRAIGHT bytes mixed by the glyph's coverage, and its alpha
// mixed toward opaque by the same coverage — writeMixedPixel over mixCoverage,
// (a * (255 - c) + b * c + 127) / 255 on every channel, the alpha's "b" being
// 255. Not premultiplied: the drawable convention the pass below stores for
// the window server is not what a headless read-back holds, and the bitmap
// tier's golden is that read-back on every arm. Bitmap coverage is 0 or 255,
// so the mix collapses to one byte or the other; the form is kept whole so a
// fractional mask would still land where the CPU lands.
static float4 softwareCellPixel(float3 backgroundEncoded, float3 foregroundEncoded, float coverage, float opacity)
{
    float c = floor(coverage * 255.0 + 0.5);
    float3 b = round(backgroundEncoded * 255.0);
    float3 f = round(foregroundEncoded * 255.0);
    float bgA = floor(opacity * 255.0 + 0.5);
    float3 mixed = floor((b * (255.0 - c) + f * c + 127.0) / 255.0) / 255.0;
    float outA = floor((bgA * (255.0 - c) + 255.0 * c + 127.0) / 255.0) / 255.0;
    return float4(srgbToLinear(mixed), outA);
}

// The byte CoreGraphics writes when it composites text through a coverage
// mask: the mix of the ENCODED 8-bit channels, divided with truncation, not
// rounding, in sRGB and Display P3 alike. A rounded mix is one code too high
// on half of every edge. The colours arrive as code/255 and the mask as
// code/255 from a unorm texture, so the product is an integer up to float
// error, which the small bias absorbs without ever crossing the next code.
// Spelled over the premultiplied destination below; at opacity one the
// destination is the colour itself.
//
// The byte a translucent background is stored as. The window server reads a
// drawable's bytes as premultiplied in the ENCODED domain — the convention
// CoreGraphics writes, enc(colour) × α — and never decodes them first.
// On an sRGB-format target the GPU encodes what the
// fragment returns, so the fragment returns the DECODED premultiplied byte
// and the encode restores it. Rounded as CoreGraphics rounds its fill.
static float3 premultipliedBackgroundByte(float3 backgroundEncoded, float opacity)
{
    return round(backgroundEncoded * opacity * 255.0) / 255.0;
}

// CoreGraphics' text composite over a premultiplied destination, measured:
// floor(fg × cov + stored × (1 − cov)) per channel on the encoded bytes, with
// `stored` the premultiplied background byte above (29806 of 29826 samples
// exact over five pairs at opacities 0.2–1, the rest one code).
static float3 coreGraphicsTextMixPremultiplied(float3 foreground, float3 storedBackground, float coverage)
{
    float3 mixed = (foreground * coverage + storedBackground * (1.0 - coverage)) * 255.0;
    return floor(mixed + 1.0 / 1024.0) / 255.0;
}

// The alpha byte CoreGraphics writes under that composite: the mask's coverage
// over the destination's stored opacity, truncated as the colour channels are:
// a rounded mix is one code above CoreText on every edge pixel whose exact
// value has a fractional half.
static float coreGraphicsTextAlpha(float coverage, float opacity)
{
    float stored = round(opacity * 255.0);
    return floor(coverage * 255.0 + stored * (1.0 - coverage) + 1.0 / 1024.0) / 255.0;
}

vertex VertexOut termVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]],
                            constant CellInstance* cells [[buffer(1)]])
{
    CellInstance cell = cells[iid];
    float2 corner = quadCorners[vid];

    float2 cellSizeScaled = float2(u.cellSizeInPixels.x * cell.widthCells, u.cellSizeInPixels.y);
    float2 topLeftInPixels = u.originInPixels
        + float2(cell.gridPos.x * u.cellSizeInPixels.x, cell.gridPos.y * u.cellSizeInPixels.y);
    float2 positionInPixels = topLeftInPixels + corner * cellSizeScaled;

    VertexOut out;
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.atlasUV = mix(cell.atlasTopLeft, cell.atlasBottomRight, corner);
    out.atlasBoxTopLeft = cell.atlasTopLeft;
    out.atlasBoxBottomRight = cell.atlasBottomRight;
    out.foreground = cell.foreground;
    out.background = cell.background;
    out.hasGlyph = (cell.atlasTopLeft.x == cell.atlasBottomRight.x
                    && cell.atlasTopLeft.y == cell.atlasBottomRight.y) ? 0.0 : 1.0;
    // Core resolves background opacity before compositing the block cursor.
    out.alphaBase = cell.background.a < 0.0 ? min(u.backgroundOpacity, -cell.background.a) : cell.background.a;
    return out;
}


fragment float4 termFragment(VertexOut in [[stage_in]],
                             constant Uniforms& u [[buffer(0)]],
                             texture2d<float> atlas [[texture(0)]],
                             sampler atlasSampler [[sampler(0)]])
{
    // This pass has blending DISABLED and writes the drawable's first layer
    // straight, so it emits PREMULTIPLIED color. Background opacity < 1 lets
    // the desktop show through behind the cell color: the fragment's alpha is
    // u.backgroundOpacity over bare background and rises to 1 under glyph ink (text
    // stays opaque). rgb is premultiplied by that alpha. Later passes blend
    // straight-over-premultiplied, only adding opacity where their ink lands.
    float o = in.alphaBase;
    float3 backgroundRGB = in.background.rgb;
    if (in.hasGlyph < 0.5 || u.edgeToEdge != 0 || in.foreground.a < 0.0) {
        // Fullscreen content mode (DECSET 7402): the letterbox must stay OPAQUE
        // even on a translucent terminal, and no leftover glyph may bleed through
        // the bars — so glyphless cells, and every cell while edge-to-edge, paint
        // the opaque letterbox background and ignore backgroundOpacity.
        // INVARIANT (ties to the CPU occlusion-skip): the `u.edgeToEdge != 0` arm here
        // paints every cell the opaque letterbox and never samples the glyph atlas, so
        // CellInstanceBuilder.cpp's shouldSkipOccludedGlyphs emits letterbox-bg-only cells and skips
        // the glyph build for exactly this condition. NARROWING this arm (e.g. gating it on
        // a further flag) without narrowing that CPU guard in lockstep would drop visible
        // glyphs the CPU already skipped emitting.
        float a = (u.edgeToEdge != 0) ? 1.0 : o;
        // The stored byte is the encoded colour times the opacity; the encode
        // on store undoes the decode here. Opaque cells store the colour.
        // Bitmap tier: the straight byte the software renderer stores, not
        // the premultiplied one the window server reads.
        if (u.bitmapTier != 0)
            return softwareCellPixel(backgroundRGB, in.foreground.rgb, 0.0, a);
        return float4(srgbToLinear(premultipliedBackgroundByte(backgroundRGB, a)), a);
    }
    // A CoreText sheet keeps the linear tap: its glyphs are antialiased and its
    // slots carry a margin, so a coordinate between two texels names a real
    // intermediate coverage and the texel outside the box is that glyph's own
    // blank. The bitmap tier has neither property and takes the tap above.
    float coverage = u.bitmapTier != 0
        ? atlasTexelCoverage(atlas, atlasSampler, in.atlasUV, in.atlasBoxTopLeft, in.atlasBoxBottomRight)
        : atlas.sample(atlasSampler, atlasNormalized(atlas, in.atlasUV)).r;
    // SGR 5/6 blink fade rides on foreground.a — scale coverage by it so the glyph
    // dissolves into the background on the same curve as the cursor caret.
    coverage *= in.foreground.a;
    // Ink is opaque; bare background carries backgroundOpacity. The composited alpha
    // tracks coverage so partly-covered edge pixels feather between the two, on
    // CoreGraphics' truncating rule rather than the store's rounding.
    float a = coreGraphicsTextAlpha(coverage, o);
    // The mask is CoreText's own smoothing-dilated coverage for this foreground's
    // tier, and AppKit composites that mask between the sRGB-encoded colours, so
    // the blend happens on the encoded values and only the result is linearised
    // for the sRGB target. That reproduces CTLineDraw to the byte; a linear-light
    // blend of the same mask reads thinner than every other window on the desktop.
    // Over a translucent cell the destination is the premultiplied background
    // byte, and the mix is already premultiplied: it is stored as it is.
    if (u.bitmapTier != 0)
        return softwareCellPixel(backgroundRGB, in.foreground.rgb, coverage, o);
    float3 stored = coreGraphicsTextMixPremultiplied(in.foreground.rgb, premultipliedBackgroundByte(backgroundRGB, o), coverage);
    return float4(srgbToLinear(stored), a);
}

vertex OverlayOut overlayVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant Uniforms& u [[buffer(0)]],
                                constant OverlayInstance* quads [[buffer(1)]])
{
    OverlayInstance q = quads[iid];
    float2 corner = quadCorners[vid];
    float2 positionInPixels = mix(q.topLeftInPixels, q.bottomRightInPixels, corner);
    float2 center = 0.5 * (q.topLeftInPixels + q.bottomRightInPixels);

    OverlayOut out;
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.color = q.color;
    out.bitmapTier = float(u.bitmapTier);
    out.localPixels = positionInPixels - center;
    out.halfSizeInPixels = 0.5 * (q.bottomRightInPixels - q.topLeftInPixels);
    out.cornerRadius = q.cornerRadius;
    out.cornerStyle = q.cornerStyle;
    out.strokeWidth = q.strokeWidth;
    out.shadeDensity = q.shadeDensity;
    out.shapeKind = q.shapeKind;
    out.usesBackgroundColors = q.usesBackgroundColors;
    out.foregroundCoverage = q.foregroundCoverage;
    out.background = q.background;
    out.plA = q.plA;
    out.plB = q.plB;
    out.cellLocalPixels = positionInPixels - q.topLeftInPixels;
    out.cellSizePixels = q.bottomRightInPixels - q.topLeftInPixels;
    return out;
}

// --- Analytic Powerline-separator SDF helpers (device-pixel space) -----------
// shapeKind (mirror of PowerlineShapeKind): 1 SolidTriangle, 2 OutlineTriangle
// (round-capped capsule pair), 3 SolidHalfDisc, 4 OutlineHalfDisc,
// 5 OutlineWedge (thin chevron), 6 OutlineDiagonal (thin corner wedge). The
// fragment branches on these thresholds.

// Signed distance to a line segment a→b at point p (all device px). >0 outside.
static float plSegDist(float2 p, float2 a, float2 b)
{
    float2 ab = b - a;
    float2 ap = p - a;
    float denom = max(dot(ab, ab), 1e-6);
    float t = clamp(dot(ap, ab) / denom, 0.0, 1.0);
    return distance(p, a + t * ab);
}

// Signed distance to the filled triangle (a,b,c) at p; <0 inside, >0 outside.
// Orientation-independent (uses the winding sign of the area).
static float plTriDist(float2 p, float2 a, float2 b, float2 c)
{
    float2 e0 = b - a, e1 = c - b, e2 = a - c;
    float2 v0 = p - a, v1 = p - b, v2 = p - c;
    float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / max(dot(e0, e0), 1e-6), 0.0, 1.0);
    float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / max(dot(e1, e1), 1e-6), 0.0, 1.0);
    float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / max(dot(e2, e2), 1e-6), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                       float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}

// Signed distance to the line through a→b at p, negative on the side the
// winding sign `s` names as inward. The line itself — not a stroke centred on
// it — is the shape's outer boundary, so a band taken inward from here keeps
// the whole stroke inside the silhouette and lets the quad's clip finish the
// ends as points where the line crosses the cell corners.
static float plLineDistInward(float2 p, float2 a, float2 b, float s)
{
    float2 e = b - a;
    float len = max(length(e), 1e-6);
    return -s * (e.x * (p.y - a.y) - e.y * (p.x - a.x)) / len;
}

// Mosaic-mask coverage (shapeKind == -1): one full-cell quad carries a packed
// subcell bitmask in plA (mask, columns, rows). Resolve which subcell this pixel
// lands in and report whether that bit is set, so coverage tracks the lit
// subcells rather than the whole quad.
static bool mosaicSubcellLit(OverlayOut in)
{
    uint columns = max(uint(in.plA.y + 0.5), 1u);
    uint rows = max(uint(in.plA.z + 0.5), 1u);
    float2 local = in.cellLocalPixels;
    float2 size = in.cellSizePixels;
    uint column = local.x < round(size.x * 0.5) ? 0u : 1u;
    uint row = 0u;
    if (rows == 2u) {
        row = local.y < round(size.y * 0.5) ? 0u : 1u;
    } else {
        float firstSplit = round(size.y / 3.0);
        float secondSplit = round(size.y * 2.0 / 3.0);
        row = local.y < firstSplit ? 0u : (local.y < secondSplit ? 1u : 2u);
    }
    column = min(column, columns - 1u);
    row = min(row, rows - 1u);
    uint bit = row * columns + column;
    uint mask = uint(in.plA.x + 0.5);
    return ((mask >> bit) & 1u) != 0u;
}

// The focused pill's ring: SoftwareRenderer::compositeFocusedPillRing, spelled
// the same way. The pill's rect in plA with the corner radius, the shadow's
// reach and opacity in plB.xy, the matched cells' box in plB.zw. Inside that
// box on the pill's row the destination is kept — the cell pass painted the
// pill there under the glyphs; everywhere else the shadow lands first, its
// opacity falling off with the square of the distance past the pill's edge,
// and the pill's coverage over it, above the neighbours' ink. Both opacities
// are held to the bitmap tier's levels there.
static float4 focusedPillRing(OverlayOut in, float4 destination, bool isEncodedPass)
{
    float2 pixel = in.position.xy;
    float left = in.plA.x, top = in.plA.y, right = in.plA.z, bottom = in.plA.w;
    // The pill stands `strokeWidth` below the cells' box's top and
    // `shadeDensity` above its bottom, and the cell pass painted the whole
    // box: inside it, the pill's own rows keep the fill the cell pass laid
    // down, and the strips the insets vacated are repainted from the frame's
    // ground — packed into the colour's alpha as three bytes — with the shadow
    // and the pill's edge composited over them as they are everywhere else,
    // so the ring closes over the top and the bottom.
    float inset = in.strokeWidth;
    float bottomInset = in.shadeDensity;
    bool inBox = pixel.x >= in.plB.z && pixel.x < in.plB.w;
    bool inStrip = inBox
        && ((inset > 0.0 && pixel.y >= top - inset && pixel.y < top)
            || (bottomInset > 0.0 && pixel.y >= bottom && pixel.y < bottom + bottomInset));
    if (inBox && !inStrip && pixel.y >= top && pixel.y < bottom)
        return overlayKeepDestination(in.bitmapTier, destination);
    // The strips are opaque and carry their own shadow; the shadow pass
    // leaves them to the pill's draw.
    if (inStrip && destinationIsShadowPass(destination))
        return float4(0.0);
    float halfX = (right - left) * 0.5, halfY = (bottom - top) * 0.5;
    float excessX = max(abs(pixel.x - (left + halfX)) - (halfX - in.cornerRadius), 0.0);
    float excessY = max(abs(pixel.y - (top + halfY)) - (halfY - in.cornerRadius), 0.0);
    float distance = sqrt(excessX * excessX + excessY * excessY) - in.cornerRadius;
    float pillCoverage = clamp(0.5 - distance, 0.0, 1.0);
    float falloff = in.plB.x > 0.0 ? 1.0 - clamp(distance / in.plB.x, 0.0, 1.0) : 0.0;
    float shadow = in.plB.y * falloff * falloff;
    if (in.bitmapTier > 0.5) {
        pillCoverage = floor(pillCoverage * 51.0 + 0.5) / 51.0;
        shadow = floor(shadow * 51.0 + 0.5) / 51.0;
    }
    if (inStrip) {
        float packed = in.color.a;
        float3 groundEncoded = float3(floor(packed / 65536.0), floor(fmod(packed, 65536.0) / 256.0), fmod(packed, 256.0)) / 255.0;
        if (in.bitmapTier > 0.5) {
            // The ground is the strip's own, opaque, so this branch needs no
            // read of the target.
            float4 ground = float4(groundEncoded, 1.0);
            float4 shaded = shadow > 0.0 ? overlayComposite(in.bitmapTier, float3(0.0), shadow, ground) : ground;
            return pillCoverage > 0.0 ? overlayComposite(in.bitmapTier, in.color.rgb, pillCoverage, shaded) : shaded;
        }
        // Opaque: the strip replaces the fill beneath it rather than
        // blending over it, in the domain its pass blends the shadow in
        // everywhere else. The encoded pass darkens the encoded bytes, so the
        // strip does too; a linear darkening there reads lighter than the
        // shadow around it and cuts the ring off at the pill's top.
        if (isEncodedPass) {
            float3 shadedEncoded = groundEncoded * (1.0 - shadow);
            return float4(srgbToLinear(mix(shadedEncoded, in.color.rgb, pillCoverage)), 1.0);
        }
        float3 shaded = srgbToLinear(groundEncoded) * (1.0 - shadow);
        return float4(mix(shaded, srgbToLinear(in.color.rgb), pillCoverage), 1.0);
    }
    if (shadow <= 0.0 && pillCoverage <= 0.0)
        return overlayKeepDestination(in.bitmapTier, destination);
    if (in.bitmapTier > 0.5 && destinationIsUnread(destination)) {
        // Unread: the shadow and the pill are two draws, each blended into
        // the bytes the previous one left (see unreadShadowDestination).
        if (destinationIsShadowPass(destination))
            return shadow > 0.0 ? overlayComposite(in.bitmapTier, float3(0.0), shadow, unreadDestination) : float4(0.0);
        return pillCoverage > 0.0 ? overlayComposite(in.bitmapTier, in.color.rgb, pillCoverage, unreadDestination) : float4(0.0);
    }
    if (in.bitmapTier > 0.5) {
        // Reading the target, the two layers chain: the shadow composites into
        // it, then the pill over that result, as the software renderer does.
        float4 shaded = shadow > 0.0 ? overlayComposite(in.bitmapTier, float3(0.0), shadow, destination) : destination;
        return pillCoverage > 0.0 ? overlayComposite(in.bitmapTier, in.color.rgb, pillCoverage, shaded) : shaded;
    }
    // The blending pass hands the hardware one colour and one alpha, so the
    // shadow beneath the pill has to be folded into that pair here. The shadow
    // is black, so the union of the two coverages carries the pill's colour
    // weighted by its own share of it, and source-over reproduces
    // `pill*c + (1-c)(1-s)*dst` exactly. Emitting the pill alone would drop the
    // shadow wherever both cover a pixel — the antialiased rim, where the
    // shadow is deepest — and ring the pill in a bright seam.
    float combined = pillCoverage + shadow - pillCoverage * shadow;
    if (combined <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(srgbToLinear(in.color.rgb) * (pillCoverage / combined), combined);
}

// The overlay body, shared by the two entry points below. `destination` is
// read only on the bitmap tier; the blending pass passes zero for it and every
// branch it can reach ignores it.
static float4 overlayShade(OverlayOut in, float4 destination, bool isEncodedPass = false)
{
    float a = in.color.a;
    if (in.shapeKind < -2.5)
        return focusedPillRing(in, destination, isEncodedPass);
    if (in.shapeKind < -1.5) {
        float2 pixel = in.position.xy;
        float coverage;
        if (in.cornerRadius <= 0.0) {
            float2 extent = clamp(min(pixel + 0.5, in.plA.zw) - max(pixel - 0.5, in.plA.xy), 0.0, 1.0);
            coverage = extent.x * extent.y;
        } else {
            float distance = length(pixel - (in.plA.xy + in.plA.zw) * 0.5) - in.cornerRadius;
            if (in.strokeWidth > 0.0)
                distance = abs(distance + in.strokeWidth * 0.5) - in.strokeWidth * 0.5;
            coverage = clamp(0.5 - distance, 0.0, 1.0);
        }
        if (in.bitmapTier > 0.5)
            coverage = floor(coverage * 51.0 + 0.5) / 51.0;
        return overlayComposite(in.bitmapTier, in.color.rgb, a * coverage, destination);
    }
    if (in.shapeKind < -0.5) {
        if (!mosaicSubcellLit(in)) {
            return overlayKeepDestination(in.bitmapTier, destination);
        }
        return overlayComposite(in.bitmapTier, in.color.rgb, a, destination);
    }
    if (in.shapeKind > 0.5) {
        // Analytic Powerline separator: compute feathered coverage from the
        // shape's signed distance in DEVICE PIXELS, so the diagonal / curved
        // edges are ~1 px antialiased (vs. the strip-fill stair-step). Unit
        // shape parameters (plA/plB) scale to pixels by the cell quad size.
        float2 sz = in.cellSizePixels;
        float2 p  = in.cellLocalPixels;
        float dist;                         // <0 inside, >0 outside (px)
        if (in.shapeKind > 6.5) {
            float2 center = in.plA.xy * sz;
            float2 radii = in.plA.zw * sz;
            float2 halfWidths = in.plB.xy * sz;
            float2 outerRadii = max(radii + halfWidths, float2(1e-3));
            float2 offset = max((p - center) * in.plB.zw, float2(0));
            float2 outerQ = offset / outerRadii;
            float outerLength = max(length(outerQ), 1e-4);
            dist = (outerLength - 1.0) * outerLength / max(length(outerQ / outerRadii), 1e-6);
            if (all(radii > halfWidths)) {
                float2 innerRadii = max(radii - halfWidths, float2(1e-3));
                float2 innerQ = offset / innerRadii;
                float innerLength = max(length(innerQ), 1e-4);
                float inner = (innerLength - 1.0) * innerLength / max(length(innerQ / innerRadii), 1e-6);
                dist = max(dist, -inner);
            }
        } else if (in.shapeKind < 2.5) {
            // Triangle (solid) or the round-capped capsule pair. plA=a,b ;
            // plB.xy=c.
            float2 va = in.plA.xy * sz;
            float2 vb = in.plA.zw * sz;
            float2 vc = in.plB.xy * sz;
            if (in.shapeKind < 1.5) {
                dist = plTriDist(p, va, vb, vc);          // solid
            } else {
                // Capsules a→b→c: nearest of the two segments, minus the
                // stroke half-width (unit-Y → px). The caps spill past the
                // endpoints so a stepped run of diagonals meets with no notch.
                float strokeHalf = in.plB.z * sz.y;
                float d = min(plSegDist(p, va, vb), plSegDist(p, vb, vc));
                dist = d - strokeHalf;
            }
        } else if (in.shapeKind > 4.5) {
            // Thin separators: the band from the shape's outer boundary
            // INWARD by the full stroke, so the boundary lines pass through
            // the cell corners / apex and the quad clip finishes the stroke
            // ends as points — the bundled face's construction.
            float2 va = in.plA.xy * sz;
            float2 vb = in.plA.zw * sz;
            float2 vc = in.plB.xy * sz;
            float strokeHalf = in.plB.z * sz.y;
            float outer;
            if (in.shapeKind < 5.5) {
                // Wedge (thin chevron): inside is the winding of the solid
                // triangle a,b,c with b the apex.
                float s = sign((vb.x - va.x) * (vc.y - va.y) - (vb.y - va.y) * (vc.x - va.x));
                outer = max(plLineDistInward(p, va, vb, s), plLineDistInward(p, vb, vc, s));
            } else {
                // Diagonal (thin corner wedge): one stroke along a→b banded
                // toward the witness c on the solid sibling's filled side.
                float s = sign((vb.x - va.x) * (vc.y - va.y) - (vb.y - va.y) * (vc.x - va.x));
                outer = plLineDistInward(p, va, vb, s);
            }
            dist = abs(outer + strokeHalf) - strokeHalf;
        } else {
            // Half-disc. plA=centre,radii (unit); plB.x=sideSign, plB.y=strokeHalf.
            float2 c  = in.plA.xy * sz;
            float2 r  = max(in.plA.zw * sz, float2(1e-3));
            float2 q  = (p - c) / r;
            // First-order ellipse distance: the implicit value over its own
            // gradient magnitude. Scaling by min(r) instead is exact only on a
            // circle — on the stretched cell's eccentric ellipse it thins the
            // stroke toward the flat ends and thickens it at the equator, so
            // the arc's weight visibly wobbles.
            float L = max(length(q), 1e-4);
            float grad = max(length(q / r), 1e-6);
            float ellipse = (L - 1.0) * L / grad;
            // Flat-side half-plane: keep sideSign*(x-cx) >= 0; its distance is
            // the signed perpendicular distance to the diameter line.
            float side = in.plB.x * (p.x - c.x);
            if (in.shapeKind < 3.5) {
                dist = max(ellipse, -side);               // filled half-disc
            } else {
                // Arc stroke: the band from the arc INWARD by the full
                // stroke — the arc is the outer boundary, as the face draws
                // it — kept to the sideSign half (discard the diameter chord).
                float strokeHalf = in.plB.y * sz.y;
                dist = max(abs(ellipse + strokeHalf) - strokeHalf, -side);
            }
        }
        // Device-px AA width from the SDF gradient (≈1 px), feathered.
        // The elliptical arc distance is in pixels; derivatives at its center
        // are singular and must not widen coverage into the empty interior.
        float aa = in.shapeKind > 6.5 ? 1.0 : max(fwidth(dist), 1e-3);
        // Bitmap tier: the software renderer feathers over a fixed one-pixel
        // ramp with no gradient normalisation (coverage = 0.5 - dist), so a
        // 45-degree edge covers the same pixels as an axis-aligned one there.
        // The bitmap tier holds the coverage to the 51 levels the software
        // renderer mixes at, before the quad's alpha scales it.
        float cov = in.bitmapTier > 0.5
            ? floor(clamp(0.5 - dist, 0.0, 1.0) * 51.0 + 0.5) / 51.0
            : clamp(0.5 - dist / aa, 0.0, 1.0);
        if (cov <= 0.0)
            return overlayKeepDestination(in.bitmapTier, destination);
        return overlayComposite(in.bitmapTier, in.color.rgb, a * cov, destination);
    }
    if (in.shadeDensity > 0.0) {
        // A pattern shade (Core/Rendering/ShadeStyle.h, isShadePixelLit): a
        // quarter, half or three quarters of the device pixels lit SOLID in
        // the foreground, keyed on the surface pixel plus Core's grid phase in
        // plA.x so the field stitches across cell edges. The unlit pixels keep
        // what the cell pass stored. A fill shade never reaches here: Core
        // emits it as a plain rect at the shade's alpha.
        int lit = int(in.shadeDensity * 4.0 + 0.5);
        int phase = int(in.plA.x + 0.5);
        int2 p = int2(floor(in.position.xy));
        if (((p.x + 2 * p.y + phase) & 3) >= lit)
            return overlayKeepDestination(in.bitmapTier, destination);
        return overlayComposite(in.bitmapTier, in.color.rgb, a, destination);
    }
    if (in.strokeWidth > 0.0) {
        // Hollow outline: signed-distance box, keep the [-strokeWidth, 0] band.
        float2 d = abs(in.localPixels) - in.halfSizeInPixels + in.cornerRadius;
        float dist = min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - in.cornerRadius;
        float sd = abs(dist + in.strokeWidth * 0.5) - in.strokeWidth * 0.5;
        // Bitmap tier: the software renderer's hollow outline is a hard ring
        // — a pixel whose centre is inside the band is drawn whole, one
        // outside it not at all — never a feathered one.
        a *= in.bitmapTier > 0.5 ? (sd < 0.0 ? 1.0 : 0.0) : clamp(0.5 - sd, 0.0, 1.0);
    } else if (in.cornerRadius > 0.0) {
        // Rounded-rect SDF: distance to the box shrunk by r, then re-inflated by
        // r; ~1 px antialiased edge. Sharp rect when r == 0.
        //
        // The norm is what decides the corner's shape. length() is the L2 norm,
        // a circular arc that meets the straight edges at a tangent and jumps
        // from zero curvature to 1/r there. A continuous corner is a
        // superellipse: a higher-order norm curves into the edges, which is the
        // corner macOS draws everywhere and the one an arc looks pasted on
        // beside. Exponent 4 is the usual approximation — close enough that the
        // difference from Apple's own curve is under a pixel at these radii, and
        // cheap enough for a fragment that runs per overlay pixel.
        float2 d = max(abs(in.localPixels) - (in.halfSizeInPixels - in.cornerRadius), 0.0);
        float reach = in.cornerStyle > 0.5
            ? pow(pow(d.x, 4.0) + pow(d.y, 4.0), 0.25)
            : length(d);
        float dist = reach - in.cornerRadius;
        float cov = clamp(0.5 - dist, 0.0, 1.0);
        // Held to 51 levels in the bitmap tier, as the software renderer holds it.
        a *= in.bitmapTier > 0.5 ? floor(cov * 51.0 + 0.5) / 51.0 : cov;
    }
    return overlayComposite(in.bitmapTier, in.color.rgb, a, destination);
}

// The bitmap tier's entry point: it reads the target and returns the finished
// byte, so its pipeline replaces rather than blends.
fragment float4 secondaryMarginFragment(OverlayOut in [[stage_in]])
{
    return float4(0);
}

fragment float4 overlayFragment(OverlayOut in [[stage_in]],
                                float4 destination [[color(0)]])
{
    if (in.color.a < 0.0 || in.usesBackgroundColors != 0) {
        discard_fragment();
    }
    return overlayShade(in, destination);
}

// The blending entry point, declaring no colour attachment because no branch
// it reaches reads one. An implementation that refuses framebuffer reads
// refuses to build a pipeline that declares one; the state then resolves to
// nil and the encoder skips that pass without reporting it, so the whole
// overlay tier — underline, strike, selection, search pill — leaves the frame
// while the render still reports success.
fragment float4 overlayFragmentBlended(OverlayOut in [[stage_in]])
{
    if (in.color.a < 0.0 || in.usesBackgroundColors != 0) {
        discard_fragment();
    }
    return overlayShade(in, float4(0.0));
}

// The margin restore, blending off: a strip resets a rebuilt row's overhang
// margins to the ground, so it stores the byte the clear stores — the
// premultiplied background on a whole code, as a bare cell stores it. Core
// premultiplies the strip's colour; the rounding is this stage's. Handed a
// colour between two codes, the target's encode may land on either, and the
// clear it stands in for is rounded before it is stored
// (TerminalRenderer.premultipliedClear): a strip stored unrounded can differ
// by a code from the clear a full rebuild leaves in the same pixels.
fragment float4 marginRestoreFragment(OverlayOut in [[stage_in]])
{
    return float4(srgbToLinear(round(in.color.rgb * 255.0) / 255.0), round(in.color.a * 255.0) / 255.0);
}

// The bitmap tier's overlays where the target cannot be read: colour and
// coverage for a straight-alpha hardware blend (see unreadDestination).
fragment float4 overlayFragmentUnread(OverlayOut in [[stage_in]])
{
    if (in.color.a < 0.0 || in.usesBackgroundColors != 0) {
        discard_fragment();
    }
    return overlayShade(in, unreadDestination);
}

// The focused pill's shadow, drawn before the overlays in the encoded pass
// where the target cannot be read; every other overlay waits for that pass.
fragment float4 encodedOverlayFragmentUnreadShadow(OverlayOut in [[stage_in]])
{
    if (in.color.a < 0.0 || in.usesBackgroundColors != 0 || in.shapeKind >= -2.5) {
        discard_fragment();
    }
    float4 shaded = overlayShade(in, unreadShadowDestination);
    return float4(linearToSrgb(shaded.rgb), shaded.a);
}

// The bitmap tier's overlays where the target cannot be read, drawn into a
// linear-format view of the target so the hardware blend mixes the stored sRGB
// bytes, as the software renderer's integer overlay mix does. The colour goes
// out encoded for that view.
fragment float4 encodedOverlayFragmentUnread(OverlayOut in [[stage_in]])
{
    if (in.color.a < 0.0 || in.usesBackgroundColors != 0) {
        discard_fragment();
    }
    float4 shaded = overlayShade(in, unreadDestination);
    return float4(linearToSrgb(shaded.rgb), shaded.a);
}

fragment float4 encodedOverlayFragment(OverlayOut in [[stage_in]])
{
    if (in.color.a < 0.0 || in.usesBackgroundColors != 0) {
        discard_fragment();
    }
    float4 shaded = overlayShade(in, float4(0.0), true);
    return float4(linearToSrgb(shaded.rgb), shaded.a);
}

fragment float4 secondaryOverlayFragment(OverlayOut in [[stage_in]])
{
    if (in.color.a >= 0.0 || in.usesBackgroundColors != 0) {
        discard_fragment();
    }
    in.color.a = -in.color.a;
    in.bitmapTier = 0;
    float coverage = overlayShade(in, float4(0)).a;
    return float4(srgbToLinear(in.color.rgb * coverage), coverage);
}

static float4 nativeBackgroundPixel(float4 color, constant Uniforms& u)
{
    float totalCoverage = max(0.0, -color.a);
    float tintCoverage = min(u.backgroundOpacity, totalCoverage);
    float coverage = tintCoverage < 1.0 ? (totalCoverage - tintCoverage) / (1.0 - tintCoverage) : 0.0;
    return float4(srgbToLinear(coverage * color.rgb), coverage);
}

static float4 ordinaryBackgroundPixel(float4 color, constant Uniforms& u)
{
    float coverage = color.a < 0.0 ? min(u.backgroundOpacity, -color.a) : color.a;
    return float4(srgbToLinear(premultipliedBackgroundByte(color.rgb, coverage)), coverage);
}

static float backgroundTransitionCoverage(OverlayOut in)
{
    in.color.a = in.foregroundCoverage;
    in.bitmapTier = 0;
    return overlayShade(in, float4(0)).a;
}

fragment float4 backgroundTransitionFragment(OverlayOut in [[stage_in]],
                                             constant Uniforms& u [[buffer(0)]])
{
    if (in.usesBackgroundColors == 0) {
        discard_fragment();
    }
    // Both sides replace the full cell. Source-over would accumulate the two
    // tints inside the shape and leave a seam against the adjacent solid fill.
    return mix(ordinaryBackgroundPixel(in.background, u), ordinaryBackgroundPixel(in.color, u),
        backgroundTransitionCoverage(in));
}

fragment float4 nativeBackgroundTransitionFragment(OverlayOut in [[stage_in]],
                                                   constant Uniforms& u [[buffer(0)]])
{
    if (in.usesBackgroundColors == 0) {
        discard_fragment();
    }
    return mix(nativeBackgroundPixel(in.background, u), nativeBackgroundPixel(in.color, u),
        backgroundTransitionCoverage(in));
}

struct DecorationOut {
    float4 position [[position]];
    float  bitmapTier [[flat]]; // Uniforms.bitmapTier, carried so the fragment needs no buffer of its own
    float3 colorEncoded [[flat]]; // the rule colour as authored (sRGB-encoded), for the bitmap tier's mix
    float4 color; // rgb LINEAR (converted in the vertex stage), a as authored
    float2 localPositionInPixels;      // pixel offset from the rule's top-left corner
    float2 sizeInPixels;       // rule rect size in pixels
    float  kind;
    float  dashPeriodInPixels;
    float  thicknessInPixels;
    float  skipInk;
    float2 inkUV;        // glyph cell-box atlas UV at this fragment's band
    float2 padInAtlas;        // skip-ink dilation radius (atlas UV)
    float  padSteps;     // taps per side across the radius (scales with pad px)
    float  sheetMask;    // base-8 digits: the sheet the self, left and right taps read
    float2 glyphSlotTopLeftUV;       // glyph atlas-slot UV clamp rect (flat — no neighbour bleed)
    float2 glyphSlotBottomRightUV;
    float4 leftInk;      // left/right neighbour glyph (cross-cell skip-ink); see
    float4 leftBox;      // DecorationInstance for the field layout
    float4 rightInk;
    float4 rightBox;
};

vertex DecorationOut decorationVertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      constant Uniforms& u [[buffer(0)]],
                                      constant DecorationInstance* decos [[buffer(1)]])
{
    DecorationInstance d = decos[iid];
    float2 corner = quadCorners[vid];
    float2 sizeInPixels = d.bottomRightInPixels - d.topLeftInPixels;
    float2 positionInPixels = d.topLeftInPixels + corner * sizeInPixels;

    DecorationOut out;
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.bitmapTier = float(u.bitmapTier);
    out.colorEncoded = d.color.rgb;
    // Linear at the vertex, not per pixel: the rule's colour is the instance's, the same at
    // every pixel of the quad, and the conversion is three pow() calls. The alpha rides
    // along unconverted, which is what the fragment reads it as.
    out.color = float4(srgbToLinear(d.color.rgb), d.color.a);
    out.localPositionInPixels = corner * sizeInPixels;
    out.sizeInPixels = sizeInPixels;
    out.kind = d.kind;
    out.dashPeriodInPixels = d.dashPeriodInPixels;
    out.thicknessInPixels = d.thicknessInPixels;
    out.skipInk = d.skipInk;
    // inkTopLeft/inkBottomRight are the glyph cell-box atlas-UV corners spanning the
    // rule's rect (u across the cell width, v across the rule's height), so
    // interpolating per-axis gives this fragment the glyph UV at its actual
    // 2D position — the skip-ink cut then follows the letter outline.
    out.inkUV = float2(mix(d.inkTopLeft.x, d.inkBottomRight.x, corner.x),
                       mix(d.inkTopLeft.y, d.inkBottomRight.y, corner.y));
    out.padInAtlas = d.padInAtlas;
    out.padSteps = d.pad1.x;
    out.sheetMask = d.pad1.y;
    out.glyphSlotTopLeftUV = d.glyphSlotTopLeftUV;
    out.glyphSlotBottomRightUV = d.glyphSlotBottomRightUV;
    out.leftInk = d.leftInk;
    out.leftBox = d.leftBox;
    out.rightInk = d.rightInk;
    out.rightBox = d.rightBox;
    return out;
}

// Max glyph coverage in a disc of radius padInAtlas (2N+1 taps per side) around
// baseUV, clamped to [glyphSlotTopLeftUV, glyphSlotBottomRightUV] — the glyph's own atlas slot. Taps
// outside the slot contribute nothing (they'd sample a neighbour glyph), so
// the gap widens up to this glyph's own ink at any pad. glyphSlotBottomRightUV.x <= glyphSlotTopLeftUV.x
// marks an absent source (e.g. a blank cell or off-grid neighbour) → 0.
static float inkCoverageDisc(texture2d<float> atlas, sampler atlasSampler,
                             float2 baseUV, float2 padInAtlas, int steps,
                             float2 glyphSlotTopLeftUV, float2 glyphSlotBottomRightUV)
{
    if (glyphSlotBottomRightUV.x <= glyphSlotTopLeftUV.x)
        return 0.0;
    float cov = 0.0;
    float2 stepUV = padInAtlas / float(steps);
    for (int dy = -steps; dy <= steps; ++dy) {
        for (int dx = -steps; dx <= steps; ++dx) {
            // Round the square grid to a disc so the halo radius is uniform
            // (a square would over-cut diagonally by ~1.4x).
            if (dx * dx + dy * dy > steps * steps)
                continue;
            float2 uv = baseUV + float2(float(dx), float(dy)) * stepUV;
            if (uv.x < glyphSlotTopLeftUV.x || uv.x > glyphSlotBottomRightUV.x
                || uv.y < glyphSlotTopLeftUV.y || uv.y > glyphSlotBottomRightUV.y)
                continue;
            cov = max(cov, atlas.sample(atlasSampler, atlasNormalized(atlas, uv)).r);
        }
    }
    return cov;
}

static float inkCoverageDiscForSheet(int sheetSelector,
                                     texture2d<float> monoSheet,
                                     texture2d<float> proportionalStripSheet,
                                     texture2d<float> ligatureStripSheet,
                                     texture2d<float> proportionalSheet,
                                     texture2d<float> wideSheet,
                                     sampler atlasSampler,
                                     float2 baseUV, float2 padInAtlas, int steps,
                                     float2 glyphSlotTopLeftUV, float2 glyphSlotBottomRightUV)
{
    if (sheetSelector == 1) {
        return inkCoverageDisc(proportionalStripSheet, atlasSampler, baseUV, padInAtlas,
                               steps, glyphSlotTopLeftUV, glyphSlotBottomRightUV);
    }
    if (sheetSelector == 2) {
        return inkCoverageDisc(ligatureStripSheet, atlasSampler, baseUV, padInAtlas,
                               steps, glyphSlotTopLeftUV, glyphSlotBottomRightUV);
    }
    if (sheetSelector == 3) {
        return inkCoverageDisc(proportionalSheet, atlasSampler, baseUV, padInAtlas,
                               steps, glyphSlotTopLeftUV, glyphSlotBottomRightUV);
    }
    if (sheetSelector == 4) {
        return inkCoverageDisc(wideSheet, atlasSampler, baseUV, padInAtlas,
                               steps, glyphSlotTopLeftUV, glyphSlotBottomRightUV);
    }
    return inkCoverageDisc(monoSheet, atlasSampler, baseUV, padInAtlas,
                           steps, glyphSlotTopLeftUV, glyphSlotBottomRightUV);
}

// The software renderer's skip-ink cut, for the bitmap tier: the same disc
// of taps as the real-font cut, read nearest — the CPU truncates each tap's
// coordinate to a texel — and clamped to the sheet's edge. On a bitmap face
// bilinear taps are a difference between the arms, not a refinement.
// A linear sampler at a texel centre returns that texel exactly, which is how
// nearest is had without a second sampler.
static float inkCoverageSoftwareTaps(texture2d<float> sheet, sampler sheetSampler,
                                     float2 baseUV, float2 padInAtlas, int steps,
                                     float2 glyphSlotTopLeftUV, float2 glyphSlotBottomRightUV)
{
    if (glyphSlotBottomRightUV.x <= glyphSlotTopLeftUV.x)
        return 0.0;
    float2 size = float2(sheet.get_width(), sheet.get_height());
    float2 stepUV = padInAtlas / float(steps);
    float cov = 0.0;
    for (int dy = -steps; dy <= steps; ++dy) {
        for (int dx = -steps; dx <= steps; ++dx) {
            if (dx * dx + dy * dy > steps * steps)
                continue;
            // SoftwareRenderer's skipInkTapBias: off the texel grid, where the
            // interpolated coordinate and the CPU's round to different sides.
            float2 uv = baseUV + float2(float(dx), float(dy)) * stepUV + 1.0 / 128.0;
            // Only the glyph's own slot answers, as the CPU culls: a tap past
            // the slot's edge would read the glyph packed beside it.
            if (uv.x < glyphSlotTopLeftUV.x || uv.x > glyphSlotBottomRightUV.x
                || uv.y < glyphSlotTopLeftUV.y || uv.y > glyphSlotBottomRightUV.y)
                continue;
            uv = clamp(floor(uv) + 0.5, float2(0.5), size - 0.5);
            cov = max(cov, sheet.sample(sheetSampler, uv / size).r);
        }
    }
    return cov;
}

static float inkCoverageSoftwareTapsForSheet(int sheetSelector,
                                             texture2d<float> monoSheet,
                                             texture2d<float> proportionalStripSheet,
                                             texture2d<float> ligatureStripSheet,
                                             texture2d<float> proportionalSheet,
                                             sampler atlasSampler,
                                             float2 baseUV, float2 padInAtlas, int steps,
                                             float2 glyphSlotTopLeftUV, float2 glyphSlotBottomRightUV)
{
    if (sheetSelector == 1)
        return inkCoverageSoftwareTaps(proportionalStripSheet, atlasSampler, baseUV, padInAtlas, steps,
                                       glyphSlotTopLeftUV, glyphSlotBottomRightUV);
    if (sheetSelector == 2)
        return inkCoverageSoftwareTaps(ligatureStripSheet, atlasSampler, baseUV, padInAtlas, steps,
                                       glyphSlotTopLeftUV, glyphSlotBottomRightUV);
    if (sheetSelector == 3)
        return inkCoverageSoftwareTaps(proportionalSheet, atlasSampler, baseUV, padInAtlas, steps,
                                       glyphSlotTopLeftUV, glyphSlotBottomRightUV);
    return inkCoverageSoftwareTaps(monoSheet, atlasSampler, baseUV, padInAtlas, steps,
                                   glyphSlotTopLeftUV, glyphSlotBottomRightUV);
}

// Decoration fragment: emits the rule's color, masked by `kind`, then
// (for underline rules with skipInk set) cut where glyph ink crosses the
// underline band.
//  - Solid: full coverage (single/double rule, overline, strike, box).
//  - Dotted/dashed: an on/off duty cycle along x, period scales with stroke thickness.
//  - Curly: a sine wave whose stroke is `thicknessInPixels` tall, centered in the
//    rule rect; coverage = distance of this fragment's y from the wave.
// The decoration body, shared by the two entry points below. As with the
// overlay, `destination` is read only on the bitmap tier.
static float4 decorationShade(DecorationOut in,
                              texture2d<float> atlas,
                              texture2d<float> proportionalStripSheet,
                              texture2d<float> ligatureStripSheet,
                              texture2d<float> proportionalSheet,
                              texture2d<float> wideSheet,
                              sampler atlasSampler,
                              float4 destination)
{
    float alpha = in.color.a;
    if (in.kind == decorationDotted) {
        // Round dots: substantial BALLS, not specks. The radius fills the band
        // (the emit side sizes the band to the dot diameter), and the period is
        // derived from the radius (dot + an equal gap) so dots and gaps stay
        // balanced as the stroke scales — with a cell-relative floor so the
        // dots can't pack into a near-solid rule at thin strokes. Anchoring the
        // period to the radius (not a bare cell fraction) is what keeps the
        // balls big; the period-only fix in 1aed85c2 had shrunk them to ~1px.
        float r = max(in.sizeInPixels.y * 0.5, 1.0);
        // Period = half the cell → exactly two dots per cell, so the grid divides
        // the cell evenly and scales with the font (cellWidth grows with point size).
        // Phased per-cell (cell-local x): each dot sits at a quarter point
        // (0.25 / 0.75 of the cell), fully inside the cell's rect — so a run's
        // first dot starts cleanly on the left instead of being clipped to a
        // half-ball, and even spacing falls out for free since every cell is
        // identical. The radius floor keeps dot+gap separated in narrow cells.
        float period = max(in.dashPeriodInPixels * 0.5, r * 3.0);
        float lx = in.localPositionInPixels.x;
        float cx = (floor(lx / period) + 0.5) * period;
        float dx = lx - cx;
        float dy = in.localPositionInPixels.y - in.sizeInPixels.y * 0.5;
        float d = length(float2(dx, dy));
        alpha *= clamp(r + 0.5 - d, 0.0, 1.0);
    } else if (in.kind == decorationDashed) {
        // One dash per cell at 65% duty: a long mark (0.65 cell) with a 0.35-cell
        // gap. Cell-locked (cell-local x) so every dash is identical and the gaps
        // align to the grid — a uniform broken *line*, distinguishable at a glance from the
        // round dots (two per cell). Scales with the font since the period is the
        // cell. The stroke floor guards a degenerate period in very narrow cells.
        float period = max(in.dashPeriodInPixels, in.thicknessInPixels * 6.0);
        float phase = fract(in.localPositionInPixels.x / period);
        if (phase >= 0.65) alpha = 0.0;
        // A dash's band is the stroke itself, so the band's height is the
        // weight the thickness setting asks for. Sampling at pixel centers
        // alone answers only in whole rows, quantizing that weight to the pixel
        // grid; taking the fraction of its own row that the band covers makes
        // the summed weight the band's height exactly, at any sub-pixel size.
        // The other kinds draw a shape within a band built with slack and take
        // their edge softness from that shape's own falloff.
        float rowTop = max(in.localPositionInPixels.y - 0.5, 0.0);
        float rowBottom = min(in.localPositionInPixels.y + 0.5, in.sizeInPixels.y);
        alpha *= max(rowBottom - rowTop, 0.0);
    } else if (in.kind == decorationCurly) {
        // One sine cycle per cell. The wave's centerline rides the middle
        // of the rule rect; amplitude leaves room for the stroke so the
        // curl stays inside the rect. Coverage falls off within half the
        // stroke thickness of the wave, anti-aliased by one pixel.
        float period = max(in.dashPeriodInPixels, 2.0);
        // Heavier than half the stroke: a diagonal wave sampled by vertical
        // distance looks thinner than a flat rule of the same weight on its
        // slopes, so over-weight it to read as solid as the single underline.
        float halfThick = in.thicknessInPixels * 0.8;
        float amp = max(in.sizeInPixels.y * 0.5 - halfThick, 0.5);
        float mid = in.sizeInPixels.y * 0.5;
        float wave = mid + amp * sin(in.localPositionInPixels.x / period * 6.2831853);
        float dist = abs(in.localPositionInPixels.y - wave);
        alpha *= clamp(halfThick + 0.5 - dist, 0.0, 1.0);
    }

    // Skip-ink: dilate the glyph coverage at the underline band by padInAtlas
    // and cut the rule wherever ink (with its halo) lands, so descenders
    // break the line cleanly. A (2N+1)x(2N+1) tap grid spanning ±padInAtlas
    // approximates a disc-dilation of the coverage mask; the strongest tap
    // drives the cut. N (padSteps) scales with the pad radius in pixels so
    // the taps stay ~1px apart — a fixed 3x3 grid would leave gaps between
    // taps once the radius grew past a pixel, breaking the cut into stripes
    // instead of widening it. The cut runs against this cell's glyph and its
    // two neighbours, so a descender's halo can reach across the cell edge
    // (a per-cell rule can't otherwise break for an adjacent cell's ink).
    if (in.skipInk > 0.5 && in.bitmapTier > 0.5) {
        // Bitmap tier: the portable renderer's cut, texel for texel, from the
        // sheets the low, middle and high base-8 digits select for this cell
        // and its left and right neighbours. A bitmap face never reaches the
        // two-cell sheet's digit: its taps are only made on a phased frame.
        int steps = max(int(in.padSteps + 0.5), 1);
        int selectors = int(in.sheetMask + 0.5);
        float fx = (in.sizeInPixels.x > 0.0) ? in.localPositionInPixels.x / in.sizeInPixels.x : 0.0;
        float fy = (in.sizeInPixels.y > 0.0) ? in.localPositionInPixels.y / in.sizeInPixels.y : 0.0;
        float cov = inkCoverageSoftwareTapsForSheet(selectors % 8, atlas, proportionalStripSheet, ligatureStripSheet,
                                                    proportionalSheet, atlasSampler, in.inkUV, in.padInAtlas, steps,
                                                    in.glyphSlotTopLeftUV, in.glyphSlotBottomRightUV);
        float2 lUV = float2(in.leftInk.x + (fx + 1.0) * (in.leftInk.y - in.leftInk.x),
                            mix(in.leftInk.z, in.leftInk.w, fy));
        cov = max(cov, inkCoverageSoftwareTapsForSheet((selectors / 8) % 8, atlas, proportionalStripSheet,
                                                       ligatureStripSheet, proportionalSheet, atlasSampler, lUV,
                                                       in.padInAtlas, steps, in.leftBox.xy, in.leftBox.zw));
        float2 rUV = float2(in.rightInk.x + (fx - 1.0) * (in.rightInk.y - in.rightInk.x),
                            mix(in.rightInk.z, in.rightInk.w, fy));
        cov = max(cov, inkCoverageSoftwareTapsForSheet((selectors / 64) % 8, atlas, proportionalStripSheet,
                                                       ligatureStripSheet, proportionalSheet, atlasSampler, rUV,
                                                       in.padInAtlas, steps, in.rightBox.xy, in.rightBox.zw));
        alpha *= clamp(1.0 - cov, 0.0, 1.0);
    } else if (in.skipInk > 0.5) {
        int steps = max(int(in.padSteps + 0.5), 1);
        // This fragment's fraction across the rule rect. The neighbour glyphs
        // share this cell's width, so the same fraction shifted by ±1 cell
        // lands at the matching point in the neighbour's cell box.
        float fx = (in.sizeInPixels.x > 0.0)
            ? in.localPositionInPixels.x / in.sizeInPixels.x : 0.0;
        float fy = (in.sizeInPixels.y > 0.0)
            ? in.localPositionInPixels.y / in.sizeInPixels.y : 0.0;
        // Each tap reads the sheet that holds the ink the cell DRAWS: a cell a
        // ligature run covers draws its slice of the strip, and its glyph in
        // the mono sheet — the default form, at the cell's own phase — is not
        // on screen. A cut placed by that form sits beside the stem it should
        // split.
        int selectors = int(in.sheetMask + 0.5);
        int ownSheet = selectors % 8;
        int leftSheet = (selectors / 8) % 8;
        int rightSheet = (selectors / 64) % 8;
        // Own glyph: sample at this fragment's interpolated cell-box UV.
        float cov = inkCoverageDiscForSheet(ownSheet, atlas, proportionalStripSheet,
                                            ligatureStripSheet, proportionalSheet, wideSheet, atlasSampler, in.inkUV,
                                            in.padInAtlas, steps, in.glyphSlotTopLeftUV,
                                            in.glyphSlotBottomRightUV);
        // Left neighbour: a point fx of the way across this cell is (fx + 1) of
        // the way across the left cell, so map it into the left cell box. Only
        // taps that fall inside the left slot (near the shared edge) survive.
        float2 lUV = float2(in.leftInk.x + (fx + 1.0) * (in.leftInk.y - in.leftInk.x),
                            mix(in.leftInk.z, in.leftInk.w, fy));
        cov = max(cov, inkCoverageDiscForSheet(leftSheet, atlas, proportionalStripSheet,
                                               ligatureStripSheet, proportionalSheet, wideSheet, atlasSampler, lUV,
                                               in.padInAtlas, steps, in.leftBox.xy, in.leftBox.zw));
        // Right neighbour: (fx - 1) of the way across the right cell.
        float2 rUV = float2(in.rightInk.x + (fx - 1.0) * (in.rightInk.y - in.rightInk.x),
                            mix(in.rightInk.z, in.rightInk.w, fy));
        cov = max(cov, inkCoverageDiscForSheet(rightSheet, atlas, proportionalStripSheet,
                                               ligatureStripSheet, proportionalSheet, wideSheet, atlasSampler, rUV,
                                               in.padInAtlas, steps, in.rightBox.xy, in.rightBox.zw));
        alpha *= clamp(1.0 - cov, 0.0, 1.0);
    }
    if (in.bitmapTier > 0.5) {
        // Bitmap tier: the portable renderer is the reference, and it
        // composites a rule edge in the ENCODED domain, rounded half up. The
        // hardware blend on the sRGB target would mix in linear light and land
        // a different byte on every partial-coverage pixel — the one place the
        // two rasterisers disagreed. So this pipeline blends nothing: the
        // fragment reads the byte the target holds, mixes as the CPU does, and
        // returns it decoded so the sRGB store encodes it back to that byte.
        // A real font never comes here; its pass keeps the system's own blend.
        float3 destinationEncoded = round(linearToSrgb(destination.rgb) * 255.0) / 255.0;
        // Held to the 51 coverage levels the software renderer mixes at, so a
        // sin or sqrt a millionth apart cannot round a byte the other way.
        alpha = floor(alpha * 51.0 + 0.5) / 51.0;
        if (destinationIsUnread(destination))
            return float4(srgbToLinear(in.colorEncoded), alpha);
        float3 stored = softwareRuleMixByte(destinationEncoded, in.colorEncoded, alpha);
        return float4(srgbToLinear(stored), 1.0);
    }
    return float4(in.color.rgb, alpha); // already linear, converted once per quad
}

fragment float4 decorationFragment(DecorationOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]],
                                   texture2d<float> proportionalStripSheet [[texture(1)]],
                                   texture2d<float> ligatureStripSheet [[texture(2)]],
                                   texture2d<float> proportionalSheet [[texture(3)]],
                                   texture2d<float> wideSheet [[texture(4)]],
                                   sampler atlasSampler [[sampler(0)]],
                                   float4 destination [[color(0)]])
{
    return decorationShade(in, atlas, proportionalStripSheet, ligatureStripSheet, proportionalSheet,
                           wideSheet, atlasSampler, destination);
}

fragment float4 decorationFragmentBlended(DecorationOut in [[stage_in]],
                                          texture2d<float> atlas [[texture(0)]],
                                          texture2d<float> proportionalStripSheet [[texture(1)]],
                                          texture2d<float> ligatureStripSheet [[texture(2)]],
                                          texture2d<float> proportionalSheet [[texture(3)]],
                                          texture2d<float> wideSheet [[texture(4)]],
                                          sampler atlasSampler [[sampler(0)]])
{
    return decorationShade(in, atlas, proportionalStripSheet, ligatureStripSheet, proportionalSheet,
                           wideSheet, atlasSampler, float4(0.0));
}

// The bitmap tier's rules where the target cannot be read (see
// unreadDestination).
fragment float4 decorationFragmentUnread(DecorationOut in [[stage_in]],
                                         texture2d<float> atlas [[texture(0)]],
                                         texture2d<float> proportionalStripSheet [[texture(1)]],
                                         texture2d<float> ligatureStripSheet [[texture(2)]],
                                         texture2d<float> proportionalSheet [[texture(3)]],
                                         texture2d<float> wideSheet [[texture(4)]],
                                         sampler atlasSampler [[sampler(0)]])
{
    return decorationShade(in, atlas, proportionalStripSheet, ligatureStripSheet, proportionalSheet,
                           wideSheet, atlasSampler, unreadDestination);
}

// The bitmap tier's rules where the target cannot be read, drawn into a
// linear-format view of the target so the blend mixes the encoded bytes, as
// the software renderer's rule mix does.
fragment float4 decorationFragmentUnreadEncoded(DecorationOut in [[stage_in]],
                                                texture2d<float> atlas [[texture(0)]],
                                                texture2d<float> proportionalStripSheet [[texture(1)]],
                                                texture2d<float> ligatureStripSheet [[texture(2)]],
                                                texture2d<float> proportionalSheet [[texture(3)]],
                                                texture2d<float> wideSheet [[texture(4)]],
                                                sampler atlasSampler [[sampler(0)]])
{
    float4 shaded = decorationShade(in, atlas, proportionalStripSheet, ligatureStripSheet, proportionalSheet,
                                    wideSheet, atlasSampler, unreadDestination);
    return float4(linearToSrgb(shaded.rgb), shaded.a);
}

struct GlyphOut {
    float4 position [[position]];
    float2 atlasUV;
    float4 foreground;
    float4 background;
    // Below here: values derived from the instance and the uniforms alone, on
    // the same rule as VertexOut's. `resL` in the fragment stays there because
    // it moves with the coverage sample, which is what makes it per-pixel.
    float3 foregroundLinear;
    // The destination the cell pass painted under this glyph: the
    // premultiplied background byte, decoded, and its opacity.
    float3 storedBackground;
    float3 storedBackgroundLinear;
    float  backgroundOpacity;
    // The glyph box this instance samples, in atlas pixels, so the coverage tap
    // can be held inside it. Flat: it is the instance's own rect, not a corner
    // mix.
    float2 atlasBoxTopLeft [[flat]];
    float2 atlasBoxBottomRight [[flat]];
};

vertex GlyphOut glyphVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]],
                            constant GlyphInstance* glyphs [[buffer(1)]])
{
    GlyphInstance g = glyphs[iid];
    float2 corner = quadCorners[vid];
    float2 positionInPixels = g.originInPixels + corner * g.sizeInPixels;

    GlyphOut out;
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.atlasUV = mix(g.atlasTopLeft, g.atlasBottomRight, corner);
    out.atlasBoxTopLeft = g.atlasTopLeft;
    out.atlasBoxBottomRight = g.atlasBottomRight;
    out.foreground = g.foreground;
    out.background = g.background;
    out.foregroundLinear = srgbToLinear(g.foreground.rgb);
    float o = g.background.a < 0.0 ? min(u.backgroundOpacity, -g.background.a) : g.background.a;
    out.backgroundOpacity = o;
    out.storedBackground = premultipliedBackgroundByte(g.background.rgb, o);
    out.storedBackgroundLinear = srgbToLinear(out.storedBackground);
    return out;
}

// The glyph pass's two outputs, for dual-source blending: `color` is the
// premultiplied linear foreground, `factor` the per-channel coverage the
// blend multiplies the destination's complement by.
struct GlyphFragmentOut {
    float4 color [[color(0), index(0)]];
    float4 factor [[color(0), index(1)]];
};

fragment GlyphFragmentOut glyphFragment(GlyphOut in [[stage_in]],
                                        constant Uniforms& u [[buffer(0)]],
                                        texture2d<float> atlas [[texture(0)]],
                                        sampler atlasSampler [[sampler(0)]])
{
    if (in.foreground.a < 0.0) {
        GlyphFragmentOut transparent;
        transparent.color = float4(0.0);
        transparent.factor = float4(0.0);
        return transparent;
    }
    // The bitmap tier takes the coverage tap the cell pass takes, over this
    // instance's own glyph box: the texel the interpolated coordinate names,
    // held inside the box. The box bounds it because this tier's slots are cut
    // touching, and a quad that does not cover its box one for one — a sized
    // block, a doubled row's half, a cell the grid trimmed at its edge — lands
    // the tap between two texels, the outer of which is the neighbouring
    // glyph's last column. Half of that column beside the letter is a stray
    // stroke, at whatever rows the neighbour inks. A CoreText sheet keeps the
    // linear tap: it is antialiased and its slots carry a margin, so an
    // intermediate coverage is a real one and the texel outside the box is that
    // glyph's own blank.
    float coverage = u.bitmapTier != 0
        ? atlasTexelCoverage(atlas, atlasSampler, in.atlasUV, in.atlasBoxTopLeft, in.atlasBoxBottomRight)
        : atlas.sample(atlasSampler, atlasNormalized(atlas, in.atlasUV)).r;
    // This pass blends linear foreground over the background the cell pass
    // painted. The byte wanted in each channel is the encoded mix CoreGraphics
    // writes; a linear over-blend reaches it with a coverage of its own per
    // channel, (target - bg) / (fg - bg) in linear light, which one scalar
    // alpha cannot give coloured text — the channels' transfer slopes differ.
    // Dual-source blending carries the three factors: dst' = color + dst *
    // (1 - factor), and with dst the cell's own background the result is the
    // target to float precision. A channel where the two colours coincide has
    // no slope to solve against and takes the mask as it is.
    // The destination is the premultiplied background byte the cell pass
    // stored, which is the cell's colour at an opaque cell and less under a
    // translucent one; the target is CoreGraphics' premultiplied mix over it,
    // and the solve below lands the stored byte on that target either way.
    if (u.bitmapTier != 0) {
        // Bitmap tier: the software renderer does not blend a glyph over the
        // frame — writeMixedPixel REPLACES the pixel with the cell's own
        // straight background and foreground mixed by the coverage, alpha
        // mixed toward opaque by the same coverage. So this pipeline blends
        // nothing and the second colour output is unused; the dual-source
        // solve below is CoreText's, for a real font.
        //
        // A pixel the mask does not cover is left alone, as that loop's
        // `coverage == 0` skip leaves it: this pipeline replaces rather than
        // blends, so writing the cell's background there would paint it over
        // whatever the neighbours drew. A quad taller than its cell — a
        // proportional strip, whose slot holds the face's descenders — is
        // where that shows, as a step of background along the run.
        if (coverage <= 0.0)
            discard_fragment();
        GlyphFragmentOut replaced;
        replaced.color = softwareCellPixel(in.background.rgb, in.foreground.rgb, coverage * in.foreground.a, in.backgroundOpacity);
        replaced.factor = float4(1.0);
        return replaced;
    }
    float3 fgS = in.foreground.rgb;
    float3 targetL = srgbToLinear(coreGraphicsTextMixPremultiplied(fgS, in.storedBackground, coverage));
    float3 bgL = in.storedBackgroundLinear, fgL = in.foregroundLinear;
    float3 span = fgL - bgL;
    float3 factor = select(clamp((targetL - bgL) / span, 0.0, 1.0), float3(coverage), abs(span) < 1e-6);
    // SGR 5/6 blink fade rides on foreground.a, scaling every channel alike.
    factor *= in.foreground.a;
    // The alpha channel is the mask's coverage over whatever alpha the pixel
    // holds — cov + dst(1 − cov) once blended — truncated as CoreGraphics
    // truncates it, not rounded as the store rounds it: a rounded blend lands
    // one code high on half of every edge over a translucent ground. Biasing
    // the source by just under half a code makes the store's round-to-nearest
    // land on floor(y + 1/1024), CoreGraphics' own form, over any destination,
    // including a neighbour's opaque cursor a glyph overhangs. A zero coverage
    // clamps to zero and leaves the destination exactly as it was.
    float alpha = coverage * in.foreground.a;
    GlyphFragmentOut out;
    out.color = float4(fgL * factor, alpha > 0.0 ? alpha - (0.5 - 1.0 / 1024.0) / 255.0 : 0.0);
    out.factor = float4(factor, alpha);
    return out;
}

// Image pass: textured quads for Kitty graphics + DEC sixel placements.
// One instance per visible placement; topLeftInPixels/bottomRightInPixels is the device-pixel
// rect (y from top), uv0/uv1 the source sub-rectangle in normalized
// texture coords. The texture is an _sRGB RGBA format, so the sampler
// returns LINEAR rgb; the straight-alpha over-blend (same pipeline state
// as the overlay/glyph passes) composites it over whatever the cell +
// glyph passes already painted.
struct ImageInstance {
    float2 topLeftInPixels;
    float2 bottomRightInPixels;
    float2 uv0;
    float2 uv1;
};

struct ImageOut {
    float4 position [[position]];
    float2 uv;
    float  bitmapTier [[flat]]; // Uniforms.bitmapTier, carried so the fragment needs no buffer of its own
    // The quad itself, for the bitmap tier's filtered read, which works out
    // each pixel's texel position as the software renderer does rather than
    // from an interpolated one.
    float2 rectMin [[flat]];
    float2 rectMax [[flat]];
    float2 uvMin [[flat]];
    float2 uvMax [[flat]];
};

vertex ImageOut imageVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]],
                            constant ImageInstance* images [[buffer(1)]])
{
    ImageInstance im = images[iid];
    float2 corner = quadCorners[vid];
    float2 positionInPixels = mix(im.topLeftInPixels, im.bottomRightInPixels, corner);

    ImageOut out;

    out.bitmapTier = float(u.bitmapTier);
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.uv = mix(im.uv0, im.uv1, corner);
    out.rectMin = im.topLeftInPixels;
    out.rectMax = im.bottomRightInPixels;
    out.uvMin = im.uv0;
    out.uvMax = im.uv1;
    return out;
}

// One texel of a mip level as the byte the software renderer reads, the edge
// repeated past the last texel. The texture is sRGB, so a read comes back
// decoded and is re-encoded to its byte.
static float4 levelTexelBytes(texture2d<float> tex, uint level, int2 size, int x, int y)
{
    x = clamp(x, 0, size.x - 1);
    y = clamp(y, 0, size.y - 1);
    float4 texel = tex.read(uint2(x, y), level);
    return float4(round(linearToSrgb(texel.rgb) * 255.0), round(texel.a * 255.0));
}

// SoftwareRenderer's `bilinear`, over bytes: texel centres at half integers,
// the same operations in the same order.
static float4 bilinearBytes(texture2d<float> tex, uint level, float u, float v)
{
    int2 size = int2(int(tex.get_width(level)), int(tex.get_height(level)));
    float tx = u * float(size.x) - 0.5;
    float ty = v * float(size.y) - 0.5;
    float floorX = floor(tx);
    float floorY = floor(ty);
    float wx = tx - floorX;
    float wy = ty - floorY;
    int x0 = int(floorX);
    int y0 = int(floorY);
    float4 a = levelTexelBytes(tex, level, size, x0, y0);
    float4 b = levelTexelBytes(tex, level, size, x0 + 1, y0);
    float4 c = levelTexelBytes(tex, level, size, x0, y0 + 1);
    float4 d = levelTexelBytes(tex, level, size, x0 + 1, y0 + 1);
    float4 top = a + (b - a) * wx;
    float4 bottom = c + (d - c) * wx;
    return top + (bottom - top) * wy;
}

// SoftwareRenderer::compositeFilteredImage's texel, as bytes: bilinear in the
// two levels that bracket Image::imageLevelOfDetail, blended between them.
static float4 filteredTexelBytes(ImageOut in, texture2d<float> tex)
{
    float spanX = in.rectMax.x - in.rectMin.x;
    float spanY = in.rectMax.y - in.rectMin.y;
    float u = in.uvMin.x + ((in.position.x - in.rectMin.x) / spanX) * (in.uvMax.x - in.uvMin.x);
    float v = in.uvMin.y + ((in.position.y - in.rectMin.y) / spanY) * (in.uvMax.y - in.uvMin.y);
    float ratio = max((in.uvMax.x - in.uvMin.x) * float(tex.get_width(0)) / spanX,
                      (in.uvMax.y - in.uvMin.y) * float(tex.get_height(0)) / spanY);
    float levelOfDetail = ratio > 1.0 ? log2(ratio) : 0.0;
    int lastLevel = int(tex.get_num_mip_levels()) - 1;
    float clamped = min(levelOfDetail, float(lastLevel));
    int lower = int(floor(clamped));
    int upper = min(lower + 1, lastLevel);
    float between = clamped - float(lower);
    float4 texel = bilinearBytes(tex, uint(lower), u, v);
    if (between > 0.0)
        texel += (bilinearBytes(tex, uint(upper), u, v) - texel) * between;
    return round(texel);
}

// Image fragment: the sampler returns linear rgb (sRGB texture) with
// straight alpha. Emit it directly for the linear-blending sRGB target;
// the over-blend re-applies alpha at composite time. Sixel pixels carry
// alpha 1 (opaque); kitty RGBA carries real alpha.
static float4 imageShade(ImageOut in,
                         texture2d<float> tex,
                         sampler texSampler,
                         float4 destination,
                         uint filtered)
{
    // The bitmap tier's filtered quad: the software renderer's own filter, so
    // the frame is that renderer's picture byte for byte.
    if (in.bitmapTier > 0.5 && filtered != 0) {
        float4 bytes = filteredTexelBytes(in, tex);
        return overlayComposite(1.0, bytes.rgb / 255.0, bytes.a / 255.0, destination);
    }
    float4 texel = tex.sample(texSampler, in.uv);
    // Bitmap tier: the software renderer's straight-alpha over-blend in the
    // integer domain against the grid pixel — the same sum the overlay quads
    // use, on the texel's own alpha: nothing at zero, the texel verbatim at
    // 255, the +127 mix between. The sampler is nearest, as the CPU's texel
    // pick is; the texture is an sRGB format, so the sample comes back decoded
    // and is re-encoded to the byte the mix wants. This pipeline blends
    // nothing. A real font's pass keeps the straight-alpha hardware blend.
    if (in.bitmapTier > 0.5)
        return overlayComposite(1.0, linearToSrgb(texel.rgb), texel.a, destination);
    return float4(texel.rgb, texel.a);
}

fragment float4 imageFragment(ImageOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler texSampler [[sampler(0)]],
                              constant uint& filtered [[buffer(1)]],
                              float4 destination [[color(0)]])
{
    return imageShade(in, tex, texSampler, destination, filtered);
}

fragment float4 imageFragmentBlended(ImageOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler texSampler [[sampler(0)]],
                                     constant uint& filtered [[buffer(1)]])
{
    return imageShade(in, tex, texSampler, float4(0.0), filtered);
}

// The bitmap tier's images where the target cannot be read (see
// unreadDestination).
fragment float4 imageFragmentUnread(ImageOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    sampler texSampler [[sampler(0)]],
                                    constant uint& filtered [[buffer(1)]])
{
    return imageShade(in, tex, texSampler, unreadDestination, filtered);
}

// Rich text block pass (Docs/rich-text.md): a block's retained raster, linear
// and premultiplied, composited at one texel per device pixel over the grid;
// a selection highlight is the same quad over a one-texel texture. The
// premultiplied-over blend shows the highlight through the transparent ground
// around every glyph, whatever its run's colour.
fragment float4 richTextFragment(ImageOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler texSampler [[sampler(0)]])
{
    return tex.sample(texSampler, in.uv);
}

// Background-image pass: one full-or-letterboxed quad behind the grid. The CPU
// computes the device-pixel position rect (topLeftInPixels/bottomRightInPixels) and the
// source UV rect (uv0/uv1) for the chosen fit mode (fill/fit/stretch/tile/
// center), so the shader is mode-agnostic: it just maps the quad onto the UVs
// and emits the sampled color PREMULTIPLIED by `opacity` (the destination-over
// blend expects premultiplied source, and the texture is already
// premultiplied-last). Tile mode uses a repeating sampler and UVs > 1.
struct BackgroundImageInstance {
    float2 topLeftInPixels;
    float2 bottomRightInPixels;
    float2 uv0;
    float2 uv1;
    float  opacity;
    float  pad0;
    float2 pad1;
};

struct BackgroundImageOut {
    float4 position [[position]];
    float2 uv;
    float  opacity;
};

vertex BackgroundImageOut backgroundImageVertex(uint vid [[vertex_id]],
                                                constant Uniforms& u [[buffer(0)]],
                                                constant BackgroundImageInstance& im [[buffer(1)]])
{
    float2 corner = quadCorners[vid];
    float2 positionInPixels = mix(im.topLeftInPixels, im.bottomRightInPixels, corner);
    BackgroundImageOut out;
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.uv = mix(im.uv0, im.uv1, corner);
    out.opacity = im.opacity;
    return out;
}

fragment float4 backgroundImageFragment(BackgroundImageOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        sampler texSampler [[sampler(0)]])
{
    // Sampler returns linear rgb (sRGB texture), premultiplied alpha. Scale by
    // the image opacity (premultiplied: both rgb and alpha) so destination-over
    // composites it correctly behind the translucent theme background.
    float4 c = tex.sample(texSampler, in.uv);
    return c * in.opacity;
}

// Tek vector pass: one oriented quad per stroke run (a solid LINE, each run of
// a dashed one, a POINT, a letter's strokes, the GIN crosshair arms and the
// writing spot). p0/p1 are the run's endpoints in device pixels (y from top);
// halfThick is half the stroke width. The beam is round: every fragment shades
// the capsule round the segment from Core's integer raster (Tek/BeamRaster.h),
// the one the software compositor runs, so the ends cap round, a joint closes,
// a degenerate run is the beam's spot, and the bitmap tier's pixels are the
// software reference's to the byte.
struct TekLineInstance {
    float2 p0;
    float2 p1;
    float  halfThick;
    float  pad0;
    float4 color;
};

struct TekLineOut {
    float4 position [[position]];
    float4 color [[flat]];
    float2 startInPixels [[flat]];
    float2 endInPixels [[flat]];
    float  halfThick [[flat]];
};

// The run's quad grown by `extent` on every side, its ends included, so every
// pixel the capsule or its halo can light is rasterised.
static float2 tekRunCorner(TekLineInstance ln, uint vid, float extent)
{
    float2 corner = quadCorners[vid];
    float2 d = ln.p1 - ln.p0;
    float len = length(d);
    float2 dir = (len > 1e-4) ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float alongPx = -extent + corner.x * (len + 2.0 * extent);
    float acrossPx = (corner.y - 0.5) * (extent * 2.0);
    return ln.p0 + dir * alongPx + nrm * acrossPx;
}

static int tekRunDistance(TekLineOut in)
{
    const Ubiquitty::Tek::BeamRun run(in.startInPixels.x, in.startInPixels.y, in.endInPixels.x, in.endInPixels.y);
    return run.distanceToPixel(int(in.position.x), int(in.position.y));
}

vertex TekLineOut tekLineVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant Uniforms& u [[buffer(0)]],
                                constant TekLineInstance* lines [[buffer(1)]])
{
    TekLineInstance ln = lines[iid];
    // The feather reaches half a pixel past the half-width and the endpoints
    // snap by at most a 32nd; a whole pixel covers both.
    float2 positionInPixels = tekRunCorner(ln, vid, ln.halfThick + 1.0);
    TekLineOut out;
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.color = ln.color;
    out.startInPixels = ln.p0;
    out.endInPixels = ln.p1;
    out.halfThick = ln.halfThick;
    return out;
}

static int tekLineCoverage(TekLineOut in)
{
    return Ubiquitty::Tek::beamCoverage(tekRunDistance(in), Ubiquitty::Tek::BeamRun::units(in.halfThick));
}

// A real font's tier: the coverage as alpha, blended over in linear light.
fragment float4 tekLineFragmentBlended(TekLineOut in [[stage_in]])
{
    float coverage = float(tekLineCoverage(in)) / float(Ubiquitty::Tek::beamCoverageScale());
    return float4(srgbToLinear(in.color.rgb), in.color.a * coverage);
}

// The bitmap tier: the coverage byte mixed into the byte the target holds, as
// the software compositor mixes it.
fragment float4 tekLineFragment(TekLineOut in [[stage_in]],
                                float4 destination [[color(0)]])
{
    int alpha = Ubiquitty::Tek::beamCoverageByte(tekLineCoverage(in));
    if (alpha == 0)
        return overlayKeepDestination(1.0, destination);
    return overlayComposite(1.0, in.color.rgb, float(alpha) / 255.0, destination);
}

// The bitmap tier's beam where the target cannot be read (see
// unreadDestination).
fragment float4 tekLineFragmentUnread(TekLineOut in [[stage_in]])
{
    int alpha = Ubiquitty::Tek::beamCoverageByte(tekLineCoverage(in));
    return overlayComposite(1.0, in.color.rgb, float(alpha) / 255.0, unreadDestination);
}

// The bitmap tier's beam drawn into a linear-format view of the target where it
// cannot be read, so the blend mixes the stored bytes as the software
// compositor does.
fragment float4 tekLineFragmentUnreadEncoded(TekLineOut in [[stage_in]])
{
    int alpha = Ubiquitty::Tek::beamCoverageByte(tekLineCoverage(in));
    float4 shaded = overlayComposite(1.0, in.color.rgb, float(alpha) / 255.0, unreadDestination);
    return float4(linearToSrgb(shaded.rgb), shaded.a);
}

// --- Glowing Vectors: a bloom halo under each crisp stroke ------------------
// The halo is Core's (Tek::BeamGeometry, haloIntensity), tabulated by distance
// for the beam colour (Tek::fillHaloLevels): the quad grows by the reach on
// every side of the run, and the fragment looks its pixel's distance to the
// run's segment up in the table, so the ends cap round and a corner wraps with
// the falloff the line has across. The pipeline blends by maximum, so
// overlapping halos form the halo of the distance to the whole polyline rather
// than doubling at a joint; the maximum commutes with the sRGB encoding, so it
// lands on the table's bytes on either tier. Drawn before the crisp core pass;
// opt-in (tekGlowVectors).
struct TekHaloTable {
    float reach;
    int levelCount;
};

vertex TekLineOut tekLineGlowVertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    constant Uniforms& u [[buffer(0)]],
                                    constant TekLineInstance* lines [[buffer(1)]],
                                    constant TekHaloTable& table [[buffer(2)]])
{
    TekLineInstance ln = lines[iid];
    float2 positionInPixels = tekRunCorner(ln, vid, table.reach + 1.0);
    TekLineOut out;
    out.position = float4(pixelsToNdc(positionInPixels, u.viewportSizeInPixels), 0.0, 1.0);
    out.color = ln.color;
    out.startInPixels = ln.p0;
    out.endInPixels = ln.p1;
    out.halfThick = ln.halfThick;
    return out;
}

fragment float4 tekLineGlowFragment(TekLineOut in [[stage_in]],
                                    constant TekHaloTable& table [[buffer(2)]],
                                    constant uchar4* levels [[buffer(3)]])
{
    int index = Ubiquitty::Tek::haloLevelIndex(tekRunDistance(in));
    if (index >= table.levelCount)
        return float4(0.0);
    // Alpha zero: the maximum leaves the target's own alpha, the background
    // opacity, where it was.
    return float4(srgbToLinear(float3(levels[index].rgb) / 255.0), 0.0);
}

// Color-emoji fragment: the RGBA atlas holds premultiplied sRGB pixels
// drawn by CoreText. Un-premultiply to straight color, convert to linear
// (the target is an sRGB texture), and keep alpha — the cell foreground
// is ignored so the emoji shows its own colors. The straight-alpha
// over-blend then re-applies alpha at composite time.
fragment float4 colorGlyphFragment(GlyphOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]],
                                   sampler atlasSampler [[sampler(0)]])
{
    float2 samplePosition = clamp(in.atlasUV, in.atlasBoxTopLeft + 0.5,
                                 max(in.atlasBoxTopLeft + 0.5, in.atlasBoxBottomRight - 0.5));
    float4 positionInPixels = atlas.sample(atlasSampler, atlasNormalized(atlas, samplePosition));
    float3 straight = (positionInPixels.a > 0.0) ? positionInPixels.rgb / positionInPixels.a : float3(0.0);
    // foreground.a carries the SGR 5/6 blink fade — emoji blink with everything else.
    return float4(srgbToLinear(straight), positionInPixels.a * in.foreground.a);
}

// ===================================================================
// A fullscreen pass: one oversized triangle and its UV, shared by every
// full-drawable blit. Filed here rather than beside any one caller — the shape
// belongs to the pass, not to whatever effect first needed it.
struct FsOut {
    float4 position [[position]];
    float2 uv;
};

vertex FsOut fullscreenTriangleVertex(uint vid [[vertex_id]])
{
    // Single oversized triangle covering the viewport.
    float2 pos = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
    FsOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
    return out;
}

// Blit a premultiplied full-drawable texture over the framebuffer. The grid
// cache blits its retained texture through this.
fragment float4 fullscreenBlit(FsOut in [[stage_in]],
                                 texture2d<float> layer [[texture(0)]],
                                 sampler s [[sampler(0)]])
{
    return layer.sample(s, in.uv);   // already premultiplied + linear
}

// Native vibrancy consumes only the secondary glyph mask. The ordinary pass
// omits this ink, and its background and overlays remain ordinary composites.
fragment float4 secondaryCursorClearFragment(VertexOut in [[stage_in]])
{
    return float4(0);
}

fragment float4 vibrantBackgroundFragment(VertexOut in [[stage_in]],
                                           constant Uniforms& u [[buffer(0)]])
{
    // Ordinary tint and native fill compose to the cell's resolved coverage.
    // Raising the tint transfers the color to the ordinary plane continuously.
    return nativeBackgroundPixel(in.background, u);
}

fragment float4 secondaryCellFragment(VertexOut in [[stage_in]],
                                      constant Uniforms& u [[buffer(0)]],
                                      texture2d<float> atlas [[texture(0)]],
                                      sampler atlasSampler [[sampler(0)]])
{
    if (in.foreground.a >= 0.0 || in.hasGlyph < 0.5) {
        return float4(0.0);
    }
    float coverage = atlas.sample(atlasSampler, atlasNormalized(atlas, in.atlasUV)).r * -in.foreground.a;
    return float4(srgbToLinear(coverage * in.foreground.rgb), coverage);
}

fragment float4 secondaryGlyphFragment(GlyphOut in [[stage_in]],
                                       constant Uniforms& u [[buffer(0)]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler atlasSampler [[sampler(0)]])
{
    if (in.foreground.a >= 0.0) {
        discard_fragment();
    }
    float coverage = atlas.sample(atlasSampler, atlasNormalized(atlas, in.atlasUV)).r * -in.foreground.a;
    return float4(srgbToLinear(coverage * in.foreground.rgb), coverage);
}
