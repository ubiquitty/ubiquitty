// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-trigger — a configured trigger's action reaches the frontend and runs.
//
// Core's engine classifies a match and hands the action to Terminal::triggerClient;
// an unset client makes it drop the action silently. That was this frontend's
// state, and it is the shape a test has to be able to see: the rules parsed, the
// startup line said how many were installed, and nothing happened.
//
// Copy is the action asserted because it is the one observable headlessly —
// Clipboard::lastSetText is the same capture seam smoke-osc52 reads. Notify and
// set_title need a live GApplication and window; run_command and webhook are
// gated shut by default and are checked here for that rather than for firing.
/// Checks that a configured trigger reaches its frontend action.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeTrigger()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-trigger: FAILED — no term\n");
        return 1;
    }
    // The fixture text carries no FAIL token on purpose: this smoke prints the
    // clipboard it captured, and check-linux-smokes reads a printed FAIL as a
    // verdict contradicting a zero exit. Test data that spells a verdict word
    // becomes one by the time it reaches the log.
    bool isRuleInstalled = false;
    {
        const PaneModelWrite write(*activePane()->session);
        isRuleInstalled = Ubiquitty::Triggers::addRuleSpec(term, "BUILD BROKE: [a-z]+", "copy", Ubiquitty::CaseSensitivity::Sensitive);
    }
    if (!isRuleInstalled) {
        g_printerr("smoke-trigger: FAILED — the rule did not install\n");
        return 1;
    }
    (void)activePane()->session->installTriggerQueue();
    PaneDelivery triggerDelivery;
    triggerDelivery.hasTriggerMatches = true;

    int failures = 0;

    // A line the rule does not match, fed first: it establishes that what the
    // matching line writes came from the match rather than from any line
    // arriving at all.
    {
        const PaneModelWrite write(*activePane()->session);
        Ubiquitty::processBytes(term, std::string_view("all tests passed\r\n"));
    }
    servicePaneQueues(*activePane(), triggerDelivery);
    const std::string afterMiss = Ubiquitty::Linux::Clipboard::lastSetText();
    g_print("  non-matching line -> clipboard \"%s\"\n", afterMiss.c_str());
    if (!afterMiss.empty()) {
        g_printerr("smoke-trigger: FAILED — a line matching no rule wrote the clipboard\n");
        ++failures;
    }

    {
        const PaneModelWrite write(*activePane()->session);
        Ubiquitty::processBytes(term, std::string_view("BUILD BROKE: linker\r\n"));
    }
    servicePaneQueues(*activePane(), triggerDelivery);
    const std::string afterMatch = Ubiquitty::Linux::Clipboard::lastSetText();
    g_print("  matching line     -> clipboard \"%s\"\n", afterMatch.c_str());
    if (afterMatch.find("BUILD BROKE: linker") == std::string::npos) {
        g_printerr("smoke-trigger: FAILED — the copy action did not reach the clipboard\n");
        ++failures;
    }

    // The two gated actions, asserted closed rather than asserted firing. Both
    // default to false in Core, and a frontend that spawned or posted without
    // asking would pass every other check here.
    const bool didAllowRun = Ubiquitty::Preferences::Effective::allowRunCommand(Ubiquitty::Preferences::values());
    const bool didAllowWebhook = Ubiquitty::Preferences::Effective::allowWebhook(Ubiquitty::Preferences::values());
    g_print("  gates: allow_run_command=%s allow_webhook=%s\n",
        didAllowRun ? "true" : "false", didAllowWebhook ? "true" : "false");
    if (didAllowRun || didAllowWebhook) {
        g_printerr("smoke-trigger: FAILED — a gated action is open by default\n");
        ++failures;
    }

    if (failures) {
        g_printerr("smoke-trigger: FAILED — %d check(s)\n", failures);
        return 1;
    }
    g_print("smoke-trigger: PASS (copy reached the clipboard, a non-matching line did not,"
            " both gated actions closed)\n");
    return 0;
}
