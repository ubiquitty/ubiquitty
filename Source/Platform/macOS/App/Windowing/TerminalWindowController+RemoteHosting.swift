// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+RemoteHosting.swift — the shell hosts a thin-client window.
// The whole client lives behind the surface's session: the model mirrors
// the host's screen frames, input ships as Sync input events, and the titles, bells,
// exit and repaints arrive through the same observer events a local shell raises.
// This file is one spawn that attaches instead of launching.

import AppKit
internal import UbiquittyCore
package import UbiquittyRenderKit

extension TerminalWindowController {
    /// The transport command this window attached with (`ssh … --attach`),
    /// empty for a window that is not hosted from a remote.
    ///
    /// Read by the Sync Debug window, which names the session it reports on
    /// the way the reader started it.
    package var remoteTransportCommand: String { remoteConnection?.shellCommand ?? "" }

    /// Opens a local login-shell window, independent of the focused workspace.
    ///
    /// - Parameter sender: The menu item or keyboard action invoking the command.
    @objc
    public func newWindow(_ sender: Any?) {
        _ = Self.spawn()
    }

    /// Requests another window in the active remote workspace.
    ///
    /// - Parameter sender: The menu item invoking the workspace operation.
    @objc
    public func newRemoteWorkspaceWindow(_ sender: Any?) {
        guard let remote = remoteSurface else { return }
        // Beeps for a request the session cannot send yet, as File ▸ New Tab does.
        if !remote.drive.remoteWorkspaceAddSurface() {
            NSSound.beep()
        }
    }

    /// The host key of the remote session the key window shows.
    ///
    /// - Returns: The pairing key, nil when the key window is not a remote
    ///   terminal window.
    package static func keyRemoteHostKey() -> String? {
        guard let key = NSApp.keyWindow?.windowController as? TerminalWindowController, !key.isWindowClosed else {
            return nil
        }
        return key.remoteHostKey.isEmpty ? nil : key.remoteHostKey
    }

    /// Selects the window and pane represented by an existing workspace connection.
    package func activateRemotePane(_ pane: TerminalSurface) {
        guard let window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pane)
    }

    /// Spawns a window attached to a remote host as a thin client.
    ///
    /// - Parameters:
    ///   - shellCommand: The transport command (`ssh … --attach`).
    ///   - hostLabel: The title before the host's own stream takes over.
    ///   - quicHost: The host a QUIC carrier dials; empty offers no QUIC and
    ///     the window takes the transport command alone.
    ///   - quicBootstrapCommand: Prints the daemon's QUIC port, token and
    ///     certificate pin; empty likewise offers no QUIC.
    ///   - deploySSHHost: The host `ubiquitty-host` may be installed on when
    ///     it turns out not to have one; empty offers no install.
    ///   - deployBinaries: The bundled hosts by remote `uname -sm`.
    ///   - reattachSessionID: The daemon session this window re-homes to.
    ///     Zero opens a fresh shell, which is what a first connect wants; a
    ///     restored tab names the session it was captured holding.
    /// - Returns: The window, or nothing when it could not spawn or the attach
    ///   did not start. Returned rather than reported, because a caller
    ///   restoring a tab group has to place the window it just opened.
    @discardableResult
    public static func spawnRemoteWindow(
        shellCommand: String,
        hostLabel: String,
        quicHost: String,
        quicBootstrapCommand: String,
        deploySSHHost: String,
        deployBinaries: [String: String],
        reattachSessionID: UInt32
    ) -> TerminalWindowController? {
        spawnRemoteWindow(
            shellCommand: shellCommand,
            hostLabel: hostLabel,
            quicHost: quicHost,
            quicBootstrapCommand: quicBootstrapCommand,
            deploySSHHost: deploySSHHost,
            deployBinaries: deployBinaries,
            reattachSessionID: reattachSessionID,
            workspaceName: "",
            hostKey: ""
        )
    }

    /// Spawns a window attached to a remote host, naming the workspace to
    /// attach under and the host the pairing is remembered against.
    ///
    /// The door above in every respect but the three values a session directory
    /// knows and a restored tab does not.
    ///
    /// - Parameters:
    ///   - shellCommand: The transport command (`ssh … --attach`).
    ///   - hostLabel: The title before the host's own stream takes over.
    ///   - quicHost: The host a QUIC carrier dials; empty offers no QUIC.
    ///   - quicBootstrapCommand: Prints the daemon's QUIC port, token and
    ///     certificate pin; empty likewise.
    ///   - deploySSHHost: The host `ubiquitty-host` may be installed on; empty
    ///     offers no install.
    ///   - deployBinaries: The bundled hosts by remote `uname -sm`.
    ///   - reattachSessionID: The daemon session this window re-homes to, or
    ///     zero for a fresh one.
    ///   - workspaceName: The workspace to attach under or create under, empty
    ///     for an unnamed session.
    ///   - reattachPolicy: What the attach asks when `reattachSessionID` has
    ///     ended: a fresh session in its place, or a refusal the window shows.
    ///   - hostKey: The host a pairing is filed under, empty for a window whose
    ///     session is not to be remembered.
    ///   - workspaceID: The directory's stable workspace identifier.
    ///   - daemonSocketName: The daemon socket returned by the directory handshake.
    ///   - daemonInstanceID: The daemon process identity to require, or zero for a new connection.
    ///   - source: An existing window whose Core workspace connection is reused.
    ///   - reusingSurface: An attached pane whose view moves into this window.
    ///   - hostUpdatePlatform: When set, the connection installs this app's
    ///     host for that `uname -sm` (empty when unknown) before it dials.
    /// - Returns: The window, or nothing when it could not spawn. Credential
    ///   loading may still be pending; connection failures appear in the window.
    @discardableResult
    public static func spawnRemoteWindow(
        shellCommand: String,
        hostLabel: String,
        quicHost: String,
        quicBootstrapCommand: String,
        deploySSHHost: String,
        deployBinaries: [String: String],
        reattachSessionID: UInt32,
        workspaceName: String,
        reattachPolicy: RemoteReattachPolicy = .attachOrCreate,
        hostKey: String,
        workspaceID: UInt32 = 0,
        daemonSocketName: String = "",
        daemonInstanceID: UInt64 = 0,
        sharingWorkspaceWith source: TerminalWindowController? = nil,
        reusingSurface: TerminalSurface? = nil,
        updatingHostFor hostUpdatePlatform: String? = nil
    ) -> TerminalWindowController? {
        // An update opens its own window: one already showing the workspace
        // is attached to the daemon being replaced.
        if source == nil, hostUpdatePlatform == nil {
            let request = RemoteWindowRegistry.Request(
                shellCommand: shellCommand,
                workspaceID: workspaceID,
                sessionID: reattachSessionID,
                workspaceName: workspaceName,
                daemonSocketName: daemonSocketName,
                daemonInstanceID: daemonInstanceID
            )
            let matches = RemoteWindowRegistry.matches(for: request)
            for match in matches {
                match.controller.pendingRemoteActivationSessionID = 0
            }
            if let match = RemoteWindowRegistry.existingWindow(for: request, among: matches) {
                if match.pane.remoteSessionID != reattachSessionID {
                    match.controller.pendingRemoteActivationSessionID = reattachSessionID
                }
                match.controller.activateRemotePane(match.pane)
                return match.controller
            }
        }
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        guard
            let renderer = TerminalSurface.makeRenderer(
                configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration(),
                systemTransparency: TerminalSurface.systemTransparency
            )
        else {
            return nil
        }
        guard let surface = reusingSurface ?? TerminalSurface(rows: launch.rows, columns: launch.columns) else {
            return nil
        }
        surface.renderer = renderer
        // The host's first frame is a round trip away, and until it lands the
        // window shows this model and the chrome painted from it. A pane
        // opening beside another takes the theme its session shows; the
        // first window of a connection has only the configuration to go by.
        if reusingSurface == nil {
            let isSeededFromSource = source?.activeSurface.map { surface.drive.seedPalette(from: $0.drive) } ?? false
            if !isSeededFromSource {
                _ = surface.drive.reseedLaunchTheme(Ubiquitty.Preferences.values().pointee)
            }
            surface.publishModelWrite()
        }
        // A hosted window: the remote authority owns the topology, so the
        // surface sits outside the model and fills the window directly.
        let controller = TerminalWindowController(
            workspaceSurface: Ubiquitty.Session.Layout.invalidSurface,
            pane: nil,
            surface: surface,
            renderer: renderer,
            rows: launch.rows,
            columns: launch.columns
        )
        // Before the appearance pass: the chrome is painted from the active
        // surface, and a hosted window has no other way to name one yet. A
        // window shown without it opens on the system's window colour.
        controller.remoteSurface = surface
        // Held, not only written: the first weave would otherwise replace it
        // with the application's name, since a host that has said nothing yet
        // leaves every segment empty. Before the window is shown, which is
        // the first weave now that the window names its surface.
        controller.remoteHostLabel = hostLabel
        controller.window?.title = hostLabel
        controller.applyWindowAppearance(launch)
        spawnedControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(surface)
        RemoteSessionLifecycle.shared.start()
        RemoteSessionLifecycle.shared.reportNetworkCost(to: surface)
        controller.remoteHostKey = hostKey
        controller.remoteRequestedSessionID = reattachSessionID
        controller.remoteWorkspaceName = workspaceName
        controller.remoteConnection = RemoteConnection(
            shellCommand: shellCommand,
            hostLabel: hostLabel,
            quicHost: quicHost,
            quicBootstrapCommand: quicBootstrapCommand,
            hostKey: hostKey
        )
        var fileHostInputs = Ubiquitty.Session.PaneHostInputs()
        fileHostInputs.isHostSession = true
        fileHostInputs.hostKey = std.string(hostKey.isEmpty ? (quicHost.isEmpty ? deploySSHHost : quicHost) : hostKey)
        let fileHost = Ubiquitty.Session.resolvePaneHost(fileHostInputs)
        surface.remoteFileHost = fileHost.place == .ThisMachine ? "localhost" : String(fileHost.machine)
        surface.remoteFileHostLabel = hostLabel.isEmpty ? surface.remoteFileHost : hostLabel
        let finishAttach: (Bool) -> Void = { [weak controller, weak surface] didAttach in
            guard let controller, let surface, !controller.isWindowClosed, controller.remoteSurface === surface else { return }
            guard didAttach else {
                controller.presentRemoteConnectionStatus(
                    on: surface,
                    state: .Failed,
                    detail: "The connection couldn’t be started. Try again."
                )
                return
            }
            controller.remoteSessionDidChange(on: surface)
            controller.reportClipboardScope(for: surface)
            if !deploySSHHost.isEmpty {
                controller.offerHostDeploy(on: surface, sshHost: deploySSHHost, binaries: deployBinaries)
            }
            remoteWindowOrderedInForTesting?(controller)
        }
        let didAttach: Bool
        if reusingSurface != nil {
            didAttach = true
        } else if let source {
            if let sourceSurface = source.activeSurface {
                didAttach = surface.attachRemoteSibling(
                    to: sourceSurface.drive,
                    sessionID: reattachSessionID
                )
            } else {
                didAttach = false
            }
        } else {
            controller.presentRemoteConnectionStatus(on: surface, state: .Connecting, detail: "")
            HostTokenStore.load(forHost: hostKey) { [weak controller, weak surface] token in
                guard let controller, let surface, !controller.isWindowClosed, controller.remoteSurface === surface else { return }
                if let token { surface.drive.setRemoteAuthToken(token) }
                if let hostUpdatePlatform {
                    surface.drive.requestHostUpdateBeforeAttach(platform: hostUpdatePlatform)
                } else {
                    // The window's stored attachment, drawn before the attach
                    // dials and resumed by it.
                    let resume = RemoteResume.prepare(
                        identity: RemoteResume.identity(
                            shellCommand: shellCommand,
                            quicHost: quicHost,
                            workspaceName: workspaceName,
                            sessionID: reattachSessionID
                        )
                    )
                    resume?.install(on: surface.drive)
                    controller.remoteResume = resume
                }
                finishAttach(
                    surface.attachRemote(
                        shellCommand: shellCommand,
                        quicHost: quicHost,
                        quicBootstrapCommand: quicBootstrapCommand,
                        reattachSessionID: reattachSessionID,
                        workspaceName: workspaceName,
                        reattachPolicy: reattachPolicy,
                        workspaceID: workspaceID,
                        daemonSocketName: daemonSocketName,
                        daemonInstanceID: daemonInstanceID
                    )
                )
            }
            return controller
        }
        finishAttach(didAttach)
        return didAttach ? controller : nil
    }

    /// Called with a hosted window as its spawn returns: ordered in, attached,
    /// and not yet through a run-loop turn, so no host frame can have reached
    /// it. What the window shows here is what its first commit shows.
    package static var remoteWindowOrderedInForTesting: ((TerminalWindowController) -> Void)?

    /// Arms the host install for a remote surface.
    ///
    /// Whether the host is trusted is Core's to read, from the one trust list
    /// every window and the Connect window share. The first push to a new
    /// host raises
    /// ``RuntimeEvents/deployConfirmationPending``, which
    /// ``confirmHostDeploy(on:sshHost:)`` answers.
    ///
    /// - Parameters:
    ///   - surface: The attached remote surface.
    ///   - sshHost: The host a push targets.
    ///   - binaries: The bundled hosts by remote `uname -sm`.
    func offerHostDeploy(on surface: TerminalSurface, sshHost: String, binaries: [String: String]) {
        deploySSHHost = sshHost
        remoteDeployBinaries = binaries
        // The trust list's store is this app's; a session that read the list
        // before it was installed would ask again for a host already trusted.
        Self.installDeployTrustPersistence()
        surface.drive.offerHostDeploy(sshHost: sshHost, binaries: binaries)
    }

    /// Hands Core this app's defaults as the store its deploy-trust list is
    /// kept in: one opaque record under the key Core names, never read here.
    ///
    /// Installed once per process, because Core borrows the context the
    /// closures live in.
    package static func installDeployTrustPersistence() {
        guard !isDeployTrustPersistenceInstalled else {
            return
        }
        isDeployTrustPersistenceInstalled = true
        HostDirectory.setDeployTrustPersistence(
            load: { key in
                UserDefaults.standard.data(forKey: key).map { [UInt8]($0) }
            },
            store: { key, bytes in
                if bytes.isEmpty {
                    UserDefaults.standard.removeObject(forKey: key)
                } else {
                    UserDefaults.standard.set(Data(bytes), forKey: key)
                }
            }
        )
    }

    /// Whether ``installDeployTrustPersistence()`` has run in this process.
    private static var isDeployTrustPersistenceInstalled = false

    /// Asks whether the bundled host may be installed, and answers the
    /// session either way.
    ///
    /// One allowing button, so the answer is approve-or-not: the host list this
    /// writes on approval is the app's own memory of the choice, not a grant
    /// scope the person picked.
    ///
    /// - Parameter surface: The surface whose session asked.
    func confirmHostDeploy(on surface: TerminalSurface) {
        if surface.drive.hostUpdateLiveSessionCount > 0 {
            confirmHostUpdateLiveSessions(on: surface)
            return
        }
        let sshHost = deploySSHHost
        let alert = NSAlert()
        alert.messageText = "Install Ubiquitty’s host on \(sshHost)?"
        alert.informativeText =
            "This host doesn’t have ubiquitty-host. Ubiquitty can copy the bundled one to ~/.ubiquitty over SSH."
            + " You’re asked once per host. To turn automatic install off, choose Settings ▸ Sessions ▸ Remote Sessions."
        // A binary uploaded and run on a machine that is not this one, and a
        // host trusted from then on, so the prompt carries the warning style.
        alert.alertStyle = .warning
        // Sheeted on the window whose session asked, unless that window is
        // already showing one — a second sheet on the same window never appears
        // and its completion never runs, so the session would wait forever for
        // an answer nobody was shown.
        let host = window?.attachedSheet == nil ? window : nil
        ConsentAlert.ask(alert, refusing: "Not Now", allowing: ["Install"], on: host) { decision in
            guard decision != .deny else {
                surface.drive.declineHostDeploy()
                return
            }
            surface.drive.approveHostDeploy()
        }
    }

    /// The titles of the live-sessions question's allowing buttons, after
    /// Cancel.
    package static let hostUpdateSessionChoices = ["Update When They End", "Update Now"]

    /// Asks what an update does to the sessions the host's daemon holds, and
    /// answers the session.
    ///
    /// Cancel is the default, through ``ConsentAlert``, so a stray Return
    /// installs nothing. Both update choices preserve the running sessions.
    ///
    /// - Parameter surface: The surface whose session asked.
    func confirmHostUpdateLiveSessions(on surface: TerminalSurface) {
        let host = remoteHostLabel.isEmpty ? deploySSHHost : remoteHostLabel
        let alert = hostUpdateSessionsAlert(question: surface.drive.hostUpdateSessionsQuestion(host: host))
        let sheetHost = window?.attachedSheet == nil ? window : nil
        ConsentAlert.choose(alert, refusing: "Cancel", between: Self.hostUpdateSessionChoices, on: sheetHost) { choice in
            switch choice {
            case 1:
                surface.drive.updateHostWhenSessionsEnd()
            case 2:
                surface.drive.updateHostNow()
            default:
                surface.drive.declineHostDeploy()
            }
        }
    }

    /// The live-sessions question, built but not shown.
    ///
    /// - Parameter question: Core's sentence naming the count and the host.
    /// - Returns: The alert, without buttons: ``ConsentAlert`` adds them.
    package func hostUpdateSessionsAlert(question: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText =
            "Update When They End installs the new host beside the running one; it takes over on the first connect after the last session exits."
            + " Update Now transfers the live sessions to the new host. If handover is refused, the old host keeps them running."
        alert.alertStyle = .warning
        return alert
    }

    /// Everyone attached to the session this window is showing.
    ///
    /// The focused pane's roster, because that is the session a reader acting
    /// on the window means: a hosted workspace's panes are separate daemon
    /// sessions, each with a roster of its own, and an agent is on one of them.
    ///
    /// - Returns: The roster in the host's order, empty for a local session.
    package func sessionAttendees() -> [RuntimeDrive.Attendee] {
        presenceSurface?.drive.attendees ?? []
    }

    /// Acts on an attendee of this window's session.
    ///
    /// The one call every revoke in this shell makes — the roster menu's three
    /// scopes, Disconnect All, and Beam's agent commands — so the daemon's
    /// gates apply to all of them and none of them can drift into a second
    /// spelling. A window with no remote session has nobody to revoke and does
    /// nothing.
    ///
    /// - Parameters:
    ///   - action: What to do.
    ///   - attachmentID: The exact attachment, for ``RuntimeDrive/RevokeAction/disconnectNow``.
    ///   - identity: The separate verified grant key, for the two grant actions.
    package func revokeConsent(_ action: RuntimeDrive.RevokeAction, attachmentID: String, identity: String) {
        presenceSurface?.drive.revokeConsent(action, attachmentID: attachmentID, identity: identity)
    }

    /// The surface whose roster the badge and Beam speak for.
    ///
    /// The focused pane while it is one of this window's, and a hosted
    /// window's root before any pane holds focus — the same choice the title
    /// makes, for the same reason.
    var presenceSurface: TerminalSurface? { titleSurface }

    /// Shows the badge the focused pane's roster.
    ///
    /// Called when a roster changes and when focus moves between panes,
    /// because either changes the answer and the badge speaks for one session
    /// at a time.
    func refreshPresence() {
        refreshPanePresence()
        let surface = presenceSurface
        presenceIndicator?.acknowledgeScreenAccess = { [weak surface] cursor in
            surface?.drive.acknowledgeScreenAccess(through: cursor)
        }
        SessionPresenceIndicator.report(
            sessionAttendees(),
            screenAccesses: surface?.drive.screenAccesses ?? [],
            hasUnread: surface?.drive.hasUnreadScreenAccess ?? false,
            for: window
        )
        presenceIndicator?.showsBadge = !showsPaneTitleBars
    }

    /// Brings a consent question in front of a reader who is looking elsewhere.
    ///
    /// The window may be a background tab, occluded, or behind another app: a
    /// sheet attached to it would never be seen, and the daemon holds the agent
    /// until its consent timeout — which looks, to the person, like nothing
    /// happened. So the tab is selected within its group, the Dock is asked for
    /// attention, and a banner tagged with this window and pane goes up, which
    /// on click raises exactly this window and pane. None of it takes focus,
    /// and all of it is skipped when the window is already the foremost one.
    ///
    /// - Parameters:
    ///   - surface: The surface whose session was asked about.
    ///   - title: What the agent wants, in one line.
    ///   - body: Who is asking.
    func drawAttentionToConsent(on surface: TerminalSurface, title: String, body: String) {
        drawAttentionToConsent(
            on: surface,
            title: title,
            body: body,
            isWindowForemost: NSApp.isActive && window?.isKeyWindow == true
        )
    }

    /// The same, given whether the reader is already looking at this window.
    ///
    /// The fact is taken rather than read so the gate can be put to both
    /// answers — the same reason ``SessionAttention`` takes whether the app is
    /// active. A scenario's app is an accessory whose windows never take key,
    /// so the quiet case would otherwise be unreachable.
    ///
    /// - Parameters:
    ///   - surface: The surface whose session was asked about.
    ///   - title: What the agent wants, in one line.
    ///   - body: Who is asking.
    ///   - isWindowForemost: Whether this window is the key window of the
    ///     active app.
    package func drawAttentionToConsent(
        on surface: TerminalSurface,
        title: String,
        body: String,
        isWindowForemost: Bool
    ) {
        guard let window, !isWindowForemost else {
            return
        }
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        // Critical rather than informational: the ask expires, and a bounce
        // that stops after one hop is one a person who stepped away misses.
        requestUserAttention(.criticalRequest)
        postConsentBanner(
            window.windowNumber,
            Int(paneID(of: surface)?.rawValue ?? 0),
            title,
            body
        )
    }

    /// Shows what a failed push of `ubiquitty-host` printed.
    ///
    /// The connection is already Failed and its status says so; this is the
    /// part only the push knows — the tail of ssh's and the remote shell's
    /// output, which names the permission, the disk or the host key the person
    /// has to fix before connecting again.
    ///
    /// - Parameter surface: The surface whose session pushed.
    func presentHostDeployFailure(on surface: TerminalSurface) {
        presentRemoteNotice(
            hostDeployFailureAlert(failure: surface.drive.lastDeployFailure, wasDeferred: surface.drive.lastDeployWasDeferred)
        ) { _ in }
    }

    /// The failure notice, built but not shown.
    ///
    /// Built apart from the showing so a case can read what a person would
    /// read: a sheet run inside a scenario answers nobody and blocks the loop
    /// driving it.
    ///
    /// - Parameter failure: What the push printed.
    /// - Returns: The alert.
    package func hostDeployFailureAlert(failure: String, wasDeferred: Bool = false) -> NSAlert {
        let alert = NSAlert()
        let host = remoteHostLabel.isEmpty ? "the host" : remoteHostLabel
        alert.messageText = wasDeferred ? "Host Update Pending on \(host)" : "Couldn’t Update \(host)"
        alert.informativeText = failure.isEmpty ? "Ubiquitty couldn’t install ubiquitty-host on the remote host. Try again." : failure
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// Shows the steps that install `ubiquitty-host` by hand, when no
    /// automatic install can.
    ///
    /// The reason line says which case applied, because the two have different
    /// fixes: a setting the person turned off, or a platform no bundled binary
    /// serves. The steps are Core's, so every shell offers the same commands
    /// for the same host, and Copy Commands puts exactly those on the
    /// clipboard. For a platform no release publishes a host for, Core's
    /// steps are the sentence that says so, and there is nothing to copy.
    ///
    /// - Parameter surface: The surface whose session asked.
    func presentManualHostInstall(on surface: TerminalSurface) {
        let steps = surface.drive.manualHostInstallCommands
        let platform = surface.drive.manualInstallPlatform
        let alert = manualHostInstallAlert(
            steps: steps,
            platform: platform,
            isForSetting: surface.drive.isManualInstallForSetting
        )
        let offersCommands = Self.hasPublishedHost(platform: platform)
        presentRemoteNotice(alert) { [weak self] response in
            guard offersCommands, response == .alertFirstButtonReturn else { return }
            self?.copyManualHostInstallCommands(steps)
        }
    }

    /// Whether a release publishes a host for a platform, which is when
    /// Core's manual steps are commands to run.
    ///
    /// - Parameter platform: The remote's `uname -sm`.
    /// - Returns: Whether Core names a published host for it.
    package static func hasPublishedHost(platform: String) -> Bool {
        platform.withCString { !String(Ubiquitty.Session.publishedHostAsset(std.string_view($0))).isEmpty }
    }

    /// The manual-install notice, built but not shown.
    ///
    /// Built apart from the showing for the reason the failure notice is.
    ///
    /// - Parameters:
    ///   - steps: Core's commands for this host's platform.
    ///   - platform: The remote's `uname -sm`.
    ///   - isForSetting: Whether a setting stood in the way rather than a
    ///     platform no bundled binary serves.
    /// - Returns: The alert, Copy Commands first so the Return key reaches the
    ///   button that does something; OK alone for a platform no release
    ///   publishes a host for.
    package func manualHostInstallAlert(steps: String, platform: String, isForSetting: Bool) -> NSAlert {
        let host = remoteHostLabel.isEmpty ? "the host" : remoteHostLabel
        guard Self.hasPublishedHost(platform: platform) else {
            let alert = NSAlert()
            alert.messageText = "Can’t Install ubiquitty-host on \(host)"
            alert.informativeText = steps
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            return alert
        }
        let reason =
            isForSetting
            ? "Automatic host install is turned off in Settings ▸ Sessions ▸ Remote Sessions."
            : "Ubiquitty has no bundled host binary for \(platform.isEmpty ? "this platform" : platform)."
        let alert = NSAlert()
        alert.messageText = "Install ubiquitty-host on \(host)"
        alert.informativeText = "\(reason)\n\nRun this on \(host), then reconnect:\n\n\(steps)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Commands")
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// Puts the manual-install commands on the clipboard, exactly as shown.
    ///
    /// - Parameter steps: What the alert displayed.
    package func copyManualHostInstallCommands(_ steps: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(steps, forType: .string)
    }

    /// Lands a file the host answered with and shows it to the reader.
    ///
    /// Silent on every failure the host can report — no such path, outside the
    /// session's confinement, too large, not a regular file — because a
    /// Cmd-click on a local path that resolves to nothing is silent too, and a
    /// path candidate is a guess the terminal made about printed text rather
    /// than something the person asked for by name.
    ///
    /// What arrives is not something a program here produced, so it lands the
    /// way a browser download lands: a fresh directory, the clicked path's
    /// last component for a name, and a quarantine record on the write. The
    /// tag goes on before the open, not instead of it — the extension
    /// allowlist that decides open-versus-reveal is spoofable.
    ///
    /// Every waiting answer lands, not the oldest alone: the arrival event is
    /// one bit in a coalesced word, so two answers crossing in one ingest pass
    /// raise it once, and a drain of one would land the second only on some
    /// later click — the reader would be shown an earlier click's file.
    ///
    /// - Parameter surface: The surface whose session asked.
    func landHostFile(from surface: TerminalSurface) {
        while let answer = surface.drive.takeRemoteFile() {
            landHostFile(answer)
        }
    }

    /// The same, for an answer already taken.
    ///
    /// Split from the drain so a case can hand it an answer: a host that reads
    /// a file is a daemon, a filesystem and a confinement check, and none of
    /// the three is what this decides.
    ///
    /// The name is the path this session asked for, never the path the host
    /// echoed back: that name decides whether the bytes go to the default
    /// handler or are only revealed, and a host free to answer a click on a
    /// shell script with a plain-text name of its own choosing would be
    /// picking which handler runs. The write is named from the clicked path.
    ///
    /// A link that named a line (`#L12`) opens the copy at that line in the
    /// reader's `[links] line_handler`, as it opens a file of this machine
    /// (``LinkOpener/openDownloadedCopy(_:atLine:column:)``). With no handler,
    /// or one that cannot be started, the copy is opened or revealed as any
    /// fetched file is.
    ///
    /// - Parameter answer: What the host sent.
    /// - Returns: Where the file landed, or nil when nothing was written.
    @discardableResult
    package func landHostFile(_ answer: RuntimeDrive.RemoteFile) -> URL? {
        // Read or not read, and nothing in between: a host that read a file of
        // no bytes read a file, and the reader is shown the empty file they
        // clicked.
        guard answer.isRead else { return nil }
        guard let landed = QuarantinedDownload.land(bytes: answer.bytes, suggestedName: answer.requestedPath) else {
            return nil
        }
        if LinkOpener.openDownloadedCopy(landed, atLine: answer.requestedLine, column: answer.requestedColumn) {
            return landed
        }
        if QuarantinedDownload.isSafeToOpen(landed) {
            openDownload(landed)
        } else {
            revealDownload(landed)
        }
        return landed
    }

    /// Sheets a remote session's notice on this window, or runs it app-modal
    /// when the window already shows a sheet.
    ///
    /// A second sheet on one window never appears and its completion never
    /// runs, so a notice queued behind the install prompt would be lost.
    ///
    /// - Parameters:
    ///   - alert: The notice.
    ///   - completion: Receives the button the person pressed.
    private func presentRemoteNotice(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// The remote connection reported a session or a failure: the pairing this
    /// host is remembered by follows from what the host actually said.
    ///
    /// Remembered from the id the host pinned rather than from the attach
    /// returning true, which says only that the ask went out. A host that
    /// answered a reattach with a different id ended the session that was asked
    /// for, and the pairing is rewritten to what it gave instead — so the next
    /// connect reattaches to a session that exists.
    ///
    /// A refused reattach is the other direction: the host will not give that
    /// session back, so the pairing is dropped rather than retried, the reason
    /// the daemon sent is shown, and the next connect decides as a first one.
    ///
    /// A shared pane reports here too: its badge names the local daemon while
    /// the daemon drives it, and comes down when the session is handed back.
    ///
    /// - Parameter surface: The surface whose connection moved — the window's
    ///   remote surface, or a pane this window shared.
    package func remoteSessionDidChange(on surface: TerminalSurface) {
        windowSharing?.advance()
        remoteClosePresentation?.retireIfStale()
        // A pane handed back, or whose connection ended, has nothing in
        // doubt, and says nothing of it.
        presentInputInDoubt(on: surface)
        // A pane whose connection ended without its window closing is one the
        // daemon handed back: it is local again, and its chrome follows. Only
        // a pane of this window's own model can be handed back. A hosted
        // window's views are the host's: one the projection let go of has had
        // its connection closed, and an event it still delivers reads as
        // detached. Taken as the window going local, it would strip the host
        // chip and the host's name from a window still attached through its
        // other panes.
        guard surface.drive.isRemoteAttached else {
            if remoteSurface == nil {
                withdrawSharingChrome(from: surface)
            }
            return
        }
        if surface === activeSurface {
            reportClipboardScope(for: surface)
        }
        refreshRemoteConnectionIndicator(on: surface)
        presentRemoteConnectionStatus(on: surface, state: surface.drive.remoteState, detail: surface.remoteFailureDetail)
        if surface === remoteSurface, surface.drive.remoteState == .Failed, !hasPresentedVersionRefusal,
            let refusal = surface.drive.lastHostRefusal, refusal.reason == .VersionMismatch
        {
            // The refusal names what to do — update the older end — so the
            // sheet offers it rather than leaving the sentence in the status.
            hasPresentedVersionRefusal = true
            presentRefusalSheet(
                sessionID: remoteRequestedSessionID,
                // Core's sentence names the older end and both builds; the
                // connection's own notice would say it a second time.
                content: refusalSheetContent(reason: .VersionMismatch, hostBuild: refusal.hostBuild, detail: "")
            )
            return
        }
        if surface.wasReattachRefused, surface.refusedReattachSessionID == remoteRequestedSessionID {
            let refusedSessionID = remoteRequestedSessionID
            // Zeroed before the sheet goes up, so the refusal is reported once:
            // the refusal stands until the connection reaches another state,
            // and this method runs on every one of them.
            remoteRequestedSessionID = 0
            presentReattachRefusal(
                sessionID: refusedSessionID,
                detail: surface.remoteFailureDetail
            )
            return
        }
        guard !remoteHostKey.isEmpty else { return }
        let sessionID = surface.remoteSessionID
        guard sessionID != 0 else {
            return
        }
        remoteRequestedSessionID = sessionID
        HostDirectory.remember(host: remoteHostKey, sessionID: sessionID, workspaceName: remoteWorkspaceName)
    }

    /// Refreshes window chrome from the remote session's authoritative state.
    ///
    /// The connection's phases fold to the link state a badge draws through
    /// Core's ``Ubiquitty/Session/healthFor(_:)``, so this shell's badge and
    /// every other frontend's read one vocabulary: a fold written here would be
    /// a second one, and the copy that drifts is the one nobody is looking at.
    /// A place no link of ours reaches — a shell that ran `ssh` — has no link
    /// state to report, and stands steady for as long as it is there.
    package func refreshRemoteConnectionIndicator(on surface: TerminalSurface) {
        let host = paneHost(of: surface)
        let statedBefore = remoteConnectionIndicator?.statedHostName ?? ""
        remoteConnectionIndicator?
            .update(
                place: host.place,
                health: host.isHostSession ? Ubiquitty.Session.healthFor(surface.drive.remoteState) : .Connected,
                host: String(host.label),
                carrier: String(host.carrier),
                isShared: surface.drive.isSharedIntoLocalDaemon,
                hostTag: hostChipTag,
                titlebarWash: loudTagColor,
                tagStyle: titleRowTagStyle
            )
        refreshHostSubtitle(host: host)
        noteChromeHostMoved(from: statedBefore)
    }

    /// Has the group's tab labels baked again when the host this window's
    /// chrome names changed: whether a label carries its host turns on what
    /// the chrome already says, and the labels were baked before it said this.
    ///
    /// - Parameter statedBefore: What the chip named before the change.
    private func noteChromeHostMoved(from statedBefore: String) {
        guard (remoteConnectionIndicator?.statedHostName ?? "") != statedBefore else { return }
        refreshSiblingTabTitles()
    }

    /// Asks for every tab label of this window's group, this one's included,
    /// to be baked again a turn from now.
    func refreshSiblingTabTitles() {
        scheduleTabFocusRefresh()
    }

    /// Stands the host chip for the pane the title row speaks for, or takes it
    /// down when that pane is a plain local shell.
    ///
    /// Asked whenever where that pane is may have moved: a link changing state
    /// reports through ``remoteSessionDidChange(on:)``, and a walk, a report or
    /// a focus change arrives through the title refresh.
    package func refreshHostChip() {
        guard let surface = hostSurface else {
            let statedBefore = remoteConnectionIndicator?.statedHostName ?? ""
            remoteConnectionIndicator?.withdraw()
            refreshHostSubtitle(host: Ubiquitty.Session.PaneHost())
            noteChromeHostMoved(from: statedBefore)
            return
        }
        refreshRemoteConnectionIndicator(on: surface)
    }

    /// The pairing key the Connect window's This Mac row dials this Mac's own
    /// daemon under: Core's ``Ubiquitty/Session/thisMachineHostKey``.
    nonisolated package static let thisMacHostKey = String(Ubiquitty.Session.thisMachineHostKeySpelling())

    /// The pane whose host the title row's chip, its subtitle and its tags
    /// speak for: the window's host link, a pane it shared into this Mac's
    /// daemon, and otherwise the pane the title names.
    package var hostSurface: TerminalSurface? {
        remoteSurface ?? sharedSurface ?? titleSurface
    }

    /// Where a pane's session lives: Core's one answer, which the chip, the
    /// tab, the pane bars and the tag rules all read.
    ///
    /// The window's facts go in as they are — whether the pane is a host
    /// session's client, the key and label it was dialled under — and the
    /// pane's own sources beside them. A tmux window's panes run nothing on
    /// this Mac, so their sources are the hosting client's: its stamp names
    /// the host it dialled, and its walk sees the `ssh` it runs.
    ///
    /// - Parameter surface: The pane.
    /// - Returns: Core's answer for it.
    package func paneHost(of surface: TerminalSurface) -> Ubiquitty.Session.PaneHost {
        var inputs = Ubiquitty.Session.PaneHostInputs()
        inputs.isHostSession = surface.drive.isRemoteAttached
        inputs.isShared = surface.drive.isSharedIntoLocalDaemon
        inputs.usesQUIC = surface.drive.isRemoteUsingQUIC
        inputs.hostKey = std.string(remoteHostKey)
        inputs.hostLabel = std.string(remoteHostLabel)
        inputs.location = (hostingSurface ?? surface).drive.locationInputs()
        return Ubiquitty.Session.resolvePaneHost(inputs)
    }

    /// Where a pane's session lives, as a place.
    ///
    /// - Parameter surface: The pane.
    /// - Returns: Core's place for it.
    package func hostPlace(of surface: TerminalSurface) -> Ubiquitty.Session.HostPlace {
        paneHost(of: surface).place
    }

    /// The name a pane's host goes by in the chrome, empty for a plain local
    /// shell.
    ///
    /// - Parameter surface: The pane.
    /// - Returns: The host's name.
    package func hostName(of surface: TerminalSurface) -> String {
        RemoteConnectionIndicator.hostName(of: paneHost(of: surface))
    }

    /// Whether this window's pane bars name each pane's host: Core's answer
    /// over every pane the window shows, which is yes only where they live in
    /// more than one place — a shared pane beside plain shells, or a shell
    /// that went to another machine beside one that stayed.
    ///
    /// - Returns: Whether a pane bar carries its host.
    package func paneHeadersNameHost() -> Bool {
        var mix = Ubiquitty.Session.PaneHostMix()
        for surface in surfaces.values {
            let host = paneHost(of: surface)
            mix.add(host.place, host.machine)
        }
        for surface in remotePaneSurfaces.values {
            let host = paneHost(of: surface)
            mix.add(host.place, host.machine)
        }
        return mix.shouldNameHost()
    }

    /// Records where this tab's title pane lives, as the last title refresh
    /// found it, and asks the group's labels to be baked again when it moved.
    ///
    /// Each tab of a group reads every other tab's place to learn whether the
    /// window mixes places. Kept here rather than resolved per reader: the
    /// labels are refreshed on every screen update, and a walk of every tab's
    /// panes on each would be the group's size in work for a fact that moves
    /// when a link does.
    ///
    /// - Parameter host: Core's answer for the pane the tab's title names.
    func noteTabHost(_ host: Ubiquitty.Session.PaneHost) {
        let machine = String(host.machine)
        guard tabHost == nil || tabHost!.place != host.place || tabHost!.machine != machine else { return }
        let hadPlace = tabHost != nil
        tabHost = (host.place, machine)
        // The other tabs' labels were baked against this tab's previous
        // place. The first answer is the tab arriving, which its group hears of
        // as a selection or a focus edge already.
        if hadPlace, (window?.tabGroup?.windows.count ?? 1) > 1 {
            refreshSiblingTabTitles()
        }
    }

    /// What this window's chrome says of its host and whether its tabs live
    /// in more than one place, for Core's rule on which tab labels name a
    /// host.
    ///
    /// The chrome is the front tab's: its title row is the one on screen, so
    /// the chip standing there is what a reader has already been told. The
    /// mix is Core's ``Ubiquitty/Session/PaneHostMix`` over the place each
    /// tab's title pane was last found in.
    ///
    /// - Returns: The host the chip names, empty when it names none, and
    ///   whether the tabs mix places.
    func windowHostFacts() -> (hostName: String, doTabsMixPlaces: Bool) {
        guard let window else { return ("", false) }
        var mix = Ubiquitty.Session.PaneHostMix()
        for tabWindow in window.tabGroup?.windows ?? [window] {
            guard let controller = tabWindow.windowController as? TerminalWindowController, !controller.isWindowClosed else {
                continue
            }
            if controller.tabHost == nil, let surface = controller.titleSurface {
                let host = controller.paneHost(of: surface)
                controller.tabHost = (host.place, String(host.machine))
            }
            if let place = controller.tabHost {
                mix.add(place.place, std.string(place.machine))
            }
        }
        let front = (window.tabGroup?.selectedWindow ?? window).windowController as? TerminalWindowController
        return (front?.remoteConnectionIndicator?.statedHostName ?? "", mix.shouldNameHost())
    }

    /// Names the window's host in its subtitle, the line AppKit carries under
    /// the title wherever the system shows the window by name, or clears it.
    ///
    /// - Parameter host: Where the window's session lives.
    func refreshHostSubtitle(host: Ubiquitty.Session.PaneHost) {
        guard let window else { return }
        let subtitle = RemoteConnectionIndicator.hostName(of: host)
        if window.subtitle != subtitle {
            window.subtitle = subtitle
        }
    }

    /// Detaches this window's host endpoints as the window goes.
    ///
    /// The daemon keeps the sessions either way — that is the point of the
    /// pairing this window wrote — so the only thing decided here is the
    /// moment the endpoints go. This one, rather than whenever the last
    /// reference to a surface happens to fall: Core's workspace registry hands a connect the
    /// connection an earlier window opened, and an endpoint still holding the
    /// session that connect asks for turns it into a refusal against an attach
    /// this app itself owns — so the window meant to replace this one never
    /// opens at all.
    ///
    /// Every endpoint the window owns, its own and each pane it mirrors,
    /// because each holds an attachment of its own on the workspace's carrier.
    /// The carrier is not this window's to end: it is held by reference, so a
    /// sibling window projecting the same workspace keeps it and only the last
    /// holder's release takes it down.
    func detachRemoteOnClose() {
        var endpoints: [TerminalSurface] = []
        if let root = remoteSurface {
            endpoints.append(root)
        }
        for pane in remotePaneSurfaces.values where !endpoints.contains(where: { $0 === pane }) {
            endpoints.append(pane)
        }
        for endpoint in endpoints {
            endpoint.drive.close()
        }
        // Closed by the person, the window detached its attachment and left
        // nothing to resume; closed by a quit, it keeps its record.
        if !RemoteSessionLifecycle.shared.isTerminating {
            remoteResume?.retire()
        }
        remoteResume = nil
    }

    /// Takes the paste-push panel down ahead of a remote window closing.
    ///
    /// A push crosses to the host this window's session lives on, and the panel
    /// names that destination while it is in flight. The session is gone, so
    /// the bytes have nowhere to land and no answer is coming: a panel left
    /// standing would sit over a closed window naming a host that is not there,
    /// waiting for a status the wire will never carry. Ahead of the close
    /// rather than after it, so the panel never outlives the window by a frame.
    ///
    /// Through the shell's presenter, which is how the panel reaches the Kit at
    /// all: an embedder hosting a surface without the app's window furniture
    /// has no panel, and nothing here should know that.
    func dismissPastePushForRemoteClose() {
        Self.pastePushPresenter?.dismissed()
    }

    /// Presents transport state without replacing the last terminal snapshot.
    ///
    /// - Parameters:
    ///   - surface: The session surface that owns the status.
    ///   - state: The current state supplied by Core.
    ///   - detail: The failure reason supplied by Core.
    package func presentRemoteConnectionStatus(on surface: TerminalSurface, state: Ubiquitty.Session.State, detail: String) {
        if state == .Connected, surface === remoteSurface {
            remoteResume?.noteConnected(surface.drive)
        }
        let existing = surface.subviews.compactMap { $0 as? RemoteConnectionStatusView }.first
        let linkDetail = surface.drive.paneLinkIndicatorText
        if state == .Connected && linkDetail.isEmpty {
            existing?.removeFromSuperview()
            return
        }
        let status = existing ?? RemoteConnectionStatusView()
        if status.superview == nil {
            surface.addSubview(status)
            let preferredWidth = status.widthAnchor.constraint(equalToConstant: 440)
            preferredWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                status.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
                status.topAnchor.constraint(equalTo: surface.topAnchor, constant: 16),
                status.leadingAnchor.constraint(greaterThanOrEqualTo: surface.leadingAnchor, constant: 12),
                status.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -12),
                preferredWidth,
            ])
        }
        let statusDetail: String
        if state == .Connected {
            statusDetail = linkDetail
        } else if state == .Failed, let refusal = surface.drive.lastHostRefusal {
            // The persistent overlay should explain the refusal, not repeat the
            // wire diagnostic already available in the alert's technical details.
            statusDetail = refusalSheetContent(reason: refusal.reason, hostBuild: refusal.hostBuild, detail: "").sentence
        } else {
            statusDetail = detail
        }
        status.update(state: state, host: remoteHostLabel, detail: statusDetail)
    }

    /// Shows Core's notice over a pane while some of what was typed into it
    /// may not have reached its host, and takes it down once nothing awaits
    /// the person's decision.
    ///
    /// The two answers reach Core only from the notice's buttons: sending
    /// again can run a command twice, so nothing here sends unasked.
    ///
    /// - Parameter surface: The pane whose input may be in doubt.
    package func presentInputInDoubt(on surface: TerminalSurface) {
        presentInputInDoubt(
            surface.drive.inputInDoubtNotice,
            on: surface,
            resend: { [weak self, weak surface] in
                guard let surface else { return }
                surface.drive.resendInputInDoubt()
                self?.presentInputInDoubt(on: surface)
            },
            discard: { [weak self, weak surface] in
                guard let surface else { return }
                surface.drive.discardInputInDoubt()
                self?.presentInputInDoubt(on: surface)
            }
        )
    }

    /// Shows a notice over the bottom of a pane, or takes it down.
    ///
    /// The notice never takes the keyboard: the pane keeps it, its picture
    /// stays readable and selectable, and what the person types waits behind
    /// the input in doubt.
    ///
    /// - Parameters:
    ///   - notice: Core's words, or nil to take the notice down.
    ///   - surface: The pane it belongs to.
    ///   - resend: What Send Again does.
    ///   - discard: What Discard does.
    package func presentInputInDoubt(
        _ notice: RuntimeDrive.InputInDoubtNotice?,
        on surface: TerminalSurface,
        resend: @escaping @MainActor () -> Void,
        discard: @escaping @MainActor () -> Void
    ) {
        let existing = surface.subviews.compactMap { $0 as? InputInDoubtView }.first
        guard let notice else {
            existing?.removeFromSuperview()
            return
        }
        let view = existing ?? InputInDoubtView()
        let isNew = view.superview == nil
        if isNew {
            surface.addSubview(view)
            let preferredWidth = view.widthAnchor.constraint(equalToConstant: 440)
            preferredWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
                view.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: surface.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -12),
                preferredWidth,
            ])
        }
        view.update(notice: notice, resend: resend, discard: discard)
        if isNew {
            NSAccessibility.post(
                element: view,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: notice.message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    /// Presents Core's refusal summary and remedies, retaining the host's full diagnostic in details.
    ///
    /// - Parameters:
    ///   - sessionID: The session the host refused.
    ///   - detail: The host's reason, empty when it sent none.
    private func presentReattachRefusal(sessionID: UInt32, detail: String) {
        // Dropped before the sheet: the host has said the session will not
        // come back, and a pairing kept would send the next connect after it
        // again.
        if !remoteHostKey.isEmpty { HostDirectory.forget(host: remoteHostKey) }
        let refusal = remoteSurface?.drive.lastHostRefusal
        let content = refusalSheetContent(
            reason: refusal?.reason ?? .SessionGone,
            hostBuild: refusal?.hostBuild ?? .init(),
            detail: detail
        )
        presentRefusalSheet(sessionID: sessionID, content: content)
    }
}

/// Shows the current connection state over the terminal's retained contents.
@MainActor
package final class RemoteConnectionStatusView: NSVisualEffectView {
    package let message = NSTextField(wrappingLabelWithString: "")
    package let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("remoteConnectionStatus")
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        message.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        message.setAccessibilityIdentifier("remoteConnectionMessage")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        detailLabel.setAccessibilityIdentifier("remoteConnectionDetail")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        let heading = NSStackView(views: [progress, message])
        heading.orientation = .horizontal
        heading.spacing = 8
        let content = NSStackView(views: [heading, detailLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Updates visible progress and the supplied failure reason.
    ///
    /// - Parameters:
    ///   - state: The transport state reported by Core.
    ///   - host: The destination's display label.
    ///   - detail: The failure reason, if available.
    func update(state: Ubiquitty.Session.State, host: String, detail: String) {
        let destination = host.isEmpty ? "host" : host
        switch state {
        case .Idle, .Connecting:
            message.stringValue = "Connecting to \(destination)…"
        case .Deploying:
            message.stringValue = "Setting up \(destination)…"
        case .Reconnecting:
            message.stringValue = "Reconnecting to \(destination)…"
        case .Failed:
            message.stringValue = "Connection to \(destination) ended"
        case .Connected:
            message.stringValue = "Connected to \(destination)"
        @unknown default:
            message.stringValue = "Waiting for \(destination)…"
        }
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        let isWorking = state != .Failed && state != .Connected
        progress.isHidden = !isWorking
        if isWorking {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }
}

/// Tells the person that some of what they typed may not have reached the
/// host, and offers Core's two answers.
///
/// Neither button is a default or takes the keyboard: Return keeps going to
/// the pane, so nothing is sent again by a key meant for the program.
@MainActor
package final class InputInDoubtView: NSVisualEffectView {
    package let message = NSTextField(wrappingLabelWithString: "")
    package let detailLabel = NSTextField(wrappingLabelWithString: "")
    package let resendButton = NSButton(title: "", target: nil, action: nil)
    package let discardButton = NSButton(title: "", target: nil, action: nil)
    private var resend: @MainActor () -> Void = {}
    private var discard: @MainActor () -> Void = {}

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("inputInDoubt")
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        message.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        message.setAccessibilityIdentifier("inputInDoubtMessage")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setAccessibilityIdentifier("inputInDoubtDetail")
        for button in [resendButton, discardButton] {
            button.bezelStyle = .push
            button.controlSize = .regular
            button.refusesFirstResponder = true
            button.target = self
        }
        resendButton.action = #selector(sendAgain(_:))
        discardButton.action = #selector(discardInput(_:))
        resendButton.setAccessibilityIdentifier("inputInDoubtSendAgain")
        discardButton.setAccessibilityIdentifier("inputInDoubtDiscard")
        let words = NSStackView(views: [message, detailLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        let buttons = NSStackView(views: [discardButton, resendButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let content = NSStackView(views: [words, buttons])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            words.widthAnchor.constraint(equalTo: content.widthAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Shows Core's words and what each answer does.
    ///
    /// - Parameters:
    ///   - notice: The notice.
    ///   - resend: What Send Again does.
    ///   - discard: What Discard does.
    func update(
        notice: RuntimeDrive.InputInDoubtNotice,
        resend: @escaping @MainActor () -> Void,
        discard: @escaping @MainActor () -> Void
    ) {
        message.stringValue = notice.message
        detailLabel.stringValue = notice.detail
        resendButton.title = notice.resendButton
        discardButton.title = notice.discardButton
        setAccessibilityLabel(notice.message)
        self.resend = resend
        self.discard = discard
    }

    @objc
    private func sendAgain(_: Any?) { resend() }

    @objc
    private func discardInput(_: Any?) { discard() }
}

/// The live remote windows, read as facts: which window shows a session, and
/// which windows show a host.
///
/// One function finds the window an attach would reuse, and both the spawn and
/// the Connect window's "Show Window" call it: a Connect window that matched
/// windows its own way would offer "Show Window" for a window the spawn would
/// not reuse, or open a second window beside one it would.
@MainActor
package enum RemoteWindowRegistry {
    /// What an attach names, as the spawn takes it.
    package struct Request {
        package var shellCommand: String
        package var workspaceID: UInt32
        package var sessionID: UInt32
        package var workspaceName: String
        package var daemonSocketName: String
        package var daemonInstanceID: UInt64

        package init(
            shellCommand: String,
            workspaceID: UInt32,
            sessionID: UInt32,
            workspaceName: String,
            daemonSocketName: String,
            daemonInstanceID: UInt64
        ) {
            self.shellCommand = shellCommand
            self.workspaceID = workspaceID
            self.sessionID = sessionID
            self.workspaceName = workspaceName
            self.daemonSocketName = daemonSocketName
            self.daemonInstanceID = daemonInstanceID
        }
    }

    /// One open window showing a pane of the requested workspace.
    package struct Match {
        package let controller: TerminalWindowController
        package let pane: TerminalSurface
    }

    /// Every open window showing a pane the request names.
    ///
    /// A request naming no session, workspace or name names nothing to reuse:
    /// it asks for a fresh session.
    ///
    /// - Parameter request: The attach.
    /// - Returns: The matches, in window order.
    package static func matches(for request: Request) -> [Match] {
        guard request.sessionID != 0 || request.workspaceID != 0 || !request.workspaceName.isEmpty else {
            return []
        }
        var found: [Match] = []
        for existing in TerminalWindowController.spawnedControllers where !existing.isWindowClosed {
            var candidates = Array(existing.remotePaneSurfaces.values)
            if let root = existing.remoteSurface, !candidates.contains(where: { $0 === root }) {
                candidates.append(root)
            }
            // A window shared into this Mac's daemon projects the workspace
            // it published, on the connection an attach of it reuses.
            for shared in existing.projectedSurfaces
            where shared.drive.isSharedIntoLocalDaemon && !candidates.contains(where: { $0 === shared }) {
                candidates.append(shared)
            }
            for pane in candidates
            where pane.drive.matchesRemoteWorkspace(
                shellCommand: request.shellCommand,
                workspaceID: request.workspaceID,
                sessionID: request.sessionID,
                workspaceName: request.workspaceName,
                daemonSocketName: request.daemonSocketName,
                daemonInstanceID: request.daemonInstanceID
            ) {
                found.append(Match(controller: existing, pane: pane))
            }
        }
        return found
    }

    /// The window an attach reuses instead of opening one.
    ///
    /// The pane showing the requested session when one does, else the first
    /// window of the requested workspace.
    ///
    /// - Parameters:
    ///   - request: The attach.
    ///   - matches: ``matches(for:)``'s answer, when the caller already has it.
    /// - Returns: The window and pane, or nil when the attach opens a window.
    package static func existingWindow(for request: Request, among matches: [Match]? = nil) -> Match? {
        let candidates = matches ?? self.matches(for: request)
        if request.sessionID != 0, let exact = candidates.first(where: { $0.pane.remoteSessionID == request.sessionID }) {
            return exact
        }
        return candidates.first
    }

    /// Whether any open window shows a session of the host filed under a key.
    ///
    /// - Parameter hostKey: The pairing key.
    /// - Returns: Whether one does.
    package static func isShowingHost(_ hostKey: String) -> Bool {
        !hostKey.isEmpty
            && TerminalWindowController.spawnedControllers.contains { !$0.isWindowClosed && $0.remoteHostKey == hostKey }
    }

    /// What a reader of a host's outline calls the host a pairing key files:
    /// nothing for this Mac, the key itself for any other.
    ///
    /// - Parameter hostKey: The pairing key.
    /// - Returns: The host's name as Core's outline request takes it.
    package static func readerHost(forKey hostKey: String) -> String {
        hostKey == TerminalWindowController.thisMacHostKey ? "" : hostKey
    }

    /// What this app has open, on every host: each window's host, workspace
    /// and the session it attached with.
    ///
    /// Facts for Core, which answers from them whether opening a row reveals
    /// a window that is already here or attaches; nothing here decides that.
    ///
    /// - Returns: One entry per open window attached to a host.
    package static func openWorkspaces() -> [HostOutlineOpenWorkspace] {
        TerminalWindowController.spawnedControllers.compactMap { controller in
            guard !controller.isWindowClosed, !controller.remoteHostKey.isEmpty, let root = controller.remoteSurface,
                root.remoteSessionID != 0
            else { return nil }
            return HostOutlineOpenWorkspace(
                host: readerHost(forKey: controller.remoteHostKey),
                workspaceID: root.drive.remoteWorkspaceID,
                sessionID: root.remoteSessionID
            )
        }
    }

    /// Brings forward the window that already shows what Core says a row
    /// reveals, at the pane Core names.
    ///
    /// - Parameters:
    ///   - hostKey: The pairing key of the host the row is on.
    ///   - sessionID: The session this app holds the workspace open with.
    ///   - paneID: The pane to show, 0 for wherever the window's focus is.
    /// - Returns: Whether a window came forward.
    package static func reveal(hostKey: String, sessionID: UInt32, paneID: UInt32) -> Bool {
        for controller in TerminalWindowController.spawnedControllers
        where !controller.isWindowClosed && controller.remoteHostKey == hostKey {
            guard let root = controller.remoteSurface, root.remoteSessionID == sessionID else { continue }
            // The pane may be in another tab of the same workspace: every
            // window projecting it is searched for the pane's own view.
            for sibling in TerminalWindowController.spawnedControllers
            where !sibling.isWindowClosed && sibling.remoteHostKey == hostKey
                && sibling.remoteSurface?.drive.remoteWorkspaceID == root.drive.remoteWorkspaceID
            {
                if let pane = Ubiquitty.Session.Layout.PaneID(rawValue: paneID), let surface = sibling.remotePaneSurfaces[pane] {
                    sibling.activateRemotePane(surface)
                    return true
                }
            }
            controller.activateRemotePane(root)
            return true
        }
        return false
    }
}
