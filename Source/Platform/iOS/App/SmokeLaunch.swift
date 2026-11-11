// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UIKit
import UbiquittyIOSBridge
import UbiquittyKit

#if UBIQUITTY_IOS_UI_TESTS
import UbiquittyCore

private typealias SyncWire = Ubiquitty.`Protocol`.Sync
#endif

/// The launch-argument smokes, this shell's counterpart of the desktop
/// main's flag block.
///
/// A phone app has no command line of its own, so the flags arrive through
/// the simulator's launch arguments and are answered once the app is live —
/// a display cycle needs a running application, which is what these smokes
/// exist to stand in a real one.
enum SmokeLaunch {
    #if UBIQUITTY_IOS_UI_TESTS
    /// Supplies only the host's Welcome platform for the keyboard accessory UI case.
    static var commandAccessoryHostPlatform: String? {
        if CommandLine.arguments.contains("--seed-command-host-darwin") { return "Darwin arm64" }
        if CommandLine.arguments.contains("--seed-command-host-linux") { return "Linux aarch64" }
        return nil
    }
    #endif
    /// Runs whichever smoke the launch arguments name, and exits with its
    /// verdict. Returns when none is named.
    @MainActor
    static func runIfRequested() {
        if CommandLine.arguments.contains("--smoke-keyboard-accessory") {
            Task { @MainActor in
                let passed = await KeyboardAccessorySmokeEntry.run()
                report("keyboard-accessory: -- \(passed ? "PASS" : "FAIL")")
                exit(passed ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--smoke-background-refresh") {
            Task { @MainActor in
                let passed = await BackgroundRefreshSmoke.run()
                report("background-refresh: -- \(passed ? "PASS" : "FAIL")")
                exit(passed ? 0 : 1)
            }
            return
        }
        #if UBIQUITTY_IOS_UI_TESTS
        // Outside the normal --smoke battery, which runs the release build:
        // only the --ui-tests build has Core's question-injection door and
        // the cold-resume fixture. Scripts/run-ios-ui-tests.sh runs both.
        if CommandLine.arguments.contains("--check-structure-consent") {
            let passed = structureConsentTracksTheLiveQuestion() && secondPaneQuestionWaitsOnItsPane()
            report("structure-consent: -- \(passed ? "PASS" : "FAIL")")
            exit(passed ? 0 : 1)
        }
        if CommandLine.arguments.contains("--check-cold-resume") {
            Task { @MainActor in
                let passed = await ColdResumeSmoke.run()
                report("cold-resume: -- \(passed ? "PASS" : "FAIL")")
                exit(passed ? 0 : 1)
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--ios-snapshot") {
            let passed = IOSSnapshotLaunch.run()
            report("ios-snapshot: -- \(passed ? "PASS" : "FAIL")")
            exit(passed ? 0 : 1)
        }
        let legs: [(String, @MainActor () -> Bool)] = [
            ("--smoke-draw-entry", { DrawEntrySmokeEntry.run() }),
            ("--smoke-clipboard", { clipboardReachesThePasteboard() }),
            ("--smoke-touch", { TouchSmokeEntry.run() }),
            ("--smoke-accessibility-value", { AccessibilityValueSmokeEntry.run() }),
            ("--smoke-network-path", { NetworkPathSmokeEntry.run() }),
            ("--smoke-connection-log", { ConnectionLogSmokeEntry.run() }),
            ("--smoke-ssh-pipeline", { SSHPipelineSmokeEntry.run() }),
            ("--smoke-ssh-connect", { SSHConnectSmokeEntry.run() }),
            ("--smoke-secret-store", { SecretStoreSmokeEntry.run() }),
            ("--smoke-host-record", { HostRecordSmokeEntry.run() }),
            ("--smoke-second-pick", { SecondPickSmokeEntry.run() }),
            ("--smoke-redial", { RedialSmokeEntry.run() }),
            ("--smoke-bootstrap-retry", { BootstrapRetrySmokeEntry.run() }),
            ("--smoke-bootstrap-supersede", { BootstrapSupersedeSmokeEntry.run() }),
            ("--smoke-terminal-ground", { TerminalGroundSmokeEntry.run() }),
            ("--smoke-light-first-frame", { TerminalFirstFrameGroundSmokeEntry.run() }),
            ("--smoke-hint", { HintSmokeEntry.run() }),
            ("--smoke-screen-visibility", { ScreenVisibilitySmokeEntry.run() }),
            ("--smoke-background-view", { BackgroundViewSmokeEntry.run() }),
            ("--smoke-pane-arrangement", { PaneArrangementSmokeEntry.run() }),
            ("--smoke-swipe-navigation", { SwipeNavigationSmokeEntry.run() }),
            ("--smoke-session-status", { sessionStatusReachesTheModel() }),
            ("--smoke-pointer-lock", { PointerLockSmokeEntry.run() }),
            ("--smoke-cursor-blink", { CursorBlinkSmokeEntry.run() }),
            ("--smoke-surface-focus", { SurfaceFocusSmokeEntry.run() }),
            ("--smoke-inline-image", { InlineImageSmokeEntry.run() }),
            ("--smoke-rich-text", { RichTextSmokeEntry.run() }),
            ("--smoke-rich-text-selection", { RichTextSelectionSmokeEntry.run() }),
            ("--smoke-skip-ink", { SkipInkSmokeEntry.run() }),
            ("--smoke-configuration", { ConfigurationSmokeEntry.run() }),
            ("--smoke-password-lock", { PasswordLockSmokeEntry.run() }),
            ("--smoke-notification-presentation", { NotificationPresentationSmoke.run() }),
        ]
        for (flag, leg) in legs where CommandLine.arguments.contains(flag) {
            let passed = leg()
            // One verdict line, printed here rather than by each leg. simctl
            // answers for the LAUNCH and not for the process, so the runner
            // reads this line — and a leg that spelled its own would be a leg
            // the runner could silently stop understanding.
            report("\(flag.dropFirst(8)): -- \(passed ? "PASS" : "FAIL")")
            exit(passed ? 0 : 1)
        }
    }

    #if UBIQUITTY_IOS_UI_TESTS
    /// Checks that a question one pane holds while another pane's is shown
    /// waits on its pane, rather than being declined, and is shown once the
    /// sheet closes.
    @MainActor
    private static func secondPaneQuestionWaitsOnItsPane() -> Bool {
        let model = TerminalSessionModel()
        defer { model.disconnect() }
        model.seedWorkspaceForTesting(
            [
                TerminalPane(id: 1, title: "first", windowIndex: 0, tabIndex: 0, tabTitle: "Tab 1"),
                TerminalPane(id: 2, title: "second", windowIndex: 0, tabIndex: 0, tabTitle: "Tab 1"),
            ],
            focusing: 1
        )
        guard let first = model.surface(forPane: 1), let second = model.surface(forPane: 2), first !== second else {
            report("structure-consent: the seeded workspace has no two panes to ask through")
            return false
        }
        var request = SyncWire.StructureConsent()
        request.requestID = 21
        request.sessionID = 2
        request.workspaceID = 7
        request.revision = 1
        request.workspaceName = std.string("review")
        request.method = std.string("workspace.rename")
        request.parameters = std.string("{\"workspace\":7,\"name\":\"release\"}")
        request.peerProcess = std.string("/usr/bin/tool")
        first.drive.noteStructureConsentForTesting(request)
        first.serviceIngestEvents()
        guard let shown = model.consentRequest, shown.surface === first else {
            report("structure-consent: the first pane's question was not shown")
            return false
        }
        request.requestID = 22
        second.drive.noteStructureConsentForTesting(request)
        second.serviceIngestEvents()
        guard model.consentRequest?.id == shown.id, second.drive.pendingStructureConsent != nil else {
            report("structure-consent: a second pane's question was declined while another was shown")
            return false
        }
        model.answerConsent(shown, decision: .deny)
        first.serviceIngestEvents()
        guard let next = model.consentRequest, next.surface === second else {
            report("structure-consent: the question that waited was not shown when the sheet closed")
            return false
        }
        model.answerConsent(next, decision: .deny)
        return true
    }

    /// Checks Core's operation identity through the real iOS session model.
    @MainActor
    private static func structureConsentTracksTheLiveQuestion() -> Bool {
        let model = TerminalSessionModel()
        guard let surface = model.surfaceForDrawing() else { return false }
        defer { model.disconnect() }
        var request = SyncWire.StructureConsent()
        request.requestID = 11
        request.sessionID = 2
        request.workspaceID = 7
        request.revision = 1
        request.workspaceName = std.string("review")
        request.method = std.string("workspace.rename")
        request.parameters = std.string("{\"workspace\":7,\"name\":\"release\"}")
        request.peerProcess = std.string("/usr/bin/tool")
        surface.drive.noteStructureConsentForTesting(request)
        surface.serviceIngestEvents()
        guard let first = model.consentRequest, let firstPrompt = first.structurePrompt,
            first.question == String(Ubiquitty.Security.structureConsentText(request).question),
            !first.allowsPersistentGrant
        else {
            report("structure-consent: Core's exact one-operation question did not reach the model")
            return false
        }
        request.requestID = 12
        surface.drive.noteStructureConsentForTesting(request)
        surface.serviceIngestEvents()
        guard model.consentRequest?.id == first.id else {
            report("structure-consent: a queued question replaced the displayed one")
            return false
        }
        surface.drive.noteStructureConsentResolvedForTesting(11)
        surface.serviceIngestEvents()
        guard let second = model.consentRequest, second.id != first.id,
            second.structurePrompt?.token != firstPrompt.token
        else {
            report("structure-consent: retirement did not present the next question")
            return false
        }
        model.answerConsent(first, decision: .allowOnce)
        guard model.consentRequest?.id == second.id,
            surface.drive.pendingStructureConsent?.token == second.structurePrompt?.token
        else {
            report("structure-consent: a stale sheet answered its successor")
            return false
        }
        model.answerConsent(second, decision: .deny)
        surface.serviceIngestEvents()
        guard model.consentRequest == nil, surface.drive.pendingStructureConsent == nil else {
            report("structure-consent: denying the displayed question did not settle it")
            return false
        }
        request.requestID = 11
        surface.drive.noteStructureConsentForTesting(request)
        surface.serviceIngestEvents()
        guard let reused = model.consentRequest, reused.id != first.id else {
            report("structure-consent: the reused host request number kept its old identity")
            return false
        }
        model.answerConsent(first, decision: .allowOnce)
        guard model.consentRequest?.id == reused.id else { return false }
        surface.drive.noteStructureConsentResolvedForTesting(11)
        surface.serviceIngestEvents()
        guard model.consentRequest == nil else {
            report("structure-consent: final host retirement left a sheet standing")
            return false
        }
        surface.drive.noteStructureConsentForTesting(request)
        surface.serviceIngestEvents()
        guard model.consentRequest != nil else { return false }
        model.disconnect()
        guard model.consentRequest == nil else {
            report("structure-consent: disconnect kept an answerable question")
            return false
        }
        return true
    }
    #endif

    /// Verifies program status and bells reach the persistent session model.
    ///
    /// - Returns: Whether the model reflects the emitted terminal events.
    @MainActor
    private static func sessionStatusReachesTheModel() -> Bool {
        let model = TerminalSessionModel()
        guard let surface = model.surfaceForDrawing() else { return false }
        surface.feed(Data("\u{1b}]21337;indicator=#5f87ff;status=Waiting;status-color=#5f87ff\u{7}\u{7}".utf8))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (!model.hasUnheardBell || model.programStatusLabel != "Waiting") {
            surface.serviceIngestEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard model.hasUnheardBell, model.programStatusLabel == "Waiting", model.programStatusColor != nil else {
            report(
                "session-status: bell=\(model.hasUnheardBell), label=\(model.programStatusLabel), color=\(model.programStatusColor != nil)"
            )
            return false
        }
        model.screenDidAppear()
        if UIApplication.shared.applicationState == .active && model.hasUnheardBell {
            report("session-status: opening an active session did not clear its bell")
            return false
        }
        surface.feed(Data("\u{1b}]21337;indicator=;status=;status-color=\u{7}".utf8))
        let clearDeadline = Date().addingTimeInterval(3)
        while Date() < clearDeadline && model.programStatusColor != nil {
            surface.serviceIngestEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return model.programStatusLabel.isEmpty && model.programStatusColor == nil
    }

    /// Whether a `--seed-host-sessions` launch stands the showcase host in for
    /// the host's answer.
    ///
    /// The picker is reached over a QUIC carrier to a daemon holding sessions,
    /// which no offline run has. The showcase host is the one every
    /// frontend's outline is checked against
    /// (`Tests/Core/Session/ShowcaseSessionTree.h`): named workspaces of
    /// several windows, a pane at its prompt in a workspace that ends when
    /// detached, people and an agent attached, and a workspace nothing runs
    /// in. It is held where the host's tree lands, so Core builds the rows a
    /// case reads.
    ///
    /// What this cannot prove is the wire: the tree arrives where the host's
    /// answer lands rather than through it, so the live lane is what says a
    /// listing crosses at all.
    static var isSeedingHostSessions: Bool {
        CommandLine.arguments.contains("--seed-host-sessions")
    }

    /// Whether a `--seed-connected-host` launch settles every connect as
    /// connected without dialling, and stands the showcase host in for the
    /// tree a watch follows while the connection is up.
    ///
    /// What a live connection shows — a host's outline under its row on the
    /// Hosts screen, a terminal that reads as connected — needs a host
    /// holding workspaces, which no offline run has. The connect settles
    /// through the presentation a connected carrier takes, and the tree is
    /// held where a watch's report lands, so Core builds the rows a case
    /// reads and decides how current they are.
    ///
    /// What this cannot prove is the wire: neither the carrier nor the
    /// watch's connection is dialled, so Core's directory tests and the live
    /// lane are what say a watch crosses at all.
    static var isSeedingConnectedHost: Bool {
        CommandLine.arguments.contains("--seed-connected-host")
    }

    /// What a seeded host answers a listing with.
    enum SeededHostTree {
        /// The showcase host.
        case showcase
        /// A host holding nothing.
        case empty
        /// No answer: the question could not be asked.
        case unanswered
        /// The directory is busy with another errand and refuses the ask,
        /// as a live one does while a terminate or a rename is out.
        case busy
    }

    /// What a seeding launch's host answers the next listing with, nil for a
    /// launch that seeds none.
    ///
    /// Besides the showcase host, three hosts a case needs and no offline run
    /// has: `--seed-empty-host` holds nothing; `--seed-unanswered-host` never
    /// answers; and `--seed-host-filled-by-attach` is a fresh host. It holds
    /// nothing until this device has connected to it; then its directory is
    /// busy for the first ask, as it is while the errand before it is still
    /// out, and from the next ask on it holds the showcase host's workspaces —
    /// the host as the person sees it on the first visit, and again once their
    /// first workspace runs there.
    ///
    /// - Parameters:
    ///   - hasConnected: Whether the model has connected since launch.
    ///   - refusals: How many asks the seeded directory has refused since.
    /// - Returns: The answer, or nil to ask a real host.
    static func seededHostTree(hasConnected: Bool, refusals: Int) -> SeededHostTree? {
        let arguments = CommandLine.arguments
        if arguments.contains("--seed-host-sessions") { return .showcase }
        if arguments.contains("--seed-empty-host") { return .empty }
        if arguments.contains("--seed-unanswered-host") { return .unanswered }
        if arguments.contains("--seed-host-filled-by-attach") {
            guard hasConnected else { return .empty }
            return refusals == 0 ? .busy : .showcase
        }
        return nil
    }

    /// Whether a `--seed-build-refusal` launch stands a host of an older build
    /// in for the host every connect dials.
    ///
    /// A host of another build refuses the handshake with `VersionMismatch`
    /// and states its build, and the app says which end to update. No offline
    /// run has a host of another build to dial, so each connect of this launch
    /// settles on that refusal without opening a carrier, handed to the same
    /// presentation a refusal read from the carrier is, so Core writes the
    /// sentence a case reads.
    ///
    /// What this cannot prove is the handshake: the refusal is held where the
    /// host's lands rather than sent through it, so Core's handshake tests are
    /// what say another build is refused at all.
    static var isSeedingBuildRefusal: Bool {
        CommandLine.arguments.contains("--seed-build-refusal")
    }

    /// Whether a `--seed-workspace` launch stands a workspace of three tabs in
    /// for the host every connect dials.
    ///
    /// No offline run has a host holding tabs and panes, so the connect builds
    /// the showcase workspace instead (``TerminalSessionModel/seedShowcaseWorkspace()``):
    /// real surfaces fed what programs print, whose requests the model answers
    /// itself. What this cannot prove is the host's side of a request; the
    /// live lane says a rename or a reorder crosses at all.
    static var isSeedingWorkspace: Bool {
        CommandLine.arguments.contains("--seed-workspace")
    }

    /// Whether a `--seed-sign-in-prompt` launch stands a server that asks for a
    /// password, and refuses it, in for the host every connect dials.
    ///
    /// No offline run has an SSH server to ask, so each connect of this launch
    /// raises the password prompt the sign-in raises, through the same model
    /// path, and settles on the refusal a wrong password meets: the prompt,
    /// the failure banner and Connection Details are reached as a person
    /// reaches them.
    ///
    /// What this cannot prove is the sign-in: the request is raised where the
    /// server's lands rather than sent by one, so SSHConnectSmoke is what says
    /// a server's password request crosses at all.
    static var isSeedingSignInPrompt: Bool {
        CommandLine.arguments.contains("--seed-sign-in-prompt")
    }

    /// The file every smoke line is appended to, in the app's temporary
    /// directory inside its data container, where `Scripts/run-ios-smokes.sh`
    /// reads the verdict once the launch returns.
    static let reportFileName = "smoke-report.txt"

    /// Writes one line to stderr, which is where the simulator console reads,
    /// and appends it to the report file.
    ///
    /// The console can lose the last lines a process writes before it exits.
    /// A line is in the report file once its write returns, so the runner
    /// judges a smoke by the file and shows the console only as diagnostics.
    ///
    /// - Parameter line: The line, without its newline.
    static func report(_ line: String) {
        let data = Data((line + "\n").utf8)
        FileHandle.standardError.write(data)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(reportFileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: url) else {
            return
        }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data)
        try? file.close()
    }

    /// Puts a surface in a window of the app's scene, which is what makes the
    /// toolkit run display passes for it.
    ///
    /// - Parameter surface: The surface to show.
    /// - Returns: The window, which the caller hides when it is done, or nil
    ///   when the app has no scene to show it in.
    @MainActor
    static func present(_ surface: TerminalSurface) -> UIWindow? {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else {
            return nil
        }
        let window = UIWindow(windowScene: scene)
        surface.frame = window.bounds
        window.addSubview(surface)
        window.makeKeyAndVisible()
        return window
    }

    /// Whether text the terminal copies arrives on the system pasteboard.
    ///
    /// Driven through PAL, not through the shell's own writer: with nothing
    /// installed in the seam, every copy on this platform reaches a null sink
    /// and the terminal has no clipboard, while a leg that called the writer
    /// directly would still pass.
    @MainActor
    private static func clipboardReachesThePasteboard() -> Bool {
        // Multibyte, because the seam carries a byte count rather than a
        // character count: a writer that took one for the other truncates here
        // and matches on a plain ASCII string.
        let sent = "ubiquitty ✓ copied"
        UIPasteboard.general.string = "not the text under test"
        sent.withCString { Ubiquitty.PAL.clipboardSetText(std.string_view($0)) }
        let landed = UIPasteboard.general.string
        let ok = landed == sent
        report("smoke-clipboard: sent=\(sent.utf8.count) bytes landed=\(landed?.utf8.count ?? -1)")
        return ok
    }
}
