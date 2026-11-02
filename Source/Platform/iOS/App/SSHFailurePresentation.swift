// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CxxStdlib
import Foundation
import UbiquittyCore
import UbiquittySSH

/// What went wrong with a connection, said for a person: what happened, what
/// to do about it, and the actions that do it, the default first.
///
/// Built only from typed facts — a reach failure, a close classification, a
/// host's refusal — so the words are the ones Core and this presentation
/// chose for that fact, never a carrier's own description, which stays in the
/// connection log.
struct ConnectionFailure: Equatable {
    /// One way forward a failure offers.
    enum Action: Hashable {
        /// Dial the same host again.
        case tryAgain
        /// Open the host's settings, where its address, port and sign-in are.
        case editHost
        /// Open the host's settings at its pinned key.
        case reviewHostKey
        /// Open a login shell over SSH in place of a workspace that needs QUIC.
        case openLoginShell
        /// Go back to the host's workspaces to pick another.
        case chooseWorkspace
        /// Start a new workspace on the host.
        case newWorkspace
    }

    /// What happened, in one sentence.
    let cause: String
    /// What to do about it, in one sentence; empty when the actions say it.
    let fix: String
    /// The actions, the default first.
    let actions: [Action]

    /// A failure only its own sentence describes, which another try is the
    /// one answer to.
    ///
    /// - Parameter cause: The sentence, already written for a person.
    init(cause: String, fix: String = "", actions: [Action] = [.tryAgain]) {
        self.cause = cause
        self.fix = fix
        self.actions = actions
    }

    /// A host's refusal, in Core's words, with Core's remedies.
    ///
    /// - Parameters:
    ///   - refusal: Why the host refused.
    ///   - cause: The sentence already shown for it, which for a version
    ///     refusal names the end to update.
    ///   - hasWorkspaceName: Whether the refused session carried a name.
    init(refusal: Ubiquitty.`Protocol`.Sync.ByeReason, cause: String, hasWorkspaceName: Bool) {
        var fact = Ubiquitty.Session.ConnectFact()
        fact.kind = .attachRefused
        fact.surface = .terminalWindow
        fact.deniedReason = refusal
        fact.hasWorkspaceName = hasWorkspaceName
        let remedy = String(Ubiquitty.Session.connectRemedySentence(fact))
        // Core's notice says what happened and then what to do, as two
        // sentences; the banner sets the first as the cause and the second
        // as the fix. A one-sentence notice takes Core's remedy sentence as
        // its fix, unless that only restates it.
        let (head, tail) = Self.splitFirstSentence(cause)
        self.cause = head
        fix = !tail.isEmpty ? tail : (remedy == cause || refusal == .VersionMismatch ? "" : remedy)
        actions = Self.actions(for: fact)
    }

    /// The first sentence of a text and the rest of it.
    static func splitFirstSentence(_ text: String) -> (String, String) {
        guard let end = text.range(of: ". ") else { return (text, "") }
        let head = String(text[..<end.lowerBound]) + "."
        let tail = text[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return (head, tail)
    }

    /// The remedies Core decided for a fact, as the actions this app has.
    ///
    /// A remedy with no counterpart here — a token, an install, the host's
    /// administration window — is left out rather than relabelled, and the
    /// window's own Close is the banner's Dismiss.
    static func actions(for fact: Ubiquitty.Session.ConnectFact) -> [Action] {
        var actions: [Action] = []
        for index in 0..<Ubiquitty.Session.connectRemedyCount(fact) {
            let action: Action? =
                switch Ubiquitty.Session.connectRemedyAt(fact, index) {
                case .tryAgain, .askAgain: .tryAgain
                case .editAddress: .editHost
                case .openSSHShell: .openLoginShell
                case .chooseAnother: .chooseWorkspace
                case .startNewNamed, .startNewSession: .newWorkspace
                default: nil
                }
            if let action, !actions.contains(action) { actions.append(action) }
        }
        return actions.isEmpty ? [.tryAgain] : actions
    }
}

/// Localizes typed SSH failure facts; raw transport wording belongs in the connection log.
enum SSHFailurePresentation {
    /// The card's typed recovery, independent of transport diagnostics.
    struct Summary: Equatable {
        enum Recovery: Equatable { case retryConnect, newShell }
        let title: String
        let message: String
        let recovery: Recovery
        /// What the recovery does, beside the cause the failure states.
        var fix: String { recovery == .newShell ? String(localized: "Reconnecting opens a new shell.") : "" }
    }

    /// The direct login-shell card; kept Sync+SSH sessions do not use this recovery.
    /// - Parameter classification: The carrier's first close fact.
    /// - Returns: An interruption card or no specialized card for another outcome.
    static func directShellSummary(_ classification: SSHCloseClassification?) -> Summary? {
        guard classification == .interrupted else { return nil }
        return Summary(
            title: String(localized: "SSH Connection Interrupted"),
            message: String(localized: "The SSH connection was interrupted. Reconnecting opens a new shell."),
            recovery: .newShell
        )
    }

    /// The sentence for the physical connection's actual close phase.
    ///
    /// - Parameters:
    ///   - reason: A supplied human explanation when no backend close occurred.
    ///   - reachFailure: The typed initial connect failure, when present.
    ///   - classification: The backend's first-close fact, independent of error text.
    ///   - host: The host the person selected.
    ///   - port: The SSH port dialled.
    /// - Returns: The readable status, never a typed network error's debug description.
    static func sentence(
        reason: String,
        reachFailure: SSHReachFailure?,
        classification: SSHCloseClassification? = nil,
        host: String,
        port: Int
    ) -> String {
        var connectFailure = reachFailure
        switch classification {
        case .interrupted:
            return String(localized: "The SSH connection was interrupted.")
        case .interruptedBeforeSession:
            return String(localized: "The SSH connection was interrupted before sign-in finished.")
        case .authenticationRefused:
            return String(localized: "The server refused the password or key for this host.")
        case .authenticationCancelled:
            return String(localized: "Sign-in was canceled.")
        case .noAcceptedMethod:
            return String(localized: "The server doesn’t accept any sign-in method this host can offer.")
        case .closedDuringSignIn:
            return String(localized: "The server closed the connection during sign-in.")
        case .hostKeyUnreadable:
            return String(localized: "The server sent a host key Ubiquitty can’t read, so its identity couldn’t be verified.")
        case .hostKeyMismatched:
            return String(localized: "The server’s host key doesn’t match the one saved for this host.")
        case .otherFailure:
            return String(localized: "The SSH connection failed.")
        case .reachFailure(let failure):
            connectFailure = failure ?? connectFailure
        case .normal:
            return String(localized: "The SSH connection ended.")
        case .cancelled:
            return String(localized: "The connection was canceled.")
        case nil:
            break
        }
        guard let connectFailure else {
            if classification != nil { return String(localized: "The SSH connection could not be opened.") }
            return reason.isEmpty ? String(localized: "The connection failed.") : reason
        }
        let failure = connectFailure.connectFailure
        if classification != nil, failure == .Reset {
            return String(localized: "The SSH connection was interrupted before it opened.")
        }
        let portText = String(UInt16(clamping: port))
        switch failure {
        case .Refused:
            return String(localized: "\(host) refused the connection on port \(portText).")
        case .TimedOut:
            return String(localized: "\(host) did not answer on port \(portText).")
        case .Reset:
            return String(localized: "\(host) closed the connection on port \(portText) before it opened.")
        case .HostUnreachable:
            return String(localized: "\(host) cannot be reached from this network.")
        case .NetworkUnreachable:
            return String(localized: "This device has no network that reaches \(host).")
        case .NameNotResolved:
            return String(localized: "No host named \(host) could be found.")
        default:
            return String(localized: "The connection to \(host) on port \(portText) failed.")
        }
    }
}

extension SSHFailurePresentation {
    /// The failure a typed SSH fact describes: ``sentence`` for what
    /// happened, and what to do about it — Core's remedy for a connection that
    /// never opened, and this presentation's for how sign-in or the host's
    /// identity failed.
    ///
    /// - Parameters:
    ///   - reason: A supplied human explanation when no backend close occurred.
    ///   - reachFailure: The typed initial connect failure, when present.
    ///   - classification: The backend's first-close fact.
    ///   - host: The host the person selected.
    ///   - port: The SSH port dialled.
    /// - Returns: The cause, its fix and the actions that carry the fix out.
    static func failure(
        reason: String,
        reachFailure: SSHReachFailure?,
        classification: SSHCloseClassification? = nil,
        host: String,
        port: Int
    ) -> ConnectionFailure {
        let cause = sentence(reason: reason, reachFailure: reachFailure, classification: classification, host: host, port: port)
        switch classification {
        case .authenticationRefused, .closedDuringSignIn:
            return ConnectionFailure(
                cause: cause,
                fix: String(localized: "Check the password or key in the host’s settings."),
                actions: [.editHost, .tryAgain]
            )
        case .noAcceptedMethod:
            return ConnectionFailure(
                cause: cause,
                fix: String(localized: "Save a key or password for this host in its settings."),
                actions: [.editHost]
            )
        case .hostKeyMismatched:
            return ConnectionFailure(
                cause: cause,
                fix: String(
                    localized:
                        "If the host was reinstalled, forget the old key in its settings. Otherwise, the connection may not be safe."
                ),
                actions: [.reviewHostKey]
            )
        case .interrupted, .interruptedBeforeSession, .authenticationCancelled, .cancelled, .normal, .otherFailure,
            .hostKeyUnreadable:
            return ConnectionFailure(cause: cause)
        case .reachFailure(let failure):
            guard let failure = failure ?? reachFailure else { return ConnectionFailure(cause: cause) }
            return connectFailed(cause: cause, failure.connectFailure)
        case nil:
            guard let reachFailure else { return ConnectionFailure(cause: cause) }
            return connectFailed(cause: cause, reachFailure.connectFailure)
        }
    }

    /// A connection that never opened, with Core's remedy beside the cause.
    private static func connectFailed(cause: String, _ failure: Ubiquitty.Transport.ConnectFailure) -> ConnectionFailure {
        var fact = Ubiquitty.Session.ConnectFact()
        fact.kind = .connectFailed
        fact.connectFailure = failure
        return ConnectionFailure(
            cause: cause,
            fix: String(Ubiquitty.Session.connectRemedySentence(fact)),
            actions: ConnectionFailure.actions(for: fact)
        )
    }
}

extension SSHReachFailure {
    /// The fact Core reads this failure as.
    var connectFailure: Ubiquitty.Transport.ConnectFailure {
        switch self {
        case .system(let errorCode): return Ubiquitty.Transport.classifyConnectError(errorCode)
        case .nameNotResolved: return .NameNotResolved
        case .timedOut: return .TimedOut
        }
    }

    /// Whether Core says a connect may still land after this failure, so a
    /// carrier waiting for a usable path keeps waiting rather than reporting it.
    var isWorthWaitingOut: Bool {
        Ubiquitty.Transport.isTransientConnectFailure(connectFailure)
    }
}
