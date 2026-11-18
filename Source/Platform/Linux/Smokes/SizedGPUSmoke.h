// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-nf-render — render a lone wide Nerd-Font icon and PROVE the overflow
// pass un-clipped it: its ink must reach OUTSIDE its own cell (into the neighbour
// columns), and the CPU + GPU renders must be byte-identical. Renders a row with
// one icon (fa-home, U+F015 — smoke-nf measured ink width 16 in a 10px cell) at a known
// column surrounded by spaces, with a newline after so the cursor block lands on
// the NEXT row (out of the scanned band).
// --smoke-sized-gpu — OSC 66 sized text drawn by the Vulkan pipeline is the
// picture the CPU rasteriser draws. Both arms take the builder's sharp sized
// windows from their glyph backend; a backend that offers none falls back to the
// cell raster magnified over the block, which differs from the sharp windows in
// every edge pixel, so the byte comparison is the sharpness check. Whole scales
// and an n/d fraction are both on the screen, because they ask for different
// rasters, and so are one-cell and two-cell glyphs, because they are cut on
// different pages. Skips, by name, where no FreeType face is configured: Unifont is a
// bitmap, and both arms correctly magnify it.
/// Compares sized-text geometry across software and Vulkan rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeSizedGPU()
{
    // A face that draws CJK from outlines: the primary's own fallback chain
    // ends in Unifont, whose two-cell glyphs are bitmaps on every arm, and a
    // bitmap shows nothing about whether a window was cut from a raster drawn
    // at the block's size.
    constexpr std::string_view configuration = "[font]\nfamily = \"Noto Sans Mono CJK JP\"\nsize = 12\n";
    if (!Ubiquitty::Preferences::configure(std::string(configuration), Ubiquitty::Preferences::ParseMode::Strict).isApplied) {
        g_printerr("smoke-sized-gpu: configuration failed\n");
        return 1;
    }
    setupFonts();
    Ubiquitty::Rendering::GlyphRasterizer& rasteriser = currentRasterizer();
    if (!rasteriser.rasterisesScaledGlyphsSharply()) {
        g_print("smoke-sized-gpu: SKIPPED — the configured face is a bitmap, so a sized glyph is the magnified cell on every arm\n");
        return 0;
    }
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-sized-gpu: no term\n");
        return 1;
    }
    term->drawsSizedText = true;
    Ubiquitty::processBytes(term, "\x1b[?25l\x1b]66;s=2;Hg\x07 \x1b]66;s=3;E\x07 \x1b]66;s=3:n=1:d=2;A\x07 \x1b]66;s=2:n=3:d=4:v=2:h=2;b\x07\r\n");
    // Two-cell glyphs, whose windows are two cells wide on both arms' wide pages.
    Ubiquitty::processBytes(term, "\r\n\r\n\x1b]66;s=2;\xe6\x9d\xb1\x07 \x1b]66;s=3;\xe6\x9d\xb1\x07 \x1b]66;s=3:n=1:d=2;\xe6\x9d\xb1\x07\r\n");

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(rasteriser);
    if (!renderer.init())
        return skipNoGPUFrame("smoke-sized-gpu", "vulkan init failed");
    std::vector<uint8_t> cpu;
    std::vector<uint8_t> gpu;
    int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
    const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
    renderer.shutdown();
    if (!didRenderCPUFrame) {
        g_printerr("smoke-sized-gpu: the CPU arm drew nothing\n");
        return 1;
    }
    if (!didRenderGPUFrame)
        return skipNoGPUFrame("smoke-sized-gpu", "no GPU frame");
    // The fractional two-cell block, columns 12-17 of rows 3-5, draws the 1x
    // wide raster mapped into its smaller area — a scaled quad both arms
    // sample bilinearly from sheets laid out differently, so its interior may
    // differ by a unit of coverage, as `--smoke-script-glyphs`' scaled scripts
    // do. What the block must agree on is where it is drawn: the same ink box
    // on both arms. Every other pixel of the frame must be identical.
    const Ubiquitty::Rendering::CellMetrics metrics = rasteriser.cellMetrics();
    const int blockLeft = static_cast<int>(std::lround(12.0f * metrics.cellWidth));
    const int blockRight = static_cast<int>(std::lround(18.0f * metrics.cellWidth));
    const int blockTop = static_cast<int>(std::lround(3.0f * metrics.cellHeight));
    const int blockBottom = static_cast<int>(std::lround(6.0f * metrics.cellHeight));
    const bool isSameSize = cpuWidth == gpuWidth && cpuHeight == gpuHeight;
    struct InkBox {
        int left = INT_MAX;
        int top = INT_MAX;
        int right = -1;
        int bottom = -1;
        bool operator==(const InkBox&) const = default;
    };
    InkBox cpuBlockInk;
    InkBox gpuBlockInk;
    int differingPixels = 0;
    int differingBlockPixels = 0;
    const auto widen = [](InkBox& box, int x, int y) {
        box.left = std::min(box.left, x);
        box.top = std::min(box.top, y);
        box.right = std::max(box.right, x);
        box.bottom = std::max(box.bottom, y);
    };
    for (int y = 0; isSameSize && y < cpuHeight; ++y) {
        for (int x = 0; x < cpuWidth; ++x) {
            const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(cpuWidth) + static_cast<std::size_t>(x)) * 4;
            const bool isInBlock = x >= blockLeft && x < blockRight && y >= blockTop && y < blockBottom;
            const bool differs = std::memcmp(cpu.data() + offset, gpu.data() + offset, 4) != 0;
            if (!isInBlock) {
                differingPixels += differs ? 1 : 0;
                continue;
            }
            differingBlockPixels += differs ? 1 : 0;
            if (std::memcmp(cpu.data() + offset, cpu.data(), 4) != 0)
                widen(cpuBlockInk, x, y);
            if (std::memcmp(gpu.data() + offset, gpu.data(), 4) != 0)
                widen(gpuBlockInk, x, y);
        }
    }
    const bool didPass = isSameSize && differingPixels == 0 && cpuBlockInk == gpuBlockInk && cpuBlockInk.right >= 0;
    if (!didPass) {
        for (const auto& [label, rgba] : { std::pair<const char*, const std::vector<uint8_t>&>("cpu", cpu), { "gpu", gpu } }) {
            const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { label == std::string_view("cpu") ? cpuWidth : gpuWidth, label == std::string_view("cpu") ? cpuHeight : gpuHeight });
            const std::string path = std::string("/tmp/sized_gpu_") + label + ".png";
            if (FILE* file = std::fopen(path.c_str(), "wb")) {
                std::fwrite(png.data(), 1, png.size(), file);
                std::fclose(file);
                g_print("smoke-sized-gpu: wrote %s\n", path.c_str());
            }
        }
    }
    Ubiquitty::PAL::logLine(stdout, "smoke-sized-gpu: fractional wide block ink CPU [{},{}..{},{}] GPU [{},{}..{},{}], {} interior pixel(s) differ",
        cpuBlockInk.left, cpuBlockInk.top, cpuBlockInk.right, cpuBlockInk.bottom,
        gpuBlockInk.left, gpuBlockInk.top, gpuBlockInk.right, gpuBlockInk.bottom, differingBlockPixels);
    Ubiquitty::PAL::logLine(stdout, "smoke-sized-gpu: CPU {}x{} GPU {}x{}, {} pixel(s) differ outside it -- {}",
        cpuWidth, cpuHeight, gpuWidth, gpuHeight, differingPixels, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
