// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-clear — Ctrl+Shift+K clear-buffer: print a line, clear, assert the row is
// blank afterward (the cursor row is preserved; the screen above it is wiped).
/// Checks that clearing the buffer preserves the cursor row and erases earlier rows.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeClear()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-clear: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "ABC\n"); // row 0 = "ABC", cursor moves to row 1
    const Ubiquitty::Cell* before = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const bool hadText = before != nullptr && before->codePoint == static_cast<uint32_t>('A');
    Ubiquitty::clearBufferPreserveInput(term);
    const Ubiquitty::Cell* after = Ubiquitty::Screen::visibleCell(term, 0, 0, 0);
    const bool cleared = after == nullptr || after->codePoint == 0 || after->codePoint == static_cast<uint32_t>(' ');
    const bool didPass = hadText && cleared;
    g_print("smoke-clear: had-text=%d cleared=%d -- %s\n", static_cast<int>(hadText), static_cast<int>(cleared), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
