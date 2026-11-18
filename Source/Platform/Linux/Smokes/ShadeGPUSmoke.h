// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Runs of ░ ▒ ▓ through the Vulkan arm at cells 9, 10 and 11 pixels wide and
// 17 tall — widths the shade field's period of four does not divide, which is
// where a pattern restarted per cell opens a seam. Every pixel of each run must
// be Core's grid-anchored field (ShadeStyle.h), so no background column opens
// at a cell edge; the medium and dark shades must ink every column and the
// light one never leave two adjacent columns empty.
/// Checks that shade patterns stay aligned to the grid across cell boundaries.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeShadeGPU()
{
    setupFonts();
    constexpr int columns = 8;
    constexpr int rows = 6;
    activePane()->session->start(rows, columns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-shade-gpu: no term\n");
        return 1;
    }
    const std::string_view canned = "\x1b[?25l\x1b[H"
                                    " \u2591\u2591\u2591\u2591\u2591\u2591\r\n"
                                    " \u2591\u2591\u2591\u2591\u2591\u2591\r\n"
                                    " \u2592\u2592\u2592\u2592\u2592\u2592\r\n"
                                    " \u2592\u2592\u2592\u2592\u2592\u2592\r\n"
                                    " \u2593\u2593\u2593\u2593\u2593\u2593\r\n"
                                    " \u2593\u2593\u2593\u2593\u2593\u2593";
    Ubiquitty::processBytes(term, canned);

    bool didPass = true;
    for (const int characterSpacing : { 1, 2, 3 }) {
        Ubiquitty::Rendering::UnifontRasterizer face(1, 1, characterSpacing);
        Ubiquitty::Rendering::BoxDrawingRasterizer boxes(face);
        const Ubiquitty::Rendering::CellMetrics metrics = boxes.cellMetrics();
        const int cellWidth = static_cast<int>(metrics.cellWidth + 0.5f);
        const int cellHeight = static_cast<int>(metrics.cellHeight + 0.5f);
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(boxes);
        if (!renderer.init())
            return skipNoGPUFrame("smoke-shade-gpu", "vulkan init failed");
        std::vector<uint8_t> gpu;
        int width = 0, height = 0;
        const bool didRender = renderer.renderGrid(app().rasterContext, term, gpu, width, height, 0, nullptr, nullptr);
        renderer.shutdown();
        if (!didRender)
            return skipNoGPUFrame("smoke-shade-gpu", "no GPU frame");
        if (width < columns * cellWidth || height < rows * cellHeight) {
            g_printerr("smoke-shade-gpu: frame %dx%d smaller than the %dx%d grid\n", width, height, columns * cellWidth, rows * cellHeight);
            return 1;
        }
        const auto pixelAt = [&](int x, int y) { return &gpu[(static_cast<std::size_t>(y) * width + x) * 4]; };
        // Column 0 is a space: the ground the unlit pixels must keep.
        const std::uint8_t* ground = pixelAt(1, 1);
        const auto isInked = [&](int x, int y) {
            const std::uint8_t* pixel = pixelAt(x, y);
            return pixel[0] != ground[0] || pixel[1] != ground[1] || pixel[2] != ground[2];
        };
        const int phase = Ubiquitty::Rendering::shadePhase(0, 0);
        for (int shade = 0; shade < 3; ++shade) {
            const int lit = shade + 1;
            const int top = shade * 2 * cellHeight;
            const int bottom = top + 2 * cellHeight;
            int mismatches = 0;
            int emptyRun = 0;
            int widestEmptyRun = 0;
            for (int x = cellWidth; x < 7 * cellWidth; ++x) {
                bool isColumnInked = false;
                for (int y = top; y < bottom; ++y) {
                    const bool isPixelInked = isInked(x, y);
                    isColumnInked |= isPixelInked;
                    mismatches += isPixelInked != Ubiquitty::Rendering::isShadePixelLit(x, y, lit, phase) ? 1 : 0;
                }
                emptyRun = isColumnInked ? 0 : emptyRun + 1;
                widestEmptyRun = std::max(widestEmptyRun, emptyRun);
            }
            const int allowedEmptyRun = lit == 1 ? 1 : 0;
            const bool isSeamless = mismatches == 0 && widestEmptyRun <= allowedEmptyRun;
            didPass &= isSeamless;
            Ubiquitty::PAL::logLine(stdout, "smoke-shade-gpu: cell {}x{} U+{:04X} field mismatches={} widest background run={} -- {}",
                cellWidth, cellHeight, 0x2591 + shade, mismatches, widestEmptyRun, isSeamless ? "PASS" : "FAIL");
        }
    }
    return didPass ? 0 : 1;
}
