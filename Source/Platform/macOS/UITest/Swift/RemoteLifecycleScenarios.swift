// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// RemoteLifecycleScenarios.swift — what a window does around the connection to
// its host, rather than what crosses it.
//
// Two claims. The badge in the title row says what the link is doing and says
// it off Core's one link state, so it cannot come to mean one thing for a
// daemon session and another for a carrier added later. And a window that
// mirrors a host follows that host: the session id is captured so a later
// connect reattaches the same shell, the grid the host chose becomes the
// window's size, the clipboard badge is re-read whenever the connection moves
// rather than latched at attach, and the shell exiting takes the window and any
// paste crossing to it.
//
// The second scenario runs against a real ubiquitty-host forked with a home of
// its own, because the facts it asserts are the daemon's answers.

/// Registers the remote-lifecycle scenarios with the UI-test runner.
enum RemoteLifecycleScenarios {
    /// The pairing key this file's windows are remembered under, its own so a
    /// run never reads or writes the operator's host directory.
    private static let pairingKey = "swift-remote-lifecycle.ui-test"

    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_remote_badge_reads_the_portable_link_state") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                verifyBadge(t)
            }
        }
        UBUITestRegister("swift_remote_carrier_probe", isInDefaultSuite: false) { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { probeCarriers(t) }
        }
        UBUITestRegister("swift_remote_carrier_probe_hold_is_opt_in") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyProbeHold(t) }
        }
        UBUITestRegister("swift_remote_carrier_probe_target_is_explicit") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyProbeTarget(t) }
        }
        UBUITestRegister("swift_remote_window_follows_its_host_session") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                verifyLifecycle(t)
            }
        }
        UBUITestRegister("swift_remote_non_owner_pan_follows_the_host_cursor") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyLifecycle(t, presentation: .pan) }
        }
        UBUITestRegister("swift_remote_non_owner_fit_preserves_the_host_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyLifecycle(t, presentation: .fit) }
        }
        UBUITestRegister("this_mac_host_new_session_attaches_at_the_launch_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                verifyThisMacHost(t)
            }
        }
    }

    // MARK: - This Mac's own host, the way the Connect window opens it

    /// The Connect window's This Mac → Ubiquitty Host → New Workspace, run
    /// through the directory model the window drives: the app's own bundled
    /// host, the daemon that host starts for itself, the loopback transport
    /// Core plans for it. Nothing is forked here, because the claim is that
    /// the app reaches the daemon it starts on its own.
    ///
    /// The window opens at the launch grid, attaches, and stays attached while
    /// its renderer publishes the typography table to the host; and a second
    /// connect, which reattaches the remembered session, opens at that grid too.
    @MainActor
    private static func verifyThisMacHost(_ t: UBUITestContext) {
        let root = "/tmp/ubq-this-mac-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        HostServers.installPairingPersistence()
        let server = ConnectModel.thisMac
        UbiquittyKit.HostDirectory.forget(host: server.pairingKey)
        defer {
            t.closeAllWindows()
            UbiquittyKit.HostDirectory.forget(host: server.pairingKey)
            // The daemon the bundled host started for this home ends with it.
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
                for entry in entries where entry.hasPrefix("host-") && entry.hasSuffix(".pid") {
                    if let text = try? String(contentsOfFile: home + "/" + entry, encoding: .utf8),
                        let processID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    {
                        kill(processID, SIGTERM)
                    }
                }
            }
            if let previousHome {
                setenv("UBIQUITTY_HOME", previousHome, 1)
            } else {
                unsetenv("UBIQUITTY_HOME")
            }
            try? FileManager.default.removeItem(atPath: root)
        }
        // The maintainer's typography: a face and padding other than the
        // defaults, under which the first layout pass reported an empty pane.
        let saved = t.configureAppending(
            """
            [font]
            family = "Monaspace Neon"
            size = 11.25
            line_spacing = 2.0
            [appearance]
            padding_left = 8.0
            padding_right = 8.0
            padding_bottom = 8.0
            """
        )
        defer { t.restoreConfiguration(saved) }
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        let launchGrid = (rows: Int(launch.rows), columns: Int(launch.columns))

        for attempt in ["new session", "reattach"] {
            // No remembered frame, so the window is sized from the launch grid.
            UserDefaults.standard.removeObject(forKey: "UbiquittyWindowFrame")
            let directory = HostDirectoryModel()
            directory.point(at: server)
            let before = Set(NSApp.windows.compactMap { ($0.windowController as? TerminalWindowController).map(ObjectIdentifier.init) })
            let opened = attempt == "new session" ? directory.newSession() : directory.connect()
            guard opened,
                let controller = NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController })
                    .first(where: { !before.contains(ObjectIdentifier($0)) && $0.remoteSurface != nil }),
                let surface = controller.remoteSurface
            else {
                t.expect(false, desc: "\(attempt): This Mac's host opened a window")
                return
            }
            let attached = t.wait(
                until: { surface.drive.remoteState == Ubiquitty.Session.State.Connected && surface.remoteSessionID != 0 },
                timeout: 30
            )
            t.expect(attached, desc: "\(attempt): the window attached to This Mac's daemon (\(surface.remoteFailureDetail))")
            guard attached else { return }
            // Watched for long enough for the typography table to cross and
            // for a window following the host to settle: the grid it shows
            // must never fall below the launch grid on the way.
            var smallest = surface.publishedGrid
            _ = t.wait(
                until: {
                    let grid = surface.publishedGrid
                    if grid.columns * grid.rows < smallest.columns * smallest.rows {
                        smallest = grid
                    }
                    return false
                },
                timeout: 3
            )
            t.expect(
                surface.drive.remoteState == Ubiquitty.Session.State.Connected,
                desc: "\(attempt): and stays attached (\(surface.drive.remoteState), \(surface.remoteFailureDetail))"
            )
            t.expect(
                surface.publishedGrid == launchGrid && smallest == launchGrid,
                desc: "\(attempt): at the launch grid throughout (\(surface.publishedGrid), smallest \(smallest), against \(launchGrid))"
            )
            // Closed as the close button does, which detaches: the session
            // stays on the host for the reattach to find.
            controller.shellCloseWindow()
            t.expect(t.wait(until: { controller.isClosedForTesting }, timeout: 20), desc: "\(attempt): the window closed")
        }
    }

    // MARK: - A carrier probe against a real host

    /// Selects one existing session without allowing a malformed ID to create one.
    private struct ProbeSelection {
        let sessionID: UInt32
        let carrier: String?

        /// - Parameters:
        ///   - session: An optional nonzero decimal session ID, excluding the protocol sentinel.
        ///   - carrier: One explicit carrier for reattach; absent runs both for a fresh probe.
        init?(session: String?, carrier: String?) {
            guard carrier == nil || carrier == "quic" || carrier == "ssh" else { return nil }
            if let session {
                guard carrier != nil, !session.isEmpty, session.utf8.count <= 10,
                    session.utf8.allSatisfy({ (48...57).contains($0) }),
                    let value = UInt32(session), value > 0, value < UInt32.max
                else { return nil }
                sessionID = value
            } else {
                sessionID = 0
            }
            self.carrier = carrier
        }
    }

    /// Restricts the requested home before the remote shell verifies its canonical path.
    /// - Parameter home: The absolute task-owned directory requested by the operator.
    /// - Returns: Whether its first temporary-directory child is a nonempty ubq-* name.
    private static func isProbeHome(_ home: String) -> Bool {
        guard home.utf8.count <= 4096,
            home.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let suffix: Substring
        if home.hasPrefix("/private/tmp/") {
            suffix = home.dropFirst("/private/tmp/".count)
        } else if home.hasPrefix("/tmp/") {
            suffix = home.dropFirst("/tmp/".count)
        } else {
            return false
        }
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = components.first, first.hasPrefix("ubq-"), first.count > 4 else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Pins invalid-ID and path refusal without dialing or touching any daemon.
    /// - Parameter t: The native test context.
    @MainActor
    private static func verifyProbeTarget(_ t: UBUITestContext) {
        t.expect(ProbeSelection(session: nil, carrier: nil)?.sessionID == 0, desc: "the original two-carrier probe remains the default")
        t.expect(ProbeSelection(session: "8", carrier: "quic")?.sessionID == 8, desc: "an explicit QUIC reattach retains its exact session")
        t.expect(ProbeSelection(session: "4294967294", carrier: "ssh") != nil, desc: "the largest real session ID is admitted")
        for text in ["", "0", "-1", "+8", " 8", "8 ", "8\n", "8.0", "4294967295", "4294967296", "18446744073709551616"] {
            t.expect(
                ProbeSelection(session: text, carrier: "quic") == nil,
                desc: "invalid reattach ID \(text.debugDescription) cannot create a session"
            )
        }
        t.expect(ProbeSelection(session: "8", carrier: nil) == nil, desc: "reattach requires one explicit carrier")
        for carrier in ["", "both", "QUIC", "tcp"] {
            t.expect(ProbeSelection(session: nil, carrier: carrier) == nil, desc: "unknown carrier \(carrier) is refused")
        }
        for home in ["/tmp/ubq-demo", "/private/tmp/ubq-demo/nested"] {
            t.expect(isProbeHome(home), desc: "the task-owned home is admitted: \(home)")
        }
        for home in [
            "/tmp", "/tmp/ubq-", "/tmp/other", "/Users/user", "/private/tmp/ubq-demo/../other", "/tmp/ubq-demo/./child", "/tmp/ubq-demo\n",
        ] {
            t.expect(!isProbeHome(home), desc: "a non-task or ambiguous home is refused: \(home.debugDescription)")
        }
    }

    /// Exercises QUIC and SSH against an already-running, isolated daemon.
    ///
    /// UBQ_QUIC_PROBE_SSH_HOST, BINARY, HOME and SOCKET identify that daemon;
    /// HOME must resolve inside a /tmp/ubq-* or /private/tmp/ubq-* directory.
    /// UBQ_QUIC_PROBE_HOLD_SECONDS optionally keeps each verified window visible
    /// for 0–600 seconds. With --ui-test-visible, a positive hold dispatches
    /// native events; zero and offscreen holds never activate the application.
    /// The probe neither captures images nor starts a daemon.
    /// UBQ_QUIC_PROBE_LABEL optionally supplies a non-personal display name.
    /// UBQ_QUIC_PROBE_REATTACH_SESSION with UBQ_QUIC_PROBE_CARRIER=quic or ssh
    /// attaches only that existing session and sends no probe commands into its program.
    ///
    /// - Parameter t: The visible or off-screen native test context.
    @MainActor
    private static func probeCarriers(_ t: UBUITestContext) {
        let environment = ProcessInfo.processInfo.environment
        let displayLabel = environment["UBQ_QUIC_PROBE_LABEL"]
        guard let sshHost = environment["UBQ_QUIC_PROBE_SSH_HOST"], let binary = environment["UBQ_QUIC_PROBE_BINARY"],
            let home = environment["UBQ_QUIC_PROBE_HOME"], let socket = environment["UBQ_QUIC_PROBE_SOCKET"]
        else {
            // An operator's probe: without the daemon it names, there is
            // nothing here to drive, which is no verdict on the carriers.
            t.refuse("UBQ_QUIC_PROBE_SSH_HOST, BINARY, HOME and SOCKET must identify an isolated running daemon")
            return
        }
        guard sshHost.withCxxStringView({ Ubiquitty.Transport.validateSSHHost($0) }),
            isProbeHome(home),
            let selection = ProbeSelection(
                session: environment["UBQ_QUIC_PROBE_REATTACH_SESSION"],
                carrier: environment["UBQ_QUIC_PROBE_CARRIER"]
            ),
            displayLabel.map({ label in
                !label.isEmpty && label.utf8.count <= 256
                    && label.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            }) ?? true,
            [binary, home]
                .allSatisfy({ path in
                    path.hasPrefix("/") && path.utf8.count <= 4096
                        && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                }),
            socket.utf8.count == 26, socket.hasPrefix("host-"), socket.hasSuffix(".sock"),
            socket.utf8.dropFirst(5).dropLast(5)
                .allSatisfy({ byte in
                    (byte >= 97 && byte <= 102) || (byte >= 48 && byte <= 57)
                }),
            let holdSeconds = Double(environment["UBQ_QUIC_PROBE_HOLD_SECONDS"] ?? "0"),
            holdSeconds.isFinite, (0...600).contains(holdSeconds)
        else {
            t.expect(
                false,
                desc:
                    "the probe requires a task-owned home, valid SSH destination, absolute binary, host-<16 lowercase hex>.sock, bounded label and hold, and one carrier with any nonzero reattach session"
            )
            return
        }
        let quote: (String) -> String = { text in
            String(text.withCxxStringView { Ubiquitty.Transport.shellSingleQuote($0) })
        }
        // Resolve symlinks on the remote machine before selecting its home.
        // An explicit socket makes --quic-bootstrap skip daemon ensure/start.
        let remotePrefix =
            "cd -P \(quote(home)) || exit 64; "
            + "case \"$PWD\" in /tmp/ubq-?*|/private/tmp/ubq-?*) ;; *) exit 64 ;; esac; "
            + "test -S \"$PWD\"/\(quote(socket)) && test ! -L \"$PWD\"/\(quote(socket)) || exit 64; "
            + "export UBIQUITTY_HOME=\"$PWD\"; exec \(quote(binary))"
        let sshPrefix =
            "exec ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o serveralivecountmax=3 "
            + "-o ControlMaster=no -o ControlPath=none"
        let attachRemote = "exec /bin/sh -c " + quote(remotePrefix + " --attach --socket " + quote(socket))
        let bootstrapRemote = "exec /bin/sh -c " + quote(remotePrefix + " --quic-bootstrap --socket " + quote(socket))
        let attachCommand = sshPrefix + " " + quote(sshHost) + " " + quote(attachRemote)
        // Core requires ssh's direct-reach evidence before dialing non-loopback
        // QUIC. Disable connection sharing so -v describes this exact attempt.
        let bootstrapCommand = sshPrefix + " -v " + quote(sshHost) + " " + quote(bootstrapRemote)
        let networkHost = String(sshHost.split(separator: "@").last ?? Substring(sshHost))
        for (label, quicHost) in [("quic", networkHost), ("ssh", "")] {
            if let carrier = selection.carrier, carrier != label { continue }
            guard
                let window = TerminalWindowController.spawnRemoteWindow(
                    shellCommand: attachCommand,
                    hostLabel: displayLabel ?? "probe \(label)",
                    quicHost: quicHost,
                    quicBootstrapCommand: quicHost.isEmpty ? "" : bootstrapCommand,
                    deploySSHHost: "",
                    deployBinaries: [:],
                    reattachSessionID: selection.sessionID,
                    workspaceName: "",
                    reattachPolicy: selection.sessionID == 0 ? .attachOrCreate : .attachOnly,
                    hostKey: "",
                    daemonSocketName: socket
                ), let surface = window.remoteSurface
            else {
                t.expect(false, desc: "\(label): the isolated remote window opened")
                continue
            }
            // Closing the controller detaches its local endpoints. The remote
            // daemon and its sessions remain owned by the probe's caller.
            defer { if !window.isClosedForTesting { TerminalWindowController.detachRemoteWorkspaceForTesting(from: surface.drive) } }
            let connected = t.wait(
                until: { surface.drive.remoteState == Ubiquitty.Session.State.Connected && surface.remoteSessionID != 0 },
                timeout: 40
            )
            t.expect(connected, desc: "\(label): connected to the pinned daemon (\(surface.remoteFailureDetail))")
            guard connected else { continue }
            let usesExpectedCarrier = surface.drive.isRemoteUsingQUIC == !quicHost.isEmpty
            t.expect(usesExpectedCarrier, desc: "\(label): the requested carrier is active, without a silent fallback")
            guard usesExpectedCarrier else { continue }

            if selection.sessionID != 0 {
                t.expect(surface.remoteSessionID == selection.sessionID, desc: "reattach reaches only the requested existing session")
                guard surface.remoteSessionID == selection.sessionID, let nativeWindow = window.window else { continue }
                holdProbeWindow(nativeWindow, seconds: holdSeconds, context: t) {
                    FileHandle.standardError.write(
                        Data(
                            "CARRIER_PROBE_READY carrier=\(label) usingQUIC=\(surface.drive.isRemoteUsingQUIC) session=\(surface.remoteSessionID) window=\(nativeWindow.windowNumber) reattach=true holdSeconds=\(holdSeconds)\n"
                                .utf8
                        )
                    )
                }
                t.expect(
                    surface.drive.remoteState == .Connected && surface.drive.isRemoteUsingQUIC == !quicHost.isEmpty
                        && surface.remoteSessionID == selection.sessionID,
                    desc: "the existing session remains connected on the requested carrier after capture"
                )
                TerminalWindowController.detachRemoteWorkspaceForTesting(from: surface.drive)
                t.expect(t.wait(until: { window.isClosedForTesting }, timeout: 20), desc: "the existing workspace's local views detach")
                continue
            }

            // The result token is absent from the echoed command. Both it and
            // OSC 9;4 must be emitted by the real remote shell and cross Sync.
            surface.send("printf '\\033]9;4;1;40\\007'; printf '\\ncarrier-\(label)-%s\\n' $((41000+1301))\r")
            let answered = waitForGridText(t, of: surface) { $0.contains("carrier-\(label)-42301") }
            t.expect(answered, desc: "\(label): remote shell output crosses the carrier")
            let reportedProgress = t.wait(
                until: {
                    let snapshot = surface.drive.readSnapshot()
                    return snapshot.progressState == 1 && snapshot.progressValue == 40
                },
                timeout: 10
            )
            t.expect(reportedProgress, desc: "\(label): the remote OSC 9;4 report reaches the published snapshot")
            let showsProgress = t.wait(
                until: { ProgressChromeScenarios.windowBand(of: window).map { !$0.isHidden } ?? false },
                timeout: 5
            )
            t.expect(showsProgress, desc: "\(label): native window chrome displays the remote progress")
            guard answered && reportedProgress && showsProgress else { continue }
            guard let nativeWindow = window.window else {
                t.expect(false, desc: "\(label): the verified window remains available for the capture interval")
                continue
            }
            holdProbeWindow(nativeWindow, seconds: holdSeconds, context: t) {
                FileHandle.standardError.write(
                    Data(
                        "CARRIER_PROBE_READY carrier=\(label) usingQUIC=\(surface.drive.isRemoteUsingQUIC) session=\(surface.remoteSessionID) window=\(nativeWindow.windowNumber) progress=40 holdSeconds=\(holdSeconds)\n"
                            .utf8
                    )
                )
            }
            t.expect(
                surface.drive.remoteState == .Connected && surface.drive.isRemoteUsingQUIC == !quicHost.isEmpty,
                desc: "\(label): the same carrier remains connected after the capture interval"
            )
            window.shellCloseWindow()
            t.expect(t.wait(until: { window.isClosedForTesting }, timeout: 20), desc: "\(label): the local window detached")
        }
    }

    /// Whether a capture hold may take focus and dispatch native user input.
    ///
    /// - Parameters:
    ///   - seconds: The validated probe hold, where zero disables the hold.
    ///   - arguments: The process arguments, including the explicit visibility opt-in.
    /// - Returns: Whether both a positive hold and --ui-test-visible were requested.
    private static func isInteractiveProbeHold(seconds: Double, arguments: [String]) -> Bool {
        seconds > 0 && arguments.contains("--ui-test-visible")
    }

    /// Holds a real probe window without changing ordinary test activation.
    ///
    /// The harness normally pumps only NSRunLoop. A visible capture hold must
    /// also dispatch AppKit events so menus, typing and window controls work.
    ///
    /// - Parameters:
    ///   - window: The verified, task-owned window.
    ///   - seconds: The validated hold duration in the range 0...600.
    ///   - context: The native test context used for noninteractive pumping.
    ///   - ready: Reports readiness after any requested activation.
    @MainActor
    private static func holdProbeWindow(_ window: NSWindow, seconds: Double, context: UBUITestContext, ready: () -> Void) {
        guard isInteractiveProbeHold(seconds: seconds, arguments: ProcessInfo.processInfo.arguments) else {
            ready()
            if seconds > 0 { context.pump(seconds) }
            return
        }
        let originalPolicy = NSApp.activationPolicy()
        let originalApplication = NSWorkspace.shared.frontmostApplication
        defer {
            NSApp.setActivationPolicy(originalPolicy)
            if originalApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                originalApplication?.activate(options: [])
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.updateWindows()
        ready()
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline && window.isVisible {
            autoreleasepool {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                let until = Date(timeIntervalSinceNow: max(0, min(0.01, remaining)))
                if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
            }
        }
    }

    /// Pins the opt-in boundary without contacting a host or activating offscreen tests.
    ///
    /// - Parameter t: The native test context.
    @MainActor
    private static func verifyProbeHold(_ t: UBUITestContext) {
        t.expect(!isInteractiveProbeHold(seconds: 0, arguments: ["--ui-test-visible"]), desc: "zero hold never opts into activation")
        t.expect(!isInteractiveProbeHold(seconds: 1, arguments: ["--ui-test"]), desc: "an offscreen hold cannot activate")
        t.expect(!isInteractiveProbeHold(seconds: 1, arguments: []), desc: "a hold alone does not opt into visibility")
        t.expect(
            isInteractiveProbeHold(seconds: 1, arguments: ["--ui-test-visible"]),
            desc: "a positive visible hold dispatches native events"
        )
        let originalPolicy = NSApp.activationPolicy()
        let originalApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.close() }
        var readyCount = 0
        holdProbeWindow(window, seconds: 0, context: t) { readyCount += 1 }
        t.expect(readyCount == 1, desc: "the zero-hold probe reports readiness exactly once")
        if WindowContainment.isOffscreen {
            holdProbeWindow(window, seconds: 0.02, context: t) { readyCount += 1 }
            t.expect(readyCount == 2, desc: "the offscreen hold reports readiness exactly once")
        }
        t.expect(NSApp.activationPolicy() == originalPolicy, desc: "noninteractive holds preserve the activation policy")
        t.expect(
            NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApplication?.processIdentifier,
            desc: "noninteractive holds leave the foreground application unchanged"
        )
    }

    // MARK: - The badge

    /// The trailing-titlebar badge, driven through the window that owns it.
    ///
    /// A transport that never answers is enough: what is asserted is the fold
    /// from a connection's phases to the link state and the two decisions drawn
    /// off it, none of which needs bytes to flow.
    @MainActor
    private static func verifyBadge(_ t: UBUITestContext) {
        guard
            let controller = TerminalWindowController.spawnRemoteWindow(
                shellCommand: "/bin/sleep 30",
                hostLabel: "badge host",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0
            ), let surface = controller.remoteSurface
        else {
            t.expect(false, desc: "a silent transport opens a window wearing the remote badge")
            return
        }
        defer { controller.shellCloseWindow() }
        guard let badge = controller.remoteConnectionIndicator else {
            t.expect(false, desc: "a remote window's title row carries the badge")
            return
        }

        // Through the live path first: the window folds the connection's own
        // phase to the link state a badge draws, so an arm that read the phases
        // itself would need a second vocabulary.
        controller.refreshRemoteConnectionIndicator(on: surface)
        t.expect(
            badge.readingForTesting == "badge host",
            desc: "a connection still being stood up keeps its host identity (\(badge.readingForTesting))"
        )
        t.expect(
            surface.drive.remoteState == .Idle || surface.drive.remoteState == .Connecting,
            desc: "and that reading came from a phase that has not reached the host"
        )
        t.expect(!badge.isHidden, desc: "the badge is in the title row rather than hidden")
        // A status indicator, not a control: one that read as a button would
        // invite a click that does nothing.
        t.expect(badge.accessibilityRole() == .group, desc: "the badge announces itself as a status group, not a button")
        t.expect(!badge.acceptsFirstResponder, desc: "and never takes focus from the grid")

        // Steady: the chrome's own ink, with the carrier distinguished by its globe.
        badge.update(place: .Remote, health: .Connected, host: "badge host", carrier: "ssh")
        t.expect(
            badge.readingForTesting == "badge host" && badge.symbolNameForTesting == "globe",
            desc: "a steady SSH link names the host beside an outline globe (\(badge.readingForTesting))"
        )
        t.expect(
            badge.globeInkForTesting == .secondaryLabelColor,
            desc: "a steady link is drawn in the chrome's ink rather than flagged"
        )
        badge.update(place: .Remote, health: .Connected, host: "badge host", carrier: "quic")
        t.expect(
            badge.readingForTesting == "badge host" && badge.symbolNameForTesting == "globe.fill"
                && badge.accessibilityLabel()?.contains("QUIC") == true,
            desc: "QUIC uses a filled globe and remains explicit in the accessible description"
        )

        // Every other state: a tinted globe, the host name still monochrome,
        // and the connection state retained in its accessible description.
        let unsteady: [(Ubiquitty.Session.Health, String)] = [
            (.Connecting, "Connecting to badge host"),
            (.Deploying, "Setting up badge host"),
            (.Reconnecting, "Reconnecting to badge host"),
            (.Failed, "Disconnected from badge host"),
        ]
        for (health, reading) in unsteady {
            badge.update(place: .Remote, health: health, host: "badge host", carrier: "quic")
            t.expect(badge.readingForTesting == "badge host", desc: "the host identity stays stable while \(reading)")
            t.expect(
                badge.globeInkForTesting != .secondaryLabelColor,
                desc: "\(reading) is flagged rather than drawn as the steady state"
            )
            t.expect(
                badge.hostInkForTesting == .secondaryLabelColor,
                desc: "\(reading) leaves the host name as the window's stable identity"
            )
        }

        // The fold's one decision rather than a rename: a session whose attach
        // has not started shows the same badge as one in flight, because there
        // is no pre-start badge to show.
        t.expect(
            Ubiquitty.Session.healthFor(.Idle) == Ubiquitty.Session.healthFor(.Connecting),
            desc: "an unstarted attach reads as one that has not connected yet"
        )
    }

    // MARK: - The lifecycle, against a daemon

    /// Exercises opt-in Pan on an actual second attachment without resizing its host.
    @MainActor
    private static func verifyPan(
        _ t: UBUITestContext,
        owner: TerminalWindowController,
        ownerSurface: TerminalSurface,
        peer: TerminalWindowController,
        peerSurface: TerminalSurface
    ) {
        owner.resizeWindow(toColumns: 80, rows: 24)
        peer.resizeWindow(toColumns: 48, rows: 12)
        ownerSurface.send("printf '\\033[41m\\033[2J\\033[24;80H'; read -r UBQ_PAN_REPLY\r")
        defer {
            peerSurface.setRemoteViewportPresentationForTesting(.letterbox)
            ownerSurface.send("\rprintf '\\033[0m\\033[2J\\033[H'\r")
        }
        guard
            t.wait(
                until: {
                    let picture = peerSurface.drive.readSnapshot()
                    return peerSurface.drive.isRemoteGeometryOwnedElsewhere && picture.columns == 80 && picture.rows == 24
                        && picture.cursorRow == 23 && picture.cursorColumn == 79 && picture.isCursorVisible
                        && peerSurface.publishedGrid.columns < 80 && peerSurface.publishedGrid.rows < 24
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the real non-owner holds an oversized host picture with its cursor at the far corner")
            return
        }
        let beforeWindow = peer.window?.frame
        let beforeDrawable = peerSurface.publishedGrid
        guard let before = peerSurface.renderedFrameForTesting(), let painter = peerSurface.renderer else {
            t.expect(false, desc: "the real non-owner renders its letterbox baseline")
            return
        }
        peerSurface.setRemoteViewportPresentationForTesting(.pan)
        guard let after = peerSurface.renderedFrameForTesting(),
            let clip = painter.contentClip(for: peerSurface), !clip.isEmpty,
            let cursor = peerSurface.viewPoint(forRow: 23, column: 79)
        else {
            t.expect(false, desc: "authenticated non-owner Pan supplies a viewport and rendered frame")
            return
        }
        let natural = painter.cellSize(for: peerSurface)
        let drawn = painter.drawnCellSize(for: peerSurface)
        let insets = painter.gridInsets(for: peerSurface)
        t.expect(clip.contains(cursor), desc: "Pan exposes the host cursor at native size")
        t.expect(abs(drawn.width - natural.width) < 0.01, desc: "Pan does not shrink the remote text")
        t.expect(insets.left < 0 && insets.top < 0, desc: "both oversized axes have local viewport offsets")
        let hit = peerSurface.gridHitForTesting(atViewPoint: cursor)
        t.expect(hit.strict?.row == 23 && hit.strict?.column == 79, desc: "the visible cursor maps back to its exact host cell")
        let padding = CGPoint(x: clip.minX - 1, y: clip.midY)
        let firstVisible = CGPoint(x: clip.minX, y: clip.midY)
        let paddingHit = peerSurface.gridHitForTesting(atViewPoint: padding)
        let edgeHit = peerSurface.gridHitForTesting(atViewPoint: firstVisible)
        t.expect(paddingHit.strict == nil, desc: "hidden host cells cannot be selected through Pan's padding")
        t.expect(paddingHit.report?.column == edgeHit.report?.column, desc: "padding reports clamp to a visible host cell")
        if before.width == after.width && before.height == after.height && clip.minX >= 1 {
            let scale = peerSurface.metalLayer.contentsScale
            let y = min(after.height - 1, max(0, Int(clip.midY * scale)))
            let paddingOffset = y * after.width * 4
            let interiorX = min(after.width - 1, max(0, Int(clip.midX * scale)))
            let interiorOffset = paddingOffset + interiorX * 4
            t.expect(
                before.pixels[paddingOffset..<(paddingOffset + 4)] == after.pixels[paddingOffset..<(paddingOffset + 4)],
                desc: "translated cell backgrounds stay out of the real rendered padding"
            )
            t.expect(
                after.pixels[paddingOffset..<(paddingOffset + 4)] != after.pixels[interiorOffset..<(interiorOffset + 4)],
                desc: "the rendered red host background remains visible inside the clip"
            )
        } else {
            t.expect(false, desc: "the Pan pixel fixture retains equal drawable sizes and actual left padding")
        }
        t.expect(
            peer.window?.frame == beforeWindow && peerSurface.publishedGrid == beforeDrawable,
            desc: "Pan never moves the client's window or advertised viewport"
        )
        let ownerPicture = ownerSurface.drive.readSnapshot()
        t.expect(ownerPicture.columns == 80 && ownerPicture.rows == 24, desc: "local presentation does not resize the shared host grid")
        ownerSurface.send("\rprintf '\\033[1;1H'; read -r UBQ_PAN_REPLY\r")
        t.expect(
            t.wait(
                until: {
                    let picture = peerSurface.drive.readSnapshot()
                    guard picture.cursorRow == 0 && picture.cursorColumn == 0,
                        let origin = peerSurface.viewPoint(forRow: 0, column: 0),
                        let clip = painter.contentClip(for: peerSurface)
                    else { return false }
                    return clip.contains(origin)
                },
                timeout: 20
            ),
            desc: "Pan follows a later host cursor back to the first cell"
        )

        // With equal grids and an unechoed byte, only authenticated ownership
        // changes: the origin and pixels need not change with the clip.
        owner.resizeWindow(toColumns: peerSurface.publishedGrid.columns, rows: peerSurface.publishedGrid.rows)
        ownerSurface.send("\rstty -echo; printf '\\033[1;1H'; read -r UBQ_PAN_REPLY; stty echo\r")
        guard
            t.wait(
                until: {
                    let picture = peerSurface.drive.readSnapshot()
                    return peerSurface.drive.isRemoteGeometryOwnedElsewhere && picture.cursorRow == 0 && picture.cursorColumn == 0
                        && Int(picture.columns) == peerSurface.publishedGrid.columns && Int(picture.rows) == peerSurface.publishedGrid.rows
                },
                timeout: 20
            ), let fixedOrigin = peerSurface.viewPoint(forRow: 0, column: 0),
            let fixedClip = painter.contentClip(for: peerSurface)
        else {
            t.expect(false, desc: "equal-grid ownership fixture is ready at the unchanged origin")
            return
        }
        peerSurface.send("\0")
        t.expect(
            t.wait(
                until: {
                    !peerSurface.drive.isRemoteGeometryOwnedElsewhere
                        && painter.contentClip(for: peerSurface) == nil
                        && peerSurface.viewPoint(forRow: 0, column: 0) == fixedOrigin
                },
                timeout: 20
            ),
            desc: "becoming owner removes Pan's clip without moving the cell origin"
        )
        ownerSurface.send("\0")
        t.expect(
            t.wait(
                until: {
                    peerSurface.drive.isRemoteGeometryOwnedElsewhere
                        && painter.contentClip(for: peerSurface) == fixedClip
                        && peerSurface.viewPoint(forRow: 0, column: 0) == fixedOrigin
                },
                timeout: 20
            ),
            desc: "becoming non-owner restores Pan's clip at the same origin"
        )

        // Repaint after the shell prompts and host reflow above. Those may
        // replace the original red cells; recovery must compare the actual
        // current host picture, not assume the pre-resize pixels survived.
        let clearID = UUID().uuidString
        let clearMarker = "pan-clear-" + clearID
        ownerSurface.send(
            "\rstty -echo; printf '\\033[41m\\033[2Jpan-clear-%s\\033[1;1H' '\(clearID)'; read -r UBQ_PAN_REPLY; stty echo\r"
        )
        guard waitForGridText(t, of: peerSurface, { $0.contains(clearMarker) }),
            peerSurface.drive.isRemoteGeometryOwnedElsewhere,
            let visible = peerSurface.renderedFrameForTesting(),
            visible.width == before.width, visible.height == before.height
        else {
            t.expect(false, desc: "the host repaints the current non-owner viewport before testing its removal")
            return
        }
        let middle = (visible.height / 2 * visible.width + visible.width / 2) * 4
        let ground = (visible.height / 2 * visible.width) * 4
        let scale = peerSurface.metalLayer.contentsScale
        let redX = min(after.width - 1, max(0, Int(clip.midX * scale)))
        let redY = min(after.height - 1, max(0, Int(clip.midY * scale)))
        let red = (redY * after.width + redX) * 4
        guard visible.pixels[middle..<(middle + 4)] == after.pixels[red..<(red + 4)],
            visible.pixels[middle..<(middle + 4)] != visible.pixels[ground..<(ground + 4)]
        else {
            t.expect(false, desc: "the current host picture actually contains the red pixel that will be hidden and restored")
            return
        }

        // User padding can consume all visible content. This must clear the
        // current red frame, not leave it on glass after declining an encode.
        guard let savedPadding = peerSurface.setLeftPaddingForTesting(peerSurface.bounds.width + 1) else {
            t.expect(false, desc: "the native renderer exposes its actual left padding")
            return
        }
        defer { peerSurface.setLeftPaddingForTesting(savedPadding) }
        guard let empty = peerSurface.renderedFrameForTesting() else {
            t.expect(
                false,
                desc: "a zero-visible Pan viewport still encodes a real frame (drawable \(peerSurface.metalLayer.drawableSize))"
            )
            return
        }
        let emptyClip = painter.contentClip(for: peerSurface)
        t.expect(
            emptyClip?.isEmpty == true,
            desc: "padding consumes Pan's viewport (clip \(String(describing: emptyClip)), bounds \(peerSurface.bounds))"
        )
        guard empty.width == before.width, empty.height == before.height else {
            t.expect(
                false,
                desc: "padding does not resize the drawable (\(empty.width)×\(empty.height), baseline \(before.width)×\(before.height))"
            )
            return
        }
        t.expect(
            empty.pixels[middle..<(middle + 4)] == visible.pixels[ground..<(ground + 4)],
            desc: "an empty viewport clears old terminal content to the window background"
        )
        t.expect(
            peerSurface.gridHitForTesting(atViewPoint: CGPoint(x: peerSurface.bounds.midX, y: peerSurface.bounds.midY)).strict == nil,
            desc: "an empty viewport exposes no hidden terminal cell"
        )
        peerSurface.setLeftPaddingForTesting(savedPadding)
        guard let restored = peerSurface.renderedFrameForTesting() else {
            t.expect(false, desc: "restoring visible padding produces a complete frame")
            return
        }
        t.expect(
            restored.pixels[middle..<(middle + 4)] == visible.pixels[middle..<(middle + 4)]
                && restored.pixels[middle..<(middle + 4)] != empty.pixels[middle..<(middle + 4)],
            desc: "restoring the viewport repaints the red host content"
        )
    }

    /// Exercises uniform Fit and inverse hits on an actual second attachment.
    @MainActor
    private static func verifyFit(
        _ t: UBUITestContext,
        owner: TerminalWindowController,
        ownerSurface: TerminalSurface,
        peer: TerminalWindowController,
        peerSurface: TerminalSurface
    ) {
        guard let painter = peerSurface.renderer, let ownerPainter = ownerSurface.renderer,
            let savedPadding = peerSurface.setLeftPaddingForTesting(8)
        else {
            t.expect(false, desc: "the Fit fixture has native renderers and explicit padding")
            return
        }
        // Half-size content stays above the existing 6pt floor, so this case
        // tests a complete fit rather than the separately bounded clipping.
        let savedPointSize = painter.pointSize
        painter.adopt(pointSize: 16)
        defer {
            painter.adopt(pointSize: savedPointSize)
            peerSurface.setLeftPaddingForTesting(savedPadding)
        }
        t.expect(painter.pointSize == 16, desc: "the full-fit fixture uses an explicit font above the shrink floor")
        owner.resizeWindow(toColumns: 80, rows: 24)
        peer.resizeWindow(toColumns: 48, rows: 12)
        let markerID = UUID().uuidString
        let marker = "fit-ready-" + markerID
        ownerSurface.send(
            "stty -echo; printf '\\033[41m\\033[2J\\033[Hfit-ready-%s\\033[24;80HX\\033[24;80H' '\(markerID)'; read -r UBQ_FIT_REPLY; stty echo\r"
        )
        defer {
            ownerSurface.setRemoteViewportPresentationForTesting(.letterbox)
            peerSurface.setRemoteViewportPresentationForTesting(.letterbox)
            ownerSurface.send("\rprintf '\\033[0m\\033[2J\\033[H'\r")
        }
        guard waitForGridText(t, of: peerSurface, { $0.contains(marker) }),
            t.wait(
                until: {
                    let picture = peerSurface.drive.readSnapshot()
                    return peerSurface.drive.isRemoteGeometryOwnedElsewhere && picture.columns == 80 && picture.rows == 24
                        && picture.cursorRow == 23 && picture.cursorColumn == 79
                },
                timeout: 20
            )
        else {
            let picture = peerSurface.drive.readSnapshot()
            t.expect(
                false,
                desc: "the Fit fixture has a real oversized host picture on a non-owner "
                    + "(grid \(picture.columns)×\(picture.rows), cursor \(picture.cursorColumn),\(picture.cursorRow), "
                    + "non-owner \(peerSurface.drive.isRemoteGeometryOwnedElsewhere), marker \(visibleWords(of: peerSurface).contains(marker)))"
            )
            return
        }
        let window = peer.window?.frame
        let viewport = peerSurface.publishedGrid
        let natural = painter.cellSize(for: peerSurface)
        peerSurface.setRemoteViewportPresentationForTesting(.fit)
        guard let frame = peerSurface.renderedFrameForTesting(),
            let clip = painter.contentClip(for: peerSurface), !clip.isEmpty,
            let first = peerSurface.viewPoint(forRow: 0, column: 0),
            let last = peerSurface.viewPoint(forRow: 23, column: 79)
        else {
            t.expect(false, desc: "Fit supplies the real transform and a rendered frame")
            return
        }
        let drawn = painter.drawnCellSize(for: peerSurface)
        let horizontal = drawn.width / natural.width
        let vertical = drawn.height / natural.height
        let minimum = min(1, Ubiquitty.Preferences.Zoom.clampFontZoom(0.0) / painter.pointSize)
        let expected = max(minimum, min(1, min(clip.width / (natural.width * 80), clip.height / (natural.height * 24))))
        t.expect(horizontal < 1 && abs(horizontal - vertical) < 0.0001, desc: "Fit scales both axes uniformly")
        t.expect(abs(horizontal - expected) < 0.0001, desc: "Fit uses the viewport ratio bounded by the existing font zoom minimum")
        t.expect(clip.contains(first) && clip.contains(last), desc: "both distant host cells fit inside this viewport")
        for (point, row, column) in [(first, 0, 0), (last, 23, 79)] {
            let hit = peerSurface.gridHitForTesting(atViewPoint: point)
            t.expect(
                hit.strict?.row == row && hit.strict?.column == column,
                desc: "Fit's inverse pointer map reaches host cell \(row),\(column)"
            )
        }
        let scale = peerSurface.metalLayer.contentsScale
        let middleX = min(frame.width - 1, max(0, Int(clip.midX * scale)))
        let middleY = min(frame.height - 1, max(0, Int(clip.midY * scale)))
        let middle = (middleY * frame.width + middleX) * 4
        let padding = middleY * frame.width * 4
        t.expect(
            frame.pixels[middle..<(middle + 4)] != frame.pixels[padding..<(padding + 4)],
            desc: "Fit renders the host's red background inside untouched window padding"
        )
        let fittedPixel = Array(frame.pixels[middle..<(middle + 4)])
        peerSurface.setRemoteViewportPresentationForTesting(.pan)
        t.expect(peerSurface.renderedFrameForTesting() != nil, desc: "Pan renders after Fit without a new host frame")
        let panned = painter.drawnCellSize(for: peerSurface)
        t.expect(
            abs(panned.width - natural.width) < 0.01 && abs(panned.height - natural.height) < 0.01,
            desc: "switching to Pan restores native cell size"
        )
        peerSurface.setRemoteViewportPresentationForTesting(.fit)
        if let restored = peerSurface.renderedFrameForTesting(), restored.width == frame.width, restored.height == frame.height {
            t.expect(Array(restored.pixels[middle..<(middle + 4)]) == fittedPixel, desc: "Fit repaints its content after the Pan transform")
        } else {
            t.expect(false, desc: "returning to Fit retains the same drawable")
        }
        ownerSurface.setRemoteViewportPresentationForTesting(.fit)
        t.expect(ownerSurface.renderedFrameForTesting() != nil, desc: "the geometry owner's Fit request renders")
        let ownerNatural = ownerPainter.cellSize(for: ownerSurface)
        let ownerDrawn = ownerPainter.drawnCellSize(for: ownerSurface)
        t.expect(!ownerSurface.drive.isRemoteGeometryOwnedElsewhere, desc: "the first attachment remains the authenticated geometry owner")
        t.expect(
            ownerPainter.contentClip(for: ownerSurface) == nil && ownerNatural == ownerDrawn,
            desc: "Fit does not transform the geometry owner's ordinary view"
        )
        t.expect(
            peer.window?.frame == window && peerSurface.publishedGrid == viewport,
            desc: "Fit never changes the independent window or advertised viewport"
        )
        let picture = ownerSurface.drive.readSnapshot()
        t.expect(picture.columns == 80 && picture.rows == 24, desc: "Fit and pointer reads never resize the authoritative host grid")
    }

    /// The whole connection lifecycle against a forked host.
    @MainActor
    private static func verifyLifecycle(_ t: UBUITestContext, presentation: RemoteViewportPresentation = .letterbox) {
        guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: hostBinary)
        else {
            t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return
        }
        // A home of its own under /tmp — a Unix socket path is capped at 103
        // bytes and the daemon's socket lives in this home — so nothing here
        // touches the operator's daemon.
        let root = "/tmp/ubq-lifecycle-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        // The app's own store behind Core's directory, the one every window
        // that can open a remembered session installs before it does.
        HostServers.installPairingPersistence()
        UbiquittyKit.HostDirectory.forget(host: pairingKey)
        defer {
            t.closeAllWindows()
            UbiquittyKit.HostDirectory.forget(host: pairingKey)
            if let previousHome {
                setenv("UBIQUITTY_HOME", previousHome, 1)
            } else {
                unsetenv("UBIQUITTY_HOME")
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: hostBinary)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do {
            try daemon.run()
        } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        guard
            t.wait(
                until: {
                    let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
                    return entries.contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the daemon opened its socket")
            return
        }

        let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let attachCommand = "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach"

        guard
            let owner = TerminalWindowController.spawnRemoteWindow(
                shellCommand: attachCommand,
                hostLabel: "lifecycle host",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: UbiquittyKit.HostDirectory.rememberedSessionID(host: pairingKey),
                workspaceName: "",
                hostKey: pairingKey
            ), let ownerSurface = owner.remoteSurface
        else {
            t.expect(false, desc: "a window attached to the forked daemon")
            return
        }
        guard
            t.wait(
                until: { ownerSurface.drive.remoteState == Ubiquitty.Session.State.Connected && ownerSurface.remoteSessionID != 0 },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the first window reached the daemon (\(ownerSurface.remoteFailureDetail))")
            return
        }
        let sessionID = ownerSurface.remoteSessionID

        // Captured, so a later connect to this host reattaches this shell
        // rather than opening a fresh one — which is also what makes closing
        // the window a clean detach rather than a session thrown away.
        //
        // Waited for rather than read at once: Core reaches Connected on its
        // own thread and the window hears about it on the next delivery, so the
        // claim is that the pairing arrives, not that it arrives this instant.
        t.expect(
            t.wait(until: { UbiquittyKit.HostDirectory.rememberedSessionID(host: pairingKey) == sessionID }, timeout: 20),
            desc:
                "the host's session id is remembered against the host "
                + "(\(UbiquittyKit.HostDirectory.rememberedSessionID(host: pairingKey)) for \(sessionID))"
        )
        t.expect(
            UbiquittyKit.HostDirectory.rememberedSessionID(host: pairingKey + ".elsewhere") == 0,
            desc: "and the pairing is the host's own, so another host knows nothing of this session"
        )

        // The badge, off the live connection.
        if let badge = owner.remoteConnectionIndicator {
            t.expect(
                t.wait(until: { badge.readingForTesting == "lifecycle host" }, timeout: 20),
                desc: "a connected window names its host once (\(badge.readingForTesting))"
            )
        } else {
            t.expect(false, desc: "the connected window wears the badge")
        }

        // A mark inside the shell, so "the same session" is a claim about the
        // process on the far side rather than about a number the daemon reused
        // or a screen it happened to replay. Read back through the shell's own
        // expansion and wrapped, so the answer can only come from a shell that
        // holds the variable: the line that set it carries the mark too, and
        // an unwrapped match would be satisfied by that line still on screen.
        t.expect(waitForShellAnswer(t, of: ownerSurface), desc: "the host's shell answers (\(visibleWords(of: ownerSurface)))")
        let marker = "lifecycle-" + String(UUID().uuidString.prefix(8))
        ownerSurface.send("UBQ_LIFECYCLE_MARK=\(marker); echo \"held:[$UBQ_LIFECYCLE_MARK]\"\r")
        t.expect(
            waitForGridText(t, of: ownerSurface) { $0.contains("held:[\(marker)]") },
            desc: "the mark reached the host's shell and came back (\(visibleWords(of: ownerSurface)))"
        )

        // Closing the window detaches: the daemon is asked to keep the session
        // rather than to end it, which is what the remembered id is for.
        owner.shellCloseWindow()
        t.expect(t.wait(until: { owner.isClosedForTesting }, timeout: 20), desc: "the first window closed")
        t.expect(
            UbiquittyKit.HostDirectory.rememberedSessionID(host: pairingKey) == sessionID,
            desc: "and the pairing survived the close, so the next connect has a session to ask for"
        )

        let opened = TerminalWindowController.spawnRemoteWindow(
            shellCommand: attachCommand,
            hostLabel: "lifecycle host",
            quicHost: "",
            quicBootstrapCommand: "",
            deploySSHHost: "",
            deployBinaries: [:],
            reattachSessionID: UbiquittyKit.HostDirectory.rememberedSessionID(host: pairingKey),
            workspaceName: "",
            hostKey: pairingKey
        )
        guard let reattached = opened, let reattachedSurface = reattached.remoteSurface, reattached !== owner else {
            t.expect(
                false,
                desc:
                    "connecting to the host again opened a window of its own "
                    + "(asking for session \(UbiquittyKit.HostDirectory.rememberedSessionID(host: pairingKey)); "
                    + "opened \(opened == nil ? "nothing" : (opened === owner ? "the closed window" : "a window with no surface")))"
            )
            return
        }
        guard
            t.wait(
                until: {
                    reattachedSurface.drive.remoteState == Ubiquitty.Session.State.Connected && reattachedSurface.remoteSessionID != 0
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the second connect reached the daemon (\(reattachedSurface.remoteFailureDetail))")
            return
        }
        t.expect(
            reattachedSurface.remoteSessionID == sessionID,
            desc:
                "the later connect reattached this host's session rather than spawning a fresh shell "
                + "(\(reattachedSurface.remoteSessionID) for \(sessionID))"
        )
        reattachedSurface.send("echo \"kept:[$UBQ_LIFECYCLE_MARK]\"\r")
        t.expect(
            waitForGridText(t, of: reattachedSurface) { $0.contains("kept:[\(marker)]") },
            desc:
                "and it is the same shell, still holding what was set in it before the detach "
                + "(looking for kept:[\(marker)] in \(visibleWords(of: reattachedSurface)))"
        )

        // A second client on the same session. Its own transport command, so
        // the connect opens a window rather than focusing the first one: two
        // humans on one shell is what makes the session's grid neither
        // window's to declare.
        guard
            let peer = TerminalWindowController.spawnRemoteWindow(
                shellCommand: "UBQ_LIFECYCLE_PEER=1 " + attachCommand,
                hostLabel: "lifecycle peer",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: sessionID,
                workspaceName: "",
                hostKey: ""
            ), let peerSurface = peer.remoteSurface, peer !== reattached
        else {
            t.expect(false, desc: "a second client attached to the same session in its own window")
            return
        }
        guard
            t.wait(
                until: { peerSurface.drive.remoteState == Ubiquitty.Session.State.Connected && peerSurface.remoteSessionID == sessionID },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the second client reached the same session (\(peerSurface.remoteFailureDetail))")
            return
        }

        // Restored window frames may come from a smaller earlier scenario.
        // Both drawables need room for the subsequent shrink and letterbox.
        reattached.resizeWindow(toColumns: 80, rows: 24)
        peer.resizeWindow(toColumns: 80, rows: 24)
        let geometryMarker = String(UUID().uuidString.prefix(8))
        reattachedSurface.send("printf '\\n%s%s\\n' 'geometry-ready-' '\(geometryMarker)'\r")
        guard
            waitForGridText(t, of: reattachedSurface, { $0.contains("geometry-ready-\(geometryMarker)") }),
            waitForGridText(t, of: peerSurface, { $0.contains("geometry-ready-\(geometryMarker)") })
        else {
            t.expect(false, desc: "both mirrors receive real host output after explicit initial window sizing")
            return
        }

        // One session, so one grid on the host, and both mirrors hold it. The
        // windows are each their person's: neither takes its size from the
        // host, so the one whose drawable holds another grid goes on holding
        // it. Waited for rather than read at once, since the host's frames
        // arrive on the daemon's schedule.
        let mirrorGrid = { (surface: TerminalSurface) -> (rows: Int, columns: Int) in
            let snapshot = surface.drive.readSnapshot()
            return (Int(snapshot.rows), Int(snapshot.columns))
        }
        guard
            t.wait(
                until: {
                    mirrorGrid(peerSurface) == mirrorGrid(reattachedSurface) && mirrorGrid(peerSurface).columns > 40
                        && mirrorGrid(peerSurface).rows > 12
                },
                timeout: 20
            )
        else {
            t.expect(
                false,
                desc:
                    "both mirrors settled on the host's one grid "
                    + "(peer \(mirrorGrid(peerSurface)), first \(mirrorGrid(reattachedSurface)))"
            )
            return
        }

        // The other end moves the grid: the window whose person typed last
        // is resized, the daemon reflows the session both are attached to,
        // and the peer's mirror follows. The peer's window does not: its
        // frame is its own person's, and a host's grid moves no window.
        let shared = mirrorGrid(peerSurface)
        // Smaller rather than larger: a window asked to grow past the screen
        // would be testing AppKit's frame clamp instead of the resize.
        let wantedColumns = shared.columns - 9
        let wantedRows = shared.rows - 4
        let peerFrameBefore = peer.window?.frame ?? .zero
        let peerDrawableGrid = peerSurface.publishedGrid
        reattached.resizeWindow(toColumns: wantedColumns, rows: wantedRows)
        t.expect(
            t.wait(
                until: { mirrorGrid(reattachedSurface) == (rows: wantedRows, columns: wantedColumns) },
                timeout: 20
            ),
            desc:
                "the window that asked holds the grid it asked for (mirror \(mirrorGrid(reattachedSurface)), "
                + "drawable \(reattachedSurface.publishedGrid), stated \(reattachedSurface.drive.syncTraceReport().totals.viewportsStated); "
                + "peer drawable \(peerSurface.publishedGrid), stated \(peerSurface.drive.syncTraceReport().totals.viewportsStated))"
        )
        t.expect(
            t.wait(
                until: { mirrorGrid(peerSurface) == (rows: wantedRows, columns: wantedColumns) },
                timeout: 20
            ),
            desc:
                "the other client's mirror took the host's grid without asking for it "
                + "(\(mirrorGrid(peerSurface)) against \(wantedRows)×\(wantedColumns))"
        )
        t.pump(0.5)
        t.expect(
            (peer.window?.frame ?? .zero) == peerFrameBefore,
            desc:
                "and its window stayed where its person left it "
                + "(\(String(describing: peer.window?.frame)) for \(peerFrameBefore))"
        )
        t.expect(
            peerSurface.publishedGrid == peerDrawableGrid,
            desc: "its drawable holds the grid it held (\(peerSurface.publishedGrid) for \(peerDrawableGrid))"
        )

        // The peer's larger drawable has blank space where the host has no
        // cell. A strict hit there must not offer content from another row;
        // reporting pointer events still clamps to the host's actual edge.
        if let emptyPoint = peerSurface.viewPoint(forRow: wantedRows, column: wantedColumns),
            let rightPoint = peerSurface.viewPoint(forRow: 0, column: wantedColumns),
            let leftPoint = peerSurface.viewPoint(forRow: 0, column: -1),
            let lastPoint = peerSurface.viewPoint(forRow: wantedRows - 1, column: wantedColumns - 1)
        {
            let empty = peerSurface.gridHitForTesting(atViewPoint: emptyPoint)
            let right = peerSurface.gridHitForTesting(atViewPoint: rightPoint)
            let left = peerSurface.gridHitForTesting(atViewPoint: leftPoint)
            let last = peerSurface.gridHitForTesting(atViewPoint: lastPoint)
            t.expect(empty.strict == nil, desc: "the non-owner's letterbox is not a terminal cell")
            t.expect(right.strict == nil && left.strict == nil, desc: "horizontal letterbox and left padding are not selectable")
            t.expect(
                right.report?.column == Int32(wantedColumns - 1) && left.report?.column == 0,
                desc: "horizontal pointer reports clamp to real host cells on both sides"
            )
            t.expect(
                empty.report?.row == Int32(wantedRows - 1) && empty.report?.column == Int32(wantedColumns - 1),
                desc: "pointer reports clamp to the host grid, not this client's larger viewport"
            )
            t.expect(
                last.strict?.row == wantedRows - 1 && last.strict?.column == wantedColumns - 1,
                desc: "the last real host cell remains selectable in the non-owner view"
            )
            t.expect(
                mirrorGrid(peerSurface) == (rows: wantedRows, columns: wantedColumns),
                desc: "hit testing never resizes the host replica"
            )
        } else {
            t.expect(false, desc: "the non-owner view resolves points against its drawn cells")
        }

        if presentation == .pan {
            verifyPan(t, owner: reattached, ownerSurface: reattachedSurface, peer: peer, peerSurface: peerSurface)
            return
        }
        if presentation == .fit {
            verifyFit(t, owner: reattached, ownerSurface: reattachedSurface, peer: peer, peerSurface: peerSurface)
            return
        }

        // The clipboard badge is re-read whenever the connection moves. The
        // serving fact is changed behind the badge's back — as a preference
        // edited between an attach and a later automatic reconnect would — and
        // the connection's next report is what has to pick it up.
        guard let clipboardBadge = clipboardScopeIndicator(in: peer.window) else {
            t.expect(false, desc: "the remote window's title row carries a clipboard-scope badge")
            return
        }
        t.expect(peerSurface.canChangeClipboardServing, desc: "the negotiated host offers a clipboard source to change")
        // Claimed on the session rather than through the badge's own menu, so
        // nothing but a connection report can move what the badge shows.
        t.expect(peerSurface.setClipboardServing(true), desc: "this Mac's clipboard can be claimed for the session")
        t.expect(
            t.wait(until: { peerSurface.isServingClipboardToHost && !peerSurface.isClipboardRoutingPending }, timeout: 10),
            desc: "the host acknowledged the claim"
        )
        peer.remoteSessionDidChange(on: peerSurface)
        t.expect(
            t.wait(until: { clipboardBadge.scope == .client }, timeout: 10),
            desc: "a connection report re-reads the claim rather than repeating the one attach made (\(clipboardBadge.scope))"
        )
        t.expect(peerSurface.setClipboardServing(false), desc: "the claim can be given back")
        t.expect(
            t.wait(until: { !peerSurface.isServingClipboardToHost && !peerSurface.isClipboardRoutingPending }, timeout: 10),
            desc: "the host acknowledged the revocation"
        )
        peer.remoteSessionDidChange(on: peerSurface)
        t.expect(
            t.wait(until: { clipboardBadge.scope == .host }, timeout: 10),
            desc: "and the next report follows the claim back (\(clipboardBadge.scope))"
        )

        // The shell exits: the windows mirroring it go, and a paste crossing to
        // that host goes first — it has nowhere to land and no answer coming.
        PastePushPanel.shared.dismissNow() // an earlier scenario's panel is not this one's
        PastePushPanel.shared.showPasting(toDestination: "lifecycle host", mime: "image/png", over: nil, progress: nil)
        t.pump(0.2)
        t.expect(visiblePastePushPanel() != nil, desc: "a paste to the host is on screen while it crosses")
        peerSurface.send("exit\r")
        t.expect(
            t.wait(until: { peer.isClosedForTesting && reattached.isClosedForTesting }, timeout: 20),
            desc:
                "the host session's shell exiting closed the windows mirroring it "
                + "(peer \(peer.isClosedForTesting), reattached \(reattached.isClosedForTesting))"
        )
        t.expect(
            visiblePastePushPanel() == nil,
            desc: "and the paste panel went with them rather than standing over a window that closed"
        )
    }
}

/// A window's clipboard-scope badge, found where a person sees it.
///
/// Walked out of the title row rather than taken from a handle, because the
/// claim is about what the badge shows.
///
/// - Parameter window: The window to look in.
/// - Returns: The badge, or nil when the window wears none.
@MainActor
private func clipboardScopeIndicator(in window: NSWindow?) -> ClipboardScopeIndicator? {
    guard let window else { return nil }
    for accessory in window.titlebarAccessoryViewControllers {
        if let found = firstClipboardScopeIndicator(under: accessory.view) {
            return found
        }
    }
    return nil
}

/// The first clipboard-scope badge in a view tree.
///
/// - Parameter view: The root to search.
/// - Returns: The badge, or nil when the tree holds none.
@MainActor
private func firstClipboardScopeIndicator(under view: NSView) -> ClipboardScopeIndicator? {
    if let indicator = view as? ClipboardScopeIndicator {
        return indicator
    }
    for subview in view.subviews {
        if let found = firstClipboardScopeIndicator(under: subview) {
            return found
        }
    }
    return nil
}

/// What a surface is showing, as one line, for a failure to quote.
///
/// - Parameter surface: The surface to read.
/// - Returns: Its visible words, run together and bounded.
@MainActor
private func visibleWords(of surface: TerminalSurface) -> String {
    let words = surface.gridTextForTesting().split(whereSeparator: { $0.isWhitespace })
    return words.isEmpty ? "an empty grid" : words.suffix(24).joined(separator: " ")
}

/// Whether the shell on the far side answers a probe, sent again until it does.
///
/// A line typed before that shell reads its terminal is echoed there and never
/// run, so a scenario that types its first command at once can wait on an
/// answer that never comes. The probe prints its word in two halves, so the
/// line that asks for it cannot satisfy the wait.
///
/// - Parameters:
///   - t: The scenario's context.
///   - surface: The pane whose shell is asked.
/// - Returns: Whether the shell answered within about twenty seconds.
@MainActor
private func waitForShellAnswer(_ t: UBUITestContext, of surface: TerminalSurface) -> Bool {
    let word = "shell-ready-" + String(UUID().uuidString.prefix(8))
    let middle = word.index(word.startIndex, offsetBy: 6)
    for _ in 0..<10 {
        surface.send("printf '%s%s\\n' '\(word[..<middle])' '\(word[middle...])'\r")
        for _ in 0..<20 {
            if surface.gridTextForTesting().contains(word) {
                return true
            }
            t.pump(0.1)
        }
    }
    return surface.gridTextForTesting().contains(word)
}

/// Pumps until the mirror's visible text satisfies the predicate.
///
/// - Parameters:
///   - t: The scenario's context, whose pump turns the run loop.
///   - surface: The surface whose grid is read.
///   - predicate: What the text has to say.
/// - Returns: Whether it said it before the wait ran out.
@MainActor
private func waitForGridText(_ t: UBUITestContext, of surface: TerminalSurface, _ predicate: (String) -> Bool) -> Bool {
    var remaining = 100
    while remaining > 0 {
        if predicate(surface.gridTextForTesting()) {
            return true
        }
        t.pump(0.1)
        remaining -= 1
    }
    return predicate(surface.gridTextForTesting())
}

/// The paste-push panel's window, if it is on screen.
///
/// Found by looking at what is on screen rather than through a handle the panel
/// hands out, because the claim is what a person can see. File scope because a
/// scenario is a C function pointer and carries no context.
@MainActor
private func visiblePastePushPanel() -> NSWindow? {
    NSApp.windows.first { window in
        guard window is NSPanel, window.isVisible, let content = window.contentView else { return false }
        return content.subviews.contains { ($0 as? NSTextField)?.stringValue.contains("Pasting to") == true }
    }
}
