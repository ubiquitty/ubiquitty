#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Colour glyph vertex stage. Same GlyphInstance attributes the mono glyph pass
// consumes, but it carries a different thing across the quad.
//
// The coverage stage receives flat atlas bounds and reconstructs its samples
// from the fragment's pixel position. This stage instead interpolates the
// atlas coordinate for the colour sampler across the destination cell span.

layout(location = 0) in vec2 inOrigin; // slot top-left, device px       @0
layout(location = 1) in vec2 inSize; // slot size, device px            @8
layout(location = 2) in vec4 inForeground; //                            @16
layout(location = 3) in vec4 inBackground; //                            @32
layout(location = 4) in vec2 inAtlasMin; // FULL-slot UV top-left        @48
layout(location = 5) in vec2 inAtlasMax; // FULL-slot UV bottom-right    @56

layout(push_constant) uniform Push {
    vec2 viewportSize; // pixels (cols*cellWidth, rows*cellHeight)
    vec2 cellSize; // pixels
}
pc;

layout(location = 0) out vec2 outUV;

const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main()
{
    vec2 corner = kCorners[gl_VertexIndex];
    vec2 px = inOrigin + corner * inSize;
    vec2 ndc = px / pc.viewportSize * 2.0 - 1.0; // Vulkan: (-1,-1) = top-left
    gl_Position = vec4(ndc, 0.0, 1.0);
    // Pixel-boundary UVs map native-size fragment centres to texel centres.
    outUV = mix(inAtlasMin, inAtlasMax, corner);
}
