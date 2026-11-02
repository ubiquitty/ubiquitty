// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// FontZoomScenarios.swift — View > Zoom In / Zoom Out / Actual Size, driven
// the way the menu drives them: an action sent down the responder chain, so
// the key window's controller is the one that answers.
//
// A zoom is view state of one window. The other windows keep their size, the
// preference and its file are untouched, and a change to the default (the
// Settings pane) reaches every window through its own zoom. Actual Size
// renders the CONFIGURED size, not the compiled default, and writes nothing.
// Menu actions reach the Swift terminal window through the responder chain.

/// The size the scenarios configure, apart from the compiled default so
/// Actual Size can be told from a reset to the compiled default.
private let configuredSize = 14.0

/// Registers the font-zoom scenarios with the UI-test runner.
///
/// A scenario is a C function pointer, so each closure below carries no
/// context.
enum FontZoomScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("zoom_changes_the_front_window_only") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
                defer { app.settingsSetFontSize(savedSize) }
                app.settingsSetFontSize(configuredSize)
                let configBytes = configFileBytes()

                guard let front = t.newWindowRunning(nil), let other = t.newWindowRunning(nil) else {
                    t.expect(false, desc: "two Metal-arm windows open")
                    return
                }
                t.expect(fontSize(of: front) == configuredSize, desc: "a new window opens at the configured size")
                t.expect(fontSize(of: other) == configuredSize, desc: "and so does the next")

                t.expect(send("growFontSize:", to: front.window), desc: "Zoom In is answered by the key window's controller")
                t.pump(0.1)
                t.expect(fontSize(of: front) == configuredSize + step, desc: "the key window grows by one step")
                t.expect(fontSize(of: other) == configuredSize, desc: "the other window keeps its size")
                t.expect(
                    Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee) == configuredSize,
                    desc: "the preference is not what a zoom changes"
                )
                t.expect(configFileBytes() == configBytes, desc: "and the config file is untouched")

                t.expect(send("shrinkFontSize:", to: front.window), desc: "Zoom Out is answered by the key window's controller")
                t.expect(send("shrinkFontSize:", to: front.window), desc: "twice")
                t.pump(0.1)
                t.expect(fontSize(of: front) == configuredSize - step, desc: "two steps out from one step in is one step under")
                t.expect(fontSize(of: other) == configuredSize, desc: "the other window still keeps its size")

                // A new default reaches both windows, each through its own zoom.
                app.settingsSetFontSize(configuredSize + 2.0 * step)
                t.pump(0.1)
                t.expect(fontSize(of: front) == configuredSize + step, desc: "the zoomed window keeps its zoom over the new default")
                t.expect(fontSize(of: other) == configuredSize + 2.0 * step, desc: "the unzoomed window shows the new default")

                let opened = t.newWindowRunning(nil)
                t.expect(
                    opened.map(fontSize(of:)) == configuredSize + 2.0 * step,
                    desc: "a window opened afterwards is at the default, unzoomed"
                )
            }
        }

        UBUITestRegister("actual_size_restores_the_configured_size") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
                defer { app.settingsSetFontSize(savedSize) }
                app.settingsSetFontSize(configuredSize)
                let configBytes = configFileBytes()

                guard let front = t.newWindowRunning(nil) else {
                    t.expect(false, desc: "a Metal-arm window opens")
                    return
                }
                t.expect(send("growFontSize:", to: front.window), desc: "Zoom In is answered")
                t.expect(send("growFontSize:", to: front.window), desc: "twice")
                t.pump(0.1)
                t.expect(fontSize(of: front) == configuredSize + 2.0 * step, desc: "two steps in")

                t.expect(send("resetFontSize:", to: front.window), desc: "Actual Size is answered by the key window's controller")
                t.pump(0.1)
                t.expect(fontSize(of: front) == configuredSize, desc: "Actual Size renders the configured size, not the compiled default")
                t.expect(
                    Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee) == configuredSize,
                    desc: "the preference still says the configured size"
                )
                t.expect(configFileBytes() == configBytes, desc: "and the config file is untouched")
            }
        }

        UBUITestRegister("swift_shell_zoom_changes_the_front_window_only") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
                defer { app.settingsSetFontSize(savedSize) }
                app.settingsSetFontSize(configuredSize)
                let configBytes = configFileBytes()

                // The Swift shell is reached the way the product reaches it: as
                // the window a tmux -CC session surfaces. Two servers, so the
                // two windows are two shells rather than two tabs of one.
                t.killTmuxServer(onSocket: "ubiquitty-uitest-zoom-a")
                t.killTmuxServer(onSocket: "ubiquitty-uitest-zoom-b")
                defer {
                    t.killTmuxServer(onSocket: "ubiquitty-uitest-zoom-a")
                    t.killTmuxServer(onSocket: "ubiquitty-uitest-zoom-b")
                }
                guard let front = swiftShell(t, launching: "-L ubiquitty-uitest-zoom-a -CC new-session -A -s zoomA"),
                    let other = swiftShell(t, launching: "-L ubiquitty-uitest-zoom-b -CC new-session -A -s zoomB")
                else {
                    t.expect(false, desc: "two tmux sessions each surface a Swift-shell window")
                    return
                }
                t.pump(0.2)
                guard let frontCell = cellHeight(of: front), let otherCell = cellHeight(of: other) else {
                    t.expect(false, desc: "both windows report a cell size")
                    return
                }
                t.expect(frontCell == otherCell, desc: "two new windows share the configured cell size")

                t.expect(send("growFontSize:", to: front.window), desc: "Zoom In is answered by the key window's controller")
                t.pump(0.1)
                t.expect(front.fontZoomOffset == step, desc: "the key window carries one step of zoom")
                t.expect((cellHeight(of: front) ?? 0) > frontCell, desc: "and its cells grew")
                t.expect(cellHeight(of: other) == otherCell, desc: "the other window keeps its cell size")
                t.expect(other.fontZoomOffset == 0.0, desc: "and carries no zoom")
                t.expect(
                    Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee) == configuredSize,
                    desc: "the preference is not what a zoom changes"
                )
                t.expect(configFileBytes() == configBytes, desc: "and the config file is untouched")

                t.expect(send("resetFontSize:", to: front.window), desc: "Actual Size is answered by the key window's controller")
                t.pump(0.1)
                t.expect(front.fontZoomOffset == 0.0, desc: "Actual Size clears the zoom")
                t.expect(cellHeight(of: front) == frontCell, desc: "and the cells are back at the configured size")
                t.expect(configFileBytes() == configBytes, desc: "with the config file still untouched")
            }
        }
        // The proportional face is configured at a size of its own, beside the
        // grid's, and a zoom moves the two by one ratio: a run set at twelve
        // points beside a fourteen-point grid draws at twelve times the zoom.
        UBUITestRegister("swift_shell_zoom_scales_the_proportional_face_with_the_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let values = Ubiquitty.Preferences.values().pointee
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(values)
                let savedProportional = Ubiquitty.Preferences.Effective.renderConfiguration(values).proportionalFontSizePoints
                defer {
                    app.settingsSetFontSize(savedSize)
                    _ = setSetting(.FontProportionalSize, double: savedProportional)
                }
                app.settingsSetFontSize(configuredSize)
                _ = setSetting(.FontProportionalSize, double: 12.0)
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeKeyAndOrderFront(nil)
                t.expect(
                    surface.drawnProportionalPointSizeForTesting == 12.0,
                    desc:
                        "unzoomed, runs are set at the configured proportional size (\(surface.drawnProportionalPointSizeForTesting ?? -1))"
                )
                t.expect(send("growFontSize:", to: window), desc: "Zoom In is answered by the window's controller")
                t.pump(0.2)
                let grid = surface.drawnFontPointSizeForTesting ?? 0
                let proportional = surface.drawnProportionalPointSizeForTesting ?? 0
                t.expect(grid == configuredSize + step, desc: "the grid grew by one step (\(grid))")
                t.expect(
                    abs(proportional - 12.0 * grid / configuredSize) < 1e-6,
                    desc: "and the proportional face by the grid's ratio (\(proportional) for a \(grid)-point grid)"
                )
                t.expect(send("resetFontSize:", to: window), desc: "Actual Size is answered")
                t.pump(0.2)
                t.expect(
                    surface.drawnProportionalPointSizeForTesting == 12.0,
                    desc: "Actual Size returns the proportional face to its configured size"
                )
            }
        }
    }
}

// File scope because a scenario is a C function pointer, which cannot
// capture the context a type's static member carries.

/// One zoom step, Core's.
@MainActor
private var step: Double {
    Ubiquitty.Preferences.Zoom.fontZoomStep
}

/// Sends a View-menu action down a window's responder chain, the way the
/// menu does for the key window: from the first responder up, then the
/// window, then the window's controller. The harness runs as an accessory,
/// whose windows are never key, so the chain is walked from the window a
/// scenario names rather than from NSApp's key window; a window with no
/// first responder starts at the window itself.
///
/// - Parameters:
///   - selector: The action's selector name.
///   - window: The window that would be key.
/// - Returns: Whether a responder answered.
@MainActor
private func send(_ selector: String, to window: NSWindow?) -> Bool {
    let action = Selector(selector)
    var responder: NSResponder? = window?.firstResponder ?? window
    while let current = responder {
        if current.responds(to: action) {
            _ = current.perform(action, with: nil)
            return true
        }
        if let target = current.supplementalTarget(forAction: action, sender: nil) as? NSObject, target.responds(to: action) {
            _ = target.perform(action, with: nil)
            return true
        }
        responder = current.nextResponder
    }
    return false
}

/// The Metal-arm window's live font size, read from its focused
/// renderer through the property path the Inspector reads it by.
///
/// - Parameter controller: The window.
/// - Returns: The size in points.
@MainActor
private func fontSize(of controller: TerminalWindowController) -> Double {
    controller.beamSurface?.drive.withTerminal { $0.fontRequests.actualSizePoints() } ?? -1.0
}

/// The Swift-shell window's cell height, from the renderer of its one
/// pane's surface.
///
/// - Parameter controller: The window.
/// - Returns: The cell height in points, or nil without a renderer.
@MainActor
private func cellHeight(of controller: TerminalWindowController) -> Double? {
    guard let content = controller.window?.contentView, let surface = terminalSurface(under: content), let renderer = surface.renderer
    else {
        return nil
    }
    return renderer.cellSize(for: surface).height
}

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for child in view.subviews {
        if let surface = terminalSurface(under: child) {
            return surface
        }
    }
    return nil
}

/// The sandboxed config file's bytes, or nil when there is no file.
///
/// The suite points XDG_CONFIG_HOME at a throwaway directory, and the
/// settings setters write there; a zoom must not.
///
/// - Returns: The file's contents.
private func configFileBytes() -> Data? {
    guard let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] else {
        return nil
    }
    return try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("ubiquitty/config.toml"))
}

/// The Swift-shell window a tmux -CC session surfaces.
///
/// - Parameters:
///   - t: The harness.
///   - arguments: The complete tmux argument string, private socket included.
/// - Returns: The shell's controller, or nil when none surfaced in time.
@MainActor
private func swiftShell(_ t: UBUITestContext, launching arguments: String) -> TerminalWindowController? {
    guard let primary = t.launchTmuxArguments(arguments) else {
        return nil
    }
    var shell: TerminalWindowController?
    _ = t.wait(
        until: {
            shell = t.tmuxChildren(of: primary).first as? TerminalWindowController
            return shell != nil
        },
        timeout: 8.0
    )
    return shell
}
