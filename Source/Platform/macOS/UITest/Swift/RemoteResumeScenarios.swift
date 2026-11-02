// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Security
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// RemoteResumeScenarios.swift — a remote window across an application restart.
//
// Two claims. The protected keychain the sealed resume record keeps its key in
// answers as the app's signature says it should: a team-signed build keeps a
// key, and an ad-hoc build is told so in one sentence and keeps nothing,
// without failing. And a remote window that the app quits with comes back in
// the next process: its stored picture is drawn before the first packet, it
// greets as the same client instance, and the host continues the attachment
// with a diff and shows what was printed meanwhile.
//
// The restart runs two application processes against one daemon this
// scenario forks with a home of its own. An unsigned build has no keychain
// access group, so the parent names a scratch keychain for its children
// (UBIQUITTY_RESUME_TEST_KEYCHAIN); a team-signed build uses the real one.

/// Whether a surface's buffer holds `text`.
@MainActor
private func bufferHolds(_ text: String, in surface: TerminalSurface) -> Bool {
    let holds = surface.searchScrollbackAndWait(text, isCaseSensitive: true).totalMatches > 0
    surface.drive.clearScrollbackSearch()
    return holds
}

/// Registers the remote resume scenarios with the UI-test runner.
enum RemoteResumeScenarios {
    static func register() {
        UBUITestRegister("sealed_resume_store_answers_as_the_signature_says") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkProtectedKeychain(t) }
        }
        UBUITestRegister("remote_window_resumes_across_an_application_restart") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkRestart(t) }
        }
    }

    /// The keychain probe: a team-signed build keeps a key in the data
    /// protection keychain; any other build cannot, and the window's resume
    /// is then unavailable, said in one sentence, with no crash.
    @MainActor
    private static func checkProtectedKeychain(_ t: UBUITestContext) {
        let team = RemoteResume.signingTeamIdentifier
        let status = RemoteResume.probeProtectedKeychain()
        print("remote-resume probe: team \(team ?? "none"), SecItemAdd status \(status)")
        if team != nil {
            t.expect(status == errSecSuccess, desc: "the team-signed build keeps a key in the protected keychain (status \(status))")
        } else {
            t.expect(status != errSecSuccess, desc: "a build with no team cannot reach the protected keychain (status \(status))")
            // Without the scratch keychain the window has no store, and says why.
            if ProcessInfo.processInfo.environment["UBIQUITTY_RESUME_TEST_KEYCHAIN"] == nil {
                t.expect(RemoteResume.prepare(identity: "probe-\(UUID().uuidString)") == nil, desc: "the store reports itself unavailable")
                t.expect(!RemoteResume.unavailableSentence.isEmpty, desc: "and says so in one sentence")
            }
        }
    }

    /// Runs both application processes against one owned daemon.
    @MainActor
    private static func checkRestart(_ t: UBUITestContext) {
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment["UBIQUITTY_UI_TEST_RESUME_PHASE"] {
            checkRestartPhase(t, phase: phase)
            return
        }
        guard let hostBinary = environment["UBIQUITTY_UI_TEST_HOST"], FileManager.default.isExecutableFile(atPath: hostBinary) else {
            t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return
        }
        t.closeAllWindows()
        let files = FileManager.default
        // Under /tmp: a Unix socket path is capped at 103 bytes.
        let root = "/tmp/ubq-rr-" + String(UUID().uuidString.prefix(8))
        let home = root + "/home"
        do { try files.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch {
            t.expect(false, desc: "the isolated restart fixture is created: \(error)")
            return
        }
        defer { try? files.removeItem(atPath: root) }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: hostBinary)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do { try daemon.run() } catch {
            t.expect(false, desc: "the restart daemon launches: \(error)")
            return
        }
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        guard
            t.wait(
                until: {
                    ((try? files.contentsOfDirectory(atPath: home)) ?? []).contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the isolated daemon becomes ready")
            return
        }
        var childEnvironment = environment
        childEnvironment["UBIQUITTY_HOME"] = home
        childEnvironment["UBIQUITTY_UI_TEST_RESUME_ROOT"] = root
        childEnvironment["UBIQUITTY_UI_TEST_RESUME_MARK"] = String(UUID().uuidString.prefix(8))
        if RemoteResume.signingTeamIdentifier == nil {
            childEnvironment["UBIQUITTY_RESUME_TEST_KEYCHAIN"] = root + "/keychain"
        }
        print(
            "remote-resume restart: \(childEnvironment["UBIQUITTY_RESUME_TEST_KEYCHAIN"] == nil ? "protected keychain" : "scratch keychain")"
        )
        for phase in ["first", "second"] {
            childEnvironment["UBIQUITTY_UI_TEST_RESUME_PHASE"] = phase
            guard
                t.runApplicationPhase(
                    "remote_window_resumes_across_an_application_restart",
                    phase: phase,
                    environment: childEnvironment,
                    logDirectory: root,
                    timeout: 90
                )
            else { return }
        }
    }

    /// Runs one application process of the restart.
    @MainActor
    private static func checkRestartPhase(_ t: UBUITestContext, phase: String) {
        t.closeAllWindows()
        let environment = ProcessInfo.processInfo.environment
        guard let hostBinary = environment["UBIQUITTY_UI_TEST_HOST"], let home = environment["UBIQUITTY_HOME"],
            let root = environment["UBIQUITTY_UI_TEST_RESUME_ROOT"], let marker = environment["UBIQUITTY_UI_TEST_RESUME_MARK"]
        else {
            t.expect(false, desc: "the restart phase has an isolated fixture")
            return
        }
        let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let attachCommand = "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach"
        let bootstrapCommand = "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --quic-bootstrap"
        let instanceFile = URL(fileURLWithPath: root + "/client-instance")
        let open: () -> TerminalWindowController? = {
            TerminalWindowController.spawnRemoteWindow(
                shellCommand: attachCommand,
                hostLabel: "resume host",
                quicHost: "127.0.0.1",
                quicBootstrapCommand: bootstrapCommand,
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "resume",
                hostKey: ""
            )
        }

        if phase == "first" {
            guard let window = open(), let surface = window.remoteSurface else {
                t.expect(false, desc: "the first process opens the remote window")
                return
            }
            guard t.wait(until: { surface.drive.remoteState == .Connected }, timeout: 30) else {
                t.expect(false, desc: "the remote window connects over QUIC")
                return
            }
            surface.send("echo BEFORE-THE-REST''ART-\(marker); (sleep 4; echo WHILE-THE-APP-WAS-GO''NE-\(marker)) &\n")
            t.expect(
                t.wait(until: { bufferHolds("BEFORE-THE-RESTART-\(marker)", in: surface) }, timeout: 15),
                desc: "the marker reaches the screen"
            )
            t.expect(
                t.wait(until: { window.remoteResume?.hasBoundPeer == true && window.remoteResume?.hasResumeReach == true }, timeout: 15),
                desc: "the window's descriptor holds the welcomed peer and its QUIC reach"
            )
            let instance = surface.drive.remoteClientInstance
            t.expect(
                window.remoteResume.map { UUIDHalves($0.clientID) == UUIDHalves(low: instance.low, high: instance.high) } == true,
                desc: "the window greets as its descriptor's client instance"
            )
            try? "\(instance.low) \(instance.high)".write(to: instanceFile, atomically: true, encoding: .utf8)
            // The app quits: every remote window stores its newest picture and
            // says goodbye as a suspended client.
            RemoteSessionLifecycle.shared.suspendForTermination()
            t.pump(0.5)
            t.closeAllWindows()
            return
        }

        // The second process: the window draws the stored picture before any
        // host frame can reach it.
        var wasDrawnBeforeFirstPacket: Bool?
        TerminalWindowController.remoteWindowOrderedInForTesting = { controller in
            guard let surface = controller.remoteSurface else { return }
            wasDrawnBeforeFirstPacket = bufferHolds("BEFORE-THE-RESTART-\(marker)", in: surface)
        }
        defer { TerminalWindowController.remoteWindowOrderedInForTesting = nil }
        guard let window = open(), let surface = window.remoteSurface else {
            t.expect(false, desc: "the second process opens the same remote window")
            return
        }
        t.expect(
            t.wait(until: { wasDrawnBeforeFirstPacket != nil }, timeout: 15) && wasDrawnBeforeFirstPacket == true,
            desc: "the stored picture is on screen before the first packet"
        )
        guard t.wait(until: { surface.drive.remoteState == .Connected }, timeout: 30) else {
            t.expect(false, desc: "the restored window reconnects")
            return
        }
        t.expect(
            t.wait(until: { surface.drive.remoteResumedPanesDiffed > 0 }, timeout: 10),
            desc: "the host continued the attachment with a diff"
        )
        let stored = (try? String(contentsOf: instanceFile, encoding: .utf8)) ?? ""
        let instance = surface.drive.remoteClientInstance
        t.expect(stored == "\(instance.low) \(instance.high)", desc: "the window greets as the client instance it had before the restart")
        let hasMeanwhileOutput = t.wait(until: { bufferHolds("WHILE-THE-APP-WAS-GONE-\(marker)", in: surface) }, timeout: 20)
        surface.send("echo AFTER-THE-REST''ART-\(marker)\n")
        let hasEchoAfter = t.wait(until: { bufferHolds("AFTER-THE-RESTART-\(marker)", in: surface) }, timeout: 10)
        t.expect(hasMeanwhileOutput, desc: "what was printed meanwhile arrives")
        t.expect(hasEchoAfter, desc: "input typed after the restart comes back")
        t.expect(bufferHolds("BEFORE-THE-RESTART-\(marker)", in: surface), desc: "the stored picture is kept")
        // Closed by the person, the window retires its record.
        let records = root + "/keychain/RemoteResume"
        window.close()
        t.pump(0.5)
        if environment["UBIQUITTY_RESUME_TEST_KEYCHAIN"] != nil {
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: records)) ?? []).filter { $0.hasSuffix(".sealed") }
            t.expect(left.isEmpty, desc: "closing the window retires its sealed record (\(left.count) left)")
        }
    }
}

/// A UUID as Core's two little-endian halves, for comparing with a drive's
/// client instance.
private struct UUIDHalves: Equatable {
    let low: UInt64
    let high: UInt64

    init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    init(_ uuid: UUID) {
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        func half(_ start: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[start + $1]) << (8 * $1) } }
        self.init(low: half(0), high: half(8))
    }
}
