// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks shaping-strip placement and reuse in the glyph sheet.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeLigatureSheet()
{
    setupFonts();
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-ligature-sheet: FAILED — no bundled primary face beside the binary\n");
        return 1;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready() || !bundled.canShapeText()) {
        g_printerr("smoke-ligature-sheet: FAILED — the bundled face did not load a shaper\n");
        return 1;
    }

    const int cellWidth = static_cast<int>(bundled.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(bundled.cellMetrics().cellHeight);
    Ubiquitty::Rendering::LigatureSheet sheet(cellWidth, cellHeight, 0, 0, &bundled);
    if (!sheet.isUsable()) {
        g_printerr("smoke-ligature-sheet: FAILED — the sheet reports itself unusable\n");
        return 1;
    }
    g_print("  sheet %dx%d px, slot %dx%d, %d strip(s)\n", sheet.widthInPixels(), sheet.heightInPixels(),
        sheet.slotWidthInPixels(), sheet.slotHeightInPixels(), sheet.slotCapacity());

    int failures = 0;

    // A row Core's walk finds one run in — all four cells, not just the operator
    // pair. A run is a maximal stretch of same-shape eligible cells holding at
    // least one operator, so the letters join it rather than bracketing it;
    // context cells are what a stretch longer than ligatureMaxCells gets when it
    // is chunked, and nothing this short is chunked. Written here expecting the
    // other answer, and the run length said otherwise.
    const char* text = "x=>x";
    const int columns = static_cast<int>(std::strlen(text));
    std::vector<Ubiquitty::Rendering::LigatureCell> cells(static_cast<std::size_t>(columns));
    for (int i = 0; i < columns; ++i)
        cells[static_cast<std::size_t>(i)].codePoint = static_cast<std::uint32_t>(text[i]);
    std::vector<Ubiquitty::Rendering::LigatureRun> runs(static_cast<std::size_t>(columns));
    // Pre-dirtied so a sheet that failed to reset an uncovered column is caught:
    // the contract is that every entry is written, not only the covered ones.
    for (auto& run : runs)
        run.length = 99;

    sheet.beginFrame();
    sheet.shapeRow(cells, static_cast<float>(cellWidth), runs);

    // Two counts, because they answer different questions and only one of them
    // is "how many ligatures are in this row". A run is published into each
    // column it covers — the consumer indexes by column and takes its slice from
    // `column - startColumn` — so the number of non-empty entries is the number
    // of covered cells. The runs themselves are the entries that begin at their
    // own column. Counting cells and calling them runs is the reading this smoke
    // started with, and it made a working four-cell run look like four runs.
    int coveredCells = 0;
    int distinctRuns = 0;
    for (int column = 0; column < columns; ++column) {
        const auto& run = runs[static_cast<std::size_t>(column)];
        if (run.length == 99) {
            g_printerr("smoke-ligature-sheet: FAILED — column %d was left holding a previous run\n", column);
            ++failures;
        }
        if (run.length > 0) {
            ++coveredCells;
            if (run.startColumn == column) {
                ++distinctRuns;
                g_print("  run at column %d, %d cell(s), used %.0f of slot %.0f\n", run.startColumn, run.length,
                    static_cast<double>(run.usedWidthInAtlasPixels), static_cast<double>(run.slotWidthInAtlasPixels));
            }
            if (!run.strip.present) {
                g_printerr("smoke-ligature-sheet: FAILED — a covered run carries no strip\n");
                ++failures;
            }
            if (run.usedWidthInAtlasPixels <= 0.0f || run.usedWidthInAtlasPixels > run.slotWidthInAtlasPixels) {
                g_printerr("smoke-ligature-sheet: FAILED — the inked extent is not inside its slot\n");
                ++failures;
            }
        }
    }
    if (distinctRuns != 1) {
        g_printerr("smoke-ligature-sheet: FAILED — expected one run in \"%s\", found %d\n", text, distinctRuns);
        ++failures;
    }
    // The run covers every cell it claims. A run published only at its start
    // column passes every check above and still renders as one strip cell beside
    // three unligatured ones, which is the defect this line exists to catch.
    if (distinctRuns == 1 && coveredCells != runs[0].length) {
        g_printerr("smoke-ligature-sheet: FAILED — a %d-cell run reached %d column(s)\n",
            runs[0].length, coveredCells);
        ++failures;
    }

    // The strip carries ink, and it carries it in the slot the rect names. A run
    // reported with an empty slot would satisfy every field above.
    std::size_t isPixelInked = 0;
    for (std::uint8_t coverage : sheet.coverage())
        isPixelInked += coverage != 0 ? 1 : 0;
    const std::size_t sheetPixels = sheet.coverage().size();
    g_print("  %zu inked px of %zu across the sheet\n", isPixelInked, sheetPixels);
    if (isPixelInked == 0) {
        g_printerr("smoke-ligature-sheet: FAILED — the sheet holds no ink\n");
        ++failures;
    }
    // One strip drawn, so the rest of the sheet stays clear: writing a slot must
    // not reach into its neighbours, which a rendering of one run cannot show.
    const std::size_t slotPixels = static_cast<std::size_t>(sheet.slotWidthInPixels()) * static_cast<std::size_t>(sheet.slotHeightInPixels());
    if (isPixelInked >= slotPixels) {
        g_printerr("smoke-ligature-sheet: FAILED — %zu inked px exceeds one slot's %zu; a strip reached past its own\n",
            isPixelInked, slotPixels);
        ++failures;
    }

    // A stretch longer than ligatureMaxCells, which is the case the short row
    // above cannot reach: it chunks, the chunks carry context, and a chunk
    // reaches the cap. Three pieces of the contract that a four-cell run leaves
    // entirely unexercised: with only that row, every mutation to the chunk
    // seam passes.
    const int longColumns = Ubiquitty::Rendering::ligatureMaxCells + 8;
    std::vector<Ubiquitty::Rendering::LigatureCell> longCells(static_cast<std::size_t>(longColumns));
    for (int i = 0; i < longColumns; ++i)
        longCells[static_cast<std::size_t>(i)].codePoint = static_cast<std::uint32_t>((i % 2) == 0 ? '=' : '>');
    std::vector<Ubiquitty::Rendering::LigatureRun> longRuns(static_cast<std::size_t>(longColumns));

    sheet.beginFrame();
    sheet.shapeRow(longCells, static_cast<float>(cellWidth), longRuns);

    int chunks = 0;
    int longestChunk = 0;
    bool sawFullChunk = false;
    bool doesSlotSumHold = true;
    bool doesExtentSumHold = true;
    bool sawContextInset = false;
    // The two sums, spelled out here rather than read back through the helpers
    // that produce them, so this is a second witness and not the same
    // arithmetic agreeing with itself. The sheet was built with no margin.
    const float expectedSlotWidth = static_cast<float>(Ubiquitty::Rendering::stripSlotCells * cellWidth + 1);
    for (int column = 0; column < longColumns; ++column) {
        const auto& run = longRuns[static_cast<std::size_t>(column)];
        if (run.length <= 0 || run.startColumn != column)
            continue; // count the runs, not the cells each one covers
        ++chunks;
        longestChunk = std::max(longestChunk, run.length);
        if (run.length == Ubiquitty::Rendering::ligatureMaxCells)
            sawFullChunk = true;
        if (run.slotWidthInAtlasPixels != expectedSlotWidth)
            doesSlotSumHold = false;
        const float expectedExtent = static_cast<float>(std::ceil(run.length * static_cast<double>(cellWidth) + 1.0));
        if (run.usedWidthInAtlasPixels != expectedExtent)
            doesExtentSumHold = false;
        if (run.contextInsetLeftInAtlasPixels > 0.0f || run.contextInsetRightInAtlasPixels > 0.0f)
            sawContextInset = true;
    }
    g_print("  %d column(s) → %d chunk(s), longest %d, full chunk=%d, slot sum=%d, extent sum=%d, context inset=%d\n",
        longColumns, chunks, longestChunk, static_cast<int>(sawFullChunk), static_cast<int>(doesSlotSumHold),
        static_cast<int>(doesExtentSumHold), static_cast<int>(sawContextInset));
    if (chunks < 2) {
        g_printerr("smoke-ligature-sheet: FAILED — a %d-cell stretch produced %d chunk(s); it must split\n",
            longColumns, chunks);
        ++failures;
    }
    if (longestChunk > Ubiquitty::Rendering::ligatureMaxCells) {
        g_printerr("smoke-ligature-sheet: FAILED — a chunk of %d cells exceeds the %d-cell cap\n",
            longestChunk, Ubiquitty::Rendering::ligatureMaxCells);
        ++failures;
    }
    // The slot and the extent are two derivations of one geometry, and each is
    // held to its own sum. The slot is stripSlotCells cells plus the margins
    // plus one pixel, cut for the widest proportional run rather than for a
    // ligature chunk, which is capped at ligatureMaxCells and so fills half of
    // it at most. A chunk's extent is its own cells plus the margins plus one
    // pixel; Core clamps that to the slot, and the clamp cannot bind for a
    // ligature run — only a proportional run reaches the slot's edge. Either
    // sum drifting resamples every long run, which is what these catch. A
    // stretch of ligatureMaxCells + 8 cells must yield at least one full
    // chunk, or the extent sum was never checked at the cap.
    if (!sawFullChunk) {
        g_printerr("smoke-ligature-sheet: FAILED — no chunk reached the %d-cell cap, so the extent sum"
                   " was not checked at full length\n",
            Ubiquitty::Rendering::ligatureMaxCells);
        ++failures;
    }
    if (!doesSlotSumHold) {
        g_printerr("smoke-ligature-sheet: FAILED — a chunk's slot is not %d cells plus one pixel;"
                   " the slot derivation has drifted\n",
            Ubiquitty::Rendering::stripSlotCells);
        ++failures;
    }
    if (!doesExtentSumHold) {
        g_printerr("smoke-ligature-sheet: FAILED — a chunk's extent is not its cells plus one pixel;"
                   " the extent derivation has drifted\n");
        ++failures;
    }
    // A chunk seam has a neighbour on one side, so at least one chunk holds back
    // the margin the neighbour's context glyphs were drawn into. Without this the
    // seam paints those glyphs twice and reads bolder than the text around it.
    if (!sawContextInset) {
        g_printerr("smoke-ligature-sheet: FAILED — no chunk reported a context inset at its seam\n");
        ++failures;
    }

    if (failures) {
        g_printerr("smoke-ligature-sheet: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-ligature-sheet: PASS (one short run, a long stretch chunked with insets, each chunk's slot and extent their own sums,"
            " strips inside their own slots, uncovered columns reset)\n");
    return 0;
}
