// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// TitleDimensionsScenarios.swift — the columns×rows a window title ends with
// follows the grid, on both shells, with no output to carry it.
//
// A title poll delivers a MOVED process sample, and a resize under one
// program moves none, so the readout cannot ride the poll. Each window
// re-weaves the title where its grid moves. A readout driven only by a
// per-drain title refresh tracks a drag only while output flows, and a resize
// with a quiet program stands at the size the drag began at until the settle. Both
// scenarios below resize with nothing writing to the pane, so only the resize
// itself can move the readout.

/// Registers the title-dimensions scenarios with the UI-test runner.
@objc(UBTitleDimensionsScenarios)
public final class TitleDimensionsScenarios: NSObject {
    /// Registers every scenario in this file.
    @objc
    public static func register() {
        UBUITestRegister("connect_title_dimensions_follow_the_bootstrap_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                let saved = t.configureAppending("[window]\ninitial_columns = 160\ninitial_rows = 42\n")
                defer { t.restoreConfiguration(saved) }
                guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
                    FileManager.default.isExecutableFile(atPath: hostBinary)
                else {
                    t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names the bundled host")
                    return
                }
                let root = "/tmp/ubq-title-grid-" + String(UUID().uuidString.prefix(8))
                let home = root + "/.ubiquitty"
                do {
                    try FileManager.default.createDirectory(
                        atPath: home,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    t.expect(false, desc: "an isolated host home was made (\(error))")
                    return
                }
                let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
                setenv("UBIQUITTY_HOME", home, 1)
                defer {
                    if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
                    try? FileManager.default.removeItem(atPath: root)
                }
                let daemon = Process()
                daemon.executableURL = URL(fileURLWithPath: hostBinary)
                daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
                daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
                do {
                    try daemon.run()
                } catch {
                    t.expect(false, desc: "the isolated host daemon started (\(error))")
                    return
                }
                defer {
                    if daemon.isRunning { daemon.terminate() }
                    daemon.waitUntilExit()
                }
                guard
                    t.wait(
                        until: {
                            ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
                                .contains {
                                    $0.hasPrefix("host-") && $0.hasSuffix(".sock")
                                }
                        },
                        timeout: 20
                    )
                else {
                    t.expect(false, desc: "the isolated host daemon opened its socket")
                    return
                }
                let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
                let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
                guard
                    let controller = TerminalWindowController.spawnRemoteWindow(
                        shellCommand: "sleep 3; UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach",
                        hostLabel: "grid.example",
                        quicHost: "",
                        quicBootstrapCommand: "",
                        deploySSHHost: "",
                        deployBinaries: [:],
                        reattachSessionID: 0,
                        workspaceName: "",
                        hostKey: ""
                    ), let window = controller.window, let surface = controller.remoteSurface
                else {
                    t.expect(false, desc: "Connect opens a bootstrap window for grid.example")
                    return
                }
                defer { t.closeAllWindows() }
                t.expect(surface.drive.remotePaneBytesReceived == 0, desc: "the host has supplied no pane bytes")
                window.setFrame(NSRect(x: 200, y: 200, width: 1200, height: 760), display: true)
                t.pump(0.4)
                guard let strip = titlebarStrip(of: window), let field = titleField(in: strip) else {
                    t.expect(false, desc: "the Connect window draws a title strip")
                    return
                }
                let first = surface.publishedGrid
                t.expect(first != (24, 80), desc: "the laid-out grid differs from the launch size (\(first))")
                let firstTitle = field.attributedStringValue.string
                let firstReadout = "\(first.columns)\u{00d7}\(first.rows)"
                t.expect(
                    firstTitle.hasSuffix(firstReadout),
                    desc: "the visible title names the bootstrap grid (\(firstTitle) vs \(first))"
                )
                window.setFrame(NSRect(x: 200, y: 200, width: 1080, height: 690), display: true)
                t.pump(0.4)
                let second = surface.publishedGrid
                t.expect(second != first, desc: "the bootstrap grid follows a second resize (\(second) vs \(first))")
                let secondTitle = field.attributedStringValue.string
                let secondReadout = "\(second.columns)\u{00d7}\(second.rows)"
                t.expect(
                    secondTitle.hasSuffix(secondReadout),
                    desc: "the visible title follows the resized bootstrap grid (\(secondTitle) vs \(second))"
                )
                guard
                    t.wait(
                        until: {
                            surface.drive.remoteState == .Connected && surface.drive.remotePaneBytesReceived > 0
                        },
                        timeout: 30
                    )
                else {
                    t.expect(
                        false,
                        desc:
                            "the host supplies the pane's screen (state \(surface.drive.remoteState), session \(surface.remoteSessionID), bytes \(surface.drive.remotePaneBytesReceived), detail \(surface.remoteFailureDetail))"
                    )
                    return
                }
                t.pump(0.3)
                let hostGrid = surface.drive.readSnapshot()
                let hostTitle = titleField(in: strip)?.attributedStringValue.string ?? ""
                let hostReadout = "\(hostGrid.columns)\u{00d7}\(hostGrid.rows)"
                t.expect(
                    hostTitle.hasSuffix(hostReadout),
                    desc: "the visible title names the host's grid after the screen arrives (\(hostTitle) vs \(hostReadout))"
                )
            }
        }

        UBUITestRegister("title_dimensions_follow_a_swift_shell_grid_resize") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                // A window running one program that draws nothing on a
                // resize. This shell re-weaves the title on every screen
                // update, so a login shell — which repaints its prompt on
                // SIGWINCH — would carry the readout on its own output and
                // the scenario would pass with no grid weave at all.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/cat"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ), let window = shell.window
                else {
                    t.expect(false, desc: "a Swift shell window came up running cat")
                    return
                }
                // The process sample settled on cat before the facts below are
                // held: a chain that moves after the resize is an edge that
                // weaves the title, and the quiet assertion below would name it.
                _ = t.wait(
                    until: {
                        guard let surface = shell.focusedSurfaceForTesting, surface.drive.processChain.contains("cat")
                        else {
                            return false
                        }
                        return titlebarStrip(of: window).flatMap(titleField(in:)).flatMap(statusSuffix(of:)) != nil
                    },
                    timeout: 8.0
                )
                t.pump(0.5)
                guard let strip = titlebarStrip(of: window), let surface = shell.focusedSurfaceForTesting,
                    let before = titleField(in: strip).flatMap(statusSuffix(of:))
                else {
                    t.expect(false, desc: "the shell's titlebar carries the dimensions after the title")
                    return
                }
                let opened = surface.drive.readSnapshot()
                t.expect(
                    before == "\(opened.columns)\u{00d7}\(opened.rows)",
                    desc: "the readout names the grid the shell opened at (\(before) vs \(opened.columns)\u{00d7}\(opened.rows))"
                )
                // The readout is a component beside the title, so the title
                // text itself must not carry the size as well — woven in too,
                // the row read "208×44 — 208×44".
                t.expect(
                    !window.title.contains("\u{00d7}"),
                    desc: "the title text leaves the columns\u{00d7}rows to the readout beside it (\(window.title))"
                )
                // The facts whose edges weave the title, held across the
                // resize below: with these unmoved, only the grid can have.
                let quietTitle = surface.title
                let quietDirectory = surface.currentDirectory
                let quietChain = surface.drive.processChain

                // A few rows and columns off the frame, which is the path a
                // drag takes into the surface: the window's frame, the
                // content's, then the surface's own size.
                var resized = window.frame
                resized.size.width -= 90
                resized.size.height -= 60
                window.setFrame(resized, display: true)
                t.pump(0.3)
                let moved = surface.drive.readSnapshot()
                t.expect(
                    moved.columns < opened.columns && moved.rows < opened.rows,
                    desc:
                        "the grid moved with the frame (\(moved.columns)\u{00d7}\(moved.rows) from \(opened.columns)\u{00d7}\(opened.rows))"
                )
                t.expect(
                    surface.title == quietTitle && surface.currentDirectory == quietDirectory
                        && surface.drive.processChain == quietChain,
                    desc: "the pane stayed quiet across the resize: no title, directory or process edge to carry the readout"
                )
                let after = titleField(in: strip).flatMap(statusSuffix(of:))
                t.expect(
                    after == "\(moved.columns)\u{00d7}\(moved.rows)",
                    desc:
                        "the readout follows the grid with no output to carry it (\(after ?? "none") vs \(moved.columns)\u{00d7}\(moved.rows))"
                )
                t.closeAllWindows()
            }
        }
    }
}
