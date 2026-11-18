// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-select-all — Ctrl+Shift+A select-all: a distinctive first line is pushed
// into SCROLLBACK and a distinctive last line stays on screen; assert the facade's
// whole-buffer selection copies both (proving it reaches past the visible grid).
/// Checks that whole-buffer selection includes scrollback and visible text.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeSelectAll()
{
    setupFonts();
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-select-all: no term\n");
        return 1;
    }
    Ubiquitty::processBytes(term, "FIRSTLINE\n"); // scrolls into history
    for (int i = 0; i < startupRows + 5; ++i)
        Ubiquitty::processBytes(term, "filler\n");
    Ubiquitty::processBytes(term, "LASTLINE"); // on the live screen
    selectAll();
    const std::string all = selectionText();
    const bool hasFirst = all.find("FIRSTLINE") != std::string::npos; // from scrollback
    const bool hasLast = all.find("LASTLINE") != std::string::npos; // from the screen
    const bool didPass = hasFirst && hasLast;
    g_print("smoke-select-all: first=%d last=%d -- %s\n", static_cast<int>(hasFirst), static_cast<int>(hasLast), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
