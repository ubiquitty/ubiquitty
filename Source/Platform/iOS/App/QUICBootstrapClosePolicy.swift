// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import UbiquittySSH

/// Whether Core's reader already produced a complete authenticated dial offer.
enum QUICBootstrapOffer: Equatable { case ready, absent }

/// The interpretation of a bootstrap's close, before its one-shot answer gate.
enum QUICBootstrapCloseDecision: Equatable { case ready, declined, unreachable, cancelled }

/// Retains a complete offer; an interrupted exec with no offer did not decline QUIC.
/// - Parameters:
///   - offer: Whether Core validated a complete offer, including its reached address.
///   - phase: The physical SSH connection's last completed milestone.
///   - classification: The backend's first close fact.
/// - Returns: The answer category, or cancellation with no answer.
func quicBootstrapCloseDecision(
    offer: QUICBootstrapOffer,
    phase: SSHConnectionPhase,
    classification: SSHCloseClassification?
) -> QUICBootstrapCloseDecision {
    if classification == .cancelled { return .cancelled }
    if offer == .ready { return .ready }
    switch classification {
    case .authenticationRefused, .authenticationCancelled, .noAcceptedMethod, .closedDuringSignIn, .hostKeyUnreadable,
        .hostKeyMismatched:
        return .unreachable
    default: break
    }
    if classification?.isTransportInterruption == true { return .unreachable }
    if case .sessionOpen = phase { return .declined }
    return .unreachable
}
