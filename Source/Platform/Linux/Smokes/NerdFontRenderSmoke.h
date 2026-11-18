// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks that wide icon ink extends beyond its cell on both renderers.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeNerdFontRender()
{
    setupFonts();
    Ubiquitty::Rendering::GlyphRasterizer& rasteriser = currentRasterizer();
    const Ubiquitty::Rendering::CellMetrics metrics = rasteriser.cellMetrics();
    const int cellWidth = static_cast<int>(metrics.cellWidth);
    const int cellHeight = static_cast<int>(metrics.cellHeight);
    const int glyphCol = 3; // 0-based; the icon's cell

    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-nf-render: no term\n");
        return 1;
    }
    const char canned[] = "   \xef\x80\x95   \r\n"; // 3 spaces, U+F015, spaces, newline
    Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasteriser);
    if (!renderer.init())
        return skipNoGPUFrame("smoke-nf-render", "vulkan init failed");
    std::vector<uint8_t> cpu;
    std::vector<uint8_t> gpu;
    int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
    const bool didRasterizeCPU = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
    renderer.shutdown();
    const bool didCompareGPU = didRasterizeCPU && didRenderGPUFrame;
    const bool same = !didCompareGPU || (cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu);
    g_print("smoke-nf-render: CPU==GPU %s (%dx%d)\n", oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)), cpuWidth, cpuHeight);
    if (didRasterizeCPU) {
        const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(cpu, { cpuWidth, cpuHeight });
        FILE* f = std::fopen("/tmp/nf_render.png", "wb");
        if (f) {
            std::fwrite(png.data(), 1, png.size(), f);
            std::fclose(f);
            g_print("smoke-nf-render: wrote /tmp/nf_render.png\n");
        }
    }
    if (!didRasterizeCPU)
        return 1;

    // The only ink in row 0 is the icon (spaces are blank, the cursor is on row 1).
    // Find its horizontal extent vs its own cell [glyphCol*cellWidth, (glyphCol+1)*cellWidth):
    // ink reaching outside it means the overflow pass un-clipped the glyph.
    const std::uint8_t backgroundRed = cpu[0], backgroundGreen = cpu[1], backgroundBlue = cpu[2];
    int minX = cpuWidth;
    int maxX = -1;
    for (int y = 0; y < cellHeight; ++y)
        for (int x = 0; x < cpuWidth; ++x) {
            const std::size_t o = (static_cast<std::size_t>(y) * cpuWidth + x) * 4;
            if (cpu[o] != backgroundRed || cpu[o + 1] != backgroundGreen || cpu[o + 2] != backgroundBlue) {
                minX = std::min(minX, x);
                maxX = std::max(maxX, x);
            }
        }
    const int cellLeft = glyphCol * cellWidth;
    const int cellRight = (glyphCol + 1) * cellWidth;
    const bool doesOverflow = maxX >= 0 && (minX < cellLeft || maxX >= cellRight);
    // The verdict is printed as well as returned. It was in the exit code alone,
    // and the line above reads the same whether the run proved what it set out to
    // or not: "OVERFLOWS cell" is the PASSING reading here, which is the opposite
    // of how it scans.
    const bool didPass = same && doesOverflow;
    Ubiquitty::PAL::logLine(stdout, "smoke-nf-render: ink[{}..{}] cell[{}..{}] cellWidth={} — {} -- {}",
        minX, maxX, cellLeft, cellRight, cellWidth,
        doesOverflow ? "reaches outside its cell (un-clipped)" : "clipped to its cell",
        didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
