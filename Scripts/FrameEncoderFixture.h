// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#pragma clang module import UbiquittyCore

#include "Core/RichText/Blocks.h"

#include <memory>

/// Owns the immovable Core objects borrowed by the offscreen Swift driver.
class UBIQUITTY_NONCOPYABLE FrameEncoderFixture {
public:
    explicit FrameEncoderFixture(int columns)
        : m_terminal(std::make_unique<Ubiquitty::Terminal>())
        , m_renderer(std::make_unique<Ubiquitty::Rendering::SoftwareRenderer>(8, 16))
    {
        Ubiquitty::resize(*m_terminal, 4, columns);
        m_terminal->drawsSizedText = true;
        m_terminal->drawsProportionalText = true;
    }

    FrameEncoderFixture(FrameEncoderFixture&&) = default;
    FrameEncoderFixture& operator=(FrameEncoderFixture&&) = default;
    FrameEncoderFixture(const FrameEncoderFixture&) = delete;
    FrameEncoderFixture& operator=(const FrameEncoderFixture&) = delete;

    /// Borrows the terminal until this fixture is destroyed or moved.
    Ubiquitty::Terminal& terminal() UBIQUITTY_LIFETIMEBOUND { return *m_terminal; }
    /// Borrows the renderer until this fixture is destroyed or moved.
    Ubiquitty::Rendering::SoftwareRenderer& renderer() UBIQUITTY_LIFETIMEBOUND { return *m_renderer; }

    /// Installs the native shaper used by fixture captures.
    ///
    /// - Parameters:
    ///   - facts: The frontend's font and cell metrics.
    ///   - shape: The shaping callback.
    ///   - context: Borrowed callback state that outlives the fixture.
    void installRichText(const Ubiquitty::RichText::TypographyFacts& facts, Ubiquitty::RichText::Shaper::Function shape, void* context)
    {
        Ubiquitty::RichText::adoptTypography(*m_terminal, facts);
        m_terminal->typography.shaper = { shape, context };
    }

    /// Captures native text and a character selection for pixel checks.
    ///
    /// - Parameters:
    ///   - capture: Receives the frame.
    ///   - scale: Device pixels per point.
    /// - Returns: Whether a frame was captured.
    bool captureRichText(Ubiquitty::Rendering::FrameCapture& capture, float scale)
    {
        Ubiquitty::Rendering::TerminalSnapshotOptions options;
        options.drawCursor = false;
        options.viewportSizeInPixels = { 320 * scale, 64 * scale };
        options.style.platformSelectionColor = { 0.2f, 0.4f, 0.9f, 1.0f };
        Ubiquitty::RichText::BlockSelection selection;
        const auto blocks = m_terminal->richTextBlocks.blocks(Ubiquitty::ScreenMode::Alternate);
        if (!blocks.empty()) {
            selection = { blocks[0].serial, 1, 8 };
            options.richTextSelections = { &selection, 1 };
            options.richTextSelectionCount = 1;
        }
        Ubiquitty::Rendering::CellMetrics metrics;
        metrics.cellWidth = 8 * scale;
        metrics.cellHeight = 16 * scale;
        metrics.deviceScale = scale;
        metrics.atlasToDevicePixels = 1;
        return capture.capture(*m_terminal, options, metrics, Ubiquitty::Rendering::GlyphSlotGeometry {});
    }

private:
    std::unique_ptr<Ubiquitty::Terminal> m_terminal;
    std::unique_ptr<Ubiquitty::Rendering::SoftwareRenderer> m_renderer;
};
