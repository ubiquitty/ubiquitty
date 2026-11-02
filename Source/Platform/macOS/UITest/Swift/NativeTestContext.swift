// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

/// Configures Core from the live document with `lines` laid over it — what a
/// reload of a file that gained those lines does — and returns the document
/// that was live, for ``restoreLiveDocument(_:)``.
///
/// A bare `key = value` under a `[section]` is written into that section of
/// the document the way a settings write is, so a later write to the same key
/// edits the one line that says it rather than a copy an appended duplicate
/// section would outrank. Array tables and quoted keys are appended as given.
///
/// - Parameter lines: TOML to lay over the document, sections included.
/// - Returns: The document to restore.
@MainActor
@discardableResult
func configureAppendingToLiveDocument(_ lines: String) -> String {
    let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
    var document = saved
    var appended = ""
    var section: String?
    // A `[section]` header is appended only once a line under it is.
    var pendingHeader: String?
    for line in lines.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[[") {
            section = nil
            pendingHeader = nil
        } else if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            section = String(trimmed.dropFirst().dropLast())
            pendingHeader = line
            continue
        } else if let section, let equals = trimmed.firstIndex(of: "=") {
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let isBareKey = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if isBareKey {
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                document = String(
                    Ubiquitty.Preferences.setSectionKey(std.string(document), std.string(section), std.string(key), std.string(value))
                )
                continue
            }
        }
        if let header = pendingHeader {
            appended += header + "\n"
            pendingHeader = nil
        }
        appended += line + "\n"
    }
    _ = Ubiquitty.Preferences.configure(std.string(document + "\n" + appended), .Permissive)
    return saved
}

/// Configures Core from `document` again, as the caller found it.
///
/// - Parameter document: What ``configureAppendingToLiveDocument(_:)`` returned.
@MainActor
func restoreLiveDocument(_ document: String) {
    _ = Ubiquitty.Preferences.configure(std.string(document), .Permissive)
}

/// `document` without the tables whose header `isDropped` names.
///
/// A table runs from its header to the next header, which is where the
/// configuration parser stops routing keys into it; those lines are dropped
/// and every other line kept, so a scenario can configure a table of its own
/// in place of the reader's rather than beside it.
///
/// - Parameters:
///   - document: The TOML text.
///   - isDropped: Asked with each header, blanks removed, such as
///     `[[font.range_map]]` or `[link_handlers]`.
/// - Returns: The document with those tables taken out.
func documentDroppingTables(_ document: String, where isDropped: (String) -> Bool) -> String {
    var kept: [Substring] = []
    var isInDroppedTable = false
    for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            let header = String(trimmed.prefix { $0 != "#" }.filter { !$0.isWhitespace })
            isInDroppedTable = isDropped(header)
        }
        if !isInDroppedTable {
            kept.append(line)
        }
    }
    return kept.joined(separator: "\n")
}

/// `document` without the lines that set `keys` in its `[section]` tables, so
/// each of those keys reads as unset when the result is configured.
///
/// A dotted header names its last segment, as the configuration parser reads
/// it, so `[a.appearance]` is an `appearance` table too.
///
/// - Parameters:
///   - keys: The bare key names to drop.
///   - section: The table they belong to, such as `appearance`.
///   - document: The TOML text.
/// - Returns: The document with those assignments taken out.
func documentDroppingKeys(_ keys: Set<String>, inSection section: String, of document: String) -> String {
    var kept: [Substring] = []
    var isInSection = false
    for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            let header = String(trimmed.prefix { $0 != "#" }.filter { !$0.isWhitespace })
            let isTable = header.hasPrefix("[") && !header.hasPrefix("[[") && header.hasSuffix("]")
            let name = isTable ? header.dropFirst().dropLast() : ""
            isInSection = isTable && (name.split(separator: ".").last.map(String.init) ?? "") == section
        } else if isInSection, let equals = trimmed.firstIndex(of: "=") {
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if keys.contains(key) {
                continue
            }
        }
        kept.append(line)
    }
    return kept.joined(separator: "\n")
}

/// `text` as a TOML basic string, quotes included.
///
/// Escapes what the configuration parser decodes, so a path, a family or a
/// regex a scenario builds at run time reads back byte for byte.
///
/// - Parameter text: The value to quote.
/// - Returns: The quoted literal.
func tomlQuoted(_ text: String) -> String {
    var quoted = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": quoted += "\\\\"
        case "\"": quoted += "\\\""
        case "\n": quoted += "\\n"
        case "\r": quoted += "\\r"
        case "\t": quoted += "\\t"
        default: quoted.unicodeScalars.append(scalar)
        }
    }
    return quoted + "\""
}

/// The host in the bundle's Helpers, where the app looks for its daemon, for
/// as long as a scenario holds it.
@MainActor
final class BundledHost {
    /// The bundled host's path.
    let path: String
    private let placedHelpers: URL?
    private let isPlaced: Bool

    fileprivate init(path: String, placedHelpers: URL?, isPlaced: Bool) {
        self.path = path
        self.placedHelpers = placedHelpers
        self.isPlaced = isPlaced
    }

    /// Takes back what was placed: the host, and the Helpers directory when
    /// the bundle had none.
    func remove() {
        if isPlaced { try? FileManager.default.removeItem(atPath: path) }
        if let placedHelpers { try? FileManager.default.removeItem(at: placedHelpers) }
    }
}

/// The most failures a child application's log relays into one failure of
/// the scenario that ran it.
private let maxRelayedFailures = 8

/// What a child application's log says failed, on one line.
///
/// Only the lines the runner prints under a failing or refused scenario are
/// taken, never the child's result or tally lines; a child that stopped before
/// reporting is described by the last line it printed instead.
///
/// - Parameter output: The child's standard output and error.
/// - Returns: Its failures joined with semicolons, or its last line.
private func applicationPhaseFailures(in output: String) -> String {
    let lines = output.split(whereSeparator: \.isNewline)
    let failures = lines.filter { $0.hasPrefix(uiTestFailureLinePrefix) }.map { $0.dropFirst(uiTestFailureLinePrefix.count) }
    if failures.isEmpty {
        let last = lines.last { !$0.allSatisfy(\.isWhitespace) }
        return last.map { String($0.prefix(300)) } ?? "it printed nothing"
    }
    let relayed = failures.prefix(maxRelayedFailures).joined(separator: "; ")
    return failures.count > maxRelayedFailures ? relayed + "; and \(failures.count - maxRelayedFailures) more" : relayed
}

extension UBUITestContext {
    /// The host where a complete bundle carries it, Contents/Helpers. The
    /// UI-test bundle is built without helpers, so the host the runner built
    /// beside it (`UBIQUITTY_UI_TEST_HOST`) is placed there; a bundle that
    /// already carries one uses it as it is. The caller removes it when done.
    ///
    /// - Returns: The bundled host, or nil after reporting why there is none.
    @MainActor
    func placeBundledHost() -> BundledHost? {
        guard let harnessHost = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: harnessHost)
        else {
            expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return nil
        }
        let fileManager = FileManager.default
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let bundledHost = helpers.appendingPathComponent("ubiquitty-host").path
        let didCreateHelpers = !fileManager.fileExists(atPath: helpers.path)
        let didPlaceHost = !fileManager.isExecutableFile(atPath: bundledHost)
        if didPlaceHost {
            do {
                try fileManager.createDirectory(at: helpers, withIntermediateDirectories: true)
                try fileManager.copyItem(atPath: harnessHost, toPath: bundledHost)
            } catch {
                expect(false, desc: "the host was placed in the bundle's Helpers (\(error))")
                return nil
            }
        }
        return BundledHost(path: bundledHost, placedHelpers: didCreateHelpers ? helpers : nil, isPlaced: didPlaceHost)
    }

    /// Runs one phase of a scenario in a second process of this app, and
    /// records a failure naming what failed there.
    ///
    /// The child runs as `--ui-test <scenario>`, so it prints what a suite
    /// prints: a result line, its completion and its tally. Its standard
    /// output and error go to a log in `directory`, never to this run's, where
    /// the gate reading this run would count the scenario twice and the suite
    /// as finishing more than once. A child that fails is one failure of this
    /// scenario, carrying the assertions the child reported failing.
    ///
    /// - Parameters:
    ///   - scenario: The scenario the child runs.
    ///   - phase: The phase, named in the log's file name and in a failure.
    ///   - environment: The child's environment, including the variable that
    ///     tells the scenario which phase it is running.
    ///   - directory: A directory the scenario owns and removes, for the log.
    ///   - timeout: The longest the child may run before it is ended.
    /// - Returns: Whether the child launched, finished in time and passed.
    @MainActor
    @discardableResult
    func runApplicationPhase(
        _ scenario: String,
        phase: String,
        environment: [String: String],
        logDirectory directory: String,
        timeout: TimeInterval
    ) -> Bool {
        let logURL = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(phase)-application.log")
        let log: FileHandle
        do {
            try Data().write(to: logURL)
            log = try FileHandle(forWritingTo: logURL)
        } catch {
            expect(false, desc: "the \(phase) application's log opens in \(directory): \(error)")
            return false
        }
        defer { try? log.close() }
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--ui-test", scenario]
        child.environment = environment
        child.standardOutput = log
        child.standardError = log
        do { try child.run() } catch {
            expect(false, desc: "the \(phase) application launches: \(error)")
            return false
        }
        let finished = wait(until: { !child.isRunning }, timeout: timeout)
        if !finished { child.terminate() }
        child.waitUntilExit()
        let passed = finished && child.terminationReason == .exit && child.terminationStatus == 0
        if !passed {
            let ending: String
            if !finished {
                ending = "ended after \(Int(timeout)) s"
            } else if child.terminationReason == .exit {
                ending = "exit \(child.terminationStatus)"
            } else {
                ending = "signal \(child.terminationStatus)"
            }
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            expect(
                false,
                desc: "the \(phase) application process completes its assertions (\(ending): \(applicationPhaseFailures(in: output)))"
            )
        }
        return passed
    }

    /// Configures Core from the live document with `lines` appended — what a
    /// reload of a file that gained those lines does — and returns the
    /// document that was live, for ``restoreConfiguration(_:)``.
    ///
    /// - Parameter lines: TOML to append, sections included.
    /// - Returns: The document to restore.
    @MainActor
    @discardableResult
    func configureAppending(_ lines: String) -> String {
        configureAppendingToLiveDocument(lines)
    }

    /// Configures Core from `document` again, as the scenario found it.
    ///
    /// - Parameter document: What ``configureAppending(_:)`` returned.
    @MainActor
    func restoreConfiguration(_ document: String) {
        restoreLiveDocument(document)
    }

    @MainActor
    func newWindowRunning(_ arguments: [String]?) -> TerminalWindowController? {
        let controller =
            arguments.map {
                TerminalWindowController.spawn(arguments: $0, localePolicy: .auto, sessionLifetime: .outlivesChild)
            } ?? TerminalWindowController.spawn()
        pump(0.1)
        return controller
    }

    @MainActor
    func launchTmuxArguments(_ arguments: String) -> TerminalWindowController? {
        guard let executable = TerminalWindowController.tmuxExecutable else { return nil }
        let command = executable.withCString { executable in
            arguments.withCString {
                Ubiquitty.Network.buildLocalLaunchArguments(std.string_view(executable), std.string_view($0)).map { String($0) }
            }
        }
        let primary = TerminalWindowController.spawn(
            arguments: command,
            localePolicy: .auto,
            sessionLifetime: .endsWithChild,
            tmuxControlHost: ""
        )
        pump(0.5)
        return primary
    }

    @MainActor
    func killTmuxServer(onSocket socket: String) {
        guard let executable = TerminalWindowController.tmuxExecutable else { return }
        // A server can acknowledge termination before unlinking its socket.
        expect(
            wait(
                until: {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = ["-L", socket, "kill-server"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        process.waitUntilExit()
                        return process.terminationStatus != 0
                    } catch {
                        return true
                    }
                },
                timeout: 5
            ),
            desc: "the private tmux server terminates before another launch"
        )
    }

    @MainActor
    func sendText(_ text: String, to controller: NSWindowController) {
        (controller as? TerminalWindowController)?.sendScriptText(text)
    }

    @MainActor
    func gridText(of controller: NSWindowController) -> String {
        (controller as? TerminalWindowController)?.scriptScreenText() ?? ""
    }

    @MainActor
    func wait(forText text: String, in controller: NSWindowController, timeout: TimeInterval) -> Bool {
        wait(until: { self.gridText(of: controller).contains(text) }, timeout: timeout)
    }

    @MainActor
    func tmuxChildren(of primary: TerminalWindowController) -> [NSWindowController] {
        primary.hostedWindowsForTesting
    }

    @MainActor
    func focusedGrid(of controller: TerminalWindowController, columns: inout Int32, rows: inout Int32) {
        let snapshot = controller.beamSurface?.drive.readSnapshot()
        columns = snapshot?.columns ?? 0
        rows = snapshot?.rows ?? 0
    }

    @MainActor
    func resize(_ controller: TerminalWindowController, toColumns columns: Int32, rows: Int32) {
        controller.resizeWindow(toColumns: Int(columns), rows: Int(rows))
        pump(0.15)
    }

    @MainActor
    func click(inWindow controller: TerminalWindowController, atRow row: Int32, column: Int32, modifiers: NSEvent.ModifierFlags) {
        guard let surface = controller.beamSurface, let window = surface.window, let renderer = surface.renderer else { return }
        let cell = renderer.cellSize(for: surface)
        let insets = renderer.gridFitInsets(for: surface)
        let point = surface.convert(
            NSPoint(
                x: insets.left + (Double(column) + 0.5) * cell.width,
                y: insets.top + (Double(row) + 0.5) * cell.height
            ),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            else { continue }
            if type == .leftMouseDown { surface.mouseDown(with: event) } else { surface.mouseUp(with: event) }
        }
    }
}
