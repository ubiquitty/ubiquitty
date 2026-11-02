// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ControlHost.swift — the Swift shell's half of the control socket.
//
// Core's server (Core/Protocol/Control/Server.h) owns the socket, the token,
// the agent policy and the audit; it hands each verb it has screened to this
// host as JSON text through a C function pointer, on one of its socket
// threads. Everything here runs on the main thread, where the windows live,
// and answers with JSON text: `{"result": ...}` or `{"error": "..."}`.
//
// Ids are the ones `ls` reports: a window is its AppKit `windowNumber`, a pane
// the id its window numbers it with (the local layout's pane id, or the id the
// tmux or remote session gives it).

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

private typealias ControlProtocol = Ubiquitty.`Protocol`.Control

/// Serves the control socket's verbs over the Swift shell's windows.
@objc(UBControlHost)
public final class ControlHost: NSObject {
    /// The listening server, while there is one.
    @MainActor
    private static var server: ControlProtocol.Server?

    /// Starts the control socket when `[control] enable` asks for it.
    ///
    /// Idempotent: a running server is kept.
    @objc
    @MainActor
    public static func startIfEnabled() {
        guard server == nil else { return }
        server = ControlProtocol.Server.startIfEnabled(Ubiquitty.Preferences.values().pointee, operations)
        announceSocketToPanes()
    }

    /// Tells every pane launched from now on which socket serves it, so a
    /// tool run inside one can address `here` (Core/Session/LaunchContext.h).
    @MainActor
    private static func announceSocketToPanes() {
        let path = server.map { String($0.socketPath()) } ?? ""
        TerminalWindowController.windowModel?.setContextSocketPath(std.string(path))
    }

    /// Starts a server on an explicit path, whatever the preferences say.
    ///
    /// - Parameters:
    ///   - socketPath: Where to bind.
    ///   - approval: What a `confirm` verdict from the agent policy becomes.
    /// - Returns: Whether the socket is listening.
    @MainActor
    package static func start(socketPath: String, approval: Ubiquitty.Security.ApprovalMode) -> Bool {
        stop()
        var configuration = ControlProtocol.Configuration()
        configuration.socketPath = std.string(socketPath)
        configuration.approval = approval
        server = ControlProtocol.Server.start(configuration, operations)
        announceSocketToPanes()
        return server != nil
    }

    /// Stops the server, if one is running.
    ///
    /// The last release joins the socket's threads, and one of them may be
    /// waiting on the main thread for a verb, so the release happens off it.
    @MainActor
    package static func stop() {
        guard let retiring = server else { return }
        server = nil
        announceSocketToPanes()
        let parcel = RetiringServer(server: retiring)
        DispatchQueue.global(qos: .utility)
            .async {
                parcel.release()
            }
    }

    /// The C-ABI table Core calls through.
    private static var operations: ControlProtocol.HostOperations {
        var operations = ControlProtocol.HostOperations()
        operations.perform = { _, verb, verbLength, parameters, parametersLength, reply, replyContext in
            let verbName = verb.map { String(decoding: Data(bytes: $0, count: verbLength), as: UTF8.self) } ?? ""
            let parametersData = parameters.map { Data(bytes: $0, count: parametersLength) } ?? Data()
            let answer = ControlHost.onMainThread { ControlHost.perform(verb: verbName, parameters: parametersData) }
            answer.withUnsafeBytes { raw in
                reply?(replyContext, raw.bindMemory(to: CChar.self).baseAddress, raw.count)
            }
        }
        return operations
    }

    /// Runs `body` on the main thread and returns its result.
    ///
    /// The server's threads block here; a caller already on the main thread
    /// runs inline rather than waiting on itself.
    private static func onMainThread(_ body: @MainActor @Sendable () -> Data) -> Data {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    // MARK: - Verbs

    /// Performs one verb and serializes its reply.
    ///
    /// - Parameters:
    ///   - verb: The host verb Core named.
    ///   - parameters: Its parameters, as a JSON object.
    /// - Returns: `{"result": ...}` or `{"error": "..."}`, as JSON.
    @MainActor
    static func perform(verb: String, parameters: Data) -> Data {
        let request = (try? JSONSerialization.jsonObject(with: parameters)) as? [String: Any] ?? [:]
        let reply: [String: Any]
        switch answer(verb: verb, request: request) {
        case .success(let result):
            reply = ["result": result]
        case .failure(let failure):
            reply = ["error": failure.message]
        }
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"error":"unserializable reply"}"#.utf8)
    }

    /// A verb's refusal, in the words the response carries.
    struct Failure: Error {
        let message: String
    }

    @MainActor
    private static func answer(verb: String, request: [String: Any]) -> Result<Any, Failure> {
        let windowNumber = integer(request["window"])
        let paneID = integer(request["pane"])
        switch verb {
        case "ls":
            return .success(["windows": controllers().compactMap(windowDescription)])
        case "target":
            if windowNumber == 0, paneID != 0 {
                // A pane alone, as a tool inside one names `here`: the window
                // is whichever holds it, and a pane two windows number alike
                // is refused rather than guessed.
                let holders = controllers().filter { $0.panesByIdentifier()[paneID] != nil }
                guard holders.count == 1, let window = holders[0].window, let surface = holders[0].panesByIdentifier()[paneID] else {
                    let numbers = holders.compactMap { $0.window.map { String($0.windowNumber) } }.joined(separator: " and ")
                    return .failure(
                        Failure(message: holders.isEmpty ? "no pane \(paneID)" : "pane \(paneID) is in windows \(numbers); name the window")
                    )
                }
                return .success(["window": window.windowNumber, "pane": paneID, "sessionID": Int(surface.remoteSessionID)])
            }
            guard let controller = targetController(windowNumber) else {
                return .failure(Failure(message: windowNumber == 0 ? "no window" : "no such window"))
            }
            guard let window = controller.window, let (pane, surface) = resolvePane(paneID, in: controller) else {
                return .failure(Failure(message: "no session for that target"))
            }
            return .success(["window": window.windowNumber, "pane": pane, "sessionID": Int(surface.remoteSessionID)])
        case "focus":
            return focus(windowNumber: windowNumber, paneID: paneID)
        case "send-text":
            guard let surface = surface(windowNumber: windowNumber, paneID: paneID) else {
                return .failure(Failure(message: "no session for that target"))
            }
            let text = request["text"] as? String ?? ""
            surface.send(text)
            return .success(["sent": text.utf8.count])
        case "get-text":
            guard let surface = surface(windowNumber: windowNumber, paneID: paneID) else {
                return .failure(Failure(message: "no session for that target"))
            }
            if request["source"] as? String == "selection" {
                return .success(["source": "selection", "text": surface.selectedText ?? ""])
            }
            let text = surface.drive.withTerminal { String(Ubiquitty.Accessibility.visibleScreenText($0, 0)) } ?? ""
            return .success(["source": "screen", "text": text])
        case "new-window":
            guard let window = TerminalWindowController.spawn()?.window else {
                return .failure(Failure(message: "could not open a window"))
            }
            return .success(["window": window.windowNumber])
        case "new-tab":
            return openTab()
        case "split":
            guard let controller = controller(windowNumber: windowNumber), let window = controller.window else {
                return .failure(Failure(message: "no such window"))
            }
            if request["direction"] as? String == "down" {
                controller.splitDown(nil)
            } else {
                controller.splitRight(nil)
            }
            return .success(["window": window.windowNumber])
        case "set-title":
            guard let controller = targetController(windowNumber), let window = controller.window else {
                return .failure(Failure(message: "no such window"))
            }
            let title = request["title"] as? String ?? ""
            controller.setCustomTitles(window: title)
            return .success(["window": window.windowNumber, "title": controller.customWindowTitle])
        default:
            return .failure(Failure(message: "unknown verb: \(verb)"))
        }
    }

    // MARK: - Resolution

    /// A JSON number as an `Int`; 0 when absent.
    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// Every terminal window the Swift shell has open.
    @MainActor
    private static func controllers() -> [TerminalWindowController] {
        TerminalWindowController.spawnedControllers.filter { $0.window != nil }
    }

    @MainActor
    private static func controller(windowNumber: Int) -> TerminalWindowController? {
        controllers().first { $0.window?.windowNumber == windowNumber }
    }

    /// The window a request means: the one it numbers, else the key window,
    /// else the first open one.
    @MainActor
    private static func targetController(_ windowNumber: Int) -> TerminalWindowController? {
        if windowNumber != 0 {
            return controller(windowNumber: windowNumber)
        }
        if let key = NSApp.keyWindow?.windowController as? TerminalWindowController, key.window != nil {
            return key
        }
        return controllers().first
    }

    /// The pane a request means: the one it names if it is live, else the
    /// window's active pane, else its lowest-numbered one.
    @MainActor
    private static func resolvePane(_ paneID: Int, in controller: TerminalWindowController) -> (Int, TerminalSurface)? {
        let panes = controller.panesByIdentifier()
        if paneID != 0, let surface = panes[paneID] {
            return (paneID, surface)
        }
        if let active = controller.activeSurface, let id = controller.paneIdentifier(of: active) {
            return (id, active)
        }
        return panes.min { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The surface of a target the server already resolved.
    @MainActor
    private static func surface(windowNumber: Int, paneID: Int) -> TerminalSurface? {
        guard let controller = controller(windowNumber: windowNumber) else { return nil }
        return controller.panesByIdentifier()[paneID]
    }

    // MARK: - Listing

    @MainActor
    private static func windowDescription(_ controller: TerminalWindowController) -> [String: Any]? {
        guard let window = controller.window else { return nil }
        var description: [String: Any] = [
            "id": window.windowNumber,
            "title": window.title,
            "focused": window.isKeyWindow,
            "remote": controller.remoteSurface != nil,
        ]
        if let sessionID = controller.remoteSurface?.remoteSessionID, sessionID != 0 {
            description["daemonSessionID"] = Int(sessionID)
        }
        // This window and its tab-group siblings; a lone window is one tab.
        let group = window.tabGroup
        let tabWindows = group?.windows ?? [window]
        var tabs: [[String: Any]] = []
        for tabWindow in tabWindows {
            guard let tabController = tabWindow.windowController as? TerminalWindowController else { continue }
            tabs.append([
                "index": tabs.count,
                "windowID": tabWindow.windowNumber,
                "title": tabWindow.title,
                "selected": group.map { $0.selectedWindow === tabWindow } ?? true,
                "panes": paneDescriptions(tabController),
            ])
        }
        description["tabs"] = tabs
        return description
    }

    @MainActor
    private static func paneDescriptions(_ controller: TerminalWindowController) -> [[String: Any]] {
        let active = controller.activeSurface
        return controller.panesByIdentifier().sorted { $0.key < $1.key }
            .map { id, surface in
                [
                    "id": id,
                    "focused": surface === active,
                    "columns": surface.publishedGrid.columns,
                    "rows": surface.publishedGrid.rows,
                    "title": surface.title,
                ]
            }
    }

    // MARK: - Window verbs

    @MainActor
    private static func focus(windowNumber: Int, paneID: Int) -> Result<Any, Failure> {
        guard let controller = targetController(windowNumber), let window = controller.window else {
            return .failure(Failure(message: "no such window"))
        }
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if paneID != 0 {
            controller.focusPane(withIdentifier: paneID)
        }
        return .success(["focused": true, "window": window.windowNumber])
    }

    /// Opens a tab beside the key window's, or a window when none is open.
    @MainActor
    private static func openTab() -> Result<Any, Failure> {
        guard let host = targetController(0), let hostWindow = host.window else {
            guard let window = TerminalWindowController.spawn()?.window else {
                return .failure(Failure(message: "could not open a window"))
            }
            return .success(["window": window.windowNumber])
        }
        let before = Set(TerminalWindowController.spawnedControllers.map(ObjectIdentifier.init))
        host.newWindowForTab(nil)
        // A hosted workspace mints its tab on the host, and the window for it
        // arrives later: the answer is then the window the tab joins.
        let opened = TerminalWindowController.spawnedControllers.first { !before.contains(ObjectIdentifier($0)) }
        return .success(["window": (opened?.window ?? hostWindow).windowNumber])
    }
}

/// Carries the last reference to a stopping server to the thread that drops it.
private final class RetiringServer: @unchecked Sendable {
    private var server: Ubiquitty.`Protocol`.Control.Server?

    init(server: Ubiquitty.`Protocol`.Control.Server) {
        self.server = server
    }

    /// Drops the reference, which stops the server and joins its threads.
    func release() {
        server = nil
    }
}
