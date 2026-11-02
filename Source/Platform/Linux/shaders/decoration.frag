#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// A verbatim port of UBShaders.metal's decorationFragment: emits the rule color
// masked by `kind` (solid = full; dotted = round balls; dashed = 65% duty;
// curly = a sine wave), then — for underline rules with skipInk set — cuts the
// rule where glyph ink (dilated by padInAtlas, from the cell and both
// neighbours) crosses the band, so descenders break
// the line cleanly. Alpha drives the blend (the decoration pipeline blends over
// the cell pass). No srgbToLinear — the CPU SoftwareRenderer blends in sRGB too,
// keeping the CPU/GPU outputs a matched oracle pair.
layout(location = 0) flat in vec4 inRect;
layout(location = 1) in vec4 inColor;
layout(location = 2) flat in vec4 inParams;
layout(location = 3) flat in vec4 inInk;
layout(location = 4) flat in vec4 inPad;
layout(location = 5) flat in vec4 inSlot;
layout(location = 6) flat in vec4 inLeftInk;
layout(location = 7) flat in vec4 inLeftBox;
layout(location = 8) flat in vec4 inRightInk;
layout(location = 9) flat in vec4 inRightBox;
layout(location = 10) flat in float inBitmapTier;

layout(binding = 0) uniform sampler2D uAtlas;
layout(binding = 2) uniform sampler2D uProportionalStripSheet;
layout(binding = 3) uniform sampler2D uLigatureStripSheet;
layout(binding = 4) uniform sampler2D uProportionalSheet; // the dedicated glyph sheet, for a run drawn glyph by glyph

layout(location = 0) out vec4 outColor;

const float decorationDotted = 1.0;
const float decorationDashed = 2.0;
const float decorationCurly = 3.0;

// The texel a tap names, read whole and clamped to the sheet, as the CPU
// truncates and clamps: a coordinate divided by the size and sampled back can
// land a hair to the other side of a texel edge.
float texelTap(sampler2D sheet, vec2 uv)
{
    ivec2 size = textureSize(sheet, 0);
    return texelFetch(sheet, clamp(ivec2(floor(uv)), ivec2(0), size - 1), 0).r;
}

float sheetTap(int sheetSelector, vec2 uv)
{
    return sheetSelector == 1 ? texelTap(uProportionalStripSheet, uv)
        : sheetSelector == 2  ? texelTap(uLigatureStripSheet, uv)
        : sheetSelector == 3  ? texelTap(uProportionalSheet, uv)
                              : texelTap(uAtlas, uv);
}

// The tap's nudge off the texel grid, SoftwareRenderer's skipInkTapBias.
const float skipInkTapBias = 1.0 / 128.0;

// The glyph's coverage dilated by a disc of radius padUV, on a grid whose taps
// stay about a pixel apart, as SoftwareRenderer::compositeDecoration takes it.
// Only the glyph's own slot answers: a tap past its edge would read the glyph
// packed beside it. A slot whose max does not pass its min is absent.
float discCoverage(int sheetSelector, vec2 centre, vec2 padUV, int steps, vec2 minSlot, vec2 maxSlot)
{
    if (maxSlot.x <= minSlot.x)
        return 0.0;
    precise vec2 stepUV = padUV / float(steps);
    float strongest = 0.0;
    for (int dy = -steps; dy <= steps; ++dy)
        for (int dx = -steps; dx <= steps; ++dx) {
            if (dx * dx + dy * dy > steps * steps)
                continue;
            precise vec2 uv = centre + vec2(float(dx), float(dy)) * stepUV + skipInkTapBias;
            if (uv.x < minSlot.x || uv.x > maxSlot.x || uv.y < minSlot.y || uv.y > maxSlot.y)
                continue;
            strongest = max(strongest, sheetTap(sheetSelector, uv));
        }
    return strongest;
}

void main()
{
    // The pixel's centre from the rule's top-left, taken from the fragment's
    // own position rather than interpolated across the quad: the same
    // arithmetic SoftwareRenderer::compositeDecoration does, so a skip-ink tap
    // that lands near a texel or slot edge rounds the same way on both.
    precise vec2 inLocalPx = gl_FragCoord.xy - inRect.xy;
    vec2 inSizePx = inRect.zw;
    float inKind = inParams.x;
    float inCellSize = inParams.y;
    float inThickness = inParams.z;
    float alpha = inColor.a;
    if (inKind == decorationDotted) {
        float r = max(inSizePx.y * 0.5, 1.0);
        float period = max(inCellSize * 0.5, r * 3.0);
        float cx = (floor(inLocalPx.x / period) + 0.5) * period;
        float dx = inLocalPx.x - cx;
        float dy = inLocalPx.y - inSizePx.y * 0.5;
        float d = length(vec2(dx, dy));
        alpha *= clamp(r + 0.5 - d, 0.0, 1.0);
    } else if (inKind == decorationDashed) {
        float period = max(inCellSize, inThickness * 6.0);
        float phase = fract(inLocalPx.x / period);
        if (phase >= 0.65)
            alpha = 0.0;
        // A dash's band is the stroke itself, so the band's height is the
        // weight the thickness setting asks for. Sampling at pixel centers
        // alone answers only in whole rows, quantizing that weight to the pixel
        // grid; taking the fraction of its own row that the band covers makes
        // the summed weight the band's height exactly, at any sub-pixel size.
        // The other kinds draw a shape within a band built with slack and take
        // their edge softness from that shape's own falloff.
        float rowTop = max(inLocalPx.y - 0.5, 0.0);
        float rowBottom = min(inLocalPx.y + 0.5, inSizePx.y);
        alpha *= max(rowBottom - rowTop, 0.0);
    } else if (inKind == decorationCurly) {
        float period = max(inCellSize, 2.0);
        float halfThick = inThickness * 0.8;
        float amp = max(inSizePx.y * 0.5 - halfThick, 0.5);
        float mid = inSizePx.y * 0.5;
        float wave = mid + amp * sin(inLocalPx.x / period * 6.2831853);
        float dist = abs(inLocalPx.y - wave);
        alpha *= clamp(halfThick + 0.5 - dist, 0.0, 1.0);
    }

    if (inParams.w > 0.5) {
        int steps = max(int(inPad.z + 0.5), 1);
        int selectors = int(inPad.w + 0.5);
        precise vec2 fraction = vec2(inSizePx.x > 0.0 ? inLocalPx.x / inSizePx.x : 0.0,
            inSizePx.y > 0.0 ? inLocalPx.y / inSizePx.y : 0.0);
        precise vec2 inkUV = inInk.xy + fraction * (inInk.zw - inInk.xy);
        float cov = discCoverage(selectors % 8, inkUV, inPad.xy, steps, inSlot.xy, inSlot.zw);
        // A rule is per cell, so a descender leaning in from the cell beside
        // it is cut by this cell's rule too: a point fraction.x of the way
        // across this cell is (fraction.x + 1) of the way across the left cell
        // and (fraction.x - 1) across the right one.
        precise vec2 leftUV = vec2(inLeftInk.x + (fraction.x + 1.0) * (inLeftInk.y - inLeftInk.x),
            inLeftInk.z + fraction.y * (inLeftInk.w - inLeftInk.z));
        cov = max(cov, discCoverage((selectors / 8) % 8, leftUV, inPad.xy, steps, inLeftBox.xy, inLeftBox.zw));
        precise vec2 rightUV = vec2(inRightInk.x + (fraction.x - 1.0) * (inRightInk.y - inRightInk.x),
            inRightInk.z + fraction.y * (inRightInk.w - inRightInk.z));
        cov = max(cov, discCoverage((selectors / 64) % 8, rightUV, inPad.xy, steps, inRightBox.xy, inRightBox.zw));
        alpha *= clamp(1.0 - cov, 0.0, 1.0);
    }
    // Held to the 51 coverage levels the software renderer mixes at in the
    // bitmap tier: each an exact byte, so the blender narrowing it to eight
    // bits keeps the value, and a sin a millionth apart cannot round a byte
    // the other way. The CPU raster quantises only for Core's bitmap face,
    // so a native face keeps its coverage whole here as it does there.
    if (inBitmapTier > 0.5)
        alpha = floor(alpha * 51.0 + 0.5) / 51.0;
    outColor = vec4(inColor.rgb, alpha);
}
