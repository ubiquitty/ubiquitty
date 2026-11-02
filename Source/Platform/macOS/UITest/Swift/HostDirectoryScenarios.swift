// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

import struct UbiquittyRenderKit.HostDaemonInstance
import struct UbiquittyRenderKit.HostOutlineRow

// HostDirectoryScenarios.swift — the Connect window's Ubiquitty Host page,
// driven through the pieces the buttons call rather than through the buttons.
//
// Three claims, and each is one a model test could not make. The saved-server
// store and Core's pairing memory are two halves of one seam: the store is this
// app's defaults and the record's meaning is Core's, so only a running app has
// both. The connect rule is Core's, and what is worth asserting here is that
// the window ASKS it — a page that spelled the rule in Swift would answer these
// same inputs and drift the day Core's answer changed. And the terminate alert's
// safe-first shape is the one thing standing between the Delete key and a
// session somebody is working in.

/// Registers the host-directory scenarios with the UI-test runner.
enum HostDirectoryScenarios {
    /// The defaults keys these scenarios write, cleared around each one so a run
    /// leaves the operator's saved servers as it found them.
    private static let touchedDefaultsKeys = ["UBHostServers", "UBHostSessionPairings"]

    /// Registers every scenario in this file.
    static func register() {
        if ProcessInfo.processInfo.environment["UBIQUITTY_TEST_DAEMON_REPLACEMENT"] == "1" {
            UBUITestRegister("connect_vanished_daemon_restores_workspace_and_opens_unpinned") { context in
                guard let t = context else { return }
                MainActor.assumeIsolated { verifyVanishedDaemon(t) }
            }
        }
        UBUITestRegister("connect_host_servers_persist_with_a_workspace_name") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()

                var server = HostServers.blank()
                server.name = "Build Box"
                server.host = "builder@example.com"
                server.workspaceName = "release"
                HostServers.save([server])

                let readBack = HostServers.all()
                t.expect(readBack.count == 1, desc: "one server was saved and one read back (\(readBack.count))")
                guard let stored = readBack.first else { return }
                t.expect(stored.id == server.id, desc: "the row kept its identity across the store")
                t.expect(stored.name == "Build Box", desc: "the name read back (\(stored.name))")
                t.expect(stored.host == "builder@example.com", desc: "the host read back (\(stored.host))")
                t.expect(stored.kind == .ubiquittyHost, desc: "the kind read back (\(stored.kind.title))")
                t.expect(
                    stored.workspaceName == "release",
                    desc: "the predefined workspace name read back (\(stored.workspaceName))"
                )
                t.expect(
                    (UserDefaults.standard.array(forKey: "UBHostServers") as? [[String: Any]])?.first?["keepsUnnamedSessions"] == nil,
                    desc: "a saved row carries no per-host session lifetime: every session outlives its window"
                )

                // The pairing is the store's other half: Core writes an opaque
                // record through the seam this window installs, and a later
                // recall has to find it. A store that dropped the bytes would
                // reattach to nothing and every connect would open a new shell.
                HostServers.installPairingPersistence()
                HostDirectory.forget(host: stored.pairingKey)
                HostDirectory.remember(host: stored.pairingKey, sessionID: 4321, workspaceName: "release")
                t.expect(
                    HostDirectory.rememberedSessionID(host: stored.pairingKey) == 4321,
                    desc:
                        "the pairing read back through the installed store (\(HostDirectory.rememberedSessionID(host: stored.pairingKey)))"
                )
                t.expect(
                    HostDirectory.rememberedWorkspaceName(host: stored.pairingKey) == "release",
                    desc:
                        "and so did the workspace it was attached under (\(HostDirectory.rememberedWorkspaceName(host: stored.pairingKey)))"
                )
                HostDirectory.forget(host: stored.pairingKey)
                t.expect(
                    HostDirectory.rememberedSessionID(host: stored.pairingKey) == 0,
                    desc: "forgetting a host left nothing behind for the next connect to read"
                )
            }
        }

        UBUITestRegister("connect_host_connect_asks_core_for_the_plan") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                HostServers.installPairingPersistence()

                var server = HostServers.blank()
                server.name = "Build Box"
                server.host = "builder@example.com"
                HostDirectory.forget(host: server.pairingKey)
                defer { HostDirectory.forget(host: server.pairingKey) }

                let directory = HostDirectoryModel()
                directory.isDiallingSuppressedForTesting = true

                // Each of Core's plans, said out loud: the default button's
                // title and enabled state, and the sentence beside it. The
                // titles come from the plan the window asked Core for, so a
                // window that decided in Swift would title these from its own
                // answer and drift the day Core's changed.
                @MainActor
                func expectAction(_ title: String, plan: HostAttachPlan, isEnabled: Bool, sentenceContains fragment: String) {
                    let action = directory.primaryActionForTesting()
                    t.expect(action.title == title, desc: "the default reads “\(title)” (\(action.title))")
                    t.expect(action.plan == plan, desc: "for Core's plan \(plan) (\(String(describing: action.plan)))")
                    t.expect(action.isEnabled == isEnabled, desc: "and is \(isEnabled ? "enabled" : "disabled") for \(plan)")
                    t.expect(action.sentence.contains(fragment), desc: "the sentence says what Return does (\(action.sentence))")
                }

                // A predefined name the host holds: attach to it. The host is
                // the showcase host, held in the directory's own client.
                server.workspaceName = "api"
                directory.point(at: server)
                directory.holdShowcaseHostForTesting(.listed)
                expectAction("Open “api”", plan: .attachNamed, isEnabled: true, sentenceContains: "the workspace Build Box always opens")
                let named = directory.plannedConnectForTesting()
                t.expect(
                    named?.workspaceID != 0
                        && directory.outline.rows.first { $0.title == "api" }?.id?.number == UInt64(named?.workspaceID ?? 0),
                    desc: "the named plan carries the workspace its name resolves to, so the window marks its row without matching names"
                )
                t.expect(
                    directory.outline.rows.first { $0.title == "api" }.map { directory.marker(for: $0) } == .alwaysOpens,
                    desc: "and that row is the one marked as always opened"
                )

                // The same name against a host holding nothing under it.
                server.workspaceName = "nightly"
                directory.point(at: server)
                expectAction(
                    "Create “nightly”",
                    plan: .createNamed,
                    isEnabled: true,
                    sentenceContains: "Starts a workspace named “nightly”"
                )

                // No name and a host with workspaces: Core asks the person,
                // and the sentence beside the default is Core's question.
                server.workspaceName = ""
                directory.point(at: server)
                expectAction("Open", plan: .chooseFromList, isEnabled: true, sentenceContains: "5 workspaces")
                t.expect(
                    directory.primaryActionForTesting().sentence == directory.question?.shortText,
                    desc: "the bar uses Core's short question"
                )
                t.expect(!directory.connect(), desc: "no name and a listed host opens no window")
                t.expect(directory.presentedQuestion != nil, desc: "it puts Core's question in front of the person")
                directory.presentedQuestion = nil

                // No name and nothing held: a fresh session, with no question.
                directory.holdShowcaseHostForTesting(.holdingNothing)
                expectAction(
                    "New Workspace",
                    plan: .createNew,
                    isEnabled: true,
                    sentenceContains: "keeps running after you close its window"
                )
                t.expect(directory.question == nil, desc: "a plan Core picks itself asks nothing")

                // A remembered pairing re-homes while the host still lists it.
                directory.holdShowcaseHostForTesting(.listed)
                guard let api = directory.outline.rows.first(where: { $0.title == "api" }), api.open.how == .bySession else {
                    t.expect(false, desc: "the api workspace's row says which session opening it attaches to")
                    return
                }
                HostDirectory.remember(host: server.pairingKey, sessionID: api.open.sessionID, workspaceName: "api")
                expectAction(
                    "Reopen “api”",
                    plan: .attachByID,
                    isEnabled: true,
                    sentenceContains: "the workspace you last used on Build Box"
                )
                t.expect(directory.marker(for: api) == .lastUsed, desc: "and its row is marked as last used")

                // The host no longer lists it: the plan falls back to the
                // rule, and Core names the session that ended.
                HostDirectory.remember(host: server.pairingKey, sessionID: 9_999, workspaceName: "gone")
                guard let vanished = directory.plannedConnectForTesting() else {
                    t.expect(false, desc: "the directory planned a connect over a vanished pairing")
                    return
                }
                t.expect(
                    vanished.plan != .attachByID,
                    desc: "a remembered session the host no longer lists is not re-homed to (\(vanished.plan))"
                )
                t.expect(vanished.vanishedSessionID == 9_999, desc: "and Core names it as ended (\(vanished.vanishedSessionID))")

                // Before any answer, with nothing remembered, Connect waits.
                HostDirectory.forget(host: server.pairingKey)
                let unanswered = HostDirectoryModel()
                unanswered.point(at: server)
                unanswered.markListingOutstandingForTesting()
                let waiting = unanswered.primaryActionForTesting()
                t.expect(
                    waiting.title == "Connect" && waiting.plan == .awaitListing && waiting.isEnabled,
                    desc: "an unanswered host reads Connect (\(waiting.title))"
                )
            }
        }

        UBUITestRegister("connect_selected_row_is_handed_to_core") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                HostServers.installPairingPersistence()

                var server = HostServers.blank()
                server.name = "Build Box"
                server.host = "uitest-chosen@ubiquitty.invalid"
                HostDirectory.forget(host: server.pairingKey)
                defer { HostDirectory.forget(host: server.pairingKey) }

                let directory = HostDirectoryModel()
                directory.isDiallingSuppressedForTesting = true
                directory.point(at: server)
                directory.holdShowcaseHostForTesting(.listed)
                guard let deploy = directory.outline.rows.first(where: { $0.level == .workspace && $0.title == "deploy" }) else {
                    t.expect(false, desc: "the deploy workspace has a row")
                    return
                }

                // The selected row is Core's chosen input: the plan attaches
                // to the session Core says opening the row attaches to, and
                // the default is titled from that plan.
                directory.selection = deploy.key
                let chosen = directory.primaryActionForTesting()
                t.expect(chosen.title == "Open “deploy”", desc: "a selected row titles the default after it (\(chosen.title))")
                t.expect(chosen.plan == .attachByID, desc: "and Core plans an attach by id (\(String(describing: chosen.plan)))")
                t.expect(chosen.sentence.contains("2 people are attached"), desc: "and the sentence says who is on it (\(chosen.sentence))")
                t.expect(
                    deploy.open.how == .bySession && directory.plannedConnectForTesting()?.sessionID == deploy.open.sessionID,
                    desc: "Core's plan names the session the row opens (\(directory.plannedConnectForTesting()?.sessionID ?? 0))"
                )

                // The host stops listing the row: the choice no longer stands,
                // and the default falls back to Core's rule.
                directory.holdShowcaseHostForTesting(.holdingNothing)
                t.expect(directory.selection == nil, desc: "a selected row the host lost is selected no longer")
                let fallen = directory.primaryActionForTesting()
                t.expect(
                    fallen.plan == .createNew,
                    desc: "and the default falls back to the rule (\(String(describing: fallen.plan)))"
                )
            }
        }

        UBUITestRegister("connect_host_connect_waits_for_the_hosts_answer") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                HostServers.installPairingPersistence()

                // A host key nothing else files a pairing under, forgotten on
                // the way out so the run leaves no memory behind.
                var server = HostServers.blank()
                server.name = "Pending Box"
                server.host = "uitest-pending@ubiquitty.invalid"
                HostDirectory.forget(host: server.pairingKey)
                defer { HostDirectory.forget(host: server.pairingKey) }

                let directory = HostDirectoryModel()
                directory.isDiallingSuppressedForTesting = true
                directory.point(at: server)
                // The ask is out and unanswered, which is the state a person
                // pressing Connect right after selecting the host meets.
                directory.markListingOutstandingForTesting()

                // A remembered session is returned to without the answer: the
                // host has not said it ended, and the attach is attach-only, so
                // the host refuses rather than replaces one that did.
                HostDirectory.remember(host: server.pairingKey, sessionID: 42, workspaceName: "")
                guard let remembered = directory.plannedConnectForTesting() else {
                    t.expect(false, desc: "the directory planned a connect for a host it was pointed at")
                    return
                }
                t.expect(
                    remembered.plan == .attachByID && remembered.sessionID == 42,
                    desc:
                        "an unanswered host with a remembered session reattaches to it (plan \(remembered.plan), id \(remembered.sessionID))"
                )
                t.expect(
                    remembered.plan != .createNew,
                    desc: "and an unanswered listing is never read as a host holding nothing"
                )
                t.expect(
                    directory.primaryActionForTesting().title == "Reopen Workspace",
                    desc: "and the default reopens it before any listing (\(directory.primaryActionForTesting().title))"
                )

                // Nothing remembered: the connect waits for the host instead of
                // opening a fresh session beside whatever it holds.
                HostDirectory.forget(host: server.pairingKey)
                let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
                let before = directory.primaryActionForTesting()
                t.expect(
                    before.title == "Connect" && before.isEnabled,
                    desc: "with nothing remembered the default reads Connect (\(before.title))"
                )
                t.expect(!directory.connect(), desc: "a connect before the host answers opens no window")
                t.expect(directory.isConnectPending, desc: "and waits for the answer")
                let waiting = directory.primaryActionForTesting()
                t.expect(
                    waiting.title == "Waiting for Pending Box…" && !waiting.isEnabled,
                    desc: "the default says it is waiting, and is disabled (\(waiting.title))"
                )

                // Esc stops the wait, through the window's own layered Escape.
                let connectModel = ConnectModel.shared
                connectModel.setHostsForTesting([server])
                connectModel.directory.isDiallingSuppressedForTesting = true
                defer { connectModel.directory.isDiallingSuppressedForTesting = false }
                ConnectWindowController.show(place: .host(server.id))
                connectModel.directory.markListingOutstandingForTesting()
                _ = connectModel.directory.connect()
                t.expect(connectModel.directory.isConnectPending, desc: "the window's connect is waiting too")
                ConnectWindowController.shared.cancelOperation(nil)
                t.expect(!connectModel.directory.isConnectPending, desc: "Esc stops the waiting connect")
                t.expect(ConnectWindowController.shared.window?.isVisible == true, desc: "without closing the window")
                ConnectWindowController.shared.window?.close()
                // The Connect window is the one this scenario showed, and it
                // stays among the app's windows once closed, as it is kept to
                // be shown again; whether it existed before depends on which
                // scenario ran first. Any other window is one the waiting
                // connect opened.
                let opened = NSApp.windows.filter {
                    !windowsBefore.contains(ObjectIdentifier($0)) && $0 !== ConnectWindowController.shared.window
                }
                t.expect(
                    opened.isEmpty,
                    desc: "no window was opened while waiting (\(opened.map { "\(type(of: $0)) “\($0.title)”" }))"
                )

                // The answer lands holding workspaces and nothing picks one:
                // the waiting connect runs the rule over it and asks the
                // person Core's question.
                var didOpenWindow = false
                directory.pendingConnectDidOpenWindow = { didOpenWindow = true }
                directory.holdShowcaseHostForTesting(.listed)
                t.expect(!directory.isConnectPending, desc: "the waiting connect ran once the host answered")
                t.expect(!didOpenWindow, desc: "a host holding workspaces with none remembered opens no window")
                t.expect(directory.presentedQuestion != nil, desc: "the connect that waited asks the person Core's question")
                t.expect(
                    directory.primaryActionForTesting().plan == .chooseFromList,
                    desc: "over Core's plan to ask (\(directory.primaryActionForTesting().title))"
                )
            }
        }

        UBUITestRegister("host_handoff_links_require_review_and_contain_no_credentials") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let locator = HostHandoffLocator(host: "user@build.example", daemonInstanceID: 17, sessionID: 42) else {
                    t.expect(false, desc: "a valid authenticated-session locator can be built")
                    return
                }
                t.expect(HostHandoffLocator(url: locator.url) == locator, desc: "a locator retains its exact host, daemon, and session")
                for suffix in ["&token=secret", "&host=other.example", "#secret"] {
                    t.expect(
                        HostHandoffLocator(url: URL(string: locator.url.absoluteString + suffix)!) == nil,
                        desc: "unrecognized or duplicate authority is refused"
                    )
                }
                t.expect(
                    HostHandoffLocator(host: "-oProxyCommand=bad", daemonInstanceID: 17, sessionID: 42) == nil,
                    desc: "an SSH option cannot be a host"
                )
                t.expect(
                    HostHandoffLocator(host: "host", daemonInstanceID: 0, sessionID: 42) == nil,
                    desc: "a link cannot omit its daemon identity"
                )
                let alert = SessionHandoff.reviewAlert(locator)
                t.expect(
                    alert.messageText.contains("user@build.example") && alert.messageText.contains("42"),
                    desc: "review names the destination and session"
                )
                t.expect(
                    alert.buttons.first?.title == "Cancel" && alert.buttons.first?.keyEquivalent == "\r",
                    desc: "Return leaves the remote host untouched"
                )
            }
        }

        UBUITestRegister("host_management_lists_and_revokes_tokens_on_an_isolated_daemon") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyManagement(t) }
        }
        UBUITestRegister("connect_reveals_a_remembered_window_and_the_selected_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyManagement(t, checksReveal: true) }
        }

        ConnectWindowScenarios.register()
        ConnectOutlineScenarios.register()
        ConnectWindowScenarios.registerRefusals()
        ConnectWindowScenarios.registerShells()
        ConnectWindowScenarios.registerReattach()
        ConnectWindowScenarios.registerHostUpdate()
    }

    /// A stopped instance is rediscovered through the host's current plan.
    /// All daemons and shells belong to this scenario's private home.
    @MainActor
    private static func verifyVanishedDaemon(_ t: UBUITestContext) {
        guard let binary = ShareSessionSupport.localHostBinaryPath() else {
            t.expect(false, desc: "the app contains its host helper")
            return
        }
        let root = URL(fileURLWithPath: "/tmp/ubq-gone-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        let home = root.appendingPathComponent("host", isDirectory: true)
        let predecessor = root.appendingPathComponent("ubiquitty-host")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        do {
            try manager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.copyItem(at: URL(fileURLWithPath: binary), to: predecessor)
            let output = try FileHandle(forWritingTo: predecessor)
            try output.seekToEnd()
            try output.write(contentsOf: Data("\nvanished-instance-fixture\n".utf8))
            try output.close()
        } catch {
            t.expect(false, desc: "the isolated predecessor binary was prepared: \(error)")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home.path, 1)
        let old = Process()
        let discovery = Process()
        let successor = Process()
        let model = ConnectModel()
        let directory = model.directory
        let freshDirectory = HostDirectoryModel()
        let serverID = UUID()
        var server = HostServer(id: serverID, name: "Vanished Instance Fixture", host: "local", workspaceName: "replacement-workspace")
        defer {
            directory.stopFollowing()
            freshDirectory.stopFollowing()
            t.closeAllWindows()
            UbiquittyKit.HostDirectory.forget(host: server.pairingKey)
            for process in [old, discovery, successor] where process.processIdentifier != 0 {
                if process.isRunning { process.terminate() }
                if t.wait(until: { !process.isRunning }, timeout: 5) { process.waitUntilExit() }
            }
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
        }
        let environment = ProcessInfo.processInfo.environment.merging([
            "UBIQUITTY_HOME": home.path, "HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "SHELL": "/bin/sh", "ENV": "/dev/null", "HISTFILE": "/dev/null",
        ]) { $1 }
        func start(_ process: Process, executable: String) -> Bool {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--daemon", "--quic-port", "-1", "--columns", "80", "--rows", "24"]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                return true
            } catch {
                t.expect(false, desc: "the private daemon started: \(error)")
                return false
            }
        }
        func sockets() -> [String] {
            ((try? manager.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasSuffix(".sock") }
        }
        guard start(old, executable: predecessor.path), t.wait(until: { !sockets().isEmpty }, timeout: 15),
            let oldSocket = sockets().first
        else {
            t.expect(false, desc: "the predecessor listens in the private home")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "socketName": oldSocket, "executable": predecessor.path,
                "startedUnixSeconds": UInt64(Date.now.timeIntervalSince1970),
            ])
            server.daemonInstance = try JSONDecoder().decode(HostDaemonInstance.self, from: data)
        } catch {
            t.expect(false, desc: "the discovered instance was represented: \(error)")
            return
        }
        guard case .success(let plan) = HostTransport.plan(for: server) else {
            t.expect(false, desc: "the saved host has a transport plan")
            return
        }
        // A workspace opened first and ended once the one under test is open,
        // so the predecessor numbers the one under test past the first ids a
        // fresh successor mints, and its own last session is never the first
        // one's: the restored workspace has a window, a tab, a pane and a
        // session of other numbers than the ones the window was opened with.
        guard
            let ended = TerminalWindowController.spawnRemoteWindow(
                shellCommand: plan.shellCommand,
                hostLabel: server.displayName,
                quicHost: plan.quicHost,
                quicBootstrapCommand: plan.quicBootstrapCommand,
                deploySSHHost: plan.deploySSHHost,
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "replacement-ended",
                hostKey: "",
                daemonSocketName: oldSocket
            ), let endedSurface = ended.remoteSurface,
            t.wait(until: { endedSurface.drive.remoteState == .Connected && endedSurface.drive.remoteWorkspaceID != 0 }, timeout: 20)
        else {
            t.expect(false, desc: "a first workspace opens on the predecessor")
            return
        }
        guard
            let window = TerminalWindowController.spawnRemoteWindow(
                shellCommand: plan.shellCommand,
                hostLabel: server.displayName,
                quicHost: plan.quicHost,
                quicBootstrapCommand: plan.quicBootstrapCommand,
                deploySSHHost: plan.deploySSHHost,
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: server.workspaceName,
                hostKey: server.pairingKey,
                daemonSocketName: oldSocket
            ), let surface = window.remoteSurface
        else {
            t.expect(false, desc: "the first window opens through the pinned instance")
            return
        }
        guard t.wait(until: { surface.drive.remoteState == .Connected && surface.drive.remoteWorkspaceID != 0 }, timeout: 20) else {
            t.expect(false, desc: "the first window attaches: \(surface.remoteFailureDetail)")
            return
        }
        endedSurface.send("exit\r")
        guard t.wait(until: { ended.isClosedForTesting }, timeout: 20) else {
            t.expect(false, desc: "the first workspace ends with its shell (\(endedSurface.drive.remoteState))")
            return
        }
        let workspaceID = surface.drive.remoteWorkspaceID
        let formerSession = surface.drive.remoteSessionID
        let formerTab = surface.drive.remoteWorkspaceTab
        let formerPane = surface.drive.remoteWorkspacePane
        let record = home.appendingPathComponent(oldSocket + ".layouts")
        guard t.wait(until: { (try? Data(contentsOf: record))?.range(of: Data(server.workspaceName.utf8)) != nil }, timeout: 10) else {
            t.expect(false, desc: "the predecessor persisted the named workspace before its carrier is lost")
            return
        }
        guard start(discovery, executable: binary) else { return }
        model.select(.thisMacHost)
        guard
            t.wait(
                until: {
                    model.noteDirectoryChanged()
                    return directory.phase == .listed && model.hostInstances.contains { $0.socketName == oldSocket }
                },
                timeout: 15
            )
        else {
            t.expect(false, desc: "Connect discovers the predecessor through the current helper")
            return
        }
        model.selectHostInstance(oldSocket)
        guard t.wait(until: { directory.phase == .listed && directory.daemonSocketName == oldSocket }, timeout: 15) else {
            t.expect(false, desc: "the saved directory initially lists its pinned daemon")
            return
        }
        discovery.terminate()
        guard t.wait(until: { !discovery.isRunning }, timeout: 5) else {
            t.expect(false, desc: "the empty discovery helper stops before the predecessor")
            return
        }
        discovery.waitUntilExit()
        // A carrier loss sends no normal Bye. The Process owns this child;
        // no daemon discovered through a PID or socket is signalled here.
        guard old.isRunning, kill(old.processIdentifier, SIGKILL) == 0 else {
            t.expect(false, desc: "the owned predecessor is stopped abruptly")
            return
        }
        old.waitUntilExit()
        guard !old.isRunning else {
            t.expect(false, desc: "the predecessor stops without a successor or handover")
            return
        }
        guard start(successor, executable: binary),
            t.wait(until: { sockets().contains { $0 != oldSocket } }, timeout: 15)
        else {
            t.expect(false, desc: "the current helper starts as a distinct successor")
            return
        }
        func restoredWorkspaceSurface() -> TerminalSurface? {
            TerminalWindows.openControllers().compactMap { ($0 as? TerminalWindowController)?.remoteSurface }
                .first {
                    $0.drive.remoteWorkspaceID == workspaceID && $0.drive.remoteWorkspaceName == server.workspaceName
                }
        }
        let didRestore = t.wait(
            until: {
                model.noteDirectoryChanged()
                guard let current = restoredWorkspaceSurface() else { return false }
                return current.drive.remoteState == .Connected && current.drive.remoteSocketName != oldSocket
            },
            timeout: 25
        )
        let restored = restoredWorkspaceSurface()
        t.expect(
            didRestore,
            desc: "vanished-instance: the same workspace is restored on the current daemon "
                + "(connected=\(restored?.drive.remoteState == .Connected), "
                + "workspace=\(restored?.drive.remoteWorkspaceID ?? 0)/\(restored?.drive.remoteWorkspaceName ?? ""), "
                + "expected=\(workspaceID)/\(server.workspaceName), socket=\(restored?.drive.remoteSocketName ?? ""), "
                + "detail=\(restored?.remoteFailureDetail ?? ""))"
        )
        // The workspace comes back in the window it was open in, with the same
        // pane, and in no other window.
        let workspaceWindows = TerminalWindows.openControllers().compactMap { $0 as? TerminalWindowController }
            .filter { $0.remoteSurface?.drive.remoteWorkspaceName == server.workspaceName }
        t.expect(
            !window.isClosedForTesting && workspaceWindows.count == 1 && workspaceWindows.first === window
                && window.remoteSurface === surface && restored === surface,
            desc: "vanished-instance: the existing window keeps the restored workspace and its pane, and no second window opens "
                + "(closed=\(window.isClosedForTesting), windows=\(workspaceWindows.count), samePane=\(restored === surface))"
        )
        t.expect(
            didRestore && surface.drive.remoteSessionID != formerSession && surface.drive.remoteWorkspaceTab != formerTab
                && surface.drive.remoteWorkspacePane != formerPane,
            desc: "premise: the successor restored the workspace under other session, tab and pane numbers "
                + "(session \(formerSession)→\(surface.drive.remoteSessionID), tab \(formerTab.rawValue)→\(surface.drive.remoteWorkspaceTab.rawValue), "
                + "pane \(formerPane.rawValue)→\(surface.drive.remoteWorkspacePane.rawValue))"
        )
        directory.refresh()
        t.expect(
            t.wait(
                until: {
                    model.noteDirectoryChanged()
                    return directory.phase == .listed && model.selectedHostSocket.isEmpty && directory.daemonSocketName != oldSocket
                },
                timeout: 15
            ),
            desc: "vanished-instance: the saved directory retires the dead instance pin"
        )
        // A fresh request is made from the original stale row, independently
        // of whether the first directory has already repaired that row.
        freshDirectory.point(at: server)
        let existing = Set(TerminalWindows.openControllers().map { ObjectIdentifier($0) })
        t.expect(freshDirectory.newSession(named: "replacement-new"), desc: "a new workspace opens from the saved host")
        guard
            let fresh = TerminalWindows.openControllers().first(where: { !existing.contains(ObjectIdentifier($0)) })
                as? TerminalWindowController,
            let newSurface = fresh.remoteSurface
        else {
            t.expect(false, desc: "the new workspace has its own window")
            return
        }
        t.expect(
            t.wait(
                until: {
                    newSurface.drive.remoteState == .Connected && newSurface.drive.remoteSocketName != oldSocket
                        && newSurface.drive.remoteWorkspaceName == "replacement-new"
                },
                timeout: 20
            ),
            desc: "vanished-instance: a new workspace does not reuse the remembered dead socket"
        )
    }

    @MainActor
    private static func verifyManagement(_ t: UBUITestContext, checksReveal: Bool = false) {
        guard let binary = ShareSessionSupport.localHostBinaryPath() else {
            t.expect(false, desc: "the built app contains its host helper")
            return
        }
        let home = "/tmp/ubq-management-" + String(UUID().uuidString.prefix(8))
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "private host directory: \(error)")
            return
        }
        let previous = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: binary)
        daemon.arguments = ["--daemon"]
        defer {
            t.closeAllWindows()
            if daemon.isRunning { daemon.terminate() }
            if daemon.processIdentifier != 0 { daemon.waitUntilExit() }
            if let previous { setenv("UBIQUITTY_HOME", previous, 1) } else { unsetenv("UBIQUITTY_HOME") }
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
            t.expect(false, desc: "private daemon becomes ready")
            return
        }
        let server = HostServer(
            id: UUID(),
            name: "Management Fixture",
            host: "local",
            workspaceName: ""
        )
        if checksReveal {
            verifyConnectReveal(t, on: server)
            return
        }
        let model = HostManagementModel(server: server)
        defer { model.stopFollowing() }
        model.refresh()
        t.expect(
            t.wait(until: { !model.isBusy && model.snapshot.daemonInstanceID != 0 }, timeout: 15),
            desc: "management reads the live daemon: \(model.status)"
        )
        t.expect(
            t.wait(until: { model.directory.outline.freshness == .live }, timeout: 15),
            desc: "management follows the same live outline as Connect"
        )
        t.expect(model.directory.outline.rows.isEmpty, desc: "management does not create or attach a terminal session")
        var issue = HostManagementModel.Wire.ManagementRequest()
        issue.operation = .IssueToken
        issue.label = std.string("Native management test")
        issue.scopes = HostManagementModel.Wire.ScopeSet.fromRaw(1)
        issue.expiryUnix = UInt64(Date.now.timeIntervalSince1970) + 3600
        model.send(issue)
        guard t.wait(until: { !model.isBusy && model.snapshot.tokens.count == 1 && !model.issuedToken.isEmpty }, timeout: 15) else {
            t.expect(false, desc: "the explicit issue action completes: \(model.status)")
            return
        }
        guard let token = model.snapshot.tokens.first else { return }
        t.expect(token.createdUnix > 0, desc: "the daemon reports recorded token creation time")
        t.expect(
            String(token.fingerprint) != model.issuedToken && model.issuedToken.count == 64,
            desc: "the list carries a fingerprint, not the bearer secret"
        )
        var revoke = HostManagementModel.Wire.ManagementRequest()
        revoke.operation = .RevokeToken
        revoke.identity = token.fingerprint
        model.send(revoke)
        t.expect(
            t.wait(until: { !model.isBusy && model.snapshot.tokens.isEmpty }, timeout: 15),
            desc: "revocation refreshes the authoritative list: \(model.status)"
        )
        HostManagementWindows.shared.show(server: server)
        t.pump(0.5)
        t.expect(
            NSApp.windows.contains { $0.title == "Manage Management Fixture" && $0.isVisible },
            desc: "management opens its own native window"
        )
    }

    /// Exercises the actual registry and pane activation, first before a
    /// listing and then through a pane row in a watched tree.
    @MainActor
    private static func verifyConnectReveal(_ t: UBUITestContext, on server: HostServer) {
        let restore = takeDefaults()
        defer { putBackDefaults(restore) }
        HostServers.installPairingPersistence()
        guard case .success(let transport) = HostTransport.plan(for: server),
            let window = TerminalWindowController.spawnRemoteWindow(
                shellCommand: transport.shellCommand,
                hostLabel: server.displayName,
                quicHost: transport.quicHost,
                quicBootstrapCommand: transport.quicBootstrapCommand,
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "reveal",
                hostKey: server.pairingKey
            ), let root = window.remoteSurface
        else {
            t.expect(false, desc: "the isolated host opens a workspace")
            return
        }
        guard t.wait(until: { root.remoteSessionID != 0 && window.remotePaneSurfaces.count == 1 }, timeout: 20) else {
            t.expect(false, desc: "the workspace attaches with a live pane")
            return
        }
        HostDirectory.remember(host: server.pairingKey, sessionID: root.remoteSessionID, workspaceName: "reveal")
        let directory = HostDirectoryModel()
        directory.point(at: server)
        defer { directory.stopFollowing() }
        t.expect(directory.outline.rows.isEmpty, desc: "no listing or displayed workspace row is available yet")
        t.expect(
            directory.primaryActionForTesting().effect == .showWindow,
            desc: "the remembered target already open here says Show Window"
        )
        let windowCount = TerminalWindowController.spawnedControllers.filter { !$0.isWindowClosed }.count
        t.expect(directory.performPrimaryAction(), desc: "the remembered target reveals its window before a listing")
        t.expect(window.window?.firstResponder === root, desc: "the remembered session's exact pane is activated")

        window.splitRight(nil)
        guard t.wait(until: { window.remotePaneSurfaces.count == 2 }, timeout: 20),
            let sibling = window.remotePaneSurfaces.values.first(where: { $0 !== root }),
            t.wait(until: { sibling.remoteSessionID != 0 }, timeout: 20)
        else {
            t.expect(false, desc: "the workspace gains a second live pane")
            return
        }
        directory.refresh()
        let siblingPaneID = UInt32(sibling.drive.remoteWorkspacePane.rawValue)
        guard t.wait(until: { directory.outline.rows.contains { $0.level == .pane && $0.open.paneID == siblingPaneID } }, timeout: 20),
            let row = directory.outline.rows.first(where: { $0.level == .pane && $0.open.paneID == siblingPaneID })
        else {
            t.expect(false, desc: "the directory lists the second pane")
            return
        }
        t.expect(row.open.how == .byRevealing, desc: "Core says the selected pane is already open here")
        t.expect(
            directory.outline.rows.contains { $0.level == .workspace && directory.isShownHere($0) },
            desc: "the workspace this window shows wears the shown-here mark"
        )
        window.activateRemotePane(root)
        directory.selection = row.key
        t.expect(directory.primaryActionForTesting().effect == .showWindow, desc: "the selected pane's action is Show Window")
        t.expect(directory.performPrimaryAction(), desc: "opening the pane row reveals its window")
        t.expect(window.window?.firstResponder === sibling, desc: "the selected pane, not the workspace's root, is activated")
        t.expect(
            TerminalWindowController.spawnedControllers.filter { !$0.isWindowClosed }.count == windowCount,
            desc: "neither reveal opened another window"
        )
    }

    /// What the defaults hold before a scenario writes to them.
    ///
    /// - Returns: The values, by key; a key with nothing stored is absent.
    private static func takeDefaults() -> [String: Any] {
        var taken: [String: Any] = [:]
        for key in touchedDefaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                taken[key] = value
            }
        }
        return taken
    }

    /// Puts the operator's own saved servers back.
    ///
    /// - Parameter values: What ``takeDefaults()`` answered.
    private static func putBackDefaults(_ values: [String: Any]) {
        for key in touchedDefaultsKeys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Empties the keys these scenarios write.
    private static func clearDefaults() {
        for key in touchedDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
