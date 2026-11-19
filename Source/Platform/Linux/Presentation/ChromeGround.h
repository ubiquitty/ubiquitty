// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Themes/Contrast.h"

#include <cstdint>

namespace Ubiquitty::Linux::Presentation {

/// The colour the window chrome is drawn on, which decides how a program's
/// icon is inked and whether it needs a plate to be made out.
struct ChromeGround {
    /// The ground, as 0xRRGGBB.
    std::uint32_t groundRGB = lightHeaderRGB;
    /// Whether the ground is dark, so the chrome's ink is light.
    bool isDark = false; // bool-ok: names the one condition it reports

    /// The ground a stock light header bar is drawn on.
    static constexpr std::uint32_t lightHeaderRGB = 0xEBEBED;
    /// The ground a stock dark header bar is drawn on.
    static constexpr std::uint32_t darkHeaderRGB = 0x2E2E32;

    /// The ground for a known background colour, as a themed title bar has.
    ///
    /// - Parameter rgb: The background, as 0xRRGGBB.
    /// - Returns: The ground, dark when white reads better on it than black.
    [[nodiscard]] static ChromeGround fromBackground(std::uint32_t rgb)
    {
        const bool isDark = Themes::Contrast::wcagContrastRatio(0xFFFFFF, rgb) > Themes::Contrast::wcagContrastRatio(0x000000, rgb);
        return { .groundRGB = rgb, .isDark = isDark };
    }

    /// The ground a stock header bar is drawn on, read off the toolkit's ink:
    /// a theme inks a dark header light.
    ///
    /// - Parameter isInkLight: Whether the header's text colour is light.
    /// - Returns: The stock ground of that polarity.
    [[nodiscard]] static ChromeGround forStockHeader(bool isInkLight) // bool-ok: one polarity in, one ground out
    {
        return isInkLight ? ChromeGround { .groundRGB = darkHeaderRGB, .isDark = true } : ChromeGround {};
    }

    bool operator==(const ChromeGround&) const = default;
};

} // namespace Ubiquitty::Linux::Presentation
