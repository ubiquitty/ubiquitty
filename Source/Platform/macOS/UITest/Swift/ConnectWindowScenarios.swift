// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UbiquittyCore
import UbiquittyKit

import struct UbiquittyRenderKit.HostOutlineIdentity
import struct UbiquittyRenderKit.HostOutlineRow

private typealias SyncWire = Ubiquitty.`Protocol`.Sync

// ConnectWindowScenarios.swift — the Connect window itself: its shape, its
// keys, its layered Escape, and the states it shows for what Core reported.
//
// Driven through the window and the one model it draws, never through a
// second copy of either: a scenario that built its own model would pass
// against a window nobody opens. Actions that would open a terminal window on
// a host that does not exist are recorded instead, so a key can be watched
// reaching them.

/// Registers the Connect window scenarios with the UI-test runner.
enum ConnectWindowScenarios {
    /// The defaults keys these scenarios write, cleared around each one.
    private static let touchedDefaultsKeys = [
        "UBHostServers", "UBHostSessionPairings", "UBConnectRecents", "UBConnectLastPlace", "UBConnectLastHost",
    ]

    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("connect_window_shape_and_identifiers") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                model.shouldRecordActionsForTesting = true
                defer { closeConnect() }

                ConnectWindowController.show(place: .layouts)
                guard let window = ConnectWindowController.shared.window else {
                    t.expect(false, desc: "the Connect window exists")
                    return
                }
                t.expect(window.styleMask.contains(.fullSizeContentView), desc: "content extends under the toolbar")
                t.expect(window.toolbarStyle == .unified, desc: "the toolbar is unified")
                t.expect(
                    window.contentMinSize.width >= 720 && window.contentMinSize.height >= 440,
                    desc: "the window keeps its minimum size"
                )
                t.expect(t.wait(until: { window.toolbar != nil }, timeout: 3), desc: "the view's toolbar is bridged into the window")
                t.expect(
                    t.wait(until: { window.title == "Layouts" }, timeout: 3),
                    desc: "the window title is the selected place (\(window.title))"
                )

                ConnectWindowController.show(place: .shell(.ssh))
                t.expect(
                    t.wait(until: { window.title == "SSH Shell" }, timeout: 3),
                    desc: "selecting a place retitles the window (\(window.title))"
                )

                // The content state's identifier is `connect-state-` plus the
                // name the model computes, so the name is what is asserted.
                let server = invalidServer(named: "Shape Box")
                model.setHostsForTesting([server])
                model.directory.isDiallingSuppressedForTesting = true
                defer { model.directory.isDiallingSuppressedForTesting = false }
                ConnectWindowController.show(place: .host(server.id))
                t.expect(
                    t.wait(until: { window.title == "Shape Box" }, timeout: 3),
                    desc: "a host place is titled with the host (\(window.title))"
                )
                model.directory.holdShowcaseHostForTesting(.holdingNothing)
                t.expect(model.contentState.name == "empty", desc: "an empty host shows connect-state-empty (\(model.contentState.name))")
                model.directory.holdShowcaseHostForTesting(.listed)
                t.expect(
                    model.contentState.name == "sessions",
                    desc: "a host holding workspaces shows connect-state-sessions (\(model.contentState.name))"
                )
            }
        }

        UBUITestRegister("connect_key_equivalents_stay_in_connect") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                model.shouldRecordActionsForTesting = true
                model.recordedActionsForTesting = []
                model.directory.isDiallingSuppressedForTesting = true
                defer {
                    model.directory.isDiallingSuppressedForTesting = false
                    model.shouldRecordActionsForTesting = false
                    closeConnect()
                }
                let server = invalidServer(named: "Keys Box")
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                guard let window = ConnectWindowController.shared.window else {
                    t.expect(false, desc: "the Connect window exists")
                    return
                }
                t.pump(0.4)
                model.directory.holdShowcaseHostForTesting(.listed)
                t.pump(0.2)
                // A row that names one session: the workspace of one pane.
                guard let scratch = model.directory.outline.rows.first(where: { $0.level == .workspace && $0.title == "scratch" }) else {
                    t.expect(false, desc: "the scratch workspace has a row")
                    return
                }

                let inspectorBefore = model.isInspectorPresented
                t.expect(
                    window.performKeyEquivalent(with: keyEvent("i", modifiers: [.control, .command], in: window)),
                    desc: "⌃⌘I is answered by Connect"
                )
                t.pump(0.2)
                t.expect(model.isInspectorPresented != inspectorBefore, desc: "⌃⌘I toggles the inspector")

                let asksBefore = model.directory.refreshCountForTesting
                t.expect(
                    window.performKeyEquivalent(with: keyEvent("r", modifiers: .command, in: window)),
                    desc: "⌘R is answered by Connect"
                )
                t.pump(0.2)
                t.expect(
                    model.directory.refreshCountForTesting == asksBefore + 1,
                    desc: "⌘R asks the host once (\(model.directory.refreshCountForTesting - asksBefore))"
                )

                t.expect(
                    window.performKeyEquivalent(with: keyEvent("\r", modifiers: .option, in: window)),
                    desc: "⌥↩ is answered by Connect"
                )
                t.pump(0.2)
                t.expect(
                    model.recordedActionsForTesting.contains("newSession"),
                    desc: "⌥↩ starts a new session (\(model.recordedActionsForTesting))"
                )
                t.expect(!model.isNamingSession, desc: "⌥↩ does not ask for a name")
                t.expect(
                    window.performKeyEquivalent(with: keyEvent("\r", modifiers: [.option, .shift], in: window)),
                    desc: "⌥⇧↩ is answered by Connect"
                )
                t.pump(0.2)
                t.expect(model.isNamingSession, desc: "⌥⇧↩ asks for a session name")
                model.isNamingSession = false
                t.pump(0.3)

                // With Core's plan able to act, Return runs it and ⌥↩ still
                // starts a new session rather than the plan.
                model.directory.selection = scratch.key
                t.pump(0.2)
                model.recordedActionsForTesting = []
                t.expect(window.performKeyEquivalent(with: keyEvent("\r", modifiers: [], in: window)), desc: "↩ is answered by Connect")
                t.pump(0.2)
                t.expect(model.recordedActionsForTesting == ["primary"], desc: "↩ runs the default (\(model.recordedActionsForTesting))")
                model.recordedActionsForTesting = []
                _ = window.performKeyEquivalent(with: keyEvent("\r", modifiers: .option, in: window))
                t.pump(0.2)
                t.expect(
                    model.recordedActionsForTesting == ["newSession"],
                    desc: "⌥↩ is New Workspace, not the default (\(model.recordedActionsForTesting))"
                )
                model.directory.selection = nil
                t.pump(0.2)

                model.directory.selection = scratch.key
                t.pump(0.1)
                let deleteKey = String(UnicodeScalar(UInt8(NSBackspaceCharacter)))
                t.expect(
                    window.performKeyEquivalent(with: keyEvent(deleteKey, modifiers: .command, in: window)),
                    desc: "⌘⌫ is answered by Connect"
                )
                t.pump(0.2)
                t.expect(
                    model.recordedActionsForTesting.contains("terminate"),
                    desc: "⌘⌫ asks to terminate the selected session (\(model.recordedActionsForTesting))"
                )

                // The app's own chords pass through: Connect claims none of them.
                t.expect(
                    !window.performKeyEquivalent(with: keyEvent("n", modifiers: .command, in: window)),
                    desc: "⌘N is left to File ▸ New Window"
                )
                t.expect(
                    !window.performKeyEquivalent(with: keyEvent("1", modifiers: .command, in: window)),
                    desc: "⌘1 is left to Select Tab"
                )
                t.expect(
                    !window.performKeyEquivalent(with: keyEvent("d", modifiers: .command, in: window)),
                    desc: "⌘D is left to Split Right"
                )
            }
        }

        UBUITestRegister("connect_escape_is_layered_and_closes_only_connect") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                model.shouldRecordActionsForTesting = true
                defer {
                    model.shouldRecordActionsForTesting = false
                    t.closeAllWindows()
                }
                guard let terminal = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                let server = invalidServer(named: "Escape Box")
                model.setHostsForTesting([server])
                HostDirectory.forget(host: server.pairingKey)
                ConnectWindowController.show(place: .host(server.id))
                let controller = ConnectWindowController.shared
                t.pump(0.3)

                model.searchText = "builds"
                controller.cancelOperation(nil)
                t.expect(model.searchText.isEmpty, desc: "Esc first clears the search")
                t.expect(controller.window?.isVisible == true, desc: "and leaves the window open")

                model.directory.markListingOutstandingForTesting()
                _ = model.directory.connect()
                t.expect(model.directory.isConnectPending, desc: "a connect is waiting for the host")
                controller.cancelOperation(nil)
                t.expect(!model.directory.isConnectPending, desc: "Esc next stops the waiting connect")
                t.expect(controller.window?.isVisible == true, desc: "and still leaves the window open")

                controller.cancelOperation(nil)
                t.expect(t.wait(until: { controller.window?.isVisible != true }, timeout: 2), desc: "Esc then closes Connect")
                t.expect(terminal.window?.isVisible == true, desc: "and only Connect: the terminal window stays open")
            }
        }

        UBUITestRegister("connect_terminate_alert_defaults_to_the_safe_button") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Presented on the Connect window as a sheet, never app-modal,
                // in Core's words, with the button that ends nothing first.
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                model.directory.isDiallingSuppressedForTesting = true
                defer {
                    model.directory.isDiallingSuppressedForTesting = false
                    closeConnect()
                }
                let server = invalidServer(named: "Sheet Box")
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                guard let window = ConnectWindowController.shared.window else {
                    t.expect(false, desc: "the Connect window exists")
                    return
                }
                t.pump(0.3)
                let directory = model.directory
                directory.holdShowcaseHostForTesting(.listed)
                guard let scratch = directory.outline.rows.first(where: { $0.level == .workspace && $0.title == "scratch" }),
                    let services = directory.outline.rows.first(where: { $0.level == .window && $0.title == "services" })
                else {
                    t.expect(false, desc: "the showcase host has a one-pane workspace and a window of several tabs")
                    return
                }
                directory.selection = scratch.key
                t.expect(
                    window.attachedSheet == nil,
                    desc: "no sheet is up before the question (\(window.attachedSheet.map { String(describing: type(of: $0)) } ?? "none"))"
                )

                // Each request that ends sessions asks Core's question first:
                // a terminate from the keyboard, and a window's close.
                let asks: [(String, @MainActor () -> Void)] = [
                    ("terminating a workspace", { model.confirmTerminateSelection() }),
                    (
                        "closing a window",
                        { directory.window(of: services).map { directory.askToEnd(.closeWindow, $0, named: services.title) } }
                    ),
                ]
                for (what, ask) in asks {
                    ask()
                    guard let question = directory.destructiveQuestion else {
                        t.expect(false, desc: "\(what) asks Core's question")
                        return
                    }
                    t.expect(
                        question.token != 0 && !question.sessionIDs.isEmpty,
                        desc: "\(what): Core gives the question a token and names what ends"
                    )
                    t.expect(
                        t.wait(until: { window.attachedSheet != nil }, timeout: 2),
                        desc: "\(what): the question is a sheet on the Connect window"
                    )
                    t.expect(NSApp.modalWindow == nil, desc: "and nothing runs app-modal")
                    guard let sheet = window.attachedSheet else { return }
                    let presented = ConnectWindowController.shared.destructiveAlertForTesting
                    t.expect(presented?.window === sheet, desc: "the sheet is that question")
                    t.expect(
                        presented?.messageText == question.title && presented?.informativeText == question.body,
                        desc: "in Core's words and no others (\(presented?.messageText ?? "none"))"
                    )
                    t.expect(
                        presented?.buttons.map(\.title) == question.buttons.map(\.title)
                            && question.buttons.map(\.isDestructive) == [false, true],
                        desc: "with Core's two buttons, the safe one first (\(presented?.buttons.map(\.title) ?? []))"
                    )
                    // A presented alert's Return is its window's default
                    // button cell; the buttons' own key equivalents move on
                    // presentation.
                    t.expect(
                        sheet.defaultButtonCell?.title == question.buttons.first?.title,
                        desc: "the safe button holds Return on the sheet (\(sheet.defaultButtonCell?.title ?? "none"))"
                    )
                    t.expect(presented?.alertStyle == .critical, desc: "and the sheet is critical")
                    t.expect(
                        presented?.buttons.last?.hasDestructiveAction == true && presented?.buttons.first?.hasDestructiveAction == false,
                        desc: "the button that goes through is marked destructive, and the safe one is not"
                    )
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    t.expect(t.wait(until: { window.attachedSheet == nil }, timeout: 2), desc: "the safe button takes the sheet down")
                    t.pump(0.2)
                    t.expect(directory.terminatingSessionIDs.isEmpty, desc: "and sends nothing")
                    t.expect(directory.destructiveQuestion == nil, desc: "leaving no question waiting")
                }
                t.expect(!HostDestructiveAlert.isConfirmed(.alertFirstButtonReturn), desc: "the first button does not go through")
                t.expect(HostDestructiveAlert.isConfirmed(.alertSecondButtonReturn), desc: "the second one does")

                // A row Core has nothing to end for says why, in Core's
                // sentence, and asks nothing.
                directory.notice = nil
                directory.askToEnd(.terminateWorkspace, HostOutlineIdentity(kind: .workspace, number: 99_999), named: "gone")
                t.expect(directory.destructiveQuestion == nil, desc: "a workspace the host does not hold is not asked about")
                t.expect(directory.notice?.title.isEmpty == false, desc: "and Core says why (\(directory.notice?.title ?? "none"))")
                directory.notice = nil
            }
        }

        UBUITestRegister("connect_listing_failures_are_typed_states") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                model.directory.isDiallingSuppressedForTesting = true
                defer {
                    model.directory.isDiallingSuppressedForTesting = false
                    closeConnect()
                }
                let server = invalidServer(named: "States Box")
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                t.pump(0.3)
                let directory = model.directory

                let cases: [(HostListingFailure, String)] = [
                    (.of(.unreachable), "unreachable"),
                    (.of(.notInstalled), "not-installed"),
                    (.of(.signInRequired), "sign-in-required"),
                    (.of(.authenticationAttemptsExhausted), "authentication-attempts-exhausted"),
                    (.of(.endedBeforeAnswer), "ended-before-answer"),
                    (.of(.refused, deniedReason: .TokenMissing), "needs-token"),
                    (.of(.refused, deniedReason: .TokenExpired), "token-expired"),
                ]
                for (failure, name) in cases {
                    directory.holdShowcaseHostForTesting(.holdingNothing)
                    directory.setSnapshotForTesting(phase: .failed, failure: failure)
                    t.expect(
                        model.contentState.name == name,
                        desc: "\(failure.kind) shows connect-state-\(name) (\(model.contentState.name))"
                    )
                    t.expect(!model.remedyFact.remedies.isEmpty, desc: "and Core offers a remedy for \(name)")
                }

                // A server that ended the sign-in after too many attempts is
                // named for that, never as a host that could not be reached.
                directory.holdShowcaseHostForTesting(.holdingNothing)
                directory.setSnapshotForTesting(phase: .failed, failure: .of(.authenticationAttemptsExhausted))
                let title = String(directory.sectionWords.title)
                t.expect(title == "Too Many Authentication Attempts", desc: "the title names the attempts (\(title))")
                t.expect(
                    model.remedyFact.sentence.hasPrefix("The server closed the connection after too many authentication attempts."),
                    desc: "the sentence is the server's answer (\(model.remedyFact.sentence))"
                )

                // With a tree still held an unreachable host keeps its rows,
                // and the banner over them offers to ask again.
                directory.holdShowcaseHostForTesting(.listed)
                directory.setSnapshotForTesting(phase: .failed, failure: .of(.unreachable))
                t.expect(model.contentState == .sessions, desc: "held rows stay on screen (\(model.contentState.name))")
                t.expect(model.visibleBanner?.action == .tryAgain, desc: "with Try Again over them")
            }
        }

        UBUITestRegister("connect_empty_this_mac_offers_one_new_session") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyEmptyThisMac(t) }
        }

        UBUITestRegister("connect_this_mac_daemon_is_listed_once") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                defer { closeConnect() }

                // A row on this Mac's daemon naming nothing is the This Mac row
                // again; one naming a session is a different connect.
                let duplicate = HostServer(id: UUID(), name: "Local", host: "local", workspaceName: "")
                let named = HostServer(id: UUID(), name: "Local Notes", host: "local", workspaceName: "notes")
                let remote = invalidServer(named: "Listed Box")
                model.setHostsForTesting([duplicate, named, remote])
                ConnectWindowController.show(place: .layouts)
                guard let window = ConnectWindowController.shared.window else {
                    t.expect(false, desc: "the Connect window exists")
                    return
                }
                t.expect(
                    model.listedHosts.map(\.id) == [named.id, remote.id],
                    desc: "the sidebar lists the named row and the remote (\(model.listedHosts.map(\.displayName)))"
                )
                t.expect(model.hosts.count == 3, desc: "folding is the sidebar's: the saved list keeps every row (\(model.hosts.count))")
                t.expect(
                    model.filteredHosts.map(\.id) == [named.id, remote.id],
                    desc: "the rows the sidebar draws are the listed ones (\(model.filteredHosts.map(\.displayName)))"
                )
                t.expect(window.isVisible, desc: "the window drawing them is on screen")
                t.expect(
                    !ConnectModel.validationReason(for: HostServer(id: UUID(), name: "", host: "local", workspaceName: "")).isEmpty,
                    desc: "a new row on this Mac's daemon naming nothing is refused"
                )
                t.expect(ConnectModel.validationReason(for: named).isEmpty, desc: "one naming a session is accepted")
            }
        }

        UBUITestRegister("connect_invalid_address_is_inline_never_modal") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                defer { closeConnect() }
                let server = invalidServer(named: "Inline Box")
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                guard let window = ConnectWindowController.shared.window else { return }
                t.pump(0.3)

                let reason = model.updateHost(server.id, name: "Inline Box", address: "-oProxyCommand=evil", workspaceName: "")
                t.expect(reason?.contains("option") == true, desc: "Core's reason comes back for the field (\(reason ?? "none"))")
                t.expect(HostServers.all().first?.host == server.host, desc: "the refused address is not saved")
                t.expect(NSApp.modalWindow == nil && window.attachedSheet == nil, desc: "and nothing modal was shown")

                // A saved host whose stored address ssh would misread is a
                // state of the window, not an alert.
                var broken = server
                broken.host = "-oProxyCommand=evil"
                model.setHostsForTesting([broken])
                model.select(.host(broken.id))
                t.pump(0.2)
                t.expect(
                    model.contentState == .invalidAddress,
                    desc: "the host shows its invalid-address state (\(model.contentState.name))"
                )
                t.expect(NSApp.modalWindow == nil && window.attachedSheet == nil, desc: "and still nothing modal")
            }
        }

        UBUITestRegister("connect_remove_host_is_undoable") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                HostServers.installPairingPersistence()
                let model = ConnectModel.shared
                // Removing the selected row selects This Mac, and an ask of
                // This Mac starts its daemon detached, where no teardown here
                // reaches it. The claim is Undo's, so nothing is dialled. A
                // suppressed ask leaves This Mac's directory asking, so it is
                // pointed at nothing before dialling is allowed again: the next
                // selection of This Mac then asks.
                let wasDiallingSuppressed = model.directory.isDiallingSuppressedForTesting
                model.directory.isDiallingSuppressedForTesting = true
                defer {
                    closeConnect()
                    model.select(nil)
                    model.directory.isDiallingSuppressedForTesting = wasDiallingSuppressed
                }
                let server = invalidServer(named: "Removed Box")
                HostDirectory.remember(host: server.pairingKey, sessionID: 42, workspaceName: "")
                defer { HostDirectory.forget(host: server.pairingKey) }
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                guard let window = ConnectWindowController.shared.window else { return }
                t.pump(0.3)

                model.removeHost(server.id)
                t.pump(0.2)
                t.expect(model.hosts.isEmpty, desc: "the row leaves the list at once")
                t.expect(model.visibleBanner?.action == .undoRemoval, desc: "and a banner offers Undo")
                t.expect(
                    HostDirectory.rememberedSessionID(host: server.pairingKey) == 42,
                    desc: "the pairing is kept while Undo can bring the row back"
                )
                t.expect(
                    window.performKeyEquivalent(with: keyEvent("z", modifiers: .command, in: window)),
                    desc: "⌘Z is answered by Connect"
                )
                t.pump(0.2)
                t.expect(model.hosts.map(\.id) == [server.id], desc: "⌘Z puts the row back (\(model.hosts.count))")

                // Removed again and the window closed: the removal is final and
                // the pairing goes with the only row that named the host.
                model.removeHost(server.id)
                ConnectWindowController.shared.window?.close()
                t.pump(0.2)
                t.expect(HostDirectory.rememberedSessionID(host: server.pairingKey) == 0, desc: "closing the window forgets the pairing")

                // Two rows naming one host: removing one keeps the pairing.
                let twin = HostServer(id: UUID(), name: "Twin", host: server.host, workspaceName: "")
                HostDirectory.remember(host: server.pairingKey, sessionID: 43, workspaceName: "")
                model.setHostsForTesting([server, twin])
                ConnectWindowController.show(place: .host(server.id))
                model.removeHost(server.id)
                model.commitRemoval()
                t.expect(
                    HostDirectory.rememberedSessionID(host: server.pairingKey) == 43,
                    desc: "a row still naming the host keeps its pairing"
                )
            }
        }

        UBUITestRegister("connect_inspector_layout_stays_bounded_across_content_changes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                let wasDiallingSuppressed = model.directory.isDiallingSuppressedForTesting
                let wasRecordingActions = model.shouldRecordActionsForTesting
                let wasInspectorPresented = model.isInspectorPresented
                model.directory.isDiallingSuppressedForTesting = true
                model.shouldRecordActionsForTesting = true
                defer {
                    closeConnect()
                    model.directory.isDiallingSuppressedForTesting = wasDiallingSuppressed
                    model.shouldRecordActionsForTesting = wasRecordingActions
                    model.isInspectorPresented = wasInspectorPresented
                }
                let server = invalidServer(named: "Inspector Sizing Box")
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                guard let window = ConnectWindowController.shared.window,
                    let hosting = window.contentViewController as? NSHostingController<ConnectView>
                else {
                    t.expect(false, desc: "the production Connect window hosts its root view")
                    return
                }
                let savedFrame = window.frame
                defer { window.setFrame(savedFrame, display: false) }
                let hasVisibleAddressField = {
                    descendants(of: hosting.view)
                        .contains { view in
                            guard let field = view as? NSTextField else { return false }
                            return field.stringValue == server.host && field.isEditable
                                && !field.isHiddenOrHasHiddenAncestor && field.window === window && !field.visibleRect.isEmpty
                        }
                }

                // The window frame stays fixed: the content changes under a
                // fixed outer proposal, including the inspector's editing form.
                let reportedFrame = NSRect(origin: savedFrame.origin, size: NSSize(width: 807, height: 512))
                window.setFrame(reportedFrame, display: true)
                model.isInspectorPresented = true
                model.directory.holdShowcaseHostForTesting(.holdingNothing)
                t.pump(0.3)
                let settledMinSize = window.contentMinSize
                @MainActor
                func expectStableMinSize(_ transition: String) {
                    let actual = window.contentMinSize
                    t.expect(
                        actual.width >= 720 && actual.height >= 440,
                        desc: "\(transition) preserves the 720×440 minimum (actual \(actual))"
                    )
                    t.expect(
                        actual == settledMinSize,
                        desc: "\(transition) keeps the settled minimum \(settledMinSize) (actual \(actual))"
                    )
                }
                expectStableMinSize("the initial empty-host inspector")
                t.expect(window.frame == reportedFrame, desc: "the empty-host inspector lays out at the reported outer frame")
                t.expect(
                    t.wait(until: hasVisibleAddressField, timeout: 3),
                    desc: "the editable inspector is visible at the reported outer frame"
                )
                model.directory.holdShowcaseHostForTesting(.listed)
                t.pump(0.3)
                expectStableMinSize("the populated inspector")
                t.expect(window.frame == reportedFrame, desc: "the populated inspector keeps that same outer frame")
                model.directory.holdShowcaseHostForTesting(.holdingNothing)
                model.directory.setSnapshotForTesting(phase: .failed, failure: .of(.unreachable))
                t.pump(0.3)
                expectStableMinSize("the failure inspector")
                t.expect(window.frame == reportedFrame, desc: "the failure inspector keeps that same outer frame")
                for width in [CGFloat(807), 720, 1100, 807] {
                    for showsInspector in [true, false] {
                        window.setContentSize(NSSize(width: width, height: 440))
                        model.isInspectorPresented = showsInspector
                        model.directory.holdShowcaseHostForTesting(.holdingNothing)
                        t.pump(0.2)
                        t.expect(model.contentState == .empty, desc: "the empty-host layout is exercised")
                        expectStableMinSize("empty at \(width), inspector \(showsInspector)")
                        model.directory.holdShowcaseHostForTesting(.listed)
                        t.pump(0.2)
                        t.expect(model.contentState == .sessions, desc: "the populated outline layout is exercised")
                        expectStableMinSize("populated at \(width), inspector \(showsInspector)")
                        model.directory.holdShowcaseHostForTesting(.holdingNothing)
                        model.directory.setSnapshotForTesting(phase: .failed, failure: .of(.unreachable))
                        t.pump(0.2)
                        t.expect(model.contentState == .unreachable, desc: "the failure layout is exercised")
                        expectStableMinSize("failure at \(width), inspector \(showsInspector)")
                        t.expect(window.isVisible, desc: "the connect window survives content and inspector changes at \(width)")
                        let settledFrame = window.frame
                        t.pump(0.2)
                        t.expect(window.frame == settledFrame, desc: "the outer frame settles after the content transition")
                    }
                }
                model.isInspectorPresented = true
                t.expect(t.wait(until: hasVisibleAddressField, timeout: 3), desc: "the inspector's address remains visible and editable")
                expectStableMinSize("the reopened inspector")
            }
        }

        UBUITestRegister("connect_inspector_commits_on_return_not_per_keystroke") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                defer { closeConnect() }
                let server = invalidServer(named: "Inspector Box")
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                model.isInspectorPresented = true
                guard let window = ConnectWindowController.shared.window, let content = window.contentView else { return }
                guard
                    t.wait(
                        until: { descendants(of: content).contains { ($0 as? NSTextField)?.stringValue == server.host } },
                        timeout: 3
                    ),
                    let field = descendants(of: content).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == server.host })
                else {
                    let placeholders = descendants(of: content).compactMap { ($0 as? NSTextField)?.placeholderString }
                    t.expect(false, desc: "the inspector shows the address field (placeholders \(placeholders))")
                    return
                }
                window.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else {
                    t.expect(false, desc: "the address field takes text")
                    return
                }
                let asksBefore = model.directory.refreshCountForTesting
                editor.insertText("user@renamed.invalid", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                t.pump(0.2)
                t.expect(
                    HostServers.all().first?.host == server.host,
                    desc: "typing writes nothing (\(HostServers.all().first?.host ?? ""))"
                )
                // Another control ending an edit must not commit this draft.
                // AppKit broadcasts this notification to every observer.
                NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: NSTextField())
                t.pump(0.1)
                t.expect(
                    HostServers.all().first?.host == server.host,
                    desc: "an unrelated field ending its edit does not commit this address"
                )
                editor.insertNewline(nil)
                t.pump(0.3)
                t.expect(
                    HostServers.all().first?.host == "user@renamed.invalid",
                    desc: "Return commits the address (\(HostServers.all().first?.host ?? ""))"
                )
                t.expect(
                    model.directory.refreshCountForTesting == asksBefore + 1,
                    desc: "and the new endpoint is asked exactly once (\(model.directory.refreshCountForTesting - asksBefore))"
                )
            }
        }
    }

    /// Registers the scenarios for what Connect and a terminal window offer
    /// when a host refuses.
    static func registerRefusals() {
        UBUITestRegister("connect_credentials_do_not_block_or_follow_stale_selection") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let previousLoader = HostTokenStore.loadForTesting
                defer { HostTokenStore.loadForTesting = previousLoader }
                var pending: [@MainActor (String?) -> Void] = []
                HostTokenStore.loadForTesting = { _, complete in pending.append(complete) }
                let directory = HostDirectoryModel()
                directory.isDiallingSuppressedForTesting = true
                defer { directory.stopFollowing() }
                let first = HostServer(id: UUID(), name: "First", host: "first.invalid", kind: .ubiquittyHost, workspaceName: "")
                let second = HostServer(id: UUID(), name: "Second", host: "second.invalid", kind: .ubiquittyHost, workspaceName: "")
                directory.point(at: first)
                directory.refresh()
                t.expect(directory.phase == .asking && pending.count == 1, desc: "refresh returns while credential approval is pending")
                directory.point(at: second)
                directory.refresh()
                guard pending.count == 2 else {
                    t.expect(false, desc: "both hosts queue independent credential completions")
                    return
                }
                pending[0]("obsolete-first-token")
                t.expect(directory.lastAuthTokenForTesting.isEmpty, desc: "a former selection cannot set the new host's token")
                pending[1]("current-second-token")
                t.expect(directory.lastAuthTokenForTesting == "current-second-token", desc: "the current selection receives its own token")
                directory.refresh()
                var renamed = second
                renamed.name = "Renamed Second"
                directory.point(at: renamed)
                guard pending.count == 3 else {
                    t.expect(false, desc: "renaming does not queue another credential read")
                    return
                }
                pending[2]("renamed-second-token")
                t.expect(directory.lastAuthTokenForTesting == "renamed-second-token", desc: "renaming a host preserves its pending read")
                directory.refresh()
                directory.refresh()
                guard pending.count == 5 else {
                    t.expect(false, desc: "repeated refreshes queue their own reads")
                    return
                }
                pending[3]("obsolete-refresh-token")
                t.expect(
                    directory.lastAuthTokenForTesting == "renamed-second-token",
                    desc: "an older refresh cannot overwrite the current request"
                )
                directory.stopFollowing()
                pending[4]("token-after-close")
                t.expect(
                    directory.lastAuthTokenForTesting == "renamed-second-token",
                    desc: "closing Connect cancels pending credential delivery"
                )
            }
        }

        UBUITestRegister("remote_window_closed_during_credentials_does_not_attach") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let previousLoader = HostTokenStore.loadForTesting
                let previousCallback = TerminalWindowController.remoteWindowOrderedInForTesting
                defer {
                    HostTokenStore.loadForTesting = previousLoader
                    TerminalWindowController.remoteWindowOrderedInForTesting = previousCallback
                }
                var pending: (@MainActor (String?) -> Void)?
                var attached = 0
                HostTokenStore.loadForTesting = { _, complete in pending = complete }
                TerminalWindowController.remoteWindowOrderedInForTesting = { _ in attached += 1 }
                guard
                    let controller = TerminalWindowController.spawnRemoteWindow(
                        shellCommand: "exit 1",
                        hostLabel: "Credential Test",
                        quicHost: "",
                        quicBootstrapCommand: "",
                        deploySSHHost: "",
                        deployBinaries: [:],
                        reattachSessionID: 0,
                        workspaceName: "",
                        hostKey: "credential-test.invalid"
                    )
                else {
                    t.expect(false, desc: "the window opens before Keychain completes")
                    return
                }
                defer { controller.close() }
                t.expect(pending != nil && attached == 0, desc: "the window opens without blocking or starting a carrier")
                controller.close()
                pending?("late-token")
                t.pump(0.1)
                t.expect(controller.isWindowClosed && attached == 0, desc: "late credential delivery cannot resurrect a closed window")
            }
        }

        UBUITestRegister("connect_token_field_accepts_edit_menu_paste") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                let wasDiallingSuppressed = model.directory.isDiallingSuppressedForTesting
                model.directory.isDiallingSuppressedForTesting = true
                defer {
                    closeConnect()
                    model.directory.isDiallingSuppressedForTesting = wasDiallingSuppressed
                }
                let server = invalidServer(named: "Token Editing Box")
                HostTokenStore.remove(forHost: server.pairingKey)
                defer { HostTokenStore.remove(forHost: server.pairingKey) }
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                model.directory.setSnapshotForTesting(phase: .failed, failure: .of(.refused, deniedReason: .TokenMissing))
                guard let window = ConnectWindowController.shared.window,
                    let content = window.contentView,
                    let editMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu,
                    let pasteItem = editMenu.items.first(where: { $0.title == "Paste" }),
                    let action = pasteItem.action
                else {
                    t.expect(false, desc: "Connect has a window and Edit has a Paste action")
                    return
                }
                t.expect(action == #selector(NSText.paste(_:)), desc: "Paste uses the native text-editing action")
                t.expect(
                    #selector(TerminalWindowController.pasteFromPasteboard(_:)) == action,
                    desc: "a terminal window answers the same Paste action"
                )
                t.expect(
                    pasteItem.keyEquivalent == "v" && pasteItem.keyEquivalentModifierMask == .command,
                    desc: "Command-V invokes Paste"
                )
                guard t.wait(until: { descendants(of: content).contains { $0 is NSSecureTextField } }, timeout: 3),
                    let field = descendants(of: content).compactMap({ $0 as? NSSecureTextField }).first
                else {
                    t.expect(false, desc: "the missing-token state presents its secure token field")
                    return
                }
                t.expect(window.makeFirstResponder(field), desc: "the token field takes focus")
                guard let editor = field.currentEditor() as? NSTextView else {
                    t.expect(false, desc: "the token field owns a native field editor")
                    return
                }
                let token = "uitest-token-clipboard"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
                t.expect(editor.responds(to: action), desc: "the focused token editor answers the menu action")
                t.expect(NSApp.sendAction(action, to: editor, from: pasteItem), desc: "the menu action reaches the token editor")
                t.expect(editor.string == token, desc: "the complete clipboard text reaches the secure field")
                t.pump(0.2)
                t.expect(field.stringValue == token, desc: "the native token field retains the pasted value")
                editor.insertNewline(nil)
                t.expect(
                    t.wait(until: { HostTokenStore.token(forHost: server.pairingKey) == token }, timeout: 3),
                    desc: "Return submits the pasted token through the SwiftUI binding"
                )
            }
        }

        UBUITestRegister("connect_token_lives_in_keychain_not_defaults") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                defer { closeConnect() }
                let server = invalidServer(named: "Token Box")
                HostTokenStore.remove(forHost: server.pairingKey)
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                t.pump(0.3)
                model.directory.setSnapshotForTesting(phase: .failed, failure: .of(.refused, deniedReason: .TokenMissing))
                t.expect(model.contentState == .needsToken, desc: "a host refusing for no token asks for one (\(model.contentState.name))")

                let secret = "uitest-token-\(UUID().uuidString)"
                model.saveToken(secret)
                t.expect(HostTokenStore.token(forHost: server.pairingKey) == secret, desc: "the token is in the token store")
                t.expect(model.directory.lastAuthTokenForTesting == secret, desc: "and the next ask presents it")
                let defaults = String(describing: UserDefaults.standard.dictionaryRepresentation())
                t.expect(!defaults.contains(secret), desc: "no byte of the token reaches the defaults")
                model.removeToken()
                t.expect(HostTokenStore.token(forHost: server.pairingKey) == nil, desc: "Remove deletes it from the store")
            }
        }

        UBUITestRegister("refusal_sheet_names_the_workspace_and_defaults_to_core_remedy") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                defer { t.closeAllWindows() }
                guard let refused = TerminalWindowController.spawn(), let window = refused.window else {
                    t.expect(false, desc: "a window opens")
                    return
                }
                refused.standUpRemoteIdentityForTesting(
                    hostKey: "uitest@refused.invalid",
                    hostLabel: "prod-1",
                    workspaceName: "deploy",
                    shellCommand: "exit 1",
                    deployBinaries: [:]
                )
                let content = refused.refusalSheetContent(reason: .SessionGone, hostBuild: .init(), detail: "The host daemon restarted.")
                t.expect(
                    content.title == "“deploy” Is No Longer Available",
                    desc: "the sheet names the session, not its number (\(content.title))"
                )
                t.expect(!content.titles.contains("Cancel"), desc: "no button is titled Cancel (\(content.titles))")
                t.expect(content.remedies.first == .startNewNamed, desc: "Core's first remedy restarts the named session")
                t.expect(content.titles.first == "Start New “deploy”", desc: "and is titled for it (\(content.titles.first ?? ""))")
                t.expect(content.remedies.last == .closeWindow, desc: "closing the window is offered, last")

                refused.presentRefusalSheet(sessionID: 7, content: content)
                t.expect(t.wait(until: { window.attachedSheet != nil }, timeout: 2), desc: "the refusal is a sheet on the window")
                t.expect(NSApp.modalWindow == nil, desc: "and nothing runs app-modal")

                let before = Set(TerminalWindowController.spawnedControllers.map(ObjectIdentifier.init))
                refused.performRefusalRemedy(.startNewNamed, sessionID: 7)
                t.pump(0.5)
                let replacement = TerminalWindowController.spawnedControllers.first { !before.contains(ObjectIdentifier($0)) }
                t.expect(replacement != nil, desc: "Start New opens a window")
                t.expect(replacement?.remoteHostKey == "uitest@refused.invalid", desc: "on the same host key")
                t.expect(replacement?.remoteWorkspaceName == "deploy", desc: "under the same name")
                t.expect(refused.isWindowClosed || window.isVisible == false, desc: "and the refused window closes")
            }
        }

        UBUITestRegister("older_host_offers_update_and_older_client_does_not") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                defer { t.closeAllWindows() }
                guard let refused = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a window opens")
                    return
                }
                refused.standUpRemoteIdentityForTesting(
                    hostKey: "uitest@older.invalid",
                    hostLabel: "prod-1",
                    workspaceName: "deploy",
                    shellCommand: "exit 1",
                    deployBinaries: ["Linux aarch64": "/nonexistent"]
                )
                // The wire has one version, so no host speaks a lower one: the
                // older host is one that states no build at all.
                let local = SyncWire.localPeerBuild()
                var olderHost = SyncWire.PeerBuild()
                olderHost.isKnown = false
                let newerHost = peerBuild(appVersion: "9.9.9", version: local.wireVersion + 1)
                let host = refused.refusalSheetContent(reason: .VersionMismatch, hostBuild: olderHost, detail: "")
                t.expect(host.remedies.first == .updateHost, desc: "an older host is offered its update first (\(host.titles))")
                t.expect(host.titles.first == "Update prod-1", desc: "titled for the host")
                t.expect(host.title == "prod-1 Runs an Older Ubiquitty Host", desc: "and the sheet says which side is older")
                t.expect(
                    host.sentence.hasPrefix("prod-1’s Ubiquitty Host doesn’t say which build it runs")
                        && host.sentence.contains("Update the host on prod-1."),
                    desc: "and names the host's build and the end to update (\(host.sentence))"
                )
                let client = refused.refusalSheetContent(reason: .VersionMismatch, hostBuild: newerHost, detail: "")
                t.expect(!client.remedies.contains(.updateHost), desc: "an older client is never offered a host update (\(client.titles))")
                t.expect(client.title == "This Mac Runs an Older Ubiquitty", desc: "and the sheet says this Mac is older")
                t.expect(
                    client.sentence.hasPrefix("This Mac is from an older build of Ubiquitty")
                        && client.sentence.contains("than prod-1’s host (9.9.9)")
                        && client.sentence.hasSuffix("Update Ubiquitty on this Mac."),
                    desc: "and names both builds and points at this Mac (\(client.sentence))"
                )

                // The Connect window offers the same before any window exists.
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                defer { closeConnect() }
                let server = invalidServer(named: "Older Box")
                model.setHostsForTesting([server])
                ConnectWindowController.show(place: .host(server.id))
                t.pump(0.3)
                let platform = HostTransport.deployBinaries(forDeploySSHHost: server.host).keys.first ?? ""
                model.directory.setSnapshotForTesting(
                    phase: .failed,
                    failure: HostListingFailure(
                        kind: .refused,
                        deniedReason: .VersionMismatch,
                        remotePlatform: platform,
                        olderSide: .Host,
                        hostBuild: olderHost,
                        detail: ""
                    )
                )
                t.expect(model.contentState == .olderHost, desc: "Connect shows the older-host state (\(model.contentState.name))")
                t.expect(model.remedyFact.remedies.first == .updateHost, desc: "with Update first (\(model.remedyFact.remedies.count))")
                model.directory.setSnapshotForTesting(
                    phase: .failed,
                    failure: HostListingFailure(
                        kind: .refused,
                        deniedReason: .VersionMismatch,
                        remotePlatform: platform,
                        olderSide: .Client,
                        hostBuild: newerHost,
                        detail: ""
                    )
                )
                t.expect(model.contentState == .olderClient, desc: "an older client shows its own state (\(model.contentState.name))")
                t.expect(!model.remedyFact.remedies.contains(.updateHost), desc: "and never offers a host update")
                model.directory.setSnapshotForTesting(
                    phase: .failed,
                    failure: HostListingFailure(
                        kind: .refused,
                        deniedReason: .VersionMismatch,
                        remotePlatform: platform,
                        olderSide: .Unknown,
                        hostBuild: local,
                        detail: "This app and the host are from different builds of Ubiquitty. Update the older one."
                    )
                )
                t.expect(model.remedyFact.remedies.first == .updateHost, desc: "equal version numbers still offer the matching host")
                t.expect(
                    model.remedyFact.versionTitle == "Older Box Runs a Different Build of Ubiquitty",
                    desc: "the headline does not claim either build is newer"
                )
            }
        }
    }

    /// Registers the scenarios for updating a host that refused this client for
    /// its version.
    static func registerHostUpdate() {
        // A host of another build refuses at the handshake, and one built
        // before builds stated themselves refuses with the reason alone, which
        // names neither side older. The window puts the refusal up as a sheet
        // whose first action is the update, and the update runs in a
        // replacement window that installs before it dials: the host's command
        // runs once, for the refusal, and never again.
        UBUITestRegister("version_refusal_offers_the_update_and_it_dials_nothing_first") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                defer { t.closeAllWindows() }
                let marker = NSTemporaryDirectory() + "ubq-update-dials-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: marker) }
                let refuser =
                    "echo dialled >> \(marker); printf '\\nUBIQUITTY-SYNC\\n\(buildRefusalEscapes())'; sleep 5"
                guard
                    let refused = TerminalWindowController.spawnRemoteWindow(
                        shellCommand: refuser,
                        hostLabel: "Studio",
                        quicHost: "",
                        quicBootstrapCommand: "",
                        deploySSHHost: "uitest@build-host.invalid",
                        deployBinaries: ["Darwin arm64": "/nonexistent/ubiquitty-host"],
                        reattachSessionID: 0,
                        workspaceName: "work",
                        hostKey: "uitest@build-host.invalid"
                    ),
                    let window = refused.window
                else {
                    t.expect(false, desc: "a remote window opens")
                    return
                }
                t.expect(t.wait(until: { window.attachedSheet != nil }, timeout: 5), desc: "the version refusal is a sheet")
                let content = refused.lastRefusalSheetContent
                t.expect(content?.remedies.first == .updateHost, desc: "whose first action is the update (\(content?.titles ?? []))")
                t.expect(content?.titles.first == "Update Studio", desc: "titled for the host")
                let dialsBefore = (try? String(contentsOfFile: marker, encoding: .utf8))?.split(separator: "\n").count ?? 0
                t.expect(dialsBefore == 1, desc: "the refused window dialled once (\(dialsBefore))")

                let before = Set(TerminalWindowController.spawnedControllers.map(ObjectIdentifier.init))
                refused.performRefusalRemedy(.updateHost, sessionID: 0)
                t.pump(1.0)
                let replacement = TerminalWindowController.spawnedControllers.first { !before.contains(ObjectIdentifier($0)) }
                t.expect(replacement != nil, desc: "the update opens a replacement window")
                t.expect(replacement?.remoteWorkspaceName == "work", desc: "for the same session name")
                let state = replacement?.remoteSurface?.drive.remoteState
                t.expect(
                    state == .Deploying || state == .Failed,
                    desc: "which is installing, not connecting (\(String(describing: state)))"
                )
                let dialsAfter = (try? String(contentsOfFile: marker, encoding: .utf8))?.split(separator: "\n").count ?? 0
                t.expect(dialsAfter == 1, desc: "and nothing ran on the host the update replaces (\(dialsAfter))")
                t.expect(refused.isClosedForTesting || window.isVisible == false, desc: "and the refused window closes")
            }
        }
    }

    /// The `printf` escapes of the Bye a host of another build answers a Greet
    /// with when it states no build: Core's kind and reason numbers in the
    /// envelope's grammar (Envelope.h), so the refusal is the one the wire
    /// carries today.
    private static func buildRefusalEscapes() -> String {
        let body: [UInt8] = [SyncWire.ByeReason.VersionMismatch.rawValue, 0, 0] // reason, empty detail, no peer
        let frame: [UInt8] = [SyncWire.FrameKind.Bye.rawValue, 0, UInt8(body.count)] + body
        return
            frame.map { byte in
                let octal = String(byte, radix: 8)
                return "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            }
            .joined()
    }

    /// Registers the scenarios for shells, tmux, serial and layouts.
    /// Registers the scenarios for the ways into a host that skip the window:
    /// File ▸ Reattach and Beam.
    static func registerReattach() {
        UBUITestRegister("reattach_runs_cores_plan_without_the_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                HostServers.installPairingPersistence()
                let model = ConnectModel.shared
                closeConnect()
                model.shouldRecordActionsForTesting = true
                model.recordedActionsForTesting = []
                defer { closeConnect() }

                let item = reattachMenuItem()
                t.expect(item != nil, desc: "File has a Reattach item on ⌃⌘K")
                t.expect(item?.target === ConnectReattach.shared, desc: "and it is targeted at its Swift owner")
                let probe = NSMenuItem(title: "", action: #selector(ConnectReattach.reattach(_:)), keyEquivalent: "")
                t.expect(
                    !ConnectReattach.shared.validateMenuItem(probe) && probe.title == "Reattach",
                    desc: "with no host connected before, Reattach is disabled (\(probe.title))"
                )

                // A named session: Core opens it either way, so the window stays shut.
                let named = HostServer(id: UUID(), name: "Named Box", host: "uitest@named-box.invalid", workspaceName: "work")
                model.setHostsForTesting([named])
                UserDefaults.standard.set(named.pairingKey, forKey: "UBConnectLastHost")
                t.expect(ConnectReattach.shared.validateMenuItem(probe), desc: "a remembered host enables Reattach")
                t.expect(
                    probe.title == "Reattach “work” on Named Box",
                    desc: "the title names the session and the host (\(probe.title))"
                )
                ConnectReattach.shared.reattach(nil)
                t.pump(0.2)
                t.expect(
                    model.recordedActionsForTesting == ["primary"],
                    desc: "a named session is Core's connect (\(model.recordedActionsForTesting))"
                )
                t.expect(ConnectWindowController.shared.window?.isVisible != true, desc: "and Connect does not open")

                // A remembered session id: Core attaches attach-only, no window.
                let remembered = invalidServer(named: "Remembered Box")
                HostDirectory.remember(host: remembered.pairingKey, sessionID: 42, workspaceName: "")
                defer { HostDirectory.forget(host: remembered.pairingKey) }
                model.setHostsForTesting([remembered])
                UserDefaults.standard.set(remembered.pairingKey, forKey: "UBConnectLastHost")
                model.recordedActionsForTesting = []
                ConnectReattach.shared.reattach(nil)
                t.pump(0.2)
                t.expect(
                    model.recordedActionsForTesting == ["primary"],
                    desc: "a remembered session is Core's connect (\(model.recordedActionsForTesting))"
                )
                t.expect(ConnectWindowController.shared.window?.isVisible != true, desc: "and Connect stays shut")

                // Nothing to go on: Core waits for the listing, so Connect opens
                // on the host for the person to choose.
                let unknown = invalidServer(named: "Unknown Box")
                model.setHostsForTesting([unknown])
                UserDefaults.standard.set(unknown.pairingKey, forKey: "UBConnectLastHost")
                model.recordedActionsForTesting = []
                ConnectReattach.shared.reattach(nil)
                t.pump(0.2)
                t.expect(model.recordedActionsForTesting.isEmpty, desc: "a plan that needs the listing makes no connect")
                t.expect(ConnectWindowController.shared.window?.isVisible == true, desc: "Connect opens to choose")
                t.expect(model.selection == .host(unknown.id), desc: "on the host Reattach was asked about")
            }
        }

        UBUITestRegister("beam_connect_to_host_runs_core_plan") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                HostServers.installPairingPersistence()
                let model = ConnectModel.shared
                closeConnect()
                model.shouldRecordActionsForTesting = true
                model.recordedActionsForTesting = []
                defer { closeConnect() }

                let named = HostServer(id: UUID(), name: "Beam Box", host: "uitest@beam-box.invalid", workspaceName: "work")
                var shell = invalidServer(named: "Shell Box")
                shell.kind = .ssh
                model.setHostsForTesting([named, shell])
                let commands = TmuxSSHRemoteCommandProvider().commands()
                let row = commands.first { $0.title == "Connect to Beam Box" }
                t.expect(row != nil, desc: "a saved host has its own Connect row (\(commands.map(\.title)))")
                t.expect(
                    row?.secondaryActions.map(\.label)
                        == ["New Workspace on Beam Box", "Choose Workspace on Beam Box…", "Manage Beam Box…", "Edit Beam Box…"],
                    desc: "with the other ways in as secondary actions (\(row?.secondaryActions.map(\.label) ?? []))"
                )
                t.expect(
                    commands.first { $0.title == "Connect to Shell Box" }?.secondaryActions.map(\.label) == ["Edit Shell Box…"],
                    desc: "a saved shell host is listed, with only Edit beside it"
                )
                t.expect(commands.contains { $0.title == "Open Serial Port…" }, desc: "Open Serial Port… is a Beam command")
                t.expect(!commands.contains { $0.title == "Connect…" }, desc: "Connect… is left to the menu provider, listed once")

                if case .run(let run) = row?.action {
                    run()
                }
                t.pump(0.2)
                t.expect(
                    model.recordedActionsForTesting == ["primary"],
                    desc: "the row runs Core's plan (\(model.recordedActionsForTesting))"
                )
                t.expect(ConnectWindowController.shared.window?.isVisible != true, desc: "without opening Connect")
            }
        }
    }

    /// The File menu's Reattach item, found by its key equivalent.
    @MainActor
    private static func reattachMenuItem() -> NSMenuItem? {
        guard let main = NSApp.mainMenu else { return nil }
        for top in main.items {
            for item in top.submenu?.items ?? []
            where item.keyEquivalent == "k" && item.keyEquivalentModifierMask == [.command, .control] {
                return item
            }
        }
        return nil
    }

    static func registerShells() {
        UBUITestRegister("connect_ssh_and_tmux_failures_are_inline") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                let resolve = ConnectLauncher.resolveTool
                defer {
                    ConnectLauncher.resolveTool = resolve
                    closeConnect()
                }
                let windowsBefore = TerminalWindowController.spawnedControllers.count

                // A saved ssh host whose address ssh would misread: Core's
                // reason, inline, and no window.
                let broken = HostServer(id: UUID(), name: "Broken Shell", host: "-oProxyCommand=evil", kind: .ssh, workspaceName: "")
                model.setHostsForTesting([broken])
                ConnectWindowController.show(place: .host(broken.id))
                t.pump(0.3)
                model.openShell(broken)
                t.expect(
                    model.launchFailure?.stateName == "invalid-address",
                    desc: "an invalid ssh host is an inline state (\(model.launchFailure?.stateName ?? "none"))"
                )
                t.expect(
                    model.launchFailure?.sentence.contains("option") == true,
                    desc: "with Core's reason (\(model.launchFailure?.sentence ?? ""))"
                )

                // No tmux on the machine: the searched directories, inline.
                ConnectLauncher.resolveTool = { _ in nil }
                ConnectWindowController.show(place: .thisMacTmux)
                t.pump(0.2)
                model.openTmux(session: "work")
                t.expect(
                    model.launchFailure?.stateName == "tmux-missing",
                    desc: "a missing tmux is an inline state (\(model.launchFailure?.stateName ?? "none"))"
                )
                t.expect(model.launchFailure?.title == "tmux Isn’t Installed", desc: "titled for it")
                t.expect(model.launchFailure?.sentence.contains("/opt/homebrew/bin") == true, desc: "naming where Ubiquitty looked")

                // A serial device that is not there.
                ConnectWindowController.show(place: .serialPorts)
                model.openSerial(device: "/dev/cu.uitest-absent", baudRate: 115200)
                t.expect(model.launchFailure?.title == "Couldn’t Open /dev/cu.uitest-absent", desc: "an absent device is an inline state")

                t.expect(TerminalWindowController.spawnedControllers.count == windowsBefore, desc: "nothing spawned")
                t.expect(NSApp.modalWindow == nil, desc: "and no alert appeared")
            }
        }

        UBUITestRegister("connect_saved_hosts_carry_their_kind") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let tmux = HostServer(
                    id: UUID(),
                    name: "Builds",
                    host: "user@builds.invalid",
                    kind: .remoteTmux,
                    workspaceName: "",
                    tmuxSession: "ci"
                )
                let serial = HostServer(
                    id: UUID(),
                    name: "Console",
                    host: "",
                    kind: .serial,
                    workspaceName: "",
                    device: "/dev/cu.usbserial-1",
                    baudRate: 9600
                )
                let ssh = HostServer(
                    id: UUID(),
                    name: "Box",
                    host: "user@box.invalid",
                    kind: .ssh,
                    workspaceName: "",
                    shouldForwardAgent: true,
                    localePolicy: 2
                )
                HostServers.save([tmux, serial, ssh])
                let read = HostServers.all()
                t.expect(read == [tmux, serial, ssh], desc: "every kind and its fields read back (\(read.map(\.kind)))")

                // Changing the kind clears what the new kind does not use, so a
                // device or a daemon pairing key never survives it.
                let changed = HostServer(id: UUID(), name: "Local", host: "local", workspaceName: "ci").changingKind(to: .ssh)
                t.expect(
                    changed.host.isEmpty && changed.workspaceName.isEmpty,
                    desc: "a daemon host turned shell keeps no local key or session name"
                )
                let fromSerial = serial.changingKind(to: .ssh)
                t.expect(fromSerial.device.isEmpty, desc: "a serial host turned shell keeps no device (\(fromSerial.device))")
                let fromTmux = tmux.changingKind(to: .ssh)
                t.expect(fromTmux.tmuxSession.isEmpty, desc: "a tmux host turned shell keeps no tmux session (\(fromTmux.tmuxSession))")
                let model = ConnectModel.shared
                defer { closeConnect() }
                model.setHostsForTesting([tmux])
                ConnectWindowController.show(place: .host(tmux.id))
                t.expect(
                    model.shellTitle(for: tmux) == "Attach “ci”",
                    desc: "a tmux host's default names its session (\(model.shellTitle(for: tmux)))"
                )
                t.expect(model.directory.server == nil, desc: "a shell host asks no daemon for sessions")
            }
        }

        // A host added from the Add Host draft is named by its address until
        // the person names it: the draft starts with no name, and a row reads
        // as its host, so two new rows are told apart by what they dial
        // rather than by an invented "Untitled" counter.
        UBUITestRegister("connect_added_host_reads_as_its_address_until_named") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = takeDefaults()
                defer { putBackDefaults(restore) }
                clearDefaults()
                let model = ConnectModel.shared
                defer { closeConnect() }
                model.setHostsForTesting([])
                let first = HostServers.blankRemote(host: "uitest@first.invalid")
                let second = HostServers.blankRemote(host: "uitest@second.invalid")
                t.expect(first.name.isEmpty && second.name.isEmpty, desc: "a draft starts with no name")
                model.addHost(first)
                model.addHost(second)
                let names = model.hosts.map(\.displayName)
                t.expect(
                    names == ["uitest@first.invalid", "uitest@second.invalid"],
                    desc: "each new row reads as the host it dials (\(names))"
                )
            }
        }

        UBUITestRegister("layouts_save_without_windows_explains") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                let model = ConnectModel.shared
                defer { closeConnect() }
                ConnectWindowController.show(place: .layouts)
                t.pump(0.2)
                t.expect(!model.hasWindowsToSave, desc: "with no windows there is nothing to save")
                t.expect(model.layoutFooter == "Open a window to save a layout.", desc: "and the footer says so (\(model.layoutFooter))")
                t.expect(!model.saveLayout(named: "Empty"), desc: "and saving does nothing")
            }
        }
    }

    // MARK: - Helpers

    /// This Mac on a daemon of the scenario's own that holds nothing: the
    /// footer offers one New Workspace, the default button, and leaves the
    /// sentence to the empty state that already says it.
    ///
    /// A private `UBIQUITTY_HOME` keeps the ask off whatever daemon the person
    /// running the suite has, and is what makes the listing really empty.
    @MainActor
    private static func verifyEmptyThisMac(_ t: UBUITestContext) {
        let restore = takeDefaults()
        defer { putBackDefaults(restore) }
        clearDefaults()
        guard let binary = ShareSessionSupport.localHostBinaryPath() else {
            t.expect(false, desc: "the built app contains its host helper")
            return
        }
        let home = "/tmp/ubq-connect-empty-" + String(UUID().uuidString.prefix(8))
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
            closeConnect()
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

        let model = ConnectModel.shared
        ConnectWindowController.show(place: .thisMacHost)
        guard let window = ConnectWindowController.shared.window else {
            t.expect(false, desc: "the Connect window exists")
            return
        }
        guard t.wait(until: { model.contentState == .empty }, timeout: 15) else {
            t.expect(false, desc: "This Mac answers with no sessions (\(model.contentState.name))")
            return
        }
        t.expect(model.directory.plannedConnectForTesting()?.plan == .createNew, desc: "Core's plan is the new session")
        t.expect(!model.directory.isNewSessionOffered, desc: "and Core offers no second New Workspace beside it")

        let sentence = model.directory.primaryAction.sentence
        t.expect(
            sentence == "A workspace started here keeps running after you close its window.",
            desc: "the empty state says what a session here does (\(sentence))"
        )
        // The footer is one value the window draws, so the count read here is
        // the count drawn: the default button, plus New Workspace only when
        // Core offers it as a different action.
        let footer = model.footer
        let newSessionButtons = [footer.isNewSessionOffered, model.directory.primaryAction.title == "New Workspace"].filter { $0 }.count
        t.expect(newSessionButtons == 1, desc: "one New Workspace button (\(newSessionButtons))")
        t.expect(footer.sentence == nil, desc: "the footer leaves the sentence to the empty state (\(footer.sentence ?? "none"))")
        t.expect(window.isVisible, desc: "the window drawing it is on screen")
    }

    /// A saved host at an address that resolves nowhere, so an ask fails fast
    /// and nothing is ever reached.
    @MainActor
    private static func invalidServer(named name: String) -> HostServer {
        HostServer(
            id: UUID(),
            name: name,
            host: "uitest@\(name.lowercased().replacingOccurrences(of: " ", with: "-")).invalid",
            workspaceName: ""
        )
    }

    /// A key-down event for a window's key-equivalent pass.
    @MainActor
    private static func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: characters == "\r" ? 36 : 0
        )!
    }

    @MainActor
    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Closes the Connect window and returns its model to rest.
    @MainActor
    private static func closeConnect() {
        ConnectWindowController.shared.window?.close()
        ConnectModel.shared.shouldRecordActionsForTesting = false
        ConnectModel.shared.searchText = ""
        ConnectModel.shared.isInspectorPresented = false
        ConnectModel.shared.isNamingSession = false
        ConnectModel.shared.addHostDraft = nil
        ConnectModel.shared.launchFailure = nil
    }

    private static func takeDefaults() -> [String: Any] {
        var taken: [String: Any] = [:]
        for key in touchedDefaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                taken[key] = value
            }
        }
        return taken
    }

    private static func putBackDefaults(_ values: [String: Any]) {
        for key in touchedDefaultsKeys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private static func clearDefaults() {
        for key in touchedDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// A build as a refusing host states it.
///
/// - Parameters:
///   - appVersion: The host's app version.
///   - version: The protocol version it speaks.
/// - Returns: The build.
private func peerBuild(appVersion: String, version: UInt16) -> Ubiquitty.`Protocol`.Sync.PeerBuild {
    var build = SyncWire.PeerBuild()
    build.isKnown = true
    build.wireVersion = version
    build.appVersion = std.string(appVersion)
    return build
}
