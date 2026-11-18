// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-atlas-capacity — the atlas is cut for the screen it serves.
//
// A glyph the atlas has no slot for draws as bare background, so running out is
// a missing character rather than a slow frame -- and the CPU renderer has no
// atlas to run out of, so the two backends disagree about what is on screen. A
// fixed thousand slots is under one screenful of a large window: 200x50 is
// 10000 cells, and a screenful of CJK prose or a mixed-script editor reaches
// that many distinct glyphs without trying.
//
// Headless: the sizing is decided in the constructor from the cell metrics and
// the texture limit, so no device is needed to ask what it decided.
/// Checks atlas sizing against the number of cells in a large viewport.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeAtlasCapacity()
{
    bool ok = true;
    auto check = [&](bool didHold, std::string_view what) {
        if (!didHold) {
            Ubiquitty::PAL::logLine(stderr, "smoke-atlas-capacity: FAIL: {}", what);
            ok = false;
        }
    };

    // A device limit large enough that the grid, not the clamp, is what this
    // measures. The clamp has its own coverage; what is checked here is the
    // request reaching it.
    constexpr int textureLimit = 16384;
    Ubiquitty::Rendering::UnifontRasterizer rasterizer;

    Ubiquitty::Linux::VulkanGlyphAtlas unmeasured(8, 16, rasterizer, textureLimit, /*cellsInWidestScreen=*/0);
    const int floorCapacity = unmeasured.bindMonoAtlas().slotCapacity;
    check(floorCapacity > 0, "an atlas with no screen measurement still has slots");

    // An ordinary large window, whose cells a fixed thousand slots cannot hold.
    constexpr int wideScreenCells = 200 * 50;
    Ubiquitty::Linux::VulkanGlyphAtlas measured(8, 16, rasterizer, textureLimit, wideScreenCells);
    const int measuredCapacity = measured.bindMonoAtlas().slotCapacity;

    check(measuredCapacity > floorCapacity, "a measured screen does not enlarge the atlas");
    check(measuredCapacity >= wideScreenCells,
        "the atlas cannot hold one screenful, so a screen of distinct glyphs draws blanks");

    // Bigger screen, bigger atlas: the size tracks the grid rather than sitting
    // at whichever constant was written down.
    Ubiquitty::Linux::VulkanGlyphAtlas larger(8, 16, rasterizer, textureLimit, 300 * 80);
    check(larger.bindMonoAtlas().slotCapacity > measuredCapacity, "a larger screen does not enlarge the atlas further");

    Ubiquitty::PAL::logLine(stdout, "smoke-atlas-capacity: {}", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
