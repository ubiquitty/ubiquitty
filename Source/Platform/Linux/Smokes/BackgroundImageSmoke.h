// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-background-image — the window's background image on both render
// paths. A gradient with translucent texels, under a theme at opacity 0.85, in
// every placement mode and at an image opacity below one: each frame is
// rendered by the CPU raster and by the Vulkan pass and the two must be the same
// bytes, and the image must show — a blank background pixel's alpha rises past
// the theme's.
/// Compares translucent background-image placement across software and Vulkan rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeBackgroundImage()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-background-image: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "backdrop");
    // 37 x 23, so neither axis divides the frame and every mode samples
    // between texels; the corner column is translucent.
    Ubiquitty::Rendering::BackgroundImagePixels gradient;
    gradient.width = 37;
    gradient.height = 23;
    gradient.rgba.resize(static_cast<std::size_t>(gradient.width) * gradient.height * 4);
    for (int y = 0; y < gradient.height; ++y) {
        for (int x = 0; x < gradient.width; ++x) {
            const std::size_t offset = (static_cast<std::size_t>(y) * gradient.width + x) * 4;
            gradient.rgba[offset] = static_cast<std::uint8_t>(x * 7);
            gradient.rgba[offset + 1] = static_cast<std::uint8_t>(y * 11);
            gradient.rgba[offset + 2] = static_cast<std::uint8_t>((x + y) * 4);
            gradient.rgba[offset + 3] = x == 0 ? 96 : 255;
        }
    }

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    const bool hasGPU = renderer.init();
    bool didEveryModeMatch = true;
    bool didImageShow = true;
    for (const char* mode : { "fill", "fit", "stretch", "tile", "center" }) {
        const std::string document = std::string("[appearance]\nbackground_opacity = 0.85\nbackground_image = \"/smoke\"\n")
            + "background_image_opacity = 0.6\nbackground_image_mode = \"" + mode + "\"\n";
        (void)Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict);
        app().rasterContext.setRenderConfiguration(Ubiquitty::Preferences::Effective::renderConfiguration(Ubiquitty::Preferences::values()));
        // After the configure, whose subscriber loads the named path and finds
        // nothing there: the smoke's image stands in for the file.
        app().rasterContext.setBackgroundImage(gradient);
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool didRasterizeCPUFrame = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, nullptr);
        const bool didRenderGPUFrame = hasGPU && renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, nullptr);
        const bool didCompareGPU = didRasterizeCPUFrame && didRenderGPUFrame;
        const bool same = didCompareGPU && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu;
        std::size_t differing = 0;
        if (didCompareGPU && cpu.size() == gpu.size()) {
            for (std::size_t index = 0; index < cpu.size(); index += 4) {
                if (cpu[index] == gpu[index] && cpu[index + 1] == gpu[index + 1] && cpu[index + 2] == gpu[index + 2] && cpu[index + 3] == gpu[index + 3])
                    continue;
                // The first few, so a disagreement names where and by how much.
                if (differing < 3) {
                    const std::size_t pixel = index / 4;
                    g_printerr("smoke-background-image: %s (%zu,%zu) CPU %d,%d,%d,%d GPU %d,%d,%d,%d\n", mode,
                        pixel % static_cast<std::size_t>(cpuWidth), pixel / static_cast<std::size_t>(cpuWidth),
                        cpu[index], cpu[index + 1], cpu[index + 2], cpu[index + 3], gpu[index], gpu[index + 1], gpu[index + 2], gpu[index + 3]);
                }
                ++differing;
            }
        }
        int backgroundAlpha = -1;
        if (didRasterizeCPUFrame && cpuWidth > 0 && cpuHeight > 0) {
            const std::size_t middle = (static_cast<std::size_t>(cpuHeight / 2) * cpuWidth + cpuWidth / 2) * 4;
            backgroundAlpha = cpu[middle + 3];
        }
        // 0.85 alone is 217; the image adds 0.6 of the 0.15 left open.
        const bool shows = backgroundAlpha > 230;
        if (hasGPU && !didRenderGPUFrame)
            g_printerr("smoke-background-image: FAIL: '%s' rendered no GPU frame, on a device that initialised\n", mode);
        g_print("smoke-background-image: %-7s CPU==GPU %s (%zu px differ) bg-alpha=%d\n", mode,
            oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (same ? OracleOutcome::Matched : OracleOutcome::Differed)), differing, backgroundAlpha);
        didEveryModeMatch = didEveryModeMatch && (same || !hasGPU);
        didImageShow = didImageShow && shows;
    }
    if (hasGPU)
        renderer.shutdown();
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);
    const bool didPass = didEveryModeMatch && didImageShow;
    g_print("smoke-background-image: %s\n", didPass ? "PASS" : "FAIL");
    if (!hasGPU && didImageShow)
        return skipNoGPUFrame("smoke-background-image", "vulkan init failed");
    return didPass ? 0 : 1;
}
