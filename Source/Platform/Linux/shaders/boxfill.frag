#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The box-fill stream's coverage, in the words of SoftwareRenderer: a shaped
// quad (an SDF shape, a mosaic mask or a shade) as compositeBoxFill draws it,
// and a plain quad (a rect, a hollow or rounded rect, a braille dot) as
// compositeOverlay draws it, which is where compositeBoxFill sends one. No Unicode
// decomposition, stroke sizing or cell clipping lives here: Core emitted the
// shape, and this stage evaluates it per pixel.
//
// A pattern shade lights Core/Rendering/ShadeStyle.h's isShadePixelLit for the
// surface pixel, with Core's grid phase in plA.x, so a run of shades is one
// field across every cell edge at any cell size.
//
// The alpha is quantised to a byte the way the CPU quantises it and the quads
// compose by fixed-function blending in emitted order, as the web arm does.
layout(location = 0) in vec2 inLocalPx;
layout(location = 1) flat in vec2 inSizePx;
layout(location = 2) flat in vec2 inOriginPx;
layout(location = 3) flat in vec4 inColor;
layout(location = 4) flat in float inCornerRadius;
layout(location = 5) flat in float inStrokeWidth;
layout(location = 6) flat in float inShadeDensity;
layout(location = 7) flat in float inShapeKind;
layout(location = 8) flat in vec4 inPlA;
layout(location = 9) flat in vec4 inPlB;
layout(location = 10) flat in float inBitmapTier;
layout(location = 11) flat in float inCornerStyle;

layout(location = 0) out vec4 outColor;

float segmentDistance(vec2 p, vec2 a, vec2 b)
{
    vec2 edge = b - a;
    float t = clamp(dot(p - a, edge) / max(dot(edge, edge), 1e-6), 0.0, 1.0);
    return length(p - (a + t * edge));
}

float crossProduct(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

float triangleDistance(vec2 p, vec2 a, vec2 b, vec2 c)
{
    float winding = crossProduct(b - a, a - c) < 0.0 ? -1.0 : 1.0;
    float side = min(min(winding * crossProduct(p - a, b - a),
                         winding * crossProduct(p - b, c - b)),
        winding * crossProduct(p - c, a - c));
    float distance = min(min(segmentDistance(p, a, b), segmentDistance(p, b, c)), segmentDistance(p, c, a));
    return -distance * (side < 0.0 ? -1.0 : 1.0);
}

float ellipseDistance(vec2 point, vec2 radii)
{
    radii = max(radii, vec2(0.001));
    vec2 q = point / radii;
    float magnitude = max(length(q), 0.0001);
    float gradient = max(length(q / radii), 0.000001);
    return (magnitude - 1.0) * magnitude / gradient;
}

float boxCoverage()
{
    vec2 local = gl_FragCoord.xy - inOriginPx;
    if (inShadeDensity > 0.0) {
        ivec2 pixel = ivec2(floor(gl_FragCoord.xy));
        int lit = int(inShadeDensity * 4.0 + 0.5);
        return ((pixel.x + 2 * pixel.y + int(inPlA.x + 0.5)) & 3) < lit ? 1.0 : 0.0;
    }
    if (inShapeKind < -0.5) {
        uint columns = max(uint(inPlA.y + 0.5), 1u);
        uint rows = max(uint(inPlA.z + 0.5), 1u);
        uint column = local.x < floor(inSizePx.x * 0.5 + 0.5) ? 0u : 1u;
        uint row = rows == 2u
            ? (local.y < floor(inSizePx.y * 0.5 + 0.5) ? 0u : 1u)
            : (local.y < floor(inSizePx.y / 3.0 + 0.5) ? 0u
                    : (local.y < floor(inSizePx.y * 2.0 / 3.0 + 0.5) ? 1u : 2u));
        uint bit = min(row, rows - 1u) * columns + min(column, columns - 1u);
        return ((uint(inPlA.x + 0.5) >> bit) & 1u) != 0u ? 1.0 : 0.0;
    }
    if (inShapeKind < 0.5)
        return 1.0;
    vec2 a = inPlA.xy * inSizePx;
    vec2 b = inPlA.zw * inSizePx;
    vec2 c = inPlB.xy * inSizePx;
    float distance;
    if (inShapeKind > 6.5) {
        vec2 point = max((local - a) * inPlB.zw, vec2(0.0));
        distance = ellipseDistance(point, b + c);
        if (b.x > c.x && b.y > c.y)
            distance = max(distance, -ellipseDistance(point, b - c));
    } else if (inShapeKind < 1.5) {
        distance = triangleDistance(local, a, b, c);
    } else if (inShapeKind < 2.5) {
        distance = min(segmentDistance(local, a, b), segmentDistance(local, b, c)) - inPlB.z * inSizePx.y;
    } else if (inShapeKind < 4.5) {
        float ellipse = ellipseDistance(local - a, b);
        float side = inPlB.x * (local.x - a.x);
        float halfWidth = inPlB.y * inSizePx.y;
        distance = max(inShapeKind < 3.5 ? ellipse : abs(ellipse + halfWidth) - halfWidth, -side);
    } else {
        float winding = crossProduct(b - a, c - a) < 0.0 ? -1.0 : 1.0;
        float outer = -winding * crossProduct(b - a, local - a) / max(length(b - a), 1e-6);
        if (inShapeKind < 5.5)
            outer = max(outer, -winding * crossProduct(c - b, local - b) / max(length(c - b), 1e-6));
        float halfWidth = inPlB.z * inSizePx.y;
        distance = abs(outer + halfWidth) - halfWidth;
    }
    float coverage = clamp(0.5 - distance, 0.0, 1.0);
    return inBitmapTier > 0.5 ? floor(coverage * 51.0 + 0.5) / 51.0 : coverage;
}

// A plain quad's coverage: compositeOverlay's hollow ring, rounded-rect
// signed distance (L2 for a circular corner, the fourth-power norm for a
// continuous one) and braille dot, in its words.
float plainCoverage()
{
    if (inStrokeWidth > 0.0 && inCornerRadius <= 0.0) {
        bool isInBorder = inLocalPx.x < inStrokeWidth || inLocalPx.x >= inSizePx.x - inStrokeWidth
            || inLocalPx.y < inStrokeWidth || inLocalPx.y >= inSizePx.y - inStrokeWidth;
        if (!isInBorder)
            return 0.0;
    }
    if (inShapeKind == -2.0) {
        // Braille ink bounds are independent of the expanded coverage quad.
        vec2 pixel = floor(gl_FragCoord.xy) + 0.5;
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
        return inBitmapTier > 0.5 ? floor(coverage * 51.0 + 0.5) / 51.0 : coverage;
    }
    if (inCornerRadius > 0.0) {
        vec2 local = gl_FragCoord.xy - inOriginPx;
        vec2 halfSize = inSizePx * 0.5;
        vec2 excess = max(abs(local - halfSize) - (halfSize - inCornerRadius), 0.0);
        float reach = inCornerStyle > 0.5
            ? pow(excess.x * excess.x * excess.x * excess.x + excess.y * excess.y * excess.y * excess.y, 0.25)
            : length(excess);
        float distance = reach - inCornerRadius;
        float strokeDistance = abs(distance + inStrokeWidth * 0.5) - inStrokeWidth * 0.5;
        float coverage = inStrokeWidth > 0.0
            ? (inBitmapTier > 0.5 ? (strokeDistance < 0.0 ? 1.0 : 0.0) : 0.5 - strokeDistance)
            : 0.5 - distance;
        coverage = clamp(coverage, 0.0, 1.0);
        return inBitmapTier > 0.5 ? floor(coverage * 51.0 + 0.5) / 51.0 : coverage;
    }
    return 1.0;
}

void main()
{
    bool isPlain = inShadeDensity <= 0.0 && (abs(inShapeKind) < 0.5 || inShapeKind == -2.0);
    int alpha = int(inColor.a * (isPlain ? plainCoverage() : boxCoverage()) * 255.0 + 0.5);
    if (alpha <= 0)
        discard;
    vec3 rgb = round(inColor.rgb * 255.0) / 255.0;
    outColor = vec4(rgb, float(alpha) / 255.0);
}
