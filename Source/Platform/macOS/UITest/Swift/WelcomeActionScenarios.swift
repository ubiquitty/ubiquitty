// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit

// WelcomeActionScenarios.swift — the Welcome screen's buttons, clicked in a
// window, and the question that stands between one of them and the reader's
// shell startup files.
//
// A button is an OSC 8 link, and anything that can print can print one under
// any label. So the install button's question is the only consent there is,
// and these scenarios hold it from both sides: no answer and a Cancel write
// nothing, a forged label reaches the same question, a button that only opens
// a window asks nothing and writes nothing, and Install writes exactly the
// files the question named. Each is driven through the real path — the grid,
// the click, the opener, the sheet a reader sees — and nothing is injected but
// the home directory, so the files written are the scenario's and never the
// reader's.
//
// Sheets are answered by pressing their buttons. The refusing one is found as
// AppKit's default button rather than by title, because what the gate turns on
// is which answer Return gives.

/// The Welcome screen as the app writes it into a window's pane.
///
/// The pane's facts are the surface's own — its terminal, its scale, an arm
/// that draws images — so the logo is the one a reader sees, chosen by Core.
///
/// - Parameter surface: The surface the screen is fed to.
/// - Returns: The screen's bytes.
@MainActor
func welcomeScreenBytes(for surface: TerminalSurface) -> Data {
    let scale = Double(surface.window?.backingScaleFactor ?? 1)
    let configuration = Ubiquitty.Preferences.values()
    let pane =
        surface.drive.withTerminal { Ubiquitty.App.Welcome.paneOf($0, configuration.pointee, scale, .drawn) }
        ?? Ubiquitty.App.Welcome.Pane()
    return Data(String(Ubiquitty.App.Welcome.screenContent(pane)).utf8)
}

/// The name the reader's login shell runs under, as the foreground job reports it.
///
/// - Returns: The basename of `$SHELL`, or `zsh`.
func welcomeShellName() -> String {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
    return shell.isEmpty ? "zsh" : (shell as NSString).lastPathComponent
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
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Where a label sits in a grid's text.
///
/// - Parameters:
///   - label: The text to find.
///   - text: The grid, one line per row.
/// - Returns: The row and the column of the label's third character — inside
///   the label rather than on its edge — or nil when it is not on screen.
private func cell(ofLabel label: String, in text: String) -> (row: Int, column: Int)? {
    for (row, line) in text.components(separatedBy: "\n").enumerated() {
        if let range = line.range(of: label) {
            return (row, line.distance(from: line.startIndex, to: range.lowerBound) + 2)
        }
    }
    return nil
}

/// Where a button sits, found by the link it declares.
///
/// The Welcome buttons are proportional runs, whose text rides the run's
/// anchor cell, so the grid's text holds a label's first letter only and a
/// search for the label finds nothing. The target is on every cell of the
/// plate, which is the fact a click acts on.
///
/// - Parameters:
///   - target: The `ubiquitty:action/` link the button declares.
///   - surface: The surface showing the Welcome screen.
///   - skippedRow: A row to pass over, holding another link to the same target.
/// - Returns: The row and the column of the plate's third cell, or nil when no
///   cell on screen declares the target.
@MainActor
private func cell(ofTarget target: String, in surface: TerminalSurface, skipping skippedRow: Int? = nil) -> (row: Int, column: Int)? {
    let grid = surface.publishedGrid
    for row in 0..<grid.rows where row != skippedRow {
        for column in 0..<grid.columns {
            if surface.drive.resolveLink(viewOffset: 0, row: row, column: column, scope: .declared)?.uri == target {
                return (row, column + 2)
            }
        }
    }
    return nil
}

/// A plain left click on one cell of a surface, press and release.
///
/// - Parameters:
///   - surface: The surface to click.
///   - window: The window it is in.
///   - cell: The row and column.
/// - Returns: Whether the cell had geometry to click.
@MainActor
private func click(_ surface: TerminalSurface, in window: NSWindow, at cell: (row: Int, column: Int)) -> Bool {
    guard let viewPoint = surface.viewPoint(forRow: cell.row, column: cell.column) else {
        return false
    }
    let point = surface.convert(viewPoint, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard
            let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
        else {
            return false
        }
        if type == .leftMouseDown {
            surface.mouseDown(with: event)
        } else {
            surface.mouseUp(with: event)
        }
    }
    return true
}

/// The sheet a window is showing, once AppKit has put it up.
///
/// - Parameters:
///   - window: The window the sheet attaches to.
///   - t: The running scenario, for pumping.
/// - Returns: The sheet, or nil when none appeared.
@MainActor
private func waitForSheet(on window: NSWindow, pumpingWith t: UBUITestContext) -> NSWindow? {
    for _ in 0..<40 {
        if let sheet = window.attachedSheet {
            return sheet
        }
        t.pump(0.05)
    }
    return nil
}

/// Pumps until the window has no sheet, so the next question is not queued
/// behind the last one.
///
/// - Parameters:
///   - window: The window.
///   - t: The running scenario, for pumping.
/// - Returns: Whether the sheet went.
@MainActor
private func waitForNoSheet(on window: NSWindow, pumpingWith t: UBUITestContext) -> Bool {
    t.wait(until: { window.attachedSheet == nil }, timeout: 3)
}

/// Every button under a view.
///
/// - Parameter view: The root.
/// - Returns: The buttons, in view order.
@MainActor
private func buttons(under view: NSView) -> [NSButton] {
    var found: [NSButton] = []
    if let button = view as? NSButton {
        found.append(button)
    }
    for subview in view.subviews {
        found += buttons(under: subview)
    }
    return found
}

/// The button a Return would press, as the panel decides it.
///
/// - Parameter sheet: The sheet.
/// - Returns: The default button, or nil when there is none.
@MainActor
private func defaultButton(of sheet: NSWindow) -> NSButton? {
    guard let cell = sheet.defaultButtonCell, let content = sheet.contentView else {
        return nil
    }
    return buttons(under: content).first { $0.cell === cell }
}

/// A button by title.
///
/// - Parameters:
///   - title: The title.
///   - sheet: The sheet.
/// - Returns: The button, or nil.
@MainActor
private func button(titled title: String, of sheet: NSWindow) -> NSButton? {
    guard let content = sheet.contentView else {
        return nil
    }
    return buttons(under: content).first { $0.title == title }
}

/// Everything a sheet says, its text fields run together.
///
/// - Parameter sheet: The sheet.
/// - Returns: The text.
@MainActor
private func text(of sheet: NSWindow) -> String {
    guard let content = sheet.contentView else {
        return ""
    }
    func walk(_ view: NSView) -> [String] {
        var strings: [String] = []
        if let field = view as? NSTextField {
            strings.append(field.stringValue)
        }
        for subview in view.subviews {
            strings += walk(subview)
        }
        return strings
    }
    return walk(content).joined(separator: " ")
}

/// A throwaway home directory for an install, set as the install's target for
/// as long as the scenario holds it.
///
/// A class so the scenario's `defer` restores the reader's home and removes the
/// directory whichever way the scenario ends.
@MainActor
private final class ScratchHome {
    let path = NSTemporaryDirectory() + "ubq-welcome-home-\(UUID().uuidString)"

    init() {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        WelcomeActions.homeDirectoryForTesting = path
    }

    func release() {
        WelcomeActions.homeDirectoryForTesting = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The contents of a file in it, or nil when there is none.
    func contents(of name: String) -> String? {
        try? String(contentsOfFile: (path as NSString).appendingPathComponent(name), encoding: .utf8)
    }

    /// Whether anything exists at a name in it.
    func has(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(name))
    }

    /// Writes a file into it.
    func write(_ contents: String, to name: String) {
        try? contents.write(toFile: (path as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Writes a file into it with owner-only permissions, and links another
    /// name to it.
    func writeLinked(_ contents: String, at target: String, linkedFrom link: String) {
        let targetPath = (path as NSString).appendingPathComponent(target)
        try? FileManager.default.createDirectory(
            atPath: (targetPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        write(contents, to: target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetPath)
        try? FileManager.default.createSymbolicLink(
            atPath: (path as NSString).appendingPathComponent(link),
            withDestinationPath: targetPath
        )
    }

    /// Whether a name in it is a symbolic link.
    func isLink(_ name: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).appendingPathComponent(name))
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// The permission bits of a file in it.
    func permissions(of name: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).appendingPathComponent(name))
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

/// The startup files an install creates when they are absent, relative to the
/// home.
private let createdStartupFiles = [".zshrc", ".bashrc"]

/// The startup files an install writes only when they exist, relative to the
/// home.
private let existingOnlyStartupFiles = [".bash_profile", ".config/fish/config.fish"]

/// What the reader's `.bashrc` holds before any install, which an install keeps.
private let readerBashrc = "export KEEP_THIS=1\n"

/// Where the reader's `.bashrc` link points, relative to the home, as a
/// dotfiles repository keeps it.
private let dotfilesBashrc = "dotfiles/bashrc"

/// The Settings window, when it is on screen.
@MainActor
private func visibleSettingsWindow() -> NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.windowController is SettingsWindowController }
}

/// The Connect window, when it is on screen.
@MainActor
private func visibleConnectWindow() -> NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.windowController is ConnectWindowController }
}

/// Registers the Welcome screen scenarios with the UI-test runner.
enum WelcomeActionScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // The consent gate, against the Swift shell. The Welcome screen's own
        // bytes are drawn in a Swift-shell window and its install button is
        // clicked; the question has to appear, refuse on Return, and stand
        // between the click and every file.
        UBUITestRegister("swift_shell_integration_confirm_gate") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let home = ScratchHome()
                defer { home.release() }
                home.writeLinked(readerBashrc, at: dotfilesBashrc, linkedFrom: ".bashrc")

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
                t.pump(0.3)

                surface.feed(welcomeScreenBytes(for: surface))
                // A forged link beneath the screen: the target of the install
                // button under a label that claims something harmless.
                surface.feed(Data("\u{1b}]8;;ubiquitty:action/shell-integration\u{1b}\\Open the docs\u{1b}]8;;\u{1b}\\\r\n".utf8))
                t.pump(0.3)
                let grid = surface.gridTextForTesting()
                guard let forged = cell(ofLabel: "Open the docs", in: grid),
                    let install = cell(ofTarget: "ubiquitty:action/shell-integration", in: surface, skipping: forged.row),
                    let settings = cell(ofTarget: "ubiquitty:action/settings", in: surface) // preferences-vocabulary-ok: the button's own target
                else {
                    t.expect(false, desc: "the Welcome screen and the forged link are on screen (grid: \(grid))")
                    return
                }

                // Nobody answers: the question refuses on Return.
                t.expect(click(surface, in: window, at: install), desc: "the install button has geometry to click")
                guard let question = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "a click on the install button asks before it writes")
                    return
                }
                let asked = text(of: question)
                t.expect(asked.contains("Install shell integration?"), desc: "the question says what it is for (\(asked))")
                t.expect(
                    asked.contains("adds a block to ~/.zshrc and ~/.bashrc that loads"),
                    desc: "the question names every file it would write (\(asked))"
                )
                t.expect(
                    !asked.contains("~/.bash_profile") && !asked.contains("config.fish"),
                    desc: "and none it would leave absent (\(asked))"
                )
                t.expect(
                    asked.contains("~/.zshrc does not exist yet and is created"),
                    desc: "and says which of them it would create (\(asked))"
                )
                guard let refusal = defaultButton(of: question) else {
                    t.expect(false, desc: "the question has a default button")
                    return
                }
                t.expect(refusal.title == "Cancel", desc: "Return answers Cancel (default is \(refusal.title))")
                refusal.performClick(nil)
                t.expect(waitForNoSheet(on: window, pumpingWith: t), desc: "Cancel dismisses the question")
                t.pump(0.2)
                t.expect(!home.has(".zshrc"), desc: "Cancel creates no startup file")
                t.expect(home.contents(of: ".bashrc") == readerBashrc, desc: "Cancel leaves the reader's .bashrc as it was")
                t.expect(!home.has(".terminfo"), desc: "Cancel installs no terminfo entry")

                // A forged label reaches the same question, and Cancel still
                // writes nothing: the label is not the consent.
                t.expect(click(surface, in: window, at: forged), desc: "the forged link has geometry to click")
                guard let forgedQuestion = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "a forged label on the install target still asks")
                    return
                }
                guard let forgedRefusal = defaultButton(of: forgedQuestion), forgedRefusal.title == "Cancel" else {
                    t.expect(false, desc: "the forged link's question refuses on Return")
                    return
                }
                forgedRefusal.performClick(nil)
                t.expect(waitForNoSheet(on: window, pumpingWith: t), desc: "Cancel dismisses the forged link's question")
                t.pump(0.2)
                t.expect(
                    !home.has(".zshrc") && home.contents(of: ".bashrc") == readerBashrc && !home.has(".terminfo"),
                    desc: "a forged link answered Cancel writes nothing"
                )

                // A button that only opens a window asks nothing and writes
                // nothing.
                t.expect(click(surface, in: window, at: settings), desc: "the Settings button has geometry to click")
                t.pump(0.3)
                t.expect(window.attachedSheet == nil, desc: "the Settings button asks no question")
                t.expect(
                    !home.has(".zshrc") && home.contents(of: ".bashrc") == readerBashrc && !home.has(".terminfo"),
                    desc: "a different action never reaches the install"
                )
                visibleSettingsWindow()?.close()

                // Install writes what the question named, and nothing it did not.
                t.expect(click(surface, in: window, at: install), desc: "the install button can be clicked again")
                guard let second = waitForSheet(on: window, pumpingWith: t),
                    let consent = button(titled: "Install", of: second)
                else {
                    t.expect(false, desc: "the second click asks again, with an Install button")
                    return
                }
                consent.performClick(nil)
                t.expect(waitForNoSheet(on: window, pumpingWith: t), desc: "Install dismisses the question")
                t.pump(0.3)
                let zshBlock = String(Ubiquitty.App.ShellIntegrationInstall.managedBlock(.zsh))
                let bashBlock = String(Ubiquitty.App.ShellIntegrationInstall.managedBlock(.bash))
                t.expect(home.contents(of: ".zshrc") == zshBlock + "\n", desc: "Install creates .zshrc holding the block alone")
                t.expect(
                    home.contents(of: ".bashrc") == readerBashrc + "\n" + bashBlock + "\n",
                    desc: "Install appends the block to the reader's .bashrc and keeps what was there"
                )
                t.expect(
                    home.isLink(".bashrc") && home.contents(of: dotfilesBashrc) == readerBashrc + "\n" + bashBlock + "\n",
                    desc: "the write goes through the reader's link to the file it names, and the link stays a link"
                )
                t.expect(home.permissions(of: dotfilesBashrc) == 0o600, desc: "the reader's file keeps its permissions")
                t.expect(
                    existingOnlyStartupFiles.allSatisfy { !home.has($0) },
                    desc: "Install creates no file whose absence another file stands in for"
                )
                t.expect(home.has(".terminfo"), desc: "Install compiles the terminfo entry under the same home")
                t.expect(
                    ShellIntegrationInstaller.plannedChanges(homeDirectory: home.path).isEmpty,
                    desc: "and a second install would write nothing"
                )
            }
        }

        // The Welcome window the app opens: its login shell starts as any
        // window's does, with its output held until the screen is written
        // into the pane once the pane has published its geometry. So the
        // shell, and only the shell, is the pane's foreground job and the
        // title's subject throughout; the icon arrives as an image with no
        // braille and nothing in the logo's rows; and the screen precedes the
        // shell's first prompt.
        UBUITestRegister("swift_welcome_window_draws_the_icon_through_its_shell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawnWelcomeScreen(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "the Welcome window opens with a surface")
                    return
                }
                defer { window.close() }
                // The login program execs the shell, as in every window; no
                // other job ever holds the pane.
                let shellName = welcomeShellName()
                let isShellOrLogin = { (name: String) in name.hasSuffix(shellName) || name.hasSuffix("login") }
                var foregrounds: Set<String> = []
                t.expect(
                    t.wait(
                        until: {
                            let name = surface.drive.foregroundProcessName
                            if !name.isEmpty { foregrounds.insert(name) }
                            return name.hasSuffix(shellName)
                        },
                        timeout: 5
                    ),
                    desc: "the shell becomes the foreground job (seen: \(foregrounds))"
                )
                t.expect(foregrounds.allSatisfy(isShellOrLogin), desc: "and nothing else held the pane (seen: \(foregrounds))")
                t.expect(!window.title.contains("cat"), desc: "the title is the shell's (\(window.title))")
                let hasImage = {
                    surface.drive.withTerminal { Ubiquitty.Rendering.hasImagePlacements($0, 0) } ?? false
                }
                t.expect(
                    t.wait(until: { hasImage() && surface.gridTextForTesting().components(separatedBy: "\n").contains("U") }, timeout: 10),
                    desc: "the screen arrives with the icon as an image"
                )
                t.expect(t.wait(until: { !surface.drive.isOpeningHoldActive }, timeout: 5), desc: "the hold lifts with the screen")
                // The shell's first output may scroll the screen up a row or
                // two; whatever it scrolled, every row above the name is the
                // logo's, and holds no text.
                let rows = surface.gridTextForTesting().components(separatedBy: "\n")
                let nameRow = rows.firstIndex(of: "U") ?? 0
                t.expect(
                    nameRow >= 6 && rows.prefix(nameRow).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                    desc: "the logo's rows hold no text (rows: \(rows.prefix(11)))"
                )
                t.expect(
                    !surface.gridTextForTesting().unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) },
                    desc: "no braille is drawn where the image is"
                )
                // The shell's prompt follows the screen: the cursor ends below
                // the buttons, on the row the shell's output took.
                // The action row may split on a narrow window; Accessibility
                // is the last action in either layout.
                let buttonsRow = rows.lastIndex { $0.contains("A") } ?? rows.count
                t.expect(
                    t.wait(
                        until: {
                            (surface.drive.withTerminal { terminal in terminal.screens.active.map { Int($0.pointee.cursorY) } ?? 0 } ?? 0)
                                > buttonsRow
                        },
                        timeout: 5
                    ),
                    desc: "the shell's first output lands after the screen"
                )
                t.expect(isShellOrLogin(surface.drive.foregroundProcessName), desc: "and the shell is still the foreground job")
                saveSurfaceFrame(surface, "welcome-window-icon")
            }
        }

        // A pane that never publishes its geometry still starts its shell:
        // the hold lasts only as long as the delivery's attempts, and the
        // screen it writes then draws the icon from the configured face's
        // nominal cell, ahead of the shell's prompt.
        UBUITestRegister("swift_welcome_window_without_geometry_still_draws_the_icon") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(inheritingDirectory: "", openingScreen: .held), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a held window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.5)
                t.expect(surface.drive.isOpeningHoldActive, desc: "the shell's output is held")
                t.expect(
                    t.wait(until: { surface.drive.foregroundProcessName.hasSuffix(welcomeShellName()) }, timeout: 5),
                    desc: "while the shell runs as the foreground job (\(surface.drive.foregroundProcessName))"
                )
                t.expect(
                    surface.gridTextForTesting().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    desc: "and nothing has reached the screen"
                )
                // A pane that never says it published: the nominal cell it
                // carries is all the delivery has when its attempts run out.
                WelcomeScreenDelivery.deliver(
                    to: shell,
                    attemptsLeft: 4,
                    paneFacts: { surface in
                        var pane = WelcomeScreenDelivery.pane(of: surface)
                        pane?.isGeometryPublished = false
                        return pane
                    }
                )
                let hasImage = {
                    surface.drive.withTerminal { Ubiquitty.Rendering.hasImagePlacements($0, 0) } ?? false
                }
                t.expect(
                    t.wait(until: { hasImage() && !surface.drive.isOpeningHoldActive }, timeout: 5),
                    desc: "after the attempts the icon is written and the hold lifts"
                )
                t.expect(
                    !surface.gridTextForTesting().unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) },
                    desc: "no braille anywhere"
                )
            }
        }

        // The three buttons that only open a window, in a Swift-shell window,
        // each reach the window their menu item opens.
        UBUITestRegister("swift_welcome_buttons_open_their_windows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let binary = ShareSessionSupport.localHostBinaryPath() else {
                    t.expect(false, desc: "the built app contains its host helper")
                    return
                }
                let home = "/tmp/ubq-welcome-buttons-" + String(UUID().uuidString.prefix(8))
                do {
                    try FileManager.default.createDirectory(
                        atPath: home,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    t.expect(false, desc: "private host directory: \(error)")
                    return
                }
                let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
                setenv("UBIQUITTY_HOME", home, 1)
                let daemon = Process()
                daemon.executableURL = URL(fileURLWithPath: binary)
                daemon.arguments = ["--daemon"]
                defer {
                    visibleSettingsWindow()?.close()
                    visibleConnectWindow()?.close()
                    if daemon.isRunning { daemon.terminate() }
                    if daemon.processIdentifier != 0 { daemon.waitUntilExit() }
                    if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
                    try? FileManager.default.removeItem(atPath: home)
                }
                do { try daemon.run() } catch {
                    t.expect(false, desc: "private daemon starts: \(error)")
                    return
                }
                guard
                    t.wait(
                        until: { ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).contains { $0.hasSuffix(".sock") } },
                        timeout: 15
                    )
                else {
                    t.expect(false, desc: "private daemon answers on its socket")
                    return
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer {
                    window.close()
                }
                visibleSettingsWindow()?.close()
                visibleConnectWindow()?.close()
                t.pump(0.3)
                surface.feed(welcomeScreenBytes(for: surface))
                t.pump(0.3)
                let grid = surface.gridTextForTesting()
                guard let settings = cell(ofTarget: "ubiquitty:action/settings", in: surface), // preferences-vocabulary-ok: the button's own target
                    let accessibility = cell(ofTarget: "ubiquitty:action/accessibility", in: surface),
                    let connect = cell(ofTarget: "ubiquitty:action/connect", in: surface)
                else {
                    t.expect(false, desc: "the Welcome screen's buttons are on screen (grid: \(grid))")
                    return
                }

                t.expect(visibleSettingsWindow() == nil, desc: "Settings is closed before the click")
                t.expect(click(surface, in: window, at: settings), desc: "the Settings button has geometry to click")
                t.expect(
                    t.wait(until: { visibleSettingsWindow()?.title == "Appearance" }, timeout: 5),
                    desc: "Settings opens on Appearance (title \(visibleSettingsWindow()?.title ?? "none"))"
                )
                t.expect(click(surface, in: window, at: accessibility), desc: "the Accessibility button has geometry to click")
                t.expect(
                    t.wait(until: { visibleSettingsWindow()?.title == "Accessibility" }, timeout: 5),
                    desc: "Settings moves to Accessibility (title \(visibleSettingsWindow()?.title ?? "none"))"
                )
                t.expect(visibleConnectWindow() == nil, desc: "Connect is closed before the click")
                t.expect(click(surface, in: window, at: connect), desc: "the Connect button has geometry to click")
                t.expect(t.wait(until: { visibleConnectWindow() != nil }, timeout: 5), desc: "Connect opens")
                t.expect(window.attachedSheet == nil, desc: "none of the three asks a question")
                surface.send("exit\n")
                t.expect(t.wait(until: { !window.isVisible }, timeout: 5), desc: "the test shell exits and closes its window")
            }
        }

        // An Objective-C-controller window opens links through the same opener, so
        // the same target there reaches the same question and the same install.
        UBUITestRegister("swift_classic_window_link_reaches_the_same_consent_gate") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let home = ScratchHome()
                defer { home.release() }
                guard let controller = t.newWindowRunning(nil), let window = controller.window else {
                    t.expect(false, desc: "a classic window opens")
                    return
                }
                t.sendText(
                    "printf '\\033]8;;ubiquitty:action/shell-integration\\033\\\\CLASSIC-LINK\\033]8;;\\033\\\\\\n'\r",
                    to: controller
                )
                t.expect(
                    t.wait(until: { t.gridText(of: controller).components(separatedBy: "\n").contains("CLASSIC-LINK") }, timeout: 6),
                    desc: "the link is printed on a row of its own"
                )
                let lines = t.gridText(of: controller).components(separatedBy: "\n")
                guard let row = lines.lastIndex(of: "CLASSIC-LINK") else {
                    t.expect(false, desc: "the printed link has a row")
                    return
                }

                t.click(inWindow: controller, atRow: Int32(row), column: 3, modifiers: [])
                guard let question = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "a click on the link in a classic window asks before it writes")
                    return
                }
                guard let refusal = defaultButton(of: question) else {
                    t.expect(false, desc: "the classic window's question has a default button")
                    return
                }
                t.expect(refusal.title == "Cancel", desc: "Return answers Cancel there too (default is \(refusal.title))")
                refusal.performClick(nil)
                t.expect(waitForNoSheet(on: window, pumpingWith: t), desc: "Cancel dismisses the question")
                t.pump(0.2)
                t.expect(
                    (createdStartupFiles + existingOnlyStartupFiles).allSatisfy { !home.has($0) } && !home.has(".terminfo"),
                    desc: "Cancel writes nothing"
                )

                t.click(inWindow: controller, atRow: Int32(row), column: 3, modifiers: [])
                guard let second = waitForSheet(on: window, pumpingWith: t),
                    let consent = button(titled: "Install", of: second)
                else {
                    t.expect(false, desc: "the second click asks again, with an Install button")
                    return
                }
                consent.performClick(nil)
                t.expect(waitForNoSheet(on: window, pumpingWith: t), desc: "Install dismisses the question")
                t.pump(0.3)
                t.expect(createdStartupFiles.allSatisfy { home.has($0) }, desc: "Install creates .zshrc and .bashrc")
                t.expect(
                    existingOnlyStartupFiles.allSatisfy { !home.has($0) },
                    desc: "and leaves .bash_profile and the fish configuration absent"
                )
            }
        }
    }
}
