// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// WindowOpScenarios.swift — a program moves the window it is running in.
//
// The CSI t family reaches a frontend through `WindowClient`, which this arm
// cannot install. Core queues the calls instead and the window controller
// drains them on the event. The queue's own contract is pinned headless by
// test_window_request_queue; what only a running app can answer is whether a
// window actually moved, and whether it moved to where the program asked.
//
// Driven by feeding the escape to the surface, which is the path a program's
// bytes take. The assertions are about the window itself: a port that queued
// correctly and performed nothing would pass every headless case.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let found = view as? TerminalSurface {
        return found
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Feeds an escape and lets the drain carry it to the window.
///
/// - Parameters:
///   - escape: The bytes a program would write.
///   - surface: The surface to feed.
///   - t: The running scenario, for pumping.
@MainActor
private func write(_ escape: String, to surface: TerminalSurface, pumpingWith t: UBUITestContext) {
    surface.feed(Data(escape.utf8))
    t.pump(0.35)
}

/// The defaults key both shells persist the window frame through — see
/// WindowFrameMemory.
private let windowFrameDefaultsKey = "UbiquittyWindowFrame"

/// Registers the window-operation scenarios with the UI-test runner.
enum WindowOpScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // Zoom to the screen needs real display coordinates.
        // Run these scenarios with Scripts/run-ui-tests.sh --visible.
        if MainActor.assumeIsolated({ !WindowContainment.isOffscreen }) {
            // Zoom is AppKit's standard zoom. A drag-resize of a zoomed window
            // is the person taking the size: it leaves the zoomed state, a
            // move keeps it, and the next zoom zooms from it and restores to it.
            UBUITestRegister("zoom_yields_to_a_drag_resize") { context in
                guard let t = context else { return }
                MainActor.assumeIsolated {
                    guard let shell = TerminalWindowController.spawn(), let window = shell.window as? ZoomTrackingWindow,
                        let screen = window.screen ?? NSScreen.main
                    else {
                        t.expect(false, desc: "a zoom-tracking terminal window opens on a screen")
                        return
                    }
                    defer { window.close() }
                    @MainActor
                    func settled() -> Bool { !window.inLiveResize && !window.isZoomResizeInProgress }
                    window.orderBack(nil)
                    let visible = screen.visibleFrame
                    let untiled = NSRect(x: visible.minX + 120, y: visible.minY + 160, width: 640, height: 400)
                    window.setFrame(untiled, display: true)
                    t.pump(0.3)
                    t.expect(!window.isZoomed, desc: "the opening window is not zoomed (\(window.frame))")
                    window.performZoom(nil)
                    t.expect(
                        t.wait(until: { window.isZoomed && settled() }, timeout: 3),
                        desc: "zoom zooms the window to its standard frame (\(window.frame))"
                    )
                    t.pump(0.3)
                    let zoomed = window.frame
                    t.expect(zoomed.width > untiled.width + 100, desc: "zoom grows the window (\(zoomed))")

                    // A drag of the bottom-right corner, top-left corner
                    // still. WindowServer runs the drag itself and synthesized
                    // events do not reach it, so the scenario opens and
                    // closes AppKit's live resize as the drag does, which
                    // posts its edges.
                    let startLiveResize = NSSelectorFromString("_startLiveResize")
                    let endLiveResize = NSSelectorFromString("_endLiveResize")
                    guard window.responds(to: startLiveResize), window.responds(to: endLiveResize) else {
                        t.expect(false, desc: "AppKit's live resize can be opened")
                        return
                    }
                    window.perform(startLiveResize)
                    shell.beginLiveResize(pressedAt: NSPoint(x: zoomed.maxX, y: zoomed.minY))
                    t.expect(!window.isZoomResizeInProgress, desc: "a drag after a zoom is not the zoom's resize")
                    for share in [0.25, 0.5, 0.75, 1.0] {
                        let proposed = NSSize(
                            width: (zoomed.width - (zoomed.width - 820) * share).rounded(),
                            height: (zoomed.height - (zoomed.height - 520) * share).rounded()
                        )
                        let size = shell.snappedFrameSize(for: window, proposed: proposed, isLiveResize: true)
                        window.setFrame(
                            NSRect(x: zoomed.minX, y: zoomed.maxY - size.height, width: size.width, height: size.height),
                            display: true
                        )
                        t.pump(0.05)
                    }
                    let draggedTo = window.frame
                    window.perform(endLiveResize)
                    t.pump(1.0)
                    let dragged = window.frame
                    t.expect(dragged.width < zoomed.width - 100, desc: "the drag shrank the window (\(dragged))")
                    t.expect(
                        dragged.size == draggedTo.size,
                        desc: "the drag's size stands once it ends (\(dragged.size), dragged to \(draggedTo.size))"
                    )
                    t.expect(!window.isZoomed, desc: "a drag-resize leaves the zoomed state")

                    // WindowServer runs a title-bar drag too; this move is
                    // AppKit's half of one.
                    window.setFrameOrigin(NSPoint(x: dragged.minX + 80, y: dragged.minY - 40))
                    shell.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
                    t.pump(1.0)
                    let moved = window.frame
                    t.expect(moved.size == dragged.size, desc: "a move keeps the dragged size (\(moved.size), dragged \(dragged.size))")
                    t.expect(!window.isZoomed, desc: "a moved window is still not zoomed")

                    window.performZoom(nil)
                    t.expect(
                        t.wait(until: { window.isZoomed && settled() && window.frame == zoomed }, timeout: 3),
                        desc: "zoom after a drag-resize zooms to the standard frame (\(window.frame), zoomed \(zoomed))"
                    )
                    t.pump(0.3)
                    window.performZoom(nil)
                    t.expect(
                        t.wait(until: { !window.isZoomed && settled() }, timeout: 3),
                        desc: "the second zoom unzooms"
                    )
                    t.pump(0.3)
                    t.expect(
                        abs(window.frame.width - moved.width) < 2 && abs(window.frame.height - moved.height) < 2
                            && abs(window.frame.minX - moved.minX) < 2 && abs(window.frame.minY - moved.minY) < 2,
                        desc: "unzoom restores the dragged and moved frame (\(window.frame), moved \(moved))"
                    )
                }
            }

            // A tab group shares one frame, and every tab reads the zoom that
            // frame is in.
            UBUITestRegister("zoom_holds_across_tab_selection") { context in
                guard let t = context else { return }
                MainActor.assumeIsolated {
                    guard let shell = TerminalWindowController.spawn(), let first = shell.window,
                        let screen = first.screen ?? NSScreen.main
                    else {
                        t.expect(false, desc: "a terminal window opens on a screen")
                        return
                    }
                    defer {
                        for window in first.tabGroup?.windows ?? [first] { window.close() }
                    }
                    first.orderBack(nil)
                    let visible = screen.visibleFrame
                    first.setFrame(NSRect(x: visible.minX + 120, y: visible.minY + 160, width: 750, height: 500), display: true)
                    t.pump(0.3)
                    first.performZoom(nil)
                    t.expect(t.wait(until: { first.isZoomed && !first.inLiveResize }, timeout: 3), desc: "zoom zooms the first tab")
                    t.pump(0.3)
                    let zoomed = first.frame
                    shell.newWindowForTab(nil)
                    t.pump(0.5)
                    guard let group = first.tabGroup, let second = group.windows.first(where: { $0 !== first }) else {
                        t.expect(false, desc: "a second tab opens")
                        return
                    }
                    group.selectedWindow = second
                    t.pump(0.5)
                    t.expect(
                        second.isZoomed && second.frame == zoomed,
                        desc: "a new tab reads zoomed at the zoomed frame (\(second.frame), zoomed \(zoomed))"
                    )
                    group.selectedWindow = first
                    t.pump(0.5)
                    t.expect(
                        first.isZoomed && first.frame == zoomed,
                        desc: "switching back keeps the first tab zoomed at the zoomed frame (\(first.frame))"
                    )
                    group.selectedWindow = second
                    group.selectedWindow = first
                    group.selectedWindow = second
                    t.pump(0.5)
                    for (index, window) in group.windows.enumerated() {
                        t.expect(
                            window.isZoomed && window.frame == zoomed,
                            desc: "after rapid switches tab \(index + 1) reads zoomed at the zoomed frame (\(window.frame))"
                        )
                    }
                }
            }
        }
        UBUITestRegister("swift_shell_new_tab_keeps_the_host_window_frame") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let host = shell.window else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer {
                    for window in host.tabGroup?.windows ?? [host] { window.close() }
                }
                host.makeKeyAndOrderFront(nil)
                // The host stands where the reader put it, and the remembered
                // frame — where the next window would open — is somewhere
                // else: a new tab joins the host, not the memory.
                host.setFrame(NSRect(x: 140, y: 120, width: 1040, height: 620), display: true)
                t.pump(0.3)
                let defaults = UserDefaults.standard
                // A remembered frame wider than the screen: the newcomer is
                // placed constrained to the screen it opens on, and that is
                // the frame a group has been seen to settle on. Offscreen,
                // AppKit keeps the host's frame either way, so this scenario
                // holds the invariant rather than provoking the failure; the
                // failure needs a real screen to constrain against.
                let screen = host.screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
                defaults.set(
                    NSStringFromRect(NSRect(x: screen.minX - 1, y: screen.minY, width: screen.width + 1, height: screen.height - 33)),
                    forKey: windowFrameDefaultsKey
                )
                let before = host.frame
                shell.newWindowForTab(nil)
                t.pump(0.5)
                guard let group = host.tabGroup, let tab = group.windows.first(where: { $0 !== host }) else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                // The strip appearing may grow the group by its own height;
                // the width and the left edge are the host's, and the tab
                // shares whatever the group settled on.
                t.expect(
                    abs(host.frame.width - before.width) < 1 && abs(host.frame.minX - before.minX) < 1,
                    desc: "the host keeps its width and left edge: got \(host.frame), had \(before)"
                )
                t.expect(
                    host.frame.height >= before.height - 1,
                    desc: "the host does not shrink for the newcomer: got \(host.frame), had \(before)"
                )
                t.expect(
                    abs(tab.frame.width - host.frame.width) < 1 && abs(tab.frame.minX - host.frame.minX) < 1,
                    desc: "the new tab shares the host's frame: tab \(tab.frame), host \(host.frame)"
                )
            }
        }
        UBUITestRegister("swift_shell_native_window_edges_publish_geometry") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift window has a terminal")
                    return
                }
                defer {
                    window.deminiaturize(nil)
                    window.close()
                }
                t.pump(0.3)
                surface.drive.stopIngest()
                var frame = window.frame
                frame.origin.y -= 37
                window.setFrame(frame, display: true)
                t.pump(0.2)
                let expectedY = Int32(
                    max(0, ((window.screen ?? NSScreen.main)?.frame.height ?? window.frame.height) - window.frame.maxY).rounded()
                )
                surface.drive.withTerminal { terminal in
                    t.expect(terminal.winPosY == expectedY, desc: "a native move publishes the top-left position")
                    t.expect(
                        terminal.screenPixelWidth > 0 && terminal.screenPixelHeight > 0,
                        desc: "the display's available pixel size is published"
                    )
                }
                window.miniaturize(nil)
                t.pump(0.3)
                t.expect(
                    surface.drive.withTerminal { $0.windowIconified } == true,
                    desc: "native minimization publishes the iconified state"
                )
                surface.feed(Data("\u{1b}c".utf8))
                t.expect(surface.drive.withTerminal { $0.windowIconified } == true, desc: "RIS preserves the native iconified state")
                window.deminiaturize(nil)
                t.pump(0.3)
                t.expect(surface.drive.withTerminal { $0.windowIconified } == false, desc: "native restoration clears the iconified state")
            }
        }
        UBUITestRegister("swift_shell_a_program_moves_and_sizes_its_window") { context in
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
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                // CSI 3 t: move. The program's origin is top-left and y-down,
                // so the assertion converts the same way the port does — a case
                // asserting the raw y would pass on a port that never flipped.
                let screenHeight = (window.screen ?? NSScreen.main)?.frame.height ?? 0
                write("\u{1b}[3;140;90t", to: surface, pumpingWith: t)
                let moved = window.frame
                let requested = NSRect(x: 140, y: screenHeight - 90 - moved.height, width: moved.width, height: moved.height)
                let expected = WindowContainment.parkedFrame(requested)
                t.expect(
                    abs(moved.origin.x - expected.origin.x) < 2,
                    desc: "CSI 3 t moved the window to the x it named (\(moved.origin.x))"
                )
                t.expect(
                    abs(moved.origin.y - (screenHeight - 90 - moved.height)) < 2,
                    desc: "and to the y it named, flipped from the top-left origin (\(moved.origin.y))"
                )
                t.expect(
                    !WindowContainment.isOffscreen || !NSScreen.screens.contains(where: { $0.frame.intersects(moved) }),
                    desc: "the requested move stays physically outside every display"
                )

                // CSI 8 t: the grid, in cells. The window follows the counts.
                write("\u{1b}[8;20;60t", to: surface, pumpingWith: t)
                let snapshot = surface.drive.readSnapshot()
                t.expect(
                    snapshot.rows == 20 && snapshot.columns == 60,
                    desc: "CSI 8 t resized the grid to the cells it named (\(snapshot.rows)x\(snapshot.columns))"
                )

                // CSI 9 ; 1 t then CSI 9 ; 0 t: maximize and restore. The
                // restore is what says the frame was kept rather than
                // recomputed — a port that recomputed would land on a size that
                // merely looks plausible.
                let beforeMaximize = window.frame
                write("\u{1b}[9;1t", to: surface, pumpingWith: t)
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                t.expect(
                    abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2,
                    desc: "CSI 9 ; 1 t filled the screen's visible frame (\(window.frame.size))"
                )
                t.expect(
                    !WindowContainment.isOffscreen || !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
                    desc: "maximizing preserves offscreen containment"
                )
                write("\u{1b}[9;0t", to: surface, pumpingWith: t)
                t.expect(
                    abs(window.frame.width - beforeMaximize.width) < 2
                        && abs(window.frame.height - beforeMaximize.height) < 2,
                    desc: "and CSI 9 ; 0 t put back the frame it grew from (\(window.frame.size))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_program_iconifies_and_core_reads_it_back") { context in
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
                defer {
                    window.deminiaturize(nil)
                    window.close()
                }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                // The flag is latched when the request arrives, ahead of the
                // animation. What that buys is a CSI 11 t behind it reading where the
                // window is going; asserting only `isMiniaturized` would pass
                // on a port that latched nothing, since AppKit sets that itself.
                write("\u{1b}[2t", to: surface, pumpingWith: t)
                let iconified = surface.drive.withTerminal { $0.windowIconified } ?? false
                t.expect(iconified, desc: "CSI 2 t latched Core's iconified flag on the request")

                write("\u{1b}[1t", to: surface, pumpingWith: t)
                let restored = surface.drive.withTerminal { $0.windowIconified } ?? true
                t.expect(!restored, desc: "and CSI 1 t cleared it the same way")
            }
        }

        UBUITestRegister("swift_shell_a_program_fills_the_screen_in_place") { context in
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
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                // The non-native path: fill the visible frame in place, with no
                // Space change and no animation, so a geometry request behind
                // it lands instead of racing one.
                guard
                    !Ubiquitty.Preferences.Effective.programFullscreenUsesNative(
                        Ubiquitty.Preferences.values().pointee
                    )
                else {
                    t.expect(false, desc: "this case is about the in-place fill; the config asks for native")
                    return
                }
                let before = window.frame
                write("\u{1b}[10;1t", to: surface, pumpingWith: t)
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                t.expect(
                    abs(window.frame.height - visible.height) < 2,
                    desc: "CSI 10 ; 1 t filled the screen (\(window.frame.size))"
                )
                t.expect(
                    !WindowContainment.isOffscreen || !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
                    desc: "in-place screen fill preserves offscreen containment"
                )
                // In place, not through the system transition: a window that
                // went native would carry the style mask and lose its title bar.
                t.expect(
                    !window.styleMask.contains(.fullScreen),
                    desc: "and did it without entering the system's full screen"
                )
                write("\u{1b}[10;0t", to: surface, pumpingWith: t)
                t.expect(
                    abs(window.frame.height - before.height) < 2,
                    desc: "and CSI 10 ; 0 t put the window back (\(window.frame.size))"
                )
            }
        }
    }
}
