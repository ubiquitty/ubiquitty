// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks that glyph-prefix growth preserves existing rasterized glyphs.
///
/// - Parameters:
///   - renderer: The Vulkan renderer under examination.
///   - context: The raster context supplying the comparison glyphs.
/// - Returns: Whether every check passed.
bool smokeGlyphPrefixStability(Ubiquitty::Linux::VulkanRenderer& renderer, Ubiquitty::Linux::RasterContext& context)
{
    constexpr int rows = 6;
    constexpr int columns = 64;
    constexpr std::string_view prefix = "IlM09 AVWX";
    constexpr int comparedColumns = 7;
    Ubiquitty::Runtime::TerminalRuntime runtime;
    runtime.init(Ubiquitty::Runtime::RuntimeInitParameters { rows, columns, false });
    Ubiquitty::Terminal* terminal = runtime.borrowTermForRender();
    if (!terminal)
        return false;
    Ubiquitty::processBytes(terminal, "\x1b[?25l");
    const auto geometry = context.frameCaptureGeometry();
    Ubiquitty::Rendering::TerminalSnapshotOptions options;
    options.drawCursor = false;
    options.style = geometry.style;
    options.cellHeightPoints = geometry.cellHeightPoints;
    options.lineSpacingPoints = geometry.lineSpacingPoints;
    options.toolkitCaret = geometry.toolkitCaret;
    std::unique_ptr<Ubiquitty::Rendering::FrameCapture, LinuxPane::FrameRelease> captured(Ubiquitty::Rendering::FrameCapture::make());
    Ubiquitty::Rendering::FrameCapture::ViewTierOverrides emptyView;
    const auto prefixPixels = [&](const std::vector<std::uint8_t>& pixels, int width, int height) {
        const int comparedWidth = std::min(width, comparedColumns * context.cellWidth());
        std::vector<std::uint8_t> result;
        if (width <= 0 || height <= 0 || pixels.size() != static_cast<std::size_t>(width) * height * 4)
            return result;
        result.reserve(static_cast<std::size_t>(comparedWidth) * height * 4);
        for (int row = 0; row < height; ++row) {
            const auto first = pixels.begin() + static_cast<std::size_t>(row) * width * 4;
            result.insert(result.end(), first, first + comparedWidth * 4);
        }
        return result;
    };
    const std::array<std::string_view, 4> styles { "0", "1", "3", "1;3" };
    const std::array<std::string_view, 8> suffixes { "", "i", "WW", "M0i", ".aW9", "12345", "W1i9M0", "" };
    std::vector<std::uint8_t> referencePrefix;
    bool didPass = true;
    for (const auto suffix : suffixes) {
        for (std::size_t row = 0; row < styles.size(); ++row) {
            const std::string line = std::format("\x1b[{};1H\x1b[{}m{}{}\x1b[0m\x1b[K", row + 1, styles[row], prefix, suffix);
            Ubiquitty::processBytes(terminal, line);
        }
        std::vector<std::uint8_t> livePixels, capturedPixels;
        int liveWidth = 0, liveHeight = 0, capturedWidth = 0, capturedHeight = 0;
        const bool didDrawLive = renderer.renderGrid(context, terminal, livePixels, liveWidth, liveHeight);
        const bool didCapture = captured->capture(*terminal, options, geometry.metrics, geometry.glyphSlot);
        const bool didDrawCaptured = didCapture && renderer.renderGrid(context, terminal, capturedPixels, capturedWidth, capturedHeight, 0, nullptr, nullptr, 0, {}, captured.get(), &emptyView);
        const auto livePrefix = prefixPixels(livePixels, liveWidth, liveHeight);
        if (referencePrefix.empty())
            referencePrefix = livePrefix;
        const bool isStable = didDrawLive && didDrawCaptured && !livePrefix.empty()
            && liveWidth == capturedWidth && liveHeight == capturedHeight
            && livePixels == capturedPixels && livePrefix == referencePrefix;
        didPass = didPass && isStable;
        g_print("smoke-cursor: glyph-prefix suffix-length=%zu live==captured and unchanged-prefix -- %s\n", suffix.size(), isStable ? "PASS" : "FAIL");
    }
    return didPass;
}
