// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// This half of the surface is AppKit's. The events it answers — mouse
// buttons, a scroll wheel with momentum, NSEvent modifier flags, the
// AppKit text-input client — have no counterpart on a touch screen, so the
// UIKit shell answers its own and neither carries the other's model.
//
// Guarded rather than moved: it extends the shared surface, and keeping it
// beside what it extends is what stops the two halves drifting apart.

#if canImport(AppKit)

//
// TerminalSurface+ConsentPrompt.swift — the agent-attach consent UI for a remote
// surface.
//
// When an agent attaches a session a human occupies, the daemon holds it: the
// agent gets an AwaitingConsent Welcome and exact Pending status, verified
// human recipients are asked, and the first valid answer binds. This is that
// ask for the portable session path — the shell that reaches a host through
// TerminalSession.
//
// The decision belongs to the person, and everything about presenting it here
// follows from two facts about who is asking. `peerProcess` is what the daemon
// verified about the peer and is the only half a prompt may trust;
// `agentLabel` is a string the agent chose for itself, so it is shown as a
// claim and never as an identity. And what is being asked matters as much as
// who asks: approving a terminate as though it were an attach hands over the
// session, so the wording changes with the action rather than a detail line
// carrying it.
//
// Denial is the default at every exit: the Return key, a dismissed sheet, an
// action this build does not recognise. The daemon also denies on a 30-second
// timeout, so a prompt nobody answers costs the agent half a minute and then
// refuses it — this makes the refusal immediate and the approval possible.
// ``ConsentAlert`` is what holds that first clause up, for this prompt and the
// other two the app raises.
//

import AppKit
package import UbiquittyRenderKit
internal import UbiquittyCore

/// One ordinary native sheet, bound to a non-reused local question token.
@MainActor
package final class ConsentPresentation {
    package let token: UInt64
    package let alert: NSAlert

    package init(token: UInt64, alert: NSAlert) {
        self.token = token
        self.alert = alert
    }

    package func dismiss() {
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        } else if NSApp.modalWindow === alert.window {
            NSApp.abortModal()
        }
    }
}

/// One native sheet for one local consent token.
@MainActor
package final class StructureConsentPresentation {
    package let request: RuntimeDrive.StructureConsentPrompt
    private let alert = NSAlert()

    package init(_ request: RuntimeDrive.StructureConsentPrompt) {
        self.request = request
        alert.alertStyle = .warning
        alert.messageText = request.question
        alert.informativeText = request.detail
    }

    /// Presents Core's question with a refusing default and one allowing button.
    package func present(on window: NSWindow?, answer: @escaping (Bool) -> Void) {
        ConsentAlert.choose(alert, refusing: request.denyTitle, between: [request.allowTitle], on: window) { choice in
            answer(choice == 1)
        }
    }

    /// Removes a question the host no longer holds open.
    package func dismiss() {
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        } else if NSApp.modalWindow === alert.window {
            NSApp.abortModal()
        }
    }
}

extension TerminalSurface {
    /// Asks the human about the consent request this surface just received.
    ///
    /// Presented as a sheet on the surface's window when it has one, so the
    /// question is attached to the session it concerns; a surface with no
    /// window falls back to an app-modal alert rather than answering for the
    /// user.
    func askForConsent() {
        let token = drive.pendingConsentToken
        if let shown = consentPresentation {
            guard shown.token != token else { return }
            consentPresentation = nil
            shown.dismiss()
        }
        let structure = drive.pendingStructureConsent
        if let shown = structureConsentPresentation {
            guard shown.request.token != structure?.token else { return }
            structureConsentPresentation = nil
            shown.dismiss()
        }
        if drive.pendingConsentAction == .changeStructure {
            guard let request = structure else { return }
            let presentation = StructureConsentPresentation(request)
            structureConsentPresentation = presentation
            observer?
                .terminalSurface(
                    self,
                    willAskForConsent: request.question,
                    from: Self.consentActor(peerProcess: drive.pendingConsentPeerProcess)
                )
            guard structureConsentPresentation === presentation, drive.pendingStructureConsent?.token == request.token else {
                if structureConsentPresentation === presentation { structureConsentPresentation = nil }
                presentation.dismiss()
                return
            }
            presentation.present(on: window) { [weak self, weak presentation] allow in
                guard let self, let presentation, self.structureConsentPresentation === presentation else { return }
                self.structureConsentPresentation = nil
                self.drive.respondToStructureConsent(request.token, allow: allow)
            }
            return
        }
        guard token != 0 else {
            return
        }
        guard let action = drive.pendingConsentAction else {
            // An action this build does not know. Declined rather than
            // presented: a prompt that cannot say what it is asking cannot
            // collect a meaningful answer, and the alternative is a person
            // approving something the words did not describe. Declining is
            // not an answer, so a recipient that can word it still may.
            drive.declineConsent(token)
            return
        }

        if action == .grantCapability, Ubiquitty.Capability(rawValue: drive.pendingConsentCapabilityCode) == nil {
            drive.declineConsent(token)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = action == .attach ? .informational : .warning
        // A person's own device asking about the program it drives has no
        // verified process to show and no agent name to disown; the prompt
        // names the device instead.
        let isOwnRequest = action == .grantCapability && drive.pendingConsentIsOwnRequest
        // A question this client asks of its own policy, about an effect its
        // remote host delivered: the answer stays here and lasts at most as
        // long as the connection.
        let isClientHeld = action == .grantCapability && drive.pendingConsentIsClientHeld
        if isClientHeld {
            alert.messageText = Self.hostEffectConsentQuestion(capabilityCode: drive.pendingConsentCapabilityCode)
        } else {
            alert.messageText =
                isOwnRequest
                ? Self.ownDeviceConsentQuestion(
                    capabilityCode: drive.pendingConsentCapabilityCode,
                    capabilityOrigin: drive.pendingConsentCapabilityOrigin
                )
                : Self.consentQuestion(action, capabilityCode: drive.pendingConsentCapabilityCode)
        }
        if isClientHeld {
            alert.informativeText = Self.hostEffectConsentDetail(capabilityCode: drive.pendingConsentCapabilityCode)
        } else if isOwnRequest {
            alert.informativeText = String(
                Ubiquitty.Security.ownDeviceCapabilityConsentDetail(
                    drive.pendingConsentCapabilityCode,
                    drive.pendingConsentCapabilityOrigin,
                    std.string(Self.ownDeviceName)
                )
            )
        } else if action == .grantCapability {
            alert.informativeText = Self.capabilityConsentDetail(
                peerProcess: drive.pendingConsentPeerProcess,
                agentLabel: drive.pendingConsentAgentLabel,
                foregroundProcesses: drive.processChain,
                window: window?.title ?? "",
                tab: window?.tabGroup == nil ? "" : (window?.tab.title ?? ""),
                workspace: drive.remoteWorkspaceName,
                pane: observer?.terminalSurfacePaneIdentifier(self).map(String.init) ?? "",
                capabilityOrigin: drive.pendingConsentCapabilityOrigin,
                capabilityCode: drive.pendingConsentCapabilityCode
            )
        } else {
            alert.informativeText = Self.consentDetail(
                peerProcess: drive.pendingConsentPeerProcess,
                agentLabel: drive.pendingConsentAgentLabel
            )
        }
        let actor = Self.consentActor(peerProcess: drive.pendingConsentPeerProcess)
        let scopes =
            isClientHeld
            ? Self.hostEffectConsentScopes(isPerUse: drive.pendingConsentGrantIsPerUse)
            : Self.consentScopes(action, isPerUse: drive.pendingConsentGrantIsPerUse)
        let presentation = ConsentPresentation(token: token, alert: alert)
        consentPresentation = presentation
        // The observer may close, reconnect or retire this question. Retain its
        // exact presentation before the callback and recheck it before showing.
        observer?.terminalSurface(self, willAskForConsent: alert.messageText, from: actor)
        guard consentPresentation === presentation, drive.pendingConsentToken == token else {
            if consentPresentation === presentation { consentPresentation = nil }
            presentation.dismiss()
            return
        }
        ConsentAlert.ask(
            alert,
            refusing: "Deny",
            allowing: scopes,
            on: window
        ) { [weak self, weak presentation] decision in
            guard let self, let presentation, self.consentPresentation === presentation else { return }
            self.consentPresentation = nil
            self.drive.respondToConsent(token, decision: decision)
        }
    }

    /// The allowing buttons whose grants the daemon would keep.
    ///
    /// A grant is only offered when the daemon would keep it. The forced
    /// one-shot tiers are re-asked every time whatever the human picks, so a
    /// "for this session" button there would promise a lifetime that does not
    /// exist; and closing a session is a single act with no lifetime to choose
    /// at all. `ConsentAlert` reads the per-use question back off the buttons,
    /// so building the right ones is also what makes the wider scopes
    /// unreachable for these.
    ///
    /// - Parameters:
    ///   - action: What the agent wants.
    ///   - isPerUse: Core's answer for a capability request.
    /// - Returns: The allowing button titles, widest-lived last.
    package static func consentScopes(_ action: RuntimeDrive.ConsentAction, isPerUse: Bool) -> [String] {
        switch action {
        case .terminate:
            return ["Close Session"]
        case .attach:
            return ConsentAlert.onceOrSession + ["Always Allow This Agent"]
        case .grantCapability:
            return isPerUse ? ["Allow Once"] : ConsentAlert.onceOrSession + ["Always Allow"]
        case .changeStructure:
            return []
        }
    }

    /// The allowing buttons for a question this client asks of its own policy.
    ///
    /// No answer here is saved, so none is called "Always": the wider button
    /// lasts as long as the connection, which is the session scope Core keeps
    /// for it, and a capability whose grants are good for one use offers only
    /// that.
    ///
    /// - Parameter isPerUse: Core's answer for the capability.
    /// - Returns: The allowing button titles, widest-lived last.
    package static func hostEffectConsentScopes(isPerUse: Bool) -> [String] {
        isPerUse ? ["Allow Once"] : ["Allow Once", String(Ubiquitty.Security.hostEffectConnectionScopeTitle())]
    }

    /// The title of a question this client asks about an effect its remote
    /// host delivered.
    ///
    /// - Parameter capabilityCode: What the effect would do.
    /// - Returns: The alert's title.
    package static func hostEffectConsentQuestion(capabilityCode: UInt16) -> String {
        String(Ubiquitty.Security.hostEffectConsentTitle(capabilityCode))
    }

    /// Why this device asks after its host allowed the effect, and what the
    /// answer covers.
    ///
    /// - Parameter capabilityCode: What the effect would do.
    /// - Returns: The alert's explanatory text.
    package static func hostEffectConsentDetail(capabilityCode: UInt16) -> String {
        String(Ubiquitty.Security.hostEffectConsentDetail(capabilityCode, std.string(ownDeviceName)))
    }

    /// The question, in the words of what is actually being asked.
    ///
    /// - Parameters:
    ///   - action: What the agent wants.
    ///   - capabilityCode: The capability, for a grant.
    /// - Returns: The alert's title.
    package static func consentQuestion(_ action: RuntimeDrive.ConsentAction, capabilityCode: UInt16) -> String {
        switch action {
        case .attach:
            return "Let an agent attach to this session?"
        case .terminate:
            return "Let an agent close this session?"
        case .grantCapability:
            return String(Ubiquitty.Security.capabilityConsentTitle(capabilityCode))
        case .changeStructure:
            return ""
        }
    }

    /// What this device calls itself in a prompt about its own request.
    package static let ownDeviceName = "Mac"

    /// The question for a request this device's own program made.
    ///
    /// - Parameters:
    ///   - capabilityCode: The capability asked for.
    ///   - capabilityOrigin: How this device reaches the host, as the raw
    ///     `CapabilityOrigin`.
    /// - Returns: The alert's title, naming this device.
    package static func ownDeviceConsentQuestion(capabilityCode: UInt16, capabilityOrigin: UInt8) -> String {
        String(Ubiquitty.Security.ownDeviceCapabilityConsentTitle(capabilityCode, capabilityOrigin, std.string(ownDeviceName)))
    }

    /// Describes where the request came from and the lifetime Core enforces for its grant.
    ///
    /// The words are Core's (`CapabilityConsentText`), so every arm's dialog
    /// reads the same; this half only supplies the facts this shell holds. The
    /// foreground chain is the one the host's pane facts carry, and it is the
    /// terminal's nearest observation of the emitter — the principal is named
    /// separately, as the holder of drive access rather than as the sender.
    ///
    /// - Parameters:
    ///   - peerProcess: The verified attached principal.
    ///   - agentLabel: The principal's unverified label.
    ///   - foregroundProcesses: The session's foreground process chain.
    ///   - window: The title of the window showing the session.
    ///   - tab: The title of its tab, empty when the window is not tabbed.
    ///   - workspace: The authoritative hosted workspace name.
    ///   - pane: The pane displaying the requesting session.
    ///   - capabilityOrigin: The origin the request was checked against, as
    ///     the raw `CapabilityOrigin`; it decides the lifetime disclosed.
    ///   - capabilityCode: The requested capability.
    /// - Returns: The capability prompt's explanatory text.
    package static func capabilityConsentDetail(
        peerProcess: String,
        agentLabel: String,
        foregroundProcesses: String,
        window: String,
        tab: String,
        workspace: String = "",
        pane: String = "",
        capabilityOrigin: UInt8 = Ubiquitty.CapabilityOrigin.Agent.rawValue,
        capabilityCode: UInt16
    ) -> String {
        var attribution = Ubiquitty.Security.CapabilityConsentAttribution()
        attribution.origin = sessionOrigin(workspace: workspace, window: window, tab: tab, pane: pane)
        attribution.foregroundProcesses = std.string(foregroundProcesses)
        attribution.principal = std.string(peerProcess)
        attribution.agentLabel = std.string(agentLabel)
        return String(Ubiquitty.Security.capabilityConsentDetail(capabilityCode, capabilityOrigin, attribution))
    }

    private static func sessionOrigin(workspace: String, window: String, tab: String, pane: String) -> Ubiquitty.Session.SessionOrigin {
        var origin = Ubiquitty.Session.SessionOrigin()
        origin.workspace = std.string(workspace)
        origin.window = std.string(window)
        origin.tab = std.string(tab)
        origin.pane = std.string(pane)
        return origin
    }

    /// Describes the live arrangement in the labelled form a consent prompt uses.
    package var sessionOriginDescription: String {
        let origin = Self.sessionOrigin(
            workspace: drive.remoteWorkspaceName,
            window: window?.title ?? "",
            tab: window?.tabGroup == nil ? "" : (window?.tab.title ?? ""),
            pane: observer?.terminalSurfacePaneIdentifier(self).map(String.init) ?? ""
        )
        return String(Ubiquitty.Session.describeSessionOrigin(origin))
    }

    /// Who a banner names as the asker.
    ///
    /// The verified executable's own name, never the label the agent chose: a
    /// banner is read at a glance, and a claim read at a glance is read as an
    /// identity. The sheet behind it has room to attribute the label; a
    /// notification does not.
    ///
    /// - Parameter peerProcess: What the daemon verified.
    /// - Returns: The name to show.
    package static func consentActor(peerProcess: String) -> String {
        let name = (peerProcess as NSString).lastPathComponent
        return name.isEmpty ? "An unidentified program" : name
    }

    /// Who is asking, with the verified half separated from the claimed one.
    ///
    /// - Parameters:
    ///   - peerProcess: What the daemon verified.
    ///   - agentLabel: What the agent calls itself.
    /// - Returns: The alert's body.
    static func consentDetail(peerProcess: String, agentLabel: String) -> String {
        let who = peerProcess.isEmpty ? "An unidentified process" : peerProcess
        guard !agentLabel.isEmpty else {
            return "\(who) is asking. It can read what is on screen and type into it."
        }
        // The label is quoted and attributed, because an agent picks it: a
        // sentence reading "Backup Helper is asking" would let the agent write
        // the prompt.
        return "\(who) is asking, calling itself “\(agentLabel)”."
            + " That name is chosen by the agent and is not verified."
            + " It can read what is on screen and type into it."
    }
}

#endif
