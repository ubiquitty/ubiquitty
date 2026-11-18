// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// A mixed grid/proportional frame through the dedicated Vulkan sheet. The
// instance count proves the per-glyph route was taken; byte equality against
// the software renderer proves its placement, phase, and coverage agree.
/// Checks the proportional glyph route against complete software rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeProportionalAtlas()
{
    setupFonts();
    activePane()->session->start(4, 48);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-proportional-atlas: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer nativeRasterizer(16, "JetBrains Mono",
        std::string(), std::string(), bundledPath, 1, 0);
    Ubiquitty::Rendering::UnifontRasterizer bitmapRasterizer(1, 0);
    if (!nativeRasterizer.ready() || !nativeRasterizer.hasProportionalFace()) {
        g_printerr("smoke-proportional-atlas: FAILED — no native proportional face\n");
        return 1;
    }
    int pixelFailures = 0;
    int modelFailures = 0;
    for (int arm = 0; arm < 2; ++arm) {
        bool hasDedicatedRoute = false;
        Ubiquitty::Rendering::GlyphRasterizer& rasterizer = arm == 0
            ? static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(nativeRasterizer)
            : static_cast<Ubiquitty::Rendering::GlyphRasterizer&>(bitmapRasterizer);
        const char* armName = arm == 0 ? "native" : "bitmap";
        app().rasterContext.setGlyphRasterizer(rasterizer);
        app().rasterContext.setEmbeddedBitmapScale(arm);
        app().rasterContext.resetSoftwareRenderer();
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        renderer.setLigatureRasterizer(rasterizer);
        if (!renderer.init()) {
            g_printerr("smoke-proportional-atlas: FAILED — Vulkan init failed\n");
            return 1;
        }
        const float cellAdvance = static_cast<float>(Ubiquitty::Rendering::cellDimension(rasterizer.cellMetrics().cellWidth));
        const std::array<std::uint32_t, 7> pattern { 'W', 'W', 'i', 'i', ' ', 'j', ' ' };
        std::vector<Ubiquitty::ProportionalShapedGlyph> patternShape(pattern.size() * 2);
        const int patternCount = rasterizer.shapeProportionalRun(pattern,
            Ubiquitty::Rendering::FontFace::Regular, patternShape);
        float patternAdvance = 0.0f;
        for (int index = 0; index < patternCount; ++index) {
            patternAdvance += patternShape[static_cast<std::size_t>(index)].advanceInPixels;
        }
        if (patternAdvance <= 0.0f) {
            renderer.shutdown();
            g_printerr("smoke-proportional-atlas: FAILED — no proportional advances\n");
            return 1;
        }
        for (const int columns : { 48, 1024 }) {
            Ubiquitty::resize(*term, 4, columns);
            std::vector<std::uint8_t> gpu;
            int gpuWidth = 0;
            int gpuHeight = 0;
            // The measurer reads the same sheet the frame uses, after its
            // geometry exists; the test never substitutes cell ownership.
            if (!renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight)) {
                renderer.shutdown();
                g_printerr("smoke-proportional-atlas: FAILED — initial frame failed\n");
                return 1;
            }
            activePane()->session->setTextMeasurer(
                [](void* context, const std::uint32_t* codePoints, int count, std::uint8_t faceBits, std::uint32_t weight,
                    Ubiquitty::ProportionalShapedGlyph* glyphsOut, int capacity, float* advanceOut) {
                    auto& source = *static_cast<Ubiquitty::Linux::VulkanRenderer*>(context);
                    *advanceOut = source.proportionalCellAdvanceInPixels();
                    return source.shapeProportionalRun(
                        std::span<const std::uint32_t>(codePoints, static_cast<std::size_t>(count)),
                        Ubiquitty::ProportionalRunStyle { .faceBits = faceBits, .weight = weight },
                        std::span<Ubiquitty::ProportionalShapedGlyph>(glyphsOut, static_cast<std::size_t>(capacity)));
                },
                &renderer);
            const int repetitions = std::max(1, static_cast<int>(0.85f * columns * cellAdvance / patternAdvance));
            std::string text;
            for (int index = 0; index < repetitions; ++index) {
                text += "WWii j ";
            }
            text += 'W';
            const std::vector<std::uint32_t> codePoints(text.begin(), text.end());
            std::vector<Ubiquitty::ProportionalShapedGlyph> shaped(codePoints.size() * 2);
            const int shapedCount = rasterizer.shapeProportionalRun(codePoints,
                Ubiquitty::Rendering::FontFace::Regular, shaped);
            shaped.resize(static_cast<std::size_t>(std::max(0, shapedCount)));
            std::vector<Ubiquitty::Rendering::ProportionalGlyphPlacement> placements(shaped.size());
            for (const std::uint8_t alignment : { 0, 2, 3 }) {
                Ubiquitty::processBytes(term, "\x1b[2J\x1b[H\x1b[0m\x1b[?25l");
                term->drawsSizedText = true;
                term->drawsProportionalText = true;
                const std::string content = "mono grid stays fixed\r\n\x1b]66;p=1:c=20;"
                    + std::string(48, 'i') + "\x07\r\n\x1b[38;2;237;157;43m\x1b]66;p=1:c="
                    + std::to_string(columns) + ":h=" + std::to_string(alignment) + ";" + text + "\x07";
                Ubiquitty::processBytes(term, content);
                const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight);
                const std::uint32_t proportionalInstances = renderer.lastFrameProportionalInstanceCount();
                hasDedicatedRoute |= proportionalInstances >= 48;
                const std::uint32_t stripInstances = renderer.lastFrameProportionalStripInstanceCount();
                std::vector<std::uint8_t> cpu;
                int cpuWidth = 0;
                int cpuHeight = 0;
                const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight);
                std::size_t differingPixels = 0;
                const bool hasMatchingDimensions = didRenderGPUFrame && didRenderCPUFrame
                    && gpuWidth == cpuWidth && gpuHeight == cpuHeight && gpu.size() == cpu.size();
                if (hasMatchingDimensions) {
                    for (std::size_t index = 0; index < cpu.size(); index += 4) {
                        differingPixels += std::memcmp(cpu.data() + index, gpu.data() + index, 4) != 0;
                    }
                }
                const auto layout = Ubiquitty::Rendering::layoutProportionalRun(shaped, codePoints,
                    columns, alignment, cellAdvance, placements);
                const bool hasLayout = layout.glyphCount > 0;
                const float tailX = hasLayout ? placements.back().xInPixels : 0.0f;
                const int expectedTailColumn = std::clamp(static_cast<int>(std::floor(tailX / cellAdvance)), 0, columns - 1);
                const bool hasCorrectCaret = hasLayout
                    && Ubiquitty::Rendering::proportionalRunCodePointAt(placements, layout,
                           static_cast<int>(codePoints.size()), tailX + 0.01)
                        == static_cast<int>(codePoints.size()) - 1;
                bool hasTailInk = false;
                if (hasMatchingDimensions && hasLayout && cpu.size() >= 4) {
                    const int firstX = std::clamp(static_cast<int>(std::floor(tailX)) - 2, 0, cpuWidth);
                    const int lastX = std::clamp(static_cast<int>(std::ceil(tailX + shaped.back().advanceInPixels)) + 2, 0, cpuWidth);
                    const int rowHeight = cpuHeight / 4;
                    const std::uint8_t* background = cpu.data() + cpu.size() - 4;
                    for (int y = rowHeight * 2; y < rowHeight * 3; ++y) {
                        for (int x = firstX; x < lastX; ++x) {
                            const std::size_t pixel = (static_cast<std::size_t>(y) * cpuWidth + x) * 4;
                            hasTailInk |= std::memcmp(cpu.data() + pixel, background, 3) != 0;
                        }
                    }
                }
                bool hasFractionalPlacement = false;
                for (const auto& placement : placements) {
                    hasFractionalPlacement |= placement.xInPixels != std::floor(placement.xInPixels);
                }
                // The run's text rides its anchor, so the source reads back from one
                // cell; which cell the tail letter belongs to is the layout's answer
                // because the cells carry only the claim.
                const Ubiquitty::Cell& runAnchor = *term->grid->cellAt(Ubiquitty::Row(2), Ubiquitty::Column(0));
                const auto anchorText = Ubiquitty::runTextCodePoints(term, runAnchor);
                const std::vector<std::uint32_t> stored(anchorText.begin(), anchorText.end());
                std::vector<std::uint16_t> owners(codePoints.size());
                if (hasLayout) {
                    Ubiquitty::Rendering::proportionalRunCellOwners(shaped.empty()
                            ? std::span<const Ubiquitty::Rendering::ProportionalGlyphPlacement> {}
                            : std::span<const Ubiquitty::Rendering::ProportionalGlyphPlacement>(placements.data(), shaped.size()),
                        layout, static_cast<int>(codePoints.size()), columns, cellAdvance, owners);
                }
                const int storedTailColumn = (hasLayout && !owners.empty()) ? static_cast<int>(owners.back()) : -1;
                Ubiquitty::Selection::Session selection {};
                Ubiquitty::Selection::init(selection);
                Ubiquitty::Selection::selectAllText(selection, *term);
                const bool hasCompleteStoredSource = stored == codePoints;
                const std::string copied = Ubiquitty::Selection::copiedText(selection, *term);
                const bool hasCompleteCopy = copied.find(text) != std::string::npos;
                const bool hasCorrectOwner = storedTailColumn == expectedTailColumn;
                // The claim fills the row: the cursor stands on its last cell
                // with the wrap pending.
                const bool hasFixedGrid = term->screens.active->cursorX == columns - 1 && term->screens.active->wrapPending
                    && term->grid->rowMeta(2).has(Ubiquitty::RowFlag::Flowed)
                    && !term->grid->rowMeta(0).has(Ubiquitty::RowFlag::Flowed);
                const bool didPixelsPass = hasMatchingDimensions && differingPixels == 0
                    && stripInstances > 1 && hasFractionalPlacement && hasTailInk;
                pixelFailures += !didPixelsPass;
                modelFailures += !(hasCompleteStoredSource && hasCompleteCopy && hasCorrectCaret && hasCorrectOwner && hasFixedGrid);
                g_print("  %s columns=%d h=%u characters=%zu dedicated=%u tiles=%u differing=%zu fractional=%d"
                        " tail-ink=%d stored=%d copied=%d caret=%d owner=%d/%d grid=%d pixels=%s\n",
                    armName, columns, static_cast<unsigned>(alignment), codePoints.size(), proportionalInstances,
                    stripInstances, differingPixels, hasFractionalPlacement, hasTailInk, hasCompleteStoredSource, hasCompleteCopy, hasCorrectCaret,
                    storedTailColumn, expectedTailColumn, hasFixedGrid, didPixelsPass ? "PASS" : "FAIL");
                if (!hasCompleteCopy) {
                    const std::size_t rowStart = copied.find("\n", copied.find("\n") + 1) + 1;
                    const std::string copiedRow = copied.substr(rowStart);
                    std::size_t mismatch = 0;
                    while (mismatch < text.size() && mismatch < copiedRow.size() && text[mismatch] == copiedRow[mismatch]) {
                        ++mismatch;
                    }
                    g_print("    copied-row length=%zu first-mismatch=%zu expected-byte=%d actual-byte=%d\n",
                        copiedRow.size(), mismatch,
                        mismatch < text.size() ? static_cast<unsigned char>(text[mismatch]) : -1,
                        mismatch < copiedRow.size() ? static_cast<unsigned char>(copiedRow[mismatch]) : -1);
                }
            }
        }
        activePane()->session->setTextMeasurer(nullptr, nullptr);
        pixelFailures += !hasDedicatedRoute;
        renderer.shutdown();
        app().rasterContext.resetSoftwareRenderer();
    }
    app().rasterContext.setGlyphRasterizer(currentRasterizer());
    g_print("smoke-proportional-atlas: pixel failures=%d, source/caret/owner failures=%d -- %s\n",
        pixelFailures, modelFailures, pixelFailures == 0 && modelFailures == 0 ? "PASS" : "FAIL");
    return pixelFailures == 0 && modelFailures == 0 ? 0 : 1;
}
