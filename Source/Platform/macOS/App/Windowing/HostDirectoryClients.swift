// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// HostDirectoryClients.swift — one control-only directory client per host
// endpoint, shared by every window that asks a host about itself.
//
// Connect and Manage both ask the same host what it holds. Two clients would
// be two channels dialled at once and two answers that disagree for a moment;
// Core's client already queues a terminate or a management request behind a
// listing and coalesces asks, so one client per endpoint serves both, and each
// window hears every change and reads the event it cares about.
//
// The endpoint is also where a window reads the host's outline. The rows, the
// connect made on them, the question that connect asks and every change asked
// of the host's structure are Core's; what is here hands a Swift value across
// and decides nothing.
//

import Foundation
import UbiquittyAppleCallbacks
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

/// The directory client for one host endpoint, and the windows listening to it.
@MainActor
final class HostDirectoryEndpoint {
    /// The shell command the client dials; the endpoint's identity.
    let shellCommand: String

    /// Core's client. Main-thread only, like every caller of it.
    private var client: Ubiquitty.Runtime.HostDirectoryClient

    /// A window listening for changes, held weakly so a closed window stops
    /// hearing them without unsubscribing.
    private struct Listener {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    private var listeners: [Listener] = []

    /// The windows that want the host followed, held weakly. The watch runs
    /// while any of them is alive and has not let go.
    private final class Watcher {
        weak var owner: AnyObject?
        init(_ owner: AnyObject) { self.owner = owner }
    }

    private var watchers: [Watcher] = []

    /// Dials nothing yet: the client opens a channel per errand.
    ///
    /// - Parameter shellCommand: The transport command.
    init(shellCommand: String) {
        self.shellCommand = shellCommand
        client = Ubiquitty.Runtime.HostDirectoryClient(std.string(shellCommand), Ubiquitty.Apple.mainQueueLoop())
        client.setChangeCallback(
            Ubiquitty.Apple.ownedCallback { [weak self] in
                // Core delivers changes through the owning main-loop dispatcher.
                MainActor.assumeIsolated { self?.notify() }
            }
        )
    }

    /// Adds a listener for as long as its owner lives.
    ///
    /// - Parameters:
    ///   - owner: The object whose lifetime bounds the subscription.
    ///   - handler: Run on every change.
    func subscribe(_ owner: AnyObject, handler: @escaping @MainActor () -> Void) {
        // One subscription per owner: a window pointed back at a host it was
        // already listening to would otherwise hear every change twice.
        listeners.removeAll { $0.owner == nil || $0.owner === owner }
        listeners.append(Listener(owner: owner, handler: handler))
    }

    /// Core's latest answer.
    var snapshot: Ubiquitty.Runtime.HostDirectoryClient.Snapshot { client.snapshot() }

    /// Whether an errand is out or queued.
    var isBusy: Bool { client.isBusy() }

    var hostInstances: [HostDaemonInstance] { HostDaemonInstance.read(client.hostInstances()) }

    /// Core's state and words for this host's section.
    func sectionWords(
        hostName: String,
        isLocal: Bool,
        transportRefusal: Ubiquitty.Runtime.HostTransportRefusal
    ) -> Ubiquitty.Runtime.HostSectionWords {
        client.sectionWords(std.string(hostName), isLocal ? .thisMachine : .remote, transportRefusal)
    }

    /// Asks the host for its listing; joins one already queued.
    func refresh() {
        _ = client.refresh()
    }

    // MARK: - Ending sessions

    /// The question Core asks before a request that ends sessions, worded
    /// from the tree the client holds, with the token the request is sent
    /// with.
    ///
    /// - Parameters:
    ///   - request: What would be asked of the host.
    ///   - target: A window to close; a session, its pane or a workspace to
    ///     terminate.
    ///   - hostName: What the host is called in the question.
    /// - Returns: The question; its token is zero and `whyNot` says why when
    ///   there is nothing to ask.
    func confirmation(for request: HostDestructiveRequest, target: HostOutlineIdentity, hostName: String) -> HostDestructiveQuestion {
        guard let id = Self.objectID(target) else {
            return HostDestructiveQuestion(
                token: 0,
                request: request,
                target: target,
                title: "",
                body: "",
                buttons: [],
                sessionIDs: [],
                whyNot: ""
            )
        }
        let question = client.confirmationFor(request.core, id, std.string(hostName))
        return HostDestructiveQuestion(
            token: question.token,
            request: request,
            target: target,
            title: String(question.title),
            body: String(question.body),
            // Core's two buttons with their roles: the safe default first,
            // then the one that goes through.
            buttons: [
                HostDestructiveQuestion.Button(title: String(question.safeButton), isDestructive: false),
                HostDestructiveQuestion.Button(title: String(question.destructiveButton), isDestructive: true),
            ],
            sessionIDs: question.sessionIDs.map { $0 },
            whyNot: String(question.whyNot)
        )
    }

    /// Closes a window and ends the sessions in its panes, with the token of
    /// the question that was answered.
    ///
    /// - Parameter question: The answered question, for closing a window.
    /// - Returns: The request's number, 0 when the target names nothing.
    func closeWindow(confirmedBy question: HostDestructiveQuestion) -> UInt64 {
        guard question.request == .closeWindow, let window = Self.objectID(question.target) else { return 0 }
        return client.closeWindow(window, question.token)
    }

    /// Terminates a session, or every session of a workspace, with the token
    /// of the question that was answered. Each session is one terminate
    /// through the host's own consent gate, and each settles on its own.
    ///
    /// - Parameter question: The answered question, for a terminate.
    /// - Returns: How many sessions the host was asked to end, and Core's
    ///   sentence for why none was.
    func terminate(confirmedBy question: HostDestructiveQuestion) -> (sessionCount: Int, whyNot: String) {
        guard question.request != .closeWindow, let target = Self.objectID(question.target) else { return (0, "") }
        let admission = client.terminate(question.request.core, target, question.token)
        return (Int(admission.sessionCount), String(admission.whyNot))
    }

    /// Sends an administration request, queued behind any errand that is out.
    ///
    /// - Parameter request: The request.
    /// - Returns: False for a mutation that names no daemon.
    func manage(_ request: Ubiquitty.`Protocol`.Sync.ManagementRequest) -> Bool {
        client.manage(request)
    }

    /// Sets the token every later errand presents.
    ///
    /// - Parameter token: The token, empty for none.
    func setAuthToken(_ token: String) {
        client.setAuthToken(std.string(token))
    }

    // MARK: - Following the host

    /// Follows the host for as long as an owner wants it followed, or lets
    /// go of it.
    ///
    /// One watch serves every window on the host: it starts with the first
    /// owner and stops when the last has let go or gone.
    ///
    /// - Parameters:
    ///   - isWatching: Whether the owner wants the host followed.
    ///   - owner: The window asking.
    func setWatching(_ isWatching: Bool, for owner: AnyObject) {
        watchers.removeAll { $0.owner == nil || $0.owner === owner }
        if isWatching {
            watchers.append(Watcher(owner))
            _ = client.watch()
        } else if watchers.isEmpty {
            client.stopWatching()
        }
    }

    // MARK: - Connecting

    /// The connect Core's rule makes to this host, on the tree the client
    /// holds, with the question that connect asks kept for
    /// ``attachQuestion``.
    ///
    /// - Parameters:
    ///   - hostKey: The pairing key the remembered session is recalled by.
    ///   - predefinedWorkspaceName: The name the saved host carries, empty
    ///     for none.
    ///   - chosenSessionID: The session the person picked, 0 for none.
    ///   - reader: The reader whose titles name the workspaces a question is
    ///     about.
    /// - Returns: The connect to make.
    func decideAttach(
        hostKey: String,
        predefinedWorkspaceName: String,
        chosenSessionID: UInt32,
        reader: HostOutlineReader
    ) -> HostConnectDecision {
        HostConnectDecision(
            client.decideAttach(std.string(hostKey), std.string(predefinedWorkspaceName), chosenSessionID, reader.request)
        )
    }

    /// What the last ``decideAttach(hostKey:predefinedWorkspaceName:chosenSessionID:reader:)``
    /// asks the person, in Core's words; nil when it asked nothing.
    var attachQuestion: HostAttachQuestion? {
        let question = client.snapshot().attachQuestion
        guard question.ask != .none else { return nil }
        return HostAttachQuestion(
            text: String(question.text),
            shortText: String(question.shortText),
            candidates: question.candidates.map { candidate in
                HostAttachQuestion.Candidate(
                    workspaceID: candidate.workspaceID,
                    open: HostOutlineOpen(candidate.open),
                    title: String(candidate.title),
                    state: HostOutlineWorkspaceState(rawValue: candidate.state.rawValue) ?? .live
                )
            },
            isNewSessionOffered: question.isNewSessionOffered
        )
    }

    /// Reads the facts Core uses to word a connect and mark its row.
    func connectActionFacts(
        hostName: String,
        decision: HostConnectDecision,
        reader: HostOutlineReader,
        selected: HostOutlineRow?
    ) -> Ubiquitty.Runtime.ConnectActionFacts {
        var facts = client.connectActionFacts(
            std.string(hostName),
            decision.core,
            reader.request,
            selected?.id?.kind.rawValue ?? 0,
            selected?.id?.number ?? 0,
            selected?.recordedKey?.workspaceID ?? 0,
            selected?.recordedKey?.level.rawValue ?? 0,
            UInt32(clamping: selected?.recordedKey?.window ?? 0),
            UInt32(clamping: selected?.recordedKey?.tab ?? 0)
        )
        facts.questionText = client.snapshot().attachQuestion.shortText
        return facts
    }

    // MARK: - Changing the host's structure

    /// Core's process and lifetime details under the selected outline row.
    func sessionDetails(for row: HostOutlineRow) -> [Ubiquitty.Runtime.HostSessionDetails] {
        guard let id = row.id else { return [] }
        return Array(client.sessionDetails(id.kind.rawValue, id.number))
    }

    /// How a change asked of the host's structure ended
    /// (`Runtime::StructureResult`).
    struct StructureResult: Equatable {
        /// The number the request was given when it was asked.
        let requestID: UInt64
        /// Whether the host made the change.
        let isServed: Bool
        /// Why it was not made, in the host's words or Core's; empty when
        /// served.
        let reason: String
    }

    /// How the change that settled last ended; nil before any has.
    var structureResult: StructureResult? {
        let result = client.snapshot().structureResult
        guard result.requestID != 0 else { return nil }
        return StructureResult(requestID: result.requestID, isServed: result.outcome == .Served, reason: String(result.reason))
    }

    /// Gives a workspace its name, or takes it away with an empty one.
    ///
    /// - Parameters:
    ///   - workspace: The workspace's identity.
    ///   - name: The name.
    /// - Returns: The request's number, 0 when the identity names nothing.
    func renameWorkspace(_ workspace: HostOutlineIdentity, to name: String) -> UInt64 {
        guard let target = Self.objectID(workspace) else { return 0 }
        return client.renameWorkspace(target, std.string(name))
    }

    /// Gives a tab its name, or takes it away with an empty one.
    ///
    /// - Parameters:
    ///   - tab: The tab's identity.
    ///   - name: The name.
    /// - Returns: The request's number, 0 when the identity names nothing.
    func renameTab(_ tab: HostOutlineIdentity, to name: String) -> UInt64 {
        guard let target = Self.objectID(tab) else { return 0 }
        return client.renameTab(target, std.string(name))
    }

    /// Sets or clears the label of a workspace, a window, a tab, a pane or
    /// a session.
    ///
    /// - Parameters:
    ///   - label: The label; empty clears it.
    ///   - target: What is labelled.
    /// - Returns: The request's number, 0 when the identity names nothing.
    func setLabel(_ label: String, on target: HostOutlineIdentity) -> UInt64 {
        guard let id = Self.objectID(target) else { return 0 }
        return client.setLabel(id, std.string(label))
    }

    /// Replaces the tags of a workspace, a window, a tab, a pane or a
    /// session; none clears them.
    ///
    /// - Parameters:
    ///   - tags: The tags, in the order they are drawn.
    ///   - target: What is tagged.
    /// - Returns: The request's number, 0 when the identity names nothing.
    func setTags(_ tags: [String], on target: HostOutlineIdentity) -> UInt64 {
        guard let id = Self.objectID(target) else { return 0 }
        var names = Ubiquitty.Runtime.StructureTags()
        for tag in tags {
            names.append(std.string(tag))
        }
        return client.setTags(id, names)
    }

    /// Puts a tab at a place among the tabs of a window of its workspace.
    ///
    /// - Parameters:
    ///   - tab: The tab's identity.
    ///   - window: The window it is to stand in.
    ///   - index: The place it takes there, from zero.
    /// - Returns: The request's number, 0 when an identity names nothing.
    func moveTab(_ tab: HostOutlineIdentity, toWindow window: HostOutlineIdentity, at index: UInt32) -> UInt64 {
        guard let target = Self.objectID(tab), let destination = Self.objectID(window) else { return 0 }
        return client.moveTab(target, destination, index)
    }

    /// The identity Core addresses a row by.
    ///
    /// - Parameter identity: The row's identity as the outline handed it out.
    /// - Returns: Core's identity, nil for one that names nothing.
    private static func objectID(_ identity: HostOutlineIdentity) -> Ubiquitty.Session.Identity.ObjectID? {
        let made = Ubiquitty.Runtime.HostOutlineRequest.rowIdentity(identity.kind.rawValue, identity.number)
        return made.hasValue ? made.value : nil
    }

    #if UBIQUITTY_UI_TESTS
    /// Stands the showcase host up in this endpoint's client as though the
    /// host had answered, without dialling anything.
    ///
    /// - Parameter state: How the tree is held: as a listing answered it,
    ///   followed by a watch, or left behind by a watch that lost its host.
    func holdShowcaseHostForTesting(_ state: UBShowcaseHostState) {
        // The doors report as the errands do, from inside the call, while
        // this holds the client exclusively; the listeners are told once it
        // has let go.
        isHoldingForTesting = true
        withUnsafeMutablePointer(to: &client) { UBUITestHoldShowcaseHost($0, state) }
        isHoldingForTesting = false
        notify()
    }

    private var isHoldingForTesting = false
    #endif

    private func notify() {
        #if UBIQUITTY_UI_TESTS
        if isHoldingForTesting { return }
        #endif
        listeners.removeAll { $0.owner == nil }
        for listener in listeners {
            listener.handler()
        }
    }
}

/// The endpoints alive in this process, one per shell command.
@MainActor
final class HostDirectoryClients {
    /// The process's registry.
    static let shared = HostDirectoryClients()

    private final class WeakEndpoint {
        weak var endpoint: HostDirectoryEndpoint?
        init(_ endpoint: HostDirectoryEndpoint) { self.endpoint = endpoint }
    }

    private var endpoints: [String: WeakEndpoint] = [:]

    /// The endpoint for a transport, created when no window holds one.
    ///
    /// Held weakly here and strongly by the windows using it, so the client
    /// goes when the last window asking about the host does.
    ///
    /// - Parameter shellCommand: The transport command.
    /// - Returns: The shared endpoint.
    func endpoint(for shellCommand: String) -> HostDirectoryEndpoint {
        if let existing = endpoints[shellCommand]?.endpoint {
            return existing
        }
        endpoints = endpoints.filter { $0.value.endpoint != nil }
        let created = HostDirectoryEndpoint(shellCommand: shellCommand)
        endpoints[shellCommand] = WeakEndpoint(created)
        return created
    }
}

extension HostDirectoryEndpoint: HostOutlineSource {
    func outline(for reader: HostOutlineReader) -> HostOutline {
        HostOutline(client.outlineRows(reader.request))
    }

    var freshness: HostOutlineFreshness {
        HostOutlineFreshness(rawValue: client.snapshot().treeFreshness.rawValue) ?? .none
    }

    var watchError: String {
        String(client.snapshot().watchError)
    }
}

/// The connect Core's rule makes to a host, as the windows read it.
///
/// Core's `Session::AttachDecision` with its plan under this app's own name
/// for it, so a decision made on the client's tree and one made before any
/// client exists are one type.
struct HostConnectDecision: Equatable {
    /// What to do.
    let plan: HostAttachPlan
    /// The session the plan lands on: the one to re-home to for the by-id
    /// plan, the one bearing the name for the attach-named plan; 0 otherwise.
    let sessionID: UInt32
    /// The workspace the plan lands in, as the host's tree numbers it; 0 for
    /// a plan that lands in none and for one decided before the host
    /// answered.
    let workspaceID: UInt32
    /// The name to attach under or create under, for the named plans.
    let workspaceName: String
    /// The remembered session the host answered without, 0 for none.
    let vanishedSessionID: UInt32
    /// Whether a new unnamed session is a second action beside the plan.
    let isNewSessionOffered: Bool

    /// The session id an attach door is handed: the by-id plan's target, 0
    /// for every other plan.
    var reattachSessionID: UInt32 { plan == .attachByID ? sessionID : 0 }

    /// The decision's values handed back to Core without making another choice.
    var core: Ubiquitty.Session.AttachDecision {
        var decision = Ubiquitty.Session.AttachDecision()
        decision.plan =
            switch plan {
            case .attachByID: .attachByID
            case .createNamed: .createNamed
            case .attachNamed: .attachNamed
            case .chooseFromList: .chooseFromList
            case .createNew: .createNew
            case .awaitListing: .awaitListing
            }
        decision.sessionID = sessionID
        decision.workspaceID = workspaceID
        decision.workspaceName = std.string(workspaceName)
        decision.vanishedSessionID = vanishedSessionID
        decision.isNewSessionOffered = isNewSessionOffered
        return decision
    }

    /// Reads a decision Core made on a tree.
    init(_ decision: Ubiquitty.Session.AttachDecision) {
        plan = HostAttachPlan(rawValue: decision.plan.rawValue) ?? .chooseFromList
        sessionID = decision.sessionID
        workspaceID = decision.workspaceID
        workspaceName = String(decision.workspaceName)
        vanishedSessionID = decision.vanishedSessionID
        isNewSessionOffered = decision.isNewSessionOffered
    }

    /// Reads a decision Core made before any host answered.
    init(_ decision: HostAttachDecision) {
        plan = decision.plan
        sessionID = decision.sessionID
        workspaceID = 0
        workspaceName = decision.workspaceName
        vanishedSessionID = decision.vanishedSessionID
        isNewSessionOffered = decision.isNewSessionOffered
    }
}

/// A request that ends sessions, as Core's `Runtime::DestructiveRequest`
/// names them.
enum HostDestructiveRequest: Equatable {
    /// Close a window and end the sessions in its panes.
    case closeWindow
    /// End one session: the target is the session, or the pane it draws into.
    case terminateSession
    /// End every session of a workspace, and so the workspace.
    case terminateWorkspace

    /// Core's value.
    var core: Ubiquitty.Runtime.DestructiveRequest {
        switch self {
        case .closeWindow: .closeWindow
        case .terminateSession: .terminateSession
        case .terminateWorkspace: .terminateWorkspace
        }
    }
}

/// The question Core asks before a request that ends sessions
/// (`Runtime::DestructiveConfirmation`): every word of it Core's.
struct HostDestructiveQuestion: Equatable, Identifiable {
    /// What the request is sent with; zero when there is nothing to ask.
    let token: UInt64
    let request: HostDestructiveRequest
    let target: HostOutlineIdentity
    /// The question.
    let title: String
    /// What ends: how many sessions, what runs in them, who is attached.
    let body: String
    /// One button of the question, with the role Core gives it.
    struct Button: Equatable {
        let title: String
        /// Whether it goes through with the request; the other is the safe
        /// default.
        let isDestructive: Bool
    }

    /// The buttons in the order they are added: the safe default first.
    let buttons: [Button]
    /// The sessions that end, in the tree's order.
    let sessionIDs: [UInt32]
    /// Why there is nothing to ask, as a sentence; empty when there is.
    let whyNot: String

    var id: UInt64 { token }
}
