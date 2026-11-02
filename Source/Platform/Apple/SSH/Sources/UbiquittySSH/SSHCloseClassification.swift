// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The last establishment milestone reached by this physical SSH connection.
public enum SSHConnectionPhase: Sendable {
    case connecting
    case transportOpen
    /// The key exchange finished and the client is signing in.
    case signingIn
    /// The server accepted the sign-in; the session is not open yet.
    case signedIn
    case sessionOpen
}

extension SSHConnectionPhase {
    /// The milestone's place in the order a connection reaches them.
    var order: Int {
        switch self {
        case .connecting: 0
        case .transportOpen: 1
        case .signingIn: 2
        case .signedIn: 3
        case .sessionOpen: 4
        }
    }
}

/// Why a physical carrier is finishing, independent of its diagnostic wording.
public enum SSHCloseDisposition: Sendable, Equatable {
    case exited
    case cancelled
    case failure
    case unexpectedClose
}

/// The typed fact a frontend presents without displaying a transport error's debug text.
public enum SSHCloseClassification: Sendable, Equatable {
    case normal
    case cancelled
    case reachFailure(SSHReachFailure?)
    case interruptedBeforeSession
    case interrupted
    case authenticationRefused
    /// The person declined to give the password the server asked for.
    case authenticationCancelled
    /// The server accepts no sign-in method this host has an offer for.
    case noAcceptedMethod
    /// The server closed the connection while the client was signing in,
    /// which is how a server that counts failed attempts ends the last one.
    case closedDuringSignIn
    case hostKeyUnreadable
    case hostKeyMismatched
    case otherFailure

    /// Whether a typed path failure interrupted an opened transport.
    public var isTransportInterruption: Bool {
        self == .interruptedBeforeSession || self == .interrupted
    }
}

/// Classifies a close from typed errors and actual connection milestones.
///
/// No carrier, event loop, socket or credential is created or accessed.
///
/// - Parameters:
///   - disposition: A remote exit, local cancellation, typed error or unannounced close.
///   - error: The original error, never parsed through its text description.
///   - phase: The last milestone this physical connection reached.
/// - Returns: The fact to present; the original error remains a separate diagnostic.
public func classifySSHClose(
    _ disposition: SSHCloseDisposition,
    error: Error? = nil,
    phase: SSHConnectionPhase
) -> SSHCloseClassification {
    switch disposition {
    case .exited: return .normal
    case .cancelled: return .cancelled
    case .failure, .unexpectedClose: break
    }
    if let error = error as? SSHCarrierError {
        switch error {
        case .authenticationExhausted: return .authenticationRefused
        case .authenticationCancelled: return .authenticationCancelled
        case .noAcceptedMethod: return .noAcceptedMethod
        case .hostKeyUnreadable: return .hostKeyUnreadable
        case .hostKeyMismatched: return .hostKeyMismatched
        }
    }
    let reachFailure = error.flatMap { SSHCarrier.reachFailure(of: $0) }
    guard reachFailure != nil || disposition == .unexpectedClose else { return .otherFailure }
    switch phase {
    case .connecting: return .reachFailure(reachFailure)
    case .transportOpen: return .interruptedBeforeSession
    case .signingIn: return disposition == .unexpectedClose ? .closedDuringSignIn : .interruptedBeforeSession
    case .signedIn: return .interruptedBeforeSession
    case .sessionOpen: return .interrupted
    }
}
