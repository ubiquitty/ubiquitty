// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-proportional-strip — a proportional run (Docs/proportional-text.md)
// shapes in fontconfig's sans-serif face through the Core strip sheet: the
// measurement answers, the strip draws ink inside its clip, a repeat hits the
// slot it drew, and an overflowing run is cut at its cells. What this image
// resolves `sans-serif` to is fontconfig's business — a proportional face
// where one is installed, the bundled mono face where not — so the smoke
// asserts the mechanism and not the metrics.
/// Checks proportional-strip measurement, slot reuse and clipping.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeProportionalStrip()
{
    setupFonts();
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-proportional-strip: FAILED — no bundled primary face beside the binary\n");
        return 1;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready() || !bundled.canShapeText()) {
        g_printerr("smoke-proportional-strip: FAILED — the bundled face did not load a shaper\n");
        return 1;
    }
    const int cellWidth = static_cast<int>(bundled.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(bundled.cellMetrics().cellHeight);
    Ubiquitty::Rendering::LigatureSheet sheet(cellWidth, cellHeight, 2, 2, &bundled);
    if (!sheet.isUsable()) {
        g_printerr("smoke-proportional-strip: FAILED — the sheet reports itself unusable\n");
        return 1;
    }
    if (!sheet.hasProportionalFace()) {
        g_printerr("smoke-proportional-strip: FAILED — fontconfig resolved no sans-serif face\n");
        return 1;
    }
    int failures = 0;

    const std::uint32_t label[] = { 'R', 'e', 'm', 'i', 'n', 'd', ' ', 'm', 'e' };
    const std::span<const std::uint32_t> text(label);
    const int cells = sheet.proportionalRunCells(text, static_cast<float>(cellWidth));
    g_print("  \"Remind me\" measures %d cell(s) at a %dpx cell\n", cells, cellWidth);
    if (cells < 1) {
        g_printerr("smoke-proportional-strip: FAILED — the measurement answered %d\n", cells);
        ++failures;
    }

    sheet.beginFrame();
    const auto placement = sheet.proportionalStrip(text, cells + 2, 1, 0.0f, static_cast<float>(cellWidth),
        Ubiquitty::Rendering::FontFace::Regular, 0u);
    if (!placement.strip.present) {
        g_printerr("smoke-proportional-strip: FAILED — the strip is absent\n");
        return 1;
    }
    g_print("  strip %.0f px wide, quad from %.0f px past the pen\n",
        static_cast<double>(placement.widthInPixels), static_cast<double>(placement.leftInPixels));
    if (placement.widthInPixels <= 0.0f || placement.widthInPixels > static_cast<float>(sheet.slotWidthInPixels())) {
        g_printerr("smoke-proportional-strip: FAILED — the strip's width is outside its slot\n");
        ++failures;
    }
    // Right-aligned in two cells more than it needs, the quad moves right.
    if (placement.leftInPixels < 0.0f) {
        g_printerr("smoke-proportional-strip: FAILED — a right-aligned run with slack did not move right (%.0f)\n",
            static_cast<double>(placement.leftInPixels));
        ++failures;
    }
    std::size_t isPixelInked = 0;
    for (std::uint8_t coverage : sheet.coverage())
        isPixelInked += coverage != 0 ? 1 : 0;
    g_print("  %zu inked px across the sheet\n", isPixelInked);
    if (isPixelInked == 0) {
        g_printerr("smoke-proportional-strip: FAILED — the sheet holds no ink\n");
        ++failures;
    }
    // The same run again is the same slot, drawn once.
    sheet.clearDirty();
    const auto repeat = sheet.proportionalStrip(text, cells + 2, 1, 0.0f, static_cast<float>(cellWidth),
        Ubiquitty::Rendering::FontFace::Regular, 0u);
    if (!repeat.strip.present || repeat.strip.minUV.x != placement.strip.minUV.x || repeat.strip.minUV.y != placement.strip.minUV.y
        || sheet.isDirty()) {
        g_printerr("smoke-proportional-strip: FAILED — a repeated run did not hit its slot\n");
        ++failures;
    }
    // Overflow: one cell cannot hold the label, so the strip ends at that
    // cell — no margin — and the ink stays inside it.
    const auto cut = sheet.proportionalStrip(text, 1, 0, 0.0f, static_cast<float>(cellWidth),
        Ubiquitty::Rendering::FontFace::Regular, 0u);
    const float cutWidth = static_cast<float>(std::ceil(2 + cellWidth)) + 2.0f;
    if (!cut.strip.present || cut.widthInPixels != cutWidth) {
        g_printerr("smoke-proportional-strip: FAILED — an overflowing run's strip is %.0f px, not %.0f\n",
            static_cast<double>(cut.widthInPixels), static_cast<double>(cutWidth));
        ++failures;
    }
    if (cut.strip.present) {
        // Every texel of the cut strip's slot right of the clip is clear.
        const int slotColumn = static_cast<int>(cut.strip.minUV.x);
        const int slotRow = static_cast<int>(cut.strip.minUV.y);
        std::size_t spilled = 0;
        for (int y = 0; y < sheet.slotHeightInPixels(); ++y) {
            for (int x = 2 + cellWidth; x < sheet.slotWidthInPixels(); ++x) {
                const std::size_t index = static_cast<std::size_t>(slotRow + y) * static_cast<std::size_t>(sheet.widthInPixels())
                    + static_cast<std::size_t>(slotColumn + x);
                spilled += sheet.coverage()[index] != 0 ? 1 : 0;
            }
        }
        if (spilled != 0) {
            g_printerr("smoke-proportional-strip: FAILED — %zu texel(s) of an overflowing run reached past its cell\n", spilled);
            ++failures;
        }
    }

    if (failures) {
        g_printerr("smoke-proportional-strip: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-proportional-strip: PASS (measured, drawn with ink, cached on repeat, cut at the cell on overflow)\n");
    return 0;
}
