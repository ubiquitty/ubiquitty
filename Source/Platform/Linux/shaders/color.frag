#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Colour glyph fragment stage: the emoji sheet sampled through, not tinted.
//
// The mono passes mix a foreground into a background using the atlas as
// coverage, because a coverage glyph has no colour of its own. A colour glyph
// carries its own layers, so the sample becomes the output unchanged and the
// pen colour never enters — an emoji tinted by the cell's foreground would be
// a silhouette.
//
// Blended by the hardware against the framebuffer rather than against the
// GlyphInstance's carried background, which is what cell.frag and glyph.frag
// do. Those can use the carried background because a coverage glyph stays
// inside the cell that owns it; a colour slot is SQUARE while its destination
// is a cell span, so it overhangs into the neighbour's territory whenever the
// cell is not square. Compositing against a background the neighbour does not
// share would paint the wrong colour there.
//
// The cost of that choice, stated because it is a real difference rather than
// an oversight: the mono passes land on the same byte as
// SoftwareRenderer::compositeGlyph, which is what makes the CPU raster a golden
// oracle for the GPU. Hardware blending is float and the CPU path rounds
// integers (`(dst*inv + src*a + 127) / 255`), so the colour pass agrees with
// the CPU arm to within a unit rather than exactly. A parity check over this
// pass must compare with a tolerance and say so.

layout(location = 0) in vec2 inUV;

layout(binding = 1) uniform sampler2D uColorAtlas; // RGBA8 emoji sheet

layout(location = 0) out vec4 outColor;

void main()
{
    // Atlas pixels, normalized where a divide is free.
    vec4 sampled = texture(uColorAtlas, inUV / vec2(textureSize(uColorAtlas, 0)));
    // A fully transparent texel writes nothing at all. The slot is square and
    // usually larger than the ink in it, so most of the quad is empty; blending
    // zero-alpha would still cost a framebuffer write per fragment and, where
    // the quad overhangs, would touch a neighbour it has no business in.
    if (sampled.a <= 0.0)
        discard;
    outColor = sampled;
}
