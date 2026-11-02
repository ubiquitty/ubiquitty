// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "PAL/TerminalClients.h"

#include <string_view>

//
// Source/Platform/iOS/CapabilityPolicy.h — the iOS frontend's CapabilityPolicy.
//
// Same shape and same reasoning as the macOS GUI's. A LOCAL principal is the
// person's own program and may do everything. An Agent or a Remote peer keeps
// the feature, cursor and colour replies its programs block on and the effects
// that stay on the grid, and is refused every host-escaping and exfiltrating
// effect, including the two PAL would ask a remote owner about: a terminal's
// own effects have no consent question on this frontend. What a host delivers
// to this device is asked about by the Sync client, not here.
//
// The panes are surfaces over Core's TerminalSession, which wires their
// clients in Core on the shell's behalf, so nothing in the shell assigns a
// client a reader would pair with a policy. The shell installs this one beside
// the clipboard writer it owns, on every pane, so the frontend's answer is
// stated here rather than left to Core's fallback for a terminal nobody
// configured.
//
// Kept in Platform/iOS rather than shared from Platform/macOS so the backends
// stay independent.
//

namespace Ubiquitty::IOS {

/// The iOS frontend's capability gate: PAL's default, with nobody to ask.
class IOSCapabilityPolicy final : public Ubiquitty::CapabilityPolicy {
public:
    /// Decides one effect for the principal that drove it.
    ///
    /// The argument is unread: this frontend confines no path, and the
    /// effect's tier and the principal decide.
    ///
    /// - Parameters:
    ///   - capability: The effect.
    ///   - origin: Who drove the input.
    /// - Returns: ``defaultDecisionWithoutConsent`` for the pair: Allow or Deny,
    ///   never Prompt.
    [[nodiscard]] Ubiquitty::CapabilityDecision check(Ubiquitty::Capability capability, Ubiquitty::CapabilityOrigin origin, std::string_view) override
    {
        return Ubiquitty::defaultDecisionWithoutConsent(capability, origin);
    }
};

} // namespace Ubiquitty::IOS
