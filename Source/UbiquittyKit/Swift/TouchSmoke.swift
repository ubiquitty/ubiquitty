// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TouchSmoke.swift — the touch gestures are installed, and they mean what the
// terminal says they mean.
//
// Two things can go wrong independently and neither shows up in a build. The
// recognisers can be absent: every gesture compiles, none is attached to a
// view, and the phone has no scrollback, no selection and no way to press a
// button. Or they can be
// present and route to the wrong answer: a tap that summons the keyboard when
// the keyboard is already up types nothing, and a swipe that moves the local
// view under a program that asked for wheel reports scrolls the wrong thing.
//
// So this asserts both edges — that the view carries the recognisers, and that
// the fact layer under them answers each rule.
//
// The join between them is what asserting both edges does not cover. Every behavioural leg
// below drives the fact layer directly, so a recogniser callback that does nothing at all passes
// every one of them: with `handleFontZoomPinch` returning at once, a pinch does nothing on a
// simulator and each of those legs still reports ok. `recogniserCallbacksReachTheirRules` drives
// the two adapters that carry logic.
//
// Every leg here has been shown able to fail, by deleting what it covers and watching it go red:
// gesturesInstalled (pinch recogniser not attached), swipe (forwardScroll inert), tap (the
// keyboard ask removed), selection (selectionDrag inert), zoom (resizeGridToBounds removed from
// the font-zoom apply), menu (copy inert), and both halves of the join leg. A leg that still
// passed was measuring the ENVIRONMENT rather than the feature.

#if canImport(UIKit)

import Foundation
import UIKit
internal import UbiquittyCore

/// The launch-argument entry point.
public enum TouchSmokeEntry {
    /// Runs the touch smoke.
    ///
    /// - Returns: Whether every leg passed.
    @MainActor
    public static func run() -> Bool { TouchSmoke.run() }
}

enum TouchSmoke {
    @MainActor
    static func run() -> Bool {
        // Through the factory, so the surface carries a renderer: the cell size
        // comes from the renderer, and without one every point resolves to no
        // cell at all — a gesture that reports nothing while every assertion
        // about the gesture still passes.
        guard let surface = TerminalSurface(rows: 24, columns: 80, fontFamily: "Menlo", pointSize: 13)
        else {
            return failed("Core declined a surface, or the renderer could not be built")
        }
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else {
            return failed("no window scene, so no view is ever asked to draw")
        }
        let window = UIWindow(windowScene: scene)
        surface.frame = window.bounds
        window.addSubview(surface)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        guard gesturesInstalled(surface) else { return false }
        guard settle(surface) else { return false }
        guard surface.publishedGrid.columns > 1, surface.publishedGrid.rows > 1 else {
            return failed(
                "the surface published a \(surface.publishedGrid.columns)x\(surface.publishedGrid.rows) grid, so every point clamps to one cell"
            )
        }
        guard swipeMovesTheView(surface) else { return false }
        guard tapRoutesByKeyboard(surface) else { return false }
        guard doubleTapDragSelects(surface) else { return false }
        guard aRichTextWordDragSelectsCharacters(surface) else { return false }
        guard heldDragGrowsWithOutput(surface) else { return false }
        guard theLoupeFollowsAHoldOnTheGlass(surface) else { return false }
        guard pinchZoomsTheFont(surface) else { return false }
        guard theEditMenuCopies(surface) else { return false }
        guard recogniserCallbacksReachTheirRules(surface) else { return false }
        guard aTwoFingerTapAsksForSettingsAndStealsNothing(surface) else { return false }
        guard aTwoFingerSwipeSwitchesConnectionsAndAPinchDoesNot(surface) else { return false }
        guard aSidewaysPanSwitchesTabsAndAnUprightOneScrolls(surface) else { return false }
        guard aLateSecondFingerSwitchesConnectionsNotTabs(surface) else { return false }
        guard aCompositionSendsNothingUntilItCommits(surface) else { return false }
        guard aControlChordEncodesThroughCore(surface) else { return false }
        // Each answers on its own, so one going red does not hide another.
        let trackingLegs = [
            aSwipeReachesATrackingProgramAsWheelReports(surface),
            aTrackpadScrollKeepsItsSidewaysTravel(surface),
            heldModifiersReachThePointerFacts(surface),
            theTouchSelectionGestureSelectsUnderTracking(surface),
            aDoubleTapDragIsTheTrackingProgramsDrag(surface),
            aPointerHoldIsTheTrackingProgramsDrag(surface),
        ]
        guard !trackingLegs.contains(false) else { return false }
        // Last: run ahead of the settings leg, these left the simulator
        // reporting a hardware keyboard, which turns that leg's control tap
        // into a click.
        guard handlesFollowTheSelectionAndMoveIt(surface) else { return false }
        guard theScrollbackPositionIsReported() else { return false }

        report(
            "touch smoke: ok — the recognisers are attached, a swipe scrolls, a tap routes by keyboard, a double-tap drag selects, a held drag grows with output, a hold on the glass shows the loupe where a pointer's hold and a hold over a selection do not, a pinch zooms, the menu copies, the pinch and pan callbacks reach the rules under them, a two-finger tap asks for settings without becoming a click, a two-finger swipe switches connections where a pinch zooms and the two recognise together, a sideways pan switches tabs without scrolling, a second finger joining a pan makes it a connection swipe, a composition sends nothing until it commits, a control chord folds to its byte in Core, a swipe under a tracking program reaches it as wheel reports, a trackpad scroll keeps its sideways travel, the held modifiers reach every pointer fact, a hold on the glass selects under a tracking program, and a double-tap drag and a pointer's hold are that program's drag"
        )
        return true
    }

    /// Runs `body` against a program that tracks the mouse the way tmux does
    /// with its mouse option on, recording what the program receives.
    ///
    /// The bytes are read where an embedder feeding a streamless session reads
    /// them — the handler the iOS SSH carrier installs — so a report that never
    /// reaches that handler never reaches the program over SSH either.
    ///
    /// - Parameters:
    ///   - surface: The surface to run against.
    ///   - body: The leg, handed the recorder.
    /// - Returns: What `body` returned.
    @MainActor
    private static func underATrackingProgram(_ surface: TerminalSurface, _ body: (HostBytesRecorder) -> Bool) -> Bool {
        let recorder = HostBytesRecorder()
        surface.drive.setReplyHandler { bytes in recorder.append(bytes) }
        surface.feed(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2Jselect these words under tmux\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8))
        guard settle(surface) else { return false }
        surface.clearSelection()
        returnToBottom(surface)
        recorder.clear()
        let held = surface.isKeyboardPresented
        surface.isKeyboardPresented = true
        defer {
            surface.isKeyboardPresented = held
            surface.feed(Data("\u{1b}[?1006l\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1049l".utf8))
            surface.drive.setReplyHandler(nil)
            surface.clearSelection()
        }
        guard surface.drive.readSnapshot().mouseReportsActive else {
            return failed("tracking: the program's mouse modes never reached the model")
        }
        return body(recorder)
    }

    /// A one-finger swipe under a program tracking the mouse is wheel reports
    /// the program receives, on every callback of a pan that settled vertical.
    ///
    /// tmux with its mouse option on turns those reports into its own scroll,
    /// so a swipe that reaches it as nothing — or as the local view moving under
    /// a screen that has no history — is "scrolling inside tmux does not work".
    /// Driven through the recogniser's callback, so the axis lock and the
    /// per-callback delta are on the path.
    @MainActor
    private static func aSwipeReachesATrackingProgramAsWheelReports(_ surface: TerminalSurface) -> Bool {
        underATrackingProgram(surface) { recorder in
            let wheelUp = "\u{1b}[<64;"
            let wheelDown = "\u{1b}[<65;"
            let pan = StubPan()
            pan.stubLocation = CGPoint(x: 40, y: 40)
            pan.stubState = .began
            pan.stubTranslation = CGPoint(x: 0, y: 60)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
            let first = recorder.count(of: wheelUp)
            guard first > 0, recorder.count(of: wheelDown) == 0 else {
                return failed("tracking swipe: dragging the content down sent '\(recorder.text)', wanted wheel-up reports")
            }
            guard surface.viewOffset == 0 else {
                return failed("tracking swipe: the swipe moved the local view to \(surface.viewOffset) instead of reporting")
            }
            pan.stubState = .changed
            pan.stubTranslation = CGPoint(x: 0, y: 120)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
            let second = recorder.count(of: wheelUp)
            guard second > first else {
                return failed("tracking swipe: a further callback of a settled pan sent no more reports (\(first) -> \(second))")
            }
            pan.stubState = .ended
            pan.stubTranslation = CGPoint(x: 0, y: 30)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
            guard recorder.count(of: wheelDown) > 0 else {
                return failed("tracking swipe: dragging back up sent no wheel-down report ('\(recorder.text)')")
            }
            pan.stubState = .possible
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)

            // A thumb's arc: the first callback leans sideways short of a swipe,
            // and later callbacks wander further across than down. The pan
            // settled vertical, so it is a scroll on every callback, and the
            // program hears no sideways wheel it never asked a reader for.
            recorder.clear()
            let arc = StubPan()
            arc.stubLocation = CGPoint(x: 200, y: 200)
            arc.stubState = .began
            arc.stubTranslation = CGPoint(x: 13, y: 7)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
            arc.stubState = .changed
            arc.stubTranslation = CGPoint(x: 20, y: 120)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
            let settled = recorder.count(of: wheelUp)
            guard settled > 0 else {
                return failed("tracking swipe: a pan that opened with a sideways lean sent '\(recorder.text)', wanted wheel-up reports")
            }
            arc.stubTranslation = CGPoint(x: 120, y: 160)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
            guard recorder.count(of: wheelUp) > settled else {
                return failed("tracking swipe: a settled pan that wandered sideways lost its downward travel ('\(recorder.text)')")
            }
            guard recorder.count(of: "\u{1b}[<66;") == 0, recorder.count(of: "\u{1b}[<67;") == 0 else {
                return failed("tracking swipe: a pan settled vertical sent a sideways wheel ('\(recorder.text)')")
            }
            arc.stubState = .ended
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
            arc.stubState = .possible
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
            return true
        }
    }

    /// A trackpad's scroll under a tracking program keeps its sideways travel.
    ///
    /// Only a finger's pan settles on an axis; a trackpad scroll carries no
    /// finger, so it is a scroll on both axes and a sideways one reaches the
    /// program as sideways wheel reports, as it does on the desktop.
    @MainActor
    private static func aTrackpadScrollKeepsItsSidewaysTravel(_ surface: TerminalSurface) -> Bool {
        underATrackingProgram(surface) { recorder in
            let scroll = StubPan()
            scroll.stubNumberOfTouches = 0
            scroll.stubLocation = CGPoint(x: 200, y: 200)
            scroll.stubState = .began
            scroll.stubTranslation = CGPoint(x: -120, y: 0)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: scroll)
            scroll.stubState = .changed
            scroll.stubTranslation = CGPoint(x: -240, y: 0)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: scroll)
            scroll.stubState = .possible
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: scroll)
            guard recorder.count(of: "\u{1b}[<66;") + recorder.count(of: "\u{1b}[<67;") > 0 else {
                return failed("trackpad scroll: a sideways scroll sent '\(recorder.text)', wanted sideways wheel reports")
            }
            return true
        }
    }

    /// The modifiers a hardware keyboard holds reach every pointer fact, so
    /// Core's rules about them hold on the phone as they do on the desktop.
    ///
    /// Shift is the observable one: it keeps a click and a drag local under a
    /// tracking program, and a wheel report carries its bit. Each claim has its
    /// unmodified twin beside it, so a recorder that heard nothing cannot pass.
    @MainActor
    private static func heldModifiersReachThePointerFacts(_ surface: TerminalSurface) -> Bool {
        underATrackingProgram(surface) { recorder in
            guard let point = surface.viewPoint(forRow: 0, column: 2),
                let end = surface.viewPoint(forRow: 0, column: 20)
            else {
                return failed("modifiers: the surface has no cell geometry")
            }
            let plainTap = StubTap()
            plainTap.stubState = .ended
            plainTap.stubLocation = point
            surface.perform(NSSelectorFromString("handleTap:"), with: plainTap)
            guard recorder.count(of: "\u{1b}[<0;3;1M") == 1, recorder.count(of: "\u{1b}[<0;3;1m") == 1 else {
                return failed("modifiers: the control failed — a plain tap sent '\(recorder.text)', wanted a press and a release")
            }

            recorder.clear()
            let shiftedTap = StubTap()
            shiftedTap.stubState = .ended
            shiftedTap.stubLocation = point
            shiftedTap.stubModifierFlags = .shift
            surface.perform(NSSelectorFromString("handleTap:"), with: shiftedTap)
            guard recorder.text.isEmpty else {
                return failed("modifiers: a Shift tap reached the program as '\(recorder.text)'; Shift keeps a click local")
            }

            let shiftedDrag = StubSelectPress()
            shiftedDrag.stubModifierFlags = .shift
            for (state, at) in [(UIGestureRecognizer.State.began, point), (.changed, end), (.ended, end)] {
                shiftedDrag.stubState = state
                shiftedDrag.stubLocation = at
                surface.perform(NSSelectorFromString("handleSelectionDrag:"), with: shiftedDrag)
            }
            guard recorder.text.isEmpty else {
                return failed("modifiers: a Shift drag reached the program as '\(recorder.text)'")
            }
            guard let selected = surface.selectedText, selected.contains("these") else {
                return failed("modifiers: a Shift drag selected '\(surface.selectedText ?? "nothing")'")
            }
            surface.clearSelection()

            let shiftedPan = StubPan()
            shiftedPan.stubLocation = point
            shiftedPan.stubState = .began
            shiftedPan.stubTranslation = CGPoint(x: 0, y: 60)
            shiftedPan.stubModifierFlags = .shift
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: shiftedPan)
            shiftedPan.stubState = .possible
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: shiftedPan)
            guard recorder.count(of: "\u{1b}[<68;") > 0, recorder.count(of: "\u{1b}[<64;") == 0 else {
                return failed("modifiers: a Shift swipe sent '\(recorder.text)', wanted wheel reports carrying the Shift bit")
            }
            return true
        }
    }

    /// A hold on the glass selects under a tracking program, and the program
    /// hears none of it.
    ///
    /// A phone with only the onscreen keyboard has no modifier to hold, so this
    /// gesture is the only way a reader of tmux or vim selects anything. The
    /// tap beside it still clicks, which is the control that the program is
    /// listening. The arbiter is offered the touch first, as UIKit offers it,
    /// so the hold's knowledge of where the touch came from is on the path.
    @MainActor
    private static func theTouchSelectionGestureSelectsUnderTracking(_ surface: TerminalSurface) -> Bool {
        underATrackingProgram(surface) { recorder in
            guard let point = surface.viewPoint(forRow: 0, column: 8),
                let end = surface.viewPoint(forRow: 0, column: 20)
            else {
                return failed("touch selection: the surface has no cell geometry")
            }
            guard hold(surface, offering: StubTouch(type: .direct), from: point, to: end) else {
                return failed("touch selection: the hold has no arbiter to learn its touch from")
            }
            guard recorder.text.isEmpty else {
                return failed("touch selection: the hold reached the program as '\(recorder.text)'")
            }
            guard let selected = surface.selectedText, selected.contains("these words") else {
                return failed(
                    "touch selection: the hold selected '\(surface.selectedText ?? "nothing")', wanted the words dragged across"
                )
            }
            surface.clearSelection()
            let tap = StubTap()
            tap.stubState = .ended
            tap.stubLocation = point
            surface.perform(NSSelectorFromString("handleTap:"), with: tap)
            guard recorder.count(of: "\u{1b}[<0;9;1M") == 1 else {
                return failed("touch selection: the control failed — a tap sent '\(recorder.text)', so the program was not listening")
            }
            return true
        }
    }

    /// A double-tap drag under a tracking program is the program's drag.
    ///
    /// The hold is the selection gesture, so a finger can still drag a tmux
    /// pane border or select in vim's own visual mode: the press, the motion
    /// and the release all reach the program.
    @MainActor
    private static func aDoubleTapDragIsTheTrackingProgramsDrag(_ surface: TerminalSurface) -> Bool {
        underATrackingProgram(surface) { recorder in
            guard let point = surface.viewPoint(forRow: 0, column: 8),
                let end = surface.viewPoint(forRow: 0, column: 20)
            else {
                return failed("touch drag: the surface has no cell geometry")
            }
            let drag = StubSelectPress()
            for (state, at) in [(UIGestureRecognizer.State.began, point), (.changed, end), (.ended, end)] {
                drag.stubState = state
                drag.stubLocation = at
                surface.perform(NSSelectorFromString("handleSelectionDrag:"), with: drag)
            }
            guard recorder.count(of: "\u{1b}[<0;9;1M") == 1, recorder.count(of: "\u{1b}[<32;21;1M") == 1,
                recorder.count(of: "\u{1b}[<0;21;1m") == 1
            else {
                return failed("touch drag: a double-tap drag sent '\(recorder.text)', wanted a press, a motion and a release")
            }
            guard !surface.hasSelection else {
                return failed("touch drag: a double-tap drag the program took also selected '\(surface.selectedText ?? "")'")
            }
            return true
        }
    }

    /// A hold from a pointer is an ordinary drag, which a tracking program
    /// receives.
    ///
    /// A pointer has Shift to hold, so its hold is not the platform's
    /// selection gesture. The twin of the touch selection leg, differing only
    /// in the touch the arbiter is offered.
    @MainActor
    private static func aPointerHoldIsTheTrackingProgramsDrag(_ surface: TerminalSurface) -> Bool {
        underATrackingProgram(surface) { recorder in
            guard let point = surface.viewPoint(forRow: 0, column: 8),
                let end = surface.viewPoint(forRow: 0, column: 20)
            else {
                return failed("pointer hold: the surface has no cell geometry")
            }
            guard hold(surface, offering: StubTouch(type: .indirectPointer), from: point, to: end) else {
                return failed("pointer hold: the hold has no arbiter to learn its touch from")
            }
            guard recorder.count(of: "\u{1b}[<0;9;1M") == 1, recorder.count(of: "\u{1b}[<32;21;1M") == 1,
                recorder.count(of: "\u{1b}[<0;21;1m") == 1
            else {
                return failed("pointer hold: a pointer's hold sent '\(recorder.text)', wanted a press, a motion and a release")
            }
            return true
        }
    }

    /// Offers the installed hold a touch through its delegate, then drives the
    /// handler through a hold from one point to another.
    ///
    /// - Returns: Whether the hold and its delegate were there to drive.
    @MainActor
    private static func hold(_ surface: TerminalSurface, offering touch: UITouch, from start: CGPoint, to end: CGPoint) -> Bool {
        guard let installed = surface.holdPress, let arbiter = installed.delegate else { return false }
        _ = arbiter.gestureRecognizer?(installed, shouldReceive: touch)
        let press = StubSelectPress()
        for (state, at) in [(UIGestureRecognizer.State.began, start), (.changed, end), (.ended, end)] {
            press.stubState = state
            press.stubLocation = at
            surface.perform(NSSelectorFromString("handleHoldPress:"), with: press)
        }
        return true
    }

    /// A control chord folds to its byte in the terminal, not in the frontend.
    ///
    /// The control row sends the letter and the Control bit and lets Core fold
    /// them: a row that spelled 0x03 itself would send it to a host that had
    /// asked, through modifyOtherKeys or the Kitty flags, to see the two
    /// separately. Asserting the byte is what says the fold happened at all —
    /// the macOS arm pins the same three (Ctrl+A 0x01, Ctrl+K 0x0B, backspace
    /// 0x7F) from its own key-routing scenario.
    @MainActor
    private static func aControlChordEncodesThroughCore(_ surface: TerminalSurface) -> Bool {
        let recorder = TransmitRecorder()
        surface.observer = recorder
        defer { surface.observer = nil }

        for (letter, wanted) in [("c", UInt8(0x03)), ("a", UInt8(0x01)), ("k", UInt8(0x0B))] {
            recorder.transmittedBytes.removeAll()
            var press = Ubiquitty.Runtime.KeyPress()
            let scalar = letter.unicodeScalars.first?.value ?? 0
            press.unshiftedCodePoint = scalar
            press.shiftedCodePoint = scalar
            press.modifiers = UInt32(Ubiquitty.Keys.Keymap.keymapModifierCtrl)
            press.wasModified = true
            guard surface.sendKey(press) else {
                return failed("chord: Ctrl+\(letter) encoded to nothing")
            }
            guard recorder.transmittedBytes.count == 1 else {
                return failed("chord: Ctrl+\(letter) transmitted \(recorder.transmittedBytes.count) time(s), wanted 1")
            }
            guard recorder.transmittedBytes[0] == [wanted] else {
                return failed(
                    "chord: Ctrl+\(letter) encoded to \(recorder.transmittedBytes[0]), wanted [\(wanted)]"
                )
            }
        }
        return true
    }

    /// A composition sends nothing until it commits, and then sends once.
    ///
    /// The two halves an input method needs from the terminal. Intermediate
    /// text must not reach the host — a program receiving it would see every
    /// candidate the user cycled past — and the commit must arrive as user
    /// input rather than a raw write, so it snaps to the tail and counts as
    /// activity the way a keystroke does.
    ///
    /// Drives the surface's own composition seam, which is the half both shells
    /// share: UIKit's `UITextInput` and AppKit's `NSTextInputClient` are the
    /// adapters that spell these calls.
    @MainActor
    private static func aCompositionSendsNothingUntilItCommits(_ surface: TerminalSurface) -> Bool {
        let recorder = TransmitRecorder()
        surface.observer = recorder
        defer { surface.observer = nil }

        surface.composeText("にほ")
        guard surface.isComposing else {
            return failed("composition: marking text left the surface not composing")
        }
        guard recorder.transmissions.isEmpty else {
            return failed(
                "composition: transmitted \(recorder.transmissions) while still composing; the host sees nothing until it commits"
            )
        }

        // Re-marking replaces rather than appends: an input method spells the
        // whole composition again each time it changes.
        surface.composeText("にほん")
        guard surface.composedText == "にほん" else {
            return failed("composition: re-marking left \(surface.composedText)")
        }
        guard recorder.transmissions.isEmpty else {
            return failed("composition: re-marking transmitted \(recorder.transmissions)")
        }

        // The candidate window is placed at this rectangle. An empty one puts
        // the candidates in the corner instead of under the text.
        let anchor = surface.compositionAnchorRect()
        guard anchor.width > 0, anchor.height > 0 else {
            return failed("composition: the candidate anchor is empty, so candidates would sit in the corner")
        }

        surface.commitComposedText("日本")
        guard !surface.isComposing, surface.composedText.isEmpty else {
            return failed("composition: the commit left \(surface.composedText) in flight")
        }
        guard recorder.transmissions.count == 1 else {
            return failed("composition: the commit transmitted \(recorder.transmissions.count) time(s), wanted 1")
        }
        guard recorder.transmissions[0] == "日本" else {
            return failed("composition: committed \(recorder.transmissions[0]), wanted 日本")
        }

        surface.composeText("か")
        surface.cancelComposition()
        guard !surface.isComposing else {
            return failed("composition: cancelling left a composition in flight")
        }
        guard recorder.transmissions.count == 1 else {
            return failed("composition: cancelling transmitted \(recorder.transmissions)")
        }
        return true
    }

    /// The three recognisers reach the view at all.
    @MainActor
    private static func gesturesInstalled(_ surface: TerminalSurface) -> Bool {
        let recognizers = surface.gestureRecognizers ?? []
        let hasPan = recognizers.contains { recognizer in
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return pan.minimumNumberOfTouches == 1 && pan.maximumNumberOfTouches == 1
                && pan.allowedScrollTypesMask == .all
        }
        let hasTap = recognizers.contains { $0 is UITapGestureRecognizer }
        let hasSelect = recognizers.contains { recognizer in
            guard let press = recognizer as? UILongPressGestureRecognizer else { return false }
            return press.numberOfTapsRequired == 1
        }
        let hasPinch = recognizers.contains { $0 is UIPinchGestureRecognizer }
        // Delegated to the arbiter, or the hold never learns what kind of touch it is.
        let hasHold = recognizers.contains { recognizer in
            guard let press = recognizer as? UILongPressGestureRecognizer else { return false }
            return press.numberOfTapsRequired == 0 && press.delegate is TouchGestureArbiter
        }
        guard hasPan, hasTap, hasSelect, hasPinch, hasHold else {
            return failed(
                "gestures: pan=\(hasPan) tap=\(hasTap) selectDrag=\(hasSelect) pinch=\(hasPinch) hold=\(hasHold) — a missing recogniser is a gesture that compiles and never fires"
            )
        }
        return true
    }

    /// A pinch moves the font size, and returns to exactly where it started.
    @MainActor
    private static func pinchZoomsTheFont(_ surface: TerminalSurface) -> Bool {
        let configured = surface.configuredPointSize
        guard configured > 0 else {
            return failed("zoom: the surface carries no configured point size, so a zoom has nothing to offset")
        }
        guard surface.fontZoomOffset == 0, surface.zoomedPointSize == configured else {
            return failed("zoom: a fresh surface is already zoomed (\(surface.fontZoomOffset))")
        }

        // Measured, not assumed: the grid is whatever this window's bounds fit,
        // so a constant here compares against a number the surface never had
        // and the leg passes whatever the zoom did.
        let columnsBefore = surface.publishedGrid.columns
        guard columnsBefore > 0 else {
            return failed("zoom: no grid published before zooming")
        }

        surface.stepFontZoom(by: 2)
        let zoomedIn = surface.zoomedPointSize
        guard zoomedIn > configured else {
            return failed("zoom: stepping in left the size at \(zoomedIn), configured \(configured)")
        }
        // The grid follows the cell size, or the next frame draws the old row
        // count at the new scale.
        let columnsWhenLarger = surface.publishedGrid.columns
        guard columnsWhenLarger < columnsBefore else {
            return failed(
                "zoom: the grid did not re-fit — \(columnsBefore) columns at \(configured)pt, still \(columnsWhenLarger) at \(zoomedIn)pt"
            )
        }

        // Back to exactly the configured size: an offset that accumulated
        // rounding, or one clamped at an end, would land near it and not on it.
        surface.stepFontZoom(by: -2)
        guard surface.publishedGrid.columns == columnsBefore else {
            return failed(
                "zoom: returning left \(surface.publishedGrid.columns) columns, started at \(columnsBefore)"
            )
        }
        guard surface.fontZoomOffset == 0, surface.zoomedPointSize == configured else {
            return failed(
                "zoom: returning left offset \(surface.fontZoomOffset) and size \(surface.zoomedPointSize), wanted 0 and \(configured)"
            )
        }

        // Far past the end settles at the end rather than refusing, because a
        // pinch runs past the limit constantly.
        surface.applyFontZoom(offset: 10000)
        let clamped = surface.zoomedPointSize
        guard clamped > configured, clamped < 10000 else {
            return failed("zoom: an offset past the range settled at \(clamped)")
        }
        surface.resetFontZoom()
        guard surface.zoomedPointSize == configured else {
            return failed("zoom: reset left the size at \(surface.zoomedPointSize)")
        }
        return true
    }

    /// The edit menu copies a selection to the pasteboard.
    @MainActor
    private static func theEditMenuCopies(_ surface: TerminalSurface) -> Bool {
        surface.clearSelection()
        guard !surface.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil) else {
            return failed("menu: copy is offered with nothing selected")
        }

        surface.selectionDrag(.began, atViewPoint: CGPoint(x: 8, y: 8))
        surface.selectionDrag(.moved, atViewPoint: CGPoint(x: 200, y: 8))
        surface.selectionDrag(.ended, atViewPoint: CGPoint(x: 200, y: 8))
        guard let selected = surface.selectedText, !selected.isEmpty else {
            return failed("menu: nothing selected to copy")
        }
        // A hold over a selection is the menu's, so it leaves the selection as it was.
        let hold = StubSelectPress()
        for (state, at) in [
            (UIGestureRecognizer.State.began, CGPoint(x: 8, y: 40)), (.changed, CGPoint(x: 120, y: 40)), (.ended, CGPoint(x: 120, y: 40)),
        ] {
            hold.stubState = state
            hold.stubLocation = at
            surface.perform(NSSelectorFromString("handleHoldPress:"), with: hold)
        }
        guard surface.selectedText == selected else {
            return failed("menu: a hold over a selection replaced it with '\(surface.selectedText ?? "nothing")'")
        }
        guard surface.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil) else {
            return failed("menu: copy is not offered over a selection")
        }

        UIPasteboard.general.string = "not the text under test"
        surface.copy(nil)
        guard UIPasteboard.general.string == selected else {
            return failed(
                "menu: copy put \(UIPasteboard.general.string ?? "nothing") on the pasteboard, wanted the selection"
            )
        }
        surface.clearSelection()
        return true
    }

    /// A swipe moves the local view when no program is tracking the pointer.
    @MainActor
    private static func swipeMovesTheView(_ surface: TerminalSurface) -> Bool {
        // History to scroll into. Feeding more rows than the grid holds is what
        // puts lines above the viewport.
        for line in 0..<60 {
            surface.feed(Data("line \(line)\r\n".utf8))
        }
        guard settle(surface) else { return false }
        let before = surface.viewOffset
        // Dragging the content downward brings older lines in, which is the
        // sign a wheel reports for scrolling up.
        surface.forwardScroll(
            atViewPoint: CGPoint(x: 40, y: 40),
            deltaX: 0,
            deltaY: 120,
            isPrecise: true
        )
        let after = surface.viewOffset
        guard after > before else {
            return failed("swipe: viewOffset \(before) -> \(after); a downward drag must bring older lines into view")
        }
        // And back, so the smoke leaves the view where it found it.
        surface.forwardScroll(
            atViewPoint: CGPoint(x: 40, y: 40),
            deltaX: 0,
            deltaY: -240,
            isPrecise: true
        )
        return true
    }

    /// A tap asks for the keyboard until there is one, then it clicks.
    @MainActor
    private static func tapRoutesByKeyboard(_ surface: TerminalSurface) -> Bool {
        let observer = KeyboardAskRecorder()
        surface.observer = observer
        surface.isKeyboardPresented = false
        surface.tap(atViewPoint: CGPoint(x: 40, y: 40))
        guard observer.asks == 1 else {
            return failed("tap with no keyboard: asked \(observer.asks) times, wanted 1")
        }

        surface.isKeyboardPresented = true
        // The point must resolve to a cell, or the click is a no-op that this
        // leg would pass anyway — the surface reports nothing and asks nothing.
        guard surface.reportCell(atViewPoint: CGPoint(x: 40, y: 40)) != nil else {
            return failed("tap with the keyboard up resolved no cell, so it pressed nothing")
        }
        surface.tap(atViewPoint: CGPoint(x: 40, y: 40))
        guard observer.asks == 1 else {
            return failed("tap with the keyboard up asked for it again — a reader who can type cannot press a button")
        }
        surface.observer = nil
        return true
    }

    /// A double-tap drag opens and extends a selection.
    @MainActor
    private static func doubleTapDragSelects(_ surface: TerminalSurface) -> Bool {
        surface.clearSelection()
        guard !surface.hasSelection else {
            return failed("selection: a cleared selection still reads as selected")
        }
        let start = CGPoint(x: 8, y: 8)
        let end = CGPoint(x: 200, y: 8)
        let startCell = surface.reportCell(atViewPoint: start)
        let endCell = surface.reportCell(atViewPoint: end)
        surface.selectionDrag(.began, atViewPoint: start)
        let afterPress = surface.hasSelection
        surface.selectionDrag(.moved, atViewPoint: end)
        let afterDrag = surface.hasSelection
        surface.selectionDrag(.ended, atViewPoint: end)
        guard surface.hasSelection, let selected = surface.selectedText, !selected.isEmpty else {
            return failed(
                "selection: a double-tap drag selected nothing"
                    + " (press \(startCell.map { "r\($0.row)c\($0.column)" } ?? "no cell")"
                    + " -> drag \(endCell.map { "r\($0.row)c\($0.column)" } ?? "no cell");"
                    + " selected after press \(afterPress), after drag \(afterDrag);"
                    + " grid \(surface.publishedGrid.columns)x\(surface.publishedGrid.rows))"
            )
        }
        surface.clearSelection()
        return true
    }

    /// A selection grows handles at its ends, and dragging the end handle
    /// moves that end while the start stays.
    @MainActor
    private static func handlesFollowTheSelectionAndMoveIt(_ surface: TerminalSurface) -> Bool {
        surface.clearSelection()
        surface.feed(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2Jalpha beta gamma delta".utf8))
        returnToBottom(surface)
        defer {
            surface.clearSelection()
            surface.feed(Data("\u{1b}[?1049l".utf8))
        }
        guard let renderer = surface.renderer, let handles = surface.selectionHandles else {
            return failed("handles: no renderer, or no handles installed")
        }
        let cell = renderer.drawnCellSize(for: surface)
        let insets = renderer.gridInsets(for: surface)
        let rowMiddle = insets.top + cell.height / 2
        // A press and release with a click count of two: the word "beta".
        let word = CGPoint(x: insets.left + cell.width * 7.5, y: rowMiddle)
        surface.selectionDrag(.began, atViewPoint: word)
        surface.selectionDrag(.ended, atViewPoint: word)
        // The clear above arms the erase hold, which withholds frames until
        // the screen has been quiet a moment; the handles follow a frame.
        drawUntil(surface) { !handles.start.isHidden }
        guard surface.selectedText == "beta" else {
            return failed("handles: a double-tap on beta selected \(surface.selectedText ?? "nothing")")
        }
        guard !handles.start.isHidden, !handles.end.isHidden,
            abs(handles.start.frame.midX - (insets.left + cell.width * 6)) < 1,
            abs(handles.end.frame.midX - (insets.left + cell.width * 10)) < 1
        else {
            return failed(
                "handles: not on the word's edges (start \(handles.start.frame.midX), end \(handles.end.frame.midX), cell \(cell.width))"
            )
        }
        let gammaEnd = CGPoint(x: insets.left + cell.width * 16, y: rowMiddle)
        surface.moveSelectionHandle(isStart: false, phase: .began, to: gammaEnd, offersMenu: false)
        guard surface.selectionLoupe != nil else {
            return failed("handles: dragging the end handle showed no loupe")
        }
        surface.moveSelectionHandle(isStart: false, phase: .ended, to: gammaEnd, offersMenu: false)
        guard surface.selectionLoupe == nil else {
            return failed("handles: the loupe stayed up after the end handle was let go")
        }
        guard surface.selectedText == "beta gamma" else {
            return failed("handles: dragging the end handle past gamma selected \(surface.selectedText ?? "nothing")")
        }
        surface.clearSelection()
        drawUntil(surface) { handles.start.isHidden }
        guard handles.start.isHidden, handles.end.isHidden else {
            return failed("handles: a cleared selection kept its handles")
        }
        return true
    }

    /// Draws frames until `isDone`, for a second at most: a hold may
    /// withhold the first few.
    @MainActor
    private static func drawUntil(_ surface: TerminalSurface, _ isDone: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            surface.needsDisplay = true
            surface.drawSurfaceFrame()
            surface.layoutSelectionHandles()
            if isDone() { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        } while Date() < deadline
    }

    /// A view scrolled back reports where it stands and how much output
    /// arrived below it, and Jump to Bottom returns it to the tail.
    @MainActor
    private static func theScrollbackPositionIsReported() -> Bool {
        // History depth is a creation parameter. Seed a fresh terminal before
        // its first retained row, rather than reseeding an existing store.
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            return failed("scrollback: Core declined the capped-history surface")
        }
        surface.drive.withTerminal { Ubiquitty.setScrollbackLimit($0, 32) }
        // Exercise eviction: retained history must stay full while the badge
        // still counts output arriving below the held view.
        for line in 0..<(surface.publishedGrid.rows + 40) { surface.feed(Data("history \(line)\r\n".utf8)) }
        surface.serviceIngestEvents()
        let retained = surface.drive.readSnapshot().history.retainedRows
        guard retained == 32 else { return failed("scrollback: the history limit was not reached: \(retained)") }
        returnToBottom(surface)
        surface.offsetView(byLines: 5)
        guard let back = surface.reportedScrollbackPosition, back.rowsAboveTail == 5, back.rowsArrivedBelow == 0 else {
            return failed("scrollback: five lines back reported \(String(describing: surface.reportedScrollbackPosition))")
        }
        for line in 0..<3 { surface.feed(Data("arrived \(line)\r\n".utf8)) }
        surface.serviceIngestEvents()
        guard surface.drive.readSnapshot().history.retainedRows == retained else {
            return failed("scrollback: new output grew history past its limit")
        }
        guard let held = surface.reportedScrollbackPosition, held.isScrolledBack, held.rowsArrivedBelow >= 3 else {
            return failed("scrollback: output below a held view reported \(String(describing: surface.reportedScrollbackPosition))")
        }
        surface.scrollToTail()
        guard let tail = surface.reportedScrollbackPosition, !tail.isScrolledBack, tail.rowsArrivedBelow == 0 else {
            return failed("scrollback: Jump to Bottom left \(String(describing: surface.reportedScrollbackPosition))")
        }
        return true
    }

    /// A double-tap drag keeps the words' character bounds inside a rich text block.
    @MainActor
    private static func aRichTextWordDragSelectsCharacters(_ surface: TerminalSurface) -> Bool {
        surface.clearSelection()
        surface.feed(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2J\u{1b}]7404;w=30:h=3;{\\rtf1\\fs24 alpha beta gamma delta}\u{1b}\\".utf8))
        returnToBottom(surface)
        defer {
            surface.clearSelection()
            surface.feed(Data("\u{1b}[?1049l".utf8))
        }
        guard let renderer = surface.renderer else {
            return failed("rich-text drag: no renderer")
        }
        let cell = renderer.drawnCellSize(for: surface)
        let insets = renderer.gridInsets(for: surface)
        // The layout owns character positions; finding the middle of each
        // word through its carets keeps this gesture independent of the font.
        let points =
            surface.drive.withTerminal { terminal -> [CGPoint] in
                var beta: CGPoint?
                var gamma: CGPoint?
                for step in 0..<600 {
                    let x = (Double(step) + 0.5) / 20
                    let caret = Ubiquitty.Selection.resolveSelectionCaret(terminal, 0, 0, Int32(x), x, 0.3)
                    let point = CGPoint(x: insets.left + x * cell.width, y: insets.top + 0.3 * cell.height)
                    if caret.subCaret == 7 { beta = point }
                    if caret.subCaret == 13 { gamma = point }
                    if let beta, let gamma { return [beta, gamma] }
                }
                return []
            } ?? []
        guard points.count == 2 else {
            return failed("rich-text drag: the block's beta and gamma have no character carets")
        }
        for (start, end, pressedWord) in [(points[0], points[1], "beta"), (points[1], points[0], "gamma")] {
            surface.clearSelection()
            let drag = StubSelectPress()
            drag.stubState = .began
            drag.stubLocation = start
            surface.perform(NSSelectorFromString("handleSelectionDrag:"), with: drag)
            guard surface.selectedText == pressedWord else {
                return failed("rich-text drag: the press selected '\(surface.selectedText ?? "nothing")', wanted '\(pressedWord)'")
            }
            drag.stubState = .changed
            drag.stubLocation = end
            surface.perform(NSSelectorFromString("handleSelectionDrag:"), with: drag)
            guard surface.selectedText == "beta gamma" else {
                return failed("rich-text drag: motion selected '\(surface.selectedText ?? "nothing")', wanted 'beta gamma'")
            }
            drag.stubState = .ended
            surface.perform(NSSelectorFromString("handleSelectionDrag:"), with: drag)
            guard surface.selectedText == "beta gamma" else {
                return failed("rich-text drag: release changed the selected words")
            }
        }
        return true
    }

    /// A drag still held while output scrolls grows to the pointer's row.
    ///
    /// The touch path's own wiring: a held drag keeps Core's gesture open, so
    /// the output policy re-reads the retained pointer row against the moved
    /// content. Core's rule is proven headless; what only this surface can
    /// answer is whether a UIKit drag leaves the gesture open at all.
    @MainActor
    private static func heldDragGrowsWithOutput(_ surface: TerminalSurface) -> Bool {
        surface.clearSelection()
        let rows = surface.publishedGrid.rows
        guard rows >= 4 else {
            return failed("output-follow: the grid has \(rows) rows, too few for three marker rows")
        }
        // Past the last row, so the markers land as the last three rows and
        // the lines fed later scroll them.
        for line in 0..<(rows + 4) {
            surface.feed(Data("filler \(line)\r\n".utf8))
        }
        surface.feed(Data("anchor\r\nmiddle\r\npointer".utf8))
        let filled = Int(surface.drive.readSnapshot().scrollbackCount)
        surface.followTailOrHoldViewport()
        guard let start = surface.viewPoint(forRow: rows - 3, column: 1),
            let end = surface.viewPoint(forRow: rows - 1, column: 1)
        else {
            return failed("output-follow: the surface has no cell geometry")
        }
        surface.selectionDrag(.began, atViewPoint: start)
        surface.selectionDrag(.moved, atViewPoint: end)
        guard let before = surface.selectedText, before.contains("anchor"), !before.contains("new") else {
            return failed("output-follow: the held drag did not select the marker rows (got \(surface.selectedText ?? "nil"))")
        }
        surface.feed(Data("\r\nnew\r\nmore".utf8))
        let grown = Int(surface.drive.readSnapshot().scrollbackCount)
        guard grown > filled else {
            return failed("output-follow: two fed lines grew no scrollback")
        }
        surface.followTailOrHoldViewport()
        let after = surface.selectedText ?? ""
        surface.selectionDrag(.ended, atViewPoint: end)
        surface.clearSelection()
        guard after.contains("anchor"), after.contains("new") else {
            return failed("output-follow: a held drag did not grow to the moved pointer row (got \(after))")
        }
        return true
    }

    /// A hold on the glass shows the system loupe over the row it selects on
    /// and puts it away as the finger lifts.
    ///
    /// The controls are the two holds that select nothing a finger covers: a
    /// pointer's, which is a mouse's drag, and a hold over a selection, which
    /// opens the edit menu instead. Each is offered to the arbiter first, as
    /// UIKit offers it, so the hold's knowledge of its touch is on the path.
    @MainActor
    private static func theLoupeFollowsAHoldOnTheGlass(_ surface: TerminalSurface) -> Bool {
        surface.clearSelection()
        surface.feed(Data("\u{1b}[?1049h\u{1b}[Hthe loupe reads\r\nthese two rows".utf8))
        defer {
            surface.clearSelection()
            surface.feed(Data("\u{1b}[?1049l".utf8))
        }
        guard let installed = surface.holdPress, let arbiter = installed.delegate,
            let start = surface.viewPoint(forRow: 0, column: 5),
            let end = surface.viewPoint(forRow: 1, column: 8)
        else {
            return failed("loupe: no hold, no arbiter to offer it a touch, or no cell geometry")
        }
        /// Drives the hold through its three states, reporting whether a loupe was up after each.
        func hold(offering touch: UITouch) -> [Bool] {
            _ = arbiter.gestureRecognizer?(installed, shouldReceive: touch)
            let press = StubSelectPress()
            return [(UIGestureRecognizer.State.began, start), (.changed, end), (.ended, end)]
                .map { state, at in
                    press.stubState = state
                    press.stubLocation = at
                    surface.perform(NSSelectorFromString("handleHoldPress:"), with: press)
                    return surface.selectionLoupe != nil
                }
        }

        let pointer = hold(offering: StubTouch(type: .indirectPointer))
        surface.clearSelection()
        guard pointer == [false, false, false] else {
            return failed("loupe: a pointer's hold showed a loupe (began, moved, lifted: \(pointer))")
        }
        let glass = hold(offering: StubTouch(type: .direct))
        guard glass == [true, true, false] else {
            return failed("loupe: a hold on the glass wanted a loupe while held and none once lifted, got \(glass)")
        }
        guard surface.hasSelection else {
            return failed("loupe: the hold that showed the loupe selected nothing")
        }
        let caret = surface.selectionLoupeCaret(atViewPoint: CGPoint(x: end.x, y: end.y + 3))
        guard !caret.isNull, abs(caret.midY - end.y) < 0.5, abs(caret.minX - end.x) < 0.5 else {
            return failed("loupe: the caret it tracks is not on the finger's row at the finger (caret \(caret), finger \(end))")
        }
        let overSelection = hold(offering: StubTouch(type: .direct))
        guard overSelection == [false, false, false] else {
            return failed("loupe: a hold over a selection opened the edit menu and showed a loupe too, \(overSelection)")
        }
        return true
    }

    /// The recogniser callbacks reach the rules under them.
    ///
    /// Every other leg here drives the fact layer directly — `tap(atViewPoint:)`, `forwardScroll`,
    /// `selectionDrag` — and `gesturesInstalled` proves the recognisers exist. Neither touches the
    /// ADAPTER between them, so a handler that does nothing at all passes both: verified by making
    /// `handleFontZoomPinch` return immediately, after which a pinch did nothing on a real phone
    /// and this whole smoke still reported ok.
    ///
    /// Only the two adapters that carry logic are driven here. `handleTap` and the two press
    /// handlers forward a point and nothing else, and the surface already records the reason
    /// for that split — "what a recogniser adds is where the finger was, and that is the one part a
    /// test cannot assert about itself". These two are different: the pinch converts a scale into a
    /// zoom offset against a latched start, and the pan turns absolute translations into the
    /// per-callback deltas Core's sub-line accumulator expects. Both are arithmetic, and arithmetic
    /// is what goes wrong silently.
    @MainActor
    private static func recogniserCallbacksReachTheirRules(_ surface: TerminalSurface) -> Bool {
        // ---- the pinch adapter: scale -> offset, against the offset it latched at .began ----
        surface.resetFontZoom()
        let configured = surface.configuredPointSize
        guard configured > 0 else {
            return failed("join: no configured point size, so a pinch has nothing to scale")
        }
        let initialColumns = surface.publishedGrid.columns
        let pinch = StubPinch()
        pinch.stubState = .began
        pinch.stubScale = 1
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        pinch.stubState = .changed
        pinch.stubScale = 1.5
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        pinch.stubScale = 2
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        guard surface.zoomedPointSize == configured else {
            return failed("join: pinch callbacks measured fonts ahead of the display refresh")
        }
        surface.perform(NSSelectorFromString("frameDisplayLinkFired"))
        let afterPinchIn = surface.zoomedPointSize
        guard afterPinchIn > configured, surface.pendingPinchPointSize == nil,
            surface.publishedGrid.columns < initialColumns,
            surface.drive.withTerminal({ Int($0.columns) }) == surface.publishedGrid.columns,
            surface.metalLayer.affineTransform().isIdentity
        else {
            return failed("join: a live pinch did not resize the grid before release")
        }
        pinch.stubScale = 0.5
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        surface.perform(NSSelectorFromString("frameDisplayLinkFired"))
        let afterPinchOut = surface.zoomedPointSize
        guard afterPinchOut < afterPinchIn, surface.publishedGrid.columns > initialColumns else {
            return failed("join: reversing the pinch did not widen the live grid")
        }
        pinch.stubState = .ended
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        guard surface.zoomedPointSize == afterPinchOut, surface.pendingPinchPointSize == nil,
            !surface.isPinchingFont, !surface.drive.hasDeferredHistoryRewrap
        else {
            return failed("join: the pinch did not settle its final size and history")
        }
        pinch.stubState = .began
        pinch.stubScale = 1
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        pinch.stubState = .changed
        pinch.stubScale = 2
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        surface.perform(NSSelectorFromString("frameDisplayLinkFired"))
        pinch.stubState = .cancelled
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        guard surface.zoomedPointSize == afterPinchOut, surface.pendingPinchPointSize == nil,
            !surface.isPinchingFont, !surface.drive.hasDeferredHistoryRewrap
        else {
            return failed("join: a cancelled pinch did not restore its starting size and settle history")
        }
        surface.resetFontZoom()

        // ---- the pan adapter: absolute translation -> per-callback delta ----
        // Deep history first, and this leg's own: `viewOffset` stops at the top of the scrollback,
        // and with only the swipe leg's 60 lines it stops after THREE rows. A repeat-scroll
        // assertion under that ceiling is satisfied by the ceiling rather than by the adapter —
        // measured, not assumed: with the delta arithmetic broken the probe read
        // before=0 first=3 repeat=3 and the leg passed.
        for line in 0..<600 {
            surface.feed(Data("pan history \(line)\r\n".utf8))
        }
        guard settle(surface) else { return false }
        returnToBottom(surface)
        let offsetBefore = surface.viewOffset
        guard offsetBefore == 0 else {
            return failed("join: the view did not start at the bottom, offset \(offsetBefore)")
        }

        let pan = StubPan()
        pan.stubLocation = CGPoint(x: 40, y: 40)
        pan.stubState = .began
        pan.stubTranslation = CGPoint(x: 0, y: 60)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
        let offsetAfterFirst = surface.viewOffset
        guard offsetAfterFirst > offsetBefore else {
            return failed(
                "join: a pan of 60 points left viewOffset \(offsetBefore) -> \(offsetAfterFirst) — the recogniser is attached and its handler reaches no scroll"
            )
        }

        // The same ABSOLUTE translation again. The delta is zero, so a correct adapter forwards
        // nothing and the view holds; one that forwarded absolutes would scroll a second time.
        // There are 600 lines above, so neither answer is near the ceiling.
        pan.stubState = .changed
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
        let offsetAfterRepeat = surface.viewOffset
        guard offsetAfterRepeat == offsetAfterFirst else {
            return failed(
                "join: an unchanged translation scrolled again, \(offsetAfterFirst) -> \(offsetAfterRepeat) — the adapter forwards absolutes rather than deltas"
            )
        }

        // And a real further drag still moves, so the line above is not passing because the
        // adapter forwards nothing at all.
        pan.stubTranslation = CGPoint(x: 0, y: 120)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
        let offsetAfterMore = surface.viewOffset
        guard offsetAfterMore > offsetAfterRepeat else {
            return failed(
                "join: a further drag did not scroll, \(offsetAfterRepeat) -> \(offsetAfterMore) — the adapter stopped forwarding after the first callback"
            )
        }

        pan.stubState = .ended
        pan.stubTranslation = CGPoint(x: 0, y: -600)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
        returnToBottom(surface)
        return true
    }

    /// Puts the view back at the live edge.
    ///
    /// `viewOffset` clamps at zero, so one oversized negative scroll is reliable where a matched
    /// positive/negative pair is not — the pair only balances if every step landed as expected,
    /// which is the thing under test.
    @MainActor
    private static func returnToBottom(_ surface: TerminalSurface) {
        surface.forwardScroll(
            atViewPoint: CGPoint(x: 40, y: 40),
            deltaX: 0,
            deltaY: -100000,
            isPrecise: true
        )
    }

    /// A two-finger tap asks for settings, and does not become a one-finger tap.
    ///
    /// The theft this guards against is the two-finger touch routing into `handleTap` — which on a
    /// surface with no keyboard raises the keyboard ask, and with one up builds a pointer fact and
    /// sends a click no reader made.
    ///
    /// It asserts that through the KEYBOARD ask rather than through bytes on the wire: a pointer
    /// fact does not reach `didTransmit` — that hook is the text path — so counting transmissions
    /// would measure nothing.
    ///
    /// So the claim here is narrower than "sends no bytes" and it is the one that matters: the
    /// gesture does not enter the tap path at all. `tapRoutesByKeyboard` above already proves the
    /// keyboard ask fires for one finger, which is this leg's control — it is a leg rather than a
    /// line of reasoning, and it runs before this one.
    @MainActor
    private static func aTwoFingerTapAsksForSettingsAndStealsNothing(_ surface: TerminalSurface) -> Bool {
        let recorder = SettingsAskRecorder()
        surface.observer = recorder
        defer { surface.observer = nil }
        surface.isKeyboardPresented = false

        // The control, in this leg rather than borrowed: one finger with no keyboard raises the
        // ask. If this stopped holding, the assertion below would pass on a surface where no tap
        // raises anything, which is silence rather than restraint.
        surface.tap(atViewPoint: CGPoint(x: 40, y: 40))
        guard recorder.keyboardAsks == 1 else {
            return failed(
                "settings: the control failed — a one-finger tap raised \(recorder.keyboardAsks) keyboard asks, wanted 1, so this leg cannot tell a theft from silence"
                    + " (tracking \(surface.isMouseTrackingActive), link \(surface.link(atViewPoint: CGPoint(x: 40, y: 40), isCommandHeld: false) != nil),"
                    + " hardware keyboard \(surface.hasHardwareKeyboard), selection \(surface.hasSelection))"
            )
        }

        // The gesture under test, driven through the recogniser's own callback rather than the
        // rule beneath it, so an inert handler is caught rather than passed.
        let twoFingerTap = StubTap()
        twoFingerTap.stubState = .ended
        surface.perform(NSSelectorFromString("handleSettingsTap:"), with: twoFingerTap)

        guard recorder.settingsAsks == 1 else {
            return failed(
                "settings: a two-finger tap raised \(recorder.settingsAsks) settings asks, wanted 1 — the recogniser is attached and its handler reaches no host"
            )
        }
        guard recorder.keyboardAsks == 1 else {
            return failed(
                "settings: a two-finger tap also raised the keyboard ask — it routed into handleTap, so a mouse-reporting program would receive a click nobody made"
            )
        }
        return true
    }

    /// A two-finger swipe sideways asks for another connection, and a pinch does not.
    ///
    /// The pinch is the only real collision on this surface: also two fingers, and it begins
    /// identically. So this drives both through their own recogniser callbacks and asserts each
    /// reaches its own rule and not the other's — a swipe that also zoomed, or a pinch that also
    /// navigated, would be a reader losing their place by making the gesture they meant.
    ///
    /// The negative half needs a control, and it is in the leg: the swipe is shown to fire at all
    /// before a pinch is shown not to fire. Otherwise "the pinch did not navigate" would hold on
    /// a surface where nothing navigates.
    @MainActor
    private static func aTwoFingerSwipeSwitchesConnectionsAndAPinchDoesNot(_ surface: TerminalSurface) -> Bool {
        let recorder = SettingsAskRecorder()
        surface.observer = recorder
        defer { surface.observer = nil }

        // Far enough to pass the threshold at any plausible width.
        let leftward = StubPan()
        leftward.stubState = .ended
        leftward.stubTranslation = CGPoint(x: -surface.bounds.width, y: 0)
        leftward.stubLocation = CGPoint(x: 40, y: 40)
        surface.perform(NSSelectorFromString("handleConnectionSwipe:"), with: leftward)
        guard recorder.nextConnectionAsks == 1, recorder.previousConnectionAsks == 0 else {
            return failed(
                "connections: a two-finger swipe left raised \(recorder.nextConnectionAsks) next and \(recorder.previousConnectionAsks) previous asks, wanted 1 and 0 — the recogniser is attached and its handler reaches no host"
            )
        }
        let rightward = StubPan()
        rightward.stubState = .ended
        rightward.stubTranslation = CGPoint(x: surface.bounds.width, y: 0)
        rightward.stubLocation = CGPoint(x: 40, y: 40)
        surface.perform(NSSelectorFromString("handleConnectionSwipe:"), with: rightward)
        guard recorder.nextConnectionAsks == 1, recorder.previousConnectionAsks == 1 else {
            return failed("connections: a two-finger swipe right did not ask for the previous connection")
        }
        guard recorder.nextTabAsks == 0, recorder.previousTabAsks == 0 else {
            return failed("connections: a two-finger swipe asked for a tab, which is the one-finger swipe's")
        }

        // Vertical is a scroll everywhere else a reader touches; it must not navigate.
        let vertical = StubPan()
        vertical.stubState = .ended
        vertical.stubTranslation = CGPoint(x: 0, y: surface.bounds.height)
        vertical.stubLocation = CGPoint(x: 40, y: 40)
        surface.perform(NSSelectorFromString("handleConnectionSwipe:"), with: vertical)
        guard recorder.nextConnectionAsks + recorder.previousConnectionAsks == 2 else {
            return failed("connections: a two-finger drag down navigated, and everywhere else that is a scroll")
        }

        // And a pinch does not navigate. Driven through the pinch's own callback, so this is the
        // collision itself rather than a statement about touch counts.
        surface.resetFontZoom()
        let pinch = StubPinch()
        pinch.stubState = .began
        pinch.stubScale = 1
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        pinch.stubState = .changed
        pinch.stubScale = 2
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        guard recorder.nextConnectionAsks + recorder.previousConnectionAsks == 2 else {
            return failed("connections: a pinch navigated — the reader zoomed and lost their terminal")
        }
        pinch.stubState = .cancelled
        surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: pinch)
        surface.resetFontZoom()

        // The pinch and the connection pan see the same fingers, so they must recognise together:
        // under UIKit's default exclusion whichever passed its hysteresis first failed the other,
        // and a swipe whose spacing wavered zoomed instead of switching. Nothing else pairs.
        guard let arbiter = surface.touchGestureArbiter, let installedPinch = surface.fontZoomPinch,
            let installedPan = surface.connectionPan, let installedScroll = surface.scrollPan
        else {
            return failed("connections: the pinch, the two pans or their arbiter are not installed")
        }
        guard installedPinch.delegate === arbiter, installedPan.delegate === arbiter,
            arbiter.gestureRecognizer(installedPinch, shouldRecognizeSimultaneouslyWith: installedPan),
            arbiter.gestureRecognizer(installedPan, shouldRecognizeSimultaneouslyWith: installedPinch)
        else {
            return failed("connections: the pinch and the two-finger pan exclude each other, so the first to start decides alone")
        }
        guard !arbiter.gestureRecognizer(installedScroll, shouldRecognizeSimultaneouslyWith: installedPinch),
            !arbiter.gestureRecognizer(installedScroll, shouldRecognizeSimultaneouslyWith: installedPan)
        else {
            return failed("connections: the one-finger scroll recognises alongside a two-finger gesture")
        }

        // Recognising together, each lift decides on both facts. A swipe whose fingers held their
        // spacing switches and leaves the size alone, whichever recogniser hears the lift first;
        // the control is the same pinch with no travel, which must zoom, so "the size held" is
        // the swipe's doing and not a scale too small to change it.
        let travelled = StubPan()
        travelled.stubTranslation = CGPoint(x: -surface.bounds.width, y: 0)
        let still = StubPan()
        let sizeBefore = surface.zoomedPointSize
        func liftPinch(scale: CGFloat, alongside pan: StubPan) {
            surface.connectionPan = pan
            let lifting = StubPinch()
            lifting.stubState = .began
            lifting.stubScale = 1
            surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: lifting)
            lifting.stubState = .changed
            lifting.stubScale = scale
            surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: lifting)
            lifting.stubState = .ended
            surface.perform(NSSelectorFromString("handleFontZoomPinch:"), with: lifting)
            surface.connectionPan = installedPan
        }
        let swipeScale = 1 + TouchPanRule.pinchScaleTolerance - 0.01
        liftPinch(scale: swipeScale, alongside: still)
        guard surface.zoomedPointSize > sizeBefore else {
            return failed(
                "connections: the control failed — a pinch to \(swipeScale)x with no travel did not zoom, so the next line cannot tell a swipe from a scale too small to show"
            )
        }
        surface.resetFontZoom()
        liftPinch(scale: swipeScale, alongside: travelled)
        guard surface.zoomedPointSize == sizeBefore, surface.metalLayer.affineTransform().isIdentity else {
            return failed(
                "connections: a two-finger swipe whose spacing wavered zoomed the font to \(surface.zoomedPointSize) as it switched"
            )
        }
        surface.resetFontZoom()
        return true
    }

    /// A finger that joins a one-finger pan makes its sideways answer a connection, never a tab.
    ///
    /// The scroll pan takes one touch and ignores the rest, so a two-finger swipe whose first
    /// finger moved before the second landed is this pan's; it reached the tab path and switched
    /// tabs where the reader asked for a connection. The second finger is offered to the pan
    /// through its delegate, which is what this drives.
    @MainActor
    private static func aLateSecondFingerSwitchesConnectionsNotTabs(_ surface: TerminalSurface) -> Bool {
        let recorder = SettingsAskRecorder()
        surface.observer = recorder
        defer { surface.observer = nil }
        guard let arbiter = surface.touchGestureArbiter, let installedScroll = surface.scrollPan,
            installedScroll.delegate === arbiter
        else {
            return failed("late finger: the scroll pan has no arbiter to hear a second finger")
        }
        func swipe(withSecondFinger: Bool) {
            let pan = StubPan()
            pan.stubLocation = CGPoint(x: 200, y: 40)
            pan.stubState = .began
            pan.stubTranslation = CGPoint(x: -14, y: 0)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
            if withSecondFinger {
                _ = arbiter.gestureRecognizer(installedScroll, shouldReceive: UITouch())
            }
            pan.stubState = .ended
            pan.stubTranslation = CGPoint(x: -surface.bounds.width, y: 0)
            surface.perform(NSSelectorFromString("handleScrollPan:"), with: pan)
        }
        // The control: alone, the finger switches a tab.
        swipe(withSecondFinger: false)
        guard recorder.nextTabAsks == 1, recorder.nextConnectionAsks == 0 else {
            return failed("late finger: the control failed — one finger swiped left raised \(recorder.nextTabAsks) tab asks")
        }
        swipe(withSecondFinger: true)
        guard recorder.nextTabAsks == 1 else {
            return failed("late finger: a swipe a second finger joined switched tabs, where the reader asked for a connection")
        }
        guard recorder.nextConnectionAsks == 1 else {
            return failed("late finger: a swipe a second finger joined raised \(recorder.nextConnectionAsks) connection asks, wanted 1")
        }
        // And the note does not outlive its pan: the next one-finger swipe is a tab again.
        swipe(withSecondFinger: false)
        guard recorder.nextTabAsks == 2, recorder.nextConnectionAsks == 1 else {
            return failed("late finger: a second finger on one pan made the next pan a connection swipe too")
        }
        // A finger offered while no pan is under way is the pan's own first touch.
        _ = arbiter.gestureRecognizer(installedScroll, shouldReceive: UITouch())
        swipe(withSecondFinger: false)
        guard recorder.nextTabAsks == 3 else {
            return failed("late finger: a touch offered before the pan began counted as a second finger")
        }
        return true
    }

    /// A one-finger pan settles on one axis, and only a sideways one becomes a tab switch.
    ///
    /// Two halves. The rule on numbers: each row below is a pan the rule could get wrong, and
    /// the wrong answer for each is a different defect — a scroll that switches tabs, a swipe
    /// that scrolls first, a nudge that switches. Then the recogniser's own callback, so a
    /// handler that ignored the rule, or forwarded the sideways travel as a wheel before
    /// switching, is caught rather than passed.
    ///
    /// The callback half reads what the reader sees, the view's offset into history, with
    /// history to scroll into. Every sideways pan here also carries a downward drift larger than
    /// a line, so a handler that forwarded any of its travel would move the view; the upright
    /// pan is the control that the same drift does move it.
    @MainActor
    private static func aSidewaysPanSwitchesTabsAndAnUprightOneScrolls(_ surface: TerminalSurface) -> Bool {
        guard theTouchPanRuleHoldsOnNumbers() else { return false }

        for line in 0..<200 {
            surface.feed(Data("tab swipe history \(line)\r\n".utf8))
        }
        guard settle(surface) else { return false }
        returnToBottom(surface)
        let width = surface.bounds.width

        // The callback. A sideways pan travels in two steps and lifts; nothing may be forwarded
        // on the way, and the lift asks for exactly one tab.
        let recorder = SettingsAskRecorder()
        surface.observer = recorder
        defer { surface.observer = nil }
        let sideways = StubPan()
        sideways.stubLocation = CGPoint(x: 200, y: 40)
        sideways.stubState = .began
        sideways.stubTranslation = CGPoint(x: -20, y: 2)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: sideways)
        sideways.stubState = .changed
        sideways.stubTranslation = CGPoint(x: -width / 2, y: width / 6)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: sideways)
        guard surface.viewOffset == 0 else {
            return failed(
                "tab swipe: a sideways pan scrolled the view to \(surface.viewOffset) before it ended, so the program scrolled under a tab switch"
            )
        }
        guard recorder.nextTabAsks == 0 else {
            return failed("tab swipe: the tab changed before the finger lifted")
        }
        sideways.stubState = .ended
        sideways.stubTranslation = CGPoint(x: -width, y: width / 3)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: sideways)
        guard recorder.nextTabAsks == 1, recorder.previousTabAsks == 0 else {
            return failed(
                "tab swipe: a one-finger swipe left raised \(recorder.nextTabAsks) next and \(recorder.previousTabAsks) previous tab asks, wanted 1 and 0 — the handler reaches no host"
            )
        }
        guard surface.viewOffset == 0 else {
            return failed("tab swipe: the lift forwarded the swipe's travel as a wheel, the view moved to \(surface.viewOffset)")
        }
        sideways.stubState = .possible
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: sideways)

        let rightward = StubPan()
        rightward.stubLocation = CGPoint(x: 40, y: 40)
        rightward.stubState = .began
        rightward.stubTranslation = CGPoint(x: 20, y: 0)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: rightward)
        rightward.stubState = .ended
        rightward.stubTranslation = CGPoint(x: width, y: width / 3)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: rightward)
        guard recorder.previousTabAsks == 1, recorder.nextTabAsks == 1 else {
            return failed("tab swipe: a one-finger swipe right did not ask for the previous tab")
        }
        guard surface.viewOffset == 0 else {
            return failed("tab swipe: a rightward swipe scrolled the view to \(surface.viewOffset)")
        }
        rightward.stubState = .possible
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: rightward)

        // And upright: a scroll, never a tab, however far it wanders sideways after settling.
        let upright = StubPan()
        upright.stubLocation = CGPoint(x: 40, y: 40)
        upright.stubState = .began
        upright.stubTranslation = CGPoint(x: 0, y: width / 6)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: upright)
        let offsetAfterSettle = surface.viewOffset
        guard offsetAfterSettle > 0 else {
            return failed("tab swipe: an upright pan of \(width / 6) points left the view at the bottom, so it scrolled nothing")
        }
        upright.stubState = .changed
        upright.stubTranslation = CGPoint(x: -60, y: width / 6 + 100)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: upright)
        guard surface.viewOffset > offsetAfterSettle else {
            return failed("tab swipe: an upright pan stopped scrolling once it leaned sideways")
        }
        upright.stubState = .ended
        upright.stubTranslation = CGPoint(x: -width, y: width / 6 + 100)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: upright)
        guard recorder.nextTabAsks == 1, recorder.previousTabAsks == 1 else {
            return failed("tab swipe: a scroll that wandered sideways switched tabs")
        }
        upright.stubState = .possible
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: upright)
        returnToBottom(surface)

        // A thumb's arc: the first callback leans sideways but short of the lean a swipe needs,
        // and the finger then travels a long way up the grid. It is a scroll from the start.
        let arc = StubPan()
        arc.stubLocation = CGPoint(x: 200, y: 200)
        arc.stubState = .began
        arc.stubTranslation = CGPoint(x: 13, y: 7)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
        arc.stubState = .changed
        arc.stubTranslation = CGPoint(x: 20, y: 300)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
        guard surface.viewOffset > 0 else {
            return failed("tab swipe: a scroll that opened with a sideways arc was dropped for its whole length")
        }
        arc.stubState = .ended
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: arc)
        guard recorder.nextTabAsks == 1, recorder.previousTabAsks == 1 else {
            return failed("tab swipe: an arcing scroll switched tabs")
        }
        returnToBottom(surface)

        // A pan that did settle sideways and then turned up the grid becomes the scroll it was.
        let turned = StubPan()
        turned.stubLocation = CGPoint(x: 200, y: 200)
        turned.stubState = .began
        turned.stubTranslation = CGPoint(x: 20, y: 2)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: turned)
        guard surface.viewOffset == 0 else {
            return failed("tab swipe: a pan that settled sideways scrolled at once")
        }
        turned.stubState = .changed
        turned.stubTranslation = CGPoint(x: 30, y: 300)
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: turned)
        guard surface.viewOffset > 0 else {
            return failed("tab swipe: a sideways-settled pan that turned up the grid never scrolled")
        }
        turned.stubState = .ended
        surface.perform(NSSelectorFromString("handleScrollPan:"), with: turned)
        guard recorder.nextTabAsks == 1, recorder.previousTabAsks == 1 else {
            return failed("tab swipe: a pan that turned into a scroll switched tabs as it lifted")
        }
        returnToBottom(surface)
        return true
    }

    /// The axis lock and the swipe threshold, on numbers alone.
    @MainActor
    private static func theTouchPanRuleHoldsOnNumbers() -> Bool {
        let width: CGFloat = 390
        let lockDistance = TouchPanRule.axisLockDistance
        let axisCases: [(String, CGPoint, TouchPanAxis?, TouchPanAxis?)] = [
            ("a pan within the lock distance has no axis", CGPoint(x: 5, y: 5), nil, nil),
            ("a sideways pan settles horizontal", CGPoint(x: -lockDistance - 1, y: 3), nil, .horizontal),
            ("an upright pan settles vertical", CGPoint(x: 3, y: lockDistance + 1), nil, .vertical),
            ("a perfect diagonal settles vertical", CGPoint(x: 20, y: 20), nil, .vertical),
            ("a thumb's arc short of a two-to-one lean settles vertical", CGPoint(x: 13, y: -7), nil, .vertical),
            ("a pan thirty degrees off horizontal settles vertical", CGPoint(x: -13, y: 7.5), nil, .vertical),
            ("a pan at a two-to-one lean settles horizontal", CGPoint(x: -14, y: 7), nil, .horizontal),
            ("a horizontal axis is kept when the swipe dips", CGPoint(x: -200, y: 150), .horizontal, .horizontal),
            (
                "a horizontal axis is kept until the vertical travel passes the horizontal by the lock distance",
                CGPoint(x: 20, y: 20 + lockDistance - 1), .horizontal, .horizontal
            ),
            ("a horizontal axis gives way to a long vertical travel", CGPoint(x: 13, y: -300), .horizontal, .vertical),
            ("a vertical axis is kept when the pan turns", CGPoint(x: -300, y: 0), .vertical, .vertical),
        ]
        for (name, translation, locked, expected) in axisCases {
            let got = TouchPanRule.axis(after: translation, lockedAxis: locked)
            guard got == expected else {
                return failed("pan axis: \(name): expected \(String(describing: expected)), got \(String(describing: got))")
            }
        }
        let far = TouchPanRule.swipeDistance(viewWidth: width)
        guard far == width / 3, TouchPanRule.swipeDistance(viewWidth: 120) == 80 else {
            return failed("pan meaning: the swipe distance is not a third of the view with an 80-point floor")
        }
        let meaningCases: [(String, TouchPanAxis?, CGPoint, CGPoint, Bool, TouchPanMeaning)] = [
            ("an unsettled pan forwards nothing", nil, CGPoint(x: 4, y: 4), .zero, false, .nothing),
            ("a vertical pan scrolls while it moves", .vertical, CGPoint(x: 30, y: 200), .zero, false, .scroll),
            ("a vertical pan scrolls as it ends", .vertical, CGPoint(x: -200, y: 30), CGPoint(x: -2000, y: 0), true, .scroll),
            ("a sideways pan forwards nothing while it moves", .horizontal, CGPoint(x: -far - 50, y: 0), .zero, false, .nothing),
            ("a far leftward pan swipes left", .horizontal, CGPoint(x: -far, y: 10), .zero, true, .swipeLeft),
            ("a far rightward pan swipes right", .horizontal, CGPoint(x: far, y: -10), .zero, true, .swipeRight),
            ("a short slow sideways pan does nothing", .horizontal, CGPoint(x: -far + 1, y: 0), CGPoint(x: -100, y: 0), true, .nothing),
            ("a short fast flick swipes", .horizontal, CGPoint(x: 30, y: 0), CGPoint(x: 1200, y: 100), true, .swipeRight),
            ("a flick back against its travel does nothing", .horizontal, CGPoint(x: 30, y: 0), CGPoint(x: -1200, y: 0), true, .nothing),
            (
                "a flick more upright than sideways does nothing", .horizontal, CGPoint(x: -30, y: 0), CGPoint(x: -900, y: 1000), true,
                .nothing
            ),
            ("an upright nudge that ends unsettled still scrolls", nil, CGPoint(x: 1, y: 6), .zero, true, .scroll),
            ("a sideways nudge that ends unsettled does nothing", nil, CGPoint(x: -6, y: 1), CGPoint(x: -100, y: 0), true, .nothing),
            ("a leaning nudge that ends unsettled scrolls", nil, CGPoint(x: -6, y: 4), CGPoint(x: -100, y: 0), true, .scroll),
        ]
        for (name, axis, translation, velocity, hasEnded, expected) in meaningCases {
            let got = TouchPanRule.meaning(
                axis: axis,
                translation: translation,
                velocity: velocity,
                hasEnded: hasEnded,
                viewWidth: width
            )
            guard got == expected else {
                return failed("pan meaning: \(name): expected \(expected), got \(got)")
            }
        }
        let tolerance = TouchPanRule.pinchScaleTolerance
        let twoFingerCases: [(String, CGPoint, CGFloat, TouchPanMeaning)] = [
            ("two fingers far left swipe left", CGPoint(x: -far, y: 20), 1, .swipeLeft),
            ("two fingers far right swipe right", CGPoint(x: far, y: 20), 1, .swipeRight),
            ("two fingers short of the distance do nothing", CGPoint(x: -far + 1, y: 0), 1, .nothing),
            ("two fingers dragged upright do nothing", CGPoint(x: far, y: far + 1), 1, .nothing),
            ("a swipe whose spacing wavered still swipes", CGPoint(x: -far, y: 0), 1 + tolerance - 0.01, .swipeLeft),
            ("a swipe whose fingers closed a little still swipes", CGPoint(x: far, y: 0), 1 - tolerance + 0.01, .swipeRight),
            ("a spreading pinch that drifted across the view does nothing", CGPoint(x: -far * 2, y: 0), 1 + tolerance + 0.05, .nothing),
            ("a closing pinch that drifted across the view does nothing", CGPoint(x: far * 2, y: 0), 1 - tolerance - 0.05, .nothing),
        ]
        for (name, translation, scale, expected) in twoFingerCases {
            let got = TouchPanRule.twoFingerMeaning(translation: translation, pinchScale: scale, viewWidth: width)
            guard got == expected else {
                return failed("two-finger meaning: \(name): expected \(expected), got \(got)")
            }
        }
        return true
    }

    /// Presents the fixture before a gesture queries its drawn geometry.
    ///
    /// A published grid does not prove UIKit has drawn it. This smoke drives
    /// gestures synchronously, so it must give the surface a display cycle.
    /// - Parameter surface: The surface whose picture the next gesture uses.
    /// - Returns: Whether a frame reached presentation within the draw deadline.
    @MainActor
    private static func settle(_ surface: TerminalSurface) -> Bool {
        surface.layoutIfNeeded()
        guard let renderer = surface.renderer as? SurfaceRenderer else {
            return failed("settle: the fixture has no surface renderer")
        }
        let before = renderer.presentedFrameCount
        drawUntil(surface) { renderer.presentedFrameCount > before }
        return renderer.presentedFrameCount > before || failed("settle: the fixture never presented its grid")
    }

    private static func failed(_ reason: String) -> Bool {
        report("touch smoke: FAIL: \(reason)")
        return false
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// A pinch whose state and scale the smoke sets.
///
/// UIKit will not synthesise a touch sequence from a test, so the adapter is driven with a
/// recogniser that reports what a real pinch would. Overriding rather than mocking: the handler
/// takes a `UIPinchGestureRecognizer` and reads exactly these two properties.
private final class StubPinch: UIPinchGestureRecognizer {
    var stubState: UIGestureRecognizer.State = .possible
    var stubScale: CGFloat = 1
    override var state: UIGestureRecognizer.State {
        get { stubState }
        set { stubState = newValue }
    }
    override var scale: CGFloat {
        get { stubScale }
        set { stubScale = newValue }
    }
}

/// A pan whose state, translation, location, held modifiers and touch count
/// the smoke sets; a trackpad or wheel scroll carries no touch at all.
private final class StubPan: UIPanGestureRecognizer {
    var stubNumberOfTouches = 1
    override var numberOfTouches: Int { stubNumberOfTouches }
    var stubState: UIGestureRecognizer.State = .possible
    var stubTranslation: CGPoint = .zero
    var stubLocation: CGPoint = .zero
    var stubModifierFlags: UIKeyModifierFlags = []
    override var state: UIGestureRecognizer.State {
        get { stubState }
        set { stubState = newValue }
    }
    override var modifierFlags: UIKeyModifierFlags { stubModifierFlags }
    override func translation(in _: UIView?) -> CGPoint { stubTranslation }
    override func location(in _: UIView?) -> CGPoint { stubLocation }
}

/// A tap whose state, location and held modifiers the smoke sets.
private final class StubTap: UITapGestureRecognizer {
    var stubState: UIGestureRecognizer.State = .possible
    var stubLocation: CGPoint = .zero
    var stubModifierFlags: UIKeyModifierFlags = []
    override var state: UIGestureRecognizer.State {
        get { stubState }
        set { stubState = newValue }
    }
    override var modifierFlags: UIKeyModifierFlags { stubModifierFlags }
    override func location(in _: UIView?) -> CGPoint { stubLocation }
}

/// A touch of the kind the smoke names, for the arbiter to be offered.
private final class StubTouch: UITouch {
    private let stubType: UITouch.TouchType

    init(type: UITouch.TouchType) {
        stubType = type
        super.init()
    }

    override var type: UITouch.TouchType { stubType }
}

/// The tap-then-press selection drag or the hold, with the state, location and
/// held modifiers the smoke sets.
private final class StubSelectPress: UILongPressGestureRecognizer {
    var stubState: UIGestureRecognizer.State = .possible
    var stubLocation: CGPoint = .zero
    var stubModifierFlags: UIKeyModifierFlags = []
    override var state: UIGestureRecognizer.State {
        get { stubState }
        set { stubState = newValue }
    }
    override var modifierFlags: UIKeyModifierFlags { stubModifierFlags }
    override func location(in _: UIView?) -> CGPoint { stubLocation }
}

/// Records the bytes a surface's session writes to its host, as an embedder
/// feeding a streamless session receives them.
///
/// Unchecked because the session calls the handler on the thread that sends,
/// which in this smoke is always the main thread the legs run on.
private final class HostBytesRecorder: @unchecked Sendable {
    private(set) var bytes: [UInt8] = []

    var text: String { String(decoding: bytes, as: UTF8.self) }

    func append(_ data: Data) { bytes.append(contentsOf: data) }

    func clear() { bytes.removeAll() }

    /// How many times a sequence occurs in what was recorded.
    ///
    /// - Parameter sequence: The sequence to count.
    /// - Returns: The count of non-overlapping occurrences.
    func count(of sequence: String) -> Int {
        text.components(separatedBy: sequence).count - 1
    }
}

/// Counts settings, keyboard, tab and connection asks.
///
/// All of them, because each leg's claim is that one happened and another did not; a recorder
/// counting only the ask under test could not tell a clean gesture from one that also did
/// something else.
private final class SettingsAskRecorder: TerminalSurfaceObserver {
    private(set) var settingsAsks = 0
    private(set) var keyboardAsks = 0
    private(set) var nextTabAsks = 0
    private(set) var previousTabAsks = 0
    private(set) var nextConnectionAsks = 0
    private(set) var previousConnectionAsks = 0
    func terminalSurfaceDidRequestSettings(_: TerminalSurface) { settingsAsks += 1 }
    func terminalSurfaceDidRequestKeyboard(_: TerminalSurface) { keyboardAsks += 1 }
    func terminalSurfaceDidRequestNextTab(_: TerminalSurface) { nextTabAsks += 1 }
    func terminalSurfaceDidRequestPreviousTab(_: TerminalSurface) { previousTabAsks += 1 }
    func terminalSurfaceDidRequestNextConnection(_: TerminalSurface) { nextConnectionAsks += 1 }
    func terminalSurfaceDidRequestPreviousConnection(_: TerminalSurface) { previousConnectionAsks += 1 }
}

/// Counts the keyboard asks a tap produces.
/// Records what the surface transmitted, as bytes and as the text they stood
/// for.
///
/// Both, because the two questions differ: composed text is asserted as the
/// string an input method committed, and a chord as the exact byte the encoder
/// folded it to.
private final class TransmitRecorder: TerminalSurfaceObserver {
    var transmissions: [String] = []
    var transmittedBytes: [[UInt8]] = []

    func terminalSurface(_: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
        let unsigned = bytes.prefix(count).map { UInt8(bitPattern: $0) }
        transmittedBytes.append(Array(unsigned))
        transmissions.append(String(decoding: unsigned, as: UTF8.self))
    }
}

private final class KeyboardAskRecorder: TerminalSurfaceObserver {
    private(set) var asks = 0
    func terminalSurfaceDidRequestKeyboard(_: TerminalSurface) { asks += 1 }
}

#endif
