// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UbiquittyKit

/// The Core-facing plumbing relative pointer lock (DECSET 7403) needs on
/// this arm: the mode reaching the model, the verdict following the mode
/// and the focus fact only this surface can see, a grab report reaching the
/// lock's own lesson, and the break-out chord ticking to Core's clock.
///
/// The simulator has no trackpad to lock, so this stays below
/// ``TerminalSurfaceViewController``: ``UIPointerLockState`` never fires
/// here, and neither does a GameController mouse delta. What is asserted is
/// the seam every one of those calls into, which Core answers the same way
/// whoever calls it — the same scope
/// `Source/UbiquittyKit/Swift/SurfaceSmoke.swift` covers for the AppKit arm.
/// A real iPad with a trackpad still owes: that a click grants first
/// responder and iPadOS actually takes the grab, that a locked mouse's
/// deltas arrive as reports rather than being swallowed, and that the
/// break-out chord fires from a real held Control-Command rather than a
/// pinned clock.
enum PointerLockSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }

        // The mode-and-focus leg: the mode reaching the model, the verdict
        // following it and the focus fact only the surface can answer, and
        // this surface's own reading of that fact — ``isPointerLockDesired``
        // — agreeing that a surface with no window is not the input target
        // any lock could hold.
        guard let trapped = TerminalSurface(rows: 24, columns: 80) else {
            SmokeLaunch.report("pointer-lock: FAIL: no surface to trap")
            return false
        }
        trapped.feed(Data("\u{1b}[?7403h".utf8))
        check(
            trapped.drive.readSnapshot().mouseRelativePointerLockActive,
            "the pointer-lock mode never reached the model"
        )
        check(
            trapped.drive.pointerLockVerdict(isSurfaceFocused: true) == .hold,
            "a focused surface was not told to hold the grab"
        )
        check(
            trapped.drive.pointerLockVerdict(isSurfaceFocused: false) == .release,
            "an unfocused surface was told to hold the grab"
        )
        check(
            !trapped.isPointerLockDesired,
            "a surface with no window read itself as the live input target"
        )

        // The grab-report leg: reported the same way
        // ``TerminalSurfaceViewController`` reports a ``UIPointerLockState``
        // edge, and the lock's own lesson answering it.
        guard let captured = TerminalSurface(rows: 24, columns: 80) else {
            SmokeLaunch.report("pointer-lock: FAIL: no surface for the grab-report leg")
            return false
        }
        let release = String(cString: Ubiquitty.Input.hintText(.pointerLockRelease, .mac))
        check(captured.drive.hintTextShowing().isEmpty, "a fresh surface already had a lesson to show")
        captured.drive.notePointerLockGrab(.held)
        check(
            captured.drive.hintTextShowing() == release,
            "capturing the pointer did not raise the release lesson (read '\(captured.drive.hintTextShowing())')"
        )
        captured.drive.notePointerLockGrab(.released)
        check(captured.drive.hintTextShowing().isEmpty, "releasing the pointer left the lesson standing")

        // The same edge through this arm's own report, which is what the OS's
        // pointer-lock state change drives. GameController is wired only for
        // the duration of the grab: touching it earlier starts its device
        // discovery, and on a device with a keyboard attached that turns a
        // later tap into a click.
        check(!captured.isPointerLockMouseWired, "GameController was wired before any grab was held")
        captured.reportPointerLockGrab(.held)
        check(captured.isPointerLockHeld, "the arm's grab report did not record the grab")
        check(captured.drive.hintTextShowing() == release, "the arm's grab report did not reach Core's lesson")
        check(captured.isPointerLockMouseWired, "a held grab left GameController unwired, so no delta could arrive")
        captured.reportPointerLockGrab(.released)
        check(!captured.isPointerLockHeld, "the arm's release report left the grab recorded")
        check(captured.drive.hintTextShowing().isEmpty, "the arm's release report left the lesson standing")
        check(!captured.isPointerLockMouseWired, "a released grab left GameController wired")

        // The break-out chord, through Core's clock: pinned ticks stand in
        // for the wake-up this arm books with `DispatchQueue.main.asyncAfter`
        // (`TerminalSurface+UIKitPointer.swift`'s `bookPointerLockChordTick`),
        // so the hold is asserted at its exact boundary rather than by
        // sleeping a real half-second.
        guard let chorded = TerminalSurface(rows: 24, columns: 80) else {
            SmokeLaunch.report("pointer-lock: FAIL: no surface for the chord leg")
            return false
        }
        chorded.feed(Data("\u{1b}[?7403h".utf8))
        var chord = Ubiquitty.Input.PointerLockKeyState()
        chord.isControlHeld = true
        chord.isCommandHeld = true
        // Pinned from before the chord arms, not only from the hold check
        // onward: `armedAtTicks` is stamped from this same clock, and a real
        // monotonic tick read here against a pinned one at the hold check
        // would subtract two unrelated clocks.
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)
        // Without a grab a Control-Command chord is a shortcut, and it must
        // not arm.
        chorded.drive.notePointerLockChord(chord)
        check(
            chorded.drive.pointerLockChordTicksUntilDeadline() == 0,
            "the chord armed with no grab to release"
        )
        chorded.drive.notePointerLockGrab(.held)
        chorded.drive.notePointerLockChord(chord)
        let hold = Ubiquitty.Input.pointerLockBreakoutHoldTicks
        check(
            chorded.drive.pointerLockChordTicksUntilDeadline() == hold,
            "the chord's wake-up is \(chorded.drive.pointerLockChordTicksUntilDeadline()) ticks, not the hold of \(hold)"
        )
        setenv("UBIQUITTY_FAKE_TICKS", String(hold - 1), 1)
        check(chorded.drive.tickPointerLockChord(chord) == .keep, "a tick short of the hold broke out")
        setenv("UBIQUITTY_FAKE_TICKS", String(hold), 1)
        check(
            chorded.drive.tickPointerLockChord(chord) == .breakOut,
            "the hold elapsed with the chord down and the grab was kept"
        )
        check(
            !chorded.drive.readSnapshot().mouseRelativePointerLockActive,
            "a break-out left the mode set, so a hung application could re-trap the pointer"
        )
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)

        // The chord through this arm's own wire. The Simulator has no keyboard
        // for GameController to read, so the keys are supplied; what is
        // asserted is the arm's part -- a press edge reports, the wake-up is
        // booked at Core's deadline, and the hold ends in a release that
        // clears the mode -- with pinned ticks standing in for the wake-up.
        guard let wired = TerminalSurface(rows: 24, columns: 80) else {
            SmokeLaunch.report("pointer-lock: FAIL: no surface for the chord wire leg")
            return false
        }
        var wiredKeys = Ubiquitty.Input.PointerLockKeyState()
        wiredKeys.isControlHeld = true
        wiredKeys.isCommandHeld = true
        wired.overridePointerLockChordKeys { wiredKeys }
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)
        wired.feed(Data("\u{1b}[?7403h".utf8))
        wired.reportPointerLockChordEdge()
        check(wired.drive.pointerLockChordTicksUntilDeadline() == 0, "the arm armed the chord with no grab held")
        wired.reportPointerLockGrab(.held)
        wired.reportPointerLockChordEdge()
        let holdTicks = Ubiquitty.Input.pointerLockBreakoutHoldTicks
        check(
            wired.drive.pointerLockChordTicksUntilDeadline() == holdTicks,
            "a press edge under a grab did not arm the chord through the arm"
        )
        wiredKeys.isAnyNonModifierKeyHeld = true
        wired.reportPointerLockChordEdge()
        check(wired.drive.pointerLockChordTicksUntilDeadline() == 0, "a key joining the pair did not disarm through the arm")
        wiredKeys.isAnyNonModifierKeyHeld = false
        wired.reportPointerLockChordEdge()
        check(
            wired.drive.pointerLockChordTicksUntilDeadline() == holdTicks,
            "the key's release did not let the pair arm again through the arm"
        )
        // The arm booked its one wake-up at Core's deadline; the pinned clock
        // is moved past the hold and the run loop is pumped until it fires, so
        // the release is the arm's own handler's doing, not a call made here.
        setenv("UBIQUITTY_FAKE_TICKS", String(holdTicks), 1)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Double(holdTicks + 12) / 60.0))
        check(!wired.drive.readSnapshot().mouseRelativePointerLockActive, "the arm's wake-up fired and the mode is still set")
        check(wired.drive.pointerLockChordTicksUntilDeadline() == 0, "the arm's wake-up fired and the chord is still armed")
        setenv("UBIQUITTY_FAKE_TICKS", "0", 1)
        wired.overridePointerLockChordKeys(nil)

        for failure in failures {
            SmokeLaunch.report("pointer-lock: FAIL: \(failure)")
        }
        let total = 25
        SmokeLaunch.report("pointer-lock: \(total - failures.count)/\(total) checks held")
        return failures.isEmpty
    }
}
