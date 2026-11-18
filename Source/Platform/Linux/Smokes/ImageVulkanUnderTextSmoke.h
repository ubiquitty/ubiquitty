// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-image-vk-under-text — a picture placed at z<0 under the text on both
// arms. Each draws the cells' ground, then the picture, then the ink over it.
// The CPU frame is checked first: inside the picture's cells it must hold both
// the picture's red and pixels that are not red, which is the text reading on
// top. The GPU frame then has to match it to within one level a channel: the
// Vulkan arm blends that ink in the fixed-function unit, and a blender that
// rounds each product can land a partly covered pixel one level from the CPU's
// integer mix.
/// Checks that image pixels stay behind text on both renderers.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeImageVulkanUnderText()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk-under-text: no term\n");
        return 1;
    }
    constexpr int pictureColumns = 12;
    constexpr int pictureRows = 2;
    // One opaque red texel stretched over twelve cells of two rows, placed
    // without moving the cursor, then text printed over the same cells.
    Ubiquitty::processBytes(term, "\x1b[H\x1b_Ga=T,f=24,s=1,v=1,c=12,r=2,z=-1,C=1,q=2;/wAA\x1b\\");
    Ubiquitty::drainAsyncDecodes(*term);
    Ubiquitty::processBytes(term, "\x1b[1;1HText on red,\x1b[2;1Hstill legible");
    if (Ubiquitty::Image::placementCount(term) < 1) {
        g_printerr("smoke-image-vk-under-text: the picture did not produce a placement\n");
        return 1;
    }

    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!app().rasterContext.rasterizeTerm(term, rgba, width, height, 0, nullptr, nullptr)) {
        g_printerr("smoke-image-vk-under-text: CPU rasterize failed\n");
        return 1;
    }
    const int pictureWidth = std::min(pictureColumns * app().rasterContext.cellWidth(), width);
    const int pictureHeight = std::min(pictureRows * app().rasterContext.cellHeight(), height);
    std::size_t pictured = 0;
    std::size_t isPixelInked = 0;
    for (int y = 0; y < pictureHeight; ++y) {
        for (int x = 0; x < pictureWidth; ++x) {
            const std::size_t at = (static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)) * 4;
            if (rgba[at] == 255 && rgba[at + 1] == 0 && rgba[at + 2] == 0)
                ++pictured;
            else
                ++isPixelInked;
        }
    }
    g_print("smoke-image-vk-under-text: CPU picture cells hold %zu picture pixels and %zu ink pixels\n", pictured, isPixelInked);
    if (pictured == 0 || isPixelInked == 0) {
        g_printerr("smoke-image-vk-under-text: FAIL: the CPU frame does not show text over the picture\n");
        return 1;
    }
    return compareImageOracle("smoke-image-vk-under-text", term, /*toleratedChannelDelta=*/1);
}
