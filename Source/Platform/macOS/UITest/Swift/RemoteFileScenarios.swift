// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

private typealias SyncWire = Ubiquitty.`Protocol`.Sync

// RemoteFileScenarios.swift — a path clicked on a thin client, and what
// arrives when the host answers.
//
// Three claims, and the first two are about whose filesystem a printed path
// names.
//
// On a remote window a Cmd-clicked path names a file on the HOST. Stat'ing it
// here answers about this Mac: for `/etc/hosts` that is a real local file and
// the reader would be shown the wrong machine's copy, which is worse than
// nothing because it looks right. So the path is asked of the host, joined
// against the host's own reported directory when it is relative, and nothing
// local is opened.
//
// What the host sends back is a download. It lands under the last component of
// the path this side asked for, never the one the host echoed back — that
// string names nothing here, and the extension in a name is what decides
// whether the bytes reach a handler — carrying a `com.apple.quarantine` record in a browser download's
// shape, and the tag goes on before the open, not instead of it: the extension
// allowlist deciding open-versus-reveal is spoofable, so Gatekeeper still gets
// a say.
//
// The third is the other direction of the same rule: a file a ZMODEM sender
// pushed is a download whatever it named itself, so what a receive adds to the
// chosen folder carries the record too.

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

/// The `com.apple.quarantine` value a file carries, if any.
///
/// - Parameter url: The file to read.
/// - Returns: The value, or nil when the file carries no such attribute.
private func quarantineValue(of url: URL) -> String? {
    let name = "com.apple.quarantine"
    let size = url.path.withCString { path in
        name.withCString { attribute in
            getxattr(path, attribute, nil, 0, 0, 0)
        }
    }
    guard size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    let read = url.path.withCString { path in
        name.withCString { attribute in
            bytes.withUnsafeMutableBytes { buffer in
                getxattr(path, attribute, buffer.baseAddress, size, 0, 0)
            }
        }
    }
    guard read == size else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}

/// Whether a quarantine value is shaped like a browser download's.
///
/// Four semicolon-separated fields: the web-download flags, eight lower-case
/// hex digits of time, this terminal's name, and an event id. Read field by
/// field rather than by a regular expression so a failure names the field that
/// is wrong.
///
/// - Parameter value: The attribute's contents.
/// - Returns: Whether LaunchServices would read it as a download record.
private func isBrowserDownloadRecord(_ value: String) -> Bool {
    let fields = value.split(separator: ";", omittingEmptySubsequences: false)
    guard fields.count == 4 else { return false }
    guard fields[0] == "0083", fields[2] == "Ubiquitty" else { return false }
    guard fields[1].count == 8, fields[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
    return !fields[3].isEmpty
}

/// Registers the remote-file scenarios with the UI-test runner.
enum RemoteFileScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_remote_cmdclick_asks_the_host_for_the_file") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                askTheHost(t)
            }
        }
        UBUITestRegister("swift_shell_a_fetched_host_file_lands_quarantined") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                landTheAnswer(t)
            }
        }
        UBUITestRegister("swift_shell_a_fetched_line_link_opens_at_its_line") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                openTheLandedLine(t)
            }
        }
        UBUITestRegister("swift_shell_a_zmodem_arrival_carries_the_download_record") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                tagTheArrivals(t)
            }
        }
        UBUITestRegister("swift_shell_a_failed_host_install_shows_what_it_printed") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                showTheInstallTrouble(t)
            }
        }
        UBUITestRegister("swift_shell_a_consent_ask_on_a_window_nobody_sees_is_surfaced") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                surfaceTheConsentAsk(t)
            }
        }
        UBUITestRegister("swift_shell_beam_agent_revokes_ship_the_rosters_own_call") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                funnelBeamRevokes(t)
            }
        }
    }

    /// Beam's agent commands send exactly what the roster menu sends.
    ///
    /// - Parameter t: The scenario's expectations.
    @MainActor
    private static func funnelBeamRevokes(_ t: UBUITestContext) {
        var sent: [(RuntimeDrive.RevokeAction, String, String)] = []
        let roster = [
            AgentSurfaceCommandProvider.Agent(
                attachmentID: "00000000000000000000000000000007",
                name: "Test Agent",
                process: "/usr/local/bin/ubq",
                grantIdentity: "token:session-agent",
                grant: .session
            ),
            AgentSurfaceCommandProvider.Agent(
                attachmentID: "00000000000000000000000000000008",
                name: "remembered",
                process: "/opt/agents/remembered",
                grantIdentity: "token:remembered-agent",
                grant: .always
            ),
        ]
        let commands = AgentSurfaceCommandProvider(
            agents: roster,
            revoke: { action, clientID, identity in sent.append((action, clientID, identity)) }
        )
        .commands()
        let titles = commands.map(\.title)
        t.expect(
            titles.contains("Disconnect Agent: Test Agent")
                && titles.contains("Revoke Session Access: Test Agent")
                && !titles.contains("Stop Always Allowing: Test Agent"),
            desc: "a session-granted agent is offered its own scope and not the persisted one (\(titles))"
        )
        t.expect(
            titles.contains("Stop Always Allowing: remembered")
                && !titles.contains("Revoke Session Access: remembered"),
            desc: "and an agent the daemon remembers is offered the persisted one (\(titles))"
        )
        t.expect(titles.contains("Disconnect All Agents"), desc: "the palette can clear them all at once")

        // The triples are the roster menu's: stable attachment for disconnect,
        // separately verified daemon grant key for persistent/session grants.
        for command in commands {
            guard case .run(let fire) = command.action else { continue }
            fire()
        }
        t.expect(
            sent.contains(where: { $0 == (.disconnectNow, "00000000000000000000000000000007", "") }),
            desc: "Disconnect names the connection alone (\(sent.map { "\($0.0) \($0.1) \($0.2)" }))"
        )
        t.expect(
            sent.contains(where: { $0 == (.clearSessionGrant, "", "token:session-agent") }),
            desc: "the session revoke uses the distinct daemon grant key, not process or label"
        )
        t.expect(
            sent.contains(where: { $0 == (.stopAlwaysAllowing, "", "token:remembered-agent") }),
            desc: "and so is the persisted one"
        )
        t.expect(
            sent.contains(where: { $0 == (.disconnectAllAgents, "", "") }),
            desc: "Disconnect All names nobody in particular"
        )

        // A window with no remote session has nobody to revoke, so the palette
        // offers nothing rather than an item that does nothing.
        guard let controller = TerminalWindowController.spawn(), let window = controller.window else {
            t.expect(false, desc: "a Swift-shell window opens")
            return
        }
        defer { window.close() }
        t.pump(0.2)
        t.expect(
            AgentSurfaceCommandProvider(windowController: controller).commands().isEmpty,
            desc: "a local Swift window contributes no agent commands"
        )
    }

    /// A consent question on a window the reader is not looking at is brought
    /// forward without taking focus, and left alone when it is already there.
    ///
    /// - Parameter t: The scenario's expectations.
    @MainActor
    private static func surfaceTheConsentAsk(_ t: UBUITestContext) {
        guard let controller = TerminalWindowController.spawn(),
            let window = controller.window,
            let content = window.contentView,
            let surface = terminalSurface(under: content)
        else {
            t.expect(false, desc: "a Swift-shell window opens with a surface")
            return
        }
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        t.pump(0.2)

        var asks: [NSApplication.RequestUserAttentionType] = []
        var banners: [(Int, Int, String, String)] = []
        controller.requestUserAttention = { asks.append($0) }
        controller.postConsentBanner = { banners.append(($0, $1, $2, $3)) }

        // The reader is in another app: the sheet about to go up would never be
        // seen, and the daemon refuses the agent when its timeout runs out.
        controller.drawAttentionToConsent(
            on: surface,
            title: "Agent wants to attach to this session",
            body: "ubq is asking for access. Open Ubiquitty to allow or deny it.",
            isWindowForemost: false
        )
        t.expect(
            asks == [.criticalRequest],
            desc: "the Dock is asked to keep bouncing until the reader comes back (\(asks.count) asks)"
        )
        t.expect(banners.count == 1, desc: "and one banner stands in for the unseen sheet (\(banners.count))")
        t.expect(
            banners.first?.0 == window.windowNumber,
            desc: "the banner is tagged with this window, so a click returns to it"
        )
        t.expect(
            banners.first?.2.contains("attach") == true && banners.first?.3.contains("ubq") == true,
            desc: "and says what is wanted and who wants it (\(banners.first?.2 ?? "none"))"
        )
        t.expect(!NSApp.isActive, desc: "and none of it pulled the reader into this app")

        // The reader is already looking at this window: a bounce and a banner
        // for a sheet they are about to see is noise.
        asks.removeAll()
        banners.removeAll()
        controller.drawAttentionToConsent(
            on: surface,
            title: "Agent wants to attach to this session",
            body: "ubq is asking for access. Open Ubiquitty to allow or deny it.",
            isWindowForemost: true
        )
        t.expect(
            asks.isEmpty && banners.isEmpty,
            desc: "the foremost window is left alone (\(asks.count) asks, \(banners.count) banners)"
        )
    }

    /// A Cmd-click on a remote window names a path on the host.
    ///
    /// - Parameter t: The scenario's expectations.
    @MainActor
    private static func askTheHost(_ t: UBUITestContext) {
        guard let host = HostedTabScenarios.Host(t) else { return }
        defer { host.stop() }
        guard
            let controller = host.open(label: "file host"), let surface = controller.remoteSurface
        else {
            t.expect(false, desc: "a remote window opens with a surface")
            return
        }
        defer { controller.shellCloseWindow() }
        guard let window = controller.window else {
            t.expect(false, desc: "the remote window is on screen")
            return
        }
        window.makeKeyAndOrderFront(nil)
        guard t.wait(until: { surface.drive.remoteState == .Connected && surface.remoteSessionID != 0 }, timeout: 15) else {
            t.expect(false, desc: "the isolated host acknowledged the file-test pane")
            return
        }
        surface.remoteFileHost = "localhost"
        surface.remoteFileHostLabel = "file host"
        t.pump(0.3)

        var opened: [String] = []
        surface.linkOpener = { opened.append($0) }
        var prompts: [RuntimeDrive.FileDownloadPrompt] = []
        surface.fileDownloadPromptHandler = { prompts.append($0) }

        // OSC 7 is the host's own report of where the session is; a relative
        // candidate is joined against it and nothing on this Mac.
        surface.feed(Data("\u{1b}[H\u{1b}[2J\u{1b}]7;file://file-host/srv\u{07}".utf8))
        // `/etc/hosts` exists on this Mac too. That is the point: a local
        // resolve would find it and show the reader the wrong machine's file.
        surface.feed(Data("/etc/hosts\r\nlogs/build.log\r\n".utf8))

        guard let onAbsolute = surface.viewPoint(forRow: 0, column: 2),
            let onRelative = surface.viewPoint(forRow: 1, column: 2)
        else {
            t.expect(false, desc: "the surface has measured cell geometry")
            return
        }

        t.expect(
            surface.openLink(atViewPoint: onAbsolute, isCommandHeld: true),
            desc: "a Command-click on a path spends the click"
        )
        t.expect(
            surface.requestedHostFilesForTesting.isEmpty && prompts.count == 1,
            desc: "a click presents one question without sending a file request"
        )
        guard let cancelled = prompts.last else { return }
        t.expect(
            cancelled.path == "/etc/hosts" && cancelled.host == "file host (localhost)",
            desc: "the question captures the connected host and exact path"
        )
        surface.answerFileDownload(cancelled, download: false)
        t.expect(surface.requestedHostFilesForTesting.isEmpty, desc: "Cancel sends no request")
        surface.answerFileDownload(cancelled, download: true)
        t.expect(surface.requestedHostFilesForTesting.isEmpty, desc: "a cancelled completion cannot later download")
        t.expect(
            opened.isEmpty,
            desc: "nothing on this Mac was opened for it (\(opened))"
        )

        surface.openLink(atViewPoint: onRelative, isCommandHeld: true)
        guard let relative = prompts.last, relative.token != cancelled.token else {
            t.expect(false, desc: "the relative link presents a fresh question")
            return
        }
        t.expect(relative.path == "/srv/logs/build.log", desc: "the relative target is resolved when clicked")
        surface.feed(Data("\u{1b}]7;file://untrusted-name/different\u{07}".utf8))
        surface.answerFileDownload(relative, download: true)
        surface.answerFileDownload(relative, download: true)
        t.expect(
            surface.requestedHostFilesForTesting == ["/srv/logs/build.log"],
            desc: "Download sends the captured path once despite a later directory change"
        )
        surface.handleFileLink("file://localhost/srv/report%20one.txt", isPath: false)
        guard let explicit = prompts.last, explicit.token != relative.token else {
            t.expect(false, desc: "an explicit file URI also asks before a download")
            return
        }
        t.expect(explicit.path == "/srv/report one.txt", desc: "the URI path is decoded once")
        surface.answerFileDownload(explicit, download: false)
        let count = prompts.count
        surface.handleFileLink("file://other-host/srv/report.txt", isPath: false)
        t.expect(prompts.count == count, desc: "a foreign URI hostname cannot select or impersonate a connection")
        t.expect(opened.isEmpty, desc: "and still nothing local was opened (\(opened))")

        // The plate says what that click asks the host for. `ls --hyperlink`
        // on the host writes the host's name, which is not this Mac's, and a
        // file the host has need not exist here: neither is a reason to say a
        // click will not open it. A third machine's name is.
        surface.remoteFileHost = "build-box"
        let absent = "/srv/ubiquitty-absent-\(UUID().uuidString).txt"
        surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
        surface.feed(Data("\u{1b}]8;;file://build-box/srv/notes.txt\u{1b}\\NOTES\u{1b}]8;;\u{1b}\\\r\n".utf8))
        surface.feed(Data("\u{1b}]8;;file://\(absent)\u{1b}\\ABSENT\u{1b}]8;;\u{1b}\\\r\n".utf8))
        surface.feed(Data("\u{1b}]8;;file://elsewhere.invalid/srv/notes.txt\u{1b}\\THIRD\u{1b}]8;;\u{1b}\\\r\n".utf8))
        @MainActor
        func plateLine(hoveringRow row: Int) -> String {
            if let point = surface.viewPoint(forRow: row, column: 2) {
                surface.updateLinkAffordance(atViewPoint: point, isCommandHeld: false)
            }
            guard let plate = window.contentView?.subviews.compactMap({ $0 as? LinkPreviewBubble }).first, !plate.isHidden else {
                return "no plate"
            }
            return plate.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? ""
        }
        let named = plateLine(hoveringRow: 0)
        t.expect(named == "/srv/notes.txt", desc: "a link naming the host shows the host's path (\(named))")
        let missingHere = plateLine(hoveringRow: 1)
        LinkOpener.drainPreviewResolutionForTesting()
        t.pump(0.2)
        let settled = plateLine(hoveringRow: 1)
        t.expect(
            missingHere == absent && settled == absent,
            desc: "a path with nothing at it on this Mac is not marked, then or once settled (\(missingHere), \(settled))"
        )
        let third = plateLine(hoveringRow: 2)
        t.expect(
            third == LinkOpener.refusalMarker + "file://elsewhere.invalid/srv/notes.txt",
            desc: "a third machine's file says a click will not open it (\(third))"
        )
        surface.handleFileLink("file://build-box/srv/notes.txt", isPath: false)
        guard let shown = prompts.last, shown.token != explicit.token else {
            t.expect(false, desc: "the link naming the host asks the host")
            return
        }
        t.expect(shown.path == named, desc: "and the click asks the host for the path the plate showed (\(shown.path))")
        surface.answerFileDownload(shown, download: false)

        // A line link names the same file on the host: the plate shows it,
        // and the click asks the host for it with the line set aside.
        surface.feed(Data("\u{1b}]8;;file://build-box/srv/main.swift#L12\u{1b}\\LINE\u{1b}]8;;\u{1b}\\\r\n".utf8))
        let lined = plateLine(hoveringRow: 3)
        t.expect(lined == "/srv/main.swift", desc: "a line link shows the host file it fetches (\(lined))")
        surface.handleFileLink("file://build-box/srv/main.swift#L12", isPath: false)
        guard let asked = prompts.last, asked.token != shown.token else {
            t.expect(false, desc: "a line link asks the host for its file")
            return
        }
        t.expect(asked.path == "/srv/main.swift", desc: "for the file, with its line set aside (\(asked.path))")
        surface.answerFileDownload(asked, download: false)
    }

    /// What the host answers with lands the way a download lands.
    ///
    /// - Parameter t: The scenario's expectations.
    @MainActor
    private static func landTheAnswer(_ t: UBUITestContext) {
        guard let controller = TerminalWindowController.spawn(), let window = controller.window else {
            t.expect(false, desc: "a Swift-shell window opens")
            return
        }
        defer { window.close() }
        t.pump(0.2)

        var openedFiles: [URL] = []
        var revealedFiles: [URL] = []
        controller.openDownload = { openedFiles.append($0) }
        controller.revealDownload = { revealedFiles.append($0) }

        // The landing is named from the path this side asked for, reduced to
        // its last component — here one that would climb out of any directory
        // it is joined to. What the host echoes back is the host's own string
        // and names nothing on this disk.
        let payload = Array("the host's bytes".utf8)
        guard
            let landed = controller.landHostFile(
                RuntimeDrive.RemoteFile(
                    requestID: 1,
                    status: 0,
                    path: "/srv/anything-it-likes.sh",
                    requestedPath: "/srv/logs/../../../../etc/notes.txt",
                    bytes: payload
                )
            )
        else {
            t.expect(false, desc: "an answered file lands somewhere")
            return
        }
        defer { try? FileManager.default.removeItem(at: landed.deletingLastPathComponent()) }

        t.expect(
            landed.lastPathComponent == "notes.txt",
            desc: "the asked-for path is reduced to its last component (\(landed.lastPathComponent))"
        )
        t.expect(
            landed.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == "Ubiquitty-RemoteFiles",
            desc: "and it landed in a fresh directory of its own (\(landed.path))"
        )
        t.expect(
            (try? Data(contentsOf: landed)) == Data(payload),
            desc: "the bytes on disk are the bytes the host sent"
        )
        let record = quarantineValue(of: landed)
        t.expect(record != nil, desc: "the landed file carries com.apple.quarantine")
        t.expect(
            record.map(isBrowserDownloadRecord) == true,
            desc: "and the record is shaped like a browser download's (\(record ?? "none"))"
        )
        t.expect(
            openedFiles == [landed] && revealedFiles.isEmpty,
            desc: "a .txt is on the auto-open allowlist, so it opened"
                + " (opened \(openedFiles.count), revealed \(revealedFiles.count))"
        )

        // A name the allowlist does not cover is revealed rather than opened —
        // and tagged all the same, because the allowlist is a narrowing and
        // never the last gate. The extension is the clicked path's: a host
        // answering a click on a script with a `.txt` of its own choosing
        // would otherwise decide that the bytes go to a handler.
        guard
            let script = controller.landHostFile(
                RuntimeDrive.RemoteFile(
                    requestID: 2,
                    status: 0,
                    path: "/srv/notes.txt",
                    requestedPath: "/home/me/payload.sh",
                    bytes: payload
                )
            )
        else {
            t.expect(false, desc: "a script-named answer lands too")
            return
        }
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        t.expect(
            script.lastPathComponent == "payload.sh",
            desc: "the host's own name for it decided nothing (\(script.lastPathComponent))"
        )
        t.expect(
            revealedFiles == [script] && openedFiles == [landed],
            desc: "an executable extension is revealed, never opened"
                + " (opened \(openedFiles.count), revealed \(revealedFiles.count))"
        )
        t.expect(
            quarantineValue(of: script).map(isBrowserDownloadRecord) == true,
            desc: "and it carries the same record the opened one does"
        )

        // A host that could not read the file writes nothing, and says nothing:
        // a path candidate is the terminal's guess about printed text, so a
        // miss is as silent as a local click on a path naming no file.
        t.expect(
            controller.landHostFile(
                RuntimeDrive.RemoteFile(
                    requestID: 3,
                    status: 1,
                    path: "/tmp/missing.txt",
                    requestedPath: "/tmp/missing.txt",
                    bytes: []
                )
            ) == nil,
            desc: "a refusal from the host lands nothing"
        )
        t.expect(
            openedFiles.count == 1 && revealedFiles.count == 1,
            desc: "and shows nothing (opened \(openedFiles.count), revealed \(revealedFiles.count))"
        )
    }

    /// A line link fetched from a host opens the copy at its line, in the
    /// reader's line handler, as the same link opens a file of this machine.
    ///
    /// - Parameter t: The scenario's expectations.
    @MainActor
    private static func openTheLandedLine(_ t: UBUITestContext) {
        guard let controller = TerminalWindowController.spawn(), let window = controller.window else {
            t.expect(false, desc: "a Swift-shell window opens")
            return
        }
        defer { window.close() }
        t.pump(0.2)
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer { t.restoreConfiguration(saved) }
        func configureLineHandler(_ command: String?) {
            var document = documentDroppingTables(saved) { $0 == "[links]" || $0 == "[link_handlers]" }
            if let command {
                document += "\n[links]\nline_handler = \(tomlQuoted(command))\n"
            }
            restoreLiveDocument(document)
        }

        var openedFiles: [URL] = []
        var revealedFiles: [URL] = []
        controller.openDownload = { openedFiles.append($0) }
        controller.revealDownload = { revealedFiles.append($0) }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ubq-fetched-line-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else {
            t.expect(false, desc: "the scenario could make its scratch directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        var landings: [URL] = []
        defer { landings.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        @MainActor
        func land(_ requestedPath: String, line: UInt32, column: UInt32) -> URL? {
            let landed = controller.landHostFile(
                RuntimeDrive.RemoteFile(
                    requestID: 1,
                    status: 0,
                    path: requestedPath,
                    requestedPath: requestedPath,
                    requestedLine: line,
                    requestedColumn: column,
                    bytes: Array("let x = 1\n".utf8)
                )
            )
            if let landed {
                landings.append(landed)
            }
            return landed
        }

        // `ln -s` records the argument it was handed as a link's destination,
        // so what the handler received is read back off the disk.
        let recorded = scratch.appendingPathComponent("received").path
        configureLineHandler("/bin/ln -s {path}:{line}:{column} \(recorded)")
        guard let atLine = land("/srv/app/main.swift", line: 12, column: 5) else {
            t.expect(false, desc: "a line link's answer lands")
            return
        }
        var received = ""
        for _ in 0..<40 where received.isEmpty {
            received = (try? FileManager.default.destinationOfSymbolicLink(atPath: recorded)) ?? ""
            if received.isEmpty { t.pump(0.05) }
        }
        let canonical = atLine.resolvingSymlinksInPath().path
        t.expect(
            received == canonical + ":12:5",
            desc: "the line handler is handed the landed copy at the line the link named (received \(received))"
        )
        t.expect(
            openedFiles.isEmpty && revealedFiles.isEmpty,
            desc: "and the copy goes nowhere else (opened \(openedFiles.count), revealed \(revealedFiles.count))"
        )

        // With no line handler, or one that cannot start, the copy meets the
        // rule any fetched file does.
        configureLineHandler(nil)
        let unhandled = land("/srv/app/notes.txt", line: 3, column: 0)
        t.expect(
            unhandled.map { openedFiles == [$0] } == true && revealedFiles.isEmpty,
            desc: "with no line handler the copy opens as any fetched file (opened \(openedFiles.count))"
        )
        configureLineHandler("ubiquitty-no-such-editor-\(UUID().uuidString) {path}:{line}")
        let unstarted = land("/srv/app/run.sh", line: 7, column: 0)
        t.expect(
            unstarted.map { revealedFiles == [$0] } == true,
            desc: "and with one that cannot start, a script is revealed as any fetched script is (revealed \(revealedFiles.count))"
        )
        let noLine = land("/srv/app/other.txt", line: 0, column: 0)
        t.expect(
            noLine != nil && openedFiles.last == noLine,
            desc: "a link that named no line opens the copy as before"
        )
    }

    /// A file a ZMODEM sender pushed carries a download's record.
    ///
    /// The tagging step is run over a folder whose contents changed under it,
    /// which is what a receive leaves behind: the files this transfer wrote
    /// carry the record, and what the reader already had in the folder they
    /// chose is left alone — it is not a download and its own provenance is
    /// not this transfer's to rewrite.
    ///
    /// Run apart from the agent, because the claim is about the bytes and not
    /// about the agent's verdict: a sender that pushes one file and then
    /// aborts decides when the agent exits, and those bytes are on this disk
    /// either way.
    ///
    /// - Parameter t: The scenario's expectations.
    @MainActor
    private static func tagTheArrivals(_ t: UBUITestContext) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Ubiquitty-Transfer-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            t.expect(false, desc: "a folder for the receive can be made")
            return
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        let resident = folder.appendingPathComponent("resident.txt")
        FileManager.default.createFile(atPath: resident.path, contents: Data("the reader's own".utf8))
        let entriesBefore = TerminalWindowController.folderEntries(at: folder.path)

        let arrival = folder.appendingPathComponent("pushed.command")
        FileManager.default.createFile(atPath: arrival.path, contents: Data("#!/bin/sh\nid\n".utf8))

        let tagged = TerminalWindowController.tagArrivals(in: folder.path, addedTo: entriesBefore)
        t.expect(
            tagged.map(\.lastPathComponent) == ["pushed.command"],
            desc: "the transfer's own file is the one tagged (\(tagged.map(\.lastPathComponent)))"
        )
        t.expect(
            quarantineValue(of: arrival).map(isBrowserDownloadRecord) == true,
            desc: "and it carries a browser download's record"
                + " (\(quarantineValue(of: arrival) ?? "none"))"
        )
        t.expect(
            quarantineValue(of: resident) == nil,
            desc: "a file the reader already had is left as it was"
        )
    }

    /// A push that failed, and an install only a person can do, both reach the
    /// reader with something to act on.
    ///
    /// - Parameter t: The scenario's expectations.
    @MainActor
    private static func showTheInstallTrouble(_ t: UBUITestContext) {
        guard
            let controller = TerminalWindowController.spawnRemoteWindow(
                shellCommand: "/bin/sleep 30",
                hostLabel: "build-box",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0
            )
        else {
            t.expect(false, desc: "a remote window opens for the install notices")
            return
        }
        defer { controller.shellCloseWindow() }
        t.pump(0.2)

        // The push's own account, which is the part the connection's Failed
        // badge cannot carry.
        let failure = controller.hostDeployFailureAlert(
            failure: "scp: /home/me/.ubiquitty/ubiquitty-host: Read-only file system"
        )
        t.expect(
            failure.messageText.contains("build-box"),
            desc: "the failure names the host it happened on (\(failure.messageText))"
        )
        t.expect(
            failure.informativeText.contains("Read-only file system"),
            desc: "and shows what the push printed (\(failure.informativeText))"
        )
        t.expect(
            controller.hostDeployFailureAlert(failure: "").informativeText.contains("couldn’t install"),
            desc: "a push that printed nothing still says something happened"
        )
        let pending = controller.hostDeployFailureAlert(
            failure: "The old host keeps its sessions after a refused handover.",
            wasDeferred: true
        )
        t.expect(pending.messageText == "Host Update Pending on build-box", desc: "a refused handover is an explicit pending update")
        t.expect(pending.informativeText.contains("keeps its sessions"), desc: "the pending notice preserves the host's explanation")
        let handover = controller.hostUpdateSessionsAlert(question: "2 sessions are running on build-box.")
        t.expect(handover.informativeText.contains("transfers the live sessions"), desc: "Update Now offers live handover")
        t.expect(handover.informativeText.contains("old host keeps them running"), desc: "the update explains what a refusal preserves")

        // The steps are Core's, so the alert cannot spell a second version of
        // them. A published platform downloads this build's host and checks
        // it; any other platform is told there is none, with nothing to copy.
        let steps = String(
            Ubiquitty.Session.manualHostInstallCommands(std.string_view("Linux aarch64"), SyncWire.appVersion())
        )
        let offered = controller.manualHostInstallAlert(
            steps: steps,
            platform: "Linux aarch64",
            isForSetting: false
        )
        t.expect(
            offered.informativeText.contains("Linux aarch64"),
            desc: "the reason names the platform no bundled binary serves (\(offered.informativeText))"
        )
        t.expect(
            offered.informativeText.contains("https://ubiquitty.org/download/host/")
                && offered.informativeText.contains("asset=ubiquitty-host-linux-arm64")
                && offered.informativeText.contains("SHA256SUMS")
                && !offered.informativeText.contains("git clone"),
            desc: "and the steps download it from the website and check it, building nothing"
        )
        t.expect(
            offered.buttons.first?.title == "Copy Commands",
            desc: "Copy Commands is the first button (\(offered.buttons.map(\.title)))"
        )
        let turnedOff = controller.manualHostInstallAlert(steps: steps, platform: "Linux aarch64", isForSetting: true)
        t.expect(
            turnedOff.informativeText.contains("turned off"),
            desc: "a setting that stood in the way is named as the setting it is"
        )
        let unpublished = controller.manualHostInstallAlert(
            steps: String(
                Ubiquitty.Session.manualHostInstallCommands(std.string_view("FreeBSD amd64"), SyncWire.appVersion())
            ),
            platform: "FreeBSD amd64",
            isForSetting: false
        )
        t.expect(
            unpublished.informativeText == "There’s no prebuilt ubiquitty-host for FreeBSD amd64 yet."
                && unpublished.buttons.map(\.title) == ["OK"],
            desc: "a platform no release serves is told so, with nothing to copy"
                + " (\(unpublished.informativeText), \(unpublished.buttons.map(\.title)))"
        )

        let board = NSPasteboard.general
        board.clearContents()
        controller.copyManualHostInstallCommands(steps)
        t.expect(
            board.string(forType: .string) == steps,
            desc: "Copy Commands puts exactly the shown steps on the clipboard"
        )
    }
}
