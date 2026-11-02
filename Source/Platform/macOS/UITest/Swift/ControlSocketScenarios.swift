// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// ControlSocketScenarios.swift — the control socket drives the Swift shell.
//
// Core's half — decoding, the token, the agent policy, which verb reaches the
// host with which ids — is pinned in Tests/Core/Protocol/test_control_server.
// What only a running app can say is whether the host answers over a real
// socket with Kit-hosted windows: a server that enumerated only Objective-C
// controllers would list nothing for a Swift window with `ls`, and every typed
// or read verb would answer "no window".

/// A request's reply, filled in by the thread that talks to the socket.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: [String: Any]?
    private var isDone = false

    func finish(_ value: [String: Any]?) {
        lock.lock()
        reply = value
        isDone = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDone
    }

    var value: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return reply
    }
}

/// Sends one request line to a unix socket and reads one response line.
///
/// Blocking, so it runs off the main thread: the server answers each verb on
/// the main thread, and a caller waiting there would wait on itself.
///
/// - Parameters:
///   - path: The socket's path.
///   - request: One JSON-RPC request object, without its newline.
/// - Returns: The parsed response, or nil when the exchange failed.
private func exchange(path: String, request: String) -> [String: Any]? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }
    let line = Array((request + "\n").utf8)
    guard line.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == line.count else { return nil }
    var response: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !response.contains(UInt8(ascii: "\n")) {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { break }
        response.append(contentsOf: buffer[0..<count])
    }
    return (try? JSONSerialization.jsonObject(with: Data(response))) as? [String: Any]
}

/// Registers the control-socket scenarios with the UI-test runner.
enum ControlSocketScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("control_socket_drives_the_swift_shell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let directory = "/tmp/ubq-ctl-\(getpid())"
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(atPath: directory) }
                let socketPath = directory + "/control.sock"
                let policyPath = directory + "/policy.conf"
                try? Data("default allow\n".utf8).write(to: URL(fileURLWithPath: policyPath))

                // The rule file and audit log are read where the gate reads
                // them; the suite's own stay untouched.
                let savedPolicy = ProcessInfo.processInfo.environment["UBIQUITTY_AGENT_POLICY"]
                let savedAudit = ProcessInfo.processInfo.environment["UBIQUITTY_AGENT_AUDIT"]
                setenv("UBIQUITTY_AGENT_POLICY", policyPath, 1)
                setenv("UBIQUITTY_AGENT_AUDIT", directory + "/audit.log", 1)
                defer {
                    if let savedPolicy { setenv("UBIQUITTY_AGENT_POLICY", savedPolicy, 1) } else { unsetenv("UBIQUITTY_AGENT_POLICY") }
                    if let savedAudit { setenv("UBIQUITTY_AGENT_AUDIT", savedAudit, 1) } else { unsetenv("UBIQUITTY_AGENT_AUDIT") }
                }

                guard ControlHost.start(socketPath: socketPath, approval: .AutoApprove) else {
                    t.expect(false, desc: "the control socket binds \(socketPath)")
                    return
                }
                defer { ControlHost.stop() }

                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }

                var nextID = 0
                func call(_ method: String, _ parameters: [String: Any] = [:]) -> [String: Any]? {
                    nextID += 1
                    let object: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": parameters]
                    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
                    let request = String(decoding: data, as: UTF8.self)
                    let box = ReplyBox()
                    DispatchQueue.global()
                        .async {
                            box.finish(exchange(path: socketPath, request: request))
                        }
                    _ = t.wait(until: { box.isFinished }, timeout: 5)
                    return box.value
                }

                // ls lists this window, its one tab and its pane.
                let windows = (call("ls")?["result"] as? [String: Any])?["windows"] as? [[String: Any]] ?? []
                let listed = windows.first { ($0["id"] as? Int) == window.windowNumber }
                t.expect(listed != nil, desc: "ls lists the Swift-shell window (\(windows.count) listed)")
                let panes = ((listed?["tabs"] as? [[String: Any]])?.first?["panes"] as? [[String: Any]]) ?? []
                t.expect(panes.count == 1, desc: "with its one pane (\(panes.count))")
                t.expect(
                    (panes.first?["columns"] as? Int) == surface.publishedGrid.columns && surface.publishedGrid.columns > 0,
                    desc: "whose grid is the surface's"
                )
                let paneID = panes.first?["id"] as? Int ?? 0

                // send-text types into that pane, and get-text reads it back.
                let typed = "echo ctl-$((6*7))\n"
                let sent = call("send-text", ["window": window.windowNumber, "pane": paneID, "text": typed])
                t.expect(
                    ((sent?["result"] as? [String: Any])?["sent"] as? Int) == typed.utf8.count,
                    desc: "send-text reports the bytes it typed (\(String(describing: sent)))"
                )
                var screen = ""
                t.expect(
                    t.wait(
                        until: {
                            screen =
                                (call("get-text", ["window": window.windowNumber])?["result"] as? [String: Any])?["text"] as? String ?? ""
                            return screen.contains("ctl-42")
                        },
                        timeout: 8
                    ),
                    desc: "get-text shows what the typed line printed (\(screen.suffix(120)))"
                )

                // The selection is the pane's own.
                surface.selectAll(nil)
                let selection = (call("get-text", ["source": "selection"])?["result"] as? [String: Any])?["text"] as? String
                t.expect(
                    selection != nil && selection == surface.selectedText && selection?.contains("ctl-42") == true,
                    desc: "get-text source=selection returns the pane's selection"
                )

                // A pane the window does not hold is not answered with another.
                let stray = call("send-text", ["window": window.windowNumber + 100_000, "text": "x"])
                t.expect(stray?["error"] != nil, desc: "a window that does not exist is refused")
            }
        }
    }
}
