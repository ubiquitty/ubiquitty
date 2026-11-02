// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import MetalKit
import UbiquittyCore
import UbiquittyKit

// ShellIntegrationScenarios.swift — what the window shows of the working
// directory the shell reports (OSC 7, 633, 1337), on both arms of the macOS
// frontend.
//
// Core's half is proven headless (Tests/Core/OSC/test_shell_integration_cluster);
// what only a running window can answer is whether a directory the shell
// reported reaches the title bar and its proxy icon. Each sequence is typed as
// a `printf`, the way a user reproduces it, so the bytes take the PTY route a
// shell's own prompt would.

/// Registers the shell-integration scenarios with the UI-test runner.
///
/// Called from the runner's registration sweep; a scenario is a C function
/// pointer, so each closure below carries no context.
@objc(UBShellIntegrationScenarios)
public final class ShellIntegrationScenarios: NSObject {
    /// Registers every scenario in this file.
    @objc
    public static func register() {
        UBUITestRegister("swift_close_exclusions_update_the_marker_and_confirmation") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = settingText(.TerminalCloseIgnoredProcesses)
                defer {
                    _ = setSetting(.TerminalCloseIgnoredProcesses, text: saved)
                    TerminalWindowController.refreshClosePolicy()
                }
                guard let shell = spawnSwiftShell(t), let window = shell.window else { return }
                defer { shell.shellCloseWindow() }
                t.expect(shell.isShellSafeToClose, desc: "a prompt closes silently")
                shell.shellSendProbe("sleep 30\r")
                t.expect(
                    t.wait(until: { !shell.isShellSafeToClose && window.isDocumentEdited }, timeout: 8),
                    desc: "running work marks the close button"
                )
                t.expect(!shell.windowShouldClose(window), desc: "running work asks before closing")
                guard let sheet = window.attachedSheet else {
                    t.expect(false, desc: "the confirmation sheet is present")
                    return
                }
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                t.pump(0.2)
                t.expect(setSetting(.TerminalCloseIgnoredProcesses, text: "sleep"), desc: "the exclusion is saved")
                if let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
                    t.expect(
                        Ubiquitty.Preferences.configureFromFile(std.string(home + "/ubiquitty/config.toml"), .Strict).isApplied,
                        desc: "the saved configuration parses"
                    )
                    t.expect(
                        String(Ubiquitty.Preferences.Effective.closeIgnoredProcesses(Ubiquitty.Preferences.values().pointee)) == "sleep",
                        desc: "the exclusion survives a configuration reload"
                    )
                } else {
                    t.expect(false, desc: "the test owns a configuration sandbox")
                }
                TerminalWindowController.refreshClosePolicy()
                t.expect(shell.isShellSafeToClose, desc: "the excluded process closes silently")
                t.expect(!window.isDocumentEdited, desc: "the exclusion removes the close marker")
            }
        }
        // A program that takes the alternate screen and exits, the way
        // Midnight Commander quits, returns to a shell whose prompt hooks run
        // as foreground jobs a moment long. The drain that reads the start of
        // the prompt announces the program leaving; the marker redrawn for
        // that announcement must not answer for the hook running when the
        // redraw lands, because the prompt that follows moves nothing that
        // would redraw it again.
        UBUITestRegister("swift_close_marker_clears_when_an_alternate_screen_program_exits") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = spawnSwiftShell(t, arguments: ["/bin/zsh", "-f", "-i"]), let window = shell.window,
                    let surface = shell.shellFocusedPaneIdentity as? TerminalSurface
                else { return }
                defer { shell.shellCloseWindow() }
                // An off-screen test window reads as covered, and a covered
                // window neither samples its processes nor redraws its marker.
                surface.isFullyOccludedForTesting = false
                shell.refreshTitles()
                // The shell keeps the terminal for a few milliseconds after
                // the prompt's first bytes, then hands it to a short job.
                shell.shellSendProbe("precmd() { repeat 20000 do :; done; sleep 0.05 }\r")
                t.pump(0.5)
                t.expect(
                    t.wait(until: { shell.isShellSafeToClose && !window.isDocumentEdited }, timeout: 4),
                    desc: "the prompt starts unmarked"
                )
                // Spun without pumping: the announcement waits on the main
                // queue until the hook holds the terminal, which is the moment
                // a redraw lands in at random outside this test.
                func spin(until condition: () -> Bool) -> Bool {
                    let deadline = Date(timeIntervalSinceNow: 5)
                    while Date() < deadline {
                        if condition() { return true }
                    }
                    return false
                }
                for run in 1...3 {
                    shell.shellSendProbe("sh -c 'printf \"\\033[?1049h\"; sleep 0.3; printf \"\\033[?1049l\"'\r")
                    let sawProgram = spin { !shell.isShellSafeToClose }
                    let sawReclaim = sawProgram && spin { shell.isShellSafeToClose }
                    let sawHook = sawReclaim && spin { !shell.isShellSafeToClose }
                    t.expect(sawHook, desc: "run \(run): the program, the shell and its hook each held the terminal")
                    t.pump(0.05)
                    t.expect(
                        t.wait(until: { shell.isShellSafeToClose }, timeout: 4),
                        desc: "run \(run): the shell is back at its prompt"
                    )
                    t.pump(1.5)
                    t.expect(!window.isDocumentEdited, desc: "run \(run): the close button carries no running-job marker at the prompt")
                }
            }
        }
        InspectorScenarios.register()
        SessionPlumbingScenarios.register()
        UBUITestRegister("swift_native_inspector_animation_keeps_the_terminal_layers_pinned_left") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface
                else { return }
                defer { controller.shellCloseWindow() }
                // The inspector grows from the trailing edge, so the terminal
                // only narrows: its leading edge is where it was on every frame
                // of the animation, not only once the animation has settled.
                // Asked of the presentation layers, which are what Core
                // Animation composites mid-flight. What this cannot see is the
                // drawable's own pixels, which the layer places top-left and
                // does not move.
                for pass in ["the first appearance", "a later appearance"] {
                    if pass == "a later appearance" {
                        controller.toggleNativeInspector(nil)
                        t.pump(0.5)
                    }
                    guard let start = presentedLeadingEdge(of: surface) else {
                        t.expect(false, desc: "the terminal surface is layer-backed and on screen")
                        return
                    }
                    controller.toggleNativeInspector(nil)
                    var samples: [CGFloat] = []
                    let deadline = Date(timeIntervalSinceNow: 0.45)
                    while Date() < deadline {
                        t.pump(0.01)
                        if let edge = presentedLeadingEdge(of: surface) {
                            samples.append(edge)
                        }
                    }
                    let drift = samples.map { abs($0 - start) }.max() ?? 0
                    t.expect(
                        !samples.isEmpty && drift <= 1,
                        desc: "\(pass): the terminal's leading edge holds through the inspector's animation"
                            + " (start \(start), furthest \(drift) pt away over \(samples.count) frames)"
                    )
                }
            }
        }
        UBUITestRegister("swift_native_tab_strip_resize_preserves_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t), let window = controller.window,
                    let sibling = spawnSwiftShell(t), let siblingWindow = sibling.window
                else { return }
                defer { sibling.shellCloseWindow() }
                defer { controller.shellCloseWindow() }
                controller.resizeWindow(toColumns: 80, rows: 24)
                window.addTabbedWindow(siblingWindow, ordered: .above)
                window.tabGroup?.selectedWindow = window
                t.pump(0.2)
                t.expect((window.tabbedWindows?.count ?? 0) == 2, desc: "the ordinary window has a native tab strip")
                controller.resizeWindow(toColumns: 80, rows: 24)
                t.expect(
                    t.wait(
                        until: {
                            guard let surface = controller.focusedSurfaceForTesting else { return false }
                            return surface.publishedGrid.columns == 80 && surface.publishedGrid.rows == 24
                        },
                        timeout: 4
                    ),
                    desc: "an ordinary tabbed window resizes to the exact grid"
                )
            }
        }

        UBUITestRegister("swift_native_inspector_full_height_preserves_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t), let window = controller.window else { return }
                defer { controller.shellCloseWindow() }
                controller.toggleNativeInspector(nil)
                t.pump(0.25)
                guard let split = window.contentViewController as? NSSplitViewController,
                    let inspector = split.splitViewItems.last
                else {
                    t.expect(false, desc: "the native inspector split exists")
                    return
                }
                guard let inspectorContent = inspector.viewController.view.subviews.first else {
                    t.expect(false, desc: "the inspector has hosted controls")
                    return
                }
                window.contentView?.layoutSubtreeIfNeeded()
                t.expect(window.styleMask.contains(.fullSizeContentView), desc: "the inspector uses full-height native content")
                let inspectorFrame = inspectorContent.convert(inspectorContent.bounds, to: nil)
                t.expect(
                    inspectorFrame.maxY <= window.contentLayoutRect.maxY + 1,
                    desc: "the inspector leaves the window title region available to every tab"
                )
                let terminalFrame = controller.paneHost.convert(controller.paneHost.bounds, to: nil)
                t.expect(terminalFrame.maxY <= window.contentLayoutRect.maxY + 1, desc: "terminal rows remain below title and tab chrome")
                let rootSafeFrame = split.view.convert(split.view.safeAreaRect, to: nil)
                let rootFrame = split.view.convert(split.view.bounds, to: nil)
                t.expect(
                    abs(terminalFrame.maxY - rootSafeFrame.maxY) <= 1
                        && abs(terminalFrame.minY - rootFrame.minY) <= 1,
                    desc: "inspector terminal uses the root split's vertical bounds"
                        + " (terminal \(terminalFrame.minY)...\(terminalFrame.maxY), root"
                        + " \(rootFrame.minY)...\(rootSafeFrame.maxY))"
                )
                for visible in [true, false, true] {
                    if (controller.inspectorWidth > 0) != visible {
                        controller.toggleNativeInspector(nil)
                        t.pump(0.25)
                    }
                    controller.resizeWindow(toColumns: 80, rows: 24)
                    t.expect(
                        t.wait(
                            until: {
                                guard let surface = controller.focusedSurfaceForTesting else { return false }
                                return surface.publishedGrid.columns == 80 && surface.publishedGrid.rows == 24
                            },
                            timeout: 4
                        ),
                        desc: "grid resize preserves exact rows and columns with inspector shown or hidden"
                    )
                }
                controller.toggleHideTitleBar(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                let titlelessFrame = controller.paneHost.convert(controller.paneHost.bounds, to: nil)
                t.expect(
                    abs(titlelessFrame.maxY - window.contentView!.convert(window.contentView!.bounds, to: nil).maxY) <= 1,
                    desc: "hidden title chrome gives its space back to terminal content"
                )
                controller.toggleHideTitleBar(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                let revealedFrame = controller.paneHost.convert(controller.paneHost.bounds, to: nil)
                t.expect(revealedFrame.maxY <= window.contentLayoutRect.maxY + 1, desc: "revealed title chrome restores the safe top inset")
                t.expect(
                    window.styleMask.contains(.fullSizeContentView),
                    desc: "showing the titlebar preserves full-height inspector layout"
                )
                var siblingToClose: TerminalWindowController?
                defer { siblingToClose?.shellCloseWindow() }
                if let sibling = spawnSwiftShell(t), let siblingWindow = sibling.window {
                    siblingToClose = sibling
                    window.addTabbedWindow(siblingWindow, ordered: .above)
                    window.tabGroup?.selectedWindow = window
                    t.pump(0.2)
                    window.contentView?.layoutSubtreeIfNeeded()
                    t.expect((window.tabbedWindows?.count ?? 0) == 2, desc: "the test has a native tab strip")
                    let tabbedTerminal = controller.paneHost.convert(controller.paneHost.bounds, to: nil)
                    t.expect(
                        tabbedTerminal.maxY <= window.contentLayoutRect.maxY + 1,
                        desc: "the native tab strip cannot overlap terminal rows"
                    )
                    // Asked of the settled layout rather than the first pass after the
                    // strip appears: the inspector's split re-reads the content layout
                    // rect a turn after the terminal does, and a tab strip that lives
                    // in the titlebar moves that rect after the pane host has moved.
                    let inspectorView = inspectorContent
                    let inspectorClearsStrip = t.wait(
                        until: {
                            window.contentView?.layoutSubtreeIfNeeded()
                            return inspectorView.convert(inspectorView.bounds, to: nil).maxY
                                <= window.contentLayoutRect.maxY + 1
                        },
                        timeout: 2
                    )
                    let tabbedInspector = inspectorView.convert(inspectorView.bounds, to: nil)
                    t.expect(
                        inspectorClearsStrip,
                        desc: "the inspector leaves the native tab strip unobstructed"
                            + " (inspector top \(tabbedInspector.maxY), content top"
                            + " \(window.contentLayoutRect.maxY), terminal top \(tabbedTerminal.maxY),"
                            + " frame \(window.frame.height))"
                    )
                    let terminalMatchesRoot = t.wait(
                        until: {
                            window.contentView?.layoutSubtreeIfNeeded()
                            let terminalFrame = controller.paneHost.convert(controller.paneHost.bounds, to: nil)
                            let safeFrame = split.view.convert(split.view.safeAreaRect, to: nil)
                            let rootFrame = split.view.convert(split.view.bounds, to: nil)
                            return abs(terminalFrame.maxY - safeFrame.maxY) <= 1
                                && abs(terminalFrame.minY - rootFrame.minY) <= 1
                        },
                        timeout: 2
                    )
                    let settledTerminal = controller.paneHost.convert(controller.paneHost.bounds, to: nil)
                    let settledRootSafe = split.view.convert(split.view.safeAreaRect, to: nil)
                    let settledRoot = split.view.convert(split.view.bounds, to: nil)
                    t.expect(
                        terminalMatchesRoot,
                        desc: "native tabs leave the inspector terminal aligned to the root split"
                            + " (terminal \(settledTerminal.minY)...\(settledTerminal.maxY), root"
                            + " \(settledRoot.minY)...\(settledRootSafe.maxY))"
                    )
                    controller.resizeWindow(toColumns: 80, rows: 24)
                    t.expect(
                        t.wait(
                            until: {
                                guard let surface = controller.focusedSurfaceForTesting else { return false }
                                return surface.publishedGrid.columns == 80 && surface.publishedGrid.rows == 24
                            },
                            timeout: 4
                        ),
                        desc: "grid resize includes native title and tab-strip height"
                    )
                }
                if let model = controller.inspectorModel {
                    let size = model.fontSize
                    model.fontSize = size + 1
                    model.applyFont()
                    t.expect(
                        t.wait(
                            until: {
                                guard let surface = controller.focusedSurfaceForTesting else { return false }
                                return surface.publishedGrid.columns == 80 && surface.publishedGrid.rows == 24
                            },
                            timeout: 4
                        ),
                        desc:
                            "font changes retain the grid with full-height chrome (\(controller.focusedSurfaceForTesting?.publishedGrid.columns ?? 0)×\(controller.focusedSurfaceForTesting?.publishedGrid.rows ?? 0))"
                    )
                }
            }
        }
        UBUITestRegister("swift_native_inspector_tracks_session_events") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t), let window = controller.window else { return }
                defer { controller.shellCloseWindow() }
                controller.toggleNativeInspector(nil)
                guard let model = controller.inspectorModel else {
                    t.expect(false, desc: "the native inspector is created")
                    return
                }
                t.expect(window.contentViewController is NSSplitViewController, desc: "AppKit owns the inspector layout")
                t.expect(
                    t.wait(until: { model.columns > 0 && model.rows > 0 && !model.tty.isEmpty && !model.processes.isEmpty }, timeout: 8),
                    desc: "geometry, TTY, and process data populate"
                )
                let initialFontSize = model.fontSize
                model.fontSize = initialFontSize + 1
                model.applyFont()
                t.expect(model.fontSize == initialFontSize + 1, desc: "Inspector font size reaches the active renderer")
                model.fontSize = initialFontSize
                model.applyFont()
                t.expect(model.fontSize == initialFontSize, desc: "Inspector reads the acknowledged font size")
                controller.shellSendProbe("cd /tmp; printf '\\033]7;file://localhost/tmp\\007'; sleep 30\r")
                t.expect(
                    t.wait(
                        until: { model.directory.contains("tmp") && model.processes.contains(where: { $0.name == "sleep" }) },
                        timeout: 8
                    ),
                    desc: "directory and process events update the inspector without a refresh timer"
                )
                if let path = ProcessInfo.processInfo.environment["UBIQUITTY_INSPECTOR_SNAPSHOT"],
                    let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
                let firstTTY = model.tty
                controller.shellSplitRight()
                t.expect(
                    t.wait(until: { !model.tty.isEmpty && model.tty != firstTTY }, timeout: 8),
                    desc: "pane focus changes the inspected session"
                )
                t.expect(
                    !model.processes.contains(where: { $0.name == "sleep" }),
                    desc: "the sibling does not inherit the first pane's process list"
                )
                controller.toggleNativeInspector(nil)
                t.expect(controller.inspectorWidth == 0, desc: "hiding the inspector restores the terminal width")
            }
        }
        UBUITestRegister("swift_quit_confirms_background_tab_and_unfocused_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let busy = spawnSwiftShell(t), let idle = spawnSwiftShell(t),
                    let busyWindow = busy.window, let idleWindow = idle.window
                else { return }
                defer {
                    busy.shellCloseWindow()
                    idle.shellCloseWindow()
                }
                t.expect(
                    t.wait(until: { busy.isShellSafeToClose && idle.isShellSafeToClose }, timeout: 5),
                    desc: "idle shells need no confirmation"
                )
                var prompts = 0
                let idleReply = TerminalWindows.terminationReply { _ in
                    prompts += 1
                    return .alertSecondButtonReturn
                }
                t.expect(idleReply == .terminateNow && prompts == 0, desc: "idle quit is immediate")
                busy.shellSendProbe("sleep 30\r")
                t.expect(t.wait(until: { !busy.isShellSafeToClose }, timeout: 5), desc: "the foreground job requires confirmation")
                busy.shellSplitRight()
                busyWindow.addTabbedWindow(idleWindow, ordered: .above)
                idleWindow.tabGroup?.selectedWindow = idleWindow
                let cancelled = TerminalWindows.terminationReply { alert in
                    prompts += 1
                    t.expect(alert.messageText == "Quit Ubiquitty?", desc: "quit presents its confirmation")
                    return .alertSecondButtonReturn
                }
                t.expect(
                    cancelled == .terminateCancel && prompts == 1,
                    desc: "a job in an unfocused pane of a background tab blocks quit when cancelled"
                )
                t.expect(!busy.isShellSafeToClose, desc: "cancelling leaves the job running")
                t.expect(!busy.windowShouldClose(busyWindow), desc: "closing the busy tab asks first")
                if let sheet = busyWindow.attachedSheet {
                    @MainActor
                    func labels(in view: NSView) -> [String] {
                        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
                        return own + view.subviews.flatMap { labels(in: $0) }
                    }
                    let text = sheet.contentView.map { labels(in: $0).joined(separator: "\n") } ?? ""
                    t.expect(
                        text.contains("Do you want to terminate running processes in this tab?"),
                        desc: "the sheet uses Core's tab title: \(text)"
                    )
                    t.expect(
                        text.contains("Closing this tab will terminate the running process") && text.contains("sleep"),
                        desc: "the sheet names the job being terminated: \(text)"
                    )
                    busyWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                } else {
                    t.expect(false, desc: "the close confirmation sheet is attached")
                }
                let accepted = TerminalWindows.terminationReply { _ in
                    .alertFirstButtonReturn
                }
                t.expect(accepted == .terminateNow, desc: "explicit Quit allows termination")
            }
        }
        UBUITestRegister("swift_close_confirmation_terminate_closes_the_tab") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let busy = spawnSwiftShell(t), let busyWindow = busy.window else { return }
                busy.shellSendProbe("sleep 30\r")
                t.expect(t.wait(until: { !busy.isShellSafeToClose }, timeout: 5), desc: "the foreground job requires confirmation")
                t.expect(!busy.windowShouldClose(busyWindow), desc: "closing the busy tab asks first")
                guard let sheet = busyWindow.attachedSheet else {
                    t.expect(false, desc: "the close confirmation sheet is attached")
                    busy.shellCloseWindow()
                    return
                }
                // Terminate is the sheet's first button, and answering it is the
                // whole close: the tab goes on that answer alone.
                busyWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                t.expect(
                    t.wait(until: { busy.isClosedForTesting }, timeout: 5),
                    desc: "confirming the termination closes the tab without a second close"
                )
                if !busy.isClosedForTesting {
                    busy.shellCloseWindow()
                }
            }
        }
        UBUITestRegister("swift_output_repaints_without_input_or_cursor_blink") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let trigger = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: trigger) }
                let command =
                    "stty -echo; printf '\\033[2 qREADY'; while [ ! -e '\(trigger.path)' ]; do sleep 0.01; done; printf '\\033[9;1HOUTPUT-COMPLETE\\033['; sleep 20"
                guard let controller = t.newWindowRunning(["/bin/sh", "-c", command]),
                    let surface = controller.beamSurface
                else {
                    t.expect(false, desc: "the terminal opened")
                    return
                }
                defer { t.closeAllWindows() }
                t.expect(t.wait(forText: "READY", in: controller, timeout: 5), desc: "the child is ready")
                t.pump(0.03)
                let frames = surface.framesEncodedForTesting
                t.expect(frames > 0, desc: "the first frame is encoded")
                FileManager.default.createFile(atPath: trigger.path, contents: Data())
                t.expect(t.wait(forText: "OUTPUT-COMPLETE", in: controller, timeout: 3), desc: "the output reaches Core")
                t.expect(
                    t.wait(until: { surface.framesEncodedForTesting > frames }, timeout: 0.5),
                    desc: "output encodes another frame without a blink or input repaint"
                )
            }
        }
        UBUITestRegister("swift_login_title_settles_without_input_or_activation") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = TerminalWindowController.spawn(),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface,
                    let window = controller.window
                else {
                    t.expect(false, desc: "the login shell window opened")
                    return
                }
                defer { controller.shellCloseWindow() }
                t.expect(
                    t.wait(
                        until: {
                            let chain = surface.drive.processChain
                            let directory = surface.drive.currentDirectory() ?? ""
                            return !chain.isEmpty && chain != "login" && !directory.isEmpty
                                && window.title.contains(chain)
                        },
                        timeout: 8.0
                    ),
                    desc:
                        "startup settles without input or activation: title=\(window.title), chain=\(surface.drive.processChain), directory=\(surface.drive.currentDirectory() ?? "")"
                )
            }
        }
        // The Metal arm: the window controller the harness spawns.
        UBUITestRegister("osc7_reported_directory_leads_the_title_bar") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let path = scenarioDirectory("ubq-osc7-route")
                expectMetalArmFollowsReportedDirectory(t, route: "\\033]7;file://localhost\(path)\\033\\\\", path: path)
            }
        }
        UBUITestRegister("osc1337_current_dir_leads_the_title_bar") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let path = scenarioDirectory("ubq-1337-route")
                expectMetalArmFollowsReportedDirectory(t, route: "\\033]1337;CurrentDir=\(path)\\033\\\\", path: path)
            }
        }
        UBUITestRegister("osc633_cwd_leads_the_title_bar") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let path = scenarioDirectory("ubq-633-route")
                expectMetalArmFollowsReportedDirectory(t, route: "\\033]633;P;Cwd=\(path)\\033\\\\", path: path)
            }
        }

        // The Swift arm: the window shell the modern renderer opens.
        UBUITestRegister("swift_shell_title_bar_follows_the_reported_directory") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let path = scenarioDirectory("ubq-swift-osc7-route")
                guard let controller = spawnSwiftShell(t) else { return }
                controller.shellSendProbe("printf '\\033]7;file://localhost\(path)\\033\\\\'\r")
                let titleNamesIt = t.wait(
                    until: { controller.window?.title.contains(URL(fileURLWithPath: path).lastPathComponent) ?? false },
                    timeout: 0.2
                )
                t.expect(titleNamesIt, desc: "the window title immediately names the reported directory")
                let heard = t.wait(
                    until: { (controller.shellFocusedPaneIdentity as? TerminalSurface)?.currentDirectory == path },
                    timeout: 6.0
                )
                t.expect(heard, desc: "the surface hears the reported directory")
                t.expect(revealFolderIcon(in: controller.window), desc: "the Swift title strip offers a hover to dwell on")
                let iconStands = t.wait(until: { controller.window?.representedURL?.path == path }, timeout: 4.0)
                t.expect(iconStands, desc: "the proxy icon stands on the reported directory")
                controller.shellCloseWindow()
            }
        }

        // The other source. `/bin/sh` reports nothing, so everything here comes
        // from the sample Core takes of the PTY's foreground process, which is
        // what every shell with no integration configured leaves as the only
        // answer. The window is a Kit-hosted one on purpose: the shared
        // component arbitrates the sample, so the window has a directory
        // before any shell reports one.
        UBUITestRegister("swift_shell_directory_falls_back_to_the_sampled_process") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let path = scenarioDirectory("ubq-swift-sampled-cwd")
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface
                else { return }
                defer { controller.shellCloseWindow() }

                // No OSC anywhere in this scenario: `cd` moves the shell, and the
                // probe of the PTY's foreground process is what finds it.
                controller.shellSendProbe("cd \(path)\r")
                let sampled = t.wait(
                    until: { surface.drive.borrowTerminal().map { isSamePath(String($0.currentDirectory.view()), path) } ?? false },
                    timeout: 8.0
                )
                t.expect(sampled, desc: "a shell that reports nothing still carries the directory it is in")
                t.expect(
                    t.wait(
                        until: { controller.window?.title.contains(URL(fileURLWithPath: path).lastPathComponent) ?? false },
                        timeout: 4.0
                    ),
                    desc: "and the window title names it"
                )
                t.expect(
                    surface.drive.borrowTerminal().map { $0.reportedDirectory.empty() } ?? false,
                    desc: "with nothing reported, so the sample is what answered"
                )
            }
        }
        // ⌘T. The tab opens where the active pane is, and the directory it
        // inherits is Core's resolved answer, so a shell that reports nothing
        // still hands its tab the folder it is in.
        UBUITestRegister("swift_shell_new_tab_starts_in_the_active_pane_directory") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let path = scenarioDirectory("ubq-swift-tab-inherit")
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface,
                    let window = controller.window
                else { return }
                defer { window.tabGroup?.windows.forEach { $0.close() } }

                controller.shellSendProbe("cd \(path)\r")
                t.expect(
                    t.wait(
                        until: { surface.drive.borrowTerminal().map { isSamePath(String($0.currentDirectory.view()), path) } ?? false },
                        timeout: 8.0
                    ),
                    desc: "the first tab is in the directory to inherit"
                )

                controller.newWindowForTab(nil)
                t.expect(
                    t.wait(until: { (window.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    desc: "a second tab opens"
                )
                guard let sibling = window.tabGroup?.windows.first(where: { $0 !== window }),
                    let siblingController = sibling.windowController as? TerminalWindowController,
                    let siblingSurface = siblingController.shellFocusedPaneIdentity as? TerminalSurface
                else {
                    t.expect(false, desc: "the second tab hosts a surface")
                    return
                }
                t.expect(
                    t.wait(
                        until: {
                            siblingSurface.drive.borrowTerminal().map { isSamePath(String($0.currentDirectory.view()), path) } ?? false
                        },
                        timeout: 10.0
                    ),
                    desc: "and its shell started in the directory the active pane was in"
                )
            }
        }
        // The process-derived title segments. A Kit-hosted window showed none of
        // them: the composer hard-coded every one of the four flags to false,
        // so the [title] settings that ask for them were inert on this arm.
        // The window title and the tab label are the same facts spelled for
        // two surfaces, woven by two passes behind two memos. Nothing but a
        // shared trigger keeps them agreeing, and when the focus change
        // re-derived only the label they drifted: a tab settled on the shell
        // beside a window title still naming the `login` that exec'd it, for
        // as long as the session ran.
        //
        // A held program gives the pair one distinctive segment to agree
        // about. The focus handler is invoked directly because this
        // application never takes a key window of its own.
        UBUITestRegister("swift_shell_a_window_title_and_its_tab_name_one_process") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface,
                    let window = controller.window
                else { return }
                defer { controller.shellCloseWindow() }

                let windowTitle = { window.title }
                let tabLabel = { window.tab.attributedTitle?.string ?? window.tab.title ?? "" }

                controller.shellSendProbe("echo one-process-probe\r")
                t.expect(
                    t.wait(until: { !surface.drive.processChain.isEmpty && !windowTitle().isEmpty }, timeout: 10.0),
                    desc: "the session sampled its chain and named the window (\(windowTitle()))"
                )

                // A program that takes the foreground and then holds it
                // without writing again, so the segment stands still while
                // the assertions below read it.
                controller.shellSendProbe("perl -e 'print \"held\\n\"; sleep 6'\r")
                t.expect(
                    t.wait(until: { windowTitle().contains("perl") }, timeout: 10.0),
                    desc: "the window title followed the program in (\(windowTitle()))"
                )

                // The edge every tab of a group is guaranteed to see, and the
                // one that must re-derive the window title as well as the tab
                // label.
                controller.windowDidBecomeMain(
                    Notification(name: NSWindow.didBecomeMainNotification, object: window)
                )
                t.pump(0.4)

                t.expect(
                    windowTitle().contains("perl"),
                    desc: "the window title still names the held program after a focus change (\(windowTitle()))"
                )
                t.expect(
                    tabLabel().contains("perl"),
                    desc: "and its own tab names the same program (\(tabLabel()))"
                )
            }
        }

        UBUITestRegister("swift_shell_title_carries_the_process_segments") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface
                else { return }
                defer { controller.shellCloseWindow() }

                // Core samples these on its own drain probe, so they arrive
                // once the shell has produced anything at all.
                controller.shellSendProbe("echo segments-probe\r")
                t.expect(
                    t.wait(until: { !surface.drive.processChain.isEmpty }, timeout: 10.0),
                    desc: "Core sampled the foreground chain (\(surface.drive.processChain))"
                )
                t.expect(
                    !surface.drive.ttyName.isEmpty,
                    desc: "and the replica tty (\(surface.drive.ttyName))"
                )
                t.expect(
                    t.wait(until: { !surface.drive.shellCommandName.isEmpty }, timeout: 10.0),
                    desc: "and the session-leader shell (\(surface.drive.shellCommandName))"
                )

                // The chain names the shell that is running, which is what a
                // title reader is looking for.
                t.expect(
                    surface.drive.processChain.contains("sh"),
                    desc: "the chain names the running shell rather than something else"
                )

                // What the window is called, which is the claim: sampling the
                // facts and weaving them into the title are two paths, and a
                // composer that hard-codes the flags off samples just as well.
                let titleNow = { controller.window?.title ?? "" }
                t.expect(
                    t.wait(until: { titleNow().contains(surface.drive.processChain) }, timeout: 8.0),
                    desc: "the window title carries the chain (\(titleNow()))"
                )

                // A program taking the foreground moves the chain with no OSC
                // title and no `cd` behind it. Perl prints before it sleeps, so
                // the drain that samples the new foreground is one the output
                // itself provokes.
                controller.shellSendProbe("perl -e 'print \"held\\n\"; sleep 3'\r")
                t.expect(
                    t.wait(until: { titleNow().contains("perl") }, timeout: 10.0),
                    desc: "the title follows the program into the foreground (\(titleNow()))"
                )
                t.expect(
                    t.wait(until: { !titleNow().contains("perl") }, timeout: 15.0),
                    desc: "and lets it go when it finishes (\(titleNow()))"
                )

                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the settings the segments are keyed on are reachable")
                    return
                }
                let hadTTYName = app.settingsTitleWindowTTYName()
                let hadShellCommand = app.settingsTitleWindowShellCommand()
                let hadProcess = app.settingsTitleWindowProcess()
                defer {
                    app.settingsSetTitleWindowTTYName(hadTTYName)
                    app.settingsSetTitleWindowShellCommand(hadShellCommand)
                    app.settingsSetTitleWindowProcess(hadProcess)
                    TerminalWindowController.applyWindowChromeToOpenWindows()
                }

                // The replica tty, which is opt-in. Absent first, so the
                // assertion after it is answered by the setting rather than by
                // a name that was in the title all along.
                let ttyName = surface.drive.ttyName
                t.expect(
                    !titleNow().contains(ttyName),
                    desc: "the tty name is out while its setting is off (\(titleNow()))"
                )
                app.settingsSetTitleWindowTTYName(true)
                TerminalWindowController.applyWindowChromeToOpenWindows()
                t.expect(
                    titleNow().contains(ttyName),
                    desc: "and in once it is on (\(titleNow()))"
                )

                // The session-leader shell. At a prompt the leader's name and
                // the whole chain are the same text, so the chain stays off on
                // both sides of this and the setting is the only thing that
                // moves — a title still weaving the chain would otherwise
                // answer for the segment being asked about.
                app.settingsSetTitleWindowProcess(false)
                app.settingsSetTitleWindowShellCommand(false)
                TerminalWindowController.applyWindowChromeToOpenWindows()
                let shellCommand = surface.drive.shellCommandName
                t.expect(
                    !shellCommand.isEmpty,
                    desc: "the leader shell has a name to look for (\(shellCommand))"
                )
                t.expect(
                    !titleNow().contains(shellCommand),
                    desc: "neither process segment is in while both settings are off (\(titleNow()))"
                )
                app.settingsSetTitleWindowShellCommand(true)
                TerminalWindowController.applyWindowChromeToOpenWindows()
                t.expect(
                    titleNow().contains(shellCommand),
                    desc: "and the shell command arrives on its own setting (\(titleNow()))"
                )
            }
        }

        // The tab-number hints: shown while the modifier is held, and each one is
        // the key that selects the tab wearing it.
        UBUITestRegister("swift_shell_tabs_show_the_number_that_selects_them") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let first = TerminalWindowController.spawn(), let window = first.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer {
                    TerminalWindowController.isCommandKeyHeld = false
                    TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                    window.tabGroup?.windows.forEach { $0.close() }
                }

                // Two more tabs, so the strip exists and positions mean something.
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                first.newWindowForTab(nil)
                first.newWindowForTab(nil)
                t.expect(
                    t.wait(until: { (window.tabGroup?.windows.count ?? 0) == 3 }, timeout: 20),
                    desc: "the group has three tabs (\(window.tabGroup?.windows.count ?? 0))"
                )
                let tabs = window.tabGroup?.windows ?? []
                defer {
                    for tab in tabs where tab !== window {
                        tab.close()
                    }
                }

                // Trimmed: the hint is padded off the tab's right edge, which is
                // spacing rather than text.
                let accessoryText = { (tab: NSWindow) -> String in
                    ((tab.tab.accessoryView as? NSTextField)?.stringValue ?? "")
                        .trimmingCharacters(in: .whitespaces)
                }

                // The setting is stated rather than inherited: this runs against
                // a preferences sandbox of its own, and a leg that passed on
                // what that file happens to say would be reporting on the file.
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the hint setting is reachable")
                    return
                }
                let hadMode = Int(
                    Ubiquitty.Preferences.tabShortcutHintsToInt(
                        Ubiquitty.Preferences.Effective.tabShortcutHints(
                            Ubiquitty.Preferences.values().pointee
                        )
                    )
                )
                defer {
                    app.settingsSetTabShortcutHintMode(hadMode)
                    TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                }

                app.settingsSetTabShortcutHintMode(
                    Int(Ubiquitty.Preferences.tabShortcutHintsToInt(.Off))
                )
                TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                t.expect(
                    tabs.allSatisfy { accessoryText($0).isEmpty },
                    desc: "the off setting shows no numbers at all"
                )

                app.settingsSetTabShortcutHintMode(
                    Int(Ubiquitty.Preferences.tabShortcutHintsToInt(.Always))
                )
                TerminalWindowController.isCommandKeyHeld = true
                TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                // Read on the SELECTED tab. The others are background tabs whose
                // shells have printed a prompt, so they have unread output to
                // report, and that outranks a number — which is the ranking this
                // arm is meant to have.
                guard let group = window.tabGroup,
                    let selected = group.selectedWindow,
                    let selectedIndex = tabs.firstIndex(of: selected)
                else {
                    t.expect(false, desc: "the group has a selected tab to read")
                    return
                }
                let shown = accessoryText(selected)
                t.expect(
                    shown == "⌘\(selectedIndex + 1)",
                    desc: "the selected tab shows its own number (\(shown))"
                )
                // The producer and the consumer meeting on a real strip: the
                // number a tab advertises is the number that selects it.
                let selects = Ubiquitty.Session.tabIndexForShortcut(
                    Int32(selectedIndex + 1),
                    Int32(tabs.count)
                )
                t.expect(
                    Int(selects) == selectedIndex,
                    desc: "and that number selects it (\(selects))"
                )

                // A background tab with unread output reports that instead: a
                // number is recoverable by counting along the strip, unread
                // output is not.
                if let background = tabs.first(where: { $0 !== selected }) {
                    t.expect(
                        background.tab.accessoryView is TabAttentionDots,
                        desc: "unread output outranks the number on a background tab"
                    )
                }

                // Releasing changes nothing under the default setting: it asks
                // for the numbers Always, and a number that came and went with a
                // key nobody pressed would be the setting being ignored.
                TerminalWindowController.isCommandKeyHeld = false
                TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                t.expect(
                    accessoryText(selected) == "⌘\(selectedIndex + 1)",
                    desc: "the number stays while the setting asks for it always (\(accessoryText(selected)))"
                )

                // Under the on-command setting they follow the modifier, which
                // is the mode the whole held-key path exists for.
                app.settingsSetTabShortcutHintMode(
                    Int(Ubiquitty.Preferences.tabShortcutHintsToInt(.OnCommand))
                )
                TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                t.expect(
                    accessoryText(selected).isEmpty,
                    desc: "nothing held, nothing shown (\(accessoryText(selected)))"
                )
                TerminalWindowController.isCommandKeyHeld = true
                TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                t.expect(
                    accessoryText(selected) == "⌘\(selectedIndex + 1)",
                    desc: "and held brings it back (\(accessoryText(selected)))"
                )

                // A tab leaving renumbers every tab after it, and the labels
                // follow without anything else provoking them: a strip that
                // renumbered only when the reader next pressed something would
                // spend that time naming keys that select the wrong tabs.
                // Read on the selected tab again, for the same reason: the
                // others have unread output, which outranks a number.
                // The victim is neither the window this scenario reads the group
                // through nor the tab being measured, and it sits in front of
                // that tab so its going renumbers it.
                if let victim = tabs.first(where: { $0 !== window && $0 !== selected }),
                    let victimIndex = tabs.firstIndex(of: victim),
                    victimIndex < selectedIndex
                {
                    victim.close()
                    t.expect(
                        t.wait(until: { (selected.tabGroup?.windows.count ?? 0) == tabs.count - 1 }, timeout: 10),
                        desc: "the tab left the group (\(selected.tabGroup?.windows.count ?? 0))"
                    )
                    let remaining = selected.tabGroup?.windows ?? []
                    guard let movedTo = remaining.firstIndex(of: selected) else {
                        t.expect(false, desc: "the selected tab survived the close")
                        return
                    }
                    t.expect(
                        movedTo == selectedIndex - 1,
                        desc: "closing the tab in front moved it up one (\(movedTo))"
                    )
                    t.expect(
                        accessoryText(selected) == "⌘\(movedTo + 1)",
                        desc: "and its number moved with it (\(accessoryText(selected)))"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_osc72_drop_reads_native_text") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface
                else { return }
                defer { controller.shellCloseWindow() }
                let program = #"""
                    import os, tty, termios, select, time, base64
                    old = termios.tcgetattr(0)
                    received = bytearray()
                    limit = time.monotonic() + 15
                    osc = bytes([27]) + b"]72;"
                    st = bytes([27, 92])
                    def send(value): os.write(1, osc + value + st)
                    try:
                     tty.setraw(0)
                     send(b"t=a:i=0;text/plain")
                     os.write(1, b"\r\nOSC72-READY\r\n")
                     buffer = bytearray()
                     done = False
                     while not done and time.monotonic() < limit:
                      if not select.select([0], [], [], .1)[0]: continue
                      buffer.extend(os.read(0, 4096))
                      while st in buffer:
                       end = buffer.index(st)
                       packet = bytes(buffer[:end]); del buffer[:end + 2]
                       if osc not in packet: continue
                       packet = packet[packet.index(osc) + len(osc):]
                       header, _, payload = packet.partition(b";")
                       fields = dict(part.split(b"=", 1) for part in header.split(b":") if b"=" in part)
                       if fields.get(b"t") == b"m" and fields.get(b"x") != b"-1": send(b"t=m:o=1;text/plain")
                       if fields.get(b"t") == b"M":
                        send(b"t=r:x=1")
                        time.sleep(.3)
                       if fields.get(b"t") == b"r":
                        if payload: received.extend(base64.b64decode(payload + b"=" * (-len(payload) % 4)))
                        else: done = True
                     send(b"t=r:o=1")
                     send(b"t=A")
                     os.write(1, b"\r\n" + (b"OSC72-DROP-PASS" if bytes(received) == b"native drag text" * 131072 else b"OSC72-DROP-FAIL") + b"\r\n")
                    finally:
                     termios.tcsetattr(0, termios.TCSANOW, old)
                    """#
                let encoded = Data(program.utf8).base64EncodedString()
                controller.shellSendProbe("python3 -c 'import base64;exec(base64.b64decode(\"\(encoded)\"))'\r")
                guard t.wait(until: { surface.searchScrollbackAndWait("OSC72-READY").totalMatches > 0 }, timeout: 10) else {
                    t.expect(false, desc: "the terminal program registers for native drops")
                    return
                }
                let board = NSPasteboard(name: .init("ubiquitty-osc72-test-" + UUID().uuidString))
                defer { board.releaseGlobally() }
                board.clearContents()
                t.expect(
                    board.setString(String(repeating: "native drag text", count: 131072), forType: .string),
                    desc: "the native pasteboard owns its text"
                )
                guard t.wait(until: { surface.registeredDraggedTypes.contains(.string) }, timeout: 5) else {
                    t.expect(false, desc: "OSC 72 registration reaches the native surface")
                    return
                }
                surface.isFullyOccludedForTesting = false
                guard
                    t.wait(
                        until: {
                            surface.updateLayer()
                            return surface.gridHitForTesting(atViewPoint: NSPoint(x: 20, y: 20)).report != nil
                        },
                        timeout: 5
                    )
                else {
                    t.expect(false, desc: "the drawn grid maps the native drop location")
                    return
                }
                let drag = FileDropStub(pasteboard: board, location: surface.convert(NSPoint(x: 20, y: 20), to: nil))
                t.expect(surface.draggingEntered(drag).isEmpty, desc: "the native drop waits for program acceptance")
                guard t.wait(until: { surface.draggingUpdated(drag).contains(.copy) }, timeout: 5) else {
                    t.expect(false, desc: "OSC 72 acceptance reaches AppKit")
                    return
                }
                t.expect(surface.performDragOperation(drag), desc: "an accepted native drop delivers its MIME list")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("OSC72-DROP-PASS").totalMatches > 0 }, timeout: 10),
                    desc: "the program reads native text and completes the drop over OSC 72"
                )
            }
        }

        UBUITestRegister("swift_shell_dropped_files_arrive_escaped") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface
                else { return }
                defer { controller.shellCloseWindow() }

                // A name with a space in it is the case the escaping exists for:
                // unescaped it splits into two arguments nobody dropped.
                let directory = NSTemporaryDirectory() + "ubiquitty-drop-\(ProcessInfo.processInfo.processIdentifier)"
                try? FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(atPath: directory) }
                let spaced = directory + "/a file.txt"
                let plain = directory + "/plain.txt"
                for path in [spaced, plain] {
                    FileManager.default.createFile(atPath: path, contents: Data())
                }

                // Wide enough for both paths and the prompt on one row: what
                // is read back is the shell's echo of one long line, and how a
                // shell lays out a line wider than its terminal is its own.
                controller.resizeWindow(toColumns: 200, rows: 24)
                t.pump(0.3)

                let pasteboard = NSPasteboard(name: .init("ubiquitty-drop-test"))
                pasteboard.clearContents()
                pasteboard.writeObjects([URL(fileURLWithPath: spaced) as NSURL, URL(fileURLWithPath: plain) as NSURL])
                let drag = FileDropStub(pasteboard: pasteboard)

                t.expect(
                    surface.fileDropOperation(for: drag) == .copy,
                    desc: "a drag carrying files is accepted"
                )
                t.expect(surface.performFileDrop(drag), desc: "and the drop inserts something")

                // Read back off the grid: the shell echoes what was typed, so
                // the escaped form is what the reader would see at the prompt.
                let escaped = spaced.replacingOccurrences(of: " ", with: "\\ ")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait(escaped).totalMatches > 0 }, timeout: 8.0),
                    desc: "the space is escaped at the prompt"
                )
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait(plain).totalMatches > 0 }, timeout: 4.0),
                    desc: "and the second path is there beside it"
                )

                // An empty drag inserts nothing rather than a bare space.
                let empty = NSPasteboard(name: .init("ubiquitty-drop-test-empty"))
                empty.clearContents()
                let emptyDrag = FileDropStub(pasteboard: empty)
                t.expect(
                    surface.fileDropOperation(for: emptyDrag) == [],
                    desc: "a drag carrying no files is refused"
                )
                t.expect(!surface.performFileDrop(emptyDrag), desc: "and inserts nothing")
            }
        }

        // Keep on Top: the window floats, and the answer outlives the window.
        UBUITestRegister("swift_shell_keep_on_top_floats_and_is_remembered") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let wasKeptOnTop = WindowLevelMemory.isKeptOnTop()
                guard let first = TerminalWindowController.spawn(), let window = first.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer {
                    if WindowLevelMemory.isKeptOnTop() != wasKeptOnTop {
                        WindowLevelMemory.toggle(applyingTo: [])
                    }
                    window.close()
                }

                t.expect(window.level == .normal, desc: "a window opens at the ordinary level")
                first.toggleKeepOnTop(nil)
                t.expect(window.level == .floating, desc: "the command lifts it above other applications")
                t.expect(WindowLevelMemory.isKeptOnTop(), desc: "and the answer is remembered")

                // Remembered means the NEXT window opens floating: the reader
                // asked about windows, not about the one that was open.
                guard let second = TerminalWindowController.spawn(), let secondWindow = second.window else {
                    t.expect(false, desc: "a second window opens")
                    return
                }
                defer { secondWindow.close() }
                t.expect(
                    secondWindow.level == .floating,
                    desc: "a window opened afterwards floats too (\(secondWindow.level.rawValue))"
                )

                first.toggleKeepOnTop(nil)
                t.expect(window.level == .normal, desc: "and toggling it back puts it down")
                t.expect(!WindowLevelMemory.isKeptOnTop(), desc: "with the answer remembered again")
            }
        }

        // OSC 133 prompt marks in a live window. The bracket is an overlay quad
        // in the padding gutter, and the live route — a real shell, a real
        // drawable, the retained grid — is the one no snapshot arm exercises.
        UBUITestRegister("swift_remote_foreground_releases_the_local_folder_proxy") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t), let surface = controller.focusedSurfaceForTesting else { return }
                defer { controller.shellCloseWindow() }
                t.expect(
                    t.wait(until: { !surface.drive.representedLocalDirectory().isEmpty }, timeout: 8),
                    desc: "the local shell represents its folder"
                )
                controller.shellSendProbe("/usr/bin/ssh -F /dev/null -N -o 'ProxyCommand=sleep 30' -o ConnectTimeout=20 invalid.example\r")
                t.expect(
                    t.wait(until: { surface.drive.foregroundProcessName == "ssh" }, timeout: 8),
                    desc: "the local SSH process holds the foreground"
                )
                t.expect(
                    t.wait(until: { surface.drive.representedLocalDirectory().isEmpty }, timeout: 4),
                    desc: "a quiet SSH foreground has no local folder proxy"
                )
                controller.shellSendProbe("\u{3}")
                t.expect(
                    t.wait(until: { !surface.drive.representedLocalDirectory().isEmpty }, timeout: 8),
                    desc: "returning to the local shell restores its folder"
                )
            }
        }

        UBUITestRegister("swift_shell_a_prompt_mark_reaches_the_gutter") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t), let surface = controller.focusedSurfaceForTesting else { return }
                defer { controller.shellCloseWindow() }
                let before = surface.gutterOverlayCountForTesting() ?? 0
                t.expect(before == 0, desc: "a shell with no marks draws nothing in the gutters (\(before))")
                // A prompt, a command that ran and failed, the next prompt: the
                // A→C promotion marks the command's row and D;1 colours it.
                controller.shellSendProbe(
                    "printf '\\033]133;D;0\\007\\033]133;A\\007$ marked-command\\r\\n\\033]133;C\\007ran\\r\\n\\033]133;D;1\\007\\033]133;A\\007$ '\r"
                )
                t.expect(
                    t.wait(until: { surface.gridTextForTesting().contains("ran") }, timeout: 8),
                    desc: "the probe's output reached the grid"
                )
                t.expect(
                    t.wait(until: { (surface.gutterOverlayCountForTesting() ?? 0) > 0 }, timeout: 4),
                    desc: "the marked row draws a bracket in the gutter (\(surface.gutterOverlayCountForTesting() ?? -1) gutter quads)"
                )
            }
        }
        // A pinned tab: marked in the strip, held at the front of its group, and
        // asked about before it closes.
        UBUITestRegister("swift_shell_a_pinned_tab_is_marked_and_held_in_front") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t) else { return }
                defer {
                    // Unpinned first: a pinned window asks before it closes, and
                    // the sheet would hold this runner.
                    if controller.isPinned {
                        controller.togglePinTab(nil)
                    }
                    controller.shellCloseWindow()
                }

                controller.shellSendProbe("echo pin-probe\r")
                let tabLabel = { controller.window?.tab.attributedTitle?.string ?? "" }
                t.expect(
                    t.wait(until: { !tabLabel().isEmpty }, timeout: 10.0),
                    desc: "the tab has a label to mark (\(tabLabel()))"
                )
                t.expect(
                    !controller.isPinned,
                    desc: "a window opens unpinned"
                )
                t.expect(
                    !tabLabel().contains("📌"),
                    desc: "and unmarked (\(tabLabel()))"
                )

                controller.togglePinTab(nil)
                t.expect(controller.isPinned, desc: "the command pins it")
                t.expect(
                    t.wait(until: { tabLabel().contains("📌") }, timeout: 5.0),
                    desc: "the marker leads the label (\(tabLabel()))"
                )

                // The window title is not where the pin shows: a window's own
                // title bar is already the thing being pointed at.
                t.expect(
                    !(controller.window?.title ?? "").contains("📌"),
                    desc: "and does not reach the window title (\(controller.window?.title ?? ""))"
                )

                // The close asks now. windowShouldClose answers no and raises the
                // sheet; the sheet is modal and would hold this runner, so the
                // answer is what this reads.
                if let window = controller.window {
                    t.expect(
                        !controller.windowShouldClose(window),
                        desc: "a pinned close asks first"
                    )
                    window.attachedSheet.map { window.endSheet($0, returnCode: .alertSecondButtonReturn) }
                    t.expect(
                        t.wait(until: { window.attachedSheet == nil }, timeout: 3),
                        desc: "cancelling dismisses the pinned-tab confirmation"
                    )
                }

                controller.togglePinTab(nil)
                t.expect(!controller.isPinned, desc: "the command unpins it")
                t.expect(
                    t.wait(until: { !tabLabel().contains("📌") }, timeout: 5.0),
                    desc: "and the marker goes with it (\(tabLabel()))"
                )
                if let window = controller.window {
                    t.expect(
                        t.wait(until: { controller.isSafeToClose }, timeout: 5),
                        desc: "the shell has returned to an idle prompt"
                    )
                    window.performClose(nil)
                    t.expect(
                        t.wait(until: { !window.isVisible && window.attachedSheet == nil }, timeout: 3),
                        desc: "an unpinned prompt-only window closes without asking, including when retained for recovery"
                    )
                }
            }
        }

        // Which name the window answers to when several have been put on it, and
        // the argv spelling of the chain. Both are parts of the shared title
        // composer.
        UBUITestRegister("swift_shell_title_answers_to_the_names_put_on_it") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t),
                    let surface = controller.shellFocusedPaneIdentity as? TerminalSurface
                else { return }
                defer { controller.shellCloseWindow() }

                controller.shellSendProbe("echo named-probe\r")
                let titleNow = { controller.window?.title ?? "" }
                t.expect(
                    t.wait(until: { titleNow().contains("sh") }, timeout: 10.0),
                    desc: "the shell names the window to begin with (\(titleNow()))"
                )

                // A name put on the window fills the app-title segment and
                // takes the process segments' place; the folder stays, because
                // a person naming a window has not asked to stop being told
                // where it is. Set through the one writer every surface uses,
                // which is what Rename Tab calls once its sheet closes — the
                // sheet itself is modal and would hold this runner.
                let tabNow = { controller.window?.tab.title ?? "" }
                controller.setCustomTitles(window: "  the-window-name  ")
                t.expect(
                    titleNow().contains("the-window-name"),
                    desc: "the window name is in the title, trimmed (\(titleNow()))"
                )

                // The tab follows its window's name until it is named apart.
                t.expect(
                    tabNow().contains("the-window-name"),
                    desc: "the tab follows the window's name (\(tabNow()))"
                )

                // A tab's own name is the tab's alone: the window keeps its
                // name, and the tab stops following it.
                controller.setCustomTitles(tab: "the-tab-name")
                t.expect(
                    tabNow().contains("the-tab-name") && !tabNow().contains("the-window-name"),
                    desc: "the tab answers to its own name (\(tabNow()))"
                )
                t.expect(
                    titleNow().contains("the-window-name") && !titleNow().contains("the-tab-name"),
                    desc: "a tab's name does not reach its window (\(titleNow()))"
                )

                // Empty is the same fact as never set, and takes effect at
                // once: clearing both restores the woven titles rather than
                // leaving a blank window or a name that was cleared.
                controller.setCustomTitles(window: "", tab: "")
                t.expect(
                    titleNow().contains("sh") && !titleNow().contains("the-window-name"),
                    desc: "clearing restores what the composition weaves (\(titleNow()))"
                )
                t.expect(
                    !tabNow().contains("the-tab-name") && !tabNow().contains("the-window-name"),
                    desc: "and the tab's label with it (\(tabNow()))"
                )

                // The argv spelling comes from the same walk, so turning the
                // setting on shows a chain with arguments in it. Perl holds the
                // foreground long enough to read, and its argv is distinctive.
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the argv setting is reachable")
                    return
                }
                let hadArguments = app.settingsTitleWindowProcessArguments()
                defer {
                    app.settingsSetTitleWindowProcessArguments(hadArguments)
                    TerminalWindowController.applyWindowChromeToOpenWindows()
                }
                app.settingsSetTitleWindowProcessArguments(false)
                TerminalWindowController.applyWindowChromeToOpenWindows()
                // Held in the foreground while both spellings are read, so the
                // comparison is of one moment rather than two. The argv is long
                // on purpose: the plain spelling appends a tail only when the
                // whole leaf reads as a name (32 characters), so a short command
                // spells both ways identically and would test nothing.
                controller.shellSendProbe(
                    "perl -e 'print \"argv\\n\"; sleep 8; # a tail past the smart-name budget'\r"
                )
                t.expect(
                    t.wait(until: { surface.drive.processChain.contains("perl") }, timeout: 10.0),
                    desc: "Core sampled the chain (\(surface.drive.processChain))"
                )
                let plainChain = surface.drive.processChain
                let argvChain = surface.drive.processChainWithArguments
                // Without this the leg is vacuous: a plain chain that already
                // spells the arguments cannot show that the setting did
                // anything, and every assertion below would pass either way.
                t.expect(
                    plainChain != argvChain,
                    desc: "the two spellings differ, so this can tell them apart (\(plainChain) / \(argvChain))"
                )
                // Waited for rather than read once: the title is woven on a
                // later turn than the one the walk reported on.
                t.expect(
                    t.wait(until: { titleNow().contains(plainChain) && !titleNow().contains(argvChain) }, timeout: 5.0),
                    desc: "the plain chain is what shows while the setting is off (\(titleNow()))"
                )
                app.settingsSetTitleWindowProcessArguments(true)
                TerminalWindowController.applyWindowChromeToOpenWindows()
                t.expect(
                    t.wait(until: { titleNow().contains(argvChain) }, timeout: 5.0),
                    desc: "and the argv spelling once it is on (\(titleNow()))"
                )
            }
        }

        // The half a drain cannot cover. Every other title segment is pushed by
        // the bytes that changed it; the process chain is walked for, and a
        // program that takes the foreground and writes nothing produces no
        // bytes to walk on.
        UBUITestRegister("swift_shell_title_follows_a_silent_program") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = spawnSwiftShell(t) else { return }
                defer { controller.shellCloseWindow() }

                controller.shellSendProbe("echo awake\r")
                let titleNow = { controller.window?.title ?? "" }
                t.expect(
                    t.wait(until: { titleNow().contains("sh") }, timeout: 10.0),
                    desc: "the shell names the window to begin with (\(titleNow()))"
                )

                // Nothing is printed between the prompt and the program's exit,
                // so the drain that carried the prompt ran before `sleep` took
                // the foreground and no later drain runs at all.
                controller.shellSendProbe("sleep 4\r")
                t.expect(
                    t.wait(until: { titleNow().contains("sleep") }, timeout: 10.0),
                    desc: "the walk found it with no output to ride on (\(titleNow()))"
                )
                t.expect(
                    t.wait(until: { !titleNow().contains("sleep") }, timeout: 15.0),
                    desc: "and let it go when it finished (\(titleNow()))"
                )
            }
        }
    }
}

/// Whether two paths name the same directory.
///
/// The kernel reports a temporary directory under `/private/var`, and
/// `resolvingSymlinksInPath` spells the same directory `/var`: it documents
/// itself as STRIPPING a leading `/private`, so the two spellings never compare
/// equal even though `scenarioDirectory` resolved its own. Compared through one
/// normalisation rather than by string, so a sampled path and a made one agree.
///
/// - Parameters:
///   - one: A path.
///   - other: The path to compare it with.
/// - Returns: Whether both name the same directory.
@MainActor
private func isSamePath(_ one: String, _ other: String) -> Bool {
    guard !one.isEmpty, !other.isEmpty else { return false }
    return URL(fileURLWithPath: one).resolvingSymlinksInPath().path
        == URL(fileURLWithPath: other).resolvingSymlinksInPath().path
}

/// A directory under the temporary root, made so the reported path names a
/// folder that exists — the proxy icon is a real folder's.
///
/// - Parameter name: The leaf name; distinct per scenario so a stale window
///   cannot answer for a later one.
/// - Returns: The absolute path, with the temporary root resolved.
private func scenarioDirectory(_ name: String) -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath().path
}

/// Opens a Metal-arm window on `/bin/sh`, types the route as a `printf`, and
/// expects the proxy icon and the title to follow the directory it names.
///
/// - Parameters:
///   - t: The harness context.
///   - route: The escape sequence, spelled for `printf` (octal escapes).
///   - path: The directory the sequence reports.
@MainActor
private func expectMetalArmFollowsReportedDirectory(_ t: UBUITestContext, route: String, path: String) {
    // A plain `/bin/sh`, not the login shell: a shell with integration states
    // its own directory again at the prompt after the `printf`, and the title
    // rightly follows that newer report.
    guard let wc = t.newWindowRunning(["/bin/sh"]) else {
        t.expect(false, desc: "window opened")
        return
    }
    t.sendText("echo $((6*7))\r", to: wc)
    t.expect(t.wait(forText: "42", in: wc, timeout: 6.0), desc: "shell is live")
    // The proxy icon's slot is released until a dwell on the title strip owns
    // it, so the hover is held open for as long as this asserts through it.
    // While it is held the resolution funnel re-runs on every report, and the
    // icon follows the directory exactly as it does under a real pointer.
    t.expect(revealFolderIcon(in: wc.window), desc: "the title strip offers a hover to dwell on")
    t.sendText("printf '\(route)'\r", to: wc)
    let titleNamesIt = t.wait(
        until: { wc.window?.title.contains(URL(fileURLWithPath: path).lastPathComponent) ?? false },
        timeout: 0.2
    )
    t.expect(titleNamesIt, desc: "the window title immediately names the reported directory (got \"\(wc.window?.title ?? "")\")")
    let iconStands = t.wait(until: { wc.window?.representedURL?.path == path }, timeout: 6.0)
    t.expect(iconStands, desc: "the proxy icon stands on the reported directory (got \(wc.window?.representedURL?.path ?? "nil"))")
}

/// Spawns a Swift-shell window on a shell and waits for its prompt.
///
/// - Parameters:
///   - t: The harness context.
///   - arguments: The argument vector; the default is a plain `/bin/sh`.
/// - Returns: The controller, or nil after reporting the failure.
/// Where a view's leading edge is on screen right now, in the coordinates of
/// its window's content, read from the presentation layers so an animation in
/// flight is measured as drawn.
///
/// - Parameter view: A layer-backed view in a window.
/// - Returns: The edge, or nil when the view has no layer or window.
@MainActor
private func presentedLeadingEdge(of view: NSView) -> CGFloat? {
    guard let layer = view.layer, let root = view.window?.contentView?.layer else { return nil }
    let presented = layer.presentation() ?? layer
    let presentedRoot = root.presentation() ?? root
    return presented.convert(presented.bounds, to: presentedRoot).minX
}

@MainActor
private func spawnSwiftShell(_ t: UBUITestContext, arguments: [String] = ["/bin/sh"]) -> TerminalWindowController? {
    guard let controller = TerminalWindowController.spawn(arguments: arguments, localePolicy: .auto, sessionLifetime: .outlivesChild)
    else {
        t.expect(false, desc: "the Swift shell spawned")
        return nil
    }
    t.pump(0.3)
    guard controller.shellFocusedPaneIdentity is TerminalSurface else {
        t.expect(false, desc: "the Swift shell has a focused surface")
        return nil
    }
    // The prompt is up once the shell has read its first line; the wait is on
    // what each scenario observes, so this only lets the child start.
    t.pump(1.0)
    return controller
}
