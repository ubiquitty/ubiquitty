// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Feed 40 numbered lines, then assert a scrolled-back view shows an OLDER top row
// than the live tail. Pure Core content assertion — no display / renderer needed.
// 40 lines into a 24-row screen pushes the older ones into history; scrolling up
// by N reveals a top row N lines older than the live-tail top row. A pane held
// there keeps that top row in the frame renderPaneInto reads while rows arrive
// that its delivery has not handed it yet.
/// Checks that a held viewport preserves older rows as output arrives.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeScrollback()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-scrollback: no term\n");
        return 1;
    }
    std::string feed;
    for (int i = 0; i < 40; ++i) {
        char line[16];
        std::snprintf(line, sizeof(line), "line%02d\r\n", i);
        feed += line;
    }
    Ubiquitty::processBytes(term, feed);

    const int historyDepth = Ubiquitty::Screen::scrollbackCount(term);
    if (historyDepth <= 0) {
        g_printerr("smoke-scrollback: FAIL (scrollbackCount=%d, expected > 0)\n", historyDepth);
        return 1;
    }

    constexpr int probeOffsetLines = 4; // scroll 4 lines up into history
    const int probeOffset = probeOffsetLines <= historyDepth ? probeOffsetLines : historyDepth;
    const std::string topAtTail = visibleRowText(*term, 0, 0, 6);
    const std::string topAtHistory = visibleRowText(*term, probeOffset, 0, 6);

    // The lines are numbered, so the history top row must read exactly probeOffset
    // lines older than the live-tail top row ("lineNN" - probeOffset).
    const int tailLineNumber = std::atoi(topAtTail.c_str() + 4); // skip "line"
    char expectedHistory[16];
    std::snprintf(expectedHistory, sizeof(expectedHistory), "line%02d", tailLineNumber - probeOffset);

    const bool didPass = topAtTail != topAtHistory && topAtTail.starts_with("line") && topAtHistory == expectedHistory;
    g_print("smoke-scrollback: scrollbackCount=%d, top row offset 0 = \"%s\", offset %d = \"%s\" -- %s\n", historyDepth, topAtTail.c_str(), probeOffset, topAtHistory.c_str(), didPass ? "PASS" : "FAIL");
    if (!didPass)
        g_printerr("smoke-scrollback: offset %d expected \"%s\" (%d lines older than the tail)\n", probeOffset, expectedHistory, probeOffset);

    // The pane measured at that offset, then rows the ingest thread parsed
    // before a delivery: the frame stands over them, on the row it showed.
    LinuxPane& pane = *activePane();
    pane.viewOffset = probeOffset;
    static_cast<void>(Ubiquitty::Selection::viewportAfterOutput(pane.selection, pane.viewOffset, Ubiquitty::Input::OutputSnapPolicy::Indeterminate,
        Ubiquitty::Screen::historyFacts(term)));
    Ubiquitty::processBytes(term, "arrived0\r\narrived1\r\narrived2\r\n");
    const int frameOffset = paneFrameViewOffset(pane, *term);
    const std::string topInFrame = visibleRowText(*term, frameOffset, 0, 6);
    const bool doesFrameHoldRows = frameOffset == probeOffset + 3 && topInFrame == topAtHistory;
    g_print("smoke-scrollback: held at offset %d over 3 rows not yet delivered, frame offset %d, top row = \"%s\" -- %s\n", probeOffset,
        frameOffset, topInFrame.c_str(), doesFrameHoldRows ? "PASS" : "FAIL");
    // A compositor consumes the workspace number after Super goes down.
    // Receiving that bare modifier and a focus-out/in must preserve the view,
    // including when Kitty explicitly asks for modifier reports.
    const auto savedModes = pane.modes;
    const bool wasScrollOnKeypressEnabled = term->modes.scrollOnKeypress;
    term->modes.scrollOnKeypress = true;
    pane.viewOffset = probeOffset;
    onKeyPressed(nullptr, GDK_KEY_Super_L, 0, GDK_SUPER_MASK, nullptr);
    onFocusLeave(nullptr, nullptr);
    onFocusEnter(nullptr, nullptr);
    const bool doesWorkspaceSwitchHold = pane.viewOffset == probeOffset;
    pane.modes.kittyKeyboardFlags = { 8, 8 }; // REPORT_ALL includes bare modifiers.
    onKeyPressed(nullptr, GDK_KEY_Super_L, 0, GDK_SUPER_MASK, nullptr);
    const bool doesReportedModifierHold = pane.viewOffset == probeOffset;
    pane.modes = savedModes;
    onKeyPressed(nullptr, GDK_KEY_a, 0, static_cast<GdkModifierType>(0), nullptr);
    const bool doesTypingSnap = pane.viewOffset == 0;
    pane.viewOffset = probeOffset;
    term->modes.scrollOnKeypress = false;
    onKeyPressed(nullptr, GDK_KEY_b, 0, static_cast<GdkModifierType>(0), nullptr);
    const bool doesDisabledPolicyHold = pane.viewOffset == probeOffset;
    term->modes.scrollOnKeypress = wasScrollOnKeypressEnabled;
    const bool doesInputPolicyPass = doesWorkspaceSwitchHold && doesReportedModifierHold && doesTypingSnap && doesDisabledPolicyHold;
    g_print("smoke-scrollback: workspace-switch=%d reported-modifier=%d typing-snaps=%d disabled-policy=%d -- %s\n",
        doesWorkspaceSwitchHold, doesReportedModifierHold, doesTypingSnap, doesDisabledPolicyHold, doesInputPolicyPass ? "PASS" : "FAIL");
    return didPass && doesFrameHoldRows && doesInputPolicyPass ? 0 : 1;
}
