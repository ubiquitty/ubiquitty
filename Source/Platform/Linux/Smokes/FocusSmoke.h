// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Focus reporting (DECSET 1004) self-test. Core writes focus reports into the
// Terminal's gtkApplication-bound reply buffer (outputBuffer), so this asserts directly on
// Core: with 1004 ON, setFocused(true)/false must emit CSI I then CSI O; with
// 1004 OFF, no focus bytes are emitted (Core still records windowFocused).
/// Checks focus-report bytes with focus reporting enabled and disabled.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeFocus()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-focus: no term\n");
        return 1;
    }

    // 1004 ON: drive focus in then out, capturing the gtkApplication-bound bytes each time.
    const char enable1004[] = "\x1b[?1004h";
    Ubiquitty::processBytes(term, std::string_view(enable1004, sizeof(enable1004) - 1));
    term->outputLength = 0; // discard any DECSET ack; isolate the focus bytes
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Focused);
    const std::string focusIn(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));
    term->outputLength = 0;
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Unfocused);
    const std::string focusOut(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));
    term->outputLength = 0;

    // 1004 OFF: focus transitions must emit nothing.
    const char disable1004[] = "\x1b[?1004l";
    Ubiquitty::processBytes(term, std::string_view(disable1004, sizeof(disable1004) - 1));
    term->outputLength = 0;
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Focused);
    activePane()->session->setDesiredFocus(Ubiquitty::Modes::FocusState::Unfocused);
    const std::string focusOff(term->outputBuffer.data(), static_cast<std::size_t>(term->outputLength));

    const bool didReportFocus = focusIn == "\x1b[I" && focusOut == "\x1b[O";
    const bool didSuppressFocusReport = focusOff.empty();
    g_print("smoke-focus: 1004 ON  focus-in=\"");
    printEscaped(focusIn);
    g_print("\" focus-out=\"");
    printEscaped(focusOut);
    g_print("\"\n");
    g_print("smoke-focus: 1004 OFF focus-in+out=\"");
    printEscaped(focusOff);
    g_print("\" (expected empty)\n");
    const bool didPass = didReportFocus && didSuppressFocusReport;
    g_print("smoke-focus: %s (expected ESC[I then ESC[O on; nothing off)\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
