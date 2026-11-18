// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks glyph-prefix tracking across cache updates.
///
/// - Returns: Whether every check passed.
bool smokeTrackedGlyphPrefixes()
{
    const auto bundledPath = bundledFontPathForFamily("JetBrains Mono");
    bool didPass = true;
    for (const int tracking : { -3, 3 }) {
        Ubiquitty::Linux::FreeTypeRasterizer rasterizer(deviceFontPixelSize(), "JetBrains Mono", std::string(), std::string(),
            bundledPath, app().scale, app().lineSpacingPixels, tracking);
        Ubiquitty::Linux::RasterContext context;
        context.setRenderConfiguration(app().rasterContext.renderConfiguration());
        context.setDeviceScale(app().scale);
        context.setGlyphRasterizer(rasterizer);
        Ubiquitty::Linux::VulkanRenderer renderer;
        renderer.setGlyphRasterizer(rasterizer);
        renderer.setLigatureRasterizer(rasterizer);
        if (!rasterizer.ready() || !renderer.init()) {
            g_print("smoke-cursor: tracked-prefix tracking=%d unavailable -- FAIL\n", tracking);
            renderer.shutdown();
            return false;
        }
        const bool isStable = smokeGlyphPrefixStability(renderer, context);
        g_print("smoke-cursor: tracked-prefix tracking=%d -- %s\n", tracking, isStable ? "PASS" : "FAIL");
        didPass = didPass && isStable;
        renderer.shutdown();
    }
    return didPass;
}
