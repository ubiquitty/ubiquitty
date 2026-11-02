// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import QuartzCore
import UbiquittyCore

/// Supplies the frame clock to Core's per-renderer cursor presentation and motion.
final class CursorAnimator {
    private var motion = Ubiquitty.Rendering.CursorMotion()
    private var presentation = Ubiquitty.Rendering.CursorPresentation()
    var presentationInterval: Double = 0
    var presentationBypassUntil: Double = 0
    var timeForTesting: Double?

    var presentationDeadline: Double? {
        let deadline = presentation.deadlineSeconds()
        return deadline > 0 ? deadline : nil
    }

    /// Applies presentation and motion to the frame without changing its terminal.
    ///
    /// Blink opacity remains independent of cursor eligibility, so transparent
    /// phases keep their position and a redraw bracket cannot restart the fade.
    ///
    /// - Parameter capture: The frame whose cursor is about to be built.
    /// - Returns: Whether a presentation hold or a slide remains in flight.
    func apply(to capture: Ubiquitty.Rendering.FrameCapture) -> Bool {
        let now = timeForTesting ?? CACurrentMediaTime()
        capture.applyCursorPresentation(
            &presentation,
            now,
            presentationInterval,
            now < presentationBypassUntil
        )
        if presentation.isHolding() {
            capture.setCursorSettled()
            return true
        }

        var frame = Ubiquitty.Rendering.CursorMotion.Frame()
        frame.targetColumn = Float(capture.cursorColumn())
        frame.targetVRow = Float(capture.cursorRow())
        frame.motionThresholdCells = Ubiquitty.Rendering.cursorMotionDefaultThresholdCells
        frame.seconds = now
        let durationMilliseconds = capture.cursorMotionDurationMilliseconds()
        frame.durationSeconds =
            durationMilliseconds == 0
            ? Ubiquitty.Rendering.cursorMotionDefaultDurationSeconds
            : Double(durationMilliseconds) / 1000
        frame.mode = capture.cursorMotionMode()
        frame.reduceMotion = SystemMotionPreference.isReduceMotionEnabled
        frame.visible = capture.cursorRow() >= 0
        let isSliding = motion.update(frame)
        if isSliding {
            capture.setCursorSliding(motion.column(), motion.vrow())
        } else {
            capture.setCursorSettled()
        }
        return isSliding
    }

    /// Forgets cursor presentation and motion when its renderer is reset.
    func reset() {
        motion.reset()
        presentation.reset()
    }
}
