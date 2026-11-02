// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

/// Supplies an elastic clip position without synthesizing trackpad physics.
@MainActor
private final class ElasticPositionClip: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
}

// ScrollerChromeScenarios.swift — a Kit-hosted window's scroll bar shows
// the history that is actually behind it, and tints its knob against the
// terminal's own ground.
//
// What the bar should show is Core's, pinned in Tests/Core/test_scrollerchrome.cpp.
// What this reaches that a Core test cannot: whether the Swift shell asks. It
// did not — the alternate screen never entered the calculation on this arm, so
// a full-screen program got a draggable bar over a screen with nothing behind
// it, and the knob was tinted by the system appearance rather than the theme.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// The scroll bar inside a surface.
///
/// Found as the native control it is rather than by its concrete type: both facts
/// asserted here — whether the bar is on screen, and how its knob is tinted —
/// are NSScroller's own, so naming the shell type would couple the scenario to
/// it without reading anything more.
///
/// - Parameter surface: The surface to search under.
/// - Returns: The scroller, or nil when the surface has none.
@MainActor
private func scroller(in surface: NSView) -> NSScroller? {
    if let bar = surface as? NSScroller {
        return bar
    }
    for subview in surface.subviews {
        if let found = scroller(in: subview) {
            return found
        }
    }
    return nil
}

/// Whether AppKit exposes the knob to pointer interaction, including its native fade state.
@MainActor
private func knobIsRevealed(_ bar: NSScroller) -> Bool {
    guard !bar.isHiddenOrHasHiddenAncestor else { return false }
    let knob = bar.rect(for: .knob)
    let point = bar.convert(NSPoint(x: knob.midX, y: knob.midY), to: bar.superview)
    return bar.hitTest(point) != nil
}

/// Measures the track's clearance in the terminal's coordinate system.
@MainActor
private func bottomClearance(_ bar: NSScroller, in surface: NSView) -> CGFloat {
    let rectangle = bar.convert(bar.rect(for: .knobSlot), to: surface)
    return surface.isFlipped ? surface.bounds.maxY - rectangle.maxY : rectangle.minY - surface.bounds.minY
}

/// History on the primary screen, produced through the shell so the chrome
/// refreshes off the drain that delivers it.
///
/// - Parameters:
///   - t: The harness.
///   - surface: The surface whose shell writes the lines.
/// - Returns: Whether the shell produced enough scrollback to scroll into.
@MainActor
private func fillHistory(_ t: UBUITestContext, _ surface: TerminalSurface) -> Bool {
    surface.send("for i in $(seq 1 200); do echo scroller-line-$i; done\n")
    var scrollback = 0
    for _ in 0..<40 {
        t.pump(0.1)
        scrollback = Int(surface.drive.readSnapshot().scrollbackCount)
        if scrollback > 60 { break }
    }
    guard scrollback > 60 else {
        t.expect(false, desc: "the shell produced scrollback (got \(scrollback))")
        return false
    }
    return true
}

/// Holds until the shell's output stops growing the history, so a scenario
/// reading an offset reads one no appended row is still moving.
///
/// - Parameters:
///   - t: The harness.
///   - surface: The surface whose history is watched.
@MainActor
private func settleHistory(_ t: UBUITestContext, _ surface: TerminalSurface) {
    var previous = -1
    for _ in 0..<40 {
        t.pump(0.2)
        let current = Int(surface.drive.readSnapshot().scrollbackCount)
        if current == previous { return }
        previous = current
    }
}

/// One Command-held navigation key press, shaped the way AppKit delivers it.
///
/// The navigation block reads the key code and the modifier flags; the
/// characters carry the function-key code point the same press would.
///
/// - Parameters:
///   - functionKey: The function-key code point the press produces.
///   - keyCode: The hardware key code.
///   - window: The window the press is addressed to.
/// - Returns: The event, or nil when AppKit refuses it.
@MainActor
private func commandNavigationKey(_ functionKey: Int, keyCode: Int, in window: NSWindow) -> NSEvent? {
    guard let scalar = Unicode.Scalar(functionKey) else { return nil }
    let characters = String(Character(scalar))
    return NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: UInt16(keyCode)
    )
}

/// The shortest knob AppKit will draw in a scroller of this shape.
///
/// NSScroller stops shrinking its knob at a floor, so below a certain share the
/// drawn knob is longer than the viewport's share of the track and the linear
/// model stops describing the control. The floor moves with the scroller's
/// style and with the system, and AppKit publishes no constant for it, so a
/// scratch scroller of the same frame and style is asked the same question with
/// a share small enough to be clamped. Asking the live bar would mean writing to
/// the subject of the assertion.
///
/// - Parameter bar: The scroller whose shape the answer should describe.
/// - Returns: The knob height AppKit will not go below.
@MainActor
private func minKnobHeight(like bar: NSScroller) -> CGFloat {
    let probe = NSScroller(frame: bar.frame)
    probe.scrollerStyle = bar.scrollerStyle
    probe.knobStyle = bar.knobStyle
    probe.knobProportion = 0.0001
    return probe.rect(for: .knob).height
}

/// A mouse event at a point in the window.
///
/// - Parameters:
///   - type: Which mouse event.
///   - window: The window the point is in.
///   - point: The location, in window coordinates.
/// - Returns: The event, or nil when AppKit refuses it.
@MainActor
private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

/// Creates a line-unit wheel event for direct delivery to a chosen view.
///
/// Core Graphics events have no AppKit window association. Leaving the location
/// unspecified avoids presenting screen coordinates as window coordinates;
/// the viewport scenarios explicitly choose the receiving view.
///
/// - Parameter lines: Lines to scroll; positive scrolls up, into history.
/// - Returns: The event, or nil when the system refuses it.
@MainActor
private func wheelEvent(lines: Int32) -> NSEvent? {
    guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else {
        return nil
    }
    return NSEvent(cgEvent: cgEvent)
}

/// Clicks the track beside the knob, the release queued ahead of the press so
/// the scroller's own tracking loop pages once and returns, the way it would
/// under a hand.
///
/// A knob drag is not driven this way: under synthesized events
/// the knob's tracking does not settle where the events say, so the knob's
/// value is set and its action sent instead.
///
/// - Parameters:
///   - bar: The scroller.
///   - window: Its window.
///   - aboveKnob: Whether to click above the knob (a page up, into history)
///     or below it.
@MainActor
private func clickTrack(_ bar: NSScroller, in window: NSWindow, aboveKnob: Bool) {
    let slot = bar.convert(bar.rect(for: .knobSlot), to: nil)
    let knob = bar.convert(bar.rect(for: .knob), to: nil)
    let y = aboveKnob ? min(slot.maxY - 4, knob.maxY + 12) : max(slot.minY + 4, knob.minY - 12)
    let point = CGPoint(x: slot.midX, y: y)
    if let up = mouseEvent(.leftMouseUp, in: window, at: point) {
        NSApp.postEvent(up, atStart: false)
    }
    if let down = mouseEvent(.leftMouseDown, in: window, at: point) {
        bar.mouseDown(with: down)
    }
}

/// Holds the scene for an eye or a screen capture when the environment names
/// a dwell in seconds (`UBIQUITTY_UITEST_DWELL`); a run without one holds
/// nothing.
///
/// The overlay knob is drawn in a layer, so a view-cache capture
/// from inside the process sees nothing of it — only the screen does.
///
/// - Parameters:
///   - t: The harness, whose pump keeps the window drawing.
///   - moment: What the scene shows, for the log.
@MainActor
private func dwell(_ t: UBUITestContext, at moment: String) {
    guard let text = ProcessInfo.processInfo.environment["UBIQUITTY_UITEST_DWELL"], let seconds = Double(text), seconds > 0 else {
        return
    }
    FileHandle.standardError.write(Data("dwell: \(moment)\n".utf8))
    t.pump(seconds)
}

/// Every terminal surface in a view hierarchy, in tree order.
///
/// - Parameter view: The root to search under.
/// - Returns: The surfaces under it, the window's first pane first.
@MainActor
private func terminalSurfaces(under view: NSView) -> [TerminalSurface] {
    if let surface = view as? TerminalSurface {
        return [surface]
    }
    return view.subviews.flatMap { terminalSurfaces(under: $0) }
}

/// Configures `base` with `[appearance] square_bottom_corners` appended.
///
/// Configured from a document rather than through the settings path, which
/// also persists to the reader's own config file.
///
/// - Parameters:
///   - base: The document the scenario found live.
///   - squaresBottomCorners: Whether the bottom corners are square.
@MainActor
private func configureSquareBottomCorners(over base: String, _ squaresBottomCorners: Bool) {
    restoreLiveDocument(base + "\n[appearance]\nsquare_bottom_corners = \(squaresBottomCorners)\n")
}

/// Registers the scroller-chrome scenarios with the UI-test runner.
enum ScrollerChromeScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_clear_and_typing_reset_native_scroll_motion") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface), let scroll = bar.superview as? NSScrollView
                else {
                    t.expect(false, desc: "a terminal exposes its native scroll host")
                    return
                }
                defer { window.close() }
                guard fillHistory(t, surface) else { return }
                surface.offsetView(byLines: 30)
                guard let queuedWheel = wheelEvent(lines: 3) else { return }
                surface.scrollWheel(with: queuedWheel)
                surface.snapToTailOnKeypress()
                let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                t.expect(
                    surface.viewOffset == 0 && abs(scroll.contentView.bounds.minY - maximum) < 1,
                    desc: "typing synchronizes the native position with the live tail"
                )
                guard
                    let momentum = CGEvent(
                        scrollWheelEvent2Source: nil,
                        units: .pixel,
                        wheelCount: 1,
                        wheel1: 80,
                        wheel2: 0,
                        wheel3: 0
                    )
                else { return }
                momentum.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
                guard let event = NSEvent(cgEvent: momentum) else { return }
                surface.scrollWheel(with: event)
                t.pump(0.2)
                t.expect(surface.viewOffset == 0, desc: "momentum arriving after typing cannot leave the cursor behind")
                t.expect(
                    abs(scroll.contentView.bounds.minY - maximum) < 1,
                    desc: "queued native animation frames cannot undo the typing reset"
                )
                surface.runClearCommand(.Buffer)
                t.expect(
                    abs(scroll.contentView.bounds.minY) < 1 && surface.verticalOverscroll == 0,
                    desc: "clearing removes the old document origin and elastic displacement"
                )
                guard fillHistory(t, surface) else { return }
                t.expect(
                    abs(scroll.contentView.bounds.maxY - (scroll.documentView?.bounds.height ?? 0)) < 1 && surface.verticalOverscroll == 0,
                    desc: "output after clearing stays at the live tail without a stale bounce"
                )
            }
        }

        UBUITestRegister("swift_shell_short_content_bounces_without_a_scrollbar") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = t.configureAppending("[mouse]\nscroll_bounce = true\n")
                defer { t.restoreConfiguration(saved) }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface), let scroll = bar.superview as? NSScrollView
                else {
                    t.expect(false, desc: "a terminal exposes its native scroll host")
                    return
                }
                defer { window.close() }
                surface.runClearCommand(.Buffer)
                let document = scroll.documentView
                t.expect(!scroll.contentView.drawsBackground, desc: "the native scroll clip does not cover terminal rendering")
                scroll.contentView = ElasticPositionClip(frame: scroll.contentView.frame)
                scroll.contentView.drawsBackground = false
                scroll.documentView = document
                for origin: CGFloat in [-40, 40] {
                    scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: origin))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    t.expect(surface.verticalOverscroll == -origin, desc: "short content can stretch at either edge")
                    t.expect(bar.isHidden && !bar.isEnabled, desc: "elasticity does not create a scrollbar for short content")
                }
                surface.snapToTailOnKeypress()
                t.expect(surface.verticalOverscroll == 0, desc: "typing cancels a bounce even when the offset was already zero")
            }
        }

        UBUITestRegister("swift_shell_trackpad_displacement_matches_native_scroll_view") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a terminal exposes a surface")
                    return
                }
                defer { window.close() }
                surface.send("for i in $(seq 1 200); do echo scroller-line-$i; done; printf 'SCROLLER-HISTORY-READY\\n'; read -r _\n")
                defer { surface.send("\n") }
                guard
                    t.wait(
                        until: {
                            surface.drive.readSnapshot().scrollbackCount > 60
                                && surface.gridTextForTesting().contains("SCROLLER-HISTORY-READY")
                        },
                        timeout: 10
                    )
                else {
                    t.expect(false, desc: "the shell finishes its history before the wheel comparison")
                    return
                }
                var policy = surface.wheelPolicy
                policy.trackpadSpeed = 1
                surface.wheelPolicy = policy
                surface.offsetView(byLines: 50)
                let startOffset = surface.viewOffset
                let startHistory = surface.drive.readSnapshot().scrollbackCount
                let reference = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
                reference.hasVerticalScroller = true
                content.addSubview(reference)
                defer { reference.removeFromSuperview() }
                let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 10000))
                reference.documentView = document
                reference.verticalScrollElasticity = .none
                reference.contentView.scroll(to: NSPoint(x: 0, y: 5000))
                reference.reflectScrolledClipView(reference.contentView)
                let startOrigin = reference.contentView.bounds.minY
                for delta: Int32 in [1, 3, 8, 16, 32, 64, 32, 16, 8, 3, 1] {
                    guard
                        let cgEvent = CGEvent(
                            scrollWheelEvent2Source: nil,
                            units: .pixel,
                            wheelCount: 1,
                            wheel1: delta,
                            wheel2: 0,
                            wheel3: 0
                        ), let event = NSEvent(cgEvent: cgEvent)
                    else { return }
                    reference.scrollWheel(with: event)
                    surface.scrollWheel(with: event)
                    t.pump(0.02)
                }
                let nativeDistance = abs(reference.contentView.bounds.minY - startOrigin)
                let terminalDistance = Double(abs(surface.viewOffset - startOffset)) * policy.pointsPerLine
                let endHistory = surface.drive.readSnapshot().scrollbackCount
                t.expect(
                    startHistory == endHistory,
                    desc: "the shell adds no history during the wheel comparison (\(startHistory) to \(endHistory))"
                )
                t.expect(
                    nativeDistance > 0 && abs(nativeDistance - terminalDistance) < policy.pointsPerLine,
                    desc: "native travel \(nativeDistance) pt and terminal travel \(terminalDistance) pt differ by less than one row"
                )
            }
        }

        UBUITestRegister("swift_shell_reversing_bounce_consumes_stretch_before_scrolling") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = t.configureAppending("[mouse]\nscroll_bounce = true\n")
                defer { t.restoreConfiguration(saved) }
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface),
                    let scroll = bar.superview as? NSScrollView,
                    let control = scroll.superview as? TerminalScroller
                else {
                    t.expect(false, desc: "a terminal exposes its native scroll host")
                    return
                }
                defer { window.close() }
                guard fillHistory(t, surface) else { return }
                let document = scroll.documentView
                scroll.contentView = ElasticPositionClip(frame: scroll.contentView.frame)
                scroll.documentView = document
                for atTop in [true, false] {
                    surface.offsetView(byLines: atTop ? 100000 : -100000)
                    let edgeOffset = surface.viewOffset
                    let clip = scroll.contentView
                    let maximum = max(0, (document?.bounds.height ?? 0) - clip.bounds.height)
                    clip.setBoundsOrigin(NSPoint(x: 0, y: atTop ? -80 : maximum + 80))
                    scroll.reflectScrolledClipView(clip)
                    t.expect(abs(surface.verticalOverscroll) == 80, desc: "the native clip displacement reaches the content")
                    guard let wheel = wheelEvent(lines: atTop ? -1 : 1) else { return }
                    var appliedWholeDelta = false
                    control.updateForScrollWheel(wheel) {
                        appliedWholeDelta = true
                        surface.offsetView(byLines: atTop ? -1 : 1)
                    }
                    t.expect(!appliedWholeDelta, desc: "a reversed wheel does not also scroll Core through the stretched distance")
                    t.expect(
                        surface.viewOffset == edgeOffset && surface.verticalOverscroll != 0,
                        desc: "the viewport stays at the edge while content remains stretched"
                    )
                    t.restoreConfiguration(saved)
                    t.configureAppending("[mouse]\nscroll_bounce = false\n")
                    TerminalWindowController.applyScrollPreferencesToOpenWindows()
                    t.expect(surface.verticalOverscroll == 0, desc: "disabling bounce clears an active stretch")
                    t.restoreConfiguration(saved)
                    t.configureAppending("[mouse]\nscroll_bounce = true\n")
                    TerminalWindowController.applyScrollPreferencesToOpenWindows()
                }
            }
        }

        UBUITestRegister("swift_shell_scroll_bounce_setting_applies_to_open_windows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyScrollPreferencesToOpenWindows()
                }
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface),
                    let scrollView = bar.superview as? NSScrollView
                else {
                    t.expect(false, desc: "a terminal window has a native scroll view")
                    return
                }
                defer { window.close() }
                let offset = surface.viewOffset
                for enabled in [false, true, false] {
                    t.restoreConfiguration(saved)
                    t.configureAppending("[mouse]\nscroll_bounce = \(enabled)\n")
                    TerminalWindowController.applyScrollPreferencesToOpenWindows()
                    t.expect(
                        scrollView.verticalScrollElasticity == (enabled ? .allowed : .none),
                        desc: "the bounce choice applies to an already open window"
                    )
                    t.expect(surface.viewOffset == offset, desc: "changing bounce preserves the viewport")
                }
            }
        }

        UBUITestRegister("swift_shell_overscroll_moves_content_without_resizing_terminal") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface), let originalPoint = surface.viewPoint(forRow: 2, column: 3) else { return }
                let originalPosition = surface.metalLayer.position
                let originalDrawable = surface.metalLayer.drawableSize
                let originalBounds = surface.bounds
                let originalBarFrame = bar.convert(bar.bounds, to: surface)
                let originalOffset = surface.viewOffset
                let originalAnchor = surface.compositionAnchorRect()
                let originalVisualPosition = surface.layer?.convert(CGPoint.zero, from: surface.metalLayer)
                for offset: CGFloat in [48, -48, 0] {
                    surface.applyVerticalOverscroll(offset)
                    t.expect(surface.metalLayer.position.y == originalPosition.y + offset, desc: "content follows the elastic displacement")
                    if let originalVisualPosition, let visualPosition = surface.layer?.convert(CGPoint.zero, from: surface.metalLayer) {
                        t.expect(
                            visualPosition.y == originalVisualPosition.y + offset,
                            desc: "content moves in the same direction in the view's coordinate system"
                        )
                    } else {
                        t.expect(false, desc: "the terminal has a backing layer")
                    }
                    t.expect(
                        surface.metalLayer.drawableSize == originalDrawable && surface.bounds == originalBounds,
                        desc: "bounce preserves drawable and viewport dimensions"
                    )
                    t.expect(surface.viewOffset == originalOffset, desc: "bounce does not move Core's scrollback position")
                    t.expect(bar.convert(bar.bounds, to: surface) == originalBarFrame, desc: "the scrollbar stays fixed")
                    t.expect(
                        surface.viewPoint(forRow: 2, column: 3)?.y == originalPoint.y + offset,
                        desc: "cell coordinates follow the visible content"
                    )
                    t.expect(
                        surface.compositionAnchorRect().minY == originalAnchor.minY + offset,
                        desc: "the input-method anchor follows the visible cursor"
                    )
                }
                t.expect(surface.metalLayer.superlayer?.masksToBounds == true, desc: "elastic content is clipped to its pane")
            }
        }

        UBUITestRegister("swift_shell_scroller_forwards_wheel_from_native_control") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a terminal window opens with a scrollbar")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface),
                    let wheel = wheelEvent(lines: 5)
                else { return }
                bar.scrollWheel(with: wheel)
                t.pump(0.03)
                t.expect(surface.viewOffset > 0, desc: "a wheel over the native scrollbar moves terminal history")
                t.expect(knobIsRevealed(bar), desc: "scrolling over the native control reveals its knob")
                let knob = bar.rect(for: .knob)
                t.expect(bar.visibleRect.contains(knob), desc: "the knob fits its visible control area")
                t.expect(surface.bounds.contains(bar.convert(knob, to: surface)), desc: "the knob stays inside its terminal pane")
                let slot = bar.convert(bar.rect(for: .knobSlot), to: surface)
                let topMargin = surface.isFlipped ? slot.minY - surface.bounds.minY : surface.bounds.maxY - slot.maxY
                t.expect(abs(topMargin - 1) <= 0.5, desc: "the track starts one point below the terminal's top edge")
                dwell(t, at: "terminal scrollbar revealed")
            }
        }

        UBUITestRegister("swift_shell_a_surface_remirrors_its_bar_on_arrival") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // Through the shell, so a drain runs and the bar settles on it.
                surface.send("for i in $(seq 1 90); do echo arrive-$i; done\n")
                var settled = CGFloat(1)
                for _ in 0..<50 {
                    t.pump(0.1)
                    settled = bar.knobProportion
                    if settled < 1 { break }
                }
                t.expect(settled < 1, desc: "the bar sized itself against the history (\(settled))")

                // Keep the model's writer and main-queue delivery quiet while
                // the detached snapshot grows. Arrival must reconcile the bar
                // before the feed's queued notification can do so.
                surface.drive.stopIngest()
                guard let host = surface.superview else {
                    t.expect(false, desc: "the surface has a host view")
                    return
                }
                surface.removeFromSuperview()
                let historyBefore = surface.drive.readSnapshot().scrollbackCount
                let output = (0..<400).map { "offscreen-\($0)\r\n" }.joined()
                surface.feed(Data(output.utf8))
                t.expect(
                    surface.drive.readSnapshot().scrollbackCount > historyBefore,
                    desc: "the detached snapshot contains more history before any delivery"
                )

                let stale = bar.knobProportion
                t.expect(
                    stale == settled,
                    desc: "the bar is still sized on what it last saw (\(stale))"
                )

                // Arriving is the edge that reconciles it, and it does so
                // before anything else runs: read with no pump between, or a
                // drain that happens to land would answer for it instead.
                host.addSubview(surface)
                t.expect(
                    bar.knobProportion < stale,
                    desc: "arriving in a window re-mirrors the bar against the model"
                        + " (\(bar.knobProportion), was \(stale))"
                )
            }
        }

        UBUITestRegister("swift_shell_scroller_reveals_on_a_scroll_and_fades") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }

                // Following output can reveal the native scroller briefly;
                // an idle viewport must let it finish fading.
                t.expect(!bar.isHiddenOrHasHiddenAncestor, desc: "history behind it puts the bar in the tree")
                if bar.scrollerStyle == .overlay {
                    t.pump(2.4)
                    t.expect(
                        !knobIsRevealed(bar),
                        desc: "at the tail, with nothing scrolled, the overlay bar is faded"
                    )
                }

                guard let wheel = wheelEvent(lines: 3) else {
                    t.expect(false, desc: "a wheel event can be made")
                    return
                }
                if !WindowContainment.isOffscreen {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    t.pump(0.1)
                }
                surface.scrollWheel(with: wheel)
                t.pump(0.03)
                t.expect(surface.viewOffset > 0, desc: "the wheel scrolled into history (offset \(surface.viewOffset))")
                if let scroll = bar.superview as? NSScrollView, let document = scroll.documentView {
                    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    t.expect(
                        scroll.contentView.bounds.minY > maximum / 2,
                        desc: "a first small scroll uses the current document extent instead of jumping to its top"
                    )
                }
                if !WindowContainment.isOffscreen {
                    t.expect(knobIsRevealed(bar), desc: "the scroll revealed the bar in the active window")
                } else {
                    print("SCROLLER_REVEAL_CHECK unavailable: offscreen mode does not prove active-window reveal; use --ui-test-visible")
                }
                dwell(t, at: "revealed")

                // The knob is the viewport's share of the content, at the tail
                // end of the track.
                let knob = bar.rect(for: .knob)
                let slot = bar.rect(for: .knobSlot)
                let snapshot = surface.drive.readSnapshot()
                let share = CGFloat(snapshot.rows) / CGFloat(Int(snapshot.scrollbackCount) + Int(snapshot.rows))
                t.expect(
                    knob.height > 0 && knob.height < slot.height,
                    desc: "the knob covers a share of the track (\(knob.height) of \(slot.height))"
                )
                // A window shallow enough against deep history asks for a knob
                // shorter than AppKit draws, and the drawn knob is the floor
                // instead. Both regimes are the control behaving; asserting only
                // the share fails the moment the window is small.
                let minKnob = minKnobHeight(like: bar)
                let expectedKnobHeight = max(slot.height * share, minKnob)
                t.expect(
                    abs(knob.height - expectedKnobHeight) <= 3,
                    desc:
                        "the knob's share is the viewport's (\(knob.height) vs \(expectedKnobHeight) for \(snapshot.rows) rows over \(snapshot.scrollbackCount) lines, share \(slot.height * share), floor \(minKnob))"
                )
                // NSScroller lays its track out flipped, so the tail end is
                // the larger y; asked either way so the check reads the
                // control and not an assumption about it.
                let gapAtTail = bar.isFlipped ? slot.maxY - knob.maxY : knob.minY - slot.minY
                let pointsPerLine = slot.height / CGFloat(Int(snapshot.scrollbackCount) + Int(snapshot.rows))
                t.expect(
                    gapAtTail < 3 * pointsPerLine + 2,
                    desc:
                        "a few lines into history keeps the knob at the tail end of the track (gap \(gapAtTail) for \(pointsPerLine) points per line)"
                )

                // The overlay bar fades after its hold, and a faded bar is
                // still in the tree: fading is not extent.
                if bar.scrollerStyle == .overlay {
                    t.pump(2.4)
                    t.expect(!knobIsRevealed(bar), desc: "the bar faded after the hold")
                    t.expect(!bar.isHiddenOrHasHiddenAncestor, desc: "AppKit fades the knob without removing its control")
                    surface.scrollWheel(with: wheel)
                    t.pump(0.03)
                    t.expect(knobIsRevealed(bar), desc: "scrolling restores the native knob")
                }
            }
        }

        UBUITestRegister("swift_shell_full_history_knob_reaches_every_captured_offset") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting,
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a terminal with a scroller opens")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                surface.drive.stopIngest()
                let lines = (0..<30000).map { "history-row-\($0)\r\n" }.joined()
                surface.feed(Data(lines.utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                let history = Int(surface.drive.readSnapshot().history.retainedRows)
                t.expect(history > 1000, desc: "a long history is retained")
                for step in 0...10 {
                    bar.doubleValue = 1 - Double(step) / 10
                    bar.sendAction(bar.action, to: bar.target)
                    let wanted = Int((Double(history) * Double(step) / 10).rounded())
                    t.expect(
                        t.wait(until: { surface.lastCapturedViewOffsetForTesting == wanted }, timeout: 2),
                        desc:
                            "the frame reaches \(wanted) rows of \(history), captured \(String(describing: surface.lastCapturedViewOffsetForTesting))"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_scroller_knob_drag_and_track_click_move_the_view") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }
                guard let wheel = wheelEvent(lines: 3) else {
                    t.expect(false, desc: "a wheel event can be made")
                    return
                }
                surface.scrollWheel(with: wheel)
                t.pump(0.2)
                let afterWheel = surface.viewOffset
                t.expect(afterWheel > 0 && knobIsRevealed(bar), desc: "the wheel scrolled into history and revealed the bar")

                // The knob's own tracking is AppKit's, and under synthesized
                // events it does not settle where the events say; what is
                // this bar's is the value it reports back as lines. A knob
                // moved a fifth of the way up the track and sent as a knob
                // move lands the view a fifth of the way into history.
                bar.doubleValue = 0.8
                bar.sendAction(bar.action, to: bar.target)
                t.pump(0.3)
                let afterDrag = surface.viewOffset
                let snapshot = surface.drive.readSnapshot()
                let expected = Int((0.2 * Double(snapshot.scrollbackCount)).rounded())
                t.expect(afterDrag > afterWheel, desc: "the knob moved up walked into history (\(afterWheel) → \(afterDrag))")
                t.expect(
                    abs(afterDrag - expected) <= 1,
                    desc: "the knob's value maps to lines above the tail (\(afterDrag) for a fifth of \(snapshot.scrollbackCount))"
                )
                t.expect(knobIsRevealed(bar), desc: "the move holds the bar up")
                dwell(t, at: "dragged")

                // A click in the track pages: above the knob into history,
                // below it back toward the tail.
                clickTrack(bar, in: window, aboveKnob: true)
                t.pump(0.3)
                let afterPageUp = surface.viewOffset
                t.expect(afterPageUp > afterDrag, desc: "a click above the knob paged into history (\(afterDrag) → \(afterPageUp))")
                clickTrack(bar, in: window, aboveKnob: false)
                t.pump(0.3)
                let afterPageDown = surface.viewOffset
                t.expect(
                    afterPageDown < afterPageUp,
                    desc: "a click below the knob paged toward the tail (\(afterPageUp) → \(afterPageDown))"
                )

                // The knob at the tail end of the track is the live tail
                // exactly, not a line short of it.
                bar.doubleValue = 1
                bar.sendAction(bar.action, to: bar.target)
                t.pump(0.3)
                t.expect(surface.viewOffset == 0, desc: "the knob at the tail end returned to the tail (offset \(surface.viewOffset))")
            }
        }

        // The keyboard's page chords and the [keys] page actions take one
        // amount between them, Keys::pageLinesForRows — the amount the bar's
        // track click takes too — so a page keeps a row of overlap rather
        // than jumping a whole screenful.
        UBUITestRegister("swift_shell_page_keys_move_one_core_page") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }
                settleHistory(t, surface)

                let snapshot = surface.drive.readSnapshot()
                let rows = Int(snapshot.rows)
                let page = Int(Ubiquitty.Keys.pageLinesForRows(rows))
                // Preconditions, not the claim: the two candidate amounts must
                // differ or a whole screenful satisfies the assertions too, and
                // history must be deeper than either or the clamp answers
                // instead of the rule.
                t.expect(rows > 1 && page != rows, desc: "a page (\(page)) is not a screenful (\(rows))")
                t.expect(Int(snapshot.scrollbackCount) > rows, desc: "history is deeper than a screenful")
                t.expect(surface.viewOffset == 0, desc: "the fill left the view at the live tail")

                // Read straight after each press: the offset moves
                // synchronously, and a pumped turn could drain appended rows,
                // which move a held viewport on their own and would answer for
                // the key.
                guard
                    let pageUp = commandNavigationKey(NSPageUpFunctionKey, keyCode: kVK_PageUp, in: window),
                    let pageDown = commandNavigationKey(NSPageDownFunctionKey, keyCode: kVK_PageDown, in: window)
                else {
                    t.expect(false, desc: "AppKit synthesises Cmd-PageUp and Cmd-PageDown")
                    return
                }
                surface.keyDown(with: pageUp)
                t.expect(
                    surface.viewOffset == page,
                    desc: "Cmd-PageUp moved one Core page (\(rows) rows on screen): got \(surface.viewOffset), want \(page)"
                )
                surface.keyDown(with: pageDown)
                t.expect(surface.viewOffset == 0, desc: "Cmd-PageDown came back the same distance (offset \(surface.viewOffset))")

                // The [keys] action vocabulary reaches the same rule through
                // its own dispatch, a second site that could page its own
                // amount.
                surface.performKeyAction(named: "scroll_page_up")
                t.expect(
                    surface.viewOffset == page,
                    desc: "the scroll_page_up action moved one Core page: got \(surface.viewOffset), want \(page)"
                )
                surface.performKeyAction(named: "scroll_page_down")
                t.expect(surface.viewOffset == 0, desc: "the scroll_page_down action came back (offset \(surface.viewOffset))")
            }
        }

        UBUITestRegister("swift_shell_scroller_hides_history_behind_the_alt_screen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content),
                    let overlay = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                // History on the primary screen, so there is something for the
                // bar to be wrong about.
                surface.send("for i in $(seq 1 200); do echo scroller-line-$i; done\n")
                var scrollback = 0
                for _ in 0..<40 {
                    t.pump(0.1)
                    scrollback = Int(surface.drive.readSnapshot().scrollbackCount)
                    if scrollback > 60 { break }
                }
                guard scrollback > 60 else {
                    t.expect(false, desc: "the shell produced scrollback (got \(scrollback))")
                    return
                }
                // The bar hides itself when it has nothing to scroll, so
                // checking its visibility reads the extent, without a
                // test-only door into the view.
                t.expect(!overlay.isHiddenOrHasHiddenAncestor, desc: "the primary screen's bar is on screen")

                // A full-screen program takes the screen. Sent through the
                // shell rather than fed to the parser: the chrome is refreshed
                // off the drain that delivers output, so a direct feed changes
                // the model without ever reaching the path under test.
                surface.send("printf '\\033[?1049h'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if surface.drive.readSnapshot().modes.alternateScreenActive { break }
                }
                t.expect(
                    surface.drive.readSnapshot().modes.alternateScreenActive,
                    desc: "the alternate screen is up"
                )
                t.expect(
                    overlay.isHiddenOrHasHiddenAncestor,
                    desc:
                        "the alt-screen bar is gone, though the snapshot still reports \(surface.drive.readSnapshot().scrollbackCount) lines of primary history"
                )

                // And it comes back when the program leaves.
                surface.send("printf '\\033[?1049l'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if !surface.drive.readSnapshot().modes.alternateScreenActive { break }
                }
                t.expect(!overlay.isHiddenOrHasHiddenAncestor, desc: "the bar is back on the primary screen")
            }
        }

        UBUITestRegister("swift_shell_alt_screen_wheel_cannot_reach_primary_history") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }

                // A full-screen program takes the screen. Sent through the
                // shell rather than fed to the parser: the offset is clamped
                // against the snapshot the drain publishes, so a direct feed
                // moves the model without reaching the path under test.
                surface.send("printf '\\033[?1049h'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if surface.drive.readSnapshot().modes.alternateScreenActive { break }
                }
                t.expect(surface.drive.readSnapshot().modes.alternateScreenActive, desc: "the alternate screen is up")

                if let bar = scroller(in: surface), let scroll = bar.superview as? NSScrollView {
                    t.expect(scroll.verticalScrollElasticity == .none, desc: "the alternate screen never stretches the terminal viewport")
                } else {
                    t.expect(false, desc: "the alternate screen retains its native scroll host")
                }

                guard let wheel = wheelEvent(lines: 5) else {
                    t.expect(false, desc: "a wheel event can be made")
                    return
                }
                surface.scrollWheel(with: wheel)
                t.pump(0.2)
                t.expect(surface.verticalOverscroll == 0, desc: "alternate-screen wheel input cannot bounce the terminal")
                // DEC 1007 is off, so the wheel is the local view's; the
                // alternate screen keeps no history, so the local view has
                // nowhere to go. The bar already shows none of it.
                t.expect(
                    surface.viewOffset == 0,
                    desc:
                        "the alt-screen wheel stayed at the tail (offset \(surface.viewOffset)), though the snapshot still reports \(surface.drive.readSnapshot().scrollbackCount) lines of primary history"
                )

                // The control: the same wheel on the primary screen moves,
                // so the assertion above is not an event that never arrived.
                surface.send("printf '\\033[?1049l'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if !surface.drive.readSnapshot().modes.alternateScreenActive { break }
                }
                guard let again = wheelEvent(lines: 5) else {
                    t.expect(false, desc: "a second wheel event can be made")
                    return
                }
                surface.scrollWheel(with: again)
                t.pump(0.2)
                t.expect(surface.viewOffset > 0, desc: "the primary screen's wheel scrolls into history (offset \(surface.viewOffset))")
            }
        }

        UBUITestRegister("swift_shell_clear_scrollback_retires_the_bar_at_once") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }
                t.expect(!bar.isHiddenOrHasHiddenAncestor, desc: "history behind it puts the bar in the tree")

                // The Edit menu's own responder, with the view at the tail,
                // where the offset does not move, so the bar is published only
                // if the clear publishes it. Asserted before any pump: this
                // command sends the process nothing, so no drain is coming to
                // correct a bar left sized on history that is gone.
                shell.clearScrollback(nil)
                t.expect(
                    surface.drive.readSnapshot().scrollbackCount == 0,
                    desc: "the clear reached the model (now \(surface.drive.readSnapshot().scrollbackCount) lines)"
                )
                t.expect(bar.isHiddenOrHasHiddenAncestor, desc: "the bar went with the history it was sized on, without waiting for output")

                // Retiring the bar is not hiding it for good.
                guard fillHistory(t, surface) else { return }
                t.expect(!bar.isHiddenOrHasHiddenAncestor, desc: "new history puts the bar back")
            }
        }

        UBUITestRegister("swift_shell_width_resize_keeps_the_top_logical_text") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let surface = TerminalSurface(rows: 24, columns: 80, fontFamily: "Menlo", pointSize: 13) else {
                    t.expect(false, desc: "a terminal surface can be made")
                    return
                }
                let window = NSWindow(
                    contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
                    styleMask: [.titled, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = surface
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                t.pump(0.2)
                let snapshot = surface.drive.readSnapshot()
                let columns = Int(snapshot.columns)
                var text =
                    "\u{1b}[H\u{1b}[2Ja\r\n"
                    + String(repeating: "x", count: columns * 3) + "\r\nTARGET keeper\r\n"
                for line in 0..<(Int(snapshot.rows) * 3) {
                    text += String(repeating: "y", count: 1 + line % 5 * columns / 2) + "\r\n"
                }
                surface.feed(Data(text.utf8))
                surface.offsetView(byLines: Int(surface.drive.readSnapshot().history.retainedRows) - 4)
                let topText = {
                    surface.drive.withTerminal { terminal -> String in
                        var text = ""
                        for column in 0..<6 {
                            if let cell = Ubiquitty.Screen.visibleCell(terminal, Int32(surface.viewOffset), 0, Int32(column)),
                                let scalar = UnicodeScalar(cell.pointee.codePoint)
                            {
                                text.unicodeScalars.append(scalar)
                            }
                        }
                        return text
                    } ?? ""
                }
                t.expect(topText() == "TARGET", desc: "the viewport starts on the target line")
                let frame = window.frame
                for width in [frame.width * 0.6, frame.width * 1.2, frame.width] {
                    let beforeColumns = surface.drive.readSnapshot().columns
                    window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height), display: false)
                    t.expect(surface.drive.readSnapshot().columns != beforeColumns, desc: "the window changed the grid width")
                    t.expect(topText() == "TARGET", desc: "the resized viewport still starts on the same text")
                }
            }
        }

        UBUITestRegister("swift_shell_resize_holds_the_viewport_and_resizes_the_bar") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }

                // Park the view in history: a resize under a view on the live
                // tail moves nothing, and would test nothing.
                guard let wheel = wheelEvent(lines: 3) else {
                    t.expect(false, desc: "a wheel event can be made")
                    return
                }
                surface.scrollWheel(with: wheel)
                t.pump(0.2)
                bar.doubleValue = 0.5
                bar.sendAction(bar.action, to: bar.target)
                t.pump(0.3)
                guard surface.viewOffset > 0 else {
                    t.expect(false, desc: "the view parks in history (offset \(surface.viewOffset))")
                    return
                }

                // Let the overlay bar fade first, so what the resize does to
                // it is readable at all.
                var wasFaded = false
                if bar.scrollerStyle == .overlay {
                    t.pump(2.4)
                    wasFaded = !knobIsRevealed(bar)
                    t.expect(wasFaded, desc: "the bar faded before the resize")
                }

                let before = surface.drive.readSnapshot()
                let offsetBefore = surface.viewOffset
                let proportionBefore = bar.knobProportion

                // The window's own resize, which is the path a drag takes: the
                // content view autoresizes the surface and the surface's
                // setFrameSize refits the grid, all inside this call.
                //
                // Asserted with no pump after it. The resize signals the child,
                // whose prompt redraw is a drain, and a drain refreshes the bar
                // on its own; pumping first would let the drain answer for the
                // resize path instead of testing it.
                let frame = window.frame
                window.setFrame(
                    NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: (frame.height * 0.6).rounded()),
                    display: false
                )

                let after = surface.drive.readSnapshot()
                guard after.rows != before.rows else {
                    t.expect(false, desc: "the resize moved the grid (still \(after.rows) rows)")
                    return
                }
                // A shorter screen pushes its top rows into history, so the
                // count the viewport is measured against moves — which is the
                // whole reason the carry below exists.
                guard after.history.retainedRows != before.history.retainedRows else {
                    t.expect(false, desc: "the resize moved history (still \(after.history.retainedRows) rows)")
                    return
                }
                guard after.columns == before.columns else {
                    t.expect(false, desc: "the resize kept the width, so nothing rewrapped (\(before.columns) → \(after.columns))")
                    return
                }

                // A height change renumbers nothing: the pushed rows land at the
                // newest end of history and every row the reader was on keeps
                // its place, so the view moves back by exactly the rows that
                // crossed and shows the very rows it showed.
                let pushed = Int(after.history.retainedRows) - Int(before.history.retainedRows)
                t.expect(
                    surface.viewOffset == offsetBefore + pushed,
                    desc: "the resize carried the viewport by the \(pushed) rows it pushed"
                        + " (\(offsetBefore) → \(surface.viewOffset))"
                )

                // The knob covers the viewport's share of the content, and the
                // viewport is the one the resize just made.
                let expected = CGFloat(after.rows) / CGFloat(Int(after.history.retainedRows) + Int(after.rows))
                t.expect(
                    bar.knobProportion < proportionBefore,
                    desc: "a shorter viewport covers less of the track (\(proportionBefore) → \(bar.knobProportion))"
                )
                t.expect(
                    abs(bar.knobProportion - expected) <= 0.02,
                    desc:
                        "the knob is the new viewport's share (\(bar.knobProportion) vs \(expected) for \(after.rows) rows over \(after.history.retainedRows) lines)"
                )

                // Reflow can reveal the native indicator as the extent changes.
                if wasFaded {
                    t.pump(2.4)
                    t.expect(!knobIsRevealed(bar), desc: "the native indicator fades after resize settles")
                }
            }
        }

        UBUITestRegister("swift_shell_a_taller_window_brings_a_near_view_back_to_the_tail") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }
                settleHistory(t, surface)
                let startFrame = window.frame

                // A few rows back: the prompt and the rows above it are what a
                // taller window pulls back onto the screen.
                surface.offsetView(byLines: 3)
                guard surface.viewOffset == 3 else {
                    t.expect(false, desc: "the view parks three rows back (offset \(surface.viewOffset))")
                    return
                }
                let before = surface.drive.readSnapshot()
                // Taller, top edge held, the way a drag of the bottom edge
                // grows it. Asserted with no pump after it, for the reason the
                // shorter-window scenario gives: the prompt the child redraws on
                // SIGWINCH is a drain, and a drain would answer for the resize.
                let grown = (startFrame.height * 1.5).rounded()
                window.setFrame(
                    NSRect(x: startFrame.minX, y: startFrame.maxY - grown, width: startFrame.width, height: grown),
                    display: false
                )
                let after = surface.drive.readSnapshot()
                let pulled = Int(before.history.retainedRows) - Int(after.history.retainedRows)
                guard after.rows > before.rows, pulled >= 3 else {
                    t.expect(
                        false,
                        desc: "the resize pulled the reader's rows out of history (\(before.rows) → \(after.rows) rows, \(pulled) pulled)"
                    )
                    return
                }
                t.expect(
                    surface.viewOffset == 0,
                    desc: "every row the reader was on is live now, and the view is on the tail with them (offset \(surface.viewOffset))"
                )

                // Back to the starting height, then deep in history: a pull that
                // stops short of the reader moves the view by the rows that
                // crossed and leaves it in history, on the same rows.
                window.setFrame(startFrame, display: false)
                t.pump(0.5)
                settleHistory(t, surface)
                surface.offsetView(byLines: 40)
                let deepBefore = surface.drive.readSnapshot()
                let deepOffset = surface.viewOffset
                guard deepOffset > 20 else {
                    t.expect(false, desc: "the view parks deep in history (offset \(deepOffset))")
                    return
                }
                window.setFrame(
                    NSRect(x: startFrame.minX, y: startFrame.maxY - grown, width: startFrame.width, height: grown),
                    display: false
                )
                let deepAfter = surface.drive.readSnapshot()
                let deepPulled = Int(deepBefore.history.retainedRows) - Int(deepAfter.history.retainedRows)
                t.expect(
                    deepPulled > 0 && surface.viewOffset == deepOffset - deepPulled,
                    desc: "a pull short of the reader holds their rows (\(deepOffset) → \(surface.viewOffset), \(deepPulled) pulled)"
                )
            }
        }

        UBUITestRegister("swift_shell_scroller_lifts_off_a_rounded_bottom_corner") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }

                // Opened under the rounded shape: the lift is the window's to
                // give at birth, and nothing here touches a setting after it.
                configureSquareBottomCorners(over: saved, false)
                guard let rounded = TerminalWindowController.spawn(),
                    let roundedContent = rounded.window?.contentView,
                    let roundedSurface = terminalSurface(under: roundedContent),
                    let roundedBar = scroller(in: roundedSurface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens under the rounded shape")
                    return
                }
                defer { rounded.window?.close() }
                t.pump(0.3)
                // History puts the bar on screen; the container places it in
                // its layout pass, so the pass is asked for rather than waited
                // on.
                guard fillHistory(t, roundedSurface) else { return }
                roundedSurface.layoutSubtreeIfNeeded()
                t.expect(
                    abs(bottomClearance(roundedBar, in: roundedSurface) - 16) <= 0.5,
                    desc: "a window born rounded lifts its bar off the corner"
                )

                // Square windows give the knob equal clearance below and to its right.
                configureSquareBottomCorners(over: saved, true)
                guard let square = TerminalWindowController.spawn(),
                    let squareContent = square.window?.contentView,
                    let squareSurface = terminalSurface(under: squareContent),
                    let squareBar = scroller(in: squareSurface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens under the square shape")
                    return
                }
                defer { square.window?.close() }
                t.pump(0.3)
                guard fillHistory(t, squareSurface) else { return }
                squareSurface.layoutSubtreeIfNeeded()
                t.expect(
                    abs(
                        bottomClearance(squareBar, in: squareSurface)
                            - (squareSurface.bounds.maxX - squareBar.convert(squareBar.rect(for: .knob), to: squareSurface).maxX)
                    ) <= 0.5,
                    desc: "a window born square matches the knob's bottom and right margins"
                )
            }
        }

        UBUITestRegister("swift_shell_split_pane_scroller_lifts_off_the_corner") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                configureSquareBottomCorners(over: saved, false)

                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let first = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens under the rounded shape")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                // The pane the model opens after the window exists: it reaches
                // the tree through the layout rebuild, which is where its bar
                // learns the shape.
                shell.splitRight(nil)
                t.pump(0.5)
                let panes = terminalSurfaces(under: content)
                guard panes.count == 2,
                    let added = panes.first(where: { $0 !== first }),
                    let addedBar = scroller(in: added)
                else {
                    t.expect(false, desc: "the split opened a second surface with a bar (\(panes.count) panes)")
                    return
                }
                guard fillHistory(t, added) else { return }
                added.layoutSubtreeIfNeeded()
                t.expect(
                    abs(bottomClearance(addedBar, in: added) - 16) <= 0.5,
                    desc: "a pane the split added stands on the same corner"
                )
            }
        }

        UBUITestRegister("swift_shell_scroller_follows_dec_mode_30") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let bar = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard fillHistory(t, surface) else { return }
                t.expect(!bar.isHiddenOrHasHiddenAncestor, desc: "history behind it puts the bar in the tree")

                // Sent through the shell rather than fed to the parser: the
                // chrome is refreshed off the drain that delivers output, so a
                // direct feed would move the mode without reaching the path
                // under test.
                surface.send("printf '\\033[?30l'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if bar.isHiddenOrHasHiddenAncestor { break }
                }
                t.expect(
                    !surface.drive.readSnapshot().modes.isScrollbarVisible,
                    desc: "the published snapshot is where the shell reads ?30"
                )
                t.expect(
                    bar.isHiddenOrHasHiddenAncestor,
                    desc:
                        "?30 reset took the bar away, with \(surface.drive.readSnapshot().history.retainedRows) lines still behind it"
                )

                surface.send("printf '\\033[?30h'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if !bar.isHiddenOrHasHiddenAncestor { break }
                }
                t.expect(!bar.isHiddenOrHasHiddenAncestor, desc: "?30 set gives the bar back")

                // Following new output can reveal the native indicator, but
                // the standing visibility mode must still allow it to fade.
                if bar.scrollerStyle == .overlay {
                    t.pump(2.4)
                    t.expect(!knobIsRevealed(bar), desc: "the bar faded with ?30 set")
                    surface.send("echo tick\n")
                    t.pump(2.4)
                    t.expect(!knobIsRevealed(bar), desc: "the native indicator fades after output settles with ?30 set")
                }
            }
        }

        UBUITestRegister("swift_shell_scroller_knob_is_tinted_against_the_theme") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content),
                    let overlay = scroller(in: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a scroller")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                // OSC 11 moves the default background, which is what the knob
                // is tinted against — not the window's appearance, which does
                // not move with it.
                surface.feed(Data("\u{1b}]11;#101014\u{07}".utf8))
                t.pump(0.2)
                surface.send("\n")
                t.pump(0.2)
                t.expect(
                    overlay.knobStyle == .light,
                    desc: "a dark ground takes a light knob (style \(overlay.knobStyle.rawValue))"
                )

                surface.feed(Data("\u{1b}]11;#f8f8f4\u{07}".utf8))
                t.pump(0.2)
                surface.send("\n")
                t.pump(0.2)
                t.expect(
                    overlay.knobStyle == .dark,
                    desc: "a light ground takes a dark knob (style \(overlay.knobStyle.rawValue))"
                )
            }
        }
    }
}
