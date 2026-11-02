#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Background-image pass: one quad over the rectangle Core's
// backgroundImagePlacement places the window's image in. The fragment shader
// samples and composites it exactly as Rendering::compositeBackgroundImage
// does, so this pass and the CPU raster draw one picture.
layout(push_constant) uniform Push {
    vec2 viewportSize; // pixels, the whole frame
    vec2 topLeft; // the placed rectangle, pixels
    vec2 bottomRight;
    vec2 uv0; // the image coordinate at the rectangle's left and top edges
    vec2 uvPerPixel; // and its step per pixel: Core's backgroundImageSampling
    vec2 textureSize; // the image's pixels
    float opacity;
    float shouldRepeat; // 1 for Tile
}
pc;

// Two triangles -> a unit quad.
const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main()
{
    vec2 px = pc.topLeft + kCorners[gl_VertexIndex] * (pc.bottomRight - pc.topLeft);
    gl_Position = vec4(px / pc.viewportSize * 2.0 - 1.0, 0.0, 1.0);
}
