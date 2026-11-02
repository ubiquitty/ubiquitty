// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Preferences/PreferencesAccessors.h"
#include "Core/Preferences/RenderStyle.h"
#include "Core/Rendering/UnifontRasterizer.h"

#include <optional>

namespace Ubiquitty::Linux {

/// Holds the spacing both glyph faces are built with, in device pixels.
///
/// The native face and the embedded bitmap face take one value, so switching
/// between them moves neither the rows nor the columns, and the bitmap tier
/// draws the same cell pitch the portable reference and the other arms draw.
struct FaceSpacing {
    /// The rows added to every cell.
    int lineSpacingInPixels { 0 };
    /// The columns added to every cell; negative tightens it.
    int characterSpacingInPixels { 0 };
};

/// Converts the configured spacing to device pixels at a display scale.
///
/// - Parameters:
///   - configuration: What the configuration resolved to.
///   - deviceScale: Device pixels per point.
/// - Returns: The spacing to build both faces with.
[[nodiscard]] inline FaceSpacing faceSpacing(const Rendering::RenderConfiguration& configuration, double deviceScale)
{
    return {
        .lineSpacingInPixels = static_cast<int>(configuration.lineSpacingPoints * deviceScale + 0.5),
        .characterSpacingInPixels = Preferences::Effective::characterSpacingInPixels(configuration, deviceScale),
    };
}

/// Builds the embedded bitmap face at a requested size and the shared spacing.
///
/// The size reaches the face as an integer upscale, so a configured size
/// larger than the native 8x16 cell draws larger rather than at the default.
///
/// - Parameters:
///   - face: Rebuilt in place.
///   - fontSizePoints: The requested size in points.
///   - deviceScale: Device pixels per point.
///   - spacing: The spacing the native face is built with.
inline void emplaceBitmapFace(std::optional<Rendering::UnifontRasterizer>& face, double fontSizePoints, double deviceScale, FaceSpacing spacing)
{
    face.emplace(Rendering::unifontScaleForRequestedSize(fontSizePoints, deviceScale), spacing.lineSpacingInPixels,
        spacing.characterSpacingInPixels);
}

} // namespace Ubiquitty::Linux
