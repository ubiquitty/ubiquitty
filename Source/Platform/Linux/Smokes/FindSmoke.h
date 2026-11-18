// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-find — the find-bar search path (Stage 13). Feeds 40 numbered lines,
// then drives the same runSearch / step logic the GtkSearchEntry signals use
// (no GTK widgets needed — showSearchOutcome skips a null label), and
// asserts: a unique pattern yields 1 match whose highlighted visible row actually
// reads that text (scroll-to + selection landed right); a shared prefix yields the
// right count; next/prev step + wrap the active index; a bad pattern returns -1;
// an empty pattern clears the search + highlight.
/// Checks search results, navigation, invalid patterns and cleared highlights.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeFind()
{
    activePane()->session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = activePane()->session->terminal();
    if (!term) {
        g_printerr("smoke-find: no term\n");
        return 1;
    }
    std::string feed;
    for (int i = 0; i < 40; ++i) {
        char line[16];
        std::snprintf(line, sizeof(line), "line%02d\r\n", i);
        feed += line;
    }
    Ubiquitty::processBytes(term, feed);

    // A selection the user made before searching. It must survive every search
    // below: the match's emphasis is its own bake, so nothing here has cause to
    // touch the selection, and a find bar that clears it destroys work.
    activePane()->selection.state.active = true;
    activePane()->selection.state.mode = Ubiquitty::SelectionMode::Character;
    activePane()->selection.state.anchorRow = 0;
    activePane()->selection.state.anchorColumn = 0;
    activePane()->selection.state.headRow = 0;
    activePane()->selection.state.headColumn = 3;

    // Unique match: count 1, and the row the builder is told to bake reads
    // "line05". Asserted on the spans themselves rather than on the selection —
    // the spans are what reaches the renderer, so a proxy that stopped tracking
    // them would pass while nothing was emphasised.
    Ubiquitty::Runtime::TerminalSession* session = activePane()->session;
    const auto unique = runSearchAndWait(session, "line05");
    std::vector<Ubiquitty::Rendering::SelectionRowSpan> searchSpans;
    const auto collectSpans = [&] {
        const auto hold = holdPaneModel(*activePane());
        Ubiquitty::Rendering::collectSearchMatchRowSpans(*term, activePane()->viewOffset, searchSpans);
    };
    collectSpans();
    const std::string highlighted = searchSpans.empty() ? std::string() : visibleRowText(*term, activePane()->viewOffset, searchSpans[0].visibleRow, 6);
    const bool didFindUniqueMatch = unique.foundCount == 1 && searchSpans.size() == 1 && highlighted == "line05";

    // Shared prefix "line0" → line00..line09 = 10 matches, active starts at 0.
    const auto prefix = runSearchAndWait(session, "line0");
    const bool didCountPrefixMatches = prefix.foundCount == 10 && prefix.activeIndex == 0;

    // next steps forward; prev steps back, and from index 0 wraps to the last
    // (9). The same pattern again would not reset the active index: a repeated
    // request does not restart the search, so the walk back goes through 0.
    const bool didStepToNext = onSearchStep(session, Ubiquitty::Runtime::TerminalSession::SearchStep::Forward).activeIndex == 1;
    const bool didStepBack = onSearchStep(session, Ubiquitty::Runtime::TerminalSession::SearchStep::Backward).activeIndex == 0;
    const bool didWrapToLast = didStepBack && onSearchStep(session, Ubiquitty::Runtime::TerminalSession::SearchStep::Backward).activeIndex == 9;

    const auto bad = runSearchAndWait(session, "[unterminated");
    collectSpans();
    const bool didRejectBadPattern = bad.isPatternInvalid && searchSpans.empty();

    const auto empty = runSearchAndWait(session, "");
    collectSpans();
    const bool didClearOnEmpty = empty.foundCount == 0 && searchSpans.empty();

    // The selection set before the first search is still exactly where it was.
    const bool didKeepSelection = activePane()->selection.state.active && activePane()->selection.state.headColumn == 3;

    const bool didPass = didFindUniqueMatch && didCountPrefixMatches && didStepToNext && didWrapToLast && didRejectBadPattern && didClearOnEmpty && didKeepSelection;
    g_print("smoke-find: unique=%d(\"%s\") prefix=%d next=%d wrap=%d bad=%d empty=%d selection-kept=%d -- %s\n", static_cast<int>(didFindUniqueMatch), highlighted.c_str(), static_cast<int>(didCountPrefixMatches), static_cast<int>(didStepToNext), static_cast<int>(didWrapToLast), static_cast<int>(didRejectBadPattern), static_cast<int>(didClearOnEmpty), static_cast<int>(didKeepSelection), didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
