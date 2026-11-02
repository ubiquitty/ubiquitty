// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <algorithm>
#include <cmath>

namespace Ubiquitty::Linux {

/// Converts GTK's 1024*dots/inch setting; an unset value uses 96 DPI.
///
/// - Parameter setting: The gtk-xft-dpi property, or -1 when unavailable.
/// - Returns: Logical dots per inch.
[[nodiscard]] inline double fontDPIFromSettings(int setting)
{
    return setting > 0 ? static_cast<double>(setting) / 1024.0 : 96.0;
}

/// Device pixels per typographic point, including the window backing scale.
///
/// - Parameters:
///   - logicalDPI: Logical dots per inch from the desktop font settings.
///   - deviceScale: Backing pixels per logical pixel.
/// - Returns: The bounded conversion factor shared by font size and spacing.
[[nodiscard]] inline double fontPixelsPerPoint(double logicalDPI, int deviceScale)
{
    const double dpi = std::isfinite(logicalDPI) && logicalDPI > 0 ? logicalDPI : 96.0;
    // The largest configured font is 256pt; cap its device em at 4096px.
    return std::min(dpi / 72.0 * std::max(deviceScale, 1), 16.0);
}

/// Rounds after converting points to device pixels, retaining fractional sizes.
///
/// - Parameters:
///   - points: The configured or zoomed font size in points.
///   - logicalDPI: Logical dots per inch from the desktop font settings.
///   - deviceScale: Backing pixels per logical pixel.
/// - Returns: A device em size between 1 and 4096 pixels.
[[nodiscard]] inline int fontPixelSize(double points, double logicalDPI, int deviceScale)
{
    const double size = std::isfinite(points) ? points : 12.0;
    return static_cast<int>(std::lround(std::clamp(size * fontPixelsPerPoint(logicalDPI, deviceScale), 1.0, 4096.0)));
}

} // namespace Ubiquitty::Linux
