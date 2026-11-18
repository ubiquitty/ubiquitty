// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// webgl.js — the browser's GPU backend.
//
// Draws the instance stream `buildCellInstances` produces — the arrays Metal and
// Vulkan bind, at their struct strides, over one coverage atlas. What a cell
// looks like was resolved in portable C++ before these bytes existed; this file
// binds them and issues one instanced draw per pass.
//
// The shaders are `Source/Platform/Linux/shaders/*` in GLSL ES 3.00. Three
// differences change what the shader must compute, each marked at its line:
//
//   - GL clip space is bottom-left origin where Vulkan's is top-left. The vertex
//     shader flips Y so the shared instance data stays in one coordinate system.
//   - `gl_FragCoord.y` counts from the opposite edge, so the fragment shader
//     converts before deriving a cell-local pixel.
//   - Push constants become uniforms; WebGL has no equivalent.
//
// The integer-domain mix and the `texelFetch` are carried across unchanged. Those
// two are what keep GPU output byte-identical to the CPU `SoftwareRenderer` that
// serves as the cross-backend oracle, so an idiomatic rewrite of either forks
// this backend away from it without failing anything.

const CELL_INSTANCE_STRIDE = 64; // Rendering::CellInstance, pinned by static_assert

const CELL_VERTEX_SHADER = `#version 300 es
// Per-instance attributes ARE Rendering::CellInstance; the locations map to its
// field byte offsets, so the buffer uploads as it stands. Location 2 is the
// 4 bytes of alignment padding at offset 12, which no attribute declares.
layout(location = 0) in vec2 inGridPosition; // (column, row), cell units  @0
layout(location = 1) in float inWidthCells;  // 1 narrow, 2 wide lead      @8
layout(location = 3) in vec4 inForeground;   //                            @16
layout(location = 4) in vec4 inBackground;   //                            @32
layout(location = 5) in vec2 inAtlasMin;     // glyph UV top-left          @48
layout(location = 6) in vec2 inAtlasMax;     // glyph UV bottom-right      @56

uniform vec2 uViewportSize; // device pixels
uniform vec2 uCellSize;     // device pixels

out vec4 vForeground;
out vec4 vBackground;
flat out float vHasGlyph;
// Passed *flat* so the fragment shader recovers an integer atlas texel rather
// than sampling an interpolated UV. Only the integer path matches the CPU
// renderer's nearest tap once coverage is anti-aliased rather than 0 or 255.
flat out vec2 vCellOriginPx;
flat out vec2 vCellSizePx;
flat out vec2 vAtlasMin;
flat out vec2 vAtlasMax;

const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main() {
    vec2 corner = kCorners[gl_VertexID];
    vec2 originPx = inGridPosition * uCellSize;
    vec2 sizePx = vec2(inWidthCells * uCellSize.x, uCellSize.y);
    vec2 px = originPx + corner * sizePx;
    vec2 ndc = px / uViewportSize * 2.0 - 1.0;
    // GL's clip space is bottom-left origin; the instances are top-left origin.
    // Flipping here keeps the shared instance data in one coordinate system.
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    vForeground = inForeground;
    vBackground = inBackground;
    // atlasTopLeft == atlasBottomRight marks a blank cell — sampling texel
    // (0,0) instead would stamp a stray glyph into every space.
    vHasGlyph = (inAtlasMax.x > inAtlasMin.x) ? 1.0 : 0.0;
    vCellOriginPx = originPx;
    vCellSizePx = sizePx;
    vAtlasMin = inAtlasMin;
    vAtlasMax = inAtlasMax;
}`;

const CELL_FRAGMENT_SHADER = `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;

in vec4 vForeground;
in vec4 vBackground;
flat in float vHasGlyph;
flat in vec2 vCellOriginPx;
flat in vec2 vCellSizePx;
flat in vec2 vAtlasMin;
flat in vec2 vAtlasMax;

uniform sampler2D uAtlas;   // R8 glyph coverage
uniform vec2 uViewportSize; // device pixels, for the Y flip below

out vec4 outColor;

// Paint the cell background, then mix the foreground over it by atlas coverage.
//
// Two properties keep this byte-identical to the CPU SoftwareRenderer:
//
//  1. Coverage is fetched by integer texelFetch, never an interpolated UV with
//     a nearest filter: interpolation ULPs make a nearest tap pick the
//     neighbouring texel at the texel-centre boundary.
//  2. The mix runs in the integer 0..255 domain and is emitted as byte/255. A
//     float mix into a UNORM8 store rounds a least-significant bit differently
//     across implementations. At coverage 0 or 255 it reduces to background or
//     foreground, so only anti-aliased coverage shows the difference.
void main() {
    int coverage = 0;
    if (vHasGlyph > 0.5) {
        ivec2 texSize = textureSize(uAtlas, 0);
        // gl_FragCoord.y counts from the bottom in GL; the cell origin is
        // measured from the top, so convert before taking the cell-local pixel.
        vec2 fragTopLeft = vec2(gl_FragCoord.x, uViewportSize.y - gl_FragCoord.y);
        ivec2 local = ivec2(floor(fragTopLeft - vCellOriginPx));
        // The whole atlas rect spans the cell quad, including doubled rows
        // whose ordinary mono raster occupies a wider or taller destination.
        vec2 source = vAtlasMin + (vec2(local) + vec2(0.5)) / vCellSizePx * (vAtlasMax - vAtlasMin);
        ivec2 texel = clamp(ivec2(source), ivec2(0), texSize - ivec2(1));
        coverage = int(round(texelFetch(uAtlas, texel, 0).r * 255.0));
    }
    int opacity = int(round(clamp(abs(vForeground.a), 0.0, 1.0) * 255.0));
    coverage = (coverage * opacity + 127) / 255;
    int invCoverage = 255 - coverage;
    ivec3 background = ivec3(round(vBackground.rgb * 255.0));
    ivec3 foreground = ivec3(round(vForeground.rgb * 255.0));
    ivec3 mixed = (background * invCoverage + foreground * coverage + ivec3(127)) / 255;
    int bgA = int(round(vBackground.a * 255.0));
    int outA = (bgA * invCoverage + 255 * coverage + 127) / 255;
    outColor = vec4(vec3(mixed) / 255.0, float(outA) / 255.0);
}`;


const OVERLAY_INSTANCE_STRIDE = 112;   // Rendering::OverlayInstance — static_assert-pinned in CellInstance.h

// One segment of every grid stream: the head (the grid) or the tail (the
// cursor tier). A stream's bytes are a view onto the wasm heap, so a segment
// is a subarray of them; the tail is the last `tier` instances.
const GLYPH_INSTANCE_STRIDE = 64;
function sliceStreams(frame, segment) {
  const tier = frame.cursorTier || {};
  const cut = (bytes, count, tail, stride) => {
    const tailCount = Math.min(tail || 0, count);
    const headCount = count - tailCount;
    if (segment === "head")
      return { bytes: headCount > 0 ? bytes.subarray(0, headCount * stride) : null, count: headCount };
    return { bytes: tailCount > 0 ? bytes.subarray(headCount * stride) : null, count: tailCount };
  };
  const cells = cut(frame.cellBytes, frame.cellCount, tier.cellCount, CELL_INSTANCE_STRIDE);
  const glyphs = cut(frame.glyphBytes, frame.glyphCount || 0, tier.glyphCount, GLYPH_INSTANCE_STRIDE);
  const wide = cut(frame.wideGlyphBytes, frame.wideGlyphCount, tier.wideGlyphCount, GLYPH_INSTANCE_STRIDE);
  const proportional = cut(frame.proportionalGlyphBytes, frame.proportionalGlyphCount, tier.proportionalGlyphCount, GLYPH_INSTANCE_STRIDE);
  const strips = cut(frame.proportionalStripBytes, frame.proportionalStripCount, tier.proportionalStripCount, GLYPH_INSTANCE_STRIDE);
  const ligatures = cut(frame.ligatureGlyphBytes, frame.ligatureGlyphCount, tier.ligatureGlyphCount, GLYPH_INSTANCE_STRIDE);
  const color = cut(frame.colorGlyphBytes, frame.colorGlyphCount, tier.colorGlyphCount, GLYPH_INSTANCE_STRIDE);
  const decorations = cut(frame.decorationBytes, frame.decorationCount, tier.decorationCount, DECORATION_INSTANCE_STRIDE);
  const boxes = cut(frame.boxFillBytes, frame.boxFillCount || 0, tier.boxFillCount, OVERLAY_INSTANCE_STRIDE);
  return {
    cellBytes: cells.bytes, cellCount: cells.count,
    glyphBytes: glyphs.bytes, glyphCount: glyphs.count,
    wideGlyphBytes: wide.bytes, wideGlyphCount: wide.count,
    proportionalGlyphBytes: proportional.bytes, proportionalGlyphCount: proportional.count,
    proportionalStripBytes: strips.bytes, proportionalStripCount: strips.count,
    ligatureGlyphBytes: ligatures.bytes, ligatureGlyphCount: ligatures.count,
    colorGlyphBytes: color.bytes, colorGlyphCount: color.count,
    decorationBytes: decorations.bytes, decorationCount: decorations.count,
    boxFillBytes: boxes.bytes, boxFillCount: boxes.count,
    isBitmapFace: frame.isBitmapFace,
    cellWidth: frame.cellWidth, cellHeight: frame.cellHeight,
  };
}
export const DECORATION_INSTANCE_STRIDE = 64; // Rendering::DecorationInstance
const WIDE_GLYPH_INSTANCE_STRIDE = 64; // Rendering::GlyphInstance

// Wide-glyph pass — two-cell glyphs, from their own atlas page.
//
// A cell quad samples one texture. The wide page is the same size as the mono
// one, so nothing about the dimensions warns you — but its slots are two cells
// across, so the same normalized coordinate names a different glyph on each.
// Baking a wide UV into a cell that binds mono draws a real, sharp, WRONG glyph,
// which is why this was invisible until someone read the CJK.
//
// The instance carries its own pixel rect rather than a grid position: the glyph
// spans two cells and is placed by the builder, so nothing here needs to know
// the grid at all.
const WIDE_GLYPH_VERTEX_SHADER = `#version 300 es
layout(location = 0) in vec2 inOrigin;      // top-left, device px      @0
layout(location = 1) in vec2 inSize;        // quad size, device px     @8
layout(location = 2) in vec4 inForeground;  //                          @16
layout(location = 3) in vec4 inBackground;  // the cell colour beneath  @32
layout(location = 4) in vec2 inAtlasMin;    //                          @48
layout(location = 5) in vec2 inAtlasMax;    //                          @56

uniform vec2 uViewportSize;

out vec2 vAtlasUV;
out vec4 vForeground;
out vec4 vBackground;

const vec2 corners[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0));

void main()
{
    vec2 corner = corners[gl_VertexID];
    vec2 pixel = inOrigin + corner * inSize;
    // Y down in pixels, Y up in clip space — the same flip the other passes do.
    vec2 clip = vec2((pixel.x / uViewportSize.x) * 2.0 - 1.0,
                     1.0 - (pixel.y / uViewportSize.y) * 2.0);
    gl_Position = vec4(clip, 0.0, 1.0);
    vAtlasUV = mix(inAtlasMin, inAtlasMax, corner);
    vForeground = inForeground;
    vBackground = inBackground;
}
`;

const WIDE_GLYPH_FRAGMENT_SHADER = `#version 300 es
precision highp float;

in vec2 vAtlasUV;
in vec4 vForeground;
in vec4 vBackground;

uniform sampler2D uWideAtlas;

out vec4 fragColor;

void main()
{
    // R8 coverage, exactly as the mono pass reads it. Blended against the cell
    // colour the builder recorded rather than against whatever the framebuffer
    // holds, so the result does not depend on what drew underneath.
    // Atlas pixels; normalize here, where a divide is free.
    float coverage = texture(uWideAtlas, vAtlasUV / vec2(textureSize(uWideAtlas, 0))).r * clamp(abs(vForeground.a), 0.0, 1.0);
    // A pixel the glyph puts no ink on keeps what lies beneath it, as
    // SoftwareRenderer::compositeGlyph skips a zero-coverage byte and the Vulkan
    // glyph pass discards one: a circle or a picture under the quad stays.
    if (coverage * 255.0 < 0.5) discard;
    fragColor = vec4(mix(vBackground.rgb, vForeground.rgb, coverage), 1.0);
}
`;

const PROPORTIONAL_GLYPH_VERTEX_SHADER = `#version 300 es
layout(location = 0) in vec2 inOrigin;
layout(location = 1) in vec2 inSize;
layout(location = 2) in vec4 inForeground;
layout(location = 3) in vec4 inBackground;
layout(location = 4) in vec2 inAtlasMin;
layout(location = 5) in vec2 inAtlasMax;

uniform vec2 uViewportSize;
flat out vec2 vOrigin;
flat out vec2 vAtlasMin;
flat out vec2 vTexelsPerPixel;
flat out vec4 vForeground;
flat out vec4 vBackground;

const vec2 corners[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0));

void main()
{
    vOrigin = vec2(ivec2(inOrigin));
    vec2 pixel = vOrigin + corners[gl_VertexID] * vec2(ivec2(inSize));
    gl_Position = vec4((pixel.x / uViewportSize.x) * 2.0 - 1.0,
        1.0 - (pixel.y / uViewportSize.y) * 2.0, 0.0, 1.0);
    vAtlasMin = inAtlasMin;
    // One for every quad drawn at its own size. Doubled rows spread the source
    // rect across the wider quad and, for DECDHL, its taller row half.
    vTexelsPerPixel = vec2(inSize.x > 0.0 ? (inAtlasMax.x - inAtlasMin.x) / inSize.x : 1.0,
        inSize.y > 0.0 ? (inAtlasMax.y - inAtlasMin.y) / inSize.y : 1.0);
    vForeground = inForeground;
    vBackground = inBackground;
}
`;

const PROPORTIONAL_GLYPH_FRAGMENT_SHADER = `#version 300 es
precision highp float;
precision highp int;

uniform sampler2D uProportionalAtlas;
uniform vec2 uViewportSize;
flat in vec2 vOrigin;
flat in vec2 vAtlasMin;
flat in vec2 vTexelsPerPixel;
flat in vec4 vForeground;
flat in vec4 vBackground;
out vec4 fragColor;

void main()
{
    ivec2 local = ivec2(gl_FragCoord.x, uViewportSize.y - gl_FragCoord.y) - ivec2(vOrigin);
    // The texel the pixel's centre falls in, which at one texel a pixel is the
    // pixel's own offset: SoftwareRenderer::compositeProportionalGlyph's tap.
    ivec2 slotMin = ivec2(vAtlasMin + vec2(0.5));
    int x = slotMin.x + int((float(local.x) + 0.5) * vTexelsPerPixel.x);
    // A DECDHL half can start between source rows. Keep that fractional origin
    // until the scaled tap is chosen, as the software compositor does.
    int y = vTexelsPerPixel.y == 1.0 ? slotMin.y + local.y
        : int(floor(vAtlasMin.y + (float(local.y) + 0.5) * vTexelsPerPixel.y));
    ivec2 texel = clamp(ivec2(x, y), ivec2(0), textureSize(uProportionalAtlas, 0) - ivec2(1));
    int coverage = int(round(texelFetch(uProportionalAtlas, texel, 0).r * 255.0));
    int opacity = int(round(clamp(abs(vForeground.a), 0.0, 1.0) * 255.0));
    coverage = (coverage * opacity + 127) / 255;
    if (coverage == 0) discard;
    ivec3 background = ivec3(round(vBackground.rgb * 255.0));
    ivec3 foreground = ivec3(round(vForeground.rgb * 255.0));
    ivec3 color = (background * (255 - coverage) + foreground * coverage + ivec3(127)) / 255;
    int backgroundAlpha = int(round(vBackground.a * 255.0));
    int alpha = (backgroundAlpha * (255 - coverage) + 255 * coverage + 127) / 255;
    fragColor = vec4(vec3(color), float(alpha)) / 255.0;
}
`;


// Colour-glyph pass — emoji, from an RGBA sheet.
//
// The instance layout is the wide pass's, so this reuses that vertex shader.
// What differs is the fragment stage and it differs in two ways that are easy to
// get wrong together.
//
// The sheet carries colours rather than coverage, so there is no pen to apply. A
// shader that mixed toward vForeground here would tint an emoji to the text
// colour, which is what the mono path already does to one and the whole reason
// this pass exists.
//
// And unlike the wide pass this one BLENDS against the framebuffer rather than
// against the background on the instance. The colour slot is square at the cell
// HEIGHT while a cell is narrower, so an emoji's quad reaches past its own cell.
// Mixing against the instance's background would paint that overhang with this
// cell's background and erase whatever the neighbour drew.
const COLOR_GLYPH_FRAGMENT_SHADER = `#version 300 es
precision highp float;

in vec2 vAtlasUV;
in vec4 vForeground;
in vec4 vBackground;

uniform sampler2D uColorAtlas;

out vec4 fragColor;

void main()
{
    // Straight alpha, matching the raster seam: the caller pairs this with
    // SRC_ALPHA / ONE_MINUS_SRC_ALPHA. Emitting premultiplied here would darken
    // every antialiased emoji edge toward black.
    fragColor = texture(uColorAtlas, vAtlasUV / vec2(textureSize(uColorAtlas, 0)));
    fragColor.a *= clamp(abs(vForeground.a), 0.0, 1.0);
}
`;


// Decoration pass — underline (solid, dotted, dashed, curly), overline,
// strikethrough and box rules, from `decoration.{vert,frag}` with the dialect
// and the Y flip changed. Rules carry their own alpha, so ordinary alpha
// blending over the cell pass suffices and no framebuffer read is needed. A
// rule glyph ink cuts arrives as the pieces Core left standing
// (Core/Rendering/SkipInk.h), each laid out across the whole rule's band, so
// no glyph is sampled here. A piece's cut end lies wherever the cut does,
// inside a pixel as often as not, and that pixel is drawn in the part the
// piece covers.
const DECORATION_VERTEX_SHADER = `#version 300 es
layout(location = 0) in vec2 inMin;        // topLeftInPixels: the piece    @0
layout(location = 1) in vec2 inMax;        // bottomRightInPixels           @8
layout(location = 2) in vec4 inColor;      //                               @16
layout(location = 3) in vec4 inParams;     // kind, period, thickness, cut ends @32
layout(location = 4) in vec4 inBand;       // the whole rule's corners      @48

uniform vec2 uViewportSize;

out vec4 vLocal;
out vec4 vColor;
flat out vec4 vParams;
flat out vec2 vCutAcross; // the piece's cut ends across; far outside where none

const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main() {
    vec2 corner = kCorners[gl_VertexID];
    // A cut end's pixel is drawn in part, so the quad reaches the whole pixel
    // the end lies in, and no further than the band's own pixels.
    int cutEnds = int(inParams.w + 0.5);
    bool isLeftCut = (cutEnds == 1 || cutEnds == 3);
    bool isRightCut = (cutEnds >= 2);
    float quadLeft = isLeftCut ? max(floor(inMin.x), ceil(inBand.x - 0.5)) : inMin.x;
    float quadRight = isRightCut ? min(ceil(inMax.x), ceil(inBand.z - 0.5)) : inMax.x;
    vec2 px = vec2(mix(quadLeft, quadRight, corner.x), mix(floor(inMin.y), ceil(inMax.y), corner.y));
    vec2 ndc = px / uViewportSize * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0); // GL clip space is bottom-left origin
    // The pattern is the band's: a piece of a cut rule draws its own part of it.
    vLocal = vec4(px - inBand.xy, inBand.zw - inBand.xy);
    vColor = inColor;
    vParams = inParams;
    vCutAcross = vec2(isLeftCut ? inMin.x : -1.0e9, isRightCut ? inMax.x : 1.0e9);
}`;

const DECORATION_FRAGMENT_SHADER = `#version 300 es
precision highp float;

in vec4 vLocal;
in vec4 vColor;
flat in vec4 vParams;
flat in vec2 vCutAcross;

out vec4 outColor;

const float decorationSolid = 0.0;
const float decorationDotted = 1.0;
const float decorationDashed = 2.0;
const float decorationCurly = 3.0;

void main() {
    vec2 vLocalPx = vLocal.xy;
    vec2 vSizePx = vLocal.zw;
    float vKind = vParams.x;
    float vCellSize = vParams.y;
    float vThickness = vParams.z;
    // The part of this pixel the piece covers across, at a cut end; all of it
    // elsewhere.
    float across = clamp(min(gl_FragCoord.x + 0.5, vCutAcross.y) - max(gl_FragCoord.x - 0.5, vCutAcross.x), 0.0, 1.0);
    float alpha = vColor.a * across;
    if (vKind == decorationDotted) {
        // Round dots the band's height across, one at the start of each
        // pitch from the band's left edge, where the run starts, (CellInstanceBuilder's patternPitch):
        // the nearer of the dot this pixel's centre lies in the pitch of and
        // the next.
        float period = vCellSize;
        float radius = vSizePx.y * 0.5;
        float along = vLocalPx.x;
        float first = floor(along / period) * period + radius;
        float deltaY = vLocalPx.y - radius;
        // A circle fitted to the pixel grid: its square's corners rounded to
        // the radius less half a pixel (dottedRuleCornerInset), so a small dot
        // is solid and a heavy one round.
        float corner = max(radius - 0.5, 0.0);
        vec2 toThis = abs(vec2(along - first, deltaY)) - (radius - corner);
        vec2 toNext = abs(vec2(along - first - period, deltaY)) - (radius - corner);
        float apart = min(length(max(toThis, 0.0)) + min(max(toThis.x, toThis.y), 0.0),
                          length(max(toNext, 0.0)) + min(max(toNext.x, toNext.y), 0.0)) - corner;
        alpha *= clamp(0.5 - apart, 0.0, 1.0);
    } else if (vKind == decorationDashed) {
        // Dashes from the band's left edge, where the run starts, at the pitch Core chose,
        // three-fifths of it on (dashedRuleOnShare): the part of this pixel
        // the dash it lies in covers, and the one before it.
        float period = vCellSize;
        float along = vLocalPx.x;
        float start = floor(along / period) * period;
        float marks = clamp(min(along + 0.5, start + 0.6 * period) - max(along - 0.5, start), 0.0, 1.0)
            + clamp(min(along + 0.5, start - 0.4 * period) - max(along - 0.5, start - period), 0.0, 1.0);
        alpha *= min(marks, 1.0);
    }
    if (vKind == decorationDashed || vKind == decorationSolid) {
        // A straight rule is drawn at its weight exactly (ruleWeight): the
        // part of this pixel's row its band covers.
        // The fraction of this pixel's row the band covers, as every other
        // renderer takes it: the summed weight is the band's height exactly,
        // at any sub-pixel size.
        float rowTop = max(vLocalPx.y - 0.5, 0.0);
        float rowBottom = min(vLocalPx.y + 0.5, vSizePx.y);
        alpha *= max(rowBottom - rowTop, 0.0);
    } else if (vKind == decorationCurly) {
        // Circular arcs half a period across, alternately crest and trough,
        // meeting on the centre line with matching tangents (CellInstanceBuilder's
        // curlyRuleProportions): the distance to the nearest of the arc
        // this pixel lies under and its two neighbours, or to an arc's end where
        // its circle's nearest point is past it.
        float period = max(vCellSize, 2.0);
        float halfWeight = vThickness * 0.5;
        float swing = max(vSizePx.y * 0.5 - halfWeight - 0.5, 0.25);
        float middle = vSizePx.y * 0.5;
        float span = period * 0.5;
        float radius = (span * span * 0.25 + swing * swing) / (2.0 * swing);
        float index = floor(vLocalPx.x / span);
        float apart = 1.0e9;
        for (int step = -1; step <= 1; ++step) {
            float arc = index + float(step);
            // Even arcs crest toward the text, odd ones dip away from it.
            float side = arc - 2.0 * floor(arc * 0.5) < 0.5 ? -1.0 : 1.0;
            float arcLeft = arc * span;
            vec2 circle = vec2(arcLeft + span * 0.5, middle - side * (radius - swing));
            vec2 offset = vec2(vLocalPx.x, vLocalPx.y) - circle;
            float reach = length(offset);
            vec2 nearest = reach > 0.0 ? circle + offset / reach * radius : circle + vec2(0.0, side * radius);
            bool isOnArc = nearest.x >= arcLeft && nearest.x <= arcLeft + span && (side < 0.0 ? nearest.y <= middle : nearest.y >= middle);
            float distance = isOnArc ? abs(reach - radius)
                                     : min(length(vec2(vLocalPx.x - arcLeft, vLocalPx.y - middle)), length(vec2(vLocalPx.x - arcLeft - span, vLocalPx.y - middle)));
            apart = min(apart, distance);
        }
        alpha *= clamp(halfWeight + 0.5 - apart, 0.0, 1.0);
    }
    outColor = vec4(vColor.rgb, alpha);
}`;

// Overlay pass — the cursor, and the translucent selection tint.
//
// The over-blend runs in the integer domain, because a fixed-function float
// blend rounds a least-significant bit differently from the CPU's
//   out = (dst*(255-a) + color*a + 127) / 255
// once the overlay is translucent. That needs the destination readable: Vulkan
// has a subpass input, WebGL2 has none, so the cell and decoration passes render
// into an offscreen texture this pass samples by `texelFetch`. Enabling
// `gl.BLEND` instead forks this backend off the CPU oracle without failing
// anything.
const OVERLAY_VERTEX_SHADER = `#version 300 es
layout(location = 0) in vec2 inMin;          // topLeftInPixels      @0
layout(location = 1) in vec2 inMax;          // bottomRightInPixels  @8
layout(location = 2) in vec4 inColor;        // RGBA 0..1            @16
layout(location = 4) in float inStrokeWidth; // >0 = hollow outline  @40
layout(location = 3) in float inCornerRadius; // device px           @32
layout(location = 5) in float inShapeKind;    // -3 = the focused pill's ring @48
layout(location = 6) in vec4 inPlA;           // the ring's pill rect @64
layout(location = 7) in vec4 inPlB;           // the ring's shadow reach and opacity, and the cells' box x extent @80
layout(location = 8) in float inShadeDensity; // phase-locked ordered dither @44

uniform vec2 uViewportSize;

out vec2 vLocalPx;
flat out vec2 vSizePx;
flat out vec2 vOriginPx;
out vec4 vColor;
flat out float vStrokeWidth;
flat out float vCornerRadius;
flat out float vShapeKind;
flat out vec4 vPlA;
flat out vec4 vPlB;
flat out float vShadeDensity;

const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main() {
    vec2 corner = kCorners[gl_VertexID];
    vec2 sizePx = inMax - inMin;
    vec2 px = inMin + corner * sizePx;
    vec2 ndc = px / uViewportSize * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    vLocalPx = corner * sizePx;
    vSizePx = sizePx;
    vColor = inColor;
    vStrokeWidth = inStrokeWidth;
    vOriginPx = inMin;
    vCornerRadius = inCornerRadius;
    vShapeKind = inShapeKind;
    vPlA = inPlA;
    vPlB = inPlB;
    vShadeDensity = inShadeDensity;
}`;

const OVERLAY_FRAGMENT_SHADER = `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;

in vec2 vLocalPx;
flat in vec2 vSizePx;
flat in vec2 vOriginPx;
in vec4 vColor;
flat in float vStrokeWidth;
flat in float vCornerRadius;
flat in float vShapeKind;
flat in vec4 vPlA;
flat in vec4 vPlB;
flat in float vShadeDensity;

uniform sampler2D uBackground; // what the cell + decoration passes produced
uniform vec2 uViewportSize;
uniform bool uBoxFill;
uniform bool uBitmapFace;

out vec4 outColor;

// The shape parameters are emitted by Core's BoxFillEmit. These distance
// functions consume that geometry, as SoftwareRenderer::compositeBoxFill does;
// no Unicode decomposition, stroke sizing or cell clipping lives here.
float segmentDistance(vec2 p, vec2 a, vec2 b) {
    vec2 edge = b - a;
    float t = clamp(dot(p - a, edge) / max(dot(edge, edge), 1e-6), 0.0, 1.0);
    return length(p - (a + t * edge));
}

float crossProduct(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

float triangleDistance(vec2 p, vec2 a, vec2 b, vec2 c) {
    float winding = crossProduct(b - a, a - c) < 0.0 ? -1.0 : 1.0;
    float side = min(min(winding * crossProduct(p - a, b - a),
        winding * crossProduct(p - b, c - b)), winding * crossProduct(p - c, a - c));
    float distance = min(min(segmentDistance(p, a, b), segmentDistance(p, b, c)), segmentDistance(p, c, a));
    return -distance * (side < 0.0 ? -1.0 : 1.0);
}

float ellipseDistance(vec2 point, vec2 radii) {
    radii = max(radii, vec2(0.001));
    vec2 q = point / radii;
    float magnitude = max(length(q), 0.0001);
    float gradient = max(length(q / radii), 0.000001);
    return (magnitude - 1.0) * magnitude / gradient;
}

float boxCoverage() {
    vec2 local = vec2(gl_FragCoord.x, uViewportSize.y - gl_FragCoord.y) - vOriginPx;
    if (vShadeDensity > 0.0) {
        // Core/Rendering/ShadeStyle.h isShadePixelLit, with Core's grid phase in plA.x.
        ivec2 pixel = ivec2(gl_FragCoord.x, uViewportSize.y - gl_FragCoord.y);
        if (((pixel.x + 2 * pixel.y + int(vPlA.x + 0.5)) & 3) >= int(vShadeDensity * 4.0 + 0.5))
            return 0.0;
        return 1.0;
    }
    if (vShapeKind < -0.5) {
        uint columns = max(uint(vPlA.y + 0.5), 1u);
        uint rows = max(uint(vPlA.z + 0.5), 1u);
        uint column = local.x < floor(vSizePx.x * 0.5 + 0.5) ? 0u : 1u;
        uint row = rows == 2u
            ? (local.y < floor(vSizePx.y * 0.5 + 0.5) ? 0u : 1u)
            : (local.y < floor(vSizePx.y / 3.0 + 0.5) ? 0u
                : (local.y < floor(vSizePx.y * 2.0 / 3.0 + 0.5) ? 1u : 2u));
        uint bit = min(row, rows - 1u) * columns + min(column, columns - 1u);
        return ((uint(vPlA.x + 0.5) >> bit) & 1u) != 0u ? 1.0 : 0.0;
    }
    if (vShapeKind < 0.5)
        return 1.0;
    vec2 a = vPlA.xy * vSizePx;
    vec2 b = vPlA.zw * vSizePx;
    vec2 c = vPlB.xy * vSizePx;
    float distance;
    if (vShapeKind > 6.5) {
        vec2 point = max((local - a) * vPlB.zw, vec2(0.0));
        distance = ellipseDistance(point, b + c);
        if (b.x > c.x && b.y > c.y)
            distance = max(distance, -ellipseDistance(point, b - c));
    } else if (vShapeKind < 1.5) {
        distance = triangleDistance(local, a, b, c);
    } else if (vShapeKind < 2.5) {
        distance = min(segmentDistance(local, a, b), segmentDistance(local, b, c)) - vPlB.z * vSizePx.y;
    } else if (vShapeKind < 4.5) {
        float ellipse = ellipseDistance(local - a, b);
        float side = vPlB.x * (local.x - a.x);
        float halfWidth = vPlB.y * vSizePx.y;
        distance = max(vShapeKind < 3.5 ? ellipse : abs(ellipse + halfWidth) - halfWidth, -side);
    } else {
        float winding = crossProduct(b - a, c - a) < 0.0 ? -1.0 : 1.0;
        float outer = -winding * crossProduct(b - a, local - a) / max(length(b - a), 1e-6);
        if (vShapeKind < 5.5)
            outer = max(outer, -winding * crossProduct(c - b, local - b) / max(length(c - b), 1e-6));
        float halfWidth = vPlB.z * vSizePx.y;
        distance = abs(outer + halfWidth) - halfWidth;
    }
    float coverage = clamp(0.5 - distance, 0.0, 1.0);
    return uBitmapFace ? floor(coverage * 51.0 + 0.5) / 51.0 : coverage;
}

// The focused pill's ring: SoftwareRenderer::compositeFocusedPillRing in the
// same words. The pill's rect in plA with the corner radius, the shadow's
// reach and opacity in plB.xy, the matched cells' box in plB.zw; inside that
// box on the pill's row the destination is kept, everywhere else the shadow
// lands first and the pill's coverage over it, held to the 51 levels the
// page's CPU raster mixes at and mixed as integers with its rounding.
void focusedPillRing() {
    vec2 pixel = vec2(gl_FragCoord.x, uViewportSize.y - gl_FragCoord.y);
    float left = vPlA.x, top = vPlA.y, right = vPlA.z, bottom = vPlA.w;
    if (pixel.x >= vPlB.z && pixel.x < vPlB.w && pixel.y >= top && pixel.y < bottom)
        discard;
    float halfX = (right - left) * 0.5, halfY = (bottom - top) * 0.5;
    float excessX = max(abs(pixel.x - (left + halfX)) - (halfX - vCornerRadius), 0.0);
    float excessY = max(abs(pixel.y - (top + halfY)) - (halfY - vCornerRadius), 0.0);
    float distance = sqrt(excessX * excessX + excessY * excessY) - vCornerRadius;
    float pillCoverage = floor(clamp(0.5 - distance, 0.0, 1.0) * 51.0 + 0.5) / 51.0;
    float falloff = vPlB.x > 0.0 ? 1.0 - clamp(distance / vPlB.x, 0.0, 1.0) : 0.0;
    float shadow = floor(vPlB.y * falloff * falloff * 51.0 + 0.5) / 51.0;
    int shadowByte = clamp(int(shadow * 255.0 + 0.5), 0, 255);
    int pillByte = clamp(int(pillCoverage * 255.0 + 0.5), 0, 255);
    if (shadowByte <= 0 && pillByte <= 0)
        discard;
    vec4 dst = texelFetch(uBackground, ivec2(gl_FragCoord.xy), 0);
    ivec3 rgb = ivec3(round(dst.rgb * 255.0));
    if (shadowByte > 0)
        rgb = (rgb * (255 - shadowByte) + ivec3(127)) / 255;
    if (pillByte > 0) {
        ivec3 pill = ivec3(round(vColor.rgb * 255.0));
        rgb = (rgb * (255 - pillByte) + pill * pillByte + ivec3(127)) / 255;
    }
    outColor = vec4(vec3(rgb) / 255.0, 1.0);
}

void main() {
    if (vShapeKind < -2.5) {
        focusedPillRing();
        return;
    }
    // strokeWidth > 0 is the hollow (unfocused) cursor: keep the border ring,
    // drop the interior so the text under it stays readable.
    if (vStrokeWidth > 0.0 && vCornerRadius <= 0.0) {
        bool inBorder = vLocalPx.x < vStrokeWidth
            || vLocalPx.x >= vSizePx.x - vStrokeWidth
            || vLocalPx.y < vStrokeWidth
            || vLocalPx.y >= vSizePx.y - vStrokeWidth;
        if (!inBorder)
            discard;
    }

    // Quantize exactly as the CPU does: toByte = round(x*255), alpha with the
    // +0.5 truncation.
    int colorR = int(round(vColor.r * 255.0));
    int colorG = int(round(vColor.g * 255.0));
    int colorB = int(round(vColor.b * 255.0));
    int alpha = int(vColor.a * 255.0 + 0.5);
    if (uBoxFill && vShapeKind != -2.0) {
        alpha = int(vColor.a * boxCoverage() * 255.0 + 0.5);
    } else if (vShapeKind == -2.0) {
        // Braille ink bounds are independent of the expanded coverage quad.
        vec2 pixel = (vPlA.xy + vPlA.zw) * 0.5 + vLocalPx - vSizePx * 0.5;
        float coverage;
        if (vCornerRadius <= 0.0) {
            vec2 extent = clamp(min(pixel + 0.5, vPlA.zw) - max(pixel - 0.5, vPlA.xy), 0.0, 1.0);
            coverage = extent.x * extent.y;
        } else {
            float distance = length(pixel - (vPlA.xy + vPlA.zw) * 0.5) - vCornerRadius;
            if (vStrokeWidth > 0.0)
                distance = abs(distance + vStrokeWidth * 0.5) - vStrokeWidth * 0.5;
            coverage = clamp(0.5 - distance, 0.0, 1.0);
        }
        if (!uBoxFill || uBitmapFace)
            coverage = floor(coverage * 51.0 + 0.5) / 51.0;
        alpha = int(vColor.a * coverage * 255.0 + 0.5);
    } else if (vCornerRadius > 0.0) {
        vec2 excess = max(abs(vLocalPx - vSizePx * 0.5) - (vSizePx * 0.5 - vCornerRadius), 0.0);
        float distance = length(excess) - vCornerRadius;
        float strokeDistance = abs(distance + vStrokeWidth * 0.5) - vStrokeWidth * 0.5;
        float coverage = vStrokeWidth > 0.0
            ? (strokeDistance < 0.0 ? 1.0 : 0.0)
            : floor(clamp(0.5 - distance, 0.0, 1.0) * 51.0 + 0.5) / 51.0;
        alpha = int(vColor.a * coverage * 255.0 + 0.5);
    }
    if (alpha <= 0)
        discard;

    // Box quads compose in emitted order, including crossing diagonals. The
    // byte-quantized alpha matches Core; fixed-function blending avoids a
    // framebuffer copy for each overlapping shape.
    if (uBoxFill) {
        outColor = vec4(vec3(colorR, colorG, colorB) / 255.0, float(alpha) / 255.0);
        return;
    }

    // The destination, read back the way subpassLoad reads it. Both this pass
    // and the source render with the same Y flip, so the fragment coordinate
    // indexes the texture directly.
    vec4 dst = texelFetch(uBackground, ivec2(gl_FragCoord.xy), 0);

    if (alpha >= 255) {
        // Opaque, the focused-cursor case: write the colour verbatim.
        outColor = vec4(float(colorR) / 255.0, float(colorG) / 255.0, float(colorB) / 255.0, 1.0);
        return;
    }

    int dr = int(round(dst.r * 255.0));
    int dg = int(round(dst.g * 255.0));
    int db = int(round(dst.b * 255.0));
    int invAlpha = 255 - alpha;
    int outR = (dr * invAlpha + colorR * alpha + 127) / 255;
    int outG = (dg * invAlpha + colorG * alpha + 127) / 255;
    int outB = (db * invAlpha + colorB * alpha + 127) / 255;
    outColor = vec4(float(outR) / 255.0, float(outG) / 255.0, float(outB) / 255.0, 1.0);
}`;

function compile(gl, type, source, label) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS))
    throw new Error(`${label}: ${gl.getShaderInfoLog(shader)}`);
  return shader;
}

function link(gl, vertexSource, fragmentSource, label) {
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vertexSource, `${label} vertex`));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragmentSource, `${label} fragment`));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS))
    throw new Error(`${label} link: ${gl.getProgramInfoLog(program)}`);
  return program;
}

// Construction throws when WebGL2 is absent or a shader will not compile. That
// is a signal to fall back to the CPU compositor, which draws the same
// instances: the frontend degrades in speed, never in output.
// The strides above are Core's sizeof, compared at startup: a mismatch means
// the page reads instance fields from the wrong offsets, which draws garbage
// rather than failing anywhere on its own.
export function assertInstanceStrides(module) {
  const pinned = [
    ['overlay', OVERLAY_INSTANCE_STRIDE, module._ubiquittyWebOverlayInstanceStride],
    ['decoration', DECORATION_INSTANCE_STRIDE, module._ubiquittyWebDecorationInstanceStride],
    ['glyph', WIDE_GLYPH_INSTANCE_STRIDE, module._ubiquittyWebGlyphInstanceStride],
  ];
  for (const [name, pageStride, coreStride] of pinned) {
    if (typeof coreStride !== 'function')
      continue; // an older module without the exports answers for itself
    const core = coreStride();
    if (core !== pageStride)
      throw new Error(`instance stride mismatch: ${name} page=${pageStride} core=${core}`);
  }
}

// Present the software-composited Core raster with a draw to the canvas.
const RGBA_VERTEX_SHADER = `#version 300 es
out vec2 texturePosition;
void main() {
    vec2 point = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    texturePosition = vec2(point.x, 1.0 - point.y);
    gl_Position = vec4(point * 2.0 - 1.0, 0.0, 1.0);
}`;
const RGBA_FRAGMENT_SHADER = `#version 300 es
precision highp float;
uniform sampler2D raster;
in vec2 texturePosition;
out vec4 color;
void main() { color = texture(raster, texturePosition); }
`;

export class WebGLRenderer {
  constructor(canvas) {
    const gl = canvas.getContext('webgl2', {
      alpha: false,
      antialias: false,     // the glyphs carry their own coverage
      depth: false,
      stencil: false,
      preserveDrawingBuffer: false,
    });
    if (!gl) throw new Error('WebGL2 unavailable');
    this.gl = gl;
    this.canvas = canvas;
    this.rgbaProgram = link(gl, RGBA_VERTEX_SHADER, RGBA_FRAGMENT_SHADER, 'raster');
    this.rgbaSampler = gl.getUniformLocation(this.rgbaProgram, 'raster');
    this.rgbaVao = gl.createVertexArray();

    this.program = link(gl, CELL_VERTEX_SHADER, CELL_FRAGMENT_SHADER, 'cell');
    this.uViewportSize = gl.getUniformLocation(this.program, 'uViewportSize');
    this.uCellSize = gl.getUniformLocation(this.program, 'uCellSize');
    this.uAtlas = gl.getUniformLocation(this.program, 'uAtlas');

    this.instanceBuffer = gl.createBuffer();
    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.instanceBuffer);
    // Attribute locations are CellInstance's field offsets. Declaring them by
    // offset rather than by a JS-side mirror of the struct leaves nothing here
    // that can silently disagree: if the C++ layout moves, CellInstance's own
    // static_asserts fail before this file is ever reached.
    const attribute = (location, size, offset) => {
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, size, gl.FLOAT, false, CELL_INSTANCE_STRIDE, offset);
      gl.vertexAttribDivisor(location, 1); // per instance, not per vertex
    };
    attribute(0, 2, 0);   // gridPosition
    attribute(1, 1, 8);   // widthCells
    attribute(3, 4, 16);  // foreground
    attribute(4, 4, 32);  // background
    attribute(5, 2, 48);  // atlasTopLeft
    attribute(6, 2, 56);  // atlasBottomRight
    gl.bindVertexArray(null);

    this.atlasTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.atlasTexture);
    // Nearest, clamped: the fragment shader fetches exact texels, so any
    // filtering here would be sampled-over and break the CPU parity.
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.atlasWidth = 0;
    this.atlasHeight = 0;

    this.decorationProgram = link(gl, DECORATION_VERTEX_SHADER, DECORATION_FRAGMENT_SHADER, 'decoration');
    this.dViewportSize = gl.getUniformLocation(this.decorationProgram, 'uViewportSize');
    this.decorationBuffer = gl.createBuffer();
    this.decorationVao = gl.createVertexArray();
    gl.bindVertexArray(this.decorationVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.decorationBuffer);
    const decorationAttribute = (location, size, offset) => {
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, size, gl.FLOAT, false, DECORATION_INSTANCE_STRIDE, offset);
      gl.vertexAttribDivisor(location, 1);
    };
    decorationAttribute(0, 2, 0);   // topLeftInPixels
    decorationAttribute(1, 2, 8);   // bottomRightInPixels
    decorationAttribute(2, 4, 16);  // color
    decorationAttribute(3, 4, 32);  // kind, dashPeriodInPixels, thicknessInPixels, cutEnds
    decorationAttribute(4, 4, 48);  // bandTopLeftInPixels, bandBottomRightInPixels
    gl.bindVertexArray(null);

    this.wideGlyphProgram = link(gl, WIDE_GLYPH_VERTEX_SHADER, WIDE_GLYPH_FRAGMENT_SHADER, 'wide-glyph');
    this.wViewportSize = gl.getUniformLocation(this.wideGlyphProgram, 'uViewportSize');
    this.wAtlas = gl.getUniformLocation(this.wideGlyphProgram, 'uWideAtlas');
    this.wideGlyphBuffer = gl.createBuffer();
    this.wideGlyphVao = gl.createVertexArray();
    gl.bindVertexArray(this.wideGlyphVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.wideGlyphBuffer);
    const wideAttribute = (location, size, offset) => {
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, size, gl.FLOAT, false, WIDE_GLYPH_INSTANCE_STRIDE, offset);
      gl.vertexAttribDivisor(location, 1);
    };
    wideAttribute(0, 2, 0);   // originInPixels
    wideAttribute(1, 2, 8);   // sizeInPixels
    wideAttribute(2, 4, 16);  // foreground
    wideAttribute(3, 4, 32);  // background
    wideAttribute(4, 2, 48);  // atlasTopLeft
    wideAttribute(5, 2, 56);  // atlasBottomRight
    gl.bindVertexArray(null);

    // Its own texture. The wide page is the same size as the mono one but its
    // slots are two cells across, so the same coordinate names a different glyph
    // on each — they cannot share a texture or a coordinate space.
    this.wideAtlasTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.wideAtlasTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.wideAtlasWidth = 0;
    this.wideAtlasHeight = 0;

    // Core supplies placement, cache identity, and pixels; this pass only binds
    // the proportional sheet and consumes the shared GlyphInstance layout.
    this.proportionalGlyphProgram = link(gl, PROPORTIONAL_GLYPH_VERTEX_SHADER, PROPORTIONAL_GLYPH_FRAGMENT_SHADER, 'proportional-glyph');
    this.proportionalViewportSize = gl.getUniformLocation(this.proportionalGlyphProgram, 'uViewportSize');
    this.proportionalAtlasUniform = gl.getUniformLocation(this.proportionalGlyphProgram, 'uProportionalAtlas');
    this.proportionalAtlasTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.proportionalAtlasTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.proportionalAtlasWidth = 0;
    this.proportionalAtlasHeight = 0;
    this.proportionalStripAtlasTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.proportionalStripAtlasTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.proportionalStripAtlasWidth = 0;
    this.proportionalStripAtlasHeight = 0;
    this.ligatureAtlasTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.ligatureAtlasTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.ligatureAtlasWidth = 0;
    this.ligatureAtlasHeight = 0;

    // Shares the wide pass's vertex shader because it shares its instance
    // layout: both are GlyphInstance, both placed in device pixels by the
    // builder. Only the fragment stage differs.
    this.colorGlyphProgram = link(gl, WIDE_GLYPH_VERTEX_SHADER, COLOR_GLYPH_FRAGMENT_SHADER, 'color-glyph');
    this.cgViewportSize = gl.getUniformLocation(this.colorGlyphProgram, 'uViewportSize');
    this.cgAtlas = gl.getUniformLocation(this.colorGlyphProgram, 'uColorAtlas');
    this.colorGlyphBuffer = gl.createBuffer();
    this.colorGlyphVao = gl.createVertexArray();
    gl.bindVertexArray(this.colorGlyphVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.colorGlyphBuffer);
    const colorAttribute = (location, size, offset) => {
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, size, gl.FLOAT, false, WIDE_GLYPH_INSTANCE_STRIDE, offset);
      gl.vertexAttribDivisor(location, 1);
    };
    colorAttribute(0, 2, 0);   // originInPixels
    colorAttribute(1, 2, 8);   // sizeInPixels
    colorAttribute(2, 4, 16);  // foreground
    colorAttribute(3, 4, 32);  // background
    colorAttribute(4, 2, 48);  // atlasTopLeft
    colorAttribute(5, 2, 56);  // atlasBottomRight
    gl.bindVertexArray(null);

    // NEAREST, like the coverage sheets, because the CPU raster is the oracle
    // this pass is checked against and it samples nearest. LINEAR looks better in
    // isolation and puts the two arms permanently ~240 pixels apart on an emoji,
    // which costs the only check either arm has.
    this.colorAtlasTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.colorAtlasTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.colorAtlasWidth = 0;
    this.colorAtlasHeight = 0;

    this.overlayProgram = link(gl, OVERLAY_VERTEX_SHADER, OVERLAY_FRAGMENT_SHADER, 'overlay');
    this.oViewportSize = gl.getUniformLocation(this.overlayProgram, 'uViewportSize');
    this.oBackground = gl.getUniformLocation(this.overlayProgram, 'uBackground');
    this.oBoxFill = gl.getUniformLocation(this.overlayProgram, 'uBoxFill');
    this.oBitmapFace = gl.getUniformLocation(this.overlayProgram, 'uBitmapFace');
    this.overlayBuffer = gl.createBuffer();
    this.overlayVao = gl.createVertexArray();
    gl.bindVertexArray(this.overlayVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.overlayBuffer);
    const overlayAttribute = (location, size, offset) => {
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, size, gl.FLOAT, false, OVERLAY_INSTANCE_STRIDE, offset);
      gl.vertexAttribDivisor(location, 1);
    };
    overlayAttribute(0, 2, 0);   // topLeftInPixels
    overlayAttribute(1, 2, 8);   // bottomRightInPixels
    overlayAttribute(2, 4, 16);  // color
    overlayAttribute(4, 1, 40);  // strokeWidth — cornerStyle sits at 36
    overlayAttribute(3, 1, 32);  // cornerRadius
    overlayAttribute(5, 1, 48);  // shapeKind
    overlayAttribute(6, 4, 64);  // plA
    overlayAttribute(7, 4, 80);  // plB
    overlayAttribute(8, 1, 44);  // shadeDensity
    gl.bindVertexArray(null);

    // The offscreen target the overlay pass reads. This is what stands in for
    // Vulkan's subpassInput: cells and decorations render here, this texture is
    // blitted to the canvas, and the overlay pass samples it while writing over
    // the top — which is the same read the integer blend needs.
    this.sceneFramebuffer = gl.createFramebuffer();
    this.sceneTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.sceneTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.sceneWidth = 0;
    this.sceneHeight = 0;
  }

  // Sizes the offscreen target to the viewport. RGBA8 rather than a renderbuffer
  // because the overlay pass has to sample it.
  resizeScene(width, height) {
    if (width === this.sceneWidth && height === this.sceneHeight) return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.sceneTexture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.sceneFramebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.sceneTexture, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    this.sceneWidth = width;
    this.sceneHeight = height;
  }

  // Core composites image and Tek frames on the CPU. A canvas cannot change
  // context type after WebGL claimed it, so present those pixels through the
  // same GPU surface instead of asking it for an unavailable 2D context.
  presentRGBA(pixels, width, height) {
    const gl = this.gl;
    gl.activeTexture(gl.TEXTURE0);
    this.resizeScene(width, height);
    gl.bindTexture(gl.TEXTURE_2D, this.sceneTexture);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, width, height);
    gl.disable(gl.BLEND);
    gl.useProgram(this.rgbaProgram);
    gl.uniform1i(this.rgbaSampler, 0);
    gl.bindVertexArray(this.rgbaVao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindVertexArray(null);
  }

  // Re-uploads the coverage atlas. Cheap to call every frame while the atlas is
  // unchanged in size, but the caller passes a generation so a frame that
  // faulted no new glyph skips the upload entirely.
  // The wide page. A separate upload because it is a separate texture of a
  // different size, which neither the mono page's texture nor its upload can
  // stand in for.
  uploadWideAtlas(pixels, width, height) {
    if (!pixels || width <= 0 || height <= 0)
      return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.wideAtlasTexture);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1); // R8 rows are not 4-byte aligned
    if (width !== this.wideAtlasWidth || height !== this.wideAtlasHeight) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
      this.wideAtlasWidth = width;
      this.wideAtlasHeight = height;
    } else {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RED, gl.UNSIGNED_BYTE, pixels);
    }
  }

  uploadColorAtlas(pixels, width, height) {
    if (!pixels || width <= 0 || height <= 0)
      return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.colorAtlasTexture);
    // RGBA rows are 4-byte aligned by construction, so this needs no
    // UNPACK_ALIGNMENT of 1 the way the R8 sheets do.
    if (width !== this.colorAtlasWidth || height !== this.colorAtlasHeight) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      this.colorAtlasWidth = width;
      this.colorAtlasHeight = height;
    } else {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    }
  }

  uploadProportionalAtlas(pixels, width, height) {
    if (!pixels || width <= 0 || height <= 0) return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.proportionalAtlasTexture);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    if (width !== this.proportionalAtlasWidth || height !== this.proportionalAtlasHeight) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
      this.proportionalAtlasWidth = width;
      this.proportionalAtlasHeight = height;
    } else {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RED, gl.UNSIGNED_BYTE, pixels);
    }
  }

  uploadLigatureAtlas(pixels, width, height) {
    if (!pixels || width <= 0 || height <= 0) return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.ligatureAtlasTexture);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    if (width !== this.ligatureAtlasWidth || height !== this.ligatureAtlasHeight) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
      this.ligatureAtlasWidth = width;
      this.ligatureAtlasHeight = height;
    } else {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RED, gl.UNSIGNED_BYTE, pixels);
    }
  }

  uploadProportionalStripAtlas(pixels, width, height) {
    if (!pixels || width <= 0 || height <= 0) return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.proportionalStripAtlasTexture);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    if (width !== this.proportionalStripAtlasWidth || height !== this.proportionalStripAtlasHeight) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
      this.proportionalStripAtlasWidth = width;
      this.proportionalStripAtlasHeight = height;
    } else {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RED, gl.UNSIGNED_BYTE, pixels);
    }
  }

  uploadAtlas(pixels, width, height) {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.atlasTexture);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1); // R8 rows are not 4-byte aligned
    if (width !== this.atlasWidth || height !== this.atlasHeight) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
      this.atlasWidth = width;
      this.atlasHeight = height;
    } else {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RED, gl.UNSIGNED_BYTE, pixels);
    }
  }

  // One layer of the grid streams, in the CPU compositor's pass order: the
  // cells, the two-cell page, the proportional glyphs and strips, the shaped
  // runs, the emoji, then the rules. `streams` carries one segment of each
  // stream — the head or the cursor tier's tail — as bytes and counts.
  drawGridStreams(streams, width, height) {
    const gl = this.gl;
    const { cellWidth, cellHeight } = streams;
    // The cell pass is opaque and covers every cell, so it establishes the frame
    // rather than blending into whatever the last one left.
    gl.disable(gl.BLEND);
    if (streams.cellCount > 0) {
      gl.useProgram(this.program);
      gl.uniform2f(this.uViewportSize, width, height);
      gl.uniform2f(this.uCellSize, cellWidth, cellHeight);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.atlasTexture);
      gl.uniform1i(this.uAtlas, 0);
      gl.bindVertexArray(this.vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.instanceBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.cellBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.cellCount);
    }

    // Core's box geometry extends beyond a cell where diagonal joins need it.
    // Draw it after every background, never baked into a cell-sized atlas quad.
    if (streams.boxFillCount > 0) {
      gl.enable(gl.BLEND);
      gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ZERO, gl.ONE);
      gl.useProgram(this.overlayProgram);
      gl.uniform2f(this.oViewportSize, width, height);
      gl.uniform1i(this.oBoxFill, 1);
      gl.uniform1i(this.oBitmapFace, streams.isBitmapFace ? 1 : 0);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.atlasTexture);
      gl.uniform1i(this.oBackground, 0);
      gl.bindVertexArray(this.overlayVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.overlayBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.boxFillBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.boxFillCount);
      gl.uniform1i(this.oBoxFill, 0);
      gl.disable(gl.BLEND);
    }

    // Scripted and fractionally sized mono glyphs carry their own geometry.
    if (streams.glyphCount > 0) {
      gl.useProgram(this.wideGlyphProgram);
      gl.uniform2f(this.wViewportSize, width, height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.atlasTexture);
      gl.uniform1i(this.wAtlas, 0);
      gl.bindVertexArray(this.wideGlyphVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.wideGlyphBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.glyphBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.glyphCount);
    }

    // Two-cell glyphs, from their own page. After the cell pass, which has
    // already laid down their background, and before the decorations, so an
    // underline crosses the glyph rather than sitting behind it.
    //
    // Blending stays OFF: the shader mixes against the background the builder
    // recorded on the instance, so the result does not depend on what the cell
    // pass happened to leave in the framebuffer.
    if (streams.wideGlyphCount > 0) {
      gl.useProgram(this.wideGlyphProgram);
      gl.uniform2f(this.wViewportSize, width, height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.wideAtlasTexture);
      gl.uniform1i(this.wAtlas, 0);
      gl.bindVertexArray(this.wideGlyphVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.wideGlyphBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.wideGlyphBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.wideGlyphCount);
    }

    if (streams.proportionalGlyphCount > 0) {
      gl.useProgram(this.proportionalGlyphProgram);
      gl.uniform2f(this.proportionalViewportSize, width, height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.proportionalAtlasTexture);
      gl.uniform1i(this.proportionalAtlasUniform, 0);
      gl.bindVertexArray(this.wideGlyphVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.wideGlyphBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.proportionalGlyphBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.proportionalGlyphCount);
    }

    if (streams.proportionalStripCount > 0) {
      gl.useProgram(this.proportionalGlyphProgram);
      gl.uniform2f(this.proportionalViewportSize, width, height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.proportionalStripAtlasTexture);
      gl.uniform1i(this.proportionalAtlasUniform, 0);
      gl.bindVertexArray(this.wideGlyphVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.wideGlyphBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.proportionalStripBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.proportionalStripCount);
    }

    if (streams.ligatureGlyphCount > 0) {
      gl.useProgram(this.proportionalGlyphProgram);
      gl.uniform2f(this.proportionalViewportSize, width, height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.ligatureAtlasTexture);
      gl.uniform1i(this.proportionalAtlasUniform, 0);
      gl.bindVertexArray(this.wideGlyphVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.wideGlyphBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.ligatureGlyphBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.ligatureGlyphCount);
    }

    // Emoji after the coverage glyphs and before the decorations, so an underline
    // still crosses them — the sheet's alpha would otherwise cover the rule the
    // pen asked for.
    //
    // Blending ON, unlike every glyph pass above it: those replace, because the
    // instance carries the background they sit on. An emoji's quad reaches past
    // its own cell, so it has to compose with what is already there.
    if (streams.colorGlyphCount > 0) {
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      gl.useProgram(this.colorGlyphProgram);
      gl.uniform2f(this.cgViewportSize, width, height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.colorAtlasTexture);
      gl.uniform1i(this.cgAtlas, 0);
      gl.bindVertexArray(this.colorGlyphVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.colorGlyphBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.colorGlyphBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.colorGlyphCount);
      gl.disable(gl.BLEND);
    }

    // Rules carry their own alpha (the pattern mask), so this pass blends
    // rather than replacing. They sample no sheet: Core cut them around glyph
    // ink and sent the pieces left standing.
    if (streams.decorationCount > 0) {
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      gl.useProgram(this.decorationProgram);
      gl.uniform2f(this.dViewportSize, width, height);
      gl.bindVertexArray(this.decorationVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.decorationBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, streams.decorationBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, streams.decorationCount);
      gl.disable(gl.BLEND);
    }
  }


  // Draws one frame: cells, then decorations over them, then the cursor and
  // selection over both. The first two render into the offscreen target so the
  // overlay pass can read what it is blending against.
  //
  // The pass order is the CPU compositor's, because they render the same
  // instances and any divergence here is a divergence from the oracle.
  drawFrame(frame) {
    const gl = this.gl;
    const { overlayBytes, overlayCount, width, height } = frame;

    this.resizeScene(width, height);
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.sceneFramebuffer);
    gl.viewport(0, 0, width, height);

    // The grid streams are drawn twice over: the heads, which are the grid,
    // and then the tails, which are the cursor tier — the cursor's cell
    // re-emitted with the cursor's colours — as one layer after every head,
    // so the cell's own ink is not composited a second time under the tier's.
    this.drawGridStreams(sliceStreams(frame, "head"), width, height);
    this.drawGridStreams(sliceStreams(frame, "tier"), width, height);

    // Put the scene on the canvas, then draw the overlays over it while reading
    // the scene texture. Blending is OFF for that pass: the shader does the
    // over-blend itself, in the integer domain, because a fixed-function float
    // blend rounds differently from the CPU once the overlay is translucent.
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, this.sceneFramebuffer);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
    gl.blitFramebuffer(0, 0, width, height, 0, 0, width, height, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);

    if (overlayCount > 0) {
      gl.viewport(0, 0, width, height);
      gl.disable(gl.BLEND);
      gl.useProgram(this.overlayProgram);
      gl.uniform2f(this.oViewportSize, width, height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.sceneTexture);
      gl.uniform1i(this.oBackground, 0);
      gl.bindVertexArray(this.overlayVao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.overlayBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, overlayBytes, gl.STREAM_DRAW);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, overlayCount);
    }
    gl.bindVertexArray(null);
  }
}
