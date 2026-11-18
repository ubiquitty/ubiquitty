// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// `[cursor] alpha` reaches the frame: a bar drawn at half alpha is not the bar
// drawn solid. The CPU raster is the witness; its cursor colour carries the
// configured alpha, which the palette's three channels cannot. A bar rather
// than a block, because the focused block is the cell tier and the alpha is
// the overlay's.
/// Checks that configured cursor opacity reaches the rendered overlay.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeCursorAlpha()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-cursor-alpha: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, std::string_view(canned, sizeof(canned) - 1));
    const auto renderBlock = [term](const char* document, std::vector<uint8_t>& out) {
        (void)Ubiquitty::Preferences::configure(document, Ubiquitty::Preferences::ParseMode::Strict);
        Ubiquitty::Linux::CursorOverlay cursor;
        cursor.visible = true;
        cursor.shape = Ubiquitty::Cursor::Shape::Bar;
        cursor.blinkAlpha = 1.0f;
        cursor.focused = true;
        int width = 0;
        int height = 0;
        return app().rasterContext.rasterizeTerm(term, out, width, height, 0, nullptr, &cursor);
    };
    // The control first: the same document twice draws the same frame, so a
    // difference below is the alpha and nothing else.
    std::vector<uint8_t> solid;
    std::vector<uint8_t> solidAgain;
    std::vector<uint8_t> translucent;
    const bool didRender = renderBlock("[cursor]\nshape = \"bar\"\n", solid)
        && renderBlock("[cursor]\nshape = \"bar\"\n", solidAgain)
        && renderBlock("[cursor]\nshape = \"bar\"\nalpha = 128\n", translucent);
    (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);
    const bool isControlStable = solid == solidAgain;
    const bool doesAlphaReachTheFrame = solid.size() == translucent.size() && solid != translucent;
    const bool didPass = didRender && isControlStable && doesAlphaReachTheFrame;
    g_print("smoke-cursor-alpha: rendered=%d control-stable=%d alpha-differs=%d -- %s\n", didRender ? 1 : 0, isControlStable ? 1 : 0,
        doesAlphaReachTheFrame ? 1 : 0, didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
