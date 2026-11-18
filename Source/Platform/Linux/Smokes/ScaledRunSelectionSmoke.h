// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-scaled-run-selection — a selection over a scaled proportional run
// lights the letters it holds through their ink, on every band row, on both
// arms. The run is "Hello" at c=6:s=3 in the bundled JetBrains Mono's
// proportional face, whose o begins in one of the run's cells and runs on
// into the next; a rectangle selection on the middle band alone, as the
// snapshot's --select-rect sets it, from the run's third column to the last
// column the text reaches, must tint every background pixel between the H's
// ink and the o's on all three band rows — the o's ink included, which a
// highlight stopping at the cell the o begins in leaves bare — and a
// selection ending two cells short must tint none of the o's. The copy is the
// word for the first and "He" for the second. The CPU and Vulkan frames agree
// byte for byte with the selection set.
/// Checks selection tint across every row of scaled proportional text.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeScaledRunSelection()
{
    setupFonts();
    constexpr int rows = 6;
    constexpr int columns = 30;
    activePane()->session->start(rows, columns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-scaled-run-selection: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer(26, "JetBrains Mono", std::string(), std::string(), bundledPath, 1, 0);
    if (!rasterizer.ready() || !rasterizer.hasProportionalFace()) {
        g_printerr("smoke-scaled-run-selection: FAILED — no native proportional face\n");
        return 1;
    }
    app().rasterContext.setGlyphRasterizer(rasterizer);
    app().rasterContext.resetSoftwareRenderer();
    // The measurer the snapshot installs: the face the frame draws in, at the
    // grid's pitch, so Core's owner map and the frame's layout are one.
    activePane()->session->setTextMeasurer(
        [](void* context, const std::uint32_t* codePoints, int count, std::uint8_t faceBits, std::uint32_t,
            Ubiquitty::ProportionalShapedGlyph* glyphsOut, int capacity, float* cellAdvanceOut) {
            auto& face = *static_cast<Ubiquitty::Linux::FreeTypeRasterizer*>(context);
            if (cellAdvanceOut)
                *cellAdvanceOut = static_cast<float>(face.cellMetrics().cellWidth);
            return face.shapeProportionalRun(std::span<const std::uint32_t>(codePoints, static_cast<std::size_t>(count)),
                static_cast<Ubiquitty::Rendering::FontFace>(faceBits), std::span<Ubiquitty::ProportionalShapedGlyph>(glyphsOut, static_cast<std::size_t>(capacity)));
        },
        &rasterizer);
    term->drawsSizedText = true;
    term->drawsProportionalText = true;
    Ubiquitty::processBytes(term, std::string_view("\x1b[?25lAx\x1b]66;s=2;X\x1b\\yz \x1b]66;p=1:c=6:s=2;Hello\x1b\\|\r\n\r\n\x1b]66;p=1:c=6:s=3;Hello\x1b\\|"));
    constexpr int runRow = 2;
    constexpr int runScale = 3;
    constexpr int runCells = 6;
    const Ubiquitty::Cell* anchor = Ubiquitty::Screen::visibleCell(term, 0, runRow, 0);
    if (!anchor || !Ubiquitty::isProportionalRunAnchor(term, *anchor)) {
        g_printerr("smoke-scaled-run-selection: FAILED — no scaled run anchored at row %d\n", runRow);
        return 1;
    }
    // Where the run's letters stand, by Core's own layout: the cell the o
    // begins in and the cells the text reaches.
    const std::span<const std::uint32_t> text = Ubiquitty::runTextCodePoints(term, *anchor);
    std::vector<std::uint16_t> owners(text.size());
    int textCells = 0;
    if (text.size() != 5 || !Ubiquitty::OSC::TextSizing::proportionalRunCellOwners(*term, text, runCells, 0, Ubiquitty::OSC::TextSizing::runStyleOf(Ubiquitty::cellPen(*anchor)), owners, &textCells)) {
        g_printerr("smoke-scaled-run-selection: FAILED — the run did not measure\n");
        return 1;
    }
    const int lastLetterCell = owners.back();
    const int textLastColumn = textCells * runScale - 1;
    const bool doesInkRunOn = textCells - 1 > lastLetterCell;
    Ubiquitty::PAL::logLine(stdout, "smoke-scaled-run-selection: o begins in cell {}, the text reaches cell {} ({} columns){}", lastLetterCell, textCells - 1,
        textCells * runScale, doesInkRunOn ? "" : " -- the face keeps the o inside its cell, so the ink past it is not exercised");

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasterizer);
    renderer.setLigatureRasterizer(rasterizer);
    if (!renderer.init())
        return skipNoGPUFrame("smoke-scaled-run-selection", "vulkan init failed");
    struct Frame {
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int width = 0;
        int height = 0;
        bool isRendered = false;
        bool isSame = false;
    };
    const auto render = [&](Ubiquitty::Selection::Session* selection) {
        Frame frame;
        int gpuWidth = 0;
        int gpuHeight = 0;
        const bool didRenderCPU = app().rasterContext.rasterizeTerm(term, frame.cpu, frame.width, frame.height, 0, selection);
        const bool didRenderGPU = renderer.renderGrid(app().rasterContext, term, frame.gpu, gpuWidth, gpuHeight, 0, selection);
        frame.isRendered = didRenderCPU && didRenderGPU && frame.width > 0 && frame.height > 0;
        frame.isSame = frame.isRendered && gpuWidth == frame.width && gpuHeight == frame.height && frame.cpu == frame.gpu;
        return frame;
    };
    const Frame bare = render(nullptr);
    // The rectangle the snapshot's --select-rect sets: the middle band row
    // alone, from the run's third column to the text's last column, and the
    // same rectangle backwards; then one ending in the run's second cell.
    struct Drag {
        const char* name;
        Ubiquitty::SelectionBounds rectangle;
        const char* copy;
        bool isLastLetterHeld;
    };
    const Drag drags[] = {
        { "F", { runRow + 1, 2, runRow + 1, textLastColumn - 1 }, "Hello", true },
        { "F-mirror", { runRow + 1, textLastColumn - 1, runRow + 1, 2 }, "Hello", true },
        { "short", { runRow + 1, 0, runRow + 1, 2 * runScale - 1 }, "He", false },
    };
    const Ubiquitty::Rendering::CellMetrics metrics = rasterizer.cellMetrics();
    const int scale = app().rasterContext.deviceScale();
    const int cellWidth = Ubiquitty::Rendering::cellDimension(metrics.cellWidth) * scale;
    const int cellHeight = Ubiquitty::Rendering::cellDimension(metrics.cellHeight) * scale;
    // The o's ink past the cell it begins in, or its own cell where the face
    // keeps it inside: the columns of the claim whose background the
    // selection must tint when it holds the o and leave when it does not.
    const int inkFirstColumn = (doesInkRunOn ? lastLetterCell + 1 : lastLetterCell) * runScale;
    const int inkLeft = inkFirstColumn * cellWidth;
    const int inkRight = (textLastColumn + 1) * cellWidth;
    const int bandTop = runRow * cellHeight;
    const int bandBottom = (runRow + runScale) * cellHeight;
    bool didPass = bare.isRendered && bare.isSame;
    if (!bare.isRendered)
        g_print("smoke-scaled-run-selection: the arms drew no frame\n");
    for (const Drag& drag : drags) {
        activePane()->viewOffset = 0;
        Ubiquitty::Selection::init(activePane()->selection);
        activePane()->selection.state = Ubiquitty::Selection::characterSelectionOverVisibleRows(*term, drag.rectangle);
        const std::string copied = selectionText();
        const Frame lit = render(&activePane()->selection);
        // Every pixel of the o's columns that is background in the bare frame:
        // tinted in the lit one where the o is held, untouched where not.
        int backgroundPixels = 0;
        int tintedCPU = 0;
        int tintedGPU = 0;
        if (bare.isRendered && lit.isRendered && lit.width == bare.width && lit.height == bare.height) {
            for (int y = bandTop; y < std::min(bandBottom, bare.height); ++y) {
                for (int x = inkLeft; x < std::min(inkRight, bare.width); ++x) {
                    const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(bare.width) + static_cast<std::size_t>(x)) * 4;
                    if (std::memcmp(bare.cpu.data() + offset, bare.cpu.data(), 4) != 0)
                        continue;
                    ++backgroundPixels;
                    tintedCPU += std::memcmp(lit.cpu.data() + offset, bare.cpu.data() + offset, 4) != 0 ? 1 : 0;
                    tintedGPU += std::memcmp(lit.gpu.data() + offset, bare.gpu.data() + offset, 4) != 0 ? 1 : 0;
                }
            }
        }
        const int wanted = drag.isLastLetterHeld ? backgroundPixels : 0;
        const bool isCopyRight = copied == drag.copy;
        const bool isLit = backgroundPixels > 0 && tintedCPU == wanted && tintedGPU == wanted;
        const bool didDragPass = isCopyRight && isLit && lit.isSame;
        didPass = didPass && didDragPass;
        Ubiquitty::PAL::logLine(stdout, "smoke-scaled-run-selection: {} rect {},{},{},{} copied \"{}\" (want \"{}\"), o's columns {}-{}: {} of {} background pixel(s) tinted on CPU, {} on GPU (want {}), CPU==GPU {} -- {}",
            drag.name, drag.rectangle.row0, drag.rectangle.column0, drag.rectangle.row1, drag.rectangle.column1, copied, drag.copy, inkFirstColumn, textLastColumn,
            tintedCPU, backgroundPixels, tintedGPU, wanted, oracleLabel(!lit.isRendered ? OracleOutcome::NotCompared : (lit.isSame ? OracleOutcome::Matched : OracleOutcome::Differed)),
            didDragPass ? "ok" : "WRONG");
        if (!didDragPass && lit.isRendered) {
            for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("cpu", lit.cpu), { "gpu", lit.gpu } }) {
                const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { lit.width, lit.height });
                const std::string path = std::string("/tmp/scaled_run_selection_") + drag.name + "_" + label + ".png";
                if (FILE* file = std::fopen(path.c_str(), "wb")) {
                    std::fwrite(png.data(), 1, png.size(), file);
                    std::fclose(file);
                    g_print("smoke-scaled-run-selection: wrote %s\n", path.c_str());
                }
            }
        }
    }
    renderer.shutdown();
    activePane()->session->setTextMeasurer(nullptr, nullptr);
    g_print("smoke-scaled-run-selection: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
