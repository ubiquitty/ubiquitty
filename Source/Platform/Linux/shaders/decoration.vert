#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Per-instance attributes are the portable Rendering::DecorationInstance
// (Source/Core/Rendering/CellInstance.h), read as whole vec4s at its field
// byte offsets so the cut's neighbour pairs fit in the attributes every
// device has: params = kind, pattern period, thickness, skipInk; ink = the
// cell box's top-left and bottom-right in atlas pixels; pad = the dilation
// radius, its tap count and the base-8 self/left/right sheet selectors;
// slot = the own glyph's atlas-slot clamp.
layout(location = 0) in vec2 inMin; // topLeftInPixels      @0
layout(location = 1) in vec2 inMax; // bottomRightInPixels  @8
layout(location = 2) in vec4 inColor; //                    @16
layout(location = 3) in vec4 inParams; //                   @32
layout(location = 4) in vec4 inInk; //                      @48
layout(location = 5) in vec4 inPad; //                      @64
layout(location = 6) in vec4 inSlot; //                     @80
layout(location = 7) in vec4 inLeftInk; //                  @96
layout(location = 8) in vec4 inLeftBox; //                  @112
layout(location = 9) in vec4 inRightInk; //                 @128
layout(location = 10) in vec4 inRightBox; //                @144

layout(push_constant) uniform Push {
    vec2 viewportSize;
    vec2 cellSize;
    float bitmapTier; // 1 = the face is Core's embedded bitmap: coverage is held to the software renderer's 51 levels
}
pc;

layout(location = 0) flat out vec4 outRect; // the rule's top-left and size, in pixels
layout(location = 1) out vec4 outColor;
layout(location = 2) flat out vec4 outParams;
layout(location = 3) flat out vec4 outInk; // the glyph cell box's top-left and bottom-right in atlas pixels
layout(location = 4) flat out vec4 outPad;
layout(location = 5) flat out vec4 outSlot;
layout(location = 6) flat out vec4 outLeftInk;
layout(location = 7) flat out vec4 outLeftBox;
layout(location = 8) flat out vec4 outRightInk;
layout(location = 9) flat out vec4 outRightBox;
layout(location = 10) flat out float outBitmapTier;

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
    outRect = vec4(inMin, sizePx);
    outColor = inColor;
    outParams = inParams;
    outInk = inInk;
    outPad = inPad;
    outSlot = inSlot;
    outLeftInk = inLeftInk;
    outLeftBox = inLeftBox;
    outRightInk = inRightInk;
    outRightBox = inRightBox;
    outBitmapTier = pc.bitmapTier;
}
