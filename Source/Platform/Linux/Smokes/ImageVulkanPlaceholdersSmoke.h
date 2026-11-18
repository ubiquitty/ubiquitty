// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-image-vk-placeholders — the oracle for kitty Unicode placeholders. A
// virtual placement (U=1) draws nothing by itself; each U+10EEEE cell shows the
// tile of the image its row and column marks name, with the image id in its
// foreground. Image 7 is a 2x2 grid of red, green, blue and yellow texels, and
// its 2x2 block of cells is printed twice. Both arms resolve the tiles from the
// cells the frame captured, so they must agree to the byte; the CPU frame must
// also show the red tile where the first block starts, or the two would agree
// about a frame with no picture in it.
/// Checks image-placeholder tiles and compares their software and Vulkan rendering.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeImageVulkanPlaceholders()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image-vk-placeholders: no term\n");
        return 1;
    }
    // FF0000 00FF00 / 0000FF FFFF00, transmitted and placed virtually.
    Ubiquitty::processBytes(term, "\x1b_Ga=T,U=1,i=7,f=24,s=2,v=2,c=2,r=2,q=2;/wAAAP8AAAD///8A\x1b\\");
    Ubiquitty::drainAsyncDecodes(*term);
    // U+10EEEE and its row then column mark: U+0305 is 0, U+030D is 1.
    const std::string topRow = "\xF4\x8E\xBB\xAE\xCC\x85\xCC\x85\xF4\x8E\xBB\xAE\xCC\x85\xCC\x8D";
    const std::string bottomRow = "\xF4\x8E\xBB\xAE\xCC\x8D\xCC\x85\xF4\x8E\xBB\xAE\xCC\x8D\xCC\x8D";
    Ubiquitty::processBytes(term, "\x1b[38;5;7m\x1b[2;3H" + topRow + "\x1b[3;3H" + bottomRow + "\x1b[2;9H" + topRow + "\x1b[3;9H" + bottomRow + "\x1b[0m");
    if (!Ubiquitty::Kitty::hasPlaceholders(term, 0)) {
        g_printerr("smoke-image-vk-placeholders: the cells did not land as placeholders\n");
        return 1;
    }

    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!app().rasterContext.rasterizeTerm(term, rgba, width, height, 0, nullptr, nullptr)) {
        g_printerr("smoke-image-vk-placeholders: CPU rasterize failed\n");
        return 1;
    }
    // The centre of the red tile, the image's top-left quarter, in the first
    // block, whose box starts at row 2, column 3. The square image is fitted
    // into its 2x2 box of cells with its aspect kept and centred on the axis
    // it does not fill, so in a cell that is not square the tile is off the
    // first cell's centre.
    const int cellWidth = app().rasterContext.cellWidth();
    const int cellHeight = app().rasterContext.cellHeight();
    const int imageSide = 2 * std::min(cellWidth, cellHeight);
    const int sampleX = 2 * cellWidth + (2 * cellWidth - imageSide) / 2 + imageSide / 4;
    const int sampleY = 1 * cellHeight + (2 * cellHeight - imageSide) / 2 + imageSide / 4;
    if (sampleX >= width || sampleY >= height) {
        g_printerr("smoke-image-vk-placeholders: the frame is smaller than the block\n");
        return 1;
    }
    const std::size_t at = (static_cast<std::size_t>(sampleY) * static_cast<std::size_t>(width) + static_cast<std::size_t>(sampleX)) * 4;
    if (!(rgba[at] > 200 && rgba[at + 1] < 60 && rgba[at + 2] < 60)) {
        g_printerr("smoke-image-vk-placeholders: FAIL: the first placeholder cell is rgb(%d,%d,%d), not the red tile\n",
            rgba[at], rgba[at + 1], rgba[at + 2]);
        return 1;
    }
    return compareImageOracle("smoke-image-vk-placeholders", term);
}
