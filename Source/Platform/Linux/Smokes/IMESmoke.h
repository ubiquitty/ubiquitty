// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-ime — the IME inline-preedit plumbing (Stage 12). Feeds "abc" (cursor →
// column 3), sets a pre-edit, and asserts the shared snapshotVisibleGrid overlays the
// composing codepoints underlined at the cursor (the path both render backends
// take), that clearing restores the cells, and that the UTF-8 → codepoint decode
// the commit/preedit handlers use round-trips a multibyte string. The live IM
// (ibus/fcitx) interaction needs a display + IM module and is verified by hand.
/// Checks inline preedit overlays and multibyte input decoding.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeIME()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-ime: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "abc"); // cursor now at row 0, column 3
    const int cursorColumn = term->screens.active->cursorX;

    // Inline preedit: two ASCII codepoints injected at the cursor, underlined.
    const std::uint32_t preedit[] = { 'n', 'i' };
    app().rasterContext.setPreedit(preedit, 2);
    std::vector<Ubiquitty::Cell> grid;
    app().rasterContext.snapshotVisibleGrid(term, 0, grid);
    const Ubiquitty::Cell& c0 = grid[static_cast<size_t>(cursorColumn)];
    const Ubiquitty::Cell& c1 = grid[static_cast<size_t>(cursorColumn) + 1];
    const bool isInjected = c0.codePoint == 'n' && Ubiquitty::cellPen(c0).attributes.contains(Ubiquitty::VT::Attribute::Underline) && c1.codePoint == 'i' && Ubiquitty::cellPen(c1).attributes.contains(Ubiquitty::VT::Attribute::Underline);

    // Clearing the preedit restores the (blank) cells under it.
    app().rasterContext.setPreedit(nullptr, 0);
    app().rasterContext.snapshotVisibleGrid(term, 0, grid);
    const bool cleared = grid[static_cast<size_t>(cursorColumn)].codePoint == 0;

    // The UTF-8 decode the handlers use: "ní好" → 'n', U+00ED, U+597D.
    const std::vector<std::uint32_t> decoded = codePointsFromUTF8("n\xC3\xAD\xE5\xA5\xBD");
    const bool didDecode = decoded.size() == 3 && decoded[0] == 'n' && decoded[1] == 0x00ED && decoded[2] == 0x597D;

    const bool didPass = isInjected && cleared && didDecode;
    g_print("smoke-ime: preedit injected=%d cleared=%d utf8-decode=%d (n=%zu) -- %s\n", static_cast<int>(isInjected), static_cast<int>(cleared), static_cast<int>(didDecode), decoded.size(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
