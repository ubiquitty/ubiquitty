// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// LinkScenarios.swift — a click on a link in a Kit-hosted window opens it, a
// click on text that merely looks like one does not, and a scheme the build
// has not sanctioned never reaches a handler.
//
// The opener is replaced rather than watched: a scenario that launched a
// browser to prove a click worked would be worse than no scenario. What it
// asserts is the DECISION — which uri the terminal handed on, and when it
// handed on nothing.
//
// The three cases together are the point. An OSC 8 link opening on a plain
// click is only correct because a regex guess does not, and a refused scheme
// is only meaningful beside a case that opens: on its own, "nothing was
// opened" is what a broken build produces too.
//
// What the opener itself does is asserted separately, and there a real program
// runs: `ln -s` records the argument it was given as a symlink's destination,
// so a uri that arrived split, requoted, or shell-interpreted leaves either no
// link or a different one. Nothing else here launches anything — the workspace
// step is asked which url it would receive, and never told to open one.

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

/// A left click at a point in the window.
///
/// - Parameters:
///   - window: The window the point is in.
///   - point: The location, in window coordinates.
///   - modifiers: The modifiers held.
/// - Returns: The event, or nil when AppKit refuses it.
@MainActor
private func click(in window: NSWindow, at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

/// The window point at the start of a visible row.
///
/// Row 0's first cell, nudged into the middle of the cell so rounding cannot
/// put the click on a boundary.
///
/// - Parameters:
///   - surface: The surface whose grid is measured.
///   - window: The window to convert into.
///   - row: The visible row.
/// - Returns: The point, in window coordinates.
@MainActor
private func windowPoint(in surface: TerminalSurface, of window: NSWindow, row: Int, column: Int) -> CGPoint {
    guard let viewPoint = surface.viewPoint(forRow: row, column: column) else {
        return .zero
    }
    return surface.convert(viewPoint, to: nil)
}

/// Configures Core from `base` with its `[link_handlers]` replaced by one
/// handler, or by none when `scheme` is nil.
///
/// - Parameters:
///   - base: The document the scenario found live.
///   - scheme: The scheme to configure.
///   - command: The command template.
@MainActor
private func configureLinkHandler(over base: String, scheme: String? = nil, command: String = "") {
    var document = documentDroppingTables(base) { $0 == "[link_handlers]" }
    if let scheme {
        document += "\n[link_handlers]\n\(tomlQuoted(scheme)) = \(tomlQuoted(command))\n"
    }
    restoreLiveDocument(document)
}

/// Configures Core from `base` with its `[links]` table replaced by one naming
/// `lineHandler`, or by none when it is nil.
///
/// - Parameters:
///   - base: The document the scenario found live.
///   - lineHandler: The `line_handler` command template.
@MainActor
private func configureLineHandler(over base: String, _ lineHandler: String?) {
    var document = documentDroppingTables(base) { $0 == "[links]" || $0 == "[link_handlers]" }
    if let lineHandler {
        document += "\n[links]\nline_handler = \(tomlQuoted(lineHandler))\n"
    }
    restoreLiveDocument(document)
}

/// What a click on a link would come to, as text a failure prints.
///
/// - Parameter disposition: The decision.
/// - Returns: `open`, `reveal` or `run` and what each acts on, or `refuse`.
@MainActor
private func described(_ disposition: LinkOpener.Disposition) -> String {
    switch disposition {
    case .open(let url):
        return "open " + url.path
    case .reveal(let url):
        return "reveal " + url.path
    case .openAtLine(let argv, let otherwise):
        return "run " + argv.joined(separator: " ") + ", else " + described(otherwise)
    case .refuse:
        return "refuse"
    }
}

/// Waits for a launched handler to have done its work.
///
/// The handler is spawned and not waited on — a terminal does not block on a
/// browser — so the scenario pumps until the file it leaves behind appears.
///
/// - Parameters:
///   - path: The path the handler creates.
///   - t: The running scenario, for pumping.
/// - Returns: Whether it appeared.
@MainActor
private func waitForHandlerOutput(at path: String, pumpingWith t: UBUITestContext) -> Bool {
    for _ in 0..<40 {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            return true
        }
        t.pump(0.05)
    }
    return false
}

/// Registers the link scenarios with the UI-test runner.
enum LinkScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_printed_path_opens_the_file_it_names") { context in
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
                t.pump(0.3)
                // This fixture owns the printed rows; login output cannot overwrite them.
                surface.drive.stopIngest()

                // A real file, and a name for one that is not there. The
                // difference between them is the whole rule: a path candidate
                // becomes a link only where a file is.
                let directory = "/tmp/ubq-link-" + UUID().uuidString
                let present = directory + "/present.txt"
                let absent = directory + "/absent.txt"
                do {
                    try FileManager.default.createDirectory(
                        atPath: directory,
                        withIntermediateDirectories: true
                    )
                    try "hello".write(toFile: present, atomically: true, encoding: .utf8)
                } catch {
                    t.expect(false, desc: "the scenario could make a file to point at (\(error))")
                    return
                }
                defer { try? FileManager.default.removeItem(atPath: directory) }

                var opened: [String] = []
                surface.linkOpener = { opened.append($0) }
                guard present.utf8.count < Int(surface.drive.readSnapshot().columns) else {
                    t.expect(false, desc: "the fixture paths fit their separate terminal rows")
                    return
                }
                surface.feed(Data("\u{1b}[H\u{1b}[2J\(present)\r\n\(absent)\r\n".utf8))
                t.pump(0.3)
                let presentLink = surface.drive.resolveLink(viewOffset: surface.viewOffset, row: 0, column: 2, scope: .any)
                let absentLink = surface.drive.resolveLink(viewOffset: surface.viewOffset, row: 1, column: 2, scope: .any)
                t.expect(
                    presentLink?.isFilePath == true && presentLink?.uri == present,
                    desc:
                        "the present row resolves to its exact path (\(presentLink?.uri ?? "none"), offset \(surface.viewOffset), screen \(t.gridText(of: shell)))"
                )
                t.expect(
                    absentLink?.isFilePath == true && absentLink?.uri == absent,
                    desc: "the absent row resolves to its exact path (\(absentLink?.uri ?? "none"))"
                )

                guard let onPresent = surface.viewPoint(forRow: 0, column: 2),
                    let onAbsent = surface.viewPoint(forRow: 1, column: 2)
                else {
                    t.expect(false, desc: "the surface has measured cell geometry")
                    return
                }

                // Command held: a bare path is a guess the terminal made, and
                // it is spent on a click only when the reader asks by name.
                t.expect(
                    t.wait(
                        until: {
                            surface.updateLinkAffordance(atViewPoint: onPresent, isCommandHeld: true)
                            return surface.isShowingLinkAffordance
                        },
                        timeout: 4
                    ),
                    desc: "the path that names a file offers the hand"
                )
                t.expect(
                    surface.hoveredLinkTarget?.hasPrefix("file://") == true,
                    desc: "and the preview says the file URL a click would open"
                        + " (\(surface.hoveredLinkTarget ?? "none"))"
                )

                surface.updateLinkAffordance(atViewPoint: onAbsent, isCommandHeld: true)
                t.expect(
                    !surface.isShowingLinkAffordance,
                    desc: "a path naming no file offers nothing"
                )

                t.expect(
                    surface.openLink(atViewPoint: onPresent, isCommandHeld: true),
                    desc: "a Command-click on the present path admits its file check"
                )
                t.expect(surface.isFileLinkClickPendingForTesting, desc: "the click waits independently of hover")
                t.expect(
                    surface.openLink(atViewPoint: onAbsent, isCommandHeld: true),
                    desc: "a second click is consumed while the first is pending"
                )
                surface.clearLinkAffordance()
                t.expect(
                    t.wait(until: { !surface.isFileLinkClickPendingForTesting }, timeout: 4),
                    desc: "the first click finishes after hover is cleared"
                )
                t.expect(
                    opened.last?.hasSuffix("present.txt") == true,
                    desc: "and it opened the file the path named (\(opened.last ?? "none"))"
                )
                t.expect(
                    surface.openLink(atViewPoint: onAbsent, isCommandHeld: true),
                    desc: "a Command-click on the absent path admits its file check"
                )
                t.expect(
                    t.wait(until: { !surface.isFileLinkClickPendingForTesting }, timeout: 4),
                    desc: "the absent path's file check finishes"
                )
                t.expect(opened.count == 1, desc: "so exactly one open happened (\(opened.count))")
                t.expect(
                    surface.openedLinksForTesting.count == 1 && surface.openedLinksForTesting.last == opened.last,
                    desc: "only a real client-hook call is recorded as opened"
                )
            }
        }

        UBUITestRegister("swift_shell_click_opens_an_osc8_link") { context in
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

                var opened: [String] = []
                surface.linkOpener = { opened.append($0) }

                // Three rows, each a different kind of candidate. Fed to the
                // parser so the grid is exactly what this asserts about; a
                // shell echo would wrap the text in a prompt whose column
                // offsets the scenario would then have to guess.
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(Data("\u{1b}]8;;https://example.com/declared\u{1b}\\DECLARED\u{1b}]8;;\u{1b}\\\r\n".utf8))
                surface.feed(Data("https://example.com/guessed\r\n".utf8))
                surface.feed(Data("\u{1b}]8;;javascript:alert(1)\u{1b}\\HOSTILE\u{1b}]8;;\u{1b}\\\r\n".utf8))
                surface.feed(Data("\u{1b}]8;;ssh://build.example\u{1b}\\CONNECT\u{1b}]8;;\u{1b}\\\r\n".utf8))
                t.pump(0.3)

                // A file link naming this machine by the kernel's name, as ls
                // --hyperlink writes it, goes on to the opener; another
                // machine's is held back. The resolver's name can be another
                // spelling of this one, a .local or DNS name.
                let thisMachine = String(Ubiquitty.PAL.systemHostName())
                t.expect(
                    !surface.handleFileLink("file://\(thisMachine)/tmp/listing.txt", isPath: false),
                    desc: "a file link naming this machine by its kernel name reaches the opener (\(thisMachine))"
                )
                t.expect(
                    surface.handleFileLink("file://elsewhere.invalid/tmp/listing.txt", isPath: false),
                    desc: "and one naming another machine does not"
                )

                // Row 0: the program declared it. A plain click opens it.
                if let event = click(in: window, at: windowPoint(in: surface, of: window, row: 0, column: 2), modifiers: []) {
                    surface.mouseDown(with: event)
                    t.pump(0.1)
                }
                t.expect(
                    opened == ["https://example.com/declared"],
                    desc: "a plain click opens an OSC 8 link (opened \(opened))"
                )

                // Row 1: the terminal read it as a URL; the program never said
                // so. A plain click must not act on that reading.
                opened.removeAll()
                if let event = click(in: window, at: windowPoint(in: surface, of: window, row: 1, column: 2), modifiers: []) {
                    surface.mouseDown(with: event)
                    t.pump(0.1)
                }
                t.expect(
                    opened.isEmpty,
                    desc: "a plain click does not open a guessed link (opened \(opened))"
                )

                // The same guess with Command: the user asked, so it opens.
                if let event = click(
                    in: window,
                    at: windowPoint(in: surface, of: window, row: 1, column: 2),
                    modifiers: [.command]
                ) {
                    surface.mouseDown(with: event)
                    t.pump(0.1)
                }
                t.expect(
                    opened == ["https://example.com/guessed"],
                    desc: "Command opens a guessed link (opened \(opened))"
                )

                // Row 2: declared, and hostile. OSC 8 says the program meant
                // it, which is exactly why the scheme allowlist is a separate
                // gate — a program declaring a link is not a program being
                // trusted to name any handler on the machine.
                opened.removeAll()
                if let event = click(
                    in: window,
                    at: windowPoint(in: surface, of: window, row: 2, column: 2),
                    modifiers: [.command]
                ) {
                    surface.mouseDown(with: event)
                    t.pump(0.1)
                }
                t.expect(
                    opened.isEmpty,
                    desc: "a javascript: scheme is refused even declared and even with Command (opened \(opened))"
                )

                // Row 3: declared, and a connection to a host the program
                // named. A plain click leaves it alone; Command opens it.
                if let event = click(in: window, at: windowPoint(in: surface, of: window, row: 3, column: 2), modifiers: []) {
                    surface.mouseDown(with: event)
                    t.pump(0.1)
                }
                t.expect(
                    opened.isEmpty,
                    desc: "a plain click does not open a declared ssh link (opened \(opened))"
                )
                if let event = click(in: window, at: windowPoint(in: surface, of: window, row: 3, column: 2), modifiers: [.command]) {
                    surface.mouseDown(with: event)
                    t.pump(0.1)
                }
                t.expect(
                    opened == ["ssh://build.example"],
                    desc: "Command opens it (opened \(opened))"
                )
            }
        }

        UBUITestRegister("swift_shell_hovered_link_reaches_the_frame") { context in
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

                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(Data("\u{1b}]8;;https://example.com/underline\u{1b}\\UNDERLINE\u{1b}]8;;\u{1b}\\ plain\r\n".utf8))
                t.pump(0.3)

                // Nothing hovered: the frame carries no run.
                surface.needsDisplay = true
                t.pump(0.2)
                t.expect(
                    surface.lastFrameHoverRowLast < surface.lastFrameHoverRowFirst,
                    desc: "a frame with nothing hovered carries no run"
                )

                // Hover the link. The assertion is on the FRAME's converted
                // rows, not on the surface's field, so a run that was recorded
                // and never drawn reads the same as one never recorded.
                if let point = surface.viewPoint(forRow: 0, column: 2),
                    let moved = NSEvent.mouseEvent(
                        with: .mouseMoved,
                        location: surface.convert(point, to: nil),
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 0,
                        pressure: 0
                    )
                {
                    surface.mouseMoved(with: moved)
                }
                t.pump(0.3)
                t.expect(
                    surface.lastFrameHoverRowFirst == 0 && surface.lastFrameHoverRowLast == 0,
                    desc:
                        "the hovered run reaches the frame on visible row 0 (first \(surface.lastFrameHoverRowFirst), last \(surface.lastFrameHoverRowLast))"
                )
                t.expect(
                    surface.lastFrameHoverColumnLast >= surface.lastFrameHoverColumnFirst,
                    desc:
                        "and covers columns \(surface.lastFrameHoverColumnFirst)...\(surface.lastFrameHoverColumnLast)"
                )

                // Typing takes the pointer away, so the accent goes with it.
                if let press = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    characters: "x",
                    charactersIgnoringModifiers: "x",
                    isARepeat: false,
                    keyCode: 7
                ) {
                    _ = surface.sendKey(press, eventType: .Press)
                }
                t.pump(0.3)
                t.expect(
                    surface.lastFrameHoverRowLast < surface.lastFrameHoverRowFirst,
                    desc:
                        "typing drops the accent (first \(surface.lastFrameHoverRowFirst), last \(surface.lastFrameHoverRowLast))"
                )
            }
        }

        UBUITestRegister("swift_shell_hover_uses_the_captured_history_depth") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift window has a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                // The fixture controls publication lag; login output must not rewrite its rows.
                surface.drive.stopIngest()
                surface.feed(Data("\u{1b}[H\u{1b}[2Jhttps://example.com/top".utf8))
                t.pump(0.3)
                for _ in 0..<3 {
                    surface.needsDisplay = true
                    surface.updateLayer()
                }
                let history = surface.drive.readSnapshot().scrollbackCount
                // A drain can advance history before its coalesced snapshot is published.
                // The live rows are unchanged; only their absolute addresses advance.
                surface.drive.withTerminal { $0.scrollbackCount = history + 40 }
                defer {
                    surface.clearLinkAffordance()
                    surface.drive.withTerminal { $0.scrollbackCount = history }
                }
                guard let point = surface.viewPoint(forRow: 0, column: 10) else {
                    t.expect(false, desc: "the first row has measured geometry")
                    return
                }
                surface.updateLinkAffordance(atViewPoint: point, isCommandHeld: true)
                t.expect(surface.hoveredLinkTarget == "https://example.com/top", desc: "Command hover resolves the top-row link")
                t.expect(surface.drive.readSnapshot().scrollbackCount == history, desc: "the published history deliberately lags the model")
                for _ in 0..<3 {
                    surface.needsDisplay = true
                    surface.updateLayer()
                }
                t.expect(
                    surface.lastFrameHoverRowFirst == 0 && surface.lastFrameHoverRowLast == 0,
                    desc: "the underline stays on row zero when publication lags by forty rows (actual \(surface.lastFrameHoverRowFirst))"
                )
            }
        }

        // A link that names a line goes to the program the reader named for
        // opening a file at a line, and that program is handed the file the
        // click judged and the line, never the link as printed. `ln -s`
        // records the one argument it was given, so the scenario reads back
        // exactly what the handler received.
        UBUITestRegister("swift_shell_a_line_link_opens_in_the_line_handler") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                let files = FileManager.default
                // Under /var, a symbolic link, so the path the link spells and
                // the canonical one differ.
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ubq-line-links-\(UUID().uuidString)")
                    .standardizedFileURL
                do {
                    try files.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    t.expect(false, desc: "the scenario could make its scratch directory (\(error))")
                    return
                }
                defer { try? files.removeItem(at: directory) }
                let base = directory.resolvingSymlinksInPath()
                let script = directory.appendingPathComponent("build.sh")
                files.createFile(
                    atPath: script.path,
                    contents: Data("#!/bin/sh\necho built\n".utf8),
                    attributes: [.posixPermissions: 0o755]
                )
                let folder = directory.appendingPathComponent("folder")
                try? files.createDirectory(at: folder, withIntermediateDirectories: false)
                let canonicalScript = base.appendingPathComponent("build.sh").path
                let recorded = base.appendingPathComponent("received").path

                configureLineHandler(over: saved, "/bin/ln -s {path}:{line}:{column} \(recorded)")
                @MainActor
                func expectOutcome(_ uri: String, _ expected: String, _ what: String) {
                    let actual = described(LinkOpener.disposition(for: uri))
                    t.expect(actual == expected, desc: "\(what) (\(uri): \(actual))")
                }
                expectOutcome(
                    script.absoluteString + "#12:5",
                    "run /bin/ln -s \(canonicalScript):12:5 \(recorded), else reveal \(canonicalScript)",
                    "a script a search found goes to the line handler, which the opener would only reveal"
                )
                expectOutcome(
                    script.absoluteString + "#L12-L20",
                    "run /bin/ln -s \(canonicalScript):12:1 \(recorded), else reveal \(canonicalScript)",
                    "a range opens at its first line, and a missing column reads as 1"
                )
                expectOutcome(script.absoluteString, "reveal " + canonicalScript, "a link that names no line meets the ordinary rule")
                expectOutcome(
                    folder.absoluteString + "#12",
                    "open " + base.appendingPathComponent("folder").path,
                    "a line names nothing in a directory"
                )
                expectOutcome(script.absoluteString + "#run", "refuse", "a fragment that is not a line is still refused")
                expectOutcome(script.absoluteString + "?open#12", "refuse", "and so is a query")

                // The click's own path, with nothing standing in for the
                // launch: the handler runs and receives the canonical path.
                t.expect(LinkOpener.open(script.absoluteString + "#12:5", from: nil), desc: "the line handler reports the link as opened")
                t.expect(waitForHandlerOutput(at: recorded, pumpingWith: t), desc: "the line handler ran")
                let received = (try? files.destinationOfSymbolicLink(atPath: recorded)) ?? ""
                t.expect(
                    received == canonicalScript + ":12:5",
                    desc: "it received the checked path and the line as one argument (received \(received))"
                )

                // A handler named without a path is looked up on the app's
                // PATH. One found nowhere leaves the link to the rule it would
                // meet with no handler, rather than taking the click and doing
                // nothing; one found there starts. The workspace step is stood
                // in for, so the fallback is recorded rather than shown in
                // Finder.
                var handed: [String] = []
                let previousWorkspace = LinkOpener.workspaceForTesting
                LinkOpener.workspaceForTesting = { handed.append(described($0)) }
                defer { LinkOpener.workspaceForTesting = previousWorkspace }
                configureLineHandler(over: saved, "ubiquitty-no-such-editor-\(UUID().uuidString) --goto {path}:{line}:{column}")
                t.expect(
                    LinkOpener.open(script.absoluteString + "#12:5", from: nil),
                    desc: "a click on a line link whose handler is on no PATH directory is still handled"
                )
                t.expect(
                    t.wait(until: { handed == ["reveal " + canonicalScript] }, timeout: 4),
                    desc: "by what the link does with no line handler (\(handed))"
                )
                handed.removeAll()
                let foundOnPath = base.appendingPathComponent("received-bare").path
                configureLineHandler(over: saved, "ln -s {path}:{line} \(foundOnPath)")
                t.expect(LinkOpener.open(script.absoluteString + "#7", from: nil), desc: "a handler named by its bare name starts")
                t.expect(waitForHandlerOutput(at: foundOnPath, pumpingWith: t), desc: "it was found on PATH and ran")
                t.expect(handed.isEmpty, desc: "and nothing fell back to the workspace (\(handed))")
            }
        }

        UBUITestRegister("swift_shell_link_handler_receives_the_uri_whole") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let directory = NSTemporaryDirectory() + "ub-link-handler-\(ProcessInfo.processInfo.processIdentifier)"
                try? FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    try? FileManager.default.removeItem(atPath: directory)
                    t.restoreConfiguration(saved)
                }

                // The uri carries a space and a semicolon on purpose: a
                // handler that received it split would be handed three
                // operands, and one that received it through a shell would
                // have run the second half.
                let uri = "https://example.com/a b; touch \(directory)/injected"
                let recorded = directory + "/opened"
                configureLinkHandler(over: saved, scheme: "https", command: "/bin/ln -s %s \(recorded)")

                t.expect(
                    LinkOpener.open(uri, from: nil),
                    desc: "a configured handler reports the link as opened"
                )
                t.expect(
                    waitForHandlerOutput(at: recorded, pumpingWith: t),
                    desc: "the handler ran and left its link behind"
                )
                let received = (try? FileManager.default.destinationOfSymbolicLink(atPath: recorded)) ?? ""
                t.expect(
                    received == uri,
                    desc: "the handler received the uri whole (received \(received))"
                )
                t.expect(
                    !FileManager.default.fileExists(atPath: directory + "/injected"),
                    desc: "and nothing in it ran as a command"
                )

                // A configured handler is consent to a scheme, not to a target
                // its reader cannot read: a hidden character is refused before
                // the handler is asked.
                let hidden = directory + "/hidden"
                configureLinkHandler(over: saved, scheme: "https", command: "/bin/ln -s %s \(hidden)")
                var handed: [LinkOpener.Disposition] = []
                let previousWorkspace = LinkOpener.workspaceForTesting
                LinkOpener.workspaceForTesting = { handed.append($0) }
                t.expect(
                    !LinkOpener.open("https://example.com/\u{202E}gpj.exe", from: nil),
                    desc: "a target with a right-to-left override is refused though a handler is configured"
                )
                t.pump(0.2)
                t.expect(
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: hidden)) == nil,
                    desc: "and the configured handler never ran"
                )
                t.expect(handed == [.refuse], desc: "the refusal is the one decision reached (\(handed))")
                // The plate reads the target in the click's order, so the
                // refusal shows on it though a handler is configured.
                t.expect(
                    LinkOpener.previewText(forTarget: "https://example.com/\u{202E}gpj.exe")
                        == LinkOpener.refusalMarker + "https://example.com/\\u{202E}gpj.exe",
                    desc: "and the plate says a click will not open it, the handler notwithstanding"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: "https://example.com/plain") == "https://example.com/plain",
                    desc: "while a target the handler takes is shown as written"
                )

                // A handler whose program is on no PATH directory was never
                // started, so the link opens the way it would with none.
                handed.removeAll()
                configureLinkHandler(
                    over: saved,
                    scheme: "https",
                    command: "ubiquitty-no-such-browser-\(UUID().uuidString) %s"
                )
                t.expect(
                    LinkOpener.open("https://example.com/plain", from: nil),
                    desc: "a click whose handler is missing is still handled"
                )
                LinkOpener.workspaceForTesting = previousWorkspace
                t.expect(
                    handed.map(described) == ["open /plain"],
                    desc: "by the workspace, as with no handler (\(handed.map(described)))"
                )

                // The Welcome screen's namespace stops before any of that: a
                // configured handler must not be reachable by a link that was
                // never a link to anywhere, and a name no button carries is
                // still in the namespace, so it is consumed doing nothing.
                let second = directory + "/second"
                configureLinkHandler(over: saved, scheme: "ubiquitty", command: "/bin/ln -s %s \(second)")
                t.expect(
                    LinkOpener.open("ubiquitty:action/no-such-action", from: nil),
                    desc: "a target in the action namespace reports the link as opened"
                )
                t.pump(0.2)
                t.expect(
                    !FileManager.default.fileExists(atPath: second),
                    desc: "and no handler ran for it"
                )
            }
        }

        UBUITestRegister("swift_shell_workspace_open_is_gated_and_encoded") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                configureLinkHandler(over: saved)
                // Which url the workspace would receive is the whole question,
                // and answering it launches nothing.
                t.expect(
                    LinkOpener.launchableURL(for: "javascript:alert(1)") == nil,
                    desc: "a scheme off the allowlist reaches no opener"
                )
                t.expect(
                    LinkOpener.launchableURL(for: "https://example.com/plain") != nil,
                    desc: "and an allowlisted one does"
                )

                // A link a program printed is bytes, not a parsed URL. This
                // system's parser encodes most bytes it dislikes on its own,
                // and a space in the AUTHORITY is one it still refuses — so it
                // is the case that reaches the retry here. On the oldest system
                // this build runs on, the parser refuses far more than that,
                // and the retry is what makes those links open at all.
                let spaced = LinkOpener.launchableURL(for: "https://exa mple.com/x")
                t.expect(
                    spaced?.absoluteString == "https://exa%20mple.com/x",
                    desc: "a uri NSURL refuses verbatim is encoded and retried (got \(String(describing: spaced)))"
                )
                t.expect(
                    LinkOpener.launchableURL(for: "javascript:alert(1 2)") == nil,
                    desc: "and the encoding does not smuggle a refused scheme past the allowlist"
                )
            }
        }

        // A file link is a path a program chose, and the workspace runs what
        // it is handed when that is a program. Each target below is a real
        // object in a scratch directory, so what is asserted is the decision
        // over what the filesystem reports, and nothing is opened or revealed:
        // the opener's own path is driven with its workspace step replaced.
        UBUITestRegister("swift_shell_a_file_link_opens_only_what_cannot_run") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                configureLineHandler(over: saved, nil)
                let files = FileManager.default
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ubq-file-links-\(UUID().uuidString)")
                    .standardizedFileURL
                do {
                    try files.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    t.expect(false, desc: "the scenario could make its scratch directory (\(error))")
                    return
                }
                defer { try? files.removeItem(at: directory) }
                // The scratch directory sits under /var, which is a symbolic
                // link; the decision reports the path it resolved to.
                let base = directory.resolvingSymlinksInPath()
                func make(_ name: String, _ contents: String, permissions: Int) -> URL {
                    let url = base.appendingPathComponent(name)
                    files.createFile(atPath: url.path, contents: Data(contents.utf8), attributes: [.posixPermissions: permissions])
                    return url
                }
                let notes = make("notes.txt", "notes\n", permissions: 0o644)
                let runnable = make("run.txt", "notes\n", permissions: 0o755)
                let tool = make("tool", "#!/bin/sh\necho hello\n", permissions: 0o755)
                let command = make("hello.command", "#!/bin/sh\necho hello\n", permissions: 0o644)
                let folder = base.appendingPathComponent("folder")
                let bundle = base.appendingPathComponent("Thing.app")
                let disguise = base.appendingPathComponent("innocent.txt")
                let pipe = base.appendingPathComponent("pipe.txt")
                // Two Finder aliases with text names, written as Finder writes
                // one. Launch Services opens an alias's target, so the first
                // goes to Terminal and the second launches Calculator.
                let alias = base.appendingPathComponent("alias.txt")
                let appAlias = base.appendingPathComponent("Calculator.txt")
                // A text file whose Open With choice names Terminal, which
                // Launch Services then opens it in instead of a text editor.
                let bound = make("bound.txt", "echo hello\n", permissions: 0o644)
                do {
                    try files.createDirectory(at: folder, withIntermediateDirectories: false)
                    try files.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                    try files.createSymbolicLink(at: disguise, withDestinationURL: command)
                    try URL.writeBookmarkData(
                        command.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
                        to: alias
                    )
                    try URL.writeBookmarkData(
                        URL(fileURLWithPath: "/System/Applications/Calculator.app")
                            .bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
                        to: appAlias
                    )
                    let openWith: [String: Any] = [
                        "bundleidentifier": "com.apple.Terminal",
                        "path": "/System/Applications/Utilities/Terminal.app",
                        "version": 0,
                    ]
                    let choice = try PropertyListSerialization.data(fromPropertyList: openWith, format: .binary, options: 0)
                    let didSetChoice = choice.withUnsafeBytes {
                        setxattr(bound.path, "com.apple.LaunchServices.OpenWith", $0.baseAddress, $0.count, 0, 0) == 0
                    }
                    t.expect(didSetChoice, desc: "the scenario could give a file its own Open With choice")
                } catch {
                    t.expect(false, desc: "the scenario could make its fixtures (\(error))")
                    return
                }
                t.expect(mkfifo(pipe.path, 0o644) == 0, desc: "the scenario could make a pipe")

                @MainActor
                func expectOutcome(_ uri: String, _ expected: String, _ what: String) {
                    let actual = described(LinkOpener.disposition(for: uri))
                    t.expect(actual == expected, desc: "\(what) (\(uri): \(actual))")
                }

                expectOutcome(
                    "file:///System/Applications/Calculator.app",
                    "reveal /System/Applications/Calculator.app",
                    "an application is shown in Finder, never launched"
                )
                expectOutcome(
                    command.absoluteString,
                    "reveal " + command.path,
                    "a .command file is shown, though nothing marks it executable"
                )
                expectOutcome(
                    runnable.absoluteString,
                    "open " + runnable.path,
                    "a stray execute bit on a file the system types as text does not make it reveal-only"
                )
                expectOutcome(tool.absoluteString, "reveal " + tool.path, "a script with no extension is shown")
                expectOutcome(bundle.absoluteString, "reveal " + bundle.path, "a bundle is shown")
                expectOutcome(disguise.absoluteString, "reveal " + command.path, "a symbolic link is judged by what it points at")
                expectOutcome(alias.absoluteString, "reveal " + alias.path, "an alias to a .command is shown, whatever its name says")
                expectOutcome(appAlias.absoluteString, "reveal " + appAlias.path, "and so is an alias to an application")
                expectOutcome(bound.absoluteString, "reveal " + bound.path, "a file that names its own opener is shown")
                expectOutcome(notes.absoluteString, "open " + notes.path, "a document opens")
                expectOutcome(folder.absoluteString, "open " + folder.path, "a directory opens")
                // A folder whose name another program claims: Mail opens a
                // .mbox, and nothing opens a .framework that is not a bundle.
                for name in ["inbox.mbox", "Thing.framework"] {
                    let claimed = base.appendingPathComponent(name)
                    try? files.createDirectory(at: claimed, withIntermediateDirectories: false)
                    expectOutcome(claimed.absoluteString, "reveal " + claimed.path, "a folder Finder does not open, \(name), is shown")
                }
                // Ordinary files the display-only rule reaches: names a
                // repository holds with no extension, and video.
                for name in ["README", "Makefile", ".gitignore", ".env", "clip.mp4"] {
                    let file = make(name, "plain\n", permissions: 0o644)
                    expectOutcome(file.absoluteString, "open " + file.path, "an ordinary \(name) opens")
                }
                // Audio is shown in Finder: Music opens it, and imports what
                // it opens into the reader's library.
                for name in ["song.mp3", "voice.m4a", "sound.wav"] {
                    let file = make(name, "plain\n", permissions: 0o644)
                    expectOutcome(file.absoluteString, "reveal " + file.path, "\(name) is shown, not handed to Music")
                }
                expectOutcome("file:" + notes.path, "open " + notes.path, "file:/path with no authority opens")
                let feed = make("pom.xml", "<project/>\n", permissions: 0o644)
                expectOutcome(feed.absoluteString, "reveal " + feed.path, "XML, which Safari runs as XHTML, is shown")
                expectOutcome(
                    URL(fileURLWithPath: folder.path + "/../notes.txt").absoluteString,
                    "open " + notes.path,
                    "dot segments are collapsed before the file is judged"
                )
                expectOutcome(pipe.absoluteString, "refuse", "a pipe is refused")
                expectOutcome(base.appendingPathComponent("missing.txt").absoluteString, "refuse", "a missing file is refused")
                expectOutcome(notes.absoluteString + "?open", "refuse", "a query is refused")
                expectOutcome(notes.absoluteString + "#run", "refuse", "a fragment is refused")
                expectOutcome(
                    notes.absoluteString + "#L12-L20",
                    "open " + notes.path,
                    "a fragment that names a line opens the file when no line handler is configured"
                )
                expectOutcome(command.absoluteString + "#12", "reveal " + command.path, "and meets the same rule as the file")
                expectOutcome("file://localhost" + notes.path, "open " + notes.path, "localhost is this machine")
                expectOutcome("file://elsewhere.invalid" + notes.path, "refuse", "another machine's name is refused")
                var host = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
                if gethostname(&host, host.count - 1) == 0 {
                    expectOutcome(
                        "file://" + String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + notes.path,
                        "open " + notes.path,
                        "this machine's own name, as ls --hyperlink writes it, opens"
                    )
                }
                expectOutcome(
                    "file:///System/Applications/\u{200B}Calculator.app",
                    "refuse",
                    "a zero-width space hides part of the target"
                )
                expectOutcome("https://example.com/\u{202E}gpj.exe", "refuse", "a right-to-left override reorders it")
                // A joiner spells a name rather than hiding part of one, so a
                // target written with one, raw as a program prints it, opens.
                let joined = make("\u{1F468}\u{200D}\u{1F4BB} notes.txt", "notes\n", permissions: 0o644)
                expectOutcome("file://" + joined.path, "open " + joined.path, "an emoji ZWJ file name opens")
                let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
                expectOutcome(
                    "https://fa.wikipedia.org/wiki/" + persian,
                    "open /wiki/" + persian,
                    "a Persian page written with a non-joiner opens"
                )
                expectOutcome("https://example.com/plain", "open /plain", "an ordinary web link opens")
                expectOutcome("javascript:alert(1)", "refuse", "a scheme off the allowlist is refused")

                // The opener a click calls hands the workspace step exactly
                // that decision. Its step is replaced here, so the application
                // below is shown to the recorder and launched by nobody.
                var handed: [String] = []
                let previousWorkspace = LinkOpener.workspaceForTesting
                LinkOpener.workspaceForTesting = { handed.append(described($0)) }
                defer { LinkOpener.workspaceForTesting = previousWorkspace }
                t.expect(
                    LinkOpener.open("file:///System/Applications/Calculator.app", from: nil),
                    desc: "inspection of an application is admitted"
                )
                t.expect(t.wait(until: { handed.count == 1 }, timeout: 4), desc: "the application is shown in Finder after inspection")
                t.expect(LinkOpener.open(alias.absoluteString, from: nil), desc: "and so does showing an alias")
                t.expect(t.wait(until: { handed.count == 2 }, timeout: 4), desc: "the alias is shown after inspection")
                t.expect(LinkOpener.open(notes.absoluteString, from: nil), desc: "a document is handled")
                t.expect(t.wait(until: { handed.count == 3 }, timeout: 4), desc: "the document is opened after inspection")
                t.expect(
                    !LinkOpener.open("file:///System/Applications/\u{200B}Calculator.app", from: nil),
                    desc: "a refused link reports nothing opened"
                )
                let expectedHanded = [
                    "reveal /System/Applications/Calculator.app", "reveal " + alias.path, "open " + notes.path, "refuse",
                ]
                t.expect(handed == expectedHanded, desc: "the opener acts on the decision and nothing else (\(handed))")

                // The plate reads a target the way the click does: through
                // Core's reading of the URI at once, and through the click's
                // own canonicalisation off the main thread, so it says what the
                // click would judge and cannot be made to hide part of it.
                let refused = LinkOpener.refusalMarker
                t.expect(
                    LinkOpener.previewText(forTarget: disguise.absoluteString) == disguise.path,
                    desc: "the plate shows the path a link spells before anything is resolved"
                )
                t.expect(
                    LinkOpener.resolvedPreviewText(forPath: disguise.path) == command.path,
                    desc: "and, resolved, the file a symbolic link points at"
                )
                // Resolving a path whose last component is missing still
                // resolves the links above it, as a click resolves them.
                let missing = base.appendingPathComponent("missing.txt")
                t.expect(
                    LinkOpener.resolvedPreviewText(forPath: missing.path)
                        == refused + missing.standardizedFileURL.resolvingSymlinksInPath().path,
                    desc: "a path with nothing there says a click will not open it"
                )
                let encodedSlash = "file://" + base.path + "/folder%2F..%2Fnotes.txt"
                t.expect(
                    LinkOpener.previewText(forTarget: encodedSlash) == notes.path,
                    desc: "an encoded slash is read as the click reads it"
                )
                expectOutcome(encodedSlash, "open " + notes.path, "and the click opens that file")
                t.expect(
                    LinkOpener.previewText(forTarget: notes.absoluteString + "#L12") == notes.path,
                    desc: "a line link shows the file it opens"
                )
                let foreign = "file://elsewhere.invalid" + notes.path
                t.expect(
                    LinkOpener.previewText(forTarget: foreign) == refused + foreign,
                    desc: "another machine's file says a click will not open it"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: notes.absoluteString + "#run") == refused + notes.absoluteString + "#run",
                    desc: "and so does a fragment that names no line"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: "https://example.com/\u{202E}gpj.exe")
                        == refused + "https://example.com/\\u{202E}gpj.exe",
                    desc: "and a character that would reorder it, spelled out"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: "https://example.com/plain") == "https://example.com/plain",
                    desc: "an ordinary web link is shown as written"
                )
                for path in ["~/src/notes.txt", "/srv/project/notes.txt"] {
                    t.expect(
                        LinkOpener.previewText(forTarget: path, onHost: "build-box", isPath: true) == path,
                        desc: "a typed host path stays on the host without local home expansion (\(path))"
                    )
                    t.expect(
                        LinkOpener.previewText(forTarget: path, onHost: "", isPath: true) == refused + path,
                        desc: "an unknown host does not resolve its bare path on this machine"
                    )
                    t.expect(
                        LinkOpener.previewText(forTarget: path, onHost: "build-box") == refused + path,
                        desc: "a declared invalid URI is not inferred to be a bare file path"
                    )
                }
                // A joiner between two ASCII characters joins nothing and
                // draws as nothing, so the plate spells it out: the file and
                // the page it names are not the ones that read the same
                // without it. The click still opens what it names.
                t.expect(
                    LinkOpener.previewText(forTarget: "file:///Users/me/notes\u{200D}.txt") == "/Users/me/notes\\u{200D}.txt",
                    desc: "a joiner that joins nothing in a path is spelled out"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: "file:///Users/me/notes\u{200D}.txt#L12") == "/Users/me/notes\\u{200D}.txt",
                    desc: "and in a line link's path"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: "https://github.com/org/re\u{200D}po") == "https://github.com/org/re\\u{200D}po",
                    desc: "and in a web address"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: "file://" + joined.path) == joined.path,
                    desc: "while the joiner an emoji is spelled with is shown as written"
                )
                t.expect(
                    LinkOpener.previewText(forTarget: "https://fa.wikipedia.org/wiki/" + persian)
                        == "https://fa.wikipedia.org/wiki/" + persian,
                    desc: "and so is the non-joiner inside a Persian word"
                )
            }
        }

        // FAT and exFAT keep no permissions and report every file as
        // executable, so the execute bit says nothing there: a file whose
        // name the display-only rule passes opens from such a volume, where
        // the same file with the bit set is revealed on one that keeps them.
        // The volumes are disk images formatted here and mounted out of
        // Finder's sight.
        UBUITestRegister("swift_shell_a_file_on_a_volume_without_permissions_opens") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let files = FileManager.default
                let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ubq-volume-permissions-\(UUID().uuidString)")
                    .resolvingSymlinksInPath()
                do {
                    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
                } catch {
                    t.expect(false, desc: "the scenario could make its scratch directory (\(error))")
                    return
                }
                defer { try? files.removeItem(at: scratch) }
                func run(_ tool: String, _ arguments: [String]) -> Int32 {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: tool)
                    process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                    } catch {
                        return -1
                    }
                    process.waitUntilExit()
                    return process.terminationStatus
                }

                // A `.conf` has no display-only type, so its execute bit
                // counts where the volume keeps one.
                let kept = scratch.appendingPathComponent("settings.conf")
                files.createFile(atPath: kept.path, contents: Data("key = 1\n".utf8), attributes: [.posixPermissions: 0o755])
                let keptOutcome = described(LinkOpener.disposition(for: kept.absoluteString))
                t.expect(
                    keptOutcome == "reveal " + kept.path,
                    desc: "an executable .conf on a volume that keeps permissions is shown (\(keptOutcome))"
                )

                for format in ["MS-DOS", "ExFAT"] {
                    let image = scratch.appendingPathComponent("\(format).dmg")
                    let mountPoint = scratch.appendingPathComponent("\(format)-volume")
                    try? files.createDirectory(at: mountPoint, withIntermediateDirectories: false)
                    let created = run(
                        "/usr/bin/hdiutil",
                        ["create", "-size", "8m", "-fs", format, "-volname", "UBQPERM", "-o", image.path]
                    )
                    let attached =
                        created == 0
                        ? run(
                            "/usr/bin/hdiutil",
                            ["attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path, image.path]
                        )
                        : created
                    guard attached == 0 else {
                        t.expect(false, desc: "a \(format) disk image could be made and mounted (hdiutil \(attached))")
                        continue
                    }
                    defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path]) }
                    let loose = mountPoint.appendingPathComponent("settings.conf")
                    files.createFile(atPath: loose.path, contents: Data("key = 1\n".utf8))
                    let isReportedExecutable = (try? loose.resourceValues(forKeys: [.isExecutableKey]))?.isExecutable == true
                    t.expect(isReportedExecutable, desc: "\(format) reports a file it holds as executable")
                    let looseOutcome = described(LinkOpener.disposition(for: loose.absoluteString))
                    t.expect(
                        looseOutcome == "open " + loose.path,
                        desc: "the same .conf on \(format), which keeps no permissions, opens (\(looseOutcome))"
                    )
                    // The volume rule discharges the bit, not the name: a
                    // script there is still shown.
                    let script = mountPoint.appendingPathComponent("run.sh")
                    files.createFile(atPath: script.path, contents: Data("#!/bin/sh\necho hello\n".utf8))
                    let scriptOutcome = described(LinkOpener.disposition(for: script.absoluteString))
                    t.expect(
                        scriptOutcome == "reveal " + script.path,
                        desc: "and a script on \(format) is still shown (\(scriptOutcome))"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_hovering_a_link_shows_the_hand") { context in
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

                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(Data("\u{1b}]8;;https://example.com/hover\u{1b}\\HOVER\u{1b}]8;;\u{1b}\\ plain text\r\n".utf8))
                t.pump(0.3)

                t.expect(
                    surface.pointerIsOverOpenableLink(
                        atViewPoint: surface.viewPoint(forRow: 0, column: 2) ?? .zero,
                        isCommandHeld: false
                    ),
                    desc: "the pointer over the link would open something"
                )
                t.expect(
                    !surface.pointerIsOverOpenableLink(
                        atViewPoint: surface.viewPoint(forRow: 0, column: 20) ?? .zero,
                        isCommandHeld: false
                    ),
                    desc: "and over the plain text beside it, nothing would open"
                )

                // Text that merely reads like a URL is a guess the terminal
                // made, not something the program declared. A bare hover does
                // not reveal it — and does not scan for it either, which is
                // what keeps an ordinary pointer move over prose from sweeping
                // the row. Command is how a reader asks for the guess by name.
                surface.feed(Data("\u{1b}[H\u{1b}[2Jsee https://example.com/guess now\r\n".utf8))
                t.pump(0.3)
                let onGuess = surface.viewPoint(forRow: 0, column: 8) ?? .zero
                let sweepsBefore = surface.drive.wideLinkScanCount
                t.expect(
                    !surface.pointerIsOverOpenableLink(atViewPoint: onGuess, isCommandHeld: false),
                    desc: "a bare hover over a bare URL reveals nothing"
                )
                // And costs nothing to answer with: the reveal policy would
                // reject the guess whatever the scan found, so what separates
                // the cheap scope from the wide one is the work, and the work
                // is what this counts.
                t.expect(
                    surface.drive.wideLinkScanCount == sweepsBefore,
                    desc: "and swept no row to say so"
                        + " (\(surface.drive.wideLinkScanCount) sweeps, was \(sweepsBefore))"
                )
                t.expect(
                    surface.pointerIsOverOpenableLink(atViewPoint: onGuess, isCommandHeld: true),
                    desc: "and Command asks for the guess by name"
                )
                t.expect(
                    surface.drive.wideLinkScanCount > sweepsBefore,
                    desc: "which is the hover that pays for the sweep"
                )
            }
        }

        UBUITestRegister("swift_shell_file_click_inspection_does_not_block_or_outlive_its_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                configureLineHandler(over: saved, nil)
                let file = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ubq-click-inspection-\(UUID().uuidString).txt")
                guard FileManager.default.createFile(atPath: file.path, contents: Data("notes\n".utf8)) else {
                    t.expect(false, desc: "the scenario could write its local document")
                    return
                }
                defer { try? FileManager.default.removeItem(at: file) }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a source window opens")
                    return
                }
                defer { window.close() }
                var handed: [String] = []
                let previousWorkspace = LinkOpener.workspaceForTesting
                LinkOpener.workspaceForTesting = { handed.append(described($0)) }
                defer { LinkOpener.workspaceForTesting = previousWorkspace }

                let release = LinkOpener.holdFileInspectionForTesting()
                defer { release() }
                t.expect(LinkOpener.open(file.absoluteString, from: window), desc: "the first file click is admitted")
                t.expect(handed.isEmpty, desc: "a blocked inspection has not launched or revealed anything")
                var refusedRepeats = 0
                for _ in 0..<64 where !LinkOpener.open(file.absoluteString, from: window) {
                    refusedRepeats += 1
                }
                t.expect(refusedRepeats == 64, desc: "repeated clicks cannot accumulate filesystem work")
                t.expect(LinkOpener.admittedFileInspectionCountForTesting == 1, desc: "only one file inspection is retained")
                t.expect(handed == Array(repeating: "refuse", count: 64), desc: "busy clicks are explicitly refused")
                handed.removeAll()

                var mainActorAdvanced = false
                DispatchQueue.main.async { mainActorAdvanced = true }
                t.expect(
                    t.wait(until: { mainActorAdvanced }, timeout: 1),
                    desc: "the main run loop continues while filesystem inspection is held"
                )
                t.expect(
                    LinkOpener.open("https://example.com/available", from: window),
                    desc: "web links still open while a file is pending"
                )
                t.expect(handed == ["open /available"], desc: "a non-file link does not wait for the filesystem worker")
                handed.removeAll()
                window.close()
                release()
                LinkOpener.drainFileInspectionForTesting()
                t.expect(
                    t.wait(until: { LinkOpener.admittedFileInspectionCountForTesting == 0 }, timeout: 4),
                    desc: "the canceled window's admitted lookup eventually retires"
                )
                t.expect(handed.isEmpty, desc: "a late answer from the closed window launches nothing")

                t.expect(LinkOpener.open(file.absoluteString, from: nil), desc: "the next file click is admitted after retirement")
                let expected = "open " + file.resolvingSymlinksInPath().path
                t.expect(
                    t.wait(until: { handed == [expected] }, timeout: 4),
                    desc: "an uncanceled inspection still opens the checked document (\(handed))"
                )

                // A configured file handler precedes built-in URI validation,
                // but its executable lookup uses the same bounded worker.
                handed.removeAll()
                let recorded = file.path + ".configured"
                defer { try? FileManager.default.removeItem(atPath: recorded) }
                let configuredURI = "file://elsewhere.invalid/srv/notes.txt?query#fragment"
                configureLinkHandler(over: saved, scheme: "file", command: "ln -s %s \(recorded)")
                let releaseHandler = LinkOpener.holdFileInspectionForTesting()
                defer { releaseHandler() }
                t.expect(LinkOpener.open(configuredURI, from: nil), desc: "configured file handler preparation is admitted")
                t.expect(
                    LinkOpener.admittedFileInspectionCountForTesting == 1,
                    desc: "the configured file handler occupies the bounded worker"
                )
                t.pump(0.1)
                t.expect(
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: recorded)) == nil && handed.isEmpty,
                    desc: "configured file preparation does not launch or fall back while its worker is held"
                )
                releaseHandler()
                t.expect(waitForHandlerOutput(at: recorded, pumpingWith: t), desc: "the prepared file handler starts after release")
                t.expect(
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: recorded)) == configuredURI && handed.isEmpty,
                    desc: "the configured handler receives the entire URI before built-in file validation"
                )
                configureLinkHandler(over: saved, scheme: "file", command: "ubiquitty-no-such-file-handler-\(UUID().uuidString) %s")
                t.expect(LinkOpener.open(file.absoluteString, from: nil), desc: "a missing configured file handler is admitted")
                t.expect(
                    t.wait(until: { handed == [expected] }, timeout: 4),
                    desc: "failed configured file launch falls back once to the checked file opener"
                )
            }
        }

        // An OSC 8 link's visible text and its target are two strings, and the
        // text can say anything — so a reader is shown the target, in the
        // window's own chrome, before they commit to a click.
        UBUITestRegister("swift_shell_hover_resolution_keeps_only_the_latest_pending_target") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a window opens for hover admission")
                    return
                }
                defer { window.close() }
                let release = LinkOpener.holdPreviewResolutionForTesting()
                let prefix = "file:///tmp/ubiquitty-hover-\(UUID().uuidString)"
                let first = prefix + "-first.txt"
                LinkOpener.showPreview(forTarget: first, in: window)
                for index in 0..<1000 {
                    LinkOpener.showPreview(forTarget: prefix + "-\(index).txt", in: window)
                }
                let latest = prefix + "-999.txt"
                t.expect(
                    plate(in: window)?.retainedResolutionCountForTesting == 2,
                    desc: "a blocked worker retains only an active and a latest pending lookup"
                )
                t.expect(
                    plate(in: window)?.pendingResolutionTargetForTesting == latest,
                    desc: "the newest pointer target replaces all intermediate work"
                )
                release()
                LinkOpener.drainPreviewResolutionForTesting()
                let latestPath = URL(string: latest)!.standardizedFileURL.resolvingSymlinksInPath().path
                t.expect(
                    t.wait(until: { plate(in: window).map(plateText) == LinkOpener.refusalMarker + latestPath }, timeout: 4),
                    desc: "after release the newest pending lookup is resolved and displayed"
                )
                let releaseHidden = LinkOpener.holdPreviewResolutionForTesting()
                LinkOpener.showPreview(forTarget: first, in: window)
                LinkOpener.showPreview(forTarget: latest, in: window)
                LinkOpener.showPreview(forTarget: nil, in: window)
                t.expect(
                    plate(in: window)?.retainedResolutionCountForTesting == 1,
                    desc: "hiding the plate discards pending filesystem work"
                )
                releaseHidden()
                LinkOpener.drainPreviewResolutionForTesting()
                t.pump(0.3)
                t.expect(
                    plate(in: window)?.retainedResolutionCountForTesting == 0,
                    desc: "the completed stale lookup leaves no work behind"
                )
                t.expect(plate(in: window)?.isHidden == true, desc: "its result does not raise a hidden plate")
            }
        }

        UBUITestRegister("swift_shell_hovering_a_link_previews_what_would_open") { context in
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
                t.pump(0.3)

                // The text says one thing, the target another — which is the
                // whole reason the plate exists. The first link names a file
                // that is there, the second one that is not, and the third is
                // a web page, which the plate shows with no lookup.
                let previewed = "/tmp/ubiquitty-preview-\(UUID().uuidString).txt"
                FileManager.default.createFile(atPath: previewed, contents: Data("notes\n".utf8))
                defer { try? FileManager.default.removeItem(atPath: previewed) }
                let absent = "/tmp/ubiquitty-absent-\(UUID().uuidString).txt"
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(
                    Data("\u{1b}]8;;file://\(previewed)\u{1b}\\SAFE\u{1b}]8;;\u{1b}\\ plain\r\n".utf8)
                )
                surface.feed(
                    Data("\u{1b}]8;;file://\(absent)\u{1b}\\GONE\u{1b}]8;;\u{1b}\\ plain\r\n".utf8)
                )
                let web = "https://example.com/elsewhere"
                surface.feed(Data("\u{1b}]8;;\(web)\u{1b}\\WEB\u{1b}]8;;\u{1b}\\ plain\r\n".utf8))
                t.pump(0.3)

                let overLink = surface.viewPoint(forRow: 0, column: 2) ?? .zero
                surface.updateLinkAffordance(atViewPoint: overLink, isCommandHeld: false)
                t.expect(
                    t.wait(until: { plate(in: window).map { !$0.isHidden } ?? false }, timeout: 4),
                    desc: "hovering a link raises the plate"
                )
                guard let bubble = plate(in: window) else {
                    t.expect(false, desc: "the plate is in the window's content view")
                    return
                }
                // The bare path, not the URI: a reader checking where a link
                // goes reads /tmp/… faster than file:///tmp/…, and asserting
                // the difference is what pins the rule rather than the string.
                t.expect(
                    plateText(bubble) == previewed,
                    desc: "and it says the path a click would open, not the URI it is written as"
                )
                // The file is looked at off the main thread, and the plate
                // says so when a click would find nothing there.
                surface.updateLinkAffordance(atViewPoint: surface.viewPoint(forRow: 1, column: 2) ?? .zero, isCommandHeld: false)
                let absentAsResolved = URL(fileURLWithPath: absent).standardizedFileURL.resolvingSymlinksInPath().path
                t.expect(
                    t.wait(
                        until: { plate(in: window).map { plateText($0) == LinkOpener.refusalMarker + absentAsResolved } ?? false },
                        timeout: 4
                    ),
                    desc: "a link to nothing says a click will not open it"
                )
                // A late answer lands only on the plate of the link it was
                // asked for. The absent link's answer is still to come when
                // the pointer moves to the web link: nothing runs on the main
                // actor between the two hovers. The web link's line needs no
                // answer of its own, so once every answer has landed, only
                // the plate's subject has kept the absent one off it.
                let overWeb = surface.viewPoint(forRow: 2, column: 2) ?? .zero
                surface.updateLinkAffordance(atViewPoint: overWeb, isCommandHeld: false)
                surface.updateLinkAffordance(atViewPoint: surface.viewPoint(forRow: 1, column: 2) ?? .zero, isCommandHeld: false)
                surface.updateLinkAffordance(atViewPoint: overWeb, isCommandHeld: false)
                LinkOpener.drainPreviewResolutionForTesting()
                t.pump(0.3)
                t.expect(
                    plate(in: window).map(plateText) == web,
                    desc: "and a late answer for one link never lands on the next one's plate"
                        + " (\(plate(in: window).map(plateText) ?? "no plate"))"
                )
                // Over the cells, and never in the way of them. Asked of the
                // plate in its own superview's coordinates, which is what
                // `hitTest` takes, and asked as "no descendant either": the
                // label is a subview, and a hit landing on the label steals
                // the click just as surely while a check for the plate alone
                // passes.
                let insideThePlate = NSPoint(x: bubble.frame.midX, y: bubble.frame.midY)
                t.expect(
                    bubble.hitTest(insideThePlate) == nil,
                    desc: "and a click through it reaches the cells underneath"
                )
                let hit = content.hitTest(content.convert(insideThePlate, to: content.superview))
                t.expect(
                    hit?.isDescendant(of: bubble) != true,
                    desc: "so nothing in the window's own hit test lands on it or its label"
                )

                surface.updateLinkAffordance(
                    atViewPoint: surface.viewPoint(forRow: 0, column: 20) ?? .zero,
                    isCommandHeld: false
                )
                t.expect(
                    t.wait(until: { plate(in: window)?.isHidden ?? true }, timeout: 4),
                    desc: "moving off the link takes it away"
                )

                // A backgrounded window has no pointer over it, so it has no
                // hover: a plate left standing pins a target the reader is no
                // longer near.
                surface.updateLinkAffordance(atViewPoint: overLink, isCommandHeld: false)
                t.expect(
                    t.wait(until: { plate(in: window).map { !$0.isHidden } ?? false }, timeout: 4),
                    desc: "the plate comes back on a fresh hover"
                )
                NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: window)
                t.expect(
                    t.wait(until: { plate(in: window)?.isHidden ?? true }, timeout: 4),
                    desc: "and the window going to the background drops it"
                )
            }
        }

        // Leaving a pane by keyboard announces itself to nothing: no mouse
        // move happens and `mouseExited` does not fire on a pane or tab
        // switch, so an affordance left standing is a hand and an underline
        // lit over the NEXT pane's content, explained by nothing on screen.
        UBUITestRegister("swift_shell_leaving_a_pane_puts_the_link_affordance_out") { context in
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
                t.pump(0.3)

                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(
                    Data("\u{1b}]8;;https://example.com/lifecycle\u{1b}\\LINK\u{1b}]8;;\u{1b}\\ plain\r\n".utf8)
                )
                t.pump(0.3)

                let overLink = surface.viewPoint(forRow: 0, column: 2) ?? .zero
                surface.updateLinkAffordance(atViewPoint: overLink, isCommandHeld: false)
                t.expect(surface.isShowingLinkAffordance, desc: "hovering the link lights the affordance")

                // Leaving by keyboard: `mouseExited` does not fire on a pane
                // or tab switch, so nothing else would put it out — and it
                // would then be lit over whatever the next pane shows.
                _ = surface.resignFirstResponder()
                t.expect(
                    !surface.isShowingLinkAffordance,
                    desc: "and leaving the pane by keyboard puts it out"
                )

                // The two RE-RESOLVE edges beside this one — arriving in a
                // pane by keyboard, and the text scrolling under a stationary
                // pointer — both ride `updateLinkAffordanceAtLivePointer`,
                // whose guard is Core's `Input::shouldReResolveLinkHover`. It
                // refuses in this harness, whose windows never take key, so
                // they are asserted at the Core level and not here — the same
                // limit `hover-live-pointer-re-resolve` records.
                surface.updateLinkAffordance(atViewPoint: overLink, isCommandHeld: false)
                t.expect(surface.isShowingLinkAffordance, desc: "and a fresh hover lights it again")
            }
        }

        // The emphasis a hovered link is drawn in. Core takes the hover colour
        // whenever its alpha is above zero, and this arm handed it an alpha of
        // one over components of zero — so the run under the pointer drew
        // BLACK, the one colour that makes a link stop looking like one.
        UBUITestRegister("swift_shell_a_hovered_link_draws_in_the_system_accent") { context in
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
                t.pump(0.3)

                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(
                    Data("\u{1b}]8;;https://example.com/accent\u{1b}\\LINK\u{1b}]8;;\u{1b}\\ plain\r\n".utf8)
                )
                t.pump(0.3)

                let overLink = surface.viewPoint(forRow: 0, column: 2) ?? .zero
                surface.updateLinkAffordance(atViewPoint: overLink, isCommandHeld: true)
                // Through AppKit's own display cycle rather than a test-only
                // entry: the hover has to reach the frame the shell draws.
                surface.display()
                t.pump(0.3)

                // Read back off the frame's own options, so this witnesses what
                // was drawn with rather than what the style holds.
                let drawn = surface.lastFrameHoverColor
                // Offscreen layer display and the assertion run in separate
                // AppKit drawing contexts. Resolve both system-blue variants;
                // a second ambient lookup can resolve under the other one.
                let systemAccents = [NSAppearance.Name.aqua, .darkAqua]
                    .compactMap {
                        resolved(NSColor.systemBlue, under: $0)
                    }
                let matchesSystemAccent = systemAccents.contains {
                    abs(Double(drawn.red) - Double($0.redComponent)) < 0.01
                        && abs(Double(drawn.green) - Double($0.greenComponent)) < 0.01
                        && abs(Double(drawn.blue) - Double($0.blueComponent)) < 0.01
                }
                t.expect(
                    matchesSystemAccent,
                    desc:
                        "a hovered link is drawn in the accent both shells read"
                        + " (drawn \(drawn.red),\(drawn.green),\(drawn.blue))"
                )
                // Said separately because the comparison above would also hold
                // if the accent itself were black, which is what components
                // left at their defaults draw: without this the case passes on
                // that defect.
                t.expect(
                    Double(drawn.red) + Double(drawn.green) + Double(drawn.blue) > 0.5,
                    desc: "and that accent is a colour, not the black the components defaulted to"
                )
            }
        }

        // What this case cannot reach, recorded so a pass is not read as more
        // than it is. The band a reader lands in comes from an interactive
        // drag: windowWillResize
        // quantises to whole cells, and `quantiseDragExtent` lets the proposal
        // through the partial cell before the screen bound. This drives `setFrameSize` on
        // the surface directly, so it reproduces the state — a viewport whose height is
        // not a whole number of cells — and not the gesture. `inLiveResize` cannot be
        // set from a harness, so the live-resize branches (the transactional present,
        // the corner gravity, the image-gap latch) are not exercised here.
        //
        // That is enough for the question actually being asked: does a fractional-height
        // viewport produce a frame that trusts the dirty set without loading the target?
        // If it does, the blank is explained and the drag is incidental. If every step
        // is clean, the cause is in the live-resize branches this cannot reach, and the
        // next instrument has to be the real application under a real drag.

        UBUITestRegister("swift_shell_a_frame_that_clears_re_reads_every_row") { context in
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
                t.pump(0.3)

                // Fill the screen so a blank frame is unmistakable.
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                for row in 0..<20 {
                    surface.feed(Data("row-\(row) ".utf8))
                    surface.feed(Data(String(repeating: "x", count: 40).utf8))
                    surface.feed(Data("\r\n".utf8))
                }
                t.pump(0.4)

                let base = surface.frame.size
                // A fixed 24-point sweep rather than one cell: the renderer is
                // private to the shell, and 24 points crosses a cell boundary
                // for every cell height this ships at, which is all the sweep
                // needs to enter and leave the fractional band.
                let steps = 24
                var sawRefusal = false
                NSLog("UBQ_SLACK base=%.1fx%.1f steps=%d", base.width, base.height, steps)
                for step in 0..<steps {
                    surface.setFrameSize(NSSize(width: base.width, height: base.height + Double(step)))
                    // Read between the resize's own frame and whatever the
                    // clock draws next. `display()` draws synchronously, so the
                    // verdict here is the first frame at the new size, the one
                    // that meets a texture cut for the old one. Pumping first
                    // lets a second frame land and overwrite it with the
                    // settled answer, which is not the question.
                    surface.display()
                    let phase = surface.lastFramePhaseInputsForTesting
                    NSLog(
                        "UBQ_SLACK step=%d h=%.1f reused=%@ trustedDirty=%@ originY=%.1f encoded=%d actualH=%.1f",
                        step,
                        base.height + Double(step),
                        (phase?.didReuseLastFrame ?? false) ? "1" : "0",
                        (phase?.didTrustDirtySet ?? false) ? "1" : "0",
                        Double(phase?.originY ?? 0),
                        surface.framesEncodedForTesting,
                        Double(surface.frame.height)
                    )
                    // The invariant `planRetainedFrame`'s reconcile exists to
                    // hold: a frame that does not load the retained target is
                    // about to clear it, so trusting the drain's dirty set
                    // there draws the changed rows onto an empty texture and
                    // takes every clean row with them.
                    //
                    // Asserted on the first frame at each new size, the only
                    // one that meets a texture cut for the previous size.
                    // Sampled after a pump instead, every step reads reused,
                    // which is the settled answer and a constant: what an
                    // instrument prints when it is not measuring.
                    let reused = phase?.didReuseLastFrame ?? false
                    let trusted = phase?.didTrustDirtySet ?? false
                    t.expect(
                        reused || !trusted,
                        desc: "step \(step): a frame that refuses the retained target refuses the dirty set"
                    )
                    sawRefusal = sawRefusal || !reused
                    t.pump(0.05)
                }
                // Without this the assertion above is vacuous: a sweep in which
                // no step ever refuses the target satisfies it by never
                // reaching the case, which is what the pumped sampling did.
                t.expect(sawRefusal, desc: "and the sweep reached the refusing case at least once")
            }
        }

        // A press spent on opening a link is never reported, so the release
        // and the motion before it must not be either: an application that saw
        // a release with no press acts on half a gesture.
        UBUITestRegister("swift_shell_a_link_click_swallows_its_own_release") { context in
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
                t.pump(0.3)

                var opened: [String] = []
                surface.linkOpener = { opened.append($0) }
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                surface.feed(
                    Data("\u{1b}]8;;https://example.com/swallow\u{1b}\\LINK\u{1b}]8;;\u{1b}\\ plain\r\n".utf8)
                )
                t.pump(0.3)
                t.expect(!surface.didPressOpenALink, desc: "no press is in flight yet")

                let overLink = surface.viewPoint(forRow: 0, column: 2) ?? .zero
                guard let press = mouseEvent(.leftMouseDown, at: overLink, in: window, on: surface) else {
                    t.expect(false, desc: "a press can be made over the link")
                    return
                }
                surface.mouseDown(with: press)
                t.expect(
                    surface.didPressOpenALink,
                    desc: "a press that opened a link is held rather than reported"
                )

                guard let release = mouseEvent(.leftMouseUp, at: overLink, in: window, on: surface) else {
                    t.expect(false, desc: "a release can be made over the link")
                    return
                }
                surface.mouseUp(with: release)
                t.expect(
                    !surface.didPressOpenALink,
                    desc: "and its release is spent on the same gesture rather than reported alone"
                )
                t.expect(opened == ["https://example.com/swallow"], desc: "the gesture opens its link once")
            }
        }
    }

    /// One synthetic mouse event over a point in a surface.
    ///
    /// - Parameters:
    ///   - kind: The event type.
    ///   - point: Where, in the surface's coordinates.
    ///   - window: The window to place it in.
    ///   - surface: The surface the point belongs to.
    /// - Returns: The event, or nil where AppKit declines to make one.
    @MainActor
    private static func mouseEvent(
        _ kind: NSEvent.EventType,
        at point: CGPoint,
        in window: NSWindow,
        on surface: TerminalSurface
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: kind,
            location: surface.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    /// The link plate a window is showing, if it has raised one.
    ///
    /// - Parameter window: The window to look in.
    /// - Returns: The plate, or nil before one is raised.
    @MainActor
    private static func plate(in window: NSWindow) -> LinkPreviewBubble? {
        window.contentView?.subviews.compactMap { $0 as? LinkPreviewBubble }.first
    }

    /// What the plate is saying, read off its label.
    ///
    /// Off the view rather than off a remembered string: what a reader can act
    /// on is the text on screen, and a plate that remembered one target and
    /// drew another would answer differently here.
    ///
    /// - Parameter bubble: The plate.
    /// - Returns: Its line, empty when it carries no label.
    @MainActor
    private static func plateText(_ bubble: LinkPreviewBubble) -> String {
        bubble.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? ""
    }
}
