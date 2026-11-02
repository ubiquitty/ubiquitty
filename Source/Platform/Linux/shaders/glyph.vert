#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Subpixel overflow glyph quad: the FULL slot, positioned at originInPixels
// (penX - margin, rowTop) so a glyph wider than the cell box overflows
// symmetrically into the neighbour columns. Mirrors cell.vert's NDC mapping; the
// per-instance attributes are the shared Rendering::GlyphInstance (CellInstance.h).

layout(location = 0) in vec2 inOrigin; // slot top-left, device px       @0
layout(location = 1) in vec2 inSize; // slot size, device px            @8
layout(location = 2) in vec4 inForeground; //                            @16
layout(location = 3) in vec4 inBackground; // the glyph's cell background @32
layout(location = 4) in vec2 inAtlasMin; // FULL-slot UV top-left        @48
layout(location = 5) in vec2 inAtlasMax; // FULL-slot UV bottom-right    @56

layout(push_constant) uniform Push {
    vec2 viewportSize; // pixels (cols*cellWidth, rows*cellHeight)
    vec2 cellSize; // pixels
    float bitmapTier; // fixed-raster coverage uses nearest sampling
    float spreadsAtlasAcrossQuad; // proportional and strip streams use nearest sampling
}
pc;

layout(location = 0) out vec4 outForeground;
layout(location = 1) out vec4 outBackground;
layout(location = 2) flat out vec2 outOriginPx;
layout(location = 3) flat out vec2 outAtlasMin;
layout(location = 4) flat out vec2 outAtlasMax;
layout(location = 5) flat out vec2 outSizePx;
layout(location = 6) flat out int outSamplingMode; // 0 exact, 1 linear, 2 bitmap, 3 strip

const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main()
{
    vec2 corner = kCorners[gl_VertexIndex];
    // Scalable scripted glyphs retain their full atlas rect inside a smaller
    // quad. The software compositor filters that rect in both axes; bitmap
    // glyphs and proportional/strip streams retain their nearest-tap rules.
    bool isOneToOne = all(lessThan(abs(inAtlasMax - inAtlasMin - inSize), vec2(0.001)));
    int samplingMode = pc.spreadsAtlasAcrossQuad > 0.5 ? 3
        : isOneToOne ? 0
        : pc.bitmapTier > 0.5 ? 2 : 1;
    // A linear quad is widened to whole pixels and a pixel past its edge one;
    // the fragment stage decides coverage in the software compositor's fixed
    // point, so a pixel the rasteriser would round the other way is neither
    // lost nor gained.
    vec2 px = samplingMode == 1
        ? floor(inOrigin) - vec2(1.0) + corner * (ceil(inOrigin + inSize) - floor(inOrigin) + vec2(2.0))
        : inOrigin + corner * inSize;
    vec2 ndc = px / pc.viewportSize * 2.0 - 1.0; // Vulkan: (-1,-1) = top-left
    gl_Position = vec4(ndc, 0.0, 1.0);
    outForeground = inForeground;
    outBackground = inBackground;
    outOriginPx = inOrigin;
    outAtlasMin = inAtlasMin;
    outAtlasMax = inAtlasMax;
    outSizePx = inSize;
    outSamplingMode = samplingMode;
}
