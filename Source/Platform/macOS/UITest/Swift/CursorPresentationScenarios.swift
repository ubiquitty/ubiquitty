// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// CursorPresentationScenarios.swift — what a Kit-hosted pane's cursor paints
// as: filled when the pane holds focus or its window is a tab behind the
// group's front one, the hollow outline when it is unfocused and can be seen.
//
// The witness is what the frame was assembled with, read back off the frame's
// own options after the shared applier wrote them, not the surface's two facts
// re-derived here. A backgrounded tab's window is ordered out and AppKit runs
// no display cycle for it, so every probe forces a frame through the shell's
// own draw entry and refuses to read a witness no frame produced.

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

/// The cursor presentation of the frame a CHANGE asks for.
///
/// A pass nobody asked for encodes nothing, so drawing one more and reading
/// what came back does not reach a frame: it reaches a surface whose owed
/// frame an earlier run-loop turn already drew, and reports no witness at all.
/// The count is taken before the change instead, and the change itself is what
/// has to produce the frame.
///
/// That is the property worth pinning rather than an accommodation of the
/// skip. A focus edge paints no cell — it moves the cursor between filled and
/// hollow and nothing else — so an edge that marked no repaint would leave the
/// cursor it drew before standing on the glass, and a probe that asked for its
/// own frame would never see it.
///
/// The run loop turns only while nothing has been encoded, so a frame produced
/// on the changing turn is read against the facts the change set, before any
/// window edge can re-derive them.
///
/// - Parameters:
///   - t: The harness.
///   - surface: The surface the change is expected to repaint.
///   - change: The change under test.
/// - Returns: The presentation of the frame it asked for, or nil when it asked
///   for none, which the caller reports rather than reading a stale one.
@MainActor
private func presentationOfTheFrameAChangeAsksFor(
    _ t: UBUITestContext,
    of surface: TerminalSurface,
    through change: () -> Void
) -> TerminalSurface.FrameCursorPresentation? {
    let before = surface.framesEncodedForTesting
    change()
    surface.updateLayer()
    for _ in 0..<20 where surface.framesEncodedForTesting == before {
        t.pump(0.05)
        surface.updateLayer()
    }
    guard surface.framesEncodedForTesting > before else {
        return nil
    }
    return surface.lastFrameCursorPresentation
}

/// The cursor presentation of a frame a backgrounded, occluded tab ASSEMBLES.
///
/// An occluded tab has no drawable to commit to, so it never bumps the
/// committed-frame count the visible probe waits on; it owes a frame and waits
/// on the assembled count instead, which the build bumps whether or not a
/// drawable let it present. Scoped to the backgrounded-tab case so the owe that
/// lets the skip-unchanged-frames gate through touches no other scenario.
///
/// - Parameters:
///   - t: The harness.
///   - surface: The occluded tab's surface.
/// - Returns: The assembled frame's cursor presentation, or nil if none assembled.
@MainActor
private func presentationOfAnAssembledFrame(_ t: UBUITestContext, of surface: TerminalSurface) -> TerminalSurface.FrameCursorPresentation? {
    let before = surface.framesAssembledForTesting
    surface.needsDisplay = true
    surface.updateLayer()
    for _ in 0..<20 where surface.framesAssembledForTesting == before {
        t.pump(0.05)
        surface.needsDisplay = true
        surface.updateLayer()
    }
    guard surface.framesAssembledForTesting > before else {
        return nil
    }
    return surface.lastFrameCursorPresentation
}

/// A window with a second native tab added, and that tab in front.
///
/// - Parameters:
///   - t: The harness.
///   - shell: The controller of the first tab.
/// - Returns: The group's two windows, first tab first, or nil when the second
///   tab did not open or could not be brought to the front.
@MainActor
private func twoTabs(_ t: UBUITestContext, of shell: TerminalWindowController) -> (first: NSWindow, second: NSWindow)? {
    guard let first = shell.window else {
        return nil
    }
    first.makeKeyAndOrderFront(nil)
    t.pump(0.4)
    shell.newWindowForTab(nil)
    guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
        let group = first.tabGroup,
        let second = group.windows.first(where: { $0 !== first })
    else {
        return nil
    }
    // Set rather than waited for: the harness's windows never take key, so
    // the front tab is named here the way a click on it would name it, and
    // the main edges a real switch fires are posted for the same reason.
    group.selectedWindow = second
    second.makeKeyAndOrderFront(nil)
    guard t.wait(until: { group.selectedWindow === second }, timeout: 2) else {
        return nil
    }
    NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: first)
    NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: second)
    t.pump(0.2)
    return (first, second)
}

/// Registers the tab-strip chrome scenarios with the UI-test runner.
enum TabStripChromeScenarios {
    /// Registers every scenario in this file's tab-strip group.
    static func register() {
        // Opening a second tab takes the strip's height out of the content
        // view. Without the compensation the grid loses a row; with it the
        // window's bottom edge moves down instead and every row stays put.
        UBUITestRegister("swift_shell_tab_strip_keeps_the_grid_rows") { context in
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
                defer { window.tabGroup?.windows.forEach { $0.close() } }
                t.pump(0.5)

                // Away from the screen's bottom, so there is room to grow into:
                // a window already on the bottom edge keeps its frame and gives
                // up the row, which is Core's cap and not what this reads. The
                // premise is asserted, because the harness re-homes windows and
                // a window left on the bottom would pass this scenario for the
                // wrong reason.
                guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
                    t.expect(false, desc: "a screen to measure room against")
                    return
                }
                // Short as well as raised: a window as tall as the screen has
                // nowhere to grow into whatever its origin says, and the harness
                // opens one that fills the display.
                var raised = window.frame
                raised.size.height = 400
                raised.origin.y = visible.origin.y + 200
                window.setFrame(raised, display: true)
                t.pump(0.5)
                t.expect(
                    window.frame.origin.y > visible.origin.y + 100,
                    desc: "the window has room below it (y \(window.frame.origin.y) over \(visible.origin.y))"
                )

                let rowsBefore = surface.drive.readSnapshot().rows
                let bottomBefore = window.frame.origin.y
                t.expect(rowsBefore > 0, desc: "the first tab has a grid (\(rowsBefore) rows)")

                shell.newWindowForTab(nil)
                t.expect(
                    t.wait(until: { (window.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    desc: "a second tab opens"
                )
                t.pump(0.8)

                let rowsAfter = surface.drive.readSnapshot().rows
                t.expect(
                    rowsAfter == rowsBefore,
                    desc: "the first tab keeps its rows across the strip appearing (\(rowsBefore) → \(rowsAfter))"
                )
                t.expect(
                    window.frame.origin.y < bottomBefore,
                    desc: "because the window's bottom edge moved down instead"
                )
            }
        }
        UBUITestRegister("swift_shell_tab_strip_preserves_inspector_viewport") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                for roomBelow in [CGFloat(200), 0] {
                    guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                        let surface = shell.focusedSurfaceForTesting,
                        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
                    else {
                        t.expect(false, desc: "a terminal window opens on a screen")
                        return
                    }
                    defer { (window.tabGroup?.windows ?? [window]).forEach { $0.close() } }
                    shell.toggleNativeInspector(nil)
                    t.pump(0.3)
                    shell.toggleNativeInspector(nil)
                    var frame = window.frame
                    frame.size.height = 400
                    frame.origin.y = visible.minY + roomBelow
                    window.setFrame(frame, display: true)
                    t.pump(0.5)
                    let before = window.frame
                    let rows = surface.drive.readSnapshot().rows
                    let viewport = before.height - shell.terminalFrameOverhead.height
                    shell.newWindowForTab(nil)
                    t.pump(0.8)
                    guard let group = window.tabGroup, group.windows.count == 2,
                        let selected = group.selectedWindow,
                        let selectedShell = selected.windowController as? TerminalWindowController
                    else {
                        t.expect(false, desc: "a second tab joins the window")
                        continue
                    }
                    if roomBelow > 0 {
                        let afterViewport = selected.frame.height - selectedShell.terminalFrameOverhead.height
                        t.expect(
                            abs(afterViewport - viewport) < 1,
                            desc: "the selected tab preserves viewport height (\(viewport) → \(afterViewport))"
                        )
                        t.expect(
                            abs(selected.frame.maxY - before.maxY) < 1 && selected.frame.height > before.height,
                            desc: "only the bottom edge grows for the strip"
                        )
                        group.selectedWindow = window
                        t.pump(0.3)
                        t.expect(surface.drive.readSnapshot().rows == rows, desc: "the original tab keeps its rows after reselection")
                    } else {
                        t.expect(
                            abs(selected.frame.height - before.height) < 1 && abs(selected.frame.minY - before.minY) < 1,
                            desc: "a window at the screen bottom keeps its frame"
                        )
                    }
                }
            }
        }

        // Output on a tab nobody is looking at marks it, and the strip carries
        // the mark. Every window here is a tab nobody is looking at: the
        // harness is an accessory application whose windows never take key, so
        // the shell's own first prompt already marks a fresh window. That is
        // the state under test rather than a nuisance, and the clear half is
        // the same foreground fact, pinned in Core because no window here can
        // ever satisfy it.
        UBUITestRegister("swift_shell_backgrounded_tab_marks_unseen_activity") { context in
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
                t.expect(!window.isKeyWindow, desc: "the harness's window cannot take key, so its tab is one nobody is looking at")

                surface.send("echo marking-this-tab\n")
                t.expect(
                    t.wait(until: { shell.hasUnseenActivity }, timeout: 8.0),
                    desc: "output on a tab nobody is looking at marks it"
                )
                guard let dots = window.tab.accessoryView as? TabAttentionDots else {
                    t.expect(false, desc: "and the strip carries the mark")
                    return
                }
                t.expect(dots.dotCount == 3, desc: "as the strip's ellipsis, which is activity rather than a status")

                // A marked tab decides nothing further, so a flood costs one
                // comparison per drain rather than an accessory rebuilt per
                // chunk. Read on the accessory's identity, which a rebuild
                // would replace.
                surface.send("for i in $(seq 1 200); do echo flood-$i; done\n")
                t.pump(1.5)
                t.expect(
                    window.tab.accessoryView === dots,
                    desc: "and a flood after it does not rebuild the mark"
                )
            }
        }

        // OSC 21337 raises a status dot on a tab the reader is not on. The
        // dots view is shared three ways — a program's status, an unseen
        // notification and unseen output — so its presence alone proves
        // nothing: output raises three dim dots and a notification one in the
        // system's blue. Only the status raises ONE dot in the colour the
        // program asked for, so the count and the colour are both the claim.
        UBUITestRegister("swift_shell_osc21337_raises_the_status_dot_on_a_background_tab") { context in
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
                defer { window.tabGroup?.windows.forEach { $0.close() } }
                // A second tab in front, so the first is a background tab with
                // a strip to draw in.
                guard let tabs = twoTabs(t, of: shell), tabs.first === window else {
                    t.expect(false, desc: "a second tab opens in front of the first")
                    return
                }

                // #ff9500, as the program below asks for it.
                let wearsTheAskedDot = {
                    guard let dots = window.tab.accessoryView as? TabAttentionDots, dots.dotCount == 1,
                        let tint = dots.tintColor.usingColorSpace(.sRGB)
                    else {
                        return false
                    }
                    return tint.redComponent > 0.9 && tint.greenComponent > 0.45 && tint.greenComponent < 0.75
                        && tint.blueComponent < 0.15
                }
                t.expect(!wearsTheAskedDot(), desc: "before the request the background tab wears no status dot")

                surface.send("printf '\\033]21337;indicator=#ff9500\\007'\n")
                t.expect(
                    t.wait(until: wearsTheAskedDot, timeout: 10.0),
                    desc: "OSC 21337 raises one dot in the asked colour on the background tab"
                        + " (\(String(describing: window.tab.accessoryView)))"
                )
            }
        }
    }
}

/// Registers the cursor-presentation scenarios with the UI-test runner.
enum CursorPresentationScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // `[appearance] blink_animation` drives Core's process-wide blink
        // curve. It reached the curve only from the Settings row, so a file
        // that turned the fade off — loaded at launch or saved while the app
        // ran — left every cursor fading. The document is the input here, as
        // a load or a save hands it over.
        UBUITestRegister("swift_shell_a_configured_blink_animation_reaches_the_curve") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                let saved = t.configureAppending("[appearance]\nblink_animation = false\n")
                defer { t.restoreConfiguration(saved) }
                t.expect(Ubiquitty.Cursor.Blink.animation() == .OnOff, desc: "a document turning the fade off switches the curve")
                t.restoreConfiguration(saved)
                t.configureAppending("[appearance]\nblink_animation = true\n")
                t.expect(Ubiquitty.Cursor.Blink.animation() == .Fade, desc: "and one turning it on fades again")
            }
        }

        // A line the parse could not place is a setting the reader wrote and
        // will not get; the window says so in its title row rather than only
        // in a log nobody opens, and a document that applies whole withdraws
        // the line.
        UBUITestRegister("swift_shell_a_configuration_diagnostic_reaches_the_title_row") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                _ = Ubiquitty.Preferences.configure(std.string("[font]\nsise = 14.0\n"), .Permissive)
                t.pump(0.1)
                t.expect(
                    shell.hintTextForTesting.contains("line 2: no setting named font.sise"),
                    desc: "the misspelt key is named with its line (\(shell.hintTextForTesting))"
                )
                _ = Ubiquitty.Preferences.configure(std.string("[font]\nsize = 14.0\n"), .Permissive)
                t.pump(0.1)
                t.expect(shell.hintTextForTesting.isEmpty, desc: "a document that applies whole withdraws the line")
            }
        }

        // The diagnostic shares the title row with the window buttons. In a
        // narrow window a sentence sized to its own text reached past the
        // zoom button and was drawn over all three; it has to stop at the
        // buttons and truncate. It is also a fact about a file the reader may
        // not want to fix yet: a press dismisses it, and the same document
        // does not raise it again.
        UBUITestRegister("swift_shell_a_configuration_diagnostic_clears_the_window_buttons") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                window.setContentSize(NSSize(width: 360, height: 240))
                t.pump(0.2)
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                let misspelt = "[appearance]\nrenderer = \"modern\"\n"
                _ = Ubiquitty.Preferences.configure(std.string(misspelt), .Permissive)
                t.pump(0.2)
                t.expect(
                    shell.hintTextForTesting.contains("no setting named appearance.renderer"),
                    desc: "the diagnostic is shown (\(shell.hintTextForTesting))"
                )
                guard let hint = shell.hintViewForTesting else {
                    t.expect(false, desc: "the window has a hint line")
                    return
                }
                let hintFrame = hint.convert(hint.bounds, to: nil)
                let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                for type in buttons {
                    guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
                    let buttonFrame = button.convert(button.bounds, to: nil)
                    t.expect(
                        !hintFrame.intersects(buttonFrame),
                        desc:
                            "the hint \(hintFrame) clears window button \(type.rawValue) at \(buttonFrame) in a \(window.frame.width)-point window"
                    )
                }
                t.expect(
                    hintFrame.minX >= 0 && hintFrame.maxX <= window.frame.width,
                    desc: "the hint \(hintFrame) fits the \(window.frame.width)-point title row"
                )
                t.expect(
                    hint.fittingSize.width > hintFrame.width,
                    desc: "the sentence is truncated rather than laid out whole (\(hint.fittingSize.width) in \(hintFrame.width))"
                )

                t.expect(hint.accessibilityPerformPress(), desc: "the hint takes a press")
                t.pump(0.1)
                t.expect(shell.hintTextForTesting.isEmpty, desc: "a press dismisses the diagnostic (\(shell.hintTextForTesting))")

                _ = Ubiquitty.Preferences.configure(std.string("[font]\nsize = 14.0\n"), .Permissive)
                t.pump(0.1)
                _ = Ubiquitty.Preferences.configure(std.string(misspelt), .Permissive)
                t.pump(0.1)
                t.expect(shell.hintTextForTesting.isEmpty, desc: "the same document does not raise it again (\(shell.hintTextForTesting))")
                if let other = TerminalWindowController.spawn() {
                    t.pump(0.2)
                    t.expect(other.hintTextForTesting.isEmpty, desc: "nor does a window opened later (\(other.hintTextForTesting))")
                    other.window?.close()
                }

                _ = Ubiquitty.Preferences.configure(std.string("[font]\nsise = 14.0\n"), .Permissive)
                t.pump(0.1)
                t.expect(
                    shell.hintTextForTesting.contains("no setting named font.sise"),
                    desc: "a different diagnostic is shown (\(shell.hintTextForTesting))"
                )
            }
        }

        // A cursor preference write produces no ingest, and every reader
        // downstream polls the PUBLISHED snapshot rather than the model: the
        // frame's cursor, and the animation schedule's decision about whether
        // anything on screen still moves. A write that did not republish would
        // sit inert until the next byte from the host — which for a reader
        // means until they type.
        // A translucent cursor is display policy, not content: the model's
        // palette carries three channels and no alpha, so the preference has
        // to arrive beside the colour or the cursor draws solid however it was
        // configured.
        UBUITestRegister("swift_shell_a_translucent_cursor_reaches_the_frame") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.5)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                t.expect(
                    t.wait(until: { surface.lastFrameCursorAlpha == 1 }, timeout: 4),
                    desc: "an unconfigured cursor is drawn solid"
                )

                // A value nothing else in the fold carries, so an alpha read
                // back as this one names the setting rather than agreeing with
                // a default by coincidence.
                let saved = t.configureAppending("[cursor]\nalpha = 96\n")
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                }
                TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                surface.feed(Data("x".utf8))
                t.expect(
                    t.wait(until: { abs(surface.lastFrameCursorAlpha - 96.0 / 255.0) < 0.005 }, timeout: 6),
                    desc: "and a configured one reaches the frame at the opacity the reader asked for"
                )
            }
        }

        // A blink edge is answered by two timers spaced to the same crossing:
        // the frame clock's tick and the one-shot each drawn frame arms. Each
        // edge is drawn once, for a blinking block and bar, faded or switched,
        // and the blinking stops with the focus. Frames ASSEMBLED count every
        // pass that resolved a cursor; frames ENCODED count the ones that
        // presented, so a pass repeated per edge shows as the assembled count
        // growing with the edges rather than staying a fixed few above them.
        UBUITestRegister("swift_shell_each_blink_edge_draws_once_and_stops_unfocused") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                // The harness app is an accessory and has no key window, so
                // the pane is told it holds focus the way an offscreen host
                // tells it.
                surface.setSurfaceFocused(true)
                var saved: String?
                defer {
                    if let saved {
                        t.restoreConfiguration(saved)
                    }
                    TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                }
                let cases: [(name: String, decscusr: String, isFaded: Bool)] = [
                    ("block, faded", "\u{1b}[1 q", true),
                    ("bar, faded", "\u{1b}[5 q", true),
                    ("block, switched", "\u{1b}[1 q", false),
                ]
                for blinkCase in cases {
                    if let saved {
                        t.restoreConfiguration(saved)
                    }
                    saved = t.configureAppending("[cursor]\nblink = true\n\n[appearance]\nblink_animation = \(blinkCase.isFaded)\n")
                    TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                    surface.feed(Data(blinkCase.decscusr.utf8))
                    // Past the activity hold, which keeps the caret solid
                    // after the bytes above.
                    t.pump(1.0)
                    let encodedBefore = surface.framesEncodedForTesting
                    let assembledBefore = surface.framesAssembledForTesting
                    t.pump(2.0)
                    let encoded = surface.framesEncodedForTesting - encodedBefore
                    let assembled = surface.framesAssembledForTesting - assembledBefore
                    t.expect(encoded >= 3, desc: "\(blinkCase.name): the caret blinks, \(encoded) frames in 2 s")
                    // Every pass presents: the schedule sleeps to each blink
                    // edge, past the solid phase's length, so no pass wakes to
                    // an unchanged caret and none is repeated for an edge.
                    t.expect(
                        assembled == encoded,
                        desc: "\(blinkCase.name): every pass presents an edge (\(assembled) assembled, \(encoded) presented)"
                    )
                }
                surface.setSurfaceFocused(false)
                t.pump(0.5)
                let unfocusedBefore = surface.framesEncodedForTesting
                t.pump(2.0)
                let unfocused = surface.framesEncodedForTesting - unfocusedBefore
                t.expect(unfocused == 0, desc: "an unfocused pane stops blinking, \(unfocused) frames in 2 s")
                t.expect(!surface.isAnimationClockArmed, desc: "and its animation clock stands down")
            }
        }

        UBUITestRegister("swift_shell_a_cursor_preference_takes_effect_without_typing") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }

                let before = surface.drive.readSnapshot().cursorBlinkEnabled
                let saved = t.configureAppending("[cursor]\nblink = \(!before)\n")
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                }
                TerminalWindowController.applyTerminalPreferencesToOpenWindows()

                // Nothing is fed and nothing is typed: the published snapshot
                // is asked directly, which is the reader every frame uses.
                t.expect(
                    surface.drive.readSnapshot().cursorBlinkEnabled == !before,
                    desc: "the write reaches the published snapshot with no input at all"
                )
            }
        }

        UBUITestRegister("swift_shell_a_picked_shape_outranks_a_stale_decscusr") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }

                var saved: String?
                defer {
                    if let saved {
                        t.restoreConfiguration(saved)
                    }
                    TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                }

                // A prompt-dressing shell's DECSCUSR: steady underline, which is
                // not the sentinel the pick restores.
                let steadyUnderline = UInt8(Ubiquitty.Cursor.Style.SteadyUnderline.rawValue)
                let sentinel = UInt8(Ubiquitty.Cursor.Style.FollowUserPreference.rawValue)
                surface.feed(Data("\u{1b}[4 q".utf8))
                t.expect(
                    t.wait(until: { surface.drive.readSnapshot().cursorStyle == steadyUnderline }, timeout: 3),
                    desc: "the program's DECSCUSR stands on the published snapshot"
                )

                // A reload is not a pick: an unrelated key moving must not
                // revoke what the running program asked for.
                let flippedBlink = !Ubiquitty.Preferences.Effective.cursorBlink(Ubiquitty.Preferences.values().pointee)
                saved = t.configureAppending("[cursor]\nblink = \(flippedBlink)\n")
                TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                t.expect(
                    surface.drive.readSnapshot().cursorStyle == steadyUnderline,
                    desc: "a reload leaves the program's style standing"
                )

                // The pick does revoke it, and with nothing fed and nothing typed.
                TerminalWindowController.applyPickedCursorShapeToOpenWindows()
                t.expect(
                    surface.drive.readSnapshot().cursorStyle == sentinel,
                    desc: "the pick hands the shape back to the reader"
                )

                // Handing it back is not taking it away: the next DECSCUSR wins
                // like any other.
                surface.feed(Data("\u{1b}[4 q".utf8))
                t.expect(
                    t.wait(until: { surface.drive.readSnapshot().cursorStyle == steadyUnderline }, timeout: 3),
                    desc: "the program reclaims the shape the next time it asks"
                )
            }
        }

        // The caret's glide is a `[cursor]` preference like the blink, and it
        // travels the same seed: the fan-out writes it onto the terminal, the
        // capture carries it to the animator, and the system's Reduce Motion
        UBUITestRegister("swift_shell_a_cursor_motion_preference_reaches_the_terminal") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }

                t.expect(
                    surface.drive.withTerminal { $0.cursorMotionModePref } == .Off,
                    desc: "an unconfigured caret is seeded Off, so it snaps"
                )

                // Values nothing else in the fold carries, so a read-back names
                // the setting rather than agreeing with a default by chance.
                let saved = t.configureAppending("[cursor]\nmotion = \"long\"\nmotion_duration = 180\n")
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                }
                TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                // Nothing is fed and nothing is typed: the model is asked directly.
                t.expect(
                    surface.drive.withTerminal { $0.cursorMotionModePref } == .Long,
                    desc: "the write reaches the terminal's glide policy with no input at all"
                )
                t.expect(
                    surface.drive.withTerminal { $0.cursorMotionDurationMilliseconds } == 180,
                    desc: "and the duration the reader asked for travels with it"
                )

                surface.feed(Data("\u{1b}[?25h\u{1b}[2 q\u{1b}[1;1H".utf8))
                t.pump(0.2)
                surface.setSurfaceFocused(true)
                surface.needsDisplay = true
                surface.updateLayer()
                surface.feed(Data("\u{1b}[1;30H".utf8))
                t.pump(0.08)
                surface.needsDisplay = true
                surface.updateLayer()
                let isSliding = surface.frameRenderers.values.contains { $0.isCursorSliding }
                t.expect(
                    isSliding != SystemMotionPreference.isReduceMotionEnabled,
                    desc: "the rendered cursor glides under the configured policy unless Reduce Motion is enabled"
                )
                t.expect(surface.isAnimationClockArmed, desc: "the glide keeps an animation clock armed")
                // Parked test windows have no compositor requesting animation frames.
                for _ in 0..<30 {
                    t.pump(0.02)
                    surface.needsDisplay = true
                    surface.updateLayer()
                }
                t.expect(
                    !surface.frameRenderers.values.contains { $0.isCursorSliding },
                    desc: "the rendered glide settles after its configured duration"
                )

                // The system's answer is sampled once for the process, ahead
                // of any window, and every animator reads that copy at its tick.
                t.expect(
                    SystemMotionPreference.isReduceMotionEnabled
                        == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    desc: "the process's Reduce Motion answer is the system's"
                )
            }
        }

        UBUITestRegister("swift_shell_backgrounded_tab_keeps_a_solid_cursor") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.tabGroup?.windows.forEach { $0.close() } }
                guard let tabs = twoTabs(t, of: shell),
                    let content = tabs.first.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a second tab opens in front of the first")
                    return
                }
                // The state the key-window recompute produces for a window that
                // is not key, driven here so the probe does not depend on the
                // harness's app activation.
                surface.setSurfaceFocused(false)
                t.expect(
                    t.wait(until: { surface.isWindowBackgroundedTab }, timeout: 3),
                    desc: "the first tab learns it is behind the front one"
                )
                guard let presentation = presentationOfAnAssembledFrame(t, of: surface) else {
                    t.expect(false, desc: "the backgrounded tab's surface encodes a frame when asked")
                    return
                }
                t.expect(presentation.isWindowBackgroundedTab, desc: "the frame was assembled as a backgrounded tab")
                t.expect(!presentation.isPaneFocused, desc: "and as an unfocused pane")
                t.expect(
                    presentation.isCursorFilled,
                    desc: "and its cursor paints filled, not as the outline a reselection would show stale"
                )
            }
        }

        UBUITestRegister("swift_shell_unfocused_visible_window_draws_the_hollow_cursor") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.tabGroup?.windows.forEach { $0.close() } }
                guard let tabs = twoTabs(t, of: shell),
                    let selectedContent = tabs.second.contentView,
                    let selected = terminalSurface(under: selectedContent)
                else {
                    t.expect(false, desc: "a second tab opens in front of the first")
                    return
                }

                // (1) The front tab of a group, unfocused: seen, so the outline.
                //
                // The fill is taken first, and taken all the way to the glass.
                // The test app is never made key, so a pane in it arrives
                // unfocused already: telling it to unfocus is no edge, publishes
                // nothing, and asks for no frame. Setting the fact alone is not
                // enough either — a frame is skipped when it reproduces what is
                // presented, and an outline drawn over an outline does. So the
                // filled cursor has to be on the glass for losing it to be the
                // edge this pins.
                let filledToBeginWith = presentationOfTheFrameAChangeAsksFor(t, of: selected) {
                    selected.setSurfaceFocused(true)
                }
                guard filledToBeginWith?.isCursorFilled == true else {
                    t.expect(false, desc: "the front tab's cursor is filled to begin with")
                    return
                }
                let unfocused = presentationOfTheFrameAChangeAsksFor(t, of: selected) {
                    selected.setSurfaceFocused(false)
                }
                guard let front = unfocused else {
                    t.expect(false, desc: "losing focus asks the front tab's surface for a frame")
                    return
                }
                t.expect(!front.isWindowBackgroundedTab, desc: "the front tab is behind nothing")
                t.expect(!front.isCursorFilled, desc: "and unfocused it draws the hollow outline; a tab group alone is no reason to fill")

                // (2) A lone window, unfocused: no group, so the outline.
                guard let lone = TerminalWindowController.spawn(),
                    let loneWindow = lone.window,
                    let loneContent = loneWindow.contentView,
                    let loneSurface = terminalSurface(under: loneContent)
                else {
                    t.expect(false, desc: "a second, standalone Swift-shell window opens")
                    return
                }
                defer { loneWindow.close() }
                t.pump(0.3)
                let loneFilledToBeginWith = presentationOfTheFrameAChangeAsksFor(t, of: loneSurface) {
                    loneSurface.setSurfaceFocused(true)
                }
                guard loneFilledToBeginWith?.isCursorFilled == true else {
                    t.expect(false, desc: "the standalone window's cursor is filled to begin with")
                    return
                }
                let loneUnfocused = presentationOfTheFrameAChangeAsksFor(t, of: loneSurface) {
                    loneSurface.setSurfaceFocused(false)
                }
                guard let standalone = loneUnfocused else {
                    t.expect(false, desc: "losing focus asks the standalone window's surface for a frame")
                    return
                }
                t.expect(!standalone.isWindowBackgroundedTab, desc: "a lone window is behind nothing")
                t.expect(!standalone.isCursorFilled, desc: "and unfocused it draws the hollow outline")

                // (3) The control in the other direction: the fill is a decision,
                // not a constant, so focus brings it back.
                let refocused = presentationOfTheFrameAChangeAsksFor(t, of: selected) {
                    selected.setSurfaceFocused(true)
                }
                guard let focused = refocused else {
                    t.expect(false, desc: "regaining focus asks the front tab's surface for a frame")
                    return
                }
                t.expect(focused.isCursorFilled, desc: "focused again, the front tab's cursor paints filled")
            }
        }

        // What a pane behind the front tab costs. The drain gate is the one
        // place the surface's own pushes are visible from outside Core: a
        // presented pane on an unthrottled machine rides the gaps inside a
        // burst, and anything else parks at the first one and picks the
        // output up on the next poll. The pane keeps capturing either way —
        // that is why the tab can be brought forward without showing the
        // state it stopped at.
        UBUITestRegister("swift_shell_backgrounded_tab_stops_riding_the_burst") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.tabGroup?.windows.forEach { $0.close() } }
                guard let tabs = twoTabs(t, of: shell),
                    let behindContent = tabs.first.contentView,
                    let behind = terminalSurface(under: behindContent),
                    let frontContent = tabs.second.contentView,
                    let front = terminalSurface(under: frontContent)
                else {
                    t.expect(false, desc: "a second tab opens in front of the first")
                    return
                }
                t.expect(
                    t.wait(until: { !behind.drive.isDrainRidingBurst }, timeout: 3),
                    desc: "the tab behind the front one stops riding the burst"
                )
                // The control: the front tab of the same group, on the same
                // machine, at the same moment. Without it a gate that reads
                // false for every pane would pass.
                t.expect(front.drive.isDrainRidingBurst, desc: "while the front tab of the same group still rides it")

                // Bringing it back is the other half — a pane that never
                // recovered would read the same on the step above.
                tabs.first.tabGroup?.selectedWindow = tabs.first
                NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: tabs.second)
                NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: tabs.first)
                t.expect(
                    t.wait(until: { behind.drive.isDrainRidingBurst }, timeout: 3),
                    desc: "and rides it again once it is the front tab"
                )

                // The machine's own budget reaches the gate on its own edges.
                // A cool machine at full charge answers the same thing every
                // time, so what is asked here is that the handler RAN: the
                // registration is the half a scenario driving the method
                // itself would never touch.
                let before = behind.machineBudgetPushesForTesting
                NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
                t.expect(
                    t.wait(until: { behind.machineBudgetPushesForTesting > before }, timeout: 3),
                    desc: "a thermal edge reaches the surface"
                )
                let afterThermal = behind.machineBudgetPushesForTesting
                NotificationCenter.default.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
                t.expect(
                    t.wait(until: { behind.machineBudgetPushesForTesting > afterThermal }, timeout: 3),
                    desc: "and so does a power-state edge, which is its own registration"
                )
            }
        }
    }
}
