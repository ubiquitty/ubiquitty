// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-titlebuild — the rich window title's platform-resolved leading directory
// segment (the only non-portable bit; formatChain/formatTitle are host-tested Core),
// plus a sanity check that formatTitle assembles the segments. The live process
// chain needs a real PTY and is verified by hand.
/// Checks status-bearing title composition against pane state.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeStatusTitle()
{
    activePane()->session->start(startupRows, startupColumns);
    auto* terminal = activePane()->session->terminal();
    if (!terminal) {
        return 1;
    }
    (void)Ubiquitty::Preferences::configure("[title]\ntab_dimensions = false\ntab_program_status = true\n", Ubiquitty::Preferences::ParseMode::Strict);
    Ubiquitty::processBytes(terminal, "\x1b]2;Build\x07\x1b]21337;indicator=#5f87ff;status=Waiting\x07");
    bool didPass = buildTabLabel(*activePane(), 0).find("Waiting") != std::string::npos;
    activePane()->hasUnheardBell = true;
    didPass = didPass && buildTabLabel(*activePane(), 0).starts_with("🔔 ");
    (void)Ubiquitty::Preferences::configure("[title]\ntab_dimensions = false\ntab_program_status = false\n", Ubiquitty::Preferences::ParseMode::Strict);
    didPass = didPass && buildTabLabel(*activePane(), 0).find("Waiting") == std::string::npos;
    onFocusEnter(nullptr, nullptr);
    didPass = didPass && !activePane()->hasUnheardBell && !buildTabLabel(*activePane(), 0).starts_with("🔔 ");
    g_print("smoke-status-title: %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
