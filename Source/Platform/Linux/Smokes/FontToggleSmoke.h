// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Self-test the runtime font swap on the GPU path: render the canned screen with
// FreeType, then re-inject Unifont + rebuildAtlas() and render again, asserting
// both renders succeed and the cell geometry actually changes. Exercises
// VulkanRenderer::rebuildAtlas — the live Unifont↔FreeType toggle — headlessly.
/// Checks rendering and cell geometry after switching from FreeType to Unifont.
///
/// - Returns: Zero on success, or a nonzero failure status.
int selftestFontToggle()
{
    initTermCanned();
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("selftest-font-toggle: no term\n");
        return 1;
    }
    setupFonts();
    if (app().fontRasterizerKind == Ubiquitty::Rendering::FontRasterizerKind::EmbeddedBitmap || !app().glyphRasterizer || !app().glyphRasterizer->ready()) {
        g_printerr("selftest-font-toggle: FreeType unavailable; cannot test the swap\n");
        return 1;
    }
    Ubiquitty::Linux::VulkanRenderer renderer;
    renderer.setGlyphRasterizer(*app().glyphRasterizer); // start on FreeType
    if (!renderer.init())
        return skipNoGPUFrame("selftest-font-toggle", "vulkan init failed");
    std::vector<uint8_t> rgba;
    int ftWidth = 0, ftHeight = 0;
    const bool didDrawFreeType = renderer.renderGrid(app().rasterContext, term, rgba, ftWidth, ftHeight);

    // Swap to Unifont at runtime (the same sequence applyFontMode runs on app().vulkan):
    // re-inject, rebuild the atlas, render again.
    renderer.setGlyphRasterizer(*app().unifontRasterizer);
    renderer.rebuildAtlas();
    int uniWidth = 0, uniHeight = 0;
    const bool didDrawUnifont = renderer.renderGrid(app().rasterContext, term, rgba, uniWidth, uniHeight);
    renderer.shutdown();

    g_print("selftest-font-toggle: freetype %dx%d (ok=%d) -> unifont %dx%d (ok=%d)\n", ftWidth, ftHeight, didDrawFreeType, uniWidth, uniHeight, didDrawUnifont);
    if (!didDrawFreeType || !didDrawUnifont) {
        g_printerr("selftest-font-toggle: FAIL (a renderGrid failed)\n");
        return 1;
    }
    if (ftWidth == uniWidth && ftHeight == uniHeight) {
        g_printerr("selftest-font-toggle: FAIL (cell geometry unchanged across the swap)\n");
        return 1;
    }
    g_print("selftest-font-toggle: PASS\n");
    return 0;
}
