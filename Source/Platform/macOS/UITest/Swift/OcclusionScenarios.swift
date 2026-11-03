// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// OcclusionScenarios.swift — what a pane nothing composites draws, and what a
// pane brought back draws first.
//
// Two properties, and they pull against each other. A window covered whole by
// another encodes nothing: the frames it would present reach a drawable the
// window server throws away, so the work buys a reader nothing. And a window
// brought forward shows its current content on the first frame — the window
// system's occlusion report lags a reveal, so a pane that waited for the report
// to say "visible" would show the layer it stopped at, which after a long cover
// is minutes old.
//
// The harness parks its windows outside every display while leaving them
// ordered and drawable, so the occlusion report describes the parking rather
// than a cover. `isFullyOccludedForTesting` stands in for the report, and the
// report's own notification is still what settles the policy — a scenario sets
// the fact and posts the notification, in the order the window server would.

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

/// Covers or uncovers a surface's window, as the window server would report it.
///
/// - Parameters:
///   - surface: The pane whose window the report describes.
///   - isCovered: Whether nothing of the window is on screen.
///   - t: The running scenario, for pumping the report's delivery.
@MainActor
func report(_ surface: TerminalSurface, covered isCovered: Bool, pumpingWith t: UBUITestContext) {
    surface.isFullyOccludedForTesting = isCovered
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface.window)
    t.pump(0.1)
}

/// Whether the surface commits a frame within a few run-loop turns.
///
/// Turns rather than seconds: the property is that the reveal's frame is the
/// next one drawn, not that one lands inside a window of time a slow machine
/// could miss.
///
/// - Parameters:
///   - surface: The pane to watch.
///   - before: The commit count taken before the edge.
///   - turns: How many turns to pump.
///   - t: The running scenario.
/// - Returns: Whether a frame was committed.
@MainActor
private func encodes(_ surface: TerminalSurface, past before: Int, withinTurns turns: Int, pumpingWith t: UBUITestContext) -> Bool {
    for _ in 0..<turns where surface.framesEncodedForTesting == before {
        t.pump(0.02)
    }
    return surface.framesEncodedForTesting > before
}

/// Clears the screen and stills the caret, so only the scenario's own writes
/// move a pixel.
///
/// - Parameters:
///   - surface: The pane to quiet.
///   - t: The running scenario.
@MainActor
private func quiet(_ surface: TerminalSurface, pumpingWith t: UBUITestContext) {
    surface.drive.stopIngest()
    // A steady block: the caret's blink is an animation of its own, and a
    // covered pane's clock standing down is one of the things under test.
    surface.feed(Data("\u{1b}[2 q\u{1b}[2J\u{1b}[H".utf8))
    t.pump(0.3)
}

/// Writes one line at a row and parks the caret well below it.
///
/// The caret draws a cell instance of its own, so a row read back as empty has
/// to be a row the caret is not resting on.
///
/// - Parameters:
///   - text: The line to write.
///   - row: The row to write it at, from zero.
///   - surface: The pane to write into.
@MainActor
private func write(_ text: String, atRow row: Int, to surface: TerminalSurface) {
    surface.feed(Data("\u{1b}[\(row + 1);1H\(text)\u{1b}[\(caretParkRow + 1);1H".utf8))
}

/// The row the caret is parked on between writes.
private let caretParkRow = 12

/// A window with a second native tab added, and that tab in front.
///
/// - Parameters:
///   - t: The harness.
///   - shell: The controller of the first tab.
/// - Returns: The group's two windows, first tab first, or nil when the second
///   tab did not open.
@MainActor
private func twoTabs(_ t: UBUITestContext, of shell: TerminalWindowController) -> (first: NSWindow, second: NSWindow)? {
    guard let first = shell.window else { return nil }
    first.makeKeyAndOrderFront(nil)
    t.pump(0.4)
    shell.newWindowForTab(nil)
    guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
        let group = first.tabGroup,
        let second = group.windows.first(where: { $0 !== first })
    else {
        return nil
    }
    // Named rather than waited for: the harness's windows never take key, so
    // the front tab is set the way a click on it would set it, and the main
    // edges a real switch fires are posted for the same reason.
    group.selectedWindow = second
    second.makeKeyAndOrderFront(nil)
    guard t.wait(until: { group.selectedWindow === second }, timeout: 2) else { return nil }
    NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: first)
    NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: second)
    t.pump(0.2)
    return (first, second)
}

/// Registers the occlusion scenarios with the UI-test runner.
enum OcclusionScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_process_sampling_follows_visible_components_and_inspector") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The default close button marker also observes processes;
                // disable it to isolate the title and inspector consumers.
                let saved = t.configureAppending(
                    "[title]\nwindow_process = false\nwindow_shell_command = false\ntab_process = true\n"
                        + "tab_shell_command = false\npane_process = false\npane_shell_command = false\n"
                        + "[terminal]\nclose_confirmation = \"never\"\n"
                )
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTitleCompositionToOpenWindows()
                }
                guard let shell = TerminalWindowController.spawn(),
                    let tabs = twoTabs(t, of: shell),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "two native tabs open")
                    return
                }
                defer {
                    surface.send("\u{3}")
                    tabs.first.close()
                    tabs.second.close()
                }
                TerminalWindowController.applyTitleCompositionToOpenWindows()
                report(surface, covered: true, pumpingWith: t)
                let frames = surface.framesEncodedForTesting
                surface.send("sleep 20\r")
                t.expect(
                    t.wait(until: { surface.drive.processChain.contains("sleep") }, timeout: 8),
                    desc: "an inactive visible tab samples the process component"
                )
                t.expect(
                    surface.framesEncodedForTesting == frames,
                    desc: "updating the tab metadata does not render its hidden canvas"
                )
                t.restoreConfiguration(saved)
                t.configureAppending(
                    "[title]\nwindow_process = false\nwindow_shell_command = false\ntab_process = false\n"
                        + "tab_shell_command = false\npane_process = false\npane_shell_command = false\n"
                        + "[terminal]\nclose_confirmation = \"never\"\n"
                )
                TerminalWindowController.applyTitleCompositionToOpenWindows()
                t.pump(0.3)
                let generation = surface.drive.processRecordsGeneration
                surface.send("\u{3}sleep 21\r")
                t.pump(0.8)
                t.expect(
                    surface.drive.processRecordsGeneration == generation,
                    desc: "no displayed process component means no process sampling"
                )
                shell.toggleNativeInspector(nil)
                t.expect(
                    t.wait(until: { surface.drive.processRecordsGeneration != generation }, timeout: 8),
                    desc: "opening the inspector resumes process sampling without a title component"
                )
            }
        }
        UBUITestRegister("swift_shell_covered_titles_refresh_on_reveal") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a window opens with a terminal surface")
                    return
                }
                let saved = t.configureAppending("[title]\nwindow_app_title = true\n")
                defer {
                    t.restoreConfiguration(saved)
                    window.close()
                }
                window.orderFront(nil)
                quiet(surface, pumpingWith: t)
                report(surface, covered: false, pumpingWith: t)
                surface.feed(Data("\u{1b}]2;VISIBLE-TITLE\u{7}".utf8))
                surface.deliver([.titleChanged])
                t.pump(0.2)
                let originalTitle = window.title
                t.expect(originalTitle.contains("VISIBLE-TITLE"), desc: "the configured title includes the program's title")
                let originalWeaves = shell.windowTitleWeavesForTesting
                report(surface, covered: true, pumpingWith: t)
                surface.feed(Data("\u{1b}]2;HIDDEN-FIRST\u{7}\u{1b}]2;HIDDEN-LATEST\u{7}".utf8))
                surface.deliver([.titleChanged])
                t.pump(0.2)
                t.expect(window.title == originalTitle, desc: "covered output does not change the native title")
                t.expect(shell.windowTitleWeavesForTesting == originalWeaves, desc: "covered title changes do not weave or lay out a title")
                t.expect(
                    surface.title == "VISIBLE-TITLE",
                    desc: "the app does not ask for a covered pane's title, so the surface holds it (\(surface.title))"
                )
                report(surface, covered: false, pumpingWith: t)
                t.expect(surface.title == "HIDDEN-LATEST", desc: "reveal hands the held title over (\(surface.title))")
                t.expect(window.title.contains("HIDDEN-LATEST"), desc: "reveal applies the latest title without more output")
                t.expect(window.title != originalTitle, desc: "reveal replaces the stale visible title")
                t.expect(
                    shell.windowTitleWeavesForTesting == originalWeaves + 1,
                    desc: "reveal coalesces the covered changes into one title weave"
                )
            }
        }
        UBUITestRegister("swift_shell_a_covered_window_draws_nothing_until_it_is_revealed") { context in
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
                window.orderFront(nil)
                quiet(surface, pumpingWith: t)
                t.expect(
                    surface.drive.readSnapshot().rows > Int32(caretParkRow),
                    desc: "the window's grid is tall enough to park the caret clear of the writes"
                )

                // (1) Covered, two writes a third of a second apart: neither
                // reaches the renderer, and the frame they asked for is still
                // owed.
                report(surface, covered: true, pumpingWith: t)
                let encodedBefore = surface.framesEncodedForTesting
                let attemptedBefore = surface.encodeAttemptCount
                write("MARKER-A", atRow: 0, to: surface)
                t.pump(0.3)
                write("MARKER-B", atRow: 1, to: surface)
                t.pump(0.3)
                // The toolkit's own pass, which a window relayout or a sibling
                // view's display runs whatever the repaint route says.
                surface.updateLayer()
                t.pump(0.1)
                t.expect(
                    surface.framesEncodedForTesting - encodedBefore,
                    equals: 0,
                    desc: "a covered pane commits no frame for two writes"
                )
                t.expect(
                    surface.encodeAttemptCount - attemptedBefore,
                    equals: 0,
                    desc: "and no pass reaches the renderer at all"
                )
                t.expect(surface.isFrameOwedForTesting, desc: "the frame the writes asked for is still owed")
                t.expect(!surface.isAnimationClockArmed, desc: "and nothing is being animated for a covered pane")

                // (2) Blinking cells are an animation, and a covered pane
                // animates nothing: the clock stands down rather than drawing
                // a blink into a drawable nobody composites.
                write("\u{1b}[5mBLINKING\u{1b}[0m", atRow: 2, to: surface)
                t.pump(1.2)
                t.expect(
                    surface.framesEncodedForTesting - encodedBefore,
                    equals: 0,
                    desc: "a blinking cell on a covered pane commits no frames"
                )
                t.expect(!surface.isAnimationClockArmed, desc: "and leaves the animation clock stopped")
                // Erased while still covered, so the reveal's frame is asked to
                // carry a row that changed twice behind the cover.
                write("\u{1b}[2K", atRow: 2, to: surface)
                t.pump(0.2)

                // (3) The reveal itself, with the window system still reporting
                // the window covered: the report lags a reveal by a frame or
                // more, and the first frame after the edge is what a reader
                // sees.
                let beforeReveal = surface.framesEncodedForTesting
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
                t.expect(
                    encodes(surface, past: beforeReveal, withinTurns: 10, pumpingWith: t),
                    desc: "the reveal draws before the window system answers"
                )
                // The frame it drew is the one the cover held: the mark those
                // writes made was kept owed across the whole cover, and this
                // is the pass that spends it.
                t.expect(
                    !surface.isFrameOwedForTesting,
                    desc: "and the frame the cover held is the one it drew"
                )
                let revealed = surface.gridTextForTesting()
                t.expect(
                    revealed.contains("MARKER-A") && revealed.contains("MARKER-B"),
                    desc: "and it drew a grid carrying both writes made behind the cover"
                )
                t.expect(
                    !revealed.contains("BLINKING"),
                    desc: "and not the line erased while it was covered"
                )

                // (4) The report lands and still says covered: the reveal is
                // settled by it, and the pane goes back to drawing nothing.
                report(surface, covered: true, pumpingWith: t)
                let beforeStillCovered = surface.framesEncodedForTesting
                write("MARKER-C", atRow: 3, to: surface)
                t.pump(0.3)
                t.expect(
                    surface.framesEncodedForTesting - beforeStillCovered,
                    equals: 0,
                    desc: "a report that still says covered puts the pane back to drawing nothing"
                )

                // (5) Uncovered for real: the write held through the cover is
                // drawn.
                let beforeUncovered = surface.framesEncodedForTesting
                surface.isFullyOccludedForTesting = false
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                t.expect(
                    encodes(surface, past: beforeUncovered, withinTurns: 10, pumpingWith: t),
                    desc: "an uncovering report draws the frame the cover held"
                )
                t.expect(
                    !surface.isFrameOwedForTesting && surface.gridTextForTesting().contains("MARKER-C"),
                    desc: "and that frame is the one the cover held, over a grid carrying the write"
                )

                // (6) A reveal nothing confirms runs out: the pane cannot draw
                // for ever on an edge the window system never answered.
                report(surface, covered: true, pumpingWith: t)
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
                t.pump(1.5)
                let beforeExpiry = surface.framesEncodedForTesting
                write("MARKER-D", atRow: 4, to: surface)
                t.pump(0.3)
                t.expect(
                    surface.framesEncodedForTesting - beforeExpiry,
                    equals: 0,
                    desc: "an unconfirmed reveal runs out and the covered pane withholds again"
                )
            }
        }

        UBUITestRegister("swift_shell_a_tab_brought_forward_draws_before_occlusion_catches_up") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.tabGroup?.windows.forEach { $0.close() } }
                guard let tabs = twoTabs(t, of: shell),
                    let behindContent = tabs.first.contentView,
                    let behind = terminalSurface(under: behindContent)
                else {
                    t.expect(false, desc: "a second tab opens in front of the first")
                    return
                }
                quiet(behind, pumpingWith: t)
                report(behind, covered: true, pumpingWith: t)
                behind.feed(Data("BEHIND-MARKER\r\n".utf8))
                t.pump(0.3)

                // The switch, with the window system still reporting the tab
                // covered: a guard on the report alone would show the layer the
                // tab stopped at, which is the stale-frame hazard this pins.
                let before = behind.framesEncodedForTesting
                tabs.first.tabGroup?.selectedWindow = tabs.first
                NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: tabs.second)
                NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: tabs.first)
                t.expect(
                    encodes(behind, past: before, withinTurns: 10, pumpingWith: t),
                    desc: "the tab brought forward draws at once, before the occlusion report arrives"
                )
                t.expect(
                    !behind.isFrameOwedForTesting && behind.gridTextForTesting().contains("BEHIND-MARKER"),
                    desc: "and draws the frame it owed, over a grid carrying what arrived while it was behind"
                )
            }
        }

        UBUITestRegister("swift_shell_every_reveal_edge_draws_at_once") { context in
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
                window.orderFront(nil)
                quiet(surface, pumpingWith: t)
                t.expect(window.isOnActiveSpace, desc: "the harness's window stands on the active space")

                let center = NotificationCenter.default
                let workspace = NSWorkspace.shared.notificationCenter
                let edges: [(name: String, post: @MainActor () -> Void)] = [
                    ("the window became key", { center.post(name: NSWindow.didBecomeKeyNotification, object: window) }),
                    ("the window became main", { center.post(name: NSWindow.didBecomeMainNotification, object: window) }),
                    ("the application activated", { center.post(name: NSApplication.didBecomeActiveNotification, object: nil) }),
                    ("the application unhid", { center.post(name: NSApplication.didUnhideNotification, object: nil) }),
                    ("the window deminiaturized", { center.post(name: NSWindow.didDeminiaturizeNotification, object: window) }),
                    ("the window changed screen", { center.post(name: NSWindow.didChangeScreenNotification, object: window) }),
                    (
                        "the active space changed",
                        { workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) }
                    ),
                    ("the screens woke", { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil) }),
                    (
                        "the login session became active",
                        { workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil) }
                    ),
                    ("a program ordered the window front", { surface.feed(Data("\u{1b}[5t".utf8)) }),
                    ("the window settled out of full screen", { surface.settleAfterFullScreenTransition() }),
                ]

                for (index, edge) in edges.enumerated() {
                    // Covered and confirmed, so each row starts from a pane
                    // that is drawing nothing.
                    report(surface, covered: true, pumpingWith: t)
                    let quietBefore = surface.framesEncodedForTesting
                    write("ROW-\(index)", atRow: index % 8, to: surface)
                    t.pump(0.2)
                    t.expect(
                        surface.framesEncodedForTesting - quietBefore,
                        equals: 0,
                        desc: "covered, the write before '\(edge.name)' draws nothing"
                    )
                    let before = surface.framesEncodedForTesting
                    edge.post()
                    t.expect(
                        encodes(surface, past: before, withinTurns: 12, pumpingWith: t),
                        desc: "\(edge.name): the pane draws at once, before the occlusion report"
                    )
                }

                // The other half: an application-wide edge says nothing about a
                // pane that is both covered and behind its group's front tab,
                // so it keeps withholding.
                guard let tabs = twoTabs(t, of: shell),
                    let behindContent = tabs.first.contentView,
                    let behind = terminalSurface(under: behindContent)
                else {
                    t.expect(false, desc: "a second tab opens in front of the first")
                    return
                }
                defer { tabs.second.close() }
                quiet(behind, pumpingWith: t)
                report(behind, covered: true, pumpingWith: t)
                let backgroundBefore = behind.framesEncodedForTesting
                let owedBefore = behind.repaintsOwedWhileWithheldForTesting
                write("BACKGROUND-MARKER", atRow: 0, to: behind)
                center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
                t.pump(0.3)
                t.expect(
                    behind.framesEncodedForTesting - backgroundBefore,
                    equals: 0,
                    desc: "an application activation draws nothing for a covered tab that is behind the front one"
                )
                t.expect(
                    behind.repaintsOwedWhileWithheldForTesting > owedBefore,
                    desc: "and the repaint it asked for is held rather than dropped"
                )
            }
        }

        // What a covered pane spends on a steady trickle of output: a line
        // every 100 ms for three seconds, with what it spent printed beside
        // what it drew.
        UBUITestRegister("swift_shell_a_covered_pane_pays_nothing_for_a_line_a_tick") { context in
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
                window.orderFront(nil)
                quiet(surface, pumpingWith: t)
                report(surface, covered: true, pumpingWith: t)

                let encodedBefore = surface.framesEncodedForTesting
                let attemptedBefore = surface.encodeAttemptCount
                let chromeBefore = shell.chromeRepaintsForTesting
                let groundBefore = shell.paneGroundPaintsForTesting
                let bakesBefore = shell.tabTitleBakesForTesting
                let writeBacksBefore = TabStripStyling.stripWriteBacksForTesting
                let searchesBefore = TabStripStyling.titlebarContainerSearchesForTesting
                let overscrollBefore = surface.overscrollLayerWritesForTesting
                for line in 0..<30 {
                    surface.feed(Data("covered line \(line)\r\n".utf8))
                    t.pump(0.1)
                }
                let encoded = surface.framesEncodedForTesting - encodedBefore
                let attempted = surface.encodeAttemptCount - attemptedBefore
                let chrome = shell.chromeRepaintsForTesting - chromeBefore
                let ground = shell.paneGroundPaintsForTesting - groundBefore
                let bakes = shell.tabTitleBakesForTesting - bakesBefore
                let writeBacks = TabStripStyling.stripWriteBacksForTesting - writeBacksBefore
                let searches = TabStripStyling.titlebarContainerSearchesForTesting - searchesBefore
                let overscroll = surface.overscrollLayerWritesForTesting - overscrollBefore
                FileHandle.standardError.write(
                    Data(
                        ("[occlusion] covered pane, 30 lines over 3s: frames=\(encoded) encodes=\(attempted) "
                            + "chromeRepaints=\(chrome) paneGroundPaints=\(ground) tabBakes=\(bakes) "
                            + "stripWriteBacks=\(writeBacks) containerSearches=\(searches) overscrollWrites=\(overscroll)\n")
                            .utf8
                    )
                )
                t.expect(encoded, equals: 0, desc: "a covered pane commits no frame for thirty lines")
                t.expect(chrome, equals: 0, desc: "and repaints no chrome")
                t.expect(ground, equals: 0, desc: "and paints no pane ground")
                t.expect(writeBacks, equals: 0, desc: "and writes no tab title back into the strip")
                t.expect(searches, equals: 0, desc: "and searches for no titlebar container")
            }
        }
    }
}
