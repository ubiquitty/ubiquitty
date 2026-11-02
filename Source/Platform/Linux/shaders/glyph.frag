#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Glyph coverage mixes over the instance's cell background, with zero coverage
// discarded so margins leave the painted background untouched. Native scaled
// quads filter the complete atlas rect in two dimensions; bitmap and strip
// quads use nearest taps. SoftwareRenderer uses the same integer colour mix.

layout(location = 0) in vec4 inForeground;
layout(location = 1) in vec4 inBackground;
layout(location = 2) flat in vec2 inOriginPx;
layout(location = 3) flat in vec2 inAtlasMin;
layout(location = 4) flat in vec2 inAtlasMax;
layout(location = 5) flat in vec2 inSizePx;
layout(location = 6) flat in int inSamplingMode; // 0 exact, 1 linear, 2 bitmap, 3 strip

layout(binding = 0) uniform sampler2D uAtlas; // R8 glyph coverage

// Whether the ink blends over what the target holds instead of over the cell
// background: a frame with a picture under its text, where the background is
// no longer what lies beneath. The pipeline blends in the fixed-function unit,
// so this stage hands it the foreground and the coverage as its alpha.
layout(constant_id = 0) const bool isOverTarget = false;

layout(location = 0) out vec4 outColor;

float coverageAt(ivec2 texel, ivec2 size)
{
    if (any(lessThan(texel, ivec2(0))) || any(greaterThanEqual(texel, size)))
        return 0.0;
    return round(texelFetch(uAtlas, texel, 0).r * 255.0);
}

// A tap past the instance's box takes the box's nearest texel, as
// SoftwareRenderer::compositeGlyph's does: never a neighbouring slot's, and
// never nothing where the box is cut from inside a raster, as a soft sized
// band is.
float coverageInBox(ivec2 texel, ivec2 size, ivec2 boxMin, ivec2 boxMax)
{
    return coverageAt(clamp(texel, boxMin, boxMax), size);
}

void main()
{
    ivec2 texSize = textureSize(uAtlas, 0);
    ivec2 slotMin = ivec2(inAtlasMin + vec2(0.5));
    vec2 sourceSize = inAtlasMax - inAtlasMin;
    int coverage;
    if (inSamplingMode == 0) {
        ivec2 local = ivec2(floor(gl_FragCoord.xy - inOriginPx));
        ivec2 texel = clamp(slotMin + local, ivec2(0), texSize - ivec2(1));
        coverage = int(round(texelFetch(uAtlas, texel, 0).r * 255.0));
    } else if (inSamplingMode == 3) {
        // Proportional and strip compositors sample from integer local pixels,
        // including a fractional atlas Y origin on a double-height row half.
        ivec2 local = ivec2(floor(gl_FragCoord.xy - inOriginPx));
        vec2 texelsPerPixel = sourceSize / inSizePx;
        int x = slotMin.x + int((float(local.x) + 0.5) * texelsPerPixel.x);
        int y = texelsPerPixel.y == 1.0 ? slotMin.y + local.y
            : int(floor(inAtlasMin.y + (float(local.y) + 0.5) * texelsPerPixel.y));
        ivec2 texel = clamp(ivec2(x, y), ivec2(0), texSize - ivec2(1));
        coverage = int(round(texelFetch(uAtlas, texel, 0).r * 255.0));
    } else {
        vec2 source = inAtlasMin + (gl_FragCoord.xy - inOriginPx) / inSizePx * sourceSize;
        if (inSamplingMode == 2) {
            ivec2 texel = clamp(ivec2(floor(source)), ivec2(floor(inAtlasMin)), ivec2(ceil(inAtlasMax)) - ivec2(1));
            coverage = int(coverageAt(texel, texSize));
        } else {
            // The linear tap in 1/64 fixed point, the integer steps
            // SoftwareRenderer::compositeGlyph takes, so the two arms agree to
            // the unit: a float division or a fused multiply-add rounds
            // differently here. The quad's own edges decide coverage in the
            // same fixed point, which is why the vertex stage widens this
            // quad to whole pixels. Taps outside the instance's box, or
            // outside the sheet, are transparent: a tap half a texel past the
            // box would read whatever the neighbouring slot holds.
            ivec2 centre64 = ivec2(floor(gl_FragCoord.xy)) * 64 + ivec2(32);
            ivec2 origin64 = ivec2(floor(inOriginPx * 64.0 + 0.5));
            ivec2 size64 = ivec2(floor(inSizePx * 64.0 + 0.5));
            if (any(lessThan(centre64, origin64)) || any(greaterThanEqual(centre64, origin64 + size64)) || any(lessThanEqual(size64, ivec2(0))))
                discard;
            ivec2 atlas64 = ivec2(floor(inAtlasMin * 64.0 + 0.5));
            ivec2 source64 = ivec2(floor((inAtlasMax - inAtlasMin) * 64.0 + 0.5));
            ivec2 position64 = atlas64 + (centre64 - origin64) * source64 / size64 - ivec2(32);
            ivec2 base = position64 >> 6;
            ivec2 weight = position64 & ivec2(63);
            ivec2 boxMin = ivec2(floor(inAtlasMin));
            ivec2 boxMax = ivec2(ceil(inAtlasMax)) - ivec2(1);
            int topLeft = int(coverageInBox(base, texSize, boxMin, boxMax));
            int topRight = int(coverageInBox(base + ivec2(1, 0), texSize, boxMin, boxMax));
            int bottomLeft = int(coverageInBox(base + ivec2(0, 1), texSize, boxMin, boxMax));
            int bottomRight = int(coverageInBox(base + ivec2(1, 1), texSize, boxMin, boxMax));
            int top = topLeft * (64 - weight.x) + topRight * weight.x;
            int bottom = bottomLeft * (64 - weight.x) + bottomRight * weight.x;
            coverage = clamp((top * (64 - weight.y) + bottom * weight.y + 2048) >> 12, 0, 255);
        }
    }
    if (coverage == 0)
        discard;
    if (isOverTarget) {
        outColor = vec4(round(inForeground.rgb * 255.0) / 255.0, float(coverage) / 255.0);
        return;
    }
    int invCoverage = 255 - coverage;
    ivec3 background = ivec3(round(inBackground.rgb * 255.0));
    ivec3 foreground = ivec3(round(inForeground.rgb * 255.0));
    ivec3 mixed = (background * invCoverage + foreground * coverage + ivec3(127)) / 255;
    int bgA = int(round(inBackground.a * 255.0));
    int outA = (bgA * invCoverage + 255 * coverage + 127) / 255;
    outColor = vec4(vec3(mixed) / 255.0, float(outA) / 255.0);
}
