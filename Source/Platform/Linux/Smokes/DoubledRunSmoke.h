// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Mono and proportional text on double-width and double-height rows, through
// Vulkan and software rendering, held to byte equality. Each arm includes
// native and fixed-raster faces so scaling samples the complete source rect
// while retaining the rasterizer's filtering policy.
/// Compares double-width and double-height text across software and Vulkan rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeDoubledRun()
{
    setupFonts();
    activePane()->session->start(3, 32);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-doubled-run: no term\n");
        return 1;
    }
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    Ubiquitty::Linux::FreeTypeRasterizer nativeRasterizer(16, "JetBrains Mono",
        std::string(), std::string(), bundledPath, 1, 0);
    Ubiquitty::Rendering::UnifontRasterizer bitmapRasterizer(1, 0);
    if (!nativeRasterizer.ready() || !nativeRasterizer.hasProportionalFace()) {
        g_printerr("smoke-doubled-run: FAILED — no native proportional face\n");
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
            g_printerr("smoke-doubled-run: FAILED — Vulkan init failed\n");
            return 1;
        }
        Ubiquitty::resize(*term, 3, 32);
        struct RunScene {
            std::uint8_t alignment;
            std::uint8_t rowAttribute;
            bool isProportional;
        };
        for (const RunScene scene : { RunScene { 0, 6, true }, RunScene { 2, 6, true }, RunScene { 0, 3, true },
                 RunScene { 2, 3, true }, RunScene { 0, 6, false }, RunScene { 0, 3, false } }) {
            const std::uint8_t alignment = scene.alignment;
            Ubiquitty::hardReset(*term);
            Ubiquitty::resize(*term, 3, 32);
            Ubiquitty::processBytes(term, "\x1b[?25l");
            term->drawsSizedText = true;
            term->drawsProportionalText = true;
            const std::string run = scene.isProportional
                ? "\x1b[38;2;237;157;43m\x1b]66;p=1:c=8:h=" + std::to_string(alignment) + ";Wiggle jA\x07\x1b[39m"
                : "\x1b[38;2;237;157;43mWgM8 jA\x1b[39m";
            std::string content = "\x1b#" + std::to_string(scene.rowAttribute) + run;
            if (scene.rowAttribute == 3) {
                content += "\r\n\x1b#4" + run;
            }
            content += scene.isProportional ? "\r\nplain \x1b]66;p=1:c=8;Wiggle jA\x07 ok" : "\r\nplain WgM8 jA";
            Ubiquitty::processBytes(term, content);
            std::vector<std::uint8_t> gpu;
            int gpuWidth = 0;
            int gpuHeight = 0;
            const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight);
            const std::uint32_t glyphInstances = renderer.lastFrameProportionalInstanceCount();
            const std::uint32_t stripInstances = renderer.lastFrameProportionalStripInstanceCount();
            // Both dedicated glyphs and overlapping whole-run strips must
            // rasterize ink at the doubled size. Empty spaces can retain a
            // stretched quad; inspect actual atlas coverage so they cannot
            // conceal a letter falling back to a stretched native-size mask.
            const std::uint32_t stretchedInstances = renderer.lastFrameStretchedProportionalInstanceCount();
            const std::uint32_t stretchedInkInstances = renderer.lastFrameStretchedProportionalInstanceCount(Ubiquitty::Linux::VulkanRenderer::CoverageFilter::Inked);
            std::vector<std::uint8_t> cpu;
            int cpuWidth = 0;
            int cpuHeight = 0;
            const bool didRenderCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight);
            const bool hasMatchingDimensions = didRenderGPUFrame && didRenderCPUFrame
                && gpuWidth == cpuWidth && gpuHeight == cpuHeight && gpu.size() == cpu.size();
            std::size_t differingPixels = 0;
            std::size_t inkedPixelsOnTheDoubledRow = 0;
            if (hasMatchingDimensions) {
                const std::uint8_t* background = cpu.data() + cpu.size() - 4;
                for (std::size_t index = 0; index < cpu.size(); index += 4) {
                    differingPixels += std::memcmp(cpu.data() + index, gpu.data() + index, 4) != 0;
                    if (index < cpu.size() / 3)
                        inkedPixelsOnTheDoubledRow += std::memcmp(cpu.data() + index, background, 3) != 0;
                }
            }
            const bool hasExpectedPopulation = scene.isProportional
                ? glyphInstances + stripInstances > 0 && stretchedInkInstances == 0
                : glyphInstances == 0 && stripInstances == 0;
            const bool didPass = hasMatchingDimensions && differingPixels == 0
                && hasExpectedPopulation && inkedPixelsOnTheDoubledRow > 0;
            failures += !didPass;
            g_print("  %s %s row-attribute=%u h=%u glyphs=%u strips=%u stretched=%u stretched-ink=%u doubled-row-ink=%zu differing=%zu %s\n", armName,
                scene.isProportional ? "proportional" : "mono", static_cast<unsigned>(scene.rowAttribute), static_cast<unsigned>(alignment), glyphInstances, stripInstances, stretchedInstances,
                stretchedInkInstances, inkedPixelsOnTheDoubledRow, differingPixels, didPass ? "PASS" : "FAIL");
        }
        renderer.shutdown();
        app().rasterContext.resetSoftwareRenderer();
    }
    app().rasterContext.setGlyphRasterizer(currentRasterizer());
    g_print("smoke-doubled-run: %d failure(s) -- %s\n", failures, failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
