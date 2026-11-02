// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/ColorGlyphPainter.cpp — see ColorGlyphPainter.h.

#include "Platform/Linux/ColorGlyphPainter.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <optional>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_COLOR_H
#include FT_OUTLINE_H

namespace Ubiquitty::Linux {

namespace {

// A 2×3 affine over doubles: x' = xx·x + xy·y + xOffset, y' = yx·x + yy·y + yOffset.
// The same layout as `FT_Affine23`, read out of 16.16 once at the node.
struct Affine {
    double xx = 1.0;
    double xy = 0.0;
    double yx = 0.0;
    double yy = 1.0;
    double xOffset = 0.0;
    double yOffset = 0.0;

    // `outer ∘ inner`: a point goes through `inner` first.
    [[nodiscard]] Affine then(const Affine& inner) const
    {
        return {
            .xx = xx * inner.xx + xy * inner.yx,
            .xy = xx * inner.xy + xy * inner.yy,
            .yx = yx * inner.xx + yy * inner.yx,
            .yy = yx * inner.xy + yy * inner.yy,
            .xOffset = xx * inner.xOffset + xy * inner.yOffset + xOffset,
            .yOffset = yx * inner.xOffset + yy * inner.yOffset + yOffset,
        };
    }

    [[nodiscard]] double determinant() const { return xx * yy - xy * yx; }

    // The inverse, or nothing for a singular map, which a gradient cannot be
    // sampled through.
    [[nodiscard]] std::expected<Affine, ColorGlyphPaintError> inverted() const
    {
        const double det = determinant();
        if (std::fabs(det) < 1e-12)
            return std::unexpected(ColorGlyphPaintError::MalformedColorLine);
        const double inverseXX = yy / det;
        const double inverseXY = -xy / det;
        const double inverseYX = -yx / det;
        const double inverseYY = xx / det;
        return Affine {
            .xx = inverseXX,
            .xy = inverseXY,
            .yx = inverseYX,
            .yy = inverseYY,
            .xOffset = -(inverseXX * xOffset + inverseXY * yOffset),
            .yOffset = -(inverseYX * xOffset + inverseYY * yOffset),
        };
    }
};

constexpr double fixed16Dot16 = 65536.0;
constexpr double fixed2Dot14 = 16384.0;
constexpr double fixed26Dot6 = 64.0;

// A well-formed graph nests a handful of levels; a cyclic one nests forever.
constexpr std::size_t maxGraphDepth = 32;
// A colour line in a shipping face carries a few stops; a bound keeps the
// stop array on the stack.
constexpr std::size_t maxColorStops = 64;
constexpr std::uint16_t foregroundPaletteIndex = 0xFFFF;

[[nodiscard]] double fromFixed(FT_Fixed value)
{
    return static_cast<double>(value) / fixed16Dot16;
}

[[nodiscard]] double fromFixed2Dot14(FT_F2Dot14 value)
{
    return static_cast<double>(value) / fixed2Dot14;
}

// A colour line's stop, resolved to a straight colour.
struct ResolvedStop {
    double offset = 0.0;
    double red = 0.0;
    double green = 0.0;
    double blue = 0.0;
    double alpha = 0.0;
};

struct ResolvedColorLine {
    std::array<ResolvedStop, maxColorStops> stops {};
    std::size_t count = 0;
    ColorLineExtend extend = ColorLineExtend::Pad;
};

// Everything one paint call shares across the recursion.
struct PaintContext {
    FT_Face face = nullptr;
    ColorGlyphPainter& painter;
    ColorGlyphCanvas canvas;
    ColorRGBA8 foreground;
    const FT_Color* palette = nullptr;
    std::size_t paletteSize = 0;
    // From font units to canvas pixels, y up from the bottom edge.
    Affine toCanvas;
};

// The colour a palette index and a paint alpha resolve to, straight.
[[nodiscard]] std::expected<ResolvedStop, ColorGlyphPaintError> resolveColor(const PaintContext& context, const FT_ColorIndex& colorIndex)
{
    ResolvedStop resolved;
    const double paintAlpha = std::clamp(fromFixed2Dot14(colorIndex.alpha), 0.0, 1.0);
    if (colorIndex.palette_index == foregroundPaletteIndex) {
        resolved.red = context.foreground.red;
        resolved.green = context.foreground.green;
        resolved.blue = context.foreground.blue;
        resolved.alpha = context.foreground.alpha / 255.0 * paintAlpha;
        return resolved;
    }
    if (!context.palette || colorIndex.palette_index >= context.paletteSize)
        return std::unexpected(ColorGlyphPaintError::MalformedColorLine);
    const FT_Color& entry = context.palette[colorIndex.palette_index];
    resolved.red = entry.red;
    resolved.green = entry.green;
    resolved.blue = entry.blue;
    resolved.alpha = entry.alpha / 255.0 * paintAlpha;
    return resolved;
}

[[nodiscard]] std::expected<ResolvedColorLine, ColorGlyphPaintError> resolveColorLine(const PaintContext& context, FT_ColorLine& line)
{
    ResolvedColorLine resolved;
    switch (line.extend) {
    case FT_COLR_PAINT_EXTEND_REPEAT:
        resolved.extend = ColorLineExtend::Repeat;
        break;
    case FT_COLR_PAINT_EXTEND_REFLECT:
        resolved.extend = ColorLineExtend::Reflect;
        break;
    case FT_COLR_PAINT_EXTEND_PAD:
    default:
        resolved.extend = ColorLineExtend::Pad;
        break;
    }
    FT_ColorStop stop;
    while (FT_Get_Colorline_Stops(context.face, &stop, &line.color_stop_iterator)) {
        if (resolved.count >= maxColorStops)
            return std::unexpected(ColorGlyphPaintError::MalformedColorLine);
        auto color = resolveColor(context, stop.color);
        if (!color)
            return std::unexpected(color.error());
        color->offset = fromFixed(stop.stop_offset);
        resolved.stops[resolved.count++] = *color;
    }
    if (resolved.count == 0)
        return std::unexpected(ColorGlyphPaintError::MalformedColorLine);
    // Stops are interpolated in offset order; the table does not promise it.
    std::stable_sort(resolved.stops.begin(), resolved.stops.begin() + static_cast<std::ptrdiff_t>(resolved.count),
        [](const ResolvedStop& a, const ResolvedStop& b) { return a.offset < b.offset; });
    return resolved;
}

// The colour at `parameter`, already folded into the stop range.
[[nodiscard]] ResolvedStop sampleColorLine(const ResolvedColorLine& line, double parameter)
{
    const ResolvedStop& first = line.stops[0];
    const ResolvedStop& last = line.stops[line.count - 1];
    if (parameter <= first.offset)
        return first;
    if (parameter >= last.offset)
        return last;
    for (std::size_t i = 1; i < line.count; ++i) {
        const ResolvedStop& from = line.stops[i - 1];
        const ResolvedStop& to = line.stops[i];
        if (parameter > to.offset)
            continue;
        const double span = to.offset - from.offset;
        const double fraction = span > 0.0 ? (parameter - from.offset) / span : 1.0;
        return {
            .offset = parameter,
            .red = from.red + (to.red - from.red) * fraction,
            .green = from.green + (to.green - from.green) * fraction,
            .blue = from.blue + (to.blue - from.blue) * fraction,
            .alpha = from.alpha + (to.alpha - from.alpha) * fraction,
        };
    }
    return last;
}

// Source-over of one straight colour at `coverage` onto a premultiplied
// BGRA pixel. Integer throughout: the canvas is bytes and the rounding is the
// same on every pixel.
void blendPixel(std::uint8_t* pixel, const ResolvedStop& color, std::uint8_t coverage)
{
    const double alpha = std::clamp(color.alpha, 0.0, 1.0) * coverage / 255.0;
    const auto sourceAlpha = static_cast<std::uint32_t>(std::lround(alpha * 255.0));
    if (sourceAlpha == 0)
        return;
    const auto premultiply = [sourceAlpha](double channel) -> std::uint32_t {
        const double clamped = std::clamp(channel, 0.0, 255.0);
        return static_cast<std::uint32_t>(std::lround(clamped * static_cast<double>(sourceAlpha) / 255.0));
    };
    const std::uint32_t sourceBlue = premultiply(color.blue);
    const std::uint32_t sourceGreen = premultiply(color.green);
    const std::uint32_t sourceRed = premultiply(color.red);
    const std::uint32_t keep = 255 - sourceAlpha;
    const auto over = [keep](std::uint32_t source, std::uint8_t destination) -> std::uint8_t {
        return static_cast<std::uint8_t>(std::min<std::uint32_t>(255, source + (destination * keep + 127) / 255));
    };
    pixel[0] = over(sourceBlue, pixel[0]);
    pixel[1] = over(sourceGreen, pixel[1]);
    pixel[2] = over(sourceRed, pixel[2]);
    pixel[3] = over(sourceAlpha, pixel[3]);
}

// Fills every canvas pixel the clip admits with `colorAt(x, y)`, where the
// point is the pixel's centre in canvas space, y up.
template<typename ColorAt>
void fillClipped(PaintContext& context, std::span<const std::uint8_t> clip, ColorAt&& colorAt)
{
    const int width = context.canvas.widthInPixels;
    const int height = context.canvas.heightInPixels;
    for (int row = 0; row < height; ++row) {
        const double y = static_cast<double>(height - row) - 0.5;
        for (int column = 0; column < width; ++column) {
            const std::size_t index = static_cast<std::size_t>(row) * static_cast<std::size_t>(width) + static_cast<std::size_t>(column);
            const std::uint8_t coverage = clip.empty() ? 255 : clip[index];
            if (coverage == 0)
                continue;
            const double x = static_cast<double>(column) + 0.5;
            const auto color = colorAt(x, y);
            if (!color)
                continue;
            blendPixel(&context.canvas.premultipliedBGRA[index * 4], *color, coverage);
        }
    }
}

std::expected<void, ColorGlyphPaintError> paintNode(PaintContext& context, FT_OpaquePaint opaque, const Affine& transform, std::span<const std::uint8_t> clip, std::size_t depth);

// The blend function B(cb, cs) of a separable mode, on one straight channel in
// 0..1 (W3C Compositing and Blending Level 1, which OpenType COLR's
// CompositeMode names its modes after).
[[nodiscard]] double blendSeparable(FT_Composite_Mode mode, double cb, double cs)
{
    switch (mode) {
    case FT_COLR_COMPOSITE_MULTIPLY:
        return cb * cs;
    case FT_COLR_COMPOSITE_SCREEN:
        return cb + cs - cb * cs;
    case FT_COLR_COMPOSITE_OVERLAY:
        return blendSeparable(FT_COLR_COMPOSITE_HARD_LIGHT, cs, cb);
    case FT_COLR_COMPOSITE_DARKEN:
        return std::min(cb, cs);
    case FT_COLR_COMPOSITE_LIGHTEN:
        return std::max(cb, cs);
    case FT_COLR_COMPOSITE_COLOR_DODGE:
        if (cb <= 0.0)
            return 0.0;
        return cs >= 1.0 ? 1.0 : std::min(1.0, cb / (1.0 - cs));
    case FT_COLR_COMPOSITE_COLOR_BURN:
        if (cb >= 1.0)
            return 1.0;
        return cs <= 0.0 ? 0.0 : 1.0 - std::min(1.0, (1.0 - cb) / cs);
    case FT_COLR_COMPOSITE_HARD_LIGHT:
        return cs <= 0.5 ? cb * 2.0 * cs : blendSeparable(FT_COLR_COMPOSITE_SCREEN, cb, 2.0 * cs - 1.0);
    case FT_COLR_COMPOSITE_SOFT_LIGHT: {
        if (cs <= 0.5)
            return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
        const double d = cb <= 0.25 ? ((16.0 * cb - 12.0) * cb + 4.0) * cb : std::sqrt(cb);
        return cb + (2.0 * cs - 1.0) * (d - cb);
    }
    case FT_COLR_COMPOSITE_DIFFERENCE:
        return std::fabs(cb - cs);
    case FT_COLR_COMPOSITE_EXCLUSION:
        return cb + cs - 2.0 * cb * cs;
    default:
        return cs;
    }
}

struct StraightRGB {
    double red = 0.0;
    double green = 0.0;
    double blue = 0.0;
};

// The non-separable modes, on straight colours (same specification).
[[nodiscard]] double luminosity(const StraightRGB& c)
{
    return 0.3 * c.red + 0.59 * c.green + 0.11 * c.blue;
}

[[nodiscard]] StraightRGB clipColor(StraightRGB c)
{
    const double l = luminosity(c);
    const double n = std::min({ c.red, c.green, c.blue });
    const double x = std::max({ c.red, c.green, c.blue });
    if (n < 0.0) {
        const double k = l - n;
        c = { l + (c.red - l) * l / k, l + (c.green - l) * l / k, l + (c.blue - l) * l / k };
    }
    if (x > 1.0) {
        const double k = x - l;
        c = { l + (c.red - l) * (1.0 - l) / k, l + (c.green - l) * (1.0 - l) / k, l + (c.blue - l) * (1.0 - l) / k };
    }
    return c;
}

[[nodiscard]] StraightRGB setLuminosity(StraightRGB c, double l)
{
    const double d = l - luminosity(c);
    return clipColor({ c.red + d, c.green + d, c.blue + d });
}

[[nodiscard]] double saturation(const StraightRGB& c)
{
    return std::max({ c.red, c.green, c.blue }) - std::min({ c.red, c.green, c.blue });
}

[[nodiscard]] StraightRGB setSaturation(StraightRGB c, double s)
{
    double* channels[3] = { &c.red, &c.green, &c.blue };
    std::sort(std::begin(channels), std::end(channels), [](double* a, double* b) { return *a < *b; });
    double& lowest = *channels[0];
    double& middle = *channels[1];
    double& highest = *channels[2];
    if (highest > lowest) {
        middle = (middle - lowest) * s / (highest - lowest);
        highest = s;
    } else {
        middle = 0.0;
        highest = 0.0;
    }
    lowest = 0.0;
    return c;
}

[[nodiscard]] std::optional<StraightRGB> blendNonSeparable(FT_Composite_Mode mode, const StraightRGB& cb, const StraightRGB& cs)
{
    switch (mode) {
    case FT_COLR_COMPOSITE_HSL_HUE:
        return setLuminosity(setSaturation(cs, saturation(cb)), luminosity(cb));
    case FT_COLR_COMPOSITE_HSL_SATURATION:
        return setLuminosity(setSaturation(cb, saturation(cs)), luminosity(cb));
    case FT_COLR_COMPOSITE_HSL_COLOR:
        return setLuminosity(cs, luminosity(cb));
    case FT_COLR_COMPOSITE_HSL_LUMINOSITY:
        return setLuminosity(cb, luminosity(cs));
    default:
        return std::nullopt;
    }
}

// One composite operator on two premultiplied BGRA pixels, source against
// backdrop, in 0..255 with the products rounded once. The names are the
// table's own (OpenType COLR, CompositeMode) and the operand roles are the
// table's: the backdrop paint is what the source paint is composited onto.
// The Porter-Duff modes act on premultiplied channels directly; the blend
// modes act on the straight colours and are laid over with the source-over
// formula the specification gives them.
[[nodiscard]] std::optional<std::array<std::uint8_t, 4>> compositePixel(FT_Composite_Mode mode, const std::uint8_t* source, const std::uint8_t* backdrop)
{
    const auto scaled = [](unsigned int value, unsigned int alpha) -> std::uint8_t {
        return static_cast<std::uint8_t>((value * alpha + 127) / 255);
    };
    const unsigned int sourceAlpha = source[3];
    const unsigned int backdropAlpha = backdrop[3];
    std::array<std::uint8_t, 4> out {};
    switch (mode) {
    case FT_COLR_COMPOSITE_CLEAR:
    case FT_COLR_COMPOSITE_SRC:
    case FT_COLR_COMPOSITE_DEST:
    case FT_COLR_COMPOSITE_SRC_OVER:
    case FT_COLR_COMPOSITE_DEST_OVER:
    case FT_COLR_COMPOSITE_SRC_IN:
    case FT_COLR_COMPOSITE_DEST_IN:
    case FT_COLR_COMPOSITE_SRC_OUT:
    case FT_COLR_COMPOSITE_DEST_OUT:
    case FT_COLR_COMPOSITE_SRC_ATOP:
    case FT_COLR_COMPOSITE_DEST_ATOP:
    case FT_COLR_COMPOSITE_XOR:
    case FT_COLR_COMPOSITE_PLUS:
        for (std::size_t channel = 0; channel < 4; ++channel) {
            const unsigned int s = source[channel];
            const unsigned int d = backdrop[channel];
            unsigned int value = 0;
            switch (mode) {
            case FT_COLR_COMPOSITE_CLEAR:
                value = 0;
                break;
            case FT_COLR_COMPOSITE_SRC:
                value = s;
                break;
            case FT_COLR_COMPOSITE_DEST:
                value = d;
                break;
            case FT_COLR_COMPOSITE_SRC_OVER:
                value = s + scaled(d, 255 - sourceAlpha);
                break;
            case FT_COLR_COMPOSITE_DEST_OVER:
                value = d + scaled(s, 255 - backdropAlpha);
                break;
            case FT_COLR_COMPOSITE_SRC_IN:
                value = scaled(s, backdropAlpha);
                break;
            case FT_COLR_COMPOSITE_DEST_IN:
                value = scaled(d, sourceAlpha);
                break;
            case FT_COLR_COMPOSITE_SRC_OUT:
                value = scaled(s, 255 - backdropAlpha);
                break;
            case FT_COLR_COMPOSITE_DEST_OUT:
                value = scaled(d, 255 - sourceAlpha);
                break;
            case FT_COLR_COMPOSITE_SRC_ATOP:
                value = scaled(s, backdropAlpha) + scaled(d, 255 - sourceAlpha);
                break;
            case FT_COLR_COMPOSITE_DEST_ATOP:
                value = scaled(d, sourceAlpha) + scaled(s, 255 - backdropAlpha);
                break;
            case FT_COLR_COMPOSITE_XOR:
                value = scaled(s, 255 - backdropAlpha) + scaled(d, 255 - sourceAlpha);
                break;
            default:
                value = s + d;
                break;
            }
            out[channel] = static_cast<std::uint8_t>(std::min(255u, value));
        }
        return out;
    default:
        break;
    }
    // A blend mode: co = cs * (1 - ab) + cb * (1 - as) + as * ab * B(cb, cs),
    // with cb and cs the straight colours and the result premultiplied by
    // ao = as + ab * (1 - as). Channels are BGRA.
    const double as = sourceAlpha / 255.0;
    const double ab = backdropAlpha / 255.0;
    const auto straight = [](const std::uint8_t* pixel, double alpha, std::size_t channel) -> double {
        return alpha > 0.0 ? std::min(1.0, (pixel[channel] / 255.0) / alpha) : 0.0;
    };
    const StraightRGB cs { straight(source, as, 2), straight(source, as, 1), straight(source, as, 0) };
    const StraightRGB cb { straight(backdrop, ab, 2), straight(backdrop, ab, 1), straight(backdrop, ab, 0) };
    StraightRGB blended;
    if (const auto nonSeparable = blendNonSeparable(mode, cb, cs)) {
        blended = *nonSeparable;
    } else {
        switch (mode) {
        case FT_COLR_COMPOSITE_MULTIPLY:
        case FT_COLR_COMPOSITE_SCREEN:
        case FT_COLR_COMPOSITE_OVERLAY:
        case FT_COLR_COMPOSITE_DARKEN:
        case FT_COLR_COMPOSITE_LIGHTEN:
        case FT_COLR_COMPOSITE_COLOR_DODGE:
        case FT_COLR_COMPOSITE_COLOR_BURN:
        case FT_COLR_COMPOSITE_HARD_LIGHT:
        case FT_COLR_COMPOSITE_SOFT_LIGHT:
        case FT_COLR_COMPOSITE_DIFFERENCE:
        case FT_COLR_COMPOSITE_EXCLUSION:
            blended = { blendSeparable(mode, cb.red, cs.red), blendSeparable(mode, cb.green, cs.green), blendSeparable(mode, cb.blue, cs.blue) };
            break;
        default:
            // A mode FreeType does not name is a font this build cannot
            // draw; the glyph fails whole rather than drawing its layers
            // unblended, which would look like the glyph and not be it.
            return std::nullopt;
        }
    }
    const double ao = as + ab * (1.0 - as);
    const auto channel = [&](double s, double b, double blend) -> std::uint8_t {
        const double co = s * as * (1.0 - ab) + b * ab * (1.0 - as) + as * ab * blend;
        return static_cast<std::uint8_t>(std::lround(std::clamp(co, 0.0, 1.0) * 255.0));
    };
    out[2] = channel(cs.red, cb.red, blended.red);
    out[1] = channel(cs.green, cb.green, blended.green);
    out[0] = channel(cs.blue, cb.blue, blended.blue);
    out[3] = static_cast<std::uint8_t>(std::lround(std::clamp(ao, 0.0, 1.0) * 255.0));
    return out;
}

// PaintComposite: the two children are painted onto layers of their own,
// with no clip, because the operator sees whole layers — a clip applied to
// each child first would make SRC_IN of a shape against its clip an empty
// result. The combined layer is then laid onto the canvas source-over,
// through the clip this node was reached under, like any other paint.
std::expected<void, ColorGlyphPaintError> paintComposite(PaintContext& context, FT_PaintComposite& composite, const Affine& transform, std::span<const std::uint8_t> clip, std::size_t depth)
{
    const std::size_t pixelCount = static_cast<std::size_t>(context.canvas.widthInPixels) * static_cast<std::size_t>(context.canvas.heightInPixels);
    std::vector<std::uint8_t> sourceLayer(pixelCount * 4, 0);
    std::vector<std::uint8_t> backdropLayer(pixelCount * 4, 0);
    PaintContext sourceContext = context;
    sourceContext.canvas.premultipliedBGRA = sourceLayer;
    PaintContext backdropContext = context;
    backdropContext.canvas.premultipliedBGRA = backdropLayer;
    if (auto drawn = paintNode(sourceContext, composite.source_paint, transform, {}, depth + 1); !drawn)
        return drawn;
    if (auto drawn = paintNode(backdropContext, composite.backdrop_paint, transform, {}, depth + 1); !drawn)
        return drawn;
    for (std::size_t i = 0; i < pixelCount; ++i) {
        const std::uint8_t coverage = clip.empty() ? 255 : clip[i];
        if (coverage == 0)
            continue;
        const auto combined = compositePixel(composite.composite_mode, &sourceLayer[i * 4], &backdropLayer[i * 4]);
        if (!combined)
            return std::unexpected(ColorGlyphPaintError::UnsupportedPaint);
        std::uint8_t* pixel = &context.canvas.premultipliedBGRA[i * 4];
        // Source-over of a premultiplied result, scaled by the clip's
        // coverage, onto what is already there.
        const unsigned int resultAlpha = ((*combined)[3] * coverage + 127) / 255;
        for (std::size_t channel = 0; channel < 4; ++channel) {
            const unsigned int result = ((*combined)[channel] * coverage + 127) / 255;
            pixel[channel] = static_cast<std::uint8_t>(std::min(255u, result + (pixel[channel] * (255 - resultAlpha) + 127) / 255));
        }
    }
    return {};
}

std::expected<void, ColorGlyphPaintError> paintSolid(PaintContext& context, const FT_PaintSolid& solid, std::span<const std::uint8_t> clip)
{
    auto color = resolveColor(context, solid.color);
    if (!color)
        return std::unexpected(color.error());
    const ResolvedStop resolved = *color;
    fillClipped(context, clip, [&resolved](double, double) -> std::optional<ResolvedStop> { return resolved; });
    return {};
}

std::expected<void, ColorGlyphPaintError> paintLinearGradient(PaintContext& context, FT_PaintLinearGradient& gradient, const Affine& transform, std::span<const std::uint8_t> clip)
{
    auto line = resolveColorLine(context, gradient.colorline);
    if (!line)
        return std::unexpected(line.error());
    auto toPaint = transform.inverted();
    if (!toPaint)
        return std::unexpected(toPaint.error());

    // The gradient runs from p0 towards p1; p2 sets the direction the colour
    // lines lie along. Projecting p1 onto the perpendicular of p0→p2 gives the
    // point p3 where the parameter reaches 1, so the parameter is the
    // projection onto p0→p3 (OpenType COLR, PaintLinearGradient).
    const double p0X = static_cast<double>(gradient.p0.x);
    const double p0Y = static_cast<double>(gradient.p0.y);
    const double p1X = static_cast<double>(gradient.p1.x);
    const double p1Y = static_cast<double>(gradient.p1.y);
    const double p2X = static_cast<double>(gradient.p2.x);
    const double p2Y = static_cast<double>(gradient.p2.y);
    const double directionX = p1X - p0X;
    const double directionY = p1Y - p0Y;
    const double perpendicularX = -(p2Y - p0Y);
    const double perpendicularY = p2X - p0X;
    const double perpendicularLength = perpendicularX * perpendicularX + perpendicularY * perpendicularY;
    // p0 = p1, or p2 on the p0→p1 line: the gradient is ill-formed and paints
    // nothing, which the specification asks for.
    if (perpendicularLength <= 0.0 || (directionX == 0.0 && directionY == 0.0))
        return {};
    const double projection = (directionX * perpendicularX + directionY * perpendicularY) / perpendicularLength;
    const double p3X = p0X + perpendicularX * projection;
    const double p3Y = p0Y + perpendicularY * projection;
    const double axisX = p3X - p0X;
    const double axisY = p3Y - p0Y;
    const double axisLength = axisX * axisX + axisY * axisY;
    if (axisLength <= 0.0)
        return {};

    const ResolvedColorLine& stops = *line;
    const Affine& inverse = *toPaint;
    fillClipped(context, clip, [&](double x, double y) -> std::optional<ResolvedStop> {
        const double paintX = inverse.xx * x + inverse.xy * y + inverse.xOffset;
        const double paintY = inverse.yx * x + inverse.yy * y + inverse.yOffset;
        const double parameter = ((paintX - p0X) * axisX + (paintY - p0Y) * axisY) / axisLength;
        const double folded = extendedColorLineParameter(parameter, stops.stops[0].offset, stops.stops[stops.count - 1].offset, stops.extend);
        return sampleColorLine(stops, folded);
    });
    return {};
}

std::expected<void, ColorGlyphPaintError> paintRadialGradient(PaintContext& context, FT_PaintRadialGradient& gradient, const Affine& transform, std::span<const std::uint8_t> clip)
{
    auto line = resolveColorLine(context, gradient.colorline);
    if (!line)
        return std::unexpected(line.error());
    auto toPaint = transform.inverted();
    if (!toPaint)
        return std::unexpected(toPaint.error());

    // Two-point conical: the circle at parameter t has centre c0 + t·(c1 − c0)
    // and radius r0 + t·(r1 − r0). A pixel takes the largest t whose circle
    // passes through it with a non-negative radius, which is the quadratic
    // below solved for t (OpenType COLR, PaintRadialGradient).
    const double c0X = static_cast<double>(gradient.c0.x);
    const double c0Y = static_cast<double>(gradient.c0.y);
    const double r0 = static_cast<double>(gradient.r0);
    const double centreDeltaX = static_cast<double>(gradient.c1.x) - c0X;
    const double centreDeltaY = static_cast<double>(gradient.c1.y) - c0Y;
    const double radiusDelta = static_cast<double>(gradient.r1) - r0;
    const double a = centreDeltaX * centreDeltaX + centreDeltaY * centreDeltaY - radiusDelta * radiusDelta;

    const ResolvedColorLine& stops = *line;
    const Affine& inverse = *toPaint;
    fillClipped(context, clip, [&](double x, double y) -> std::optional<ResolvedStop> {
        const double paintX = inverse.xx * x + inverse.xy * y + inverse.xOffset;
        const double paintY = inverse.yx * x + inverse.yy * y + inverse.yOffset;
        const double pointDeltaX = paintX - c0X;
        const double pointDeltaY = paintY - c0Y;
        const double b = pointDeltaX * centreDeltaX + pointDeltaY * centreDeltaY + r0 * radiusDelta;
        const double c = pointDeltaX * pointDeltaX + pointDeltaY * pointDeltaY - r0 * r0;
        double parameter = 0.0;
        if (std::fabs(a) < 1e-9) {
            if (std::fabs(b) < 1e-12)
                return std::nullopt;
            parameter = c / (2.0 * b);
            if (r0 + parameter * radiusDelta < 0.0)
                return std::nullopt;
        } else {
            const double discriminant = b * b - a * c;
            if (discriminant < 0.0)
                return std::nullopt;
            const double root = std::sqrt(discriminant);
            const double larger = (b + root) / a;
            const double smaller = (b - root) / a;
            if (r0 + std::max(larger, smaller) * radiusDelta >= 0.0)
                parameter = std::max(larger, smaller);
            else if (r0 + std::min(larger, smaller) * radiusDelta >= 0.0)
                parameter = std::min(larger, smaller);
            else
                return std::nullopt;
        }
        const double folded = extendedColorLineParameter(parameter, stops.stops[0].offset, stops.stops[stops.count - 1].offset, stops.extend);
        return sampleColorLine(stops, folded);
    });
    return {};
}

// Rasterises `glyphIndex`'s outline through `transform` into `mask`, then
// multiplies the incoming clip in, so the child paint is clipped by both.
std::expected<void, ColorGlyphPaintError> paintGlyph(PaintContext& context, const FT_PaintGlyph& node, const Affine& transform, std::span<const std::uint8_t> clip, std::size_t depth)
{
    // Unscaled, so the outline is in the font units the graph's transforms
    // expect; hinting and bitmaps have nothing to offer a transformed outline.
    if (FT_Load_Glyph(context.face, node.glyphID, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP | FT_LOAD_IGNORE_TRANSFORM) != 0)
        return std::unexpected(ColorGlyphPaintError::OutlineUnavailable);
    FT_GlyphSlot slot = context.face->glyph;
    if (slot->format != FT_GLYPH_FORMAT_OUTLINE)
        return std::unexpected(ColorGlyphPaintError::OutlineUnavailable);

    const int width = context.canvas.widthInPixels;
    const int height = context.canvas.heightInPixels;
    const std::size_t pixelCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    std::span<std::uint8_t> mask = context.painter.maskForDepth(depth, pixelCount);
    std::memset(mask.data(), 0, pixelCount);

    // The outline goes to 26.6 canvas coordinates in one transform: the
    // matrix carries the ×64, the translation follows in the same units.
    const auto toFixed = [](double value) -> FT_Fixed {
        return static_cast<FT_Fixed>(std::lround(std::clamp(value * fixed16Dot16, -2147483648.0, 2147483647.0)));
    };
    FT_Matrix matrix;
    matrix.xx = toFixed(transform.xx * fixed26Dot6);
    matrix.xy = toFixed(transform.xy * fixed26Dot6);
    matrix.yx = toFixed(transform.yx * fixed26Dot6);
    matrix.yy = toFixed(transform.yy * fixed26Dot6);
    FT_Outline_Transform(&slot->outline, &matrix);
    FT_Outline_Translate(&slot->outline, static_cast<FT_Pos>(std::lround(transform.xOffset * fixed26Dot6)), static_cast<FT_Pos>(std::lround(transform.yOffset * fixed26Dot6)));

    // Row 0 of a positive-pitch target is its top row, and the outline's y = 0
    // is its bottom edge — the canvas's own orientation.
    FT_Bitmap bitmap;
    std::memset(&bitmap, 0, sizeof bitmap);
    bitmap.rows = static_cast<unsigned int>(height);
    bitmap.width = static_cast<unsigned int>(width);
    bitmap.pitch = width;
    bitmap.buffer = mask.data();
    bitmap.pixel_mode = FT_PIXEL_MODE_GRAY;
    bitmap.num_grays = 256;
    if (FT_Outline_Get_Bitmap(slot->library, &slot->outline, &bitmap) != 0)
        return std::unexpected(ColorGlyphPaintError::OutlineUnavailable);

    if (!clip.empty()) {
        for (std::size_t i = 0; i < pixelCount; ++i)
            mask[i] = static_cast<std::uint8_t>((static_cast<unsigned int>(mask[i]) * clip[i] + 127) / 255);
    }
    return paintNode(context, node.paint, transform, mask.first(pixelCount), depth + 1);
}

std::expected<void, ColorGlyphPaintError> paintNode(PaintContext& context, FT_OpaquePaint opaque, const Affine& transform, std::span<const std::uint8_t> clip, std::size_t depth)
{
    if (depth >= maxGraphDepth)
        return std::unexpected(ColorGlyphPaintError::GraphTooDeep);
    FT_COLR_Paint paint;
    if (!FT_Get_Paint(context.face, opaque, &paint))
        return std::unexpected(ColorGlyphPaintError::NotAColorGlyph);

    switch (paint.format) {
    case FT_COLR_PAINTFORMAT_COLR_LAYERS: {
        FT_OpaquePaint layer;
        layer.p = nullptr;
        layer.insert_root_transform = 0;
        while (FT_Get_Paint_Layers(context.face, &paint.u.colr_layers.layer_iterator, &layer)) {
            auto result = paintNode(context, layer, transform, clip, depth + 1);
            if (!result)
                return result;
        }
        return {};
    }
    case FT_COLR_PAINTFORMAT_SOLID:
        return paintSolid(context, paint.u.solid, clip);
    case FT_COLR_PAINTFORMAT_LINEAR_GRADIENT:
        return paintLinearGradient(context, paint.u.linear_gradient, transform, clip);
    case FT_COLR_PAINTFORMAT_RADIAL_GRADIENT:
        return paintRadialGradient(context, paint.u.radial_gradient, transform, clip);
    case FT_COLR_PAINTFORMAT_GLYPH:
        return paintGlyph(context, paint.u.glyph, transform, clip, depth);
    case FT_COLR_PAINTFORMAT_COLR_GLYPH: {
        // Its root transform is the one already on the stack.
        FT_OpaquePaint root;
        root.p = nullptr;
        root.insert_root_transform = 0;
        if (!FT_Get_Color_Glyph_Paint(context.face, paint.u.colr_glyph.glyphID, FT_COLOR_NO_ROOT_TRANSFORM, &root))
            return std::unexpected(ColorGlyphPaintError::NotAColorGlyph);
        return paintNode(context, root, transform, clip, depth + 1);
    }
    case FT_COLR_PAINTFORMAT_TRANSFORM: {
        const FT_Affine23& affine = paint.u.transform.affine;
        const Affine node {
            .xx = fromFixed(affine.xx),
            .xy = fromFixed(affine.xy),
            .yx = fromFixed(affine.yx),
            .yy = fromFixed(affine.yy),
            .xOffset = fromFixed(affine.dx),
            .yOffset = fromFixed(affine.dy),
        };
        return paintNode(context, paint.u.transform.paint, transform.then(node), clip, depth + 1);
    }
    case FT_COLR_PAINTFORMAT_TRANSLATE: {
        const Affine node {
            .xOffset = fromFixed(paint.u.translate.dx),
            .yOffset = fromFixed(paint.u.translate.dy),
        };
        return paintNode(context, paint.u.translate.paint, transform.then(node), clip, depth + 1);
    }
    case FT_COLR_PAINTFORMAT_SCALE: {
        // About the centre: translate it to the origin, scale, translate back.
        const double scaleX = fromFixed(paint.u.scale.scale_x);
        const double scaleY = fromFixed(paint.u.scale.scale_y);
        const double centreX = fromFixed(paint.u.scale.center_x);
        const double centreY = fromFixed(paint.u.scale.center_y);
        const Affine node {
            .xx = scaleX,
            .yy = scaleY,
            .xOffset = centreX - scaleX * centreX,
            .yOffset = centreY - scaleY * centreY,
        };
        return paintNode(context, paint.u.scale.paint, transform.then(node), clip, depth + 1);
    }
    case FT_COLR_PAINTFORMAT_COMPOSITE:
        return paintComposite(context, paint.u.composite, transform, clip, depth);
    case FT_COLR_PAINTFORMAT_SWEEP_GRADIENT:
    case FT_COLR_PAINTFORMAT_ROTATE:
    case FT_COLR_PAINTFORMAT_SKEW:
    case FT_COLR_PAINTFORMAT_UNSUPPORTED:
    default:
        return std::unexpected(ColorGlyphPaintError::UnsupportedPaint);
    }
}

} // namespace

double extendedColorLineParameter(double parameter, double first, double last, ColorLineExtend extend)
{
    const double range = last - first;
    if (!(range > 0.0))
        return first;
    switch (extend) {
    case ColorLineExtend::Repeat: {
        double offset = std::fmod(parameter - first, range);
        if (offset < 0.0)
            offset += range;
        return first + offset;
    }
    case ColorLineExtend::Reflect: {
        double offset = std::fmod(parameter - first, 2.0 * range);
        if (offset < 0.0)
            offset += 2.0 * range;
        if (offset > range)
            offset = 2.0 * range - offset;
        return first + offset;
    }
    case ColorLineExtend::Pad:
    default:
        return std::clamp(parameter, first, last);
    }
}

bool ColorGlyphPainter::hasPaintGraph(FT_FaceRec_* face, unsigned int glyphIndex)
{
    if (!face)
        return false;
    FT_OpaquePaint root;
    root.p = nullptr;
    root.insert_root_transform = 0;
    return FT_Get_Color_Glyph_Paint(face, glyphIndex, FT_COLOR_NO_ROOT_TRANSFORM, &root) != 0;
}

std::span<std::uint8_t> ColorGlyphPainter::maskForDepth(std::size_t depth, std::size_t pixelCount)
{
    if (m_masks.size() <= depth)
        m_masks.resize(depth + 1);
    std::vector<std::uint8_t>& mask = m_masks[depth];
    if (mask.size() < pixelCount)
        mask.resize(pixelCount);
    return { mask.data(), pixelCount };
}

std::expected<void, ColorGlyphPaintError> ColorGlyphPainter::paint(FT_FaceRec_* face, unsigned int glyphIndex, ColorRGBA8 foreground, ColorGlyphCanvas canvas, ColorGlyphPlacement placement)
{
    if (canvas.widthInPixels <= 0 || canvas.heightInPixels <= 0)
        return std::unexpected(ColorGlyphPaintError::CanvasMismatch);
    const std::size_t pixelCount = static_cast<std::size_t>(canvas.widthInPixels) * static_cast<std::size_t>(canvas.heightInPixels);
    if (canvas.premultipliedBGRA.size() != pixelCount * 4)
        return std::unexpected(ColorGlyphPaintError::CanvasMismatch);
    if (!face)
        return std::unexpected(ColorGlyphPaintError::NotAColorGlyph);

    FT_OpaquePaint root;
    root.p = nullptr;
    root.insert_root_transform = 0;
    if (!FT_Get_Color_Glyph_Paint(face, glyphIndex, FT_COLOR_INCLUDE_ROOT_TRANSFORM, &root))
        return std::unexpected(ColorGlyphPaintError::NotAColorGlyph);

    PaintContext context {
        .face = face,
        .painter = *this,
        .canvas = canvas,
        .foreground = foreground,
        .toCanvas = {
            .xx = placement.scale,
            .yy = placement.scale,
            .xOffset = placement.originX,
            .yOffset = placement.originY,
        },
    };
    // The first palette; a face with none has no colours to paint with. The
    // array belongs to the face and stays valid until the next selection.
    FT_Palette_Data paletteData;
    FT_Color* palette = nullptr;
    if (FT_Palette_Data_Get(face, &paletteData) == 0 && paletteData.num_palettes > 0 && FT_Palette_Select(face, 0, &palette) == 0 && palette) {
        context.palette = palette;
        context.paletteSize = paletteData.num_palette_entries;
    }

    return paintNode(context, root, context.toCanvas, {}, 0);
}

} // namespace Ubiquitty::Linux
