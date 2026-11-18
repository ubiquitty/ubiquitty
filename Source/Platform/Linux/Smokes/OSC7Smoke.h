// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Feed an OSC 7 and assert the pane recorded the directory the shell named.
//
// The wiring this covers fails silently when it is wrong: a Terminal that
// drops OSC 7 leaves the title to the /proc read, which answers something
// plausible for the wrong process. So the assertion is that the ANNOUNCED
// directory arrived in the session's answer, not that a directory exists.
/// Checks that the directory reported by OSC 7 reaches the pane.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeOSC7()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-osc7: no term\n");
        return 1;
    }
    const char osc[] = "\x1b]7;file://host/tmp/announced\x07";
    Ubiquitty::processBytes(term, std::string_view(osc, sizeof(osc) - 1));
    term->capabilityPolicy = nullptr;

    const std::string announced = activePane()->session->currentDirectory();
    const bool didPass = announced.find("/tmp/announced") != std::string::npos;
    g_print("smoke-osc7: announced directory = \"%s\" -- %s (expected to contain \"/tmp/announced\")\n",
        announced.c_str(), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
