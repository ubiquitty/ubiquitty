// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-nf — probe which Nerd-Font icons are wider than one cell (the glyphs
// the cell-baked path CLIPS, that the subpixel overflow pass exists to fix).
// Rasterise each codepoint CENTERED in a scratch slot 3 cells wide (one cell of
// headroom each side, no clamp) and measure the ink's horizontal extent: ink
// reaching outside the central cell [cw, 2cw) means the glyph would be clipped
// in a one-cell slot. Read-only — renders to a scratch buffer, never the live
// path. After the overflow pass lands, the same wide glyphs must survive into
// the neighbour columns of a real render (see --smoke-nf-render).
/// Measures icon ink outside a single cell in a scratch raster.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeNerdFont()
{
    setupFonts();
    Ubiquitty::Rendering::GlyphRasterizer& rasteriser = currentRasterizer();
    const Ubiquitty::Rendering::CellMetrics metrics = rasteriser.cellMetrics();
    const int cellWidth = static_cast<int>(metrics.cellWidth);
    const int cellHeight = static_cast<int>(metrics.cellHeight);
    const Ubiquitty::Rendering::GlyphSlot policySlot = Ubiquitty::Rendering::computeGlyphSlot(rasteriser.glyphOverhang());
    g_print("smoke-nf: policy marginInPixels.width=%d marginInPixels.height=%d slot=%dx%d (cell=%dx%d)\n", policySlot.marginInPixels.width, policySlot.marginInPixels.height, policySlot.slotWidthInPixels, policySlot.slotHeightInPixels, cellWidth, cellHeight);
    const int slotWidthInPixels = cellWidth * 3; // central cell + a cell of headroom each side
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(slotWidthInPixels) * cellHeight);

    struct Probe {
        std::uint32_t codePoint;
        const char* name;
    };
    const Probe probes[] = {
        { 0xE0B0, "pl-arrow-r" },
        { 0xE0B2, "pl-arrow-l" },
        { 0xE0A0, "pl-branch" },
        { 0xE5FB, "seti-folder" },
        { 0xE628, "seti-go" },
        { 0xE706, "dev-python" },
        { 0xF001, "fa-music" },
        { 0xF015, "fa-home" },
        { 0xF09B, "fa-github" },
        { 0xF0E7, "fa-bolt" },
        { 0xF121, "fa-code" },
        { 0xF073, "fa-calendar" },
        { 0xF0249, "md-shield" },
        { 0xF02D1, "md-book" },
        { 0xF0594, "md-weather" },
        { 0xE315, "weather" },
        { 0xF300, "linux-logo" },
        { 0xF31B, "fl-ubuntu" },
    };

    int clipped = 0;
    int present = 0;
    for (const Probe& probe : probes) {
        coverage.assign(coverage.size(), std::uint8_t { 0 });
        rasteriser.rasterizeGlyph(probe.codePoint, Ubiquitty::Rendering::FontFace::Regular, 0, slotWidthInPixels, cellHeight, coverage.data());
        int minX = slotWidthInPixels;
        int maxX = -1;
        for (int y = 0; y < cellHeight; ++y)
            for (int x = 0; x < slotWidthInPixels; ++x)
                if (coverage[static_cast<std::size_t>(y) * slotWidthInPixels + x] >= 24) {
                    minX = std::min(minX, x);
                    maxX = std::max(maxX, x);
                }
        if (maxX < 0) {
            g_print("smoke-nf: U+%05X %-12s — no ink (font lacks glyph)\n", probe.codePoint, probe.name);
            continue;
        }
        ++present;
        const int inkWidth = maxX - minX + 1;
        const bool doesOverflow = (minX < cellWidth) || (maxX >= 2 * cellWidth);
        g_print("smoke-nf: U+%05X %-12s inkW=%2d (cell=%d) ink[%2d..%2d] %s\n", probe.codePoint, probe.name, inkWidth, cellWidth, minX, maxX, doesOverflow ? "OVERFLOWS cell -> clipped" : "fits");
        if (doesOverflow)
            ++clipped;
    }
    // The overflow count is a measurement and not a verdict — a glyph wider than
    // its cell is what the subpixel pass exists to draw, so a high count is the
    // expected reading rather than a fault. The failure available here is the
    // measurement saying nothing: no probe glyph present means the bundled font
    // did not load, and every line above reports on an empty raster while the run
    // still exits 0. That is the state this case exists to catch.
    // What this backend's null entries give up, from Core's own predicate. It
    // had no callers: a frontend leaving `colorGlyph` null draws an emoji
    // monochrome, and the cell is inked with every count right, so nothing
    // downstream can tell. Reported rather than gated — the CPU path has no
    // colour atlas at all, so a gate would fail every run and teach the reader
    // to skip it. Naming it is what makes the omission visible.
    const bool isLossy = app().rasterContext.softwareBackendIsLossy();
    Ubiquitty::PAL::logLine(stdout, "smoke-nf: software backend lossy={} ({})", isLossy ? 1 : 0,
        isLossy ? "colour glyphs and/or clusters fall back" : "every optional entry filled");

    const bool didMeasure = present > 0;
    Ubiquitty::PAL::logLine(stdout, "smoke-nf: {}/{} present glyphs overflow a single cell (cell={}x{}) -- {}",
        clipped, present, cellWidth, cellHeight, didMeasure ? "PASS" : "FAIL: no probe glyph present");
    return didMeasure ? 0 : 1;
}
