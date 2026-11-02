#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Overlay (cursor + translucent selection) fragment. Like the inline-image pass
// (image.frag), this does the over-blend in the INTEGER domain via subpassLoad —
// not fixed-function hardware blend — so the result is byte-for-byte identical to
// SoftwareRenderer::compositeOverlay (the CPU<->GPU oracle). A fixed-function
// float blend rounds differently from the CPU's
//   out = (dst*(255-a) + color*a + 127) / 255
// once the overlay is TRANSLUCENT (the selection tint), so the blend is computed
// here against the color attachment read back through input attachment 0.
//
// When strokeWidth > 0 the rect is a hollow outline (the unfocused/hollow
// cursor): keep only the border ring of that width, discard the interior. A
// cornerRadius rounds the rect the way compositeOverlay does: the rounded-rect
// signed distance feathered over one pixel, the coverage folded into the alpha
// byte before the integer blend. No shade this stage. No gamma step (the CPU
// blends in sRGB too).
layout(location = 0) in vec2 inLocalPx;
layout(location = 1) in vec2 inSizePx;
layout(location = 2) in vec4 inColor;
layout(location = 3) flat in float inStrokeWidth;
layout(location = 4) flat in float inCornerRadius;
layout(location = 5) flat in float inCornerStyle;
layout(location = 6) flat in float inBitmapTier;
layout(location = 7) flat in float inShapeKind;
layout(location = 8) flat in vec4 inPlA;
layout(location = 9) flat in vec4 inPlB;

layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput uBackground;

layout(location = 0) out vec4 outColor;

// The focused pill's ring: SoftwareRenderer::compositeFocusedPillRing in the
// same words. The pill's rect in plA with the corner radius, the shadow's
// reach and opacity in plB.xy, the matched cells' box in plB.zw; inside that
// box on the pill's row the destination is kept, everywhere else the shadow
// lands first and the pill's coverage over it, both held to the bitmap tier's
// levels there and mixed as integers with the CPU's rounding.
void focusedPillRing()
{
    vec2 pixel = gl_FragCoord.xy;
    float left = inPlA.x, top = inPlA.y, right = inPlA.z, bottom = inPlA.w;
    if (pixel.x >= inPlB.z && pixel.x < inPlB.w && pixel.y >= top && pixel.y < bottom)
        discard;
    float halfX = (right - left) * 0.5, halfY = (bottom - top) * 0.5;
    float excessX = max(abs(pixel.x - (left + halfX)) - (halfX - inCornerRadius), 0.0);
    float excessY = max(abs(pixel.y - (top + halfY)) - (halfY - inCornerRadius), 0.0);
    float distance = sqrt(excessX * excessX + excessY * excessY) - inCornerRadius;
    float pillCoverage = clamp(0.5 - distance, 0.0, 1.0);
    float falloff = inPlB.x > 0.0 ? 1.0 - clamp(distance / inPlB.x, 0.0, 1.0) : 0.0;
    float shadow = inPlB.y * falloff * falloff;
    if (inBitmapTier > 0.5) {
        pillCoverage = floor(pillCoverage * 51.0 + 0.5) / 51.0;
        shadow = floor(shadow * 51.0 + 0.5) / 51.0;
    }
    int shadowByte = clamp(int(shadow * 255.0 + 0.5), 0, 255);
    int pillByte = clamp(int(pillCoverage * 255.0 + 0.5), 0, 255);
    if (shadowByte <= 0 && pillByte <= 0)
        discard;
    vec4 dst = subpassLoad(uBackground);
    ivec3 rgb = ivec3(round(dst.rgb * 255.0));
    if (shadowByte > 0)
        rgb = (rgb * (255 - shadowByte) + ivec3(127)) / 255;
    if (pillByte > 0) {
        ivec3 pill = ivec3(round(inColor.rgb * 255.0));
        rgb = (rgb * (255 - pillByte) + pill * pillByte + ivec3(127)) / 255;
    }
    outColor = vec4(vec3(rgb) / 255.0, 1.0);
}

// The toolkit caret: SoftwareRenderer::compositeToolkitCaret in the same
// words. The colour under the 8-bit mask color.a carries, each product
// rounded on its own as pixman's MUL_UN8 rounds it, which is how GSK's cairo
// renderer mixes GtkText's faded caret.
int multiplyUnorm8(int value, int weight)
{
    int product = value * weight + 128;
    return ((product >> 8) + product) >> 8;
}

void toolkitCaret()
{
    int mask = clamp(int(round(inColor.a * 255.0)), 0, 255);
    if (mask <= 0)
        discard;
    vec4 dst = subpassLoad(uBackground);
    ivec3 rgb = ivec3(round(dst.rgb * 255.0));
    ivec3 color = ivec3(round(inColor.rgb * 255.0));
    ivec3 mixed = ivec3(multiplyUnorm8(color.r, mask) + multiplyUnorm8(rgb.r, 255 - mask),
        multiplyUnorm8(color.g, mask) + multiplyUnorm8(rgb.g, 255 - mask),
        multiplyUnorm8(color.b, mask) + multiplyUnorm8(rgb.b, 255 - mask));
    outColor = vec4(vec3(mixed) / 255.0, 1.0);
}

void main()
{
    // Before the ring's test: the caret's kind lies below the ring's.
    if (inShapeKind == -4.0) {
        toolkitCaret();
        return;
    }
    if (inShapeKind < -2.5) {
        focusedPillRing();
        return;
    }
    if (inStrokeWidth > 0.0 && inCornerRadius <= 0.0) {
        bool inBorder = inLocalPx.x < inStrokeWidth
            || inLocalPx.x >= inSizePx.x - inStrokeWidth
            || inLocalPx.y < inStrokeWidth
            || inLocalPx.y >= inSizePx.y - inStrokeWidth;
        if (!inBorder)
            discard;
    }

    // Quantize the overlay color + alpha to bytes exactly as the CPU does
    // (toByte = round(x*255); alpha = int(x*255 + 0.5)).
    int colorR = int(round(inColor.r * 255.0));
    int colorG = int(round(inColor.g * 255.0));
    int colorB = int(round(inColor.b * 255.0));
    int alpha = int(inColor.a * 255.0 + 0.5);

    if (alpha <= 0)
        discard; // nothing to blend (keep the destination)

    // Rounded corners: the box shrunk by the radius, the excess measured with
    // the L2 norm for a circular arc or the fourth-power norm for a continuous
    // corner, re-inflated by the radius, feathered over one pixel. The same
    // expression, in the same order, as compositeOverlay.
    if (inShapeKind == -2.0) {
        // Braille ink bounds are independent of the expanded coverage quad.
        vec2 pixel = (inPlA.xy + inPlA.zw) * 0.5 + inLocalPx - inSizePx * 0.5;
        float coverage;
        if (inCornerRadius <= 0.0) {
            vec2 extent = clamp(min(pixel + 0.5, inPlA.zw) - max(pixel - 0.5, inPlA.xy), 0.0, 1.0);
            coverage = extent.x * extent.y;
        } else {
            float distance = length(pixel - (inPlA.xy + inPlA.zw) * 0.5) - inCornerRadius;
            if (inStrokeWidth > 0.0)
                distance = abs(distance + inStrokeWidth * 0.5) - inStrokeWidth * 0.5;
            coverage = clamp(0.5 - distance, 0.0, 1.0);
        }
        if (inBitmapTier > 0.5)
        coverage = floor(coverage * 51.0 + 0.5) / 51.0;
        alpha = int(inColor.a * coverage * 255.0 + 0.5);
    } else if (inCornerRadius > 0.0) {
        float halfX = inSizePx.x * 0.5;
        float halfY = inSizePx.y * 0.5;
        float cx = abs(inLocalPx.x - halfX);
        float cy = abs(inLocalPx.y - halfY);
        float excessX = max(cx - (halfX - inCornerRadius), 0.0);
        float excessY = max(cy - (halfY - inCornerRadius), 0.0);
        float reach = inCornerStyle > 0.5
            ? pow(excessX * excessX * excessX * excessX + excessY * excessY * excessY * excessY, 0.25)
            : sqrt(excessX * excessX + excessY * excessY);
        // Held to the 51 coverage levels the software renderer mixes at in
        // the bitmap tier, and left as the one-pixel ramp it feathers over
        // otherwise: the CPU raster quantises only for Core's bitmap face,
        // and a quad quantised on one side of the oracle and not the other
        // differs on every partial corner.
        float distance = reach - inCornerRadius;
        float strokeDistance = abs(distance + inStrokeWidth * 0.5) - inStrokeWidth * 0.5;
        float coverage = inStrokeWidth > 0.0
            ? (inBitmapTier > 0.5 ? (strokeDistance < 0.0 ? 1.0 : 0.0) : clamp(0.5 - strokeDistance, 0.0, 1.0))
            : clamp(0.5 - distance, 0.0, 1.0);
        if (inBitmapTier > 0.5)
            coverage = floor(coverage * 51.0 + 0.5) / 51.0;
        if (coverage <= 0.0)
            discard;
        alpha = int(inColor.a * coverage * 255.0 + 0.5);
        if (alpha <= 0)
            discard;
    }

    vec4 dst = subpassLoad(uBackground);
    int dr = int(round(dst.r * 255.0));
    int dg = int(round(dst.g * 255.0));
    int db = int(round(dst.b * 255.0));

    if (alpha >= 255) {
        // Opaque (the focused cursor case): write the color verbatim, alpha kept
        // at the destination's opaque 255 — matching the CPU.
        outColor = vec4(float(colorR) / 255.0, float(colorG) / 255.0, float(colorB) / 255.0, 1.0);
        return;
    }

    int invAlpha = 255 - alpha;
    int outR = (dr * invAlpha + colorR * alpha + 127) / 255;
    int outG = (dg * invAlpha + colorG * alpha + 127) / 255;
    int outB = (db * invAlpha + colorB * alpha + 127) / 255;
    // The CPU composite leaves the alpha byte at 255 (the frame stays opaque).
    outColor = vec4(float(outR) / 255.0, float(outG) / 255.0, float(outB) / 255.0, 1.0);
}
