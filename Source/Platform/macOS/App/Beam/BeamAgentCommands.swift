// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BeamAgentCommands.swift — Beam's commands for the agents on the focused
// window's session: disconnect one, drop the grant that let it in, or clear
// them all.
//
// The daemon-initiated consent prompt and "attach an agent" have no discrete UI
// action to wrap — an agent initiates both, a human never does. What is a
// discrete, human-initiated action is revoking a live agent's access, which is
// otherwise reachable from the title bar's presence pill.
//
// Both shells answer the same two questions — who is attached, and send this
// revoke — so this provider asks them rather than a controller: the Swift
// window answers from its focused pane's session
// (`TerminalWindowController.sessionAttendees`), and sends consent.revoke through
// the same Runtime funnel as the presence pill. Every gate the daemon enforces
// therefore applies to a palette hit exactly as it does to the pill.
//
// Per-agent rather than per-window-global, so it is built fresh at Beam summon
// time from the focused window's live roster, mirroring how goTo/blocks/find
// already close over scopeController in BeamController.present.
//

import AppKit
import UbiquittyKit
import UbiquittyRenderKit

@MainActor
struct AgentSurfaceCommandProvider: BeamCommandProvider {
    /// One agent on the focused window's session, as the palette names it.
    struct Agent {
        /// The stable handle a disconnect names.
        let attachmentID: String
        /// What to call it: its claimed label, else the verified executable.
        let name: String
        /// The verified process path, for presentation only.
        let process: String
        /// The distinct server-derived key used by grant revocation.
        let grantIdentity: String
        /// The grant it holds, which decides which revokes are real.
        let grant: RuntimeDrive.Attendee.Grant?
    }

    /// The agents attached to the focused window's session.
    let agents: [Agent]

    /// The window's own revoke funnel.
    let revoke: (RuntimeDrive.RevokeAction, String, String) -> Void

    /// Builds a provider over a roster and a funnel given directly.
    ///
    /// The two are the whole of what this provider is, and a live roster needs
    /// a daemon, a consent grant and an attached agent to exist — none of
    /// which decides what the palette offers or what a chosen command sends.
    ///
    /// - Parameters:
    ///   - agents: The agents to offer commands for.
    ///   - revoke: Where a chosen command's revoke goes.
    init(agents: [Agent], revoke: @escaping (RuntimeDrive.RevokeAction, String, String) -> Void) {
        self.agents = agents
        self.revoke = revoke
    }

    /// Reads the roster and the revoke seam off whichever shell owns the window.
    ///
    /// - Parameter windowController: The focused window's controller.
    init(windowController: NSWindowController?) {
        if let shell = windowController as? TerminalWindowController {
            agents = shell.sessionAttendees()
                .filter { !$0.isHuman }
                .map {
                    Agent(
                        attachmentID: $0.attachmentID,
                        name: $0.label.isEmpty ? $0.process : $0.label,
                        process: $0.process,
                        grantIdentity: $0.grantIdentity,
                        grant: $0.grant
                    )
                }
            revoke = { [weak shell] action, attachmentID, identity in
                shell?.revokeConsent(action, attachmentID: attachmentID, identity: identity)
            }
            return
        }

        agents = []
        revoke = { _, _, _ in }
    }

    func commands() -> [BeamCommand] {
        guard !agents.isEmpty else { return [] }

        // Held as a local so each command carries the funnel and not the
        // provider, which is rebuilt on the next summon.
        let send = revoke
        var out: [BeamCommand] = []
        for agent in agents {
            if !agent.attachmentID.isEmpty {
                out.append(
                    BeamCommand(
                        title: "Disconnect Agent: \(agent.name)",
                        group: "Agents",
                        keywords: ["agent", "disconnect", "kick", "revoke"],
                        identity: "agent.disconnect.\(agent.attachmentID)",
                        needsConfirm: true,
                        run: { send(.disconnectNow, agent.attachmentID, "") }
                    )
                )
            }
            if agent.grant == .always, !agent.grantIdentity.isEmpty {
                out.append(
                    BeamCommand(
                        title: "Stop Always Allowing: \(agent.name)",
                        group: "Agents",
                        keywords: ["agent", "revoke", "always", "trust"],
                        identity: "agent.stopAlwaysAllowing.\(agent.grantIdentity)",
                        needsConfirm: true,
                        run: { send(.stopAlwaysAllowing, "", agent.grantIdentity) }
                    )
                )
            }
            if agent.grant == .session, !agent.grantIdentity.isEmpty {
                out.append(
                    BeamCommand(
                        title: "Revoke Session Access: \(agent.name)",
                        group: "Agents",
                        keywords: ["agent", "revoke", "session", "trust"],
                        identity: "agent.revokeSessionGrant.\(agent.grantIdentity)",
                        needsConfirm: true,
                        run: { send(.clearSessionGrant, "", agent.grantIdentity) }
                    )
                )
            }
        }
        out.append(
            BeamCommand(
                title: "Disconnect All Agents",
                group: "Agents",
                keywords: ["agent", "disconnect", "all", "kick"],
                identity: "agent.disconnectAll",
                needsConfirm: true,
                run: { send(.disconnectAllAgents, "", "") }
            )
        )
        return out
    }
}
