// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-weight — SGR 1:n variable font weight. Asserts (1) the Core parses 1:5
// into the cell's extendedAttributes weight bits, and (2) the builder threads that weight to
// the glyph atlas so a weighted run renders byte-identically on the CPU + GPU (the
// oracle holds for weighted text — a different atlas glyph, sampled the same by
// both). The visible weight change needs a variable font + is checked by hand; this
// pins the parse + the CPU<->GPU path that were the Linux gap (builder hardcoded 0).
/// Checks variable font-weight parsing and rendering on both backends.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeWeight()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-weight: no term\n");
        return 1;
    }
    // SGR 1:5 selects variable weight 5, then a short run; SGR 0 resets.
    const char feed[] = "\x1b[1:5mWWWW\x1b[0m";
    Ubiquitty::processBytes(term, std::string_view(feed, sizeof(feed) - 1));

    const Ubiquitty::Cell* cell = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const unsigned parsedWeight = cell != nullptr ? static_cast<unsigned>(Ubiquitty::cellPen(*cell).extendedAttributes.weight()) : 0u;
    const bool didParseWeight = parsedWeight == 5;

    std::vector<uint8_t> cpuRGBA;
    int cpuWidth = 0, cpuHeight = 0;
    const bool didRasterizeCPU = app().rasterContext.rasterizeTerm(term, cpuRGBA, cpuWidth, cpuHeight, 0, nullptr, nullptr);

    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(currentRasterizer());
    renderer.setLigatureRasterizer(currentRasterizer());
    if (!renderer.init())
        return skipNoGPUFrame("smoke-weight", "vulkan init failed");
    std::vector<uint8_t> rgbaVk;
    int wVk = 0, hVk = 0;
    const bool didRenderGPUFrame = renderer.renderGrid(app().rasterContext, term, rgbaVk, wVk, hVk, 0, nullptr, nullptr);
    renderer.shutdown();

    const bool didCompareGPU = didRasterizeCPU && didRenderGPUFrame;
    const bool isIdentical = !didCompareGPU || (cpuWidth == wVk && cpuHeight == hVk && cpuRGBA == rgbaVk);
    const bool didPass = didParseWeight && isIdentical;
    g_print("smoke-weight: parsed-weight=%u (want 5) CPU==GPU(weighted run)=%s -- %s\n", parsedWeight, oracleLabel(!didCompareGPU ? OracleOutcome::NotCompared : (isIdentical ? OracleOutcome::Matched : OracleOutcome::Differed)), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
