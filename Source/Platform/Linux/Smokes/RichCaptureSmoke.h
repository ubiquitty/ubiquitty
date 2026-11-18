// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks captured rich-text data against the rendered terminal.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeRichCapture()
{
    setupFonts();
    LinuxPane& pane = *activePane();
    pane.session->start(8, 24);
    Ubiquitty::Terminal* term = pane.session->terminal();
    if (!term) {
        g_printerr("smoke-rich-capture: no term\n");
        return 1;
    }
    const auto shaper = pane.richText.shaper();
    pane.session->setRichTextShaper(shaper.function, shaper.context);
    publishPaneTypography(pane);
    bool didPass = true;
    const auto check = [&](const char* name, bool passed) {
        didPass = didPass && passed;
        g_print("smoke-rich-capture: %s -- %s\n", name, passed ? "PASS" : "FAIL");
    };
    Ubiquitty::Linux::CursorOverlay cursor;
    cursor.visible = true;
    cursor.blinkAlpha = 1.0f;
    cursor.focused = true;
    struct CursorCase {
        const char* name;
        const char* sequence;
        Ubiquitty::Cursor::Shape shape;
        bool shouldCapture;
    };
    const std::array<CursorCase, 3> cases { {
        { "ordinary block skips capture", "\x1b[2 q", Ubiquitty::Cursor::Shape::Block, false },
        { "ordinary underline skips capture", "\x1b[4 q", Ubiquitty::Cursor::Shape::Underline, false },
        { "ordinary bar skips capture", "\x1b[6 q", Ubiquitty::Cursor::Shape::Bar, false },
    } };
    for (const auto& testCase : cases) {
        Ubiquitty::processBytes(term, testCase.sequence);
        cursor.shape = testCase.shape;
        check(testCase.name, capturePaneRichText(pane, &cursor, 0) == testCase.shouldCapture);
    }
    cursor.visible = false;
    check("hidden bar skips capture", !capturePaneRichText(pane, &cursor, 0));

    // Keep an active-screen block in history while the ordinary bar remains on
    // the live screen. The block keeps the capture; the bar outside it stays
    // the grid's, GTK's caret drawn by the cursor tier.
    Ubiquitty::processBytes(term, "\x1b[H\x1b]7404;g=1:C=1:i=1:w=12:h=2;{\\rtf1 rich text}\x1b\\\x1b[8;1H");
    for (int row = 0; row < 8; ++row)
        Ubiquitty::processBytes(term, "\r\n");
    Ubiquitty::processBytes(term, "\x1b[8;4H");
    cursor.visible = true;
    const auto blocks = term->richTextBlocks.blocks(Ubiquitty::RichText::activeScreen(*term));
    check("active block is offscreen", blocks.size() == 1 && blocks.front().row + blocks.front().height <= 0);
    check("offscreen block keeps the ordinary bar the grid's", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && !pane.richTextFrame.hasRichTextCaret() && pane.richTextFrame.inputs().cursor.shape == Ubiquitty::Cursor::Shape::Bar && pane.richTextFrame.inputs().cursor.row == 7 && pane.richTextFrame.inputs().cursor.column == 3 && pane.richTextFrame.inputs().cursor.richTextOffset == 0);
    Ubiquitty::Linux::CursorOverlay hiddenCursor;
    std::vector<std::uint8_t> pixels;
    std::vector<std::uint8_t> barPixels;
    int width = 0;
    int height = 0;
    const bool didRasterize = app().rasterContext.rasterizeTerm(term, pixels, width, height, 0, nullptr, &hiddenCursor)
        && app().rasterContext.rasterizeTerm(term, barPixels, width, height, 0, nullptr, &cursor);
    auto compositedPixels = barPixels;
    pane.richText.composite(pane.richTextFrame, compositedPixels, width, height, {}, false);
    check("offscreen block leaves the ordinary caret to the grid", didRasterize && barPixels != pixels && compositedPixels == barPixels);
    cursor.visible = false;
    check("offscreen block retains hidden-cursor capture", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && pane.richTextFrame.inputs().cursor.row < 0);
    Ubiquitty::processBytes(term, "\x1b]7404;a=d:i=1;\x1b\\");
    check("removed offscreen block permits skip", !capturePaneRichText(pane, &cursor, 0));

    constexpr std::string_view placeBlock = "\x1b[H\x1b]7404;g=1:C=1:i=1:w=12:h=2;{\\rtf1 rich text}\x1b\\";
    Ubiquitty::processBytes(term, placeBlock);
    Ubiquitty::Selection::init(pane.selection);
    Ubiquitty::Selection::beginGesture(pane.selection, *term, 0, 0, 1, 0, {});
    Ubiquitty::Selection::dragGesture(pane.selection, *term, 2, 0, 0);
    check("visible selected block captures", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().size() == 1 && !pane.richTextFrame.richTextHighlights().empty());
    // The grid's frames draw the shared translucent tint over a selection; a
    // block's bands take the same fill, or the two meet in different tones.
    const Ubiquitty::Rendering::OverlayColor tint = Ubiquitty::Rendering::selectionHighlightColor();
    check("a block's selection bands take the grid's tint",
        !pane.richTextFrame.inputs().isSelectionBehindText && !pane.richTextFrame.richTextHighlights().empty()
            && pane.richTextFrame.richTextHighlights().front().alpha == tint.alpha
            && pane.richTextFrame.richTextHighlights().front().red == tint.red);
    check("visible block grid renders", app().rasterContext.rasterizeTerm(term, pixels, width, height, 0, nullptr, &hiddenCursor));
    const auto rastersBefore = pane.richText.rasterCount();
    pane.richText.composite(pane.richTextFrame, pixels, width, height, {}, false);
    check("visible block creates a retained raster", pane.richText.rasterCount() > rastersBefore);
    Ubiquitty::processBytes(term, "\x1b]7404;a=d:i=1;\x1b\\");
    check("removed visible block gets a cleanup capture", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && pane.richTextFrame.richTextHighlights().empty());
    const auto cleanedPixels = pixels;
    pane.richText.composite(pane.richTextFrame, pixels, width, height, {}, false);
    check("cleanup composites no stale rich text", pixels == cleanedPixels);
    check("cleaned frame skips subsequent captures", !capturePaneRichText(pane, &cursor, 0));

    Ubiquitty::Selection::init(pane.selection);
    Ubiquitty::processBytes(term, placeBlock);
    check("primary block captures again", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().size() == 1);
    Ubiquitty::processBytes(term, "\x1b[?1049h");
    check("screen switch clears previous rich frame", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().empty() && pane.richTextFrame.richTextHighlights().empty());
    pane.richText.composite(pane.richTextFrame, pixels, width, height, {}, false);
    check("inactive-screen block does not force captures", !capturePaneRichText(pane, &cursor, 0));
    Ubiquitty::processBytes(term, "\x1b[?1049l");
    check("returning to primary restores rich capture", capturePaneRichText(pane, &cursor, 0) && pane.richTextFrame.richTextQuads().size() == 1);
    return didPass ? 0 : 1;
}
