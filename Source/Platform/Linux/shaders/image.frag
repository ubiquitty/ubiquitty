#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Inline-image fragment (Stage 11b) — the CPU<->GPU image oracle's crux. This
// reproduces SoftwareRenderer::compositeImages byte-for-byte:
//
//  1. Nearest-neighbour source texel, exactly as the CPU picks it. The CPU walks
//     destination pixels (x,y) and computes, at the pixel CENTER (x+0.5, y+0.5):
//        fx = ((x+0.5) - minX) / (maxX - minX);  u = u0 + fx*(u1-u0);
//        sx = int(u * texWidth)   // truncate toward zero, then clamp [0, w-1]
//     and likewise sy. gl_FragCoord.xy is the pixel center (x+0.5, y+0.5), so the
//     same float math runs on identical inputs and texelFetch(uImage, (sx,sy))
//     reads the same texel the CPU read from img->pixels. Not a smooth/filtered
//     sampler — integer texelFetch, like the cell pass. A quad Core marks
//     Smooth (Image::ImageFilter) reads its mip levels the same way, through
//     the CPU's own bilinear and level blend over the CPU's own levels.
//
//  2. Integer-domain straight-alpha over-blend, the same formula the CPU + the
//     cell/overlay passes use: out = (dst*(255-a) + src*a + 127) / 255 as
//     integers, emitted as byte/255. The destination (the grid result under the
//     image) is read from the color attachment via subpassLoad — the image pass
//     runs as a second render pass with the color attachment bound as an input
//     attachment + a by-region self-dependency, so subpassLoad returns the
//     already-composited cell/decoration/overlay pixel at this position. alpha==0
//     keeps the destination (discard); alpha==255 writes the source verbatim
//     (matching the CPU fast path); both reduce the formula to no rounding error.
//     No gamma step (the CPU blends in sRGB too).

layout(location = 0) flat in vec2 inMin;
layout(location = 1) flat in vec2 inMax;
layout(location = 2) flat in vec2 inUV0;
layout(location = 3) flat in vec2 inUV1;
layout(location = 4) flat in vec2 inTexSize;
layout(location = 5) flat in float inStraightAlpha;
layout(location = 6) flat in float inFiltered;

layout(set = 0, binding = 0) uniform sampler2D uImage; // the source image, RGBA8
layout(input_attachment_index = 0, set = 1, binding = 0) uniform subpassInput uBackground;

layout(location = 0) out vec4 outColor;

// One texel of mip `level`, clamped to its edge, in 0-255 — the byte the CPU
// reads, recovered exactly from the UNORM fetch.
vec4 levelTexel(int level, ivec2 size, int x, int y)
{
    x = clamp(x, 0, size.x - 1);
    y = clamp(y, 0, size.y - 1);
    return round(texelFetch(uImage, ivec2(x, y), level) * 255.0);
}

// SoftwareRenderer's `bilinear`: texel centres at half integers, the edge
// repeated past the last texel, the same operations in the same order.
vec4 bilinearAt(int level, float u, float v)
{
    ivec2 size = textureSize(uImage, level);
    float tx = u * float(size.x) - 0.5;
    float ty = v * float(size.y) - 0.5;
    float floorX = floor(tx);
    float floorY = floor(ty);
    float wx = tx - floorX;
    float wy = ty - floorY;
    int x0 = int(floorX);
    int y0 = int(floorY);
    vec4 a = levelTexel(level, size, x0, y0);
    vec4 b = levelTexel(level, size, x0 + 1, y0);
    vec4 c = levelTexel(level, size, x0, y0 + 1);
    vec4 d = levelTexel(level, size, x0 + 1, y0 + 1);
    vec4 top = a + (b - a) * wx;
    vec4 bottom = c + (d - c) * wx;
    return top + (bottom - top) * wy;
}

void main()
{
    // Span + pixel-center UV across the destination rect -> source sub-rect ->
    // nearest texel, mirroring compositeImages exactly.
    float spanX = inMax.x - inMin.x;
    float spanY = inMax.y - inMin.y;
    float fx = (gl_FragCoord.x - inMin.x) / spanX;
    float fy = (gl_FragCoord.y - inMin.y) / spanY;
    float u = inUV0.x + fx * (inUV1.x - inUV0.x);
    float v = inUV0.y + fy * (inUV1.y - inUV0.y);

    int sr;
    int sg;
    int sb;
    int alpha;
    if (inFiltered > 0.5) {
        // SoftwareRenderer::compositeFilteredImage: bilinear in the two levels
        // that bracket Image::imageLevelOfDetail, blended between them.
        float ratio = max((inUV1.x - inUV0.x) * inTexSize.x / spanX, (inUV1.y - inUV0.y) * inTexSize.y / spanY);
        float levelOfDetail = ratio > 1.0 ? log2(ratio) : 0.0;
        int lastLevel = textureQueryLevels(uImage) - 1;
        float clamped = min(levelOfDetail, float(lastLevel));
        int lower = int(floor(clamped));
        int upper = min(lower + 1, lastLevel);
        float between = clamped - float(lower);
        vec4 texel = bilinearAt(lower, u, v);
        if (between > 0.0)
            texel += (bilinearAt(upper, u, v) - texel) * between;
        sr = int(round(texel.r));
        sg = int(round(texel.g));
        sb = int(round(texel.b));
        alpha = clamp(int(round(texel.a)), 0, 255);
    } else {
        int imgWidth = int(inTexSize.x);
        int imgHeight = int(inTexSize.y);
        int sx = int(u * inTexSize.x); // truncate toward zero, as (int) does for u>=0
        int sy = int(v * inTexSize.y);
        sx = clamp(sx, 0, imgWidth - 1);
        sy = clamp(sy, 0, imgHeight - 1);

        vec4 texel = texelFetch(uImage, ivec2(sx, sy), 0);
        sr = int(round(texel.r * 255.0));
        sg = int(round(texel.g * 255.0));
        sb = int(round(texel.b * 255.0));
        alpha = int(round(texel.a * 255.0));
    }

    if (alpha <= 0)
        discard; // keep the destination, like the CPU's `continue`

    if (alpha >= 255) {
        // Opaque: write the source verbatim (the CPU fast path).
        outColor = vec4(float(sr) / 255.0, float(sg) / 255.0, float(sb) / 255.0, 1.0);
        return;
    }

    // Straight-alpha over-blend in the integer domain against the grid pixel.
    vec4 dst = subpassLoad(uBackground);
    int dr = int(round(dst.r * 255.0));
    int dg = int(round(dst.g * 255.0));
    int db = int(round(dst.b * 255.0));
    int invAlpha = 255 - alpha;
    int outR = (dr * invAlpha + sr * alpha + 127) / 255;
    int outG = (dg * invAlpha + sg * alpha + 127) / 255;
    int outB = (db * invAlpha + sb * alpha + 127) / 255;
    outColor = vec4(float(outR) / 255.0, float(outG) / 255.0, float(outB) / 255.0, 1.0);
}
