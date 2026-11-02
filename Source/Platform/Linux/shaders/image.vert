#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Inline-image pass (Stage 11b) — one instance per resolved ImageQuad. The
// per-instance attributes are the Linux ImageInstance (VulkanImageTextures.h):
// the device-pixel destination rect, the normalized source UVs, and the source
// image's pixel size, so the fragment shader can reproduce
// SoftwareRenderer::compositeImages' nearest-neighbour texel pick exactly.
layout(location = 0) in vec2 inMin; // minXInPixels, minYInPixels   @0
layout(location = 1) in vec2 inMax; // maxXInPixels, maxYInPixels   @8
layout(location = 2) in vec2 inUV0; // u0, v0                       @16
layout(location = 3) in vec2 inUV1; // u1, v1                       @24
layout(location = 4) in vec2 inTexSize; // texWidth, texHeight      @32
layout(location = 5) in float inStraightAlpha; //                   @40
layout(location = 6) in float inFiltered; // 1 = Image::ImageFilter::Smooth @44

layout(push_constant) uniform Push {
    vec2 viewportSize; // pixels (cols*cellWidth, rows*cellHeight)
    vec2 cellSize; // pixels (unused here; shared push layout)
}
pc;

// All passed FLAT: the fragment shader recovers the integer source texel
// deterministically from gl_FragCoord and these rect/UV parameters, matching the
// CPU compositor's nearest tap (no interpolated UV).
layout(location = 0) flat out vec2 outMin;
layout(location = 1) flat out vec2 outMax;
layout(location = 2) flat out vec2 outUV0;
layout(location = 3) flat out vec2 outUV1;
layout(location = 4) flat out vec2 outTexSize;
layout(location = 5) flat out float outStraightAlpha;
layout(location = 6) flat out float outFiltered;

// Two triangles -> a unit quad.
const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main()
{
    vec2 corner = kCorners[gl_VertexIndex];
    vec2 px = inMin + corner * (inMax - inMin);
    vec2 ndc = px / pc.viewportSize * 2.0 - 1.0; // Vulkan: (-1,-1) = top-left
    gl_Position = vec4(ndc, 0.0, 1.0);
    outMin = inMin;
    outMax = inMax;
    outUV0 = inUV0;
    outUV1 = inUV1;
    outTexSize = inTexSize;
    outStraightAlpha = inStraightAlpha;
    outFiltered = inFiltered;
}
