#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Per-instance attributes are the portable Rendering::OverlayInstance
// (Source/Core/Rendering/CellInstance.h) — locations map to its field byte offsets.
// This stage uses the rect, the RGBA color, strokeWidth (>0 = hollow outline)
// and the corner pair (radius and style) that rounds a highlight pill.
// shadeDensity / shapeKind / plA / plB are 0 this stage and are not declared.
layout(location = 0) in vec2 inMin; // topLeftInPixels   @0
layout(location = 1) in vec2 inMax; // bottomRightInPixels   @8
layout(location = 2) in vec4 inColor; // RGBA, 0..1   @16
layout(location = 3) in float inCornerRadius; // device px, 0 = square   @32
layout(location = 5) in float inCornerStyle; // >0.5 = continuous corner, else circular arc   @36
layout(location = 4) in float inStrokeWidth; // >0 = hollow, device px @40
layout(location = 6) in float inShapeKind; // -3 = the focused pill's ring @48
layout(location = 7) in vec4 inPlA; // the ring's pill rect: left, top, right, bottom @64
layout(location = 8) in vec4 inPlB; // the ring's shadow reach and opacity, and the cells' box x extent @80

layout(push_constant) uniform Push {
    vec2 viewportSize;
    vec2 cellSize;
    float bitmapTier; // 1 = the face is Core's embedded bitmap: coverage is held to the software renderer's 51 levels
}
pc;

layout(location = 0) out vec2 outLocalPx; // pixel offset from the rect top-left
layout(location = 1) out vec2 outSizePx;
layout(location = 2) out vec4 outColor;
layout(location = 3) flat out float outStrokeWidth;
layout(location = 4) flat out float outCornerRadius;
layout(location = 5) flat out float outCornerStyle;
layout(location = 6) flat out float outBitmapTier;
layout(location = 7) flat out float outShapeKind;
layout(location = 8) flat out vec4 outPlA;
layout(location = 9) flat out vec4 outPlB;

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
    outColor = inColor;
    outStrokeWidth = inStrokeWidth;
    outCornerRadius = inCornerRadius;
    outCornerStyle = inCornerStyle;
    outBitmapTier = pc.bitmapTier;
    outShapeKind = inShapeKind;
    outPlA = inPlA;
    outPlB = inPlB;
}
