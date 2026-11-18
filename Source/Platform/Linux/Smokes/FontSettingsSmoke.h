// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-ligature-sheet — a distilled row becomes strips on the sheet.
//
// The layer between the shaper and the renderer: Core walks the row into run
// candidates, this sheet keys each one, shapes it, draws it into a slot, and
// reports the rect plus the extents the builder maps cell slices against.
//
// Checked against the host mirror rather than a rendering, which is what makes
// it answerable with no GPU: the upload copies the mirror verbatim, so where a
// strip landed and whether drawing one disturbed its neighbours are questions
// the bytes answer. A rendering could not show the second one at all.
// --smoke-font-settings — character spacing moves the COLUMN and leaves the INK.
//
// The invariant is the one macOS states at its tracking fold: tracking lands on
// the layout pitch and nowhere else, because the slot describes the glyph
// rather than the column it sits in. A slot that followed the pitch would
// stretch a glyph under positive tracking and clip one under negative, and both
// draw something — so a check that only asked "did the cell change" would pass
// on the implementation this exists to reject.
//
// Three rasterizers over one face, differing only in tracking. The pitch must
// move by the tracking in both directions; the face's own advance must not move
// at all.
/// Checks font settings through the live configuration path.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeFontSettings()
{
    setupFonts();
    const std::string bundledPath = bundledFontPathForFamily("JetBrains Mono");
    if (bundledPath.empty()) {
        g_printerr("smoke-font-settings: FAILED - no bundled primary face beside the binary\n");
        return 1;
    }

    const double pixelSize = deviceFontPixelSize();
    auto build = [&](int tracking) {
        return Ubiquitty::Linux::FreeTypeRasterizer(pixelSize, "JetBrains Mono", std::string(), std::string(),
            bundledPath, app().scale, app().lineSpacingPixels, tracking);
    };

    const Ubiquitty::Linux::FreeTypeRasterizer plain = build(0);
    if (!plain.ready()) {
        g_printerr("smoke-font-settings: FAILED - the bundled face did not load\n");
        return 1;
    }
    // Wide enough that a rounding difference cannot be mistaken for the effect,
    // and small enough that the tightened cell stays well clear of Core's floor.
    const int tracking = 3;
    const Ubiquitty::Linux::FreeTypeRasterizer wider = build(tracking);
    const Ubiquitty::Linux::FreeTypeRasterizer tighter = build(-tracking);

    const float basePitch = plain.cellMetrics().cellWidth;
    const double baseInk = plain.glyphOverhang().advanceWidth;
    g_print("  pitch %.1f px, ink advance %.1f px, tracking +/-%d\n", static_cast<double>(basePitch), baseInk, tracking);

    int failures = 0;
    // Ink first: a face measuring nothing would satisfy every equality below
    // while answering no question at all.
    if (!(baseInk > 0.0) || !(basePitch > 0.0f)) {
        g_printerr("smoke-font-settings: FAILED - the face reports no advance, so nothing here is a measurement\n");
        return 1;
    }

    if (wider.cellMetrics().cellWidth != basePitch + static_cast<float>(tracking)) {
        g_printerr("smoke-font-settings: FAILED - positive tracking moved the pitch to %.1f, expected %.1f\n",
            static_cast<double>(wider.cellMetrics().cellWidth), static_cast<double>(basePitch + static_cast<float>(tracking)));
        ++failures;
    }
    if (tighter.cellMetrics().cellWidth != basePitch - static_cast<float>(tracking)) {
        g_printerr("smoke-font-settings: FAILED - negative tracking moved the pitch to %.1f, expected %.1f\n",
            static_cast<double>(tighter.cellMetrics().cellWidth), static_cast<double>(basePitch - static_cast<float>(tracking)));
        ++failures;
    }
    // The half the pitch assertions cannot see: a slot that followed the pitch
    // passes both of them.
    if (wider.glyphOverhang().advanceWidth != baseInk || tighter.glyphOverhang().advanceWidth != baseInk) {
        g_printerr("smoke-font-settings: FAILED - tracking moved the ink advance (%.1f / %.1f, expected %.1f both)\n",
            wider.glyphOverhang().advanceWidth, tighter.glyphOverhang().advanceWidth, baseInk);
        ++failures;
    }

    // The bundled primary is the variable JetBrains Mono, so the wght axis is a
    // contract here rather than a capability to report: a static build put back
    // in its place would leave every weight setting resolving to one coordinate
    // while still rendering perfectly, which is the substitution nothing else
    // notices.
    if (!plain.hasWeightAxis()) {
        g_printerr("smoke-font-settings: FAILED - the bundled primary carries no wght axis,"
                   " so every weight setting resolves to one coordinate\n");
        return 1;
    }

    // Bold with `font.bold_weight` UNSET. Zero means "the face's own bold", and
    // a variable face has no bold member to fall back to — unplaced, the axis
    // stays where the upright sits and bold text draws identically to regular.
    // Counted in pixels rather than read off the resolved coordinate: the
    // question is whether the run came out bolder, and a coordinate can be
    // right while nothing places it on the face that draws.
    const int cellWidth = static_cast<int>(plain.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(plain.cellMetrics().cellHeight);
    std::vector<std::uint8_t> uprightCoverage(static_cast<std::size_t>(cellWidth) * cellHeight);
    std::vector<std::uint8_t> boldCoverage(uprightCoverage.size());
    auto isPixelInked = [](const std::vector<std::uint8_t>& coverage) {
        long total = 0;
        for (const std::uint8_t sample : coverage)
            total += sample;
        return total;
    };
    // A plain rectangle, so the difference is stem weight and not a serif
    // moving: 'l' carries a tail and 'M' carries diagonals.
    constexpr std::uint32_t bar = U'|';
    Ubiquitty::Linux::FreeTypeRasterizer weightProbe = build(0); // rasterizing mutates the face
    const bool didDrawUpright = weightProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 0, cellWidth, cellHeight, uprightCoverage.data());
    const bool didDrawBold = weightProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Bold, 0, cellWidth, cellHeight, boldCoverage.data());
    const long uprightInk = isPixelInked(uprightCoverage);
    const long boldInk = isPixelInked(boldCoverage);
    g_print("  '|' ink upright %ld, bold %ld (bold_weight unset)\n", uprightInk, boldInk);
    if (!didDrawUpright || !didDrawBold || uprightInk == 0) {
        g_printerr("smoke-font-settings: FAILED - the weight probe drew nothing, so it compares nothing\n");
        ++failures;
    } else if (boldInk <= uprightInk) {
        g_printerr("smoke-font-settings: FAILED - bold drew %ld ink against upright %ld,"
                   " so an unset bold_weight left the axis at the upright coordinate\n",
            boldInk, uprightInk);
        ++failures;
    }

    // `font.variations`, the axis list. Two questions, and the second is the
    // one a wiring can pass without answering.
    //
    // Only `wght` is exercised, because that is the only axis the bundled face
    // carries — its fvar has one. So a pass here says the parse, the fold over
    // the derived pair, the tag lookup and the clamp all work on ONE axis; it
    // says nothing about a face with several, where a per-axis range matters.
    auto buildVaried = [&](const char* variations) {
        return Ubiquitty::Linux::FreeTypeRasterizer(pixelSize, "JetBrains Mono", std::string(), std::string(),
            bundledPath, app().scale, app().lineSpacingPixels, 0, 0, 0, 0.0, variations);
    };
    std::vector<std::uint8_t> variedCoverage(uprightCoverage.size());
    std::vector<std::uint8_t> variedBoldCoverage(uprightCoverage.size());
    Ubiquitty::Linux::FreeTypeRasterizer variedProbe = buildVaried("wght=200");
    const bool didDrawVaried = variedProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 0, cellWidth, cellHeight, variedCoverage.data());
    const bool didDrawVariedBold = variedProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Bold, 0, cellWidth, cellHeight, variedBoldCoverage.data());
    const long variedInk = isPixelInked(variedCoverage);
    const long variedBoldInk = isPixelInked(variedBoldCoverage);
    Ubiquitty::Linux::FreeTypeRasterizer heavyProbe = buildVaried("wght=800");
    std::vector<std::uint8_t> heavyCoverage(uprightCoverage.size());
    std::vector<std::uint8_t> heavyBoldCoverage(uprightCoverage.size());
    const bool didDrawHeavy = heavyProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 0, cellWidth, cellHeight, heavyCoverage.data());
    const bool didDrawHeavyBold = heavyProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Bold, 0, cellWidth, cellHeight, heavyBoldCoverage.data());
    g_print("  '|' ink at variations \"wght=800\": upright %ld, bold %ld\n", isPixelInked(heavyCoverage), isPixelInked(heavyBoldCoverage));
    if (!didDrawHeavy || !didDrawHeavyBold || isPixelInked(heavyCoverage) == 0 || heavyCoverage != heavyBoldCoverage) {
        g_printerr("smoke-font-settings: FAILED - an unset bold weight did not draw at the body's heavy wght coordinate\n");
        ++failures;
    }
    g_print("  '|' ink at variations \"wght=200\": upright %ld, bold %ld\n", variedInk, variedBoldInk);
    if (!didDrawVaried || !didDrawVariedBold || variedInk == 0) {
        g_printerr("smoke-font-settings: FAILED - the variations probe drew nothing, so it compares nothing\n");
        ++failures;
    } else {
        // The axis reached the face: 200 is below the face's 400 default, so
        // the upright run is LIGHTER than the same run without a specification.
        // Compared against that run rather than against a constant, because a
        // specification that never arrived draws exactly it.
        if (variedInk >= uprightInk) {
            g_printerr("smoke-font-settings: FAILED - \"wght=200\" drew %ld ink against %ld unspecified,"
                       " so the axis list did not reach the face\n",
                variedInk, uprightInk);
            ++failures;
        }
        // The bold face drops a user `wght`. Its weight is what makes it bold,
        // and a specification naming the body's weight would otherwise pull it
        // down onto the body — leaving bold and regular one colour on a face
        // that can draw both. This is the half a wiring passes without: erase
        // nothing and the assertion above still holds.
        if (variedBoldInk <= variedInk) {
            g_printerr("smoke-font-settings: FAILED - bold drew %ld ink against upright %ld under"
                       " \"wght=200\", so the user axis reached the bold face and collapsed it\n",
                variedBoldInk, variedInk);
            ++failures;
        }
        // An SGR weight is the running program naming the weight of one run, and
        // it outranks a configured axis. The same specification is in force, so
        // a drop that only covered the bold face leaves this run drawn at 200.
        std::vector<std::uint8_t> sgrCoverage(uprightCoverage.size());
        const bool didDrawSGR = variedProbe.rasterizeGlyph(bar, Ubiquitty::Rendering::FontFace::Regular, 7, cellWidth, cellHeight, sgrCoverage.data());
        const long sgrInk = isPixelInked(sgrCoverage);
        g_print("  '|' ink at SGR weight 7 under the same \"wght=200\": %ld\n", sgrInk);
        if (!didDrawSGR || sgrInk <= variedInk) {
            g_printerr("smoke-font-settings: FAILED - SGR weight 7 drew %ld ink against %ld at the"
                       " configured axis, so a user wght outranked the running program\n",
                sgrInk, variedInk);
            ++failures;
        }
    }

    if (failures) {
        g_printerr("smoke-font-settings: FAILED - %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-font-settings: PASS (tracking moves the pitch both ways and leaves the ink advance alone;"
            " the body variation sets the unset bold floor and an SGR weight still overrides it)\n");
    return 0;
}
