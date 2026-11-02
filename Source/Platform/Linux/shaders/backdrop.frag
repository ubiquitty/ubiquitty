#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Background-image fragment: Rendering::compositeBackgroundImage, operation for
// operation, so the CPU<->GPU oracle holds for a frame with a backdrop.
//
//  1. The texel coordinate from the pixel centre (gl_FragCoord is x + 0.5)
//     and Core's per-pixel step, multiplied rather than divided,
//     the four neighbours by integer texelFetch, each decoded to linear light
//     through Core's table and premultiplied by its alpha; past the edge the
//     neighbour wraps for Tile and is transparent black otherwise.
//  2. Bilinear weights and mixes in the CPU's order, scaled by the opacity.
//  3. Destination-over against the frame under it (subpassLoad): its colour
//     decoded through the table, the image added in the share its alpha left
//     open, and each channel encoded by counting Core's code boundaries.
//
// The transfer tables arrive in a buffer rather than as pow() and division: a
// shader's pow and divide are approximate, and the oracle compares bytes. Every value is `precise`, so
// no multiply-add is fused where the CPU's is not.

layout(push_constant) uniform Push {
    vec2 viewportSize;
    vec2 topLeft;
    vec2 bottomRight;
    vec2 uv0;
    vec2 uvPerPixel;
    vec2 textureSize;
    float opacity;
    float shouldRepeat;
}
pc;

layout(set = 0, binding = 0) uniform sampler2D uImage; // the image, straight RGBA8
layout(input_attachment_index = 0, set = 1, binding = 0) uniform subpassInput uBackground;
layout(std430, set = 2, binding = 0) readonly buffer Transfer {
    float decoded[256]; // Rendering::SRGBTransferTables::decoded
    float codeBoundaries[255]; // Rendering::SRGBTransferTables::codeBoundaries
    float fractions[256]; // Rendering::SRGBTransferTables::fractions
}
transfer;

layout(location = 0) out vec4 outColor;

vec4 linearTexel(int x, int y)
{
    ivec2 size = ivec2(pc.textureSize);
    if (pc.shouldRepeat > 0.5) {
        x = x - (x / size.x) * size.x;
        y = y - (y / size.y) * size.y;
        if (x < 0)
            x += size.x;
        if (y < 0)
            y += size.y;
    } else if (x < 0 || y < 0 || x >= size.x || y >= size.y) {
        return vec4(0.0);
    }
    ivec4 bytes = ivec4(round(texelFetch(uImage, ivec2(x, y), 0) * 255.0));
    precise float alpha = transfer.fractions[bytes.a];
    return vec4(transfer.decoded[bytes.r] * alpha, transfer.decoded[bytes.g] * alpha, transfer.decoded[bytes.b] * alpha, alpha);
}

// How many code boundaries lie at or below `value`: the byte it encodes to.
int encodeLinear(float value)
{
    int low = 0;
    int high = 255;
    while (low < high) {
        int middle = (low + high) / 2;
        if (transfer.codeBoundaries[middle] <= value)
            low = middle + 1;
        else
            high = middle;
    }
    return low;
}

void main()
{
    precise float v = pc.uv0.y + (gl_FragCoord.y - pc.topLeft.y) * pc.uvPerPixel.y;
    precise float texelY = v * pc.textureSize.y - 0.5;
    precise float floorY = floor(texelY);
    precise float weightY = texelY - floorY;
    precise float u = pc.uv0.x + (gl_FragCoord.x - pc.topLeft.x) * pc.uvPerPixel.x;
    precise float texelX = u * pc.textureSize.x - 0.5;
    precise float floorX = floor(texelX);
    precise float weightX = texelX - floorX;
    int x0 = int(floorX);
    int y0 = int(floorY);
    vec4 a = linearTexel(x0, y0);
    vec4 b = linearTexel(x0 + 1, y0);
    vec4 c = linearTexel(x0, y0 + 1);
    vec4 d = linearTexel(x0 + 1, y0 + 1);
    precise vec4 top = a + (b - a) * weightX;
    precise vec4 bottom = c + (d - c) * weightX;
    precise vec4 source = (top + (bottom - top) * weightY) * min(pc.opacity, 1.0);

    ivec4 frame = ivec4(round(subpassLoad(uBackground) * 255.0));
    precise float open = 1.0 - transfer.fractions[frame.a];
    if (open <= 0.0 || source.a <= 0.0)
        discard;
    precise float red = transfer.decoded[frame.r] + source.r * open;
    precise float green = transfer.decoded[frame.g] + source.g * open;
    precise float blue = transfer.decoded[frame.b] + source.b * open;
    precise float alpha = clamp(transfer.fractions[frame.a] + source.a * open, 0.0, 1.0);
    outColor = vec4(float(encodeLinear(red)), float(encodeLinear(green)), float(encodeLinear(blue)), floor(alpha * 255.0 + 0.5)) / 255.0;
}
