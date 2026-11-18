// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Relative pointer lock (DECSET 7403) self-test. Headless, through the same
// TerminalSession wrappers main.cpp's PointerLock.cpp wiring calls -- not
// through a real GTK window, which would hide and warp the real cursor of
// whoever is running it. Four legs: the verdict follows mode + focus, a grab
// report reaches the ladder's release lesson, a motion delta is routed as an
// SGR report while a zero delta is swallowed, and the break-out chord held for
// the pinned tick threshold clears the mode.
/// Checks pointer-lock policy, reports and the release chord without capturing the pointer.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokePointerLock()
{
    // Legs 6 and 7 split panes, and binding a pane publishes its typography
    // from the selected face; the live window sets the faces up before any
    // pane exists, so this smoke does too.
    setupFonts();
    // Pinned for the whole test, not just the chord leg: the ladder captures
    // the chord's armedAtTicks on the REAL clock otherwise, and a later pin
    // to a small tick value then underflows the unsigned subtraction against
    // that large real tick and reads as an already-elapsed hold.
    setenv("UBIQUITTY_FAKE_TICKS", "0", 1);
    Ubiquitty::Runtime::TerminalSession* session = activePane()->session;
    session->start(startupRows, startupColumns);
    Ubiquitty::Terminal* term = session->terminal();
    if (!term) {
        g_printerr("smoke-pointer-lock: no term\n");
        unsetenv("UBIQUITTY_FAKE_TICKS");
        return 1;
    }

    const char enableModes[] = "\x1b[?1016h\x1b[?7403h";
    Ubiquitty::processBytes(term, std::string_view(enableModes, sizeof(enableModes) - 1));
    bool didPass = term->modes.mouseRelativePointerLock;
    g_print("smoke-pointer-lock: mode-set %s\n", didPass ? "PASS" : "FAIL");

    // Leg 1: the verdict follows mode + focus, not either alone.
    Ubiquitty::Input::PointerLockFacts focused;
    focused.isSurfaceFocused = true;
    Ubiquitty::Input::PointerLockFacts unfocused;
    unfocused.isSurfaceFocused = false;
    const bool didVerdictFollowFocus = session->pointerLockVerdict(focused) == Ubiquitty::Input::PointerLockVerdict::Hold
        && session->pointerLockVerdict(unfocused) == Ubiquitty::Input::PointerLockVerdict::Release;
    g_print("smoke-pointer-lock: verdict-follows-focus %s\n", didVerdictFollowFocus ? "PASS" : "FAIL");
    didPass = didPass && didVerdictFollowFocus;

    // Leg 2: the grab report reaches the ladder's release lesson, and the
    // lesson withdraws with the grab -- through notePointerLockGrab exactly
    // as PointerLock.cpp's applyPointerLock calls it, never the report bytes
    // (an OS grab in a smoke would hide and warp the real cursor).
    const bool isHintNoneAtStart = session->hintShowing() == Ubiquitty::Input::Hint::None;
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Held);
    const bool isHintShowingRelease = session->hintShowing() == Ubiquitty::Input::Hint::PointerLockRelease
        && session->hintTicksUntilExpiry() == 0; // a standing lock lesson has no clock; it ends with the grab
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Released);
    const bool didHintWithdraw = session->hintShowing() == Ubiquitty::Input::Hint::None;
    const bool didGrabTeachRelease = isHintNoneAtStart && isHintShowingRelease && didHintWithdraw;
    g_print("smoke-pointer-lock: grab-report-teaches-release %s\n", didGrabTeachRelease ? "PASS" : "FAIL");
    didPass = didPass && didGrabTeachRelease;

    // Leg 3: a motion delta is routed as an SGR report; a sample with no
    // motion is swallowed rather than flooding the host with a zero delta.
    // Through Input::routePointer directly (Core's own function) rather than
    // session->pointerFact: the session's wrapper sends a routed report
    // through the real PTY this headless run has no deterministic way to read
    // back, while a throwaway ladder is equivalent for this assertion -- the
    // locked branch touches no ladder state.
    Ubiquitty::Input::PointerLadder scratchLadder;
    const Ubiquitty::Input::PointerPolicy policy;
    Ubiquitty::Input::PointerFact motion;
    motion.kind = Ubiquitty::Input::PointerFact::Kind::Motion;
    motion.button = Ubiquitty::Input::PointerButton::None;
    motion.deltaX = 5;
    motion.deltaY = -7;
    const Ubiquitty::Input::PointerRoute movedRoute = Ubiquitty::Input::routePointer(scratchLadder, *term, &activePane()->selection, motion, policy, 0);
    const std::string movedReport(movedRoute.report.data(), static_cast<std::size_t>(movedRoute.reportLength));
    const bool isMotionReported = movedRoute.wasConsumed && movedReport.size() >= 3 && movedReport.compare(0, 3, "\x1b[<") == 0;
    motion.deltaX = 0;
    motion.deltaY = 0;
    const Ubiquitty::Input::PointerRoute stillRoute = Ubiquitty::Input::routePointer(scratchLadder, *term, &activePane()->selection, motion, policy, 0);
    const bool isZeroDeltaSwallowed = stillRoute.wasConsumed && stillRoute.reportLength == 0;
    g_print("smoke-pointer-lock: motion-delta-reports \"");
    printEscaped(movedReport);
    g_print("\" zero-delta-swallowed=%d -- %s\n", static_cast<int>(isZeroDeltaSwallowed), (isMotionReported && isZeroDeltaSwallowed) ? "PASS" : "FAIL");
    didPass = didPass && isMotionReported && isZeroDeltaSwallowed;

    // Leg 4: the break-out chord, through Core's pinned clock. Without a
    // grab a bare Control+Command is a real shortcut and must not arm.
    Ubiquitty::Input::PointerLockKeyState chord;
    chord.isControlHeld = true;
    chord.isCommandHeld = true;
    session->notePointerLockChord(chord);
    const bool isUnarmedWithNoGrab = session->pointerLockChordTicksUntilDeadline() == 0;
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Held);
    session->notePointerLockChord(chord);
    const std::uint32_t hold = Ubiquitty::Input::pointerLockBreakoutHoldTicks;
    const bool isArmedAtHold = session->pointerLockChordTicksUntilDeadline() == hold;
    setenv("UBIQUITTY_FAKE_TICKS", std::to_string(hold - 1).c_str(), 1);
    const bool didKeepShortOfHold = session->tickPointerLockChord(chord) == Ubiquitty::Input::PointerLockChordVerdict::Keep;
    setenv("UBIQUITTY_FAKE_TICKS", std::to_string(hold).c_str(), 1);
    const bool didBreakOutAtHold = session->tickPointerLockChord(chord) == Ubiquitty::Input::PointerLockChordVerdict::BreakOut;
    const bool isModeCleared = !term->modes.mouseRelativePointerLock;
    unsetenv("UBIQUITTY_FAKE_TICKS");
    session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Released); // leave the ladder as this smoke found it
    const bool didChordBreakOut = isUnarmedWithNoGrab && isArmedAtHold && didKeepShortOfHold && didBreakOutAtHold && isModeCleared;
    g_print("smoke-pointer-lock: chord-breaks-out-at-hold(%u) %s\n", hold, didChordBreakOut ? "PASS" : "FAIL");
    didPass = didPass && didChordBreakOut;

    // Legs 5-7 drive this arm's own wiring rather than Core's seams. A
    // headless run has no realized widget, so the OS grab itself is stood in
    // for -- the fields applyPointerLock sets on engage are set by hand and
    // the grab reported -- and what is asserted is everything around it:
    // the key handler's chord report and its wake-up, and the two edges the
    // grab must not survive.
    const auto holdGrabByHand = [&](LinuxPane* pane) {
        app().isPointerLocked = true;
        app().pointerLockPane = pane;
        pane->session->notePointerLockGrab(Ubiquitty::Input::PointerLockGrab::Held);
    };
    setenv("UBIQUITTY_FAKE_TICKS", "0", 1);
    Ubiquitty::processBytes(term, std::string_view(enableModes, sizeof(enableModes) - 1));
    holdGrabByHand(activePane());
    const auto pair = static_cast<GdkModifierType>(GDK_CONTROL_MASK | GDK_META_MASK | GDK_SUPER_MASK);
    notePointerLockChordFromKeyEvent(GDK_KEY_Control_L, pair, Ubiquitty::Keys::KeyEventType::Press);
    const bool didKeyHandlerArm = session->pointerLockChordTicksUntilDeadline() == hold && app().pointerLockChordTimerID != 0;
    // A key joining the pair is a shortcut; its release lets the pair arm again.
    notePointerLockChordFromKeyEvent(GDK_KEY_x, pair, Ubiquitty::Keys::KeyEventType::Press);
    const bool didKeyJoiningDisarm = session->pointerLockChordTicksUntilDeadline() == 0;
    notePointerLockChordFromKeyEvent(GDK_KEY_x, pair, Ubiquitty::Keys::KeyEventType::Release);
    const bool didReleaseRearm = session->pointerLockChordTicksUntilDeadline() == hold;
    setenv("UBIQUITTY_FAKE_TICKS", std::to_string(hold).c_str(), 1);
    app().pointerLockLastModifiers = pair;
    (void)onPointerLockChordTick(nullptr);
    const bool didTickRelease = !app().isPointerLocked && app().pointerLockPane == nullptr && !term->modes.mouseRelativePointerLock;
    unsetenv("UBIQUITTY_FAKE_TICKS");
    const bool didChordWireThrough = didKeyHandlerArm && didKeyJoiningDisarm && didReleaseRearm && didTickRelease;
    g_print("smoke-pointer-lock: chord-through-key-handler arm=%d joined-disarms=%d release-rearms=%d tick-releases=%d -- %s\n",
        static_cast<int>(didKeyHandlerArm), static_cast<int>(didKeyJoiningDisarm), static_cast<int>(didReleaseRearm),
        static_cast<int>(didTickRelease), didChordWireThrough ? "PASS" : "FAIL");
    didPass = didPass && didChordWireThrough;

    // Leg 6: closing the pane that holds the grab releases it first, so
    // nothing reads a destroyed pane and no cursor is left hidden.
    const SurfaceID surface = app().model->activeSurface();
    splitFocusedPaneUX(Panes::Orientation::Vertical);
    const Panes::Tree* tree = app().model->paneTree(surface);
    const bool didSplit = tree != nullptr && tree->paneCount() == 2 && activePane() != nullptr && activePane()->session != nullptr;
    bool didCloseRelease = false;
    // A release that reads the destroyed pane is a use after free that may
    // well look like a release; applyPointerLock says so as a critical, and
    // this leg counts them, so the order of teardown is what is asserted.
    static int criticalCount = 0;
    criticalCount = 0;
    const guint criticalHandler = g_log_set_handler(nullptr, G_LOG_LEVEL_CRITICAL, [](const gchar*, GLogLevelFlags, const gchar* message, gpointer) { ++criticalCount; g_printerr("smoke-pointer-lock: critical: %s\n", message); }, nullptr);
    if (didSplit) {
        holdGrabByHand(activePane());
        closeFocusedPaneUX();
        const Panes::Tree* after = app().model->paneTree(surface);
        didCloseRelease = !app().isPointerLocked && app().pointerLockPane == nullptr && after != nullptr && after->paneCount() == 1 && criticalCount == 0;
    }
    g_log_remove_handler(nullptr, criticalHandler);
    g_print("smoke-pointer-lock: pane-close-releases split=%d criticals=%d -- %s\n", static_cast<int>(didSplit), criticalCount, didCloseRelease ? "PASS" : "FAIL");
    didPass = didPass && didCloseRelease;

    // Leg 7: a focus move to a pane whose program never asked releases the
    // grab the pane the focus left was holding.
    splitFocusedPaneUX(Panes::Orientation::Vertical);
    const Panes::Tree* tree2 = app().model->paneTree(surface);
    bool didFocusMoveRelease = false;
    if (tree2 != nullptr && tree2->paneCount() == 2 && activePane() != nullptr && activePane()->session != nullptr) {
        LinuxPane* holder = activePane();
        holdGrabByHand(holder);
        moveFocusUX(Panes::Direction::Left);
        if (activePane() == holder)
            moveFocusUX(Panes::Direction::Right);
        didFocusMoveRelease = activePane() != holder && !app().isPointerLocked && app().pointerLockPane == nullptr;
    }
    g_print("smoke-pointer-lock: focus-move-releases -- %s\n", didFocusMoveRelease ? "PASS" : "FAIL");
    didPass = didPass && didFocusMoveRelease;

    g_print("smoke-pointer-lock: overall %s\n", didPass ? "PASS" : "FAIL");
    return didPass ? 0 : 1;
}
