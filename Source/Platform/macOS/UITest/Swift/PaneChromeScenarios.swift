// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit
import UbiquittyRenderKit

// PaneChromeScenarios.swift — the geometry of a pane's title bar.
//
// The bar is shared by both shells, so its metrics are the one thing that can
// silently drift between them: a gutter changed for one arm is a split that
// reads differently depending on which shell opened it. Every number below is
// asserted against the layout rather than described, because the layout is
// arithmetic over a frame and arithmetic is exactly what a reader cannot check
// by looking at a screenshot.
//
// No window is needed. The bar lays out against its own bounds, so a frame is
// the whole input — which is also why these run without a key window, something
// the UI-test app never has.

/// Registers the pane-chrome geometry scenarios with the UI-test runner.
@objc(UBPaneChromeScenarios)
public final class PaneChromeScenarios: NSObject {
    /// A subview carrying an accessibility identifier, found anywhere beneath a
    /// root. The bar owns its parts privately, so identity is how a test reaches
    /// them without widening the component's surface for the test's benefit.
    @MainActor
    private static func view(_ identifier: String, under root: NSView) -> NSView? {
        for subview in root.subviews {
            if subview.accessibilityIdentifier() == identifier {
                return subview
            }
            if let found = view(identifier, under: subview) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private static func chrome(width: CGFloat, height: CGFloat) -> PaneChrome {
        let built = PaneChrome(
            paneID: 7,
            target: nil,
            closeAction: #selector(NSView.removeFromSuperview),
            expandAction: #selector(NSView.removeFromSuperview)
        )
        built.contentView = NSView(frame: .zero)
        built.setFrameSize(NSSize(width: width, height: height))
        return built
    }

    /// Registers every scenario in this file.
    @objc
    public static func register() {
        UBUITestRegister("swift_shell_glass_pane_headers_share_the_window_backdrop") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                let saved = t.configureAppending("[appearance]\nbackground_opacity = 0.0\nblur_radius = 20.0\n")
                defer { t.restoreConfiguration(saved) }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift window opens")
                    return
                }
                defer { window.close() }
                shell.splitRight(nil)
                t.pump(0.3)
                var bars: [NSView] = []
                @MainActor
                func collect(_ root: NSView) {
                    if root.accessibilityIdentifier() == "pane.titleBar" { bars.append(root) }
                    root.subviews.forEach(collect)
                }
                collect(shell.paneHost)
                t.expect(bars.count == 2, desc: "both split panes have a header")
                for theme in ["Glass Dark", "Glass"] {
                    shell.applyColorPreset(named: theme)
                    t.expect(
                        shell.paneHost.blendingMode == .behindWindow && shell.paneHost.maskImage == nil,
                        desc: "the window supplies the glass backdrop"
                    )
                    for bar in bars {
                        t.expect(bar.layer?.backgroundColor?.alpha == 0, desc: "a glass pane header has no opaque fill")
                        t.expect(
                            !bar.subviews.contains { $0 is NSVisualEffectView },
                            desc: "the header does not add a second material over the window's glass"
                        )
                    }
                }
            }
        }

        UBUITestRegister("swift_shell_pane_presence_follows_its_roster") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let first = chrome(width: 300, height: 200)
                let second = chrome(width: 300, height: 200)
                let contentFrame = first.contentView?.frame
                let attendee = RuntimeDrive.Attendee(
                    attachmentID: "00000000000000010000000000000002",
                    clientID: 2,
                    isHuman: false,
                    isQUIC: false,
                    isSelf: false,
                    grantScope: 0,
                    process: "",
                    grantIdentity: "agent-key",
                    label: "screen-reader"
                )
                first.updatePresence([attendee])
                second.updatePresence([])
                t.expect(!first.presenceIndicator.isHidden, desc: "an observed pane has a presence button")
                t.expect(second.presenceIndicator.isHidden, desc: "another pane does not borrow its roster")
                t.expect(first.contentView?.frame == contentFrame, desc: "presence takes no terminal space")
                guard let title = view("pane.title", under: first) else {
                    t.expect(false, desc: "the pane has a title")
                    return
                }
                let badge = first.presenceIndicator
                t.expect(badge.frame.width > 0 && badge.frame.maxX < first.bounds.width, desc: "the badge fits inside its pane")
                t.expect(title.frame.maxX < badge.frame.minX, desc: "a long title cannot cover the presence button")
                t.expect(badge.frame.maxX < first.statusMark.frame.minX, desc: "presence and the status mark have separate slots")
                let point = badge.convert(NSPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: first)
                t.expect(!first.isTransferHandle(at: point), desc: "the presence button opens its menu instead of dragging the pane")
                var revoked: String?
                badge.revoke = { _, attachmentID, _ in revoked = attachmentID }
                let menu = badge.rosterMenu()
                let action = menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Disconnect Now" }
                if let action, let selector = action.action {
                    NSApp.sendAction(selector, to: action.target, from: action)
                }
                t.expect(revoked == attendee.attachmentID, desc: "the pane menu revokes the attachment it shows")
                first.updatePresence([])
                t.expect(badge.isHidden, desc: "a detached observer leaves no stale button")
            }
        }

        UBUITestRegister("swift_shell_screen_access_stays_amber_until_reviewed") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let first = chrome(width: 320, height: 200)
                let second = chrome(width: 320, height: 200)
                let read = RuntimeDrive.ScreenAccess(
                    cursor: 10,
                    unixMilliseconds: 1_798_999_200_000,
                    claimedLabel: "screen-reader",
                    verifiedProcess: ""
                )
                first.updatePresence([], screenAccesses: [read], hasUnread: true)
                second.updatePresence([])
                let badge = first.presenceIndicator
                t.expect(!badge.isHidden && badge.isEnabled, desc: "unreviewed access stays actionable after its reader leaves")
                t.expect(badge.contentTintColor == .systemOrange, desc: "unreviewed screen access is amber")
                t.expect(second.presenceIndicator.isHidden, desc: "an unread access does not mark another pane")
                var acknowledged: UInt64?
                badge.acknowledgeScreenAccess = { acknowledged = $0 }
                let menu = badge.rosterMenu()
                t.expect(acknowledged == nil, desc: "building a menu does not claim the user opened it")
                t.expect(
                    menu.items.contains { $0.title.contains("screen-reader (claimed name)") },
                    desc: "activity identifies the claimed reader and time"
                )
                let later = RuntimeDrive.ScreenAccess(
                    cursor: 11,
                    unixMilliseconds: read.unixMilliseconds + 1,
                    claimedLabel: "later reader",
                    verifiedProcess: ""
                )
                first.updatePresence([], screenAccesses: [read, later], hasUnread: true)
                menu.delegate?.menuWillOpen?(menu)
                t.expect(acknowledged == 10, desc: "opening the earlier list reviews only the records it displayed")
                t.expect(badge.contentTintColor == .systemOrange, desc: "the newer access remains amber")
                let newest = badge.rosterMenu()
                newest.delegate?.menuWillOpen?(newest)
                t.expect(acknowledged == 11, desc: "opening the current list reviews the newest read")
                acknowledged = nil
                let applicationMenu = badge.rosterMenu(activitySubmenu: true)
                applicationMenu.delegate?.menuWillOpen?(applicationMenu)
                t.expect(acknowledged == nil, desc: "the Session menu alone does not open its activity submenu")
                if let activity = applicationMenu.items.first?.submenu {
                    activity.delegate?.menuWillOpen?(activity)
                }
                t.expect(acknowledged == 11, desc: "the Session menu's activity submenu reviews its displayed history")
                first.updatePresence([], screenAccesses: [read, later], hasUnread: false)
                t.expect(badge.isHidden, desc: "a reviewed history without a live reader no longer shows a badge")
                t.expect(
                    badge.rosterMenu().items.contains { $0.title.contains("later reader") },
                    desc: "reviewing preserves the activity history"
                )
            }
        }

        UBUITestRegister("swift_shell_theme_changes_restyle_every_pane_header") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift window opens")
                    return
                }
                defer { window.close() }
                t.expect(window.tabbingMode == .automatic, desc: "new windows honor the system tabbing preference")
                shell.splitRight(nil)
                t.pump(0.3)
                var bars: [NSView] = []
                @MainActor
                func collect(_ root: NSView) {
                    if let surface = root as? TerminalSurface {
                        surface.drive.stopIngest()
                    }
                    if root.accessibilityIdentifier() == "pane.titleBar" {
                        bars.append(root)
                    }
                    root.subviews.forEach(collect)
                }
                collect(shell.paneHost)
                t.expect(bars.count == 2, desc: "both split panes have a header")
                shell.applyColorPreset(named: "Noir Clair")
                let light = bars.map { $0.layer?.backgroundColor }
                t.expect(
                    light.allSatisfy { color in
                        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return false }
                        return rgb.redComponent > 0.8
                    },
                    desc: "a theme-only change paints both headers with the light background"
                )
                shell.applyColorPreset(named: "Noir")
                t.expect(
                    bars.allSatisfy { bar in
                        guard let color = bar.layer?.backgroundColor,
                            let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB)
                        else { return false }
                        return rgb.redComponent < 0.3
                    },
                    desc: "both headers switch back without requiring terminal output or a title change"
                )
            }
        }

        UBUITestRegister("pane_chrome_lays_its_bar_out_against_the_ported_metrics") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let box = chrome(width: 400, height: 200)
                guard let bar = view("pane.titleBar", under: box),
                    let close = view("pane.close", under: box),
                    let expand = view("pane.expand", under: box),
                    let title = view("pane.title", under: box)
                else {
                    t.expect(false, desc: "the bar, both buttons and the title are all present")
                    return
                }

                // Non-flipped: the bar pins to the top, the pane's view below it.
                t.expect(
                    bar.frame == NSRect(x: 0, y: 172, width: 400, height: 28),
                    desc: "the bar is 28pt tall and pinned to the top edge"
                )
                t.expect(
                    box.contentView?.frame == NSRect(x: 0, y: 0, width: 400, height: 172),
                    desc: "the pane's own view takes everything below the bar"
                )

                // 16pt buttons centred in a 28pt bar, 4pt from the edge and 4pt
                // apart. A drift here is the whole reason this scenario exists.
                t.expect(
                    close.frame == NSRect(x: 4, y: 6, width: 16, height: 16),
                    desc: "close sits 4pt in, vertically centred"
                )
                t.expect(
                    expand.frame == NSRect(x: 24, y: 6, width: 16, height: 16),
                    desc: "expand follows close by a 4pt gap"
                )

                // The title is inset by the button gutter on each side, so
                // centring it puts it mid-bar rather than centred over the
                // buttons: 4 + 16 + 4 + 16 + 6 + 4 = 50.
                t.expect(
                    title.frame == NSRect(x: 50, y: 6, width: 300, height: 16),
                    desc: "the title clears the buttons and is symmetrically inset"
                )
            }
        }

        UBUITestRegister("pane_chrome_reclaims_the_slot_of_a_button_it_does_not_offer") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A tmux pane has no local zoom, so it offers no expand button
                // and the title gutter tightens by that button and its gap.
                let box = chrome(width: 400, height: 200)
                box.showsExpandButton = false
                guard let expand = view("pane.expand", under: box), let title = view("pane.title", under: box) else {
                    t.expect(false, desc: "the bar still owns both parts")
                    return
                }
                t.expect(expand.frame == .zero, desc: "a button that is not offered takes no space")
                // 4 + 16 + 4 + 4 = 28, and the width loses that inset twice.
                t.expect(
                    title.frame == NSRect(x: 28, y: 6, width: 344, height: 16),
                    desc: "the title reclaims the slot rather than leaving a hole"
                )
            }
        }

        UBUITestRegister("pane_chrome_without_a_bar_gives_the_whole_pane_to_the_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let box = chrome(width: 400, height: 200)
                box.showsTitleBar = false
                guard let bar = view("pane.titleBar", under: box) else {
                    t.expect(false, desc: "the bar is still owned, just not shown")
                    return
                }
                t.expect(bar.isHidden, desc: "the bar is hidden rather than merely empty")
                t.expect(
                    box.contentView?.frame == NSRect(x: 0, y: 0, width: 400, height: 200),
                    desc: "the pane's view takes the whole container when no bar is shown"
                )
            }
        }

        UBUITestRegister("pane_chrome_keeps_a_bar_a_short_pane_can_hold") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A pane dragged shorter than the bar keeps a bar clipped to
                // what it has: a bar taller than its pane would push the grid to
                // a negative height.
                let box = chrome(width: 400, height: 20)
                guard let bar = view("pane.titleBar", under: box) else {
                    t.expect(false, desc: "the bar is present")
                    return
                }
                t.expect(
                    bar.frame == NSRect(x: 0, y: 0, width: 400, height: 20),
                    desc: "the bar clips to the pane rather than exceeding it"
                )
                t.expect(
                    box.contentView?.frame.height == 0,
                    desc: "the grid takes no negative height"
                )
            }
        }

        UBUITestRegister("swift_shell_zoomed_pane_keeps_its_header_and_tells_its_program") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let directory = "/tmp/ubq-zoom-" + String(UUID().uuidString.prefix(8))
                defer { try? FileManager.default.removeItem(atPath: directory) }
                guard let reporter = PaneZoomCheck.installReporter(in: directory),
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec python3 '\(reporter)'"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift window opens on the size reporter")
                    return
                }
                defer { window.close() }
                shell.splitRight(nil)
                guard
                    t.wait(until: { shell.focusedSurfaceForTesting.map { $0 !== surface } ?? false }, timeout: 5),
                    let sibling = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "the split opens a second pane beside the reporter")
                    return
                }
                PaneZoomCheck.verifyZoomByHeader(
                    t,
                    in: shell,
                    pane: surface,
                    beside: sibling,
                    isZoomed: { sibling.window == nil }
                )
            }
        }
    }
}

/// A zoom driven from a pane's own header, checked the same way for a local
/// window and a hosted one: what the reader sees, and what the pane's program
/// is told.
enum PaneZoomCheck {
    /// A program that prints its terminal's size as it starts and again on
    /// every SIGWINCH, each line numbered by the signals it has had.
    ///
    /// The size it prints is the PTY's, read with `TIOCGWINSZ` where the
    /// program runs: for a hosted pane that is the host's answer, which
    /// neither the view nor the replica can stand in for.
    private static let reporterSource = """
        import fcntl, signal, struct, sys, termios, time
        signals = 0
        def report(signum=None, frame=None):
            global signals
            if signum is not None:
                signals += 1
            rows, columns = struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\\0" * 8))[:2]
            sys.stdout.write("winsize %d %d %d\\n" % (signals, rows, columns))
            sys.stdout.flush()
        signal.signal(signal.SIGWINCH, report)
        report()
        while True:
            time.sleep(1)
        """

    /// One line the reporter printed.
    struct Report: Equatable {
        /// How many SIGWINCHs the program had had when it printed the line.
        var signals: Int
        var rows: Int
        var columns: Int
    }

    /// Writes the reporter into a directory, making the directory first.
    ///
    /// - Parameter directory: A directory of the scenario's own.
    /// - Returns: The program's path, or nil when it could not be written.
    static func installReporter(in directory: String) -> String? {
        let path = directory + "/winsize-reporter.py"
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(reporterSource.utf8).write(to: URL(fileURLWithPath: path))
        } catch {
            return nil
        }
        return path
    }

    /// The last line the reporter left on a pane's screen.
    ///
    /// - Parameter surface: The pane running the reporter.
    /// - Returns: The line, or nil before the program printed one.
    @MainActor
    static func lastReport(in surface: TerminalSurface) -> Report? {
        let line = surface.gridTextForTesting().split(separator: "\n").last { $0.hasPrefix("winsize ") }
        let fields = line.map { $0.split(separator: " ").dropFirst().compactMap { Int($0) } } ?? []
        guard fields.count == 3 else { return nil }
        return Report(signals: fields[0], rows: fields[1], columns: fields[2])
    }

    /// The bar over a pane, while it is shown in the pane's window.
    @MainActor
    private static func visibleHeader(of surface: TerminalSurface) -> PaneChrome? {
        guard let chrome = surface.superview as? PaneChrome, chrome.showsTitleBar,
            let window = surface.window, chrome.window === window,
            let bar = descendant("pane.titleBar", of: chrome), !bar.isHiddenOrHasHiddenAncestor, bar.frame.height > 0
        else { return nil }
        return chrome
    }

    /// The expand-or-contract button in a pane's visible bar.
    @MainActor
    private static func zoomControl(of surface: TerminalSurface) -> NSButton? {
        guard let chrome = visibleHeader(of: surface),
            let button = descendant("pane.expand", of: chrome) as? NSButton,
            !button.isHiddenOrHasHiddenAncestor, button.frame.width > 0
        else { return nil }
        return button
    }

    @MainActor
    private static func descendant(_ identifier: String, of root: NSView) -> NSView? {
        for subview in root.subviews {
            if subview.accessibilityIdentifier() == identifier {
                return subview
            }
            if let found = descendant(identifier, of: subview) {
                return found
            }
        }
        return nil
    }

    /// Zooms a split pane by its header's expand button and takes the zoom
    /// back by the same button.
    ///
    /// The zoomed pane keeps its header with the button turned to contract,
    /// so the zoom is undone where it was asked for. Each change of the
    /// pane's grid reaches its program as a SIGWINCH naming the grid the
    /// pane is drawn at, for the zoom and for the split it returns to.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The window holding both panes.
    ///   - surface: The pane to zoom; it runs the reporter.
    ///   - sibling: The pane beside it.
    ///   - isZoomed: Whether the window's authority holds `surface` zoomed.
    @MainActor
    static func verifyZoomByHeader(
        _ t: UBUITestContext,
        in controller: TerminalWindowController,
        pane surface: TerminalSurface,
        beside sibling: TerminalSurface,
        isZoomed: () -> Bool
    ) {
        // The grid the pane is drawn at, which this side states; and the grid
        // its terminal holds, which for a hosted pane is the host's.
        let grid = { surface.publishedGrid }
        let held = {
            let snapshot = surface.drive.readSnapshot()
            return (rows: Int(snapshot.rows), columns: Int(snapshot.columns))
        }
        func isReporting(_ report: Report?, after signals: Int, grid expected: (rows: Int, columns: Int)) -> Bool {
            guard let report else { return false }
            return report.signals > signals && report.rows == expected.rows && report.columns == expected.columns
        }
        let hasSplitReport = t.wait(
            until: {
                guard let report = lastReport(in: surface) else { return false }
                return report.rows == grid().rows && report.columns == grid().columns && held() == grid()
                    && sibling.window === surface.window
            },
            timeout: 20
        )
        let splitGrid = grid()
        t.expect(
            hasSplitReport,
            desc:
                "the split pane's program reads the grid it is drawn at "
                + "(\(String(describing: lastReport(in: surface))) for \(splitGrid.rows)x\(splitGrid.columns))"
        )
        guard hasSplitReport, let split = lastReport(in: surface), let expand = zoomControl(of: surface) else {
            t.expect(false, desc: "the split pane's header offers its expand button")
            return
        }
        expand.performClick(nil)
        t.expect(
            t.wait(until: { isZoomed() && surface.superview?.superview === controller.paneHost && sibling.window == nil }, timeout: 10),
            desc: "the header's expand button fills the window with its pane"
        )
        t.expect(
            visibleHeader(of: surface) != nil,
            desc: "the zoomed pane keeps its header (its superview is \(String(describing: surface.superview)))"
        )
        let contract = zoomControl(of: surface)
        t.expect(
            contract?.toolTip == "Contract pane",
            desc: "the zoomed pane's header offers the contract button (\(String(describing: contract?.toolTip)))"
        )
        let isZoomReported = t.wait(
            until: {
                grid().columns > splitGrid.columns && isReporting(lastReport(in: surface), after: split.signals, grid: grid())
                    && held() == grid()
            },
            timeout: 10
        )
        let zoomedGrid = grid()
        t.expect(
            isZoomReported,
            desc:
                "the zoomed pane's program is told the zoomed grid by a SIGWINCH "
                + "(\(String(describing: lastReport(in: surface))) for \(zoomedGrid.rows)x\(zoomedGrid.columns), "
                + "split \(splitGrid.rows)x\(splitGrid.columns); the pane is \(surface.frame.size) "
                + "in a header of \(surface.superview?.frame.size ?? .zero), the window's panes \(controller.paneHost.bounds.size))"
        )
        t.expect(
            held() == zoomedGrid,
            desc:
                "the zoomed pane's terminal holds the zoomed grid (\(held().rows)x\(held().columns) for \(zoomedGrid.rows)x\(zoomedGrid.columns))"
        )
        guard let contract else {
            t.expect(false, desc: "the zoomed pane's contract button takes the zoom back")
            return
        }
        let zoomed = lastReport(in: surface) ?? split
        contract.performClick(nil)
        t.expect(
            t.wait(until: { !isZoomed() && visibleHeader(of: surface) != nil && visibleHeader(of: sibling) != nil }, timeout: 10),
            desc: "the contract button restores the split with both headers"
        )
        t.expect(
            zoomControl(of: surface)?.toolTip == "Expand pane",
            desc: "the restored pane offers its expand button again"
        )
        let isSplitReported = t.wait(
            until: {
                grid() == splitGrid && isReporting(lastReport(in: surface), after: zoomed.signals, grid: splitGrid) && held() == splitGrid
            },
            timeout: 10
        )
        t.expect(
            isSplitReported,
            desc:
                "the unzoomed pane's program is told the split grid again "
                + "(\(String(describing: lastReport(in: surface))) for \(grid().rows)x\(grid().columns), "
                + "split \(splitGrid.rows)x\(splitGrid.columns))"
        )
        t.expect(
            held() == splitGrid,
            desc: "the unzoomed pane's terminal holds the split grid again (\(held().rows)x\(held().columns))"
        )
    }
}
