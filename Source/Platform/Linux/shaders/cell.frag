#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

layout(location = 0) in vec4 inForeground;
layout(location = 1) in vec4 inBackground;
layout(location = 2) flat in float inHasGlyph;
layout(location = 3) flat in vec2 inCellOriginPx; // cell top-left, device px
layout(location = 4) flat in vec2 inAtlasMin; // glyph UV slot top-left
layout(location = 5) flat in vec2 inAtlasMax; // glyph UV slot bottom-right
layout(location = 6) flat in vec2 inCellSizePx;

layout(binding = 0) uniform sampler2D uAtlas; // R8 glyph coverage

// Which part of the cell this pipeline paints, as SoftwareRenderer's CellPaint
// names them: 0 the ground and the ink together, 1 the ground alone, 2 the ink
// alone. A frame with a picture under its text paints the ground, then the
// picture, then the ink. The ink pipeline blends in the fixed-function unit, so
// this stage hands it the foreground and the coverage as its alpha. A partly
// covered pixel can then round one level apart from the CPU's integer mix; a
// frame with no picture under its text never takes this path.
layout(constant_id = 0) const int cellPaint = 0;

layout(location = 0) out vec4 outColor;

// Cell-background pass: paint the cell background, then mix the glyph foreground over it
// by the atlas coverage.
//
// Two things keep this byte-identical to the CPU SoftwareRenderer (the
// CPU<->GPU golden-image oracle) once coverage is anti-aliased (not just 0/255):
//
//  1. Coverage is sampled by integer texelFetch from the cell-local pixel's
//     centre mapped across the complete atlas rect. An interpolated UV can
//     select a neighbouring texel at a boundary; the CPU computes this same
//     coordinate directly, including doubled-row geometry.
//
//  2. The mix runs in the INTEGER domain (0..255) and is emitted as byte/255. The
//     float mix(background,foreground,cov) -> UNORM8 store rounds a LSB differently on the CPU vs
//     lavapipe (float32 contraction + the store's rounding). Computing
//     round((background*(255-cov)+foreground*cov)/255) as integers — the same formula the CPU
//     runs — and outputting r/255.0 (which lavapipe stores back to exactly r)
//     removes that ambiguity. For 0/255 coverage it reduces to background / foreground, so the
//     Unifont output is exact. No gamma step (the CPU blends in sRGB too).
void main()
{
    int coverage = 0; // 0..255 atlas byte
    if (inHasGlyph > 0.5 && cellPaint != 1) {
        ivec2 texSize = textureSize(uAtlas, 0);
        // Integer cell-local pixel index from the fragment center.
        ivec2 local = ivec2(floor(gl_FragCoord.xy - inCellOriginPx));
        vec2 source = inAtlasMin + (vec2(local) + vec2(0.5)) / inCellSizePx * (inAtlasMax - inAtlasMin);
        ivec2 texel = clamp(ivec2(source), ivec2(0), texSize - ivec2(1));
        coverage = int(round(texelFetch(uAtlas, texel, 0).r * 255.0));
    }
    if (cellPaint == 2) {
        if (coverage == 0)
            discard;
        outColor = vec4(round(inForeground.rgb * 255.0) / 255.0, float(coverage) / 255.0);
        return;
    }
    int invCoverage = 255 - coverage;
    ivec3 background = ivec3(round(inBackground.rgb * 255.0));
    ivec3 foreground = ivec3(round(inForeground.rgb * 255.0));
    ivec3 mixed = (background * invCoverage + foreground * coverage + ivec3(127)) / 255;
    // Output alpha: opaque text (foreground alpha 255) over the background's alpha (the window
    // opacity), in the same integer domain as the colors so the CPU + GPU land on
    // the identical byte (the golden-image oracle). background alpha 255 → 255 (opaque).
    int bgA = int(round(inBackground.a * 255.0));
    int outA = (bgA * invCoverage + 255 * coverage + 127) / 255;
    outColor = vec4(vec3(mixed) / 255.0, float(outA) / 255.0);
}
