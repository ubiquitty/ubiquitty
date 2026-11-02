// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BeamRemoteCommands.swift — Beam's ways into Connect: one row per saved or
// recent host running Core's plan (with New Session, Choose Session, Manage
// and Edit as secondary actions), the per-kind entry points, the open remote
// windows, the saved layouts, and the recent targets of every kind.
//
// Connect… itself is the File-menu item, which MenuCommandProvider surfaces;
// a second row here would list it twice.
//

import AppKit
import UbiquittyKit

struct TmuxSSHRemoteCommandProvider: BeamCommandProvider {
    // The kinds whose recent targets Beam lists as their own rows.
    private static let recentKinds: [(kind: ConnectKind, verb: String, keywords: [String])] = [
        (.ssh, "SSH", ["ssh", "connect", "remote", "shell", "recent"]),
        (.mosh, "Mosh", ["mosh", "connect", "remote", "shell", "recent"]),
        (.localTmux, "tmux", ["tmux", "attach", "control mode", "recent"]),
        (.remoteTmux, "tmux over SSH", ["tmux", "ssh", "remote", "attach", "control mode", "recent"]),
        (.serial, "Serial", ["serial", "tty", "usb", "recent"]),
    ]

    func commands() -> [BeamCommand] {
        [
            BeamCommand(
                title: "Attach Local tmux Session…",
                group: "Remote",
                keywords: ["tmux", "attach", "control mode"],
                identity: "remote.connect.localTmux",
                run: { ConnectWindowController.show(place: .thisMacTmux) }
            ),
            BeamCommand(
                title: "Open Serial Port…",
                group: "Remote",
                keywords: ["serial", "tty", "usb"],
                identity: "remote.connect.serial",
                run: { ConnectWindowController.show(place: .serialPorts) }
            ),
            BeamCommand(
                title: "New SSH Session…",
                group: "Remote",
                keywords: ["ssh", "connect", "remote", "shell"],
                identity: "remote.connect.ssh",
                run: { ConnectWindowController.show(place: .shell(.ssh)) }
            ),
            BeamCommand(
                title: "New Mosh Session…",
                group: "Remote",
                keywords: ["mosh", "connect", "remote", "shell"],
                identity: "remote.connect.mosh",
                run: { ConnectWindowController.show(place: .shell(.mosh)) }
            ),
            BeamCommand(
                title: "Attach tmux Session over SSH…",
                group: "Remote",
                keywords: ["tmux", "ssh", "remote", "attach", "control mode"],
                identity: "remote.connect.remoteTmux",
                run: { ConnectWindowController.show(place: .shell(.remoteTmux)) }
            ),
        ] + hostCommands() + windowCommands() + layoutCommands() + recentCommands()
    }

    /// One row per saved or recent host, running Core's plan, with the other
    /// ways in as secondary actions.
    private func hostCommands() -> [BeamCommand] {
        let saved = HostServers.all()
        let recents = ConnectRecents.recent(for: .ubiquittyHost).filter { target in !saved.contains { $0.host == target } }
        let hosts = saved + recents.map { ConnectModel.recentServer($0) }
        return hosts.map { server in
            let place: ConnectPlace =
                server.isLocal ? .thisMacHost : (saved.contains { $0.id == server.id } ? .host(server.id) : .recent(server.host))
            let isDaemonHost = server.kind == .ubiquittyHost
            var secondary: [BeamOption] = []
            if isDaemonHost {
                secondary = [
                    BeamOption(label: "New Workspace on \(server.displayName)") {
                        ConnectWindowController.show(place: place, intent: .newSession)
                        ConnectModel.shared.newSession()
                    },
                    BeamOption(label: "Choose Workspace on \(server.displayName)…") {
                        ConnectWindowController.show(place: place, intent: .chooseSession)
                    },
                    BeamOption(label: "Manage \(server.displayName)…") { HostManagementWindows.shared.show(server: server) },
                ]
            }
            secondary.append(
                BeamOption(label: "Edit \(server.displayName)…") {
                    ConnectWindowController.show(place: place)
                    ConnectModel.shared.isInspectorPresented = true
                }
            )
            return BeamCommand(
                title: "Connect to \(server.displayName)",
                group: "Remote",
                keywords: ["connect", "host", "reattach", server.host],
                identity: "remote.connect.host.\(server.pairingKey).\(server.id.uuidString)",
                secondaryActions: secondary,
                run: {
                    if isDaemonHost {
                        ConnectModel.shared.runPlan(for: server)
                    } else if ConnectLauncher.open(server) != nil {
                        ConnectWindowController.show(place: place)
                    }
                }
            )
        }
    }

    /// One row per open remote window, which brings it forward.
    private func windowCommands() -> [BeamCommand] {
        TerminalWindowController.spawnedControllers
            .filter { !$0.isWindowClosed && !$0.remoteHostKey.isEmpty }
            .map { controller in
                let title = controller.window?.title ?? controller.remoteHostLabel
                return BeamCommand(
                    title: title,
                    group: "Remote ▸ Windows",
                    keywords: ["window", "remote", controller.remoteHostLabel],
                    identity: "remote.window.\(ObjectIdentifier(controller).hashValue)",
                    run: { [weak controller] in controller?.window?.makeKeyAndOrderFront(nil) }
                )
            }
    }

    /// One row per saved layout.
    private func layoutCommands() -> [BeamCommand] {
        let model = ConnectModel.shared
        model.reloadLayouts()
        return model.layouts.map { entry in
            BeamCommand(
                title: "Restore Layout: \(entry.name)",
                group: "Remote ▸ Layouts",
                keywords: ["layout", "restore", "windows"],
                identity: "remote.layout.\(entry.id)",
                run: { ConnectModel.shared.openLayout(entry.id) }
            )
        }
    }

    private func recentCommands() -> [BeamCommand] {
        // One UserDefaults read for all kinds (this runs on every ⌘⇧P open).
        let byKind = ConnectRecents.recent(for: Self.recentKinds.map(\.kind))
        return Self.recentKinds.flatMap { entry in
            (byKind[entry.kind] ?? [])
                .map { target in
                    BeamCommand(
                        title: "\(entry.verb): \(target)",
                        group: "Remote ▸ Recent",
                        keywords: entry.keywords,
                        identity: "remote.connect.recent.\(entry.kind.rawValue).\(target)",
                        run: { MainActor.assumeIsolated { _ = ConnectQuickConnect.run(kind: entry.kind, target: target) } }
                    )
                }
        }
    }
}
