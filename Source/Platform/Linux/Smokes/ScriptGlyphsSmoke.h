// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Scripted native glyphs shrink their quads while retaining the whole source
// rect. The software oracle checks both axes, and the bitmap arm requires its
// fixed raster geometry to stay unchanged.
/// Compares scripted native glyph geometry with the software oracle.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeScriptGlyphs()
{
    setupFonts();
    activePane()->session->start(6, 24);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-script-glyphs: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer nativeRasterizer(16, "JetBrains Mono",
        std::string(), std::string(), bundledPath, 1, 0);
    Ubiquitty::Rendering::UnifontRasterizer bitmapRasterizer(1, 0);
    if (!nativeRasterizer.ready()) {
        g_printerr("smoke-script-glyphs: no native face\n");
        return 1;
    }
    int failures = 0;
    for (int arm = 0; arm < 2; ++arm) {
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
            g_printerr("smoke-script-glyphs: Vulkan init failed\n");
            return 1;
        }
        for (const int script : { 73, 74 }) {
            Ubiquitty::hardReset(*term);
            Ubiquitty::resize(*term, 6, 24);
            const std::string content = "\x1b[?25lplain WgM8\x1b[3;2H\x1b[38;2;237;157;43m\x1b["
                + std::to_string(script) + "mWgM8\x1b[5;2H漢界\x1b[75m\x1b[39m";
            Ubiquitty::processBytes(term, content);

            std::vector<std::uint8_t> gpu;
            int gpuWidth = 0;
            int gpuHeight = 0;
            const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight);
            const std::uint32_t scaledInstances = renderer.lastFrameScaledGlyphInstanceCount();
            std::vector<std::uint8_t> cpu;
            int cpuWidth = 0;
            int cpuHeight = 0;
            const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight);
            const bool hasMatchingDimensions = didRenderGPUFrame && didRenderCPUFrame
                && gpuWidth == cpuWidth && gpuHeight == cpuHeight && gpu.size() == cpu.size();
            std::size_t differingPixels = 0;
            std::size_t scriptedInkPixels = 0;
            if (hasMatchingDimensions && !cpu.empty()) {
                const std::uint8_t* background = cpu.data() + cpu.size() - 4;
                for (std::size_t index = 0; index < cpu.size(); index += 4) {
                    const bool isDiffering = std::memcmp(cpu.data() + index, gpu.data() + index, 4) != 0;
                    // The first few differing pixels by position and both colours, so
                    // a failure names the arm that departs rather than a count.
                    if (isDiffering && differingPixels < 4) {
                        const std::size_t pixel = index / 4;
                        g_print("    differs at (%zu,%zu): cpu %u,%u,%u,%u gpu %u,%u,%u,%u\n", pixel % static_cast<std::size_t>(cpuWidth), pixel / static_cast<std::size_t>(cpuWidth),
                            cpu[index], cpu[index + 1], cpu[index + 2], cpu[index + 3], gpu[index], gpu[index + 1], gpu[index + 2], gpu[index + 3]);
                    }
                    differingPixels += isDiffering;
                    if (index >= cpu.size() / 6) {
                        scriptedInkPixels += std::memcmp(cpu.data() + index, background, 3) != 0;
                    }
                }
            }
            const bool hasExpectedGeometry = arm == 0 ? scaledInstances > 0 : scaledInstances == 0;
            const bool didPass = hasMatchingDimensions && differingPixels == 0
                && hasExpectedGeometry && scriptedInkPixels > 0;
            failures += !didPass;
            g_print("  %s SGR%d scaled=%u scripted-ink=%zu differing=%zu %s\n", armName, script,
                scaledInstances, scriptedInkPixels, differingPixels, didPass ? "PASS" : "FAIL");
        }
        renderer.shutdown();
        app().rasterContext.resetSoftwareRenderer();
    }
    app().rasterContext.setGlyphRasterizer(currentRasterizer());
    g_print("smoke-script-glyphs: %d failure(s) -- %s\n", failures, failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
