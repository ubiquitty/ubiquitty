// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-opacity — window background opacity. With opacity 0.5, asserts (1) a
// blank background pixel's alpha is ~128 (the background shows through behind opaque text)
// and (2) the screen renders byte-identically on the CPU + GPU at <1 opacity (the
// alpha is composited in the same integer domain as the colors — the oracle holds
// for translucent backgrounds too). The actual desktop see-through is a transparent
// GTK window over a compositor and is checked by hand.
/// Checks translucent background alpha and agreement between both renderers.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeOpacity()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-opacity: no term\n");
        return 1;
    }
    (void)Ubiquitty::Preferences::configure("[appearance]\nbackground_opacity = 0.5\n", Ubiquitty::Preferences::ParseMode::Strict);
    Ubiquitty::processBytes(term, "opacity"); // text on row 0; mid-screen stays blank background

    std::vector<uint8_t> cpuRGBA;
    int cpuWidth = 0, cpuHeight = 0;
    const bool didRasterizeCPU = app().rasterContext.rasterizeTerm(term, cpuRGBA, cpuWidth, cpuHeight, 0, nullptr, nullptr);

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-opacity", "vulkan init failed");
    std::vector<uint8_t> rgbaVk;
    int wVk = 0, hVk = 0;
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, rgbaVk, wVk, hVk, 0, nullptr, nullptr);
    renderer.shutdown();

    const bool didCompareGPU = didRasterizeCPU && didRenderGPUFrame;
    const bool isIdentical = !didCompareGPU || (cpuWidth == wVk && cpuHeight == hVk && cpuRGBA == rgbaVk);
    // A blank background pixel mid-screen (away from row 0's text): alpha ≈ 0.5*255.
    int backgroundAlpha = -1;
    if (didRasterizeCPU && cpuWidth > 0 && cpuHeight > 0) {
        const std::size_t mid = (static_cast<std::size_t>(cpuHeight / 2) * cpuWidth + cpuWidth / 2) * 4;
        backgroundAlpha = cpuRGBA[mid + 3];
    }
    const bool isAlphaCorrect = backgroundAlpha >= 126 && backgroundAlpha <= 130;
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict); // restore (defensive; smokes are separate processes)

    const bool didPass = isIdentical && isAlphaCorrect;
    g_print("smoke-opacity: CPU==GPU(@0.5)=%s bg-alpha=%d (want ~128) -- %s\n", oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (isIdentical ? OracleOutcome::Matched : OracleOutcome::Differed)), backgroundAlpha, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
