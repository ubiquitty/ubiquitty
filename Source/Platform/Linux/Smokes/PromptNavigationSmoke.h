// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-prompt-navigation — Ctrl+Shift+Up/Down jump-to-prompt: build scrollback, mark a
// history row as a command-executed prompt, assert jump-previous scrolls to it and
// jump-next (no prompt below) snaps back to the live tail.
/// Checks navigation between prompt markers and the live tail.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokePromptNavigation()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-prompt-navigation: no term\n");
        return 1;
    }
    for (int i = 0; i < startupRows + 10; ++i) // push lines into scrollback
        Ubiquitty::processBytes(term, "line\n");
    const int history = Ubiquitty::Screen::scrollbackCount(term);
    if (history < 2) {
        g_printerr("smoke-prompt-navigation: FAIL (no scrollback: %d)\n", history);
        return 1;
    }
    const int markRow = 1; // an early history row
    Ubiquitty::Screen::addRowMark(term, markRow, Ubiquitty::Screen::osc133MarkCmdExecuted);
    activePane()->viewOffset = 0; // live tail
    activePane()->promptNavigationRow = -1;
    jumpToPrompt(-1); // previous prompt → scroll to markRow
    const bool didJump = activePane()->viewOffset > 0 && activePane()->promptNavigationRow == markRow;
    jumpToPrompt(+1); // none below → snap to the live tail
    const bool didSnap = activePane()->viewOffset == 0;
    const bool didPass = didJump && didSnap;
    g_print("smoke-prompt-navigation: jumped=%d snapped=%d -- %s\n", static_cast<int>(didJump), static_cast<int>(didSnap), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
