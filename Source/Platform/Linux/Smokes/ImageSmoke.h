// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-image — the inline-image draw path (Stage 11a, CPU half). Feeds a tiny
// solid-red DEC sixel at home, renders the screen via the CPU SoftwareRenderer to
// /tmp/image.png, then asserts the image region is RED (the sixel pixels) rather
// than the terminal background. Prints the resolved placement rect + a sampled
// pixel + PASS/FAIL. Leaves /tmp/image.png on disk.
/// Checks that software rendering displays the supplied sixel image.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeImage()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-image: no term\n");
        return 1;
    }

    // DEC sixel: P1;P2;P3 q  #1;2;100;0;0  (reg 1 = 100% red)  #1  !16~  ST.
    // #1 selects reg 1; "!16~" repeats the all-six-bits column 16 times, so the
    // image is 16px wide x 6px tall (one cell row) of solid red. P2=0 (opaque
    // background) so unpainted pixels would be color 0, but every pixel here is
    // painted red.
    const char sixel[] = "\x1bP0;0;0q#1;2;100;0;0#1!16~\x1b\\";
    Ubiquitty::processBytes(term, std::string_view(sixel, sizeof(sixel) - 1));

    // An image shorter than a cell leaves the cursor on the cell it was
    // placed from, and the block cursor draws over the over-text images. The
    // cursor is hidden so the sample reads the image the pass composited.
    Ubiquitty::processBytes(term, "\x1b[?25l");

    const int placements = Ubiquitty::Image::placementCount(term);
    const Ubiquitty::Image::TerminalImage* img = Ubiquitty::Image::stored(term, 0);
    if (placements < 1 || !img) {
        g_printerr("smoke-image: sixel did not produce a placement (count=%d)\n", placements);
        return 1;
    }
    g_print("smoke-image: decoded image %dx%d format=%u, placements=%d\n", static_cast<int>(img->width), static_cast<int>(img->height), static_cast<unsigned>(img->format), placements);

    // Resolve the placement to a device-pixel rect the same way the renderer
    // does (origin 0,0, scale 1, the runtime cell), for the report + the sample
    // location.
    const int cellWidth = app().rasterContext.cellWidth();
    const int cellHeight = app().rasterContext.cellHeight();
    Ubiquitty::Image::ImageQuad quad[Ubiquitty::Image::maxTerminalImagePlacementCount];
    const int resolved = Ubiquitty::Rendering::collectImageQuads(term, { static_cast<float>(cellWidth), static_cast<float>(cellHeight) }, { 0.0f, 0.0f }, 1.0f, 0, { quad, static_cast<std::size_t>(Ubiquitty::Image::maxTerminalImagePlacementCount) });
    if (resolved < 1) {
        g_printerr("smoke-image: resolveImagePlacements returned 0\n");
        return 1;
    }
    g_print("smoke-image: placement rect = [%.1f,%.1f .. %.1f,%.1f] (cell %dx%d)\n", quad[0].minXInPixels, quad[0].minYInPixels, quad[0].maxXInPixels, quad[0].maxYInPixels, cellWidth, cellHeight);

    // Render via the CPU path (no cursor override -> static block; the image is
    // composited last, over the grid).
    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!app().rasterContext.rasterizeTerm(term, rgba, width, height, 0, nullptr, nullptr)) {
        g_printerr("smoke-image: rasterize failed\n");
        return 1;
    }
    const std::vector<uint8_t> png = Ubiquitty::Rendering::encodePNG(rgba, { width, height });
    if (FILE* f = std::fopen("/tmp/image.png", "wb")) {
        std::fwrite(png.data(), 1, png.size(), f);
        std::fclose(f);
        g_print("smoke-image: wrote /tmp/image.png (%dx%d)\n", width, height);
    }

    // Sample a pixel near the center of the resolved rect — it must be red, not
    // the terminal background (default background is dark, R ~0x10). Red = R high, G/B low.
    const int sampleX = static_cast<int>((quad[0].minXInPixels + quad[0].maxXInPixels) * 0.5f);
    const int sampleY = static_cast<int>((quad[0].minYInPixels + quad[0].maxYInPixels) * 0.5f);
    const std::size_t o = (static_cast<std::size_t>(sampleY) * width + sampleX) * 4;
    const int sr = rgba[o], sg = rgba[o + 1], sb = rgba[o + 2], sa = rgba[o + 3];
    g_print("smoke-image: sampled (%d,%d) = rgba(%d,%d,%d,%d)\n", sampleX, sampleY, sr, sg, sb, sa);

    const bool isRed = sr > 200 && sg < 60 && sb < 60 && sa == 255;
    g_print("smoke-image: %s\n", isRed ? "PASS" : "FAIL");
    return isRed ? 0 : 1;
}
