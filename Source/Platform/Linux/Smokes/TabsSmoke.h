// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The headless tab lifecycle uses real PTYs without creating a GTK window.
/// Checks tab creation, selection and teardown without a GTK window.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeTabs()
{
    setupFonts(); // valid cell dims for the per-pane setWindowSize
    bool ok = true;
    auto check = [&](bool didPass, const char* what) {
        if (!didPass) {
            g_printerr("smoke-tabs: FAIL: %s\n", what);
            ok = false;
        }
    };
    // (1) Open the window's surface through the model: one tab, a launched
    // root pane, a live PTY fd, a registered drain source.
    if (!launchShell()) {
        g_printerr("smoke-tabs: FAIL: launch default pane\n");
        return 1;
    }
    const SurfaceID surface = app().model->activeSurface();
    const PaneID firstPane = app().model->focusedPane(surface);
    const TabID firstTab = app().model->activeTab(surface);
    const LinuxPane* firstPaneAddress = activePane();
    const int firstFileDescriptor = activePane()->session->fileDescriptor();
    check(app().model->tabCount(surface) == 1, "one tab after default");
    check(paneForID(firstPane) == activePane(), "default pane mapped to its PaneID");
    check(firstFileDescriptor >= 0, "default pane has a live PTY descriptor");
    check(activePane()->ptySource != 0, "default pane registered its drain source");

    // (2) newTab twice: real launches, distinct descriptors + sources, the model +
    // registry grow in lockstep, PaneIDs are distinct + monotonic, and the first
    // pane's heap address is STABLE across the vector growth (non-movable invariant).
    newTab();
    const PaneID pane2 = app().model->focusedPane(surface);
    const TabID tab2 = app().model->activeTab(surface);
    const LinuxPane* pane2Ptr = activePane();
    newTab();
    const PaneID pane3 = app().model->focusedPane(surface);
    check(app().model->tabCount(surface) == 3, "three tabs after two newTab");
    check(app().panes.size() == 3 && app().paneByID.size() == 3, "three live panes tracked");
    check(firstPane != pane2 && pane2 != pane3 && firstPane != pane3, "distinct PaneIDs");
    check(pane2 < pane3, "monotonic PaneIDs");
    check(activePane() == paneForID(pane3), "newTab focused the new pane");
    check(activePane()->session->fileDescriptor() >= 0 && activePane()->ptySource != 0, "new pane has its own live descriptor + source");
    check(paneForID(firstPane) == firstPaneAddress, "first pane address stable across growth");

    // (3) Switching moves the model's focus, which is what activePane() reads.
    switchToTab(firstTab);
    check(activePane() == paneForID(app().model->focusedPane(surface)) && activePane() == firstPaneAddress, "switch to tab 1 follows the model");
    switchTabRelative(+1); // -> tab 2
    check(activePane() == paneForID(pane2) && activePane() == pane2Ptr, "relative switch +1 -> tab 2");
    switchTabRelative(-1); // wrap/back -> tab 1
    check(activePane() == paneForID(firstPane), "relative switch -1 -> tab 1");

    // Fractional points survive both the DPI conversion and backing scale.
    const double savedPoints = app().fontSizePoints;
    const double savedDPI = app().fontDPI;
    const int savedScale = app().scale;
    app().fontDPI = 96;
    app().fontSizePoints = 15.5;
    app().scale = 2;
    const double halfPointAtTwo = deviceFontPixelSize();
    app().fontSizePoints = 16.0;
    const double wholePointAtTwo = deviceFontPixelSize();
    app().fontSizePoints = 15.0;
    const double belowAtTwo = deviceFontPixelSize();
    app().fontSizePoints = savedPoints;
    app().fontDPI = savedDPI;
    app().scale = savedScale;
    check(std::abs(halfPointAtTwo - 124.0 / 3.0) < 1e-12, "15.5pt at 96 DPI and 2x retains the fractional device em");
    check(belowAtTwo == 40 && std::abs(wholePointAtTwo - 128.0 / 3.0) < 1e-12, "whole points include both DPI and backing scale without rounding");

    // (3b) The ':' scope is a projection of the model above, so it is asserted
    // here where three real tabs exist rather than against a constructed one.
    //
    // Written to fail if the feature is removed: dropping `beamGoToCommands`
    // leaves `gotoRows` at zero, dropping the current-marker leaves
    // `gotoMarksOne` false, and dropping the accept arm in `runBeamAction`
    // leaves `gotoSwitched` false with the tab unmoved.
    switchToTab(firstTab);
    const Ubiquitty::CommandPalette::PaletteCommandList gotoRows = beamGoToCommands();
    check(gotoRows.size() == 3, "the goto scope lists all three tabs");
    // One pane per tab here, and a single pane is not a destination, so the
    // list is tabs alone — a pane row appearing would mean the suppression that
    // keeps a lone pane out of the list has gone.
    std::size_t gotoPaneRows = 0;
    std::size_t gotoCurrentRows = 0;
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : gotoRows) {
        if (row.id.starts_with(beamGoToPaneIDPrefix))
            ++gotoPaneRows;
        if (row.group.find("current") != std::string::npos)
            ++gotoCurrentRows;
    }
    check(gotoPaneRows == 0, "a lone pane is not offered as a destination");
    check(gotoCurrentRows == 1, "exactly one row is marked current");
    // And it is the ACTIVE tab that carries the marker, not merely some row —
    // a marker on a fixed position would satisfy the count above.
    const std::string firstTabRowID = beamGoToTabIDPrefix + std::to_string(static_cast<std::uint32_t>(firstTab));
    bool isActiveTabMarked = false;
    for (const Ubiquitty::CommandPalette::PaletteCommand& row : gotoRows) {
        if (row.id == firstTabRowID)
            isActiveTabMarked = row.group.find("current") != std::string::npos;
    }
    check(isActiveTabMarked, "the marked row is the active tab");

    // Accepting a row moves there. Driven through `runBeamAction` because that
    // is what the palette calls, so a dispatch that stopped recognising the
    // prefix fails here rather than only in a live window.
    using BeamActionKind = Ubiquitty::CommandPalette::BeamAction::Kind;
    Ubiquitty::CommandPalette::BeamAction gotoAccept;
    gotoAccept.kind = BeamActionKind::Run;
    gotoAccept.commandID = beamGoToTabIDPrefix + std::to_string(static_cast<std::uint32_t>(tab2));
    runBeamAction(gotoAccept);
    check(app().model->activeTab(surface) == tab2 && activePane() == pane2Ptr, "accepting a goto row switches to that tab");

    // An id no tab holds leaves the focus alone rather than moving somewhere.
    // `switchToTab` refuses an unknown handle, and this is the case that says so
    // through the palette's own path.
    gotoAccept.commandID = beamGoToTabIDPrefix + std::string("999999");
    runBeamAction(gotoAccept);
    check(app().model->activeTab(surface) == tab2, "an unknown goto id moves nothing");
    switchToTab(firstTab);

    // (4) Close the active tab: the source is torn down, the model + registry shrink,
    // and a neighbor is reselected.
    switchToTab(tab2);
    closePaneTab(activePane());
    check(app().model->tabCount(surface) == 2, "two tabs after close");
    check(app().panes.size() == 2 && app().paneByID.size() == 2, "two live panes after close");
    check(paneForID(pane2) == nullptr, "closed pane dropped from the registry");
    check(activePane() != nullptr && activePane() == paneForID(app().model->focusedPane(surface)), "active reselected to a neighbor after close");

    // (5) Close down to one; the last tab is the window-close path (app().window is null
    // here, so closePaneTab is a no-op on the model — it must not drop below one tab).
    closePaneTab(activePane());
    check(app().model->tabCount(surface) == 1, "one tab after second close");
    closePaneTab(activePane());
    check(app().model->tabCount(surface) == 1 && app().panes.size() == 1, "last tab survives closePaneTab");

    // Tear down the surviving pane's source, then end the surface's sessions
    // through the model before the pane views die — a Terminal must never
    // outlive the pane clients it references.
    if (activePane() && activePane()->ptySource != 0) {
        g_source_remove(activePane()->ptySource);
        activePane()->ptySource = 0;
    }
    app().model->closeWindowSurface(surface);
    app().panes.clear();
    app().paneByID.clear();
    g_print("smoke-tabs: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
