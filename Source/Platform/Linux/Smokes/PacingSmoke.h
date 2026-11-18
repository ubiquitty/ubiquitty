// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-pacing — that a repaint request reaches the pacing policy.
//
// The frontend asks the frame clock to stop calling back once output has been
// idle for the driver's timeout, so what brings the clock back is the driver
// hearing about new activity. Every path that wants a frame goes through
// requestRepaint() for exactly that reason, and a path that set the flag
// directly would mark a frame with nothing left installed to paint it.
//
// Headless, so there is no widget and no callback to install. What is checked
// is the half that decides: the flag, and the driver's answer to whether output
// has gone quiet. The callback bookkeeping needs a display and belongs to the
// windowed smokes.
/// Checks that a repaint request restarts the presentation pacing policy.
///
/// - Returns: Zero on success, or a nonzero failure status.
int smokePacing()
{
    bool ok = true;
    auto check = [&](bool isSatisfied, const char* what) {
        if (!isSatisfied) {
            g_printerr("smoke-pacing: FAIL: %s\n", what);
            ok = false;
        }
    };

    const auto nowSeconds = [] { return static_cast<double>(g_get_monotonic_time()) / 1e6; };
    const double idleTimeout = app().frameDriver.idleTimeoutSeconds();
    check(idleTimeout > 0.0, "the driver has no idle timeout, so the clock would never pause");

    // A request marks the frame and tells the driver output just flowed.
    app().isRepaintPending = false;
    requestRepaint();
    check(app().isRepaintPending, "requestRepaint did not mark a frame pending");
    check(!app().frameDriver.idleExpired(nowSeconds()),
        "the driver called output idle immediately after a repaint request — requestRepaint is not stamping it");

    // And that it is a stamp rather than a latch: the same driver has to report
    // idle once the timeout has passed with nothing asking for a frame.
    check(app().frameDriver.idleExpired(nowSeconds() + idleTimeout + 1.0),
        "the driver never reports idle, so the clock would keep calling back on a terminal nobody is watching");

    // Cursor-only opacity steps request a frame without making output look
    // active. Once the toolkit blink times out, no such step is scheduled and
    // the frame clock can remain uninstalled.
    (void)app().frameDriver.noteActivity(1.0);
    app().frameDriver.setMode(Ubiquitty::Runtime::FrameMode::OnDemand);
    app().isRepaintPending = false;
    requestRepaint(RepaintCause::CursorStep);
    check(app().isRepaintPending && app().frameDriver.idleExpired(nowSeconds()),
        "a cursor-only repaint kept the idle frame clock alive");

    // A pane starts ingesting before its picture is rooted. Its fallback
    // interval must turn the adaptive recommendation on-demand after output
    // stops; an unset interval makes onTick request another frame forever.
    Ubiquitty::Runtime::FrameDriver adaptive;
    adaptive.setAdaptiveDrive(Ubiquitty::Runtime::AdaptiveDrive::On);
    check(adaptive.recommendedMode(1.0) == Ubiquitty::Runtime::FrameMode::Continuous,
        "an unset pane rate should expose the continuous-drive failure mode");
    adaptive.setFrameIntervalSeconds(cursorPresentationInterval(nullptr));
    check(adaptive.recommendedMode(1.0) == Ubiquitty::Runtime::FrameMode::OnDemand,
        "an unrooted pane has no fallback rate, so an idle pane would repaint at vblank");

    g_print("smoke-pacing: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
