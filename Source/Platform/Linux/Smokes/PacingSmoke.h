// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// --smoke-pacing — that a repaint request marks the frame it asks for, and
// what a frame Core declined waits on.
//
// The frame clock's callback is installed only while something has asked for a
// cycle, so what brings a frame is a request. Every path that wants one goes
// through requestRepaint() for exactly that reason, and a path that set the
// flag directly would mark a frame with nothing left installed to paint it.
// A request says whose the frame is: the view's own is drawn whatever the
// drain published, and output's only when what it published has moved.
//
// A frame Core declines is not asked for again by a clock left running. Who
// asks is read from Core's answer, and that reading is the other half checked
// here: a mistake in it is a frame that never comes, or a clock that never
// stops.
//
// Headless, so there is no widget and no callback to install. The callback
// bookkeeping needs a display and belongs to the windowed smokes.
/// Checks what a repaint request marks and who asks again for a declined frame.
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

    // Output's wake asks the panes and owes nothing of the view's own.
    app().isRepaintPending = false;
    app().isViewRepaintOwed = false;
    requestRepaint(RepaintCause::Output);
    check(app().isRepaintPending, "an output wake did not mark a frame pending");
    check(!app().isViewRepaintOwed, "an output wake owed the view a frame, so a wake with nothing new would be drawn");

    // The view's own request owes its frame whatever the drain published.
    app().isRepaintPending = false;
    requestRepaint();
    check(app().isRepaintPending && app().isViewRepaintOwed, "requestRepaint did not mark the view's frame owed");

    // With no widget there is no clock to ask, and nothing is left installed.
    check(app().tickCallbackID == 0, "a headless repaint request installed a tick callback");

    using Ubiquitty::Runtime::FrameDecline;
    // A hold with a budget names its tick, and the one-shot asks, on either drain.
    check(!doesClockAskForDeclinedFrame({ FrameDecline::HeldByPresentation, 3 }, PaneDrain::Loop)
            && !doesClockAskForDeclinedFrame({ FrameDecline::RedrawArriving, 1 }, PaneDrain::Loop)
            && !doesClockAskForDeclinedFrame({ FrameDecline::AwaitingCapture, 1 }, PaneDrain::Inline),
        "a declined frame that names its tick left the clock asking");
    // What ends these two holds wakes the view of a pane its loop drains.
    check(!doesClockAskForDeclinedFrame({ FrameDecline::HeldByCoherence, 0 }, PaneDrain::Loop)
            && !doesClockAskForDeclinedFrame({ FrameDecline::AwaitingCapture, 0 }, PaneDrain::Loop),
        "a frame whose release wakes the view left the clock asking");
    // Nothing announces these, so the clock is what asks.
    check(doesClockAskForDeclinedFrame({ FrameDecline::OwnerStalled, 0 }, PaneDrain::Loop),
        "a stalled owner's frame was left for a wake that is not promised");
    check(doesClockAskForDeclinedFrame({ FrameDecline::HeldByCoherence, 0 }, PaneDrain::Inline)
            && doesClockAskForDeclinedFrame({ FrameDecline::AwaitingCapture, 0 }, PaneDrain::Inline),
        "an inline drain’s held frame was left for a wake no loop sends");

    g_print("smoke-pacing: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
