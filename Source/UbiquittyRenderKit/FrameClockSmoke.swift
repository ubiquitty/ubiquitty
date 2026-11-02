// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FrameClockSmoke.swift — the headless oracle for the frame clock's decision
// sequences. The goldens compare static frames and the lifecycle scenarios
// watch two edges on glass; what neither can see is ordering — the driver going
// continuous before the link unpauses, paused flipping before the driver
// clears, the clamp chain deriving the rate. A scripted delegate records
// every call and the smoke compares whole sequences, so a reordering that
// would lose a wake edge fails by name before any window exists.

import Foundation

/// The smoke's entry, which the application's entry point dispatches.
public final class FrameClockSmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether every decision sequence matched its contract.
    public static func run() -> Bool {
        FrameClockSmoke.run()
    }
}

/// A delegate that answers from a script and records every call by name.
private final class RecordingDelegate: NSObject, FrameClockDelegate {
    var calls: [String] = []
    var hasWindow = true
    var isPresented = true
    var isPaused = true
    var hasAnimatingContent = false
    var animationDelay = 0.5
    var maxScreenFPS: Int32 = 120
    /// Answers for successive driver-idle queries; the last entry repeats,
    /// and assigning a fresh script restarts the sequence.
    var idleScript: [Bool] = [true] {
        didSet { idleIndex = 0 }
    }

    private var idleIndex = 0

    func nextIdle() -> Bool {
        let answer = idleScript[min(idleIndex, idleScript.count - 1)]
        idleIndex += 1
        return answer
    }

    func frameClockHasLiveTerm(_ clock: FrameClock) -> Bool {
        calls.append("hasLiveTerm")
        return true
    }

    func frameClockServiceIngestBelt(_ clock: FrameClock) {
        calls.append("serviceIngestBelt")
    }

    func frameClockMonotonicTicks(_ clock: FrameClock) -> UInt32 {
        calls.append("monotonicTicks")
        return 0
    }

    func frameClock(_ clock: FrameClock, checkHiliteDeadlineAt nowTicks: UInt32) {
        calls.append("checkHiliteDeadline")
    }

    func frameClock(_ clock: FrameClock, updateRepaintIfCrossedAt nowTicks: UInt32) {
        calls.append("updateRepaintIfCrossed")
    }

    func frameClockAdvanceImagesIfDue(_ clock: FrameClock) {
        calls.append("advanceImages")
    }

    func frameClockResetImageClock(_ clock: FrameClock) {
        calls.append("resetImageClock")
    }

    func frameClockHasAnimatingContent(_ clock: FrameClock) -> Bool {
        calls.append("hasAnimatingContent")
        return hasAnimatingContent
    }

    func frameClock(_ clock: FrameClock, nextAnimationDelayAt nowTicks: UInt32) -> Double {
        calls.append("nextAnimationDelay")
        return animationDelay
    }

    func frameClockHasWindow(_ clock: FrameClock) -> Bool {
        calls.append("hasWindow")
        return hasWindow
    }

    func frameClockNotePerfResume(_ clock: FrameClock) {
        calls.append("notePerfResume")
    }

    func frameClockMaxScreenFramesPerSecond(_ clock: FrameClock) -> Int32 {
        calls.append("maxScreenFPS")
        return maxScreenFPS
    }

    func frameClockIsPresented(_ clock: FrameClock) -> Bool {
        calls.append("isPresented")
        return isPresented
    }

    func frameClockIsPaused(_ clock: FrameClock) -> Bool {
        calls.append("isPaused")
        return isPaused
    }

    func frameClock(_ clock: FrameClock, setPreferredFramesPerSecond fps: Int32) {
        calls.append("setPreferredFPS(\(fps))")
    }

    func frameClock(_ clock: FrameClock, setSyncPublishRefreshSeconds seconds: Double) {
        calls.append("setSyncPublish(\(String(format: "%.4f", seconds)))")
    }

    func frameClock(_ clock: FrameClock, setDriverFrameIntervalSeconds seconds: Double) {
        calls.append("setDriverFrameInterval(\(String(format: "%.4f", seconds)))")
    }

    func frameClockApplyVSyncToLayer(_ clock: FrameClock) {
        calls.append("applyVSync")
    }

    func frameClock(_ clock: FrameClock, setEnableSetNeedsDisplay enable: Bool) {
        calls.append("setEnableSetNeedsDisplay(\(enable))")
    }

    func frameClock(_ clock: FrameClock, setPaused paused: Bool) {
        calls.append("setPaused(\(paused))")
    }

    func frameClockSetNeedsDisplayNow(_ clock: FrameClock) {
        calls.append("setNeedsDisplayNow")
    }

    func frameClockCommitTekFrameIfIdle(_ clock: FrameClock) {
        calls.append("commitTek")
    }

    func frameClock(_ clock: FrameClock, setDriverContinuous continuous: Bool) {
        calls.append("setDriverContinuous(\(continuous))")
    }

    func frameClockDriverIdleExpired(_ clock: FrameClock) -> Bool {
        calls.append("driverIdleExpired")
        return nextIdle()
    }
}

/// The smoke's cases, kept as a type so its pieces stay named.
private enum FrameClockSmoke {
    static func run() -> Bool {
        var passed = true

        func expect(_ name: String, _ got: [String], _ want: [String]) {
            if got != want {
                print("FAIL \(name)")
                print("  want \(want)")
                print("  got  \(got)")
                passed = false
            } else {
                print("PASS \(name)")
            }
        }

        // Detached resume: the whole contract is three applications and no
        // driver publish — a windowless MTKView has no link to drive.
        do {
            let d = RecordingDelegate()
            d.hasWindow = false
            let clock = FrameClock(delegate: d)
            clock.resume()
            expect(
                "detachedResume",
                d.calls,
                ["hasWindow", "setPaused(true)", "setEnableSetNeedsDisplay(true)", "setNeedsDisplayNow"]
            )
        }

        // Attached resume: the rate is derived first, then the driver publishes
        // continuous ahead of the link unpausing, and the rate lands unclamped
        // at the panel maximum.
        do {
            let d = RecordingDelegate()
            let clock = FrameClock(delegate: d)
            clock.resume()
            expect(
                "attachedResume",
                d.calls,
                [
                    "hasWindow", "maxScreenFPS", "isPresented", "notePerfResume", "setDriverContinuous(true)",
                    "setPreferredFPS(120)", "setSyncPublish(0.0083)", "setDriverFrameInterval(0.0083)", "applyVSync",
                    "setEnableSetNeedsDisplay(false)", "setPaused(false)",
                ]
            )
        }

        // The cap clamps below the panel rate. A pane nobody can see gets no
        // link at any cap: the clock parks in maybePause's order — paused,
        // then the driver clears, then on-demand drive — and keeps the
        // session publishing at the reduced cadence for the reveal's repaint.
        do {
            let d = RecordingDelegate()
            let clock = FrameClock(delegate: d)
            clock.setMaxFPS(30)
            d.calls = []
            clock.resume()
            expect("cappedResume", d.calls.filter { $0.hasPrefix("setPreferredFPS") }, ["setPreferredFPS(30)"])

            d.isPresented = false
            d.calls = []
            clock.resume()
            expect(
                "backgroundResume",
                d.calls,
                [
                    "hasWindow", "maxScreenFPS", "isPresented", "setPaused(true)", "setDriverContinuous(false)",
                    "setEnableSetNeedsDisplay(true)", "setSyncPublish(0.1000)",
                ]
            )

            clock.setMaxFPS(5)
            d.calls = []
            clock.resume()
            expect("lowCapBackgroundResume", d.calls.filter { $0.hasPrefix("setPreferredFPS") || $0 == "setPaused(false)" }, [])
        }

        // The animation tick parks while the view is detached: its repaints
        // can show nowhere, so one fire stops the timer instead of burning
        // the runloop for a headless surface. The control arm holds a window
        // through the same fire and the tick stays armed — so the park above
        // cannot be a timer that never survives a fire.
        do {
            let d = RecordingDelegate()
            d.hasAnimatingContent = true
            d.animationDelay = 0.02
            d.hasWindow = false
            let clock = FrameClock(delegate: d)
            clock.noteAnimationActivity()
            let didArmDetached = clock.isTicking
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
            expect(
                "windowlessPark",
                [didArmDetached ? "armed" : "neverArmed", clock.isTicking ? "stillTicking" : "parked"],
                ["armed", "parked"]
            )

            let attached = RecordingDelegate()
            attached.hasAnimatingContent = true
            attached.animationDelay = 0.02
            let attachedClock = FrameClock(delegate: attached)
            attachedClock.noteAnimationActivity()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
            expect(
                "attachedTickSurvivesFires",
                [attachedClock.isTicking ? "stillTicking" : "parked"],
                ["stillTicking"]
            )
            attachedClock.stop()
        }

        // maybePause: an already-paused link is a no-op; still-active output
        // otherwise keeps the link; idle pauses with paused flipping ahead
        // of the driver clearing, and the recheck that catches a drain
        // landing mid-flip resumes.
        do {
            let d = RecordingDelegate()
            d.isPaused = false
            d.idleScript = [false]
            let clock = FrameClock(delegate: d)
            clock.maybePause()
            expect("activeMaybePause", d.calls, ["isPaused", "driverIdleExpired"])

            d.calls = []
            d.idleScript = [true, true]
            clock.maybePause()
            expect(
                "idleMaybePause",
                d.calls,
                [
                    "isPaused", "driverIdleExpired", "commitTek", "setPaused(true)", "setDriverContinuous(false)",
                    "setEnableSetNeedsDisplay(true)", "driverIdleExpired",
                ]
            )

            d.calls = []
            d.idleScript = [true, false, true]
            clock.maybePause()
            expect(
                "midFlipDrainResumes",
                d.calls,
                [
                    "isPaused", "driverIdleExpired", "commitTek", "setPaused(true)", "setDriverContinuous(false)",
                    "setEnableSetNeedsDisplay(true)", "driverIdleExpired", "hasWindow", "maxScreenFPS", "isPresented",
                    "notePerfResume", "setDriverContinuous(true)", "setPreferredFPS(120)",
                    "setSyncPublish(0.0083)", "setDriverFrameInterval(0.0083)", "applyVSync", "setEnableSetNeedsDisplay(false)",
                    "setPaused(false)",
                ]
            )

            // Already paused: the first guard makes this a no-op, so a
            // caller can invoke maybePause unconditionally every frame.
            d.calls = []
            d.isPaused = true
            clock.maybePause()
            expect("pausedMaybePauseNoOp", d.calls, ["isPaused"])
        }

        // setMaxFPS: an unchanged cap does nothing; a change while paused
        // stores without resuming; a change while unpaused re-derives now.
        do {
            let d = RecordingDelegate()
            let clock = FrameClock(delegate: d)
            clock.setMaxFPS(0)
            expect("unchangedCap", d.calls, [])

            clock.setMaxFPS(60)
            expect("pausedCapChange", d.calls, ["isPaused"])

            d.isPaused = false
            d.calls = []
            clock.setMaxFPS(90)
            expect("liveCapChange", d.calls.prefix(2).map { $0 }, ["isPaused", "hasWindow"])
        }

        // A non-animating screen never arms the timer: one query, no more.
        do {
            let d = RecordingDelegate()
            let clock = FrameClock(delegate: d)
            clock.noteAnimationActivity()
            expect("idleNoteActivity", d.calls, ["hasAnimatingContent"])
            clock.stop()
        }

        // Present-slip accounting, the component both arms feed: a gap of one
        // refresh is on time, two is one slipped vsync, ten is idle time and
        // no slip, two and six tenths rounds to two; the first present has
        // nothing to difference against. The gaps sit away from the rounding
        // boundary, since a difference of doubles lands a hair under it.
        do {
            let slip = PresentSlipAccounting()
            slip.noteRefreshSeconds(1.0 / 60.0)
            slip.notePresented(atSeconds: 1.0)
            slip.notePresented(atSeconds: 1.0 + 1.0 / 60.0)
            slip.notePresented(atSeconds: 1.0 + 3.0 / 60.0)
            slip.notePresented(atSeconds: 1.0 + 13.0 / 60.0)
            slip.notePresented(atSeconds: 1.0 + 15.6 / 60.0)
            if slip.slippedVsyncs != 3 {
                passed = false
                print("FAIL: presentSlip counted \(slip.slippedVsyncs) slipped vsyncs, want 3")
            }
            if slip.presentedCountForTesting != 5 {
                passed = false
                print("FAIL: presentSlip recorded \(slip.presentedCountForTesting) presents, want 5")
            }
            // A refresh of zero is ignored, not divided by.
            slip.noteRefreshSeconds(0)
            slip.notePresented(atSeconds: 1.0 + 17.5 / 60.0)
            if slip.slippedVsyncs != 4 {
                passed = false
                print("FAIL: presentSlip after a zero refresh counted \(slip.slippedVsyncs), want 4")
            }
        }

        return passed
    }
}
