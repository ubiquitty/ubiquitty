// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "PAL/TerminalClients.h"

#include <string_view>

//
// Source/Platform/Linux/CapabilityPolicy.h — the GTK frontend's CapabilityPolicy.
//
// Same shape and same reasoning as the macOS GUI's. A LOCAL principal is the
// user's own program, already running with the user's OS privileges, so gating
// it buys nothing. An Agent or a Remote peer keeps the effects that stay on the
// grid it already sees: the feature, cursor and colour replies programs block
// on, and the informational and rendering effects. It is refused every
// host-escaping and exfiltrating effect, including the two PAL would ask a
// remote owner about, because this frontend holds no consent question. The
// daemon's grant machinery (Platform/Host/HostCapabilityPolicy) is where a
// principal is asked, and a GUI frontend is not that.
//
// Why a frontend installs one when Core answers a terminal with no policy from
// the same PAL defaults: the file-read paths (`effectGranted`) refuse every
// origin without a policy, and the frontend's answer is stated here, in its own
// backend, rather than inherited from Core's fallback for a terminal nobody
// configured. Scripts/check-frontend-capability-policy.py holds every frontend
// to that.
//
// Kept in Platform/Linux rather than shared from Platform/macOS so the backends
// stay independent, which is the same reason the macOS one is not shared from
// Platform/Host.
//

namespace Ubiquitty::Linux {

/// The GTK frontend's capability gate: PAL's default, with nobody to ask.
class LinuxCapabilityPolicy final : public Ubiquitty::CapabilityPolicy {
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

} // namespace Ubiquitty::Linux
