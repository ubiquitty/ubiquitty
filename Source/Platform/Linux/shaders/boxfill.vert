#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The box-fill stream: Core's BoxFillEmit quads (blocks, shades, sextants,
// Powerline separators, diagonals, arcs) and the braille lattice, as
// Rendering::OverlayInstance. Locations map to that struct's field byte
// offsets. The geometry is Core's; this stage only places the quad.
layout(location = 0) in vec2 inMin; // topLeftInPixels @0
layout(location = 1) in vec2 inMax; // bottomRightInPixels @8
layout(location = 2) in vec4 inColor; // RGBA, 0..1 @16
layout(location = 3) in float inCornerRadius; // @32
layout(location = 9) in float inCornerStyle; // >0.5 = continuous corner, else circular arc @36
layout(location = 4) in float inStrokeWidth; // @40
layout(location = 5) in float inShadeDensity; // >0 = Core's shade field at this density @44
layout(location = 6) in float inShapeKind; // >0 analytic SDF, -1 mosaic mask, -2 braille @48
layout(location = 7) in vec4 inPlA; // @64
layout(location = 8) in vec4 inPlB; // @80

layout(push_constant) uniform Push {
    vec2 viewportSize;
    vec2 cellSize;
    float bitmapTier; // 1 = the face is Core's embedded bitmap: coverage is held to the software renderer's 51 levels
}
pc;

layout(location = 0) out vec2 outLocalPx;
layout(location = 1) flat out vec2 outSizePx;
layout(location = 2) flat out vec2 outOriginPx;
layout(location = 3) flat out vec4 outColor;
layout(location = 4) flat out float outCornerRadius;
layout(location = 5) flat out float outStrokeWidth;
layout(location = 6) flat out float outShadeDensity;
layout(location = 7) flat out float outShapeKind;
layout(location = 8) flat out vec4 outPlA;
layout(location = 9) flat out vec4 outPlB;
layout(location = 10) flat out float outBitmapTier;
layout(location = 11) flat out float outCornerStyle;

const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main()
{
    vec2 corner = kCorners[gl_VertexIndex];
    vec2 sizePx = inMax - inMin;
    vec2 px = inMin + corner * sizePx;
    vec2 ndc = px / pc.viewportSize * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    outLocalPx = corner * sizePx;
    outSizePx = sizePx;
    outOriginPx = inMin;
    outColor = inColor;
    outCornerRadius = inCornerRadius;
    outStrokeWidth = inStrokeWidth;
    outShadeDensity = inShadeDensity;
    outShapeKind = inShapeKind;
    outPlA = inPlA;
    outPlB = inPlB;
    outBitmapTier = pc.bitmapTier;
    outCornerStyle = inCornerStyle;
}
