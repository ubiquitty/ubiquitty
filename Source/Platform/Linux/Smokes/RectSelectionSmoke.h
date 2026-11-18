// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-rectsel — rectangular (column-block) selection (Stage 13). Feeds a 3x5
// grid, drives the same gesture path the Alternate-drag uses (hasAlternate → RECT), and
// asserts the extraction is the column block "BCD/GHI/LMN" (not the linear span a
// plain char-drag of the same endpoints would yield). The portable Selection model
// owns the RECT clip; this verifies the Linux frontend opts into it.
/// Checks extraction of a rectangular selection through the frontend gesture path.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeRectSelection()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-rectsel: no term\n");
        return 1;
    }
    const char* screen = "ABCDE\r\nFGHIJ\r\nKLMNO";
    Ubiquitty::processBytes(term, screen);

    // Alternate-drag from (0,1) to (2,3) through the facade: a rectangular
    // column-block selection, the style the ladder builds from hasAlternate.
    Ubiquitty::Selection::init(activePane()->selection);
    Ubiquitty::Selection::GestureStyle rectStyle;
    rectStyle.isRectangular = true;
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, rectStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 2, 3, 0);
    const bool isRect = Ubiquitty::Selection::isRectangular(&activePane()->selection.state);
    const std::string rectText = selectionText();

    // Same endpoints, plain char-drag (Alternate off) for contrast — a linear span.
    const Ubiquitty::Selection::GestureStyle plainStyle;
    Ubiquitty::Selection::beginGesture(activePane()->selection, *term, 0, 1, 1, 0, plainStyle);
    Ubiquitty::Selection::dragGesture(activePane()->selection, *term, 2, 3, 0);
    const std::string charText = selectionText();

    std::string rectShown = rectText;
    for (char& c : rectShown)
        if (c == '\n')
            c = '/';
    const bool didPass = isRect && rectText == "BCD\nGHI\nLMN" && charText != rectText;
    g_print("smoke-rectsel: isRect=%d rect=\"%s\" differs-from-linear=%d -- %s\n", static_cast<int>(isRect), rectShown.c_str(), static_cast<int>(charText != rectText), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
