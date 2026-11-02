// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Rendering/CellMetrics.h"
#include "Core/Rendering/TerminalFrameInputs.h"
#include "Core/RichText/Shaping.h"

#include <memory>
#include <span>
#include <string>

namespace Ubiquitty::Linux {

/// Font ownership and retained paragraph pixels for a Linux surface. Pango
/// supplies line breaks, fallback, bidi and grapheme carets; Core owns the
/// resulting geometry and all terminal-visible decisions.
class PangoRichText {
public:
    /// Creates an isolated font map and empty raster cache.
    PangoRichText();
    /// Releases the font map and its retained paragraph rasters.
    ~PangoRichText();
    PangoRichText(const PangoRichText&) = delete;
    PangoRichText& operator=(const PangoRichText&) = delete;

    /// Reconfigures fonts and invalidates retained pixels. Metrics are device
    /// pixels, font sizes are points, and pixelsPerPoint includes DPI and backing scale.
    RichText::TypographyFacts configure(std::string gridFamily, std::string proportionalFamily,
        const Rendering::CellMetrics&, double size, double monospaceSize, double pixelsPerPoint);
    /// Invalidates the resolved font inventory; configure republishes a new
    /// renderer revision even when the replacement dense metrics are equal.
    void invalidateFonts();
    /// Borrowed native callback; no GTK calls or UI-thread dispatch.
    [[nodiscard]] RichText::Shaper shaper();
    /// Reads the font-map snapshot prepared by configure, without UI dispatch.
    [[nodiscard]] RichText::FontCatalogProvider fontCatalog();
    /// Composites a portable frame's rich layer over the frontend's RGBA8
    /// readback. CPU and Vulkan grid paths share this same retained layer.
    /// Occlusions are native chrome in device pixels; a bar caret is painted
    /// after the text when drawCaret is true (the grid pass then omits it).
    void composite(const Rendering::TerminalFrameInputs&, std::span<std::uint8_t> rgba, int width, int height,
        std::span<const IntRect> occlusions = {}, bool drawCaret = false); // bool-ok: the grid pass already owns cursor visibility.
    /// Returns the number of content rasters built, excluding cached composites.
    [[nodiscard]] std::size_t rasterCount() const;

private:
    struct PangoStorage;
    std::unique_ptr<PangoStorage> m_state;
};

} // namespace Ubiquitty::Linux
