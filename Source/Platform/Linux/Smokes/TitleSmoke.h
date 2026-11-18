// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Feed OSC 0 (set icon + window title) and assert Core flagged the change and
// stored the UTF-8 title — the dynamic-title wiring's Core half.
/// Checks that OSC 0 stores the title and marks it changed.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeTitle()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-title: no term\n");
        return 1;
    }
    const char osc[] = "\x1b]0;hello\x07";
    Ubiquitty::processBytes(term, std::string_view(osc, sizeof(osc) - 1));
    const bool didPass = term->titleChanged && term->titleUTF8 == "hello";
    g_print("smoke-title: titleChanged=%d titleUTF8=\"%s\" -- %s\n", static_cast<int>(term->titleChanged), term->titleUTF8.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
