// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

/// Checks cursor presentation across retained Vulkan frames.
///
/// - Parameter renderer: The Vulkan renderer under examination.
/// - Returns: Whether every check passed.
bool smokeCursorPresentation(Ubiquitty::Linux::VulkanRenderer& renderer)
{
    const bool doesScrollIndicatorPass = smokeScrollIndicator();
    LinuxPane& pane = *activePane();
    pane.session->start(6, 24);
    pane.cursorPresentation.reset();
    pane.cursorPresentationBypassUntil = 0;
    Ubiquitty::Terminal* term = pane.session->terminal();
    if (!term) {
        return false;
    }
    term->windowFocused = 1;
    Ubiquitty::processBytes(term, "\x1b[?25h\x1b[6 q\x1b]12;#ff0044\x07\x1b[2;7H");
    struct Step {
        const char* name;
        const char* bytes;
        double seconds;
        int expectedRow;
        int expectedColumn;
    };
    const Step steps[] = {
        { "visible", "", 10.000, 1, 6 },
        { "redraw-hide", "\x1b[?25l\x1b[5;19H\x1b[4 q\x1b]12;#00ff00\x07", 10.001, 1, 6 },
        { "hidden-repeat", "", 10.025, 1, 6 },
        { "redraw-show", "\x1b[2;7H\x1b[6 q\x1b]12;#ff0044\x07\x1b[?25h", 10.030, 1, 6 },
        { "persistent-hide", "\x1b[?25l\x1b[5;19H", 10.040, 1, 6 },
        { "persistent-repeat", "", 10.075, 1, 6 },
        { "hidden-expired", "", 10.091, -1, 0 },
        { "hidden-stays", "", 10.120, -1, 0 },
        { "visible-again", "\x1b[2;7H\x1b[?25h", 10.130, 1, 6 },
        { "move-held", "\x1b[2;13H", 10.140, 1, 6 },
        { "move-settled", "", 10.157, 1, 12 },
    };
    bool didPass = doesScrollIndicatorPass;
    std::vector<uint8_t> baseline;
    for (const Step& step : steps) {
        Ubiquitty::processBytes(term, step.bytes);
        const Ubiquitty::Linux::CursorOverlay cursor = resolvePresentedCursorOverlay(pane, step.seconds, 1.0 / 60.0);
        const Ubiquitty::Rendering::CursorRenderState& presented = *cursor.presentation;
        std::vector<uint8_t> cpu;
        std::vector<uint8_t> gpu;
        int cpuWidth = 0, cpuHeight = 0, gpuWidth = 0, gpuHeight = 0;
        const bool didRenderCPU = app().rasterContext.rasterizeTerm(term, cpu, cpuWidth, cpuHeight, 0, nullptr, &cursor);
        const bool didRenderGPU = renderer.renderGrid(app().rasterContext, term, gpu, gpuWidth, gpuHeight, 0, nullptr, &cursor);
        const bool isPositionCorrect = presented.row == step.expectedRow
            && (presented.row < 0 || presented.column == step.expectedColumn);
        const bool isSame = didRenderCPU && didRenderGPU && cpuWidth == gpuWidth && cpuHeight == gpuHeight && cpu == gpu;
        if (baseline.empty()) {
            baseline = cpu;
        }
        const bool shouldMatchBaseline = step.expectedRow == 1 && step.expectedColumn == 6;
        const bool isAppearanceCorrect = shouldMatchBaseline ? cpu == baseline : cpu != baseline;
        const bool isStepCorrect = isPositionCorrect && isSame && isAppearanceCorrect;
        didPass = didPass && isStepCorrect;
        g_print("smoke-cursor: presentation %-17s position=%d CPU==GPU=%d appearance=%d -- %s\n", step.name,
            isPositionCorrect ? 1 : 0, isSame ? 1 : 0, isAppearanceCorrect ? 1 : 0, isStepCorrect ? "PASS" : "FAIL");
    }

    pane.cursorPresentation.reset();
    Ubiquitty::processBytes(term, "\x1b[2 q\x1b[2;7H\x1b[?25h");
    (void)resolvePresentedCursorOverlay(pane, 20.000, 1.0 / 60.0);
    noteCursorInput(pane, 20.001);
    Ubiquitty::processBytes(term, "x");
    const auto typed = resolvePresentedCursorOverlay(pane, 20.002, 1.0 / 60.0);
    const bool doesTypingMoveImmediately = typed.presentation->row == 1 && typed.presentation->column == 7
        && !pane.cursorPresentation.isHolding();
    didPass = didPass && doesTypingMoveImmediately;
    g_print("smoke-cursor: presentation typed-cell-immediate -- %s\n", doesTypingMoveImmediately ? "PASS" : "FAIL");

    const auto geometry = app().rasterContext.frameCaptureGeometry();
    Ubiquitty::Rendering::TerminalSnapshotOptions options;
    options.style = geometry.style;
    options.isFocused = true;
    options.cursorMixAlpha = 1.0f;
    options.cellHeightPoints = geometry.cellHeightPoints;
    options.lineSpacingPoints = geometry.lineSpacingPoints;
    options.toolkitCaret = geometry.toolkitCaret;
    std::unique_ptr<Ubiquitty::Rendering::FrameCapture, LinuxPane::FrameRelease> captured(Ubiquitty::Rendering::FrameCapture::make());
    noteCursorInput(pane, 20.003);
    Ubiquitty::processBytes(term, "y");
    const bool didCaptureTyping = captured->capture(*term, options, geometry.metrics, geometry.glyphSlot);
    captured->applyCursorPresentation(pane.cursorPresentation, 20.004, 1.0 / 60.0, 20.004 < pane.cursorPresentationBypassUntil);
    const bool doesCapturedTypingMoveImmediately = didCaptureTyping && captured->cursorRow() == 1 && captured->cursorColumn() == 8
        && !pane.cursorPresentation.isHolding();
    didPass = didPass && doesCapturedTypingMoveImmediately;
    g_print("smoke-cursor: presentation captured-typed-cell-immediate -- %s\n", doesCapturedTypingMoveImmediately ? "PASS" : "FAIL");
    Ubiquitty::processBytes(term, "z");
    const auto afterInputWindow = resolvePresentedCursorOverlay(pane, 20.200, 1.0 / 60.0);
    const bool doesRedrawStillHold = afterInputWindow.presentation->column == 8 && pane.cursorPresentation.isHolding();
    didPass = didPass && doesRedrawStillHold;
    g_print("smoke-cursor: presentation redraw-hold-after-input -- %s\n", doesRedrawStillHold ? "PASS" : "FAIL");

    pane.cursorPresentation.reset();
    pane.cursorPresentationBypassUntil = 0;
    Ubiquitty::processBytes(term, "\x1b[2;7H\x1b[?25h");
    (void)resolvePresentedCursorOverlay(pane, 10.158, 1.0 / 60.0);
    Ubiquitty::processBytes(term, "\x1b[?25l\x1b[2;1H\x1b#6\x1b[5;19H");
    const auto doubledRow = resolvePresentedCursorOverlay(pane, 10.159, 1.0 / 60.0);
    const bool doesHeldRowFollowGeometry = doubledRow.presentation->row == 1
        && doubledRow.presentation->lineAttribute == Ubiquitty::Screen::rowLineAttribute(term, Ubiquitty::Screen::scrollbackCount(term) + 1)
        && doubledRow.presentation->lineAttribute != Ubiquitty::lineAttributeNormal;
    didPass = didPass && doesHeldRowFollowGeometry;
    g_print("smoke-cursor: presentation held-row-geometry -- %s\n", doesHeldRowFollowGeometry ? "PASS" : "FAIL");
    LinuxPane otherPane;
    otherPane.session = pane.session;
    const auto initiallyHidden = resolvePresentedCursorOverlay(otherPane, 10.160, 1.0 / 60.0);
    const bool isPaneIndependent = initiallyHidden.presentation->row < 0 && otherPane.cursorPresentation.deadlineSeconds() == 0;
    pane.viewOffset = 1;
    const auto scrolled = resolvePresentedCursorOverlay(pane, 10.161, 1.0 / 60.0);
    const bool doesScrollReset = scrolled.presentation->row < 0 && pane.cursorPresentation.deadlineSeconds() == 0;
    pane.viewOffset = 0;
    const auto returnedHidden = resolvePresentedCursorOverlay(pane, 10.162, 1.0 / 60.0);
    const bool doesHiddenStayHidden = returnedHidden.presentation->row < 0;
    didPass = didPass && isPaneIndependent && doesScrollReset && doesHiddenStayHidden;
    g_print("smoke-cursor: presentation pane-isolation=%d scroll-reset=%d hidden-return=%d -- %s\n",
        isPaneIndependent ? 1 : 0, doesScrollReset ? 1 : 0, doesHiddenStayHidden ? 1 : 0,
        isPaneIndependent && doesScrollReset && doesHiddenStayHidden ? "PASS" : "FAIL");

    const double nowSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
    Ubiquitty::processBytes(term, "\x1b[?25h");
    (void)resolvePresentedCursorOverlay(pane, nowSeconds, 1.0 / 60.0);
    Ubiquitty::processBytes(term, "\x1b[?25l");
    (void)resolvePresentedCursorOverlay(pane, nowSeconds, 1.0 / 60.0);
    scheduleCursorPresentation(pane, nowSeconds);
    const bool didArmDeadline = pane.cursorPresentationSource != 0;
    const gint64 waitUntil = g_get_monotonic_time() + 250000;
    while (pane.cursorPresentationSource != 0 && g_get_monotonic_time() < waitUntil) {
        (void)g_main_context_iteration(nullptr, FALSE);
        g_usleep(1000);
    }
    const auto expired = resolvePresentedCursorOverlay(pane, static_cast<double>(g_get_monotonic_time()) / 1e6, 1.0 / 60.0);
    const bool didDeadlineExpire = pane.cursorPresentationSource == 0 && expired.presentation->row < 0
        && pane.cursorPresentation.deadlineSeconds() == 0;
    didPass = didPass && didArmDeadline && didDeadlineExpire;
    g_print("smoke-cursor: presentation idle-deadline armed=%d expired=%d -- %s\n",
        didArmDeadline ? 1 : 0, didDeadlineExpire ? 1 : 0,
        didArmDeadline && didDeadlineExpire ? "PASS" : "FAIL");
    guint closedSource = 0;
    {
        LinuxPane closingPane;
        closingPane.session = pane.session;
        const double closeSeconds = static_cast<double>(g_get_monotonic_time()) / 1e6;
        Ubiquitty::processBytes(term, "\x1b[?25h");
        (void)resolvePresentedCursorOverlay(closingPane, closeSeconds, 1.0 / 60.0);
        Ubiquitty::processBytes(term, "\x1b[?25l");
        (void)resolvePresentedCursorOverlay(closingPane, closeSeconds, 1.0 / 60.0);
        scheduleCursorPresentation(closingPane, closeSeconds);
        closedSource = closingPane.cursorPresentationSource;
    }
    // Modifier-only input must preserve both GTK's phase/timeout and the
    // recent-typing presentation deadline, even when Kitty reports the key.
    app().caretBlinkCycleStartMicros = 123;
    app().caretInteractionMicros = 456;
    pane.cursorPresentationBypassUntil = 7;
    GtkIMContext* const savedIMContext = app().imContext;
    app().imContext = nullptr;
    bool doModifiersPreserveBlink = true;
    for (const guint key : { GDK_KEY_Shift_L, GDK_KEY_Control_L, GDK_KEY_Alt_L, GDK_KEY_Super_L, GDK_KEY_Caps_Lock }) {
        onKeyPressed(nullptr, key, 0, static_cast<GdkModifierType>(0), nullptr);
        onKeyReleased(nullptr, key, 0, static_cast<GdkModifierType>(0), nullptr);
        doModifiersPreserveBlink = doModifiersPreserveBlink && app().caretBlinkCycleStartMicros == 123
            && app().caretInteractionMicros == 456 && pane.cursorPresentationBypassUntil == 7;
    }
    restartCaretBlink(true);
    noteCursorInput(pane, 30);
    const bool doesTypingResetBlink = app().caretBlinkCycleStartMicros != 123 && app().caretInteractionMicros != 456
        && pane.cursorPresentationBypassUntil > 30;
    app().imContext = savedIMContext;
    didPass = didPass && doModifiersPreserveBlink && doesTypingResetBlink;
    g_print("smoke-cursor: modifier-only-preserves-phase=%d typing-resets=%d -- %s\n", doModifiersPreserveBlink,
        doesTypingResetBlink, doModifiersPreserveBlink && doesTypingResetBlink ? "PASS" : "FAIL");
    const bool didCancelOnClose = closedSource != 0 && g_main_context_find_source_by_id(nullptr, closedSource) == nullptr;
    didPass = didPass && didCancelOnClose;
    g_print("smoke-cursor: presentation close-cancels-deadline -- %s\n", didCancelOnClose ? "PASS" : "FAIL");
    return didPass;
}
