// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ConnectLauncher.swift — opens an ssh, mosh, tmux or serial window from a
// Connect place or a saved host, through Core's argument builders.
//
// What an address means is Core's parse; what argv a shell runs is Core's
// builders; what a tmux Session field means is Core's mapping. This file
// resolves the executables, which only the frontend can see, and reports every
// failure as a fact the window shows inline — never an alert, never silence.
//

import AppKit
import Foundation
import UbiquittyCore
import UbiquittyKit

/// Why a launch did not open a window.
enum ConnectLaunchFailure: Equatable {
    /// Core refused the address; the sentence is its reason.
    case invalidAddress(String)
    /// No `tmux` was found; these are the directories searched.
    case tmuxUnavailable([String])
    /// The serial device could not be opened.
    case deviceUnavailable(String)
    /// The window could not be built.
    case windowFailed

    /// The state the Connect window shows for it.
    var title: String {
        switch self {
        case .invalidAddress: "The Address Isn’t Valid"
        case .tmuxUnavailable: "tmux Isn’t Installed"
        case .deviceUnavailable(let device): "Couldn’t Open \(device)"
        case .windowFailed: "Ubiquitty Couldn’t Open a Window"
        }
    }

    /// The sentence under the title.
    var sentence: String {
        switch self {
        case .invalidAddress(let reason): reason
        case .tmuxUnavailable(let directories):
            "Ubiquitty looked in " + directories.joined(separator: ", ") + ". Install tmux, then try again."
        case .deviceUnavailable:
            "The device was disconnected, or another program is using it. Reconnect it or quit the other program, then try again."
        case .windowFailed: "Nothing was started. Try again."
        }
    }

    /// The suffix of the state's `connect-state-` identifier.
    var stateName: String {
        switch self {
        case .invalidAddress: "invalid-address"
        case .tmuxUnavailable: "tmux-missing"
        case .deviceUnavailable: "serial-unavailable"
        case .windowFailed: "window-could-not-open"
        }
    }
}

/// Opens one-off and saved shells.
@MainActor
enum ConnectLauncher {
    /// Finds a tool by name; replaced by a scenario that needs a machine
    /// without one.
    static var resolveTool: (String) -> String? = { TerminalWindowController.resolveTool(named: $0) }

    /// Opens an ssh or mosh shell.
    ///
    /// - Parameters:
    ///   - kind: `.ssh` or `.mosh`.
    ///   - address: The typed address.
    ///   - shouldForwardAgent: Whether an ssh shell forwards the agent.
    ///   - localePolicy: The locale the shell runs under.
    /// - Returns: Nil when a window opened, else why not.
    static func openShell(
        kind: ConnectKind,
        address: String,
        shouldForwardAgent: Bool,
        localePolicy: ConnectCharacterLocalePolicy
    ) -> ConnectLaunchFailure? {
        let parsed = ConnectModel.parse(address)
        guard parsed.isValid, !parsed.destination.isEmpty else {
            return .invalidAddress(parsed.reason)
        }
        let tool: Ubiquitty.Network.ShellTool = kind == .mosh ? .Mosh : .SSH
        let name = kind == .mosh ? "mosh" : "ssh"
        let path = resolveTool(name) ?? name
        let forwarding: Ubiquitty.Network.AgentForwarding = shouldForwardAgent ? .Forward : .Withhold
        let arguments = path.withCxxStringView { binary in
            parsed.destination.withCxxStringView { host in
                Ubiquitty.Network.buildShellLaunchArguments(Ubiquitty.Preferences.values().pointee, tool, binary, host, forwarding)
                    .map { String($0) }
            }
        }
        guard !arguments.isEmpty else {
            return .invalidAddress(
                parsed.reason.isEmpty
                    ? "That address would be read as a command-line option. Enter a host name or address that doesn’t start with a hyphen."
                    : parsed.reason
            )
        }
        guard
            TerminalWindowController.spawn(
                arguments: arguments,
                localePolicyRawValue: Int32(localePolicy.corePolicy.rawValue),
                sessionLifetimeRawValue: Int32(Ubiquitty.Runtime.SessionLifetime.outlivesChild.rawValue)
            ) != nil
        else {
            return .windowFailed
        }
        ConnectRecents.record(parsed.destination, for: kind)
        return nil
    }

    /// Opens a tmux control-mode window, on this Mac or over ssh.
    ///
    /// - Parameters:
    ///   - host: The ssh address, nil for this Mac.
    ///   - session: The Session field as typed.
    ///   - localePolicy: The locale tmux runs under.
    /// - Returns: Nil when a window opened, else why not.
    static func openTmux(host: String?, session: String, localePolicy: ConnectCharacterLocalePolicy) -> ConnectLaunchFailure? {
        var destination: String?
        if let host {
            let parsed = ConnectModel.parse(host)
            guard parsed.isValid else { return .invalidAddress(parsed.reason) }
            destination = parsed.destination
        }
        let tmuxPath = destination == nil ? (resolveTool("tmux") ?? "") : "tmux"
        let plan: Ubiquitty.Network.TmuxLaunchPlan
        if let destination {
            let ssh = resolveTool("ssh") ?? "ssh"
            plan = ssh.withCxxStringView { binary in
                destination.withCxxStringView { target in
                    session.withCxxStringView { Ubiquitty.Network.planRemoteTmuxLaunch(binary, target, $0) }
                }
            }
        } else {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            plan = tmuxPath.withCxxStringView { binary in
                path.withCxxStringView { searched in
                    session.withCxxStringView { Ubiquitty.Network.planLocalTmuxLaunch(binary, searched, $0) }
                }
            }
        }
        switch plan.failure {
        case .None:
            break
        case .TmuxUnavailable:
            return .tmuxUnavailable(plan.searchedDirectories.map { String($0) })
        case .InvalidHost:
            return .invalidAddress(
                "That address would be read as a command-line option. Enter a host name or address that doesn’t start with a hyphen."
            )
        @unknown default:
            return .windowFailed
        }
        let arguments = plan.arguments.map { String($0) }
        // The window is the explicit control client of the host it dials: its
        // panes run as that host's Remote origin, the host names their chip,
        // and the saved window keeps the host a restore reattaches through.
        // A tmux on this Mac is a control client of no host.
        guard
            TerminalWindowController.spawn(
                arguments: arguments,
                localePolicy: localePolicy.corePolicy,
                sessionLifetime: .endsWithChild,
                tmuxControlHost: destination ?? ""
            ) != nil
        else {
            return .windowFailed
        }
        ConnectRecents.record(destination ?? session, for: destination == nil ? .localTmux : .remoteTmux)
        return nil
    }

    /// Opens a serial device.
    ///
    /// - Parameters:
    ///   - device: The device path.
    ///   - baudRate: The line rate.
    /// - Returns: Nil when a window opened, else why not.
    static func openSerial(device: String, baudRate: Int32) -> ConnectLaunchFailure? {
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) else {
            return .deviceUnavailable(trimmed.isEmpty ? "the Device" : trimmed)
        }
        guard TerminalWindowController.spawn(serialDevice: trimmed, baudRate: baudRate) != nil else {
            return .deviceUnavailable(trimmed)
        }
        ConnectRecents.record(trimmed, for: .serial)
        return nil
    }

    /// Opens a saved host of a shell kind.
    ///
    /// - Parameter server: The saved host.
    /// - Returns: Nil when a window opened, else why not.
    static func open(_ server: HostServer) -> ConnectLaunchFailure? {
        let locale = ConnectCharacterLocalePolicy(rawValue: server.localePolicy) ?? .automatic
        switch server.kind {
        case .ssh:
            return openShell(kind: .ssh, address: server.host, shouldForwardAgent: server.shouldForwardAgent, localePolicy: locale)
        case .mosh:
            return openShell(kind: .mosh, address: server.host, shouldForwardAgent: false, localePolicy: locale)
        case .remoteTmux:
            return openTmux(host: server.host, session: server.tmuxSession, localePolicy: locale)
        case .serial:
            return openSerial(device: server.device, baudRate: server.baudRate)
        case .ubiquittyHost:
            return nil
        }
    }
}
