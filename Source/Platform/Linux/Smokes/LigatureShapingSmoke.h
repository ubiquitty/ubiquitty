// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-ligature-shaping — the text face shapes programming ligatures, and the
// oracle is substitution rather than glyph count.
//
// Counting glyphs is the wrong test and reports the wrong answer on the face
// this frontend actually ships. A monospace programming face keeps one glyph per
// cell so the grid keeps its columns: `=>` shapes to a blank plus one wide glyph
// anchored at the last cell, which is two glyphs from two cells, exactly as `ab`
// is. Measured on the bundled JetBrains Mono here: `=>` → [1751 blank][1006],
// `!==` → [1751][1751][873], and glyph 1751 has an empty `glyf` record.
//
// Those indices belong to the file, not to the family: the variable build that
// replaced the v2.304 statics renumbered them, and the previous three quoted
// here had gone stale without anything noticing — the assertion below is
// substitution against the character map, which survives a renumbering.
//
// So the question is whether shaping moved a glyph off what the character map
// alone would have given, and `ab` is the control: a run of letters no face
// ligates must come back untouched, or whatever the operators showed came from
// something other than the ligature table.
/// Checks programming-ligature substitutions against the bundled face.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeLigatureShaping()
{
    setupFonts();

    // Shaped against the bundled face rather than whatever fontconfig resolved
    // for "monospace". Those are different questions and only one of them is a
    // fact about this repository. Whether the machine has a ligature face
    // installed is a capability — this container answers DejaVu Sans Mono, which
    // ligates nothing, and that is not a defect. Whether the face shipped in
    // Resources/fonts carries the tables it is bundled to provide is a contract,
    // and it holds or it does not wherever this runs.
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-ligature-shaping: FAILED — no bundled primary face beside the binary,"
                   " so nothing was shaped\n");
        return 1;
    }
    Ubiquitty::Linux::FreeTypeRasterizer bundled(deviceFontPixelSize(), "JetBrains Mono",
        std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels);
    if (!bundled.ready()) {
        g_printerr("smoke-ligature-shaping: FAILED — the bundled face at %s did not load\n",
            bundledPath.c_str());
        return 1;
    }
    auto& rasterizer = bundled;
    if (!rasterizer.canShapeText()) {
        g_printerr("smoke-ligature-shaping: FAILED — the bundled face loaded but carries no shaper\n");
        return 1;
    }

    struct Case {
        const char* text;
        bool expectSubstitution;
    };
    // The operators are the ones a programming face is bought for; the letters
    // are the control. A face without ligature tables fails the first four and
    // passes the last two, which is a different verdict from failing everything.
    const std::array<Case, 6> cases {
        Case { "=>", true },
        Case { "!==", true },
        Case { "->", true },
        Case { "===", true },
        Case { "ab", false },
        Case { "xy", false },
    };

    int failures = 0;
    for (const Case& probe : cases) {
        std::array<std::uint32_t, 8> codePoints {};
        const int count = static_cast<int>(std::strlen(probe.text));
        for (int i = 0; i < count; ++i)
            codePoints[static_cast<std::size_t>(i)] = static_cast<std::uint32_t>(probe.text[i]);

        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> shaped {};
        const int glyphs = rasterizer.shapeTextRun(
            std::span(codePoints).first(static_cast<std::size_t>(count)), 0, shaped);
        if (glyphs != count) {
            // Not a ligature verdict either way: this face maps a run of ASCII
            // one glyph per cell, so a different count means the run did not
            // shape the way every case here assumes.
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" shaped to %d glyphs from %d cells\n",
                probe.text, glyphs, count);
            ++failures;
            continue;
        }

        int substituted = 0;
        for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
            if (shaped[i].glyph != rasterizer.glyphIndexForCodePoint(codePoints[i]))
                ++substituted;
        }
        const bool sawSubstitution = substituted > 0;
        g_print("  %-4s %d glyph(s), %d substituted — %s\n", probe.text, glyphs, substituted,
            sawSubstitution ? "shaped" : "character map");
        if (sawSubstitution != probe.expectSubstitution) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" expected %s\n", probe.text,
                probe.expectSubstitution ? "a substitution" : "no substitution");
            ++failures;
        }
    }

    // The settings that reach the shaper, as a DIFFERENTIAL against the same
    // face. Everything above proves substitution happens; this pair proves the
    // configuration can stop it, which is a different claim and the one that
    // was false — all three `hb_shape` calls passed `nullptr, 0`, so
    // `[font] ligatures = false` and every `font.features` token were inert.
    //
    // A lone negative arm would be vacuous here: "no substitution" is also what
    // a face with no ligature tables answers, what a shaper that never ran
    // answers, and what a broken run answers. Only the difference between two
    // rasterizers one setting apart says the setting did it, and the arms above
    // are what make the positive half of that pair mean anything.
    {
        Ubiquitty::Linux::FreeTypeRasterizer suppressed(deviceFontPixelSize(), "JetBrains Mono",
            std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels,
            0, 0, 0, 0.0, std::string(), std::string(), Ubiquitty::Linux::Ligatures::Disabled);
        if (!suppressed.ready() || !suppressed.canShapeText()) {
            g_printerr("smoke-ligature-shaping: FAILED — the suppressed face did not load\n");
            ++failures;
        } else {
            int stillLigating = 0;
            for (const Case& probe : cases) {
                if (!probe.expectSubstitution)
                    continue; // the letters substitute under neither setting
                std::array<std::uint32_t, 8> codePoints {};
                const int count = static_cast<int>(std::strlen(probe.text));
                for (int i = 0; i < count; ++i)
                    codePoints[static_cast<std::size_t>(i)] = static_cast<std::uint32_t>(probe.text[i]);
                std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> shaped {};
                const int glyphs = suppressed.shapeTextRun(
                    std::span(codePoints).first(static_cast<std::size_t>(count)), 0, shaped);
                int substituted = 0;
                for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
                    if (shaped[i].glyph != suppressed.glyphIndexForCodePoint(codePoints[i]))
                        ++substituted;
                }
                if (substituted > 0) {
                    g_printerr("smoke-ligature-shaping: FAILED — \"%s\" still ligated with ligatures off\n",
                        probe.text);
                    ++stillLigating;
                }
            }
            g_print("  ligatures=off: %d of 4 operator(s) still ligating\n", stillLigating);
            failures += stillLigating;
        }

        // A `font.features` token reaches the shaper too, and beats the toggle
        // rather than losing to it: the specification is the finer control and
        // is appended after the suppression, so a later entry wins in HarfBuzz.
        // Asserted rather than left to the ordering comment, because reversing
        // those two lines is a silent change nothing else here would notice.
        //
        // `+calt` rather than `+liga`, and the difference is measured rather
        // than assumed: against this face `+liga` and `+clig` each restore no
        // operator at all and `+calt` restores the arrow, so JetBrains Mono
        // carries `=>` in
        // `calt` alone. That is the whole reason the suppression above lists
        // three tags — turning off `liga` would have left every operator
        // drawing and looked like a fix.
        Ubiquitty::Linux::FreeTypeRasterizer overridden(deviceFontPixelSize(), "JetBrains Mono",
            std::string(), std::string(), bundledPath, app().scale, app().lineSpacingPixels,
            0, 0, 0, 0.0, std::string(), std::string("+calt"), Ubiquitty::Linux::Ligatures::Disabled);
        if (overridden.ready() && overridden.canShapeText()) {
            const std::array<std::uint32_t, 2> arrow { '=', '>' };
            std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 2> shaped {};
            const int glyphs = overridden.shapeTextRun(arrow, 0, shaped);
            int substituted = 0;
            for (std::size_t i = 0; i < static_cast<std::size_t>(glyphs); ++i) {
                if (shaped[i].glyph != overridden.glyphIndexForCodePoint(arrow[i]))
                    ++substituted;
            }
            g_print("  ligatures=off features=+calt: %d substituted (expect > 0)\n", substituted);
            if (substituted == 0) {
                g_printerr("smoke-ligature-shaping: FAILED — an explicit +calt lost to the toggle\n");
                ++failures;
            }
        }
    }

    // Shaping at a weight, which a bold run does. What this proves depends on
    // the face and the smoke says which: with a 'wght' axis it exercises the
    // re-shape after the axis moves, and without one applyWeightAxis returns
    // immediately, so it only asserts that asking for bold does not lose the
    // ligature. Neither font reachable in the CI container is variable —
    // JetBrains Mono Regular and DejaVu Sans Mono both report no axes — so this
    // is the second case here and the first only wherever a variable face is
    // installed. Stated rather than left for a reader to assume from a pass.
    const std::array<std::uint32_t, 2> arrow { '=', '>' };
    std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 2> bold {};
    const int boldGlyphs = rasterizer.shapeTextRun(arrow, 7, bold);
    int boldSubstituted = 0;
    for (std::size_t i = 0; i < static_cast<std::size_t>(boldGlyphs); ++i) {
        if (bold[i].glyph != rasterizer.glyphIndexForCodePoint(arrow[i]))
            ++boldSubstituted;
    }
    g_print("  => at weight 7: %d glyph(s), %d substituted (face %s a wght axis)\n",
        boldGlyphs, boldSubstituted, rasterizer.hasWeightAxis() ? "has" : "lacks");
    if (boldGlyphs != 2 || boldSubstituted == 0) {
        g_printerr("smoke-ligature-shaping: FAILED — \"=>\" lost its ligature when shaped bold\n");
        ++failures;
    }

    // A run longer than the caller's buffer shapes to nothing rather than to a
    // prefix. A prefix would be drawn as though it were the whole run, so the
    // cells past it would carry the wrong glyphs instead of no glyphs.
    std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 1> one {};
    const int refused = rasterizer.shapeTextRun(arrow, 0, one);
    g_print("  room for 1 glyph on a 2-cell run → %d\n", refused);
    if (refused != 0) {
        g_printerr("smoke-ligature-shaping: FAILED — a run too long for its output span returned %d rather than 0\n", refused);
        ++failures;
    }

    // The strip a run actually draws, against the same run drawn unligated.
    //
    // Both images come out of rasteriseShapedRun, so the drawing path, the
    // baseline, the pen walk and the clipping are identical and the only
    // difference between them is which glyph ids went in: the shaper's, or the
    // character map's for the same characters. That makes an inequality mean the
    // ligature and nothing else — a strip compared against per-cell rasters
    // would also differ wherever a font's bearings do not centre a glyph in its
    // advance, which is most of them.
    //
    // `ab` is the control on the pixels as well as on the glyph ids: a run that
    // substitutes nothing must draw the identical image both ways, or the
    // comparison is reporting something other than shaping.
    const int cellWidth = static_cast<int>(rasterizer.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(rasterizer.cellMetrics().cellHeight);
    struct StripCase {
        const char* text;
        bool shouldDifferInPixels;
    };
    const std::array<StripCase, 3> stripCases {
        StripCase { "=>", true },
        StripCase { "!==", true },
        StripCase { "ab", false },
    };
    for (const StripCase& probe : stripCases) {
        const int cells = static_cast<int>(std::strlen(probe.text));
        const int stripWidth = cellWidth * cells;
        std::array<std::uint32_t, 8> codePoints {};
        for (int i = 0; i < cells; ++i)
            codePoints[static_cast<std::size_t>(i)] = static_cast<std::uint32_t>(probe.text[i]);
        const auto run = std::span(codePoints).first(static_cast<std::size_t>(cells));

        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> shaped {};
        const int glyphs = rasterizer.shapeTextRun(run, 0, shaped);

        // The same run as the character map alone would draw it: same advances,
        // same pen, unsubstituted glyphs.
        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> unligated {};
        for (int i = 0; i < glyphs; ++i) {
            unligated[static_cast<std::size_t>(i)] = shaped[static_cast<std::size_t>(i)];
            unligated[static_cast<std::size_t>(i)].glyph = rasterizer.glyphIndexForCodePoint(run[static_cast<std::size_t>(i)]);
        }

        // Handed over dirty, on purpose. A fresh vector arrives zeroed, so a
        // rasteriser that never cleared its output would draw the right picture
        // on top of zeros and pass — and then leak the previous strip's pixels
        // in the atlas, which reuses one buffer across runs. Pre-filling means a
        // rasteriser that skips its clear fails here, which is what it will do
        // there. 0xFF rather than a random byte so a survivor reads as ink
        // everywhere rather than as noise.
        std::vector<std::uint8_t> ligatedPixels(static_cast<std::size_t>(stripWidth) * static_cast<std::size_t>(cellHeight), 0xFF);
        std::vector<std::uint8_t> plainPixels(ligatedPixels.size(), 0xFF);
        const bool didDrawLigated = rasterizer.rasteriseShapedRun(
            std::span(shaped).first(static_cast<std::size_t>(glyphs)), stripWidth, cellHeight, ligatedPixels);
        const bool didDrawPlain = rasterizer.rasteriseShapedRun(
            std::span(unligated).first(static_cast<std::size_t>(glyphs)), stripWidth, cellHeight, plainPixels);
        if (!didDrawLigated || !didDrawPlain) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" did not draw a %dx%d strip\n",
                probe.text, stripWidth, cellHeight);
            ++failures;
            continue;
        }

        const bool isDifferent = ligatedPixels != plainPixels;
        // Per cell, not just per strip. The comparison above holds the two
        // draws against each other, so anything wrong in the path they SHARE
        // cancels out and passes — a pen that never advanced would stack every
        // glyph on column zero in both images and still report them equal for
        // `ab` and different for `=>`. Counting ink per cell is the absolute
        // check that the run was laid out across its columns at all.
        std::size_t isPixelInked = 0;
        int emptyCells = 0;
        for (int cell = 0; cell < cells; ++cell) {
            std::size_t cellInk = 0;
            for (int y = 0; y < cellHeight; ++y) {
                for (int x = 0; x < cellWidth; ++x) {
                    const std::size_t at = static_cast<std::size_t>(y) * static_cast<std::size_t>(stripWidth)
                        + static_cast<std::size_t>(cell * cellWidth + x);
                    if (ligatedPixels[at] != 0)
                        ++cellInk;
                }
            }
            isPixelInked += cellInk;
            if (cellInk == 0)
                ++emptyCells;
        }
        g_print("  %-4s strip %dx%d: %zu inked px across %d cell(s), %d empty, %s the unligated draw\n",
            probe.text, stripWidth, cellHeight, isPixelInked, cells, emptyCells,
            isDifferent ? "differs from" : "matches");
        // Every case here draws visible ink in every one of its cells: the
        // letters because each inks its own, and the operators because the wide
        // ligature glyph reaches back across the cells its blanks left empty.
        // A blank strip would otherwise compare equal to a blank control and
        // pass the `ab` case having drawn nothing at all.
        if (emptyCells != 0) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" left %d of %d cell(s) with no ink\n",
                probe.text, emptyCells, cells);
            ++failures;
        }
        // And a strip is mostly background: glyphs are ink on empty space, and
        // no run of operators or letters covers even half of its box. Without
        // this a rasteriser that skipped its clear passed everything above —
        // the buffer arrives dirty, the stale content is UNIFORM, so the two
        // draws still differed for `=>` and still matched for `ab`, and every
        // cell still had ink. Saturation is what a leaked buffer looks like and
        // nothing else here could see it.
        const std::size_t stripPixels = ligatedPixels.size();
        if (isPixelInked * 2 >= stripPixels) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" inked %zu of %zu strip pixels;"
                       " a strip that is more ink than background was not cleared\n",
                probe.text, isPixelInked, stripPixels);
            ++failures;
        }
        if (isDifferent != probe.shouldDifferInPixels) {
            g_printerr("smoke-ligature-shaping: FAILED — \"%s\" expected the strip to %s\n", probe.text,
                probe.shouldDifferInPixels ? "differ from the unligated draw" : "match the unligated draw");
            ++failures;
        }
    }

    if (failures) {
        g_printerr("smoke-ligature-shaping: FAILED — %d case(s), face \"%s\"\n",
            failures, rasterizer.faceName());
        return 1;
    }
    g_print("smoke-ligature-shaping: PASS (%zu case(s) shaped against \"%s\", letters unshaped, an oversized run refused)\n",
        sizeof(cases) / sizeof(cases[0]), rasterizer.faceName());
    return 0;
}
