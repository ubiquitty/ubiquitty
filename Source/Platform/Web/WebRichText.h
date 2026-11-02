// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "Core/Rendering/FontMetrics.h"
#include "Core/Rendering/TerminalFrameInputs.h"
#include "Core/RichText/Shaping.h"

#include <array>
#include <string>
#include <unordered_map>

namespace Ubiquitty::Web {

/// Browser font measurement and presentation of Core-owned rich text blocks.
class WebRichText {
public:
    /// Releases the browser adapter and its retained measurement nodes.
    ~WebRichText();
    /// Starts a distinct renderer identity, including when a pane view is recreated.
    WebRichText();
    WebRichText(const WebRichText&) = delete;
    WebRichText& operator=(const WebRichText&) = delete;
    /// Measures the same class faces used by the browser's retained text layers.
    ///
    /// - Parameters:
    ///   - gridFamily: CSS font cascade for monospace runs.
    ///   - proportionalFamily: CSS cascade for proportional runs; empty selects sans-serif.
    ///   - metrics: Grid geometry in device pixels.
    ///   - size: Proportional font size in CSS pixels.
    ///   - gridSize: Monospace font size in CSS pixels.
    ///   - deviceScale: Device pixels per CSS pixel.
    /// - Returns: Core typography facts, or empty facts when measurement fails.
    [[nodiscard]] RichText::TypographyFacts configure(std::string gridFamily, std::string proportionalFamily,
        const Rendering::CellMetrics& metrics, double size, double gridSize, double deviceScale);
    /// Whether browser font loading or feature changes invalidated the publication.
    [[nodiscard]] bool needsConfiguration() const;
    /// Shapes complete paragraphs through the browser's native text engine.
    /// - Returns: A shaper borrowing this adapter for its lifetime.
    [[nodiscard]] RichText::Shaper shaper();
    /// Reads the browser's prefetched font inventory; never requests permission.
    [[nodiscard]] RichText::FontCatalogProvider fontCatalog();
    /// Describes the captured blocks. Unchanged documents stay in the page cache.
    /// - Parameters:
    ///   - frame: The captured Core frame.
    ///   - chrome: Overlays that occlude rich text.
    /// - Returns: Borrowed JSON, valid until the next call.
    [[nodiscard]] const char* frameJSON(const Rendering::TerminalFrameInputs& frame, Rendering::ChromeLayers chrome = {});

private:
    int m_adapterHandle = 0;
    std::uint32_t m_fontGeneration = 0;
    std::array<std::string, 3> m_families { "sans-serif", "serif", "monospace" };
    RichText::TypographyFacts m_facts;
    std::unordered_map<std::uint32_t, std::uint64_t> m_sentKeys;
    std::string m_frameJSON;
};

} // namespace Ubiquitty::Web
