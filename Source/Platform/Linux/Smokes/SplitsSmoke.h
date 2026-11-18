// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-splits — the split lifecycle headlessly (app().window/app().paneContainer null, so
// attachPaneControllers + rebuildPaneTree are no-operations and renderPaneInto bails): the
// real splitFocusedPaneUX / moveFocusUX / closeFocusedPaneUX with LAUNCHED panes.
// Verifies per-pane PTY launch + fd-source registration, registry stability across
// growth (the non-movable invariant), Workspace<->registry lockstep on split, spatial
// moveFocus, the collapse + source teardown on close, and the last-pane escalation.
/// Checks split creation, focus movement and teardown with real pane processes.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokeSplits()
{
    setupFonts();
    bool ok = true;
    auto check = [&](bool didPass, const char* what) {
        if (!didPass) {
            g_printerr("smoke-splits: FAIL: %s\n", what);
            ok = false;
        }
    };
    if (!launchShell()) {
        g_printerr("smoke-splits: FAIL: launch default pane\n");
        return 1;
    }
    const SurfaceID surface = app().model->activeSurface();
    auto paneCount = [&]() {
        const Panes::Tree* tree = app().model->paneTree(surface);
        return tree != nullptr ? tree->paneCount() : 0;
    };
    const PaneID firstPane = app().model->focusedPane(surface);
    const LinuxPane* firstPaneAddress = activePane();
    check(paneCount() == 1, "one pane initially");

    // (1) Split side-by-side: a new launched pane, focused, distinct + monotonic id,
    // its own live descriptor + drain source, and the first pane's address STABLE.
    splitFocusedPaneUX(Panes::Orientation::Vertical);
    const PaneID pane2 = app().model->focusedPane(surface);
    const auto deliverBackgroundOutput = [&] {
        LinuxPane* background = paneForID(firstPane);
        PaneDelivery delivery;
        delivery.didOutputArrive = true;
        delivery.history = background->session->readSnapshot().history;
        app().isRepaintPending = false;
        applyPaneDelivery(*background, delivery);
    };
    deliverBackgroundOutput();
    check(app().isRepaintPending, "output in a visible unfocused split requests a frame");
    check(paneCount() == 2, "two panes after split");
    check(app().panes.size() == 2 && app().paneByID.size() == 2, "two live panes tracked");
    check(pane2 != invalidPane && pane2 != firstPane && pane2 > firstPane, "new PaneID distinct + monotonic");
    check(activePane() == paneForID(pane2), "split focuses the new pane");
    check(activePane()->session->fileDescriptor() >= 0 && activePane()->ptySource != 0, "new pane has its own live descriptor + source");
    check(paneForID(firstPane) == firstPaneAddress, "first pane address stable across growth");

    // (2) moveFocus across the vertical divider returns to the original (left) pane.
    moveFocusUX(Panes::Direction::Left);
    check(activePane() == paneForID(app().model->focusedPane(surface)), "moveFocus follows the model");
    check(activePane() == firstPaneAddress, "moveFocus Left reaches the original pane");

    // (3) A split tab remembers which of its panes had focus across a tab
    // round-trip. Focus is left on the first pane above, so a switch away and back
    // must land there and not on the split's newer pane — the case that
    // distinguishes activating a tab from naming a pane inside it.
    const TabID splitTab = app().model->activeTab(surface);
    newTab();
    const TabID extraTab = app().model->activeTab(surface);
    deliverBackgroundOutput();
    check(!app().isRepaintPending, "output in a hidden tab does not restart the frame clock");
    check(extraTab != splitTab, "newTab left the split tab");
    switchToTab(splitTab);
    check(activePane() == firstPaneAddress, "the split tab restored ITS focused pane");
    check(paneCount() == 2, "back to the split tab with both panes");
    switchToTab(extraTab);
    closePaneTab(activePane());
    check(app().model->activeTab(surface) == splitTab && paneCount() == 2, "closing the extra tab returns to the split one");

    // (4) Split again to three panes.
    splitFocusedPaneUX(Panes::Orientation::Horizontal);
    const PaneID pane3 = app().model->focusedPane(surface);
    check(paneCount() == 3, "three panes after second split");
    check(app().panes.size() == 3 && pane3 != firstPane && pane3 != pane2 && pane3 > pane2, "third pane distinct + monotonic");

    // (5) Close the focused pane: collapse one level, registry shrinks, the closed
    // pane is gone, and focus moves to a neighbor leaf.
    const PaneID closed = app().model->focusedPane(surface);
    closeFocusedPaneUX();
    check(paneCount() == 2, "two panes after close");
    check(app().panes.size() == 2 && app().paneByID.size() == 2, "registry shrank on close");
    check(paneForID(closed) == nullptr, "closed pane dropped from the registry");
    check(activePane() != nullptr && activePane() == paneForID(app().model->focusedPane(surface)), "focus moved to a neighbor leaf");

    // (6) Close down to one pane; the last pane escalates to the tab/window-close path
    // (app().window null → a model no-op, must not drop below one pane).
    closeFocusedPaneUX();
    check(paneCount() == 1, "one pane after second close");
    closeFocusedPaneUX();
    check(paneCount() == 1 && app().panes.size() == 1, "last pane survives close (window-close path)");

    // End the surface's sessions through the model before the pane views die
    // — a Terminal must never outlive the pane clients it references.
    if (activePane() && activePane()->ptySource != 0) {
        g_source_remove(activePane()->ptySource);
        activePane()->ptySource = 0;
    }
    app().model->closeWindowSurface(surface);
    app().panes.clear();
    app().paneByID.clear();
    g_print("smoke-splits: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
