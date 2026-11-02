// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "PAL/TerminalClients.h"

#include <string_view>

//
// Source/Platform/Wscons/CapabilityPolicy.h — the wscons frontend's CapabilityPolicy.
//
// Same shape and same reasoning as the GTK and macOS frontends'. A LOCAL
// principal is the user's own program, already running with the user's OS
// privileges, so gating it buys nothing. An Agent or a Remote peer keeps the
// replies its programs block on and the effects that stay on the grid, and is
// refused every host-escaping and exfiltrating effect; a console holds no
// consent question, so what PAL would ask a remote owner about is refused too.
// The daemon's grant machinery (Platform/Host/HostCapabilityPolicy) is where a
// principal is asked, and a console frontend is not that.
//
// Installed before this frontend wires its first client, which is the part worth
// stating. Core answers an unwired terminal from the same PAL defaults, but the
// file-read paths (`effectGranted`) refuse every origin without a policy, and
// the frontend's answer belongs in its own backend rather than in Core's
// fallback for a terminal nobody configured. A frontend with no policy and no
// host-escaping client shows nothing amiss, and nothing goes red when the first
// such client arrives. Seeding the policy first means that client lands on a
// gate this frontend chose.
//
// Kept in Platform/Wscons rather than shared from Platform/Linux so the backends
// stay independent, which is the same reason the GTK one is not shared from
// Platform/macOS.
//

namespace Ubiquitty::Wscons {

/// The wscons frontend's capability gate: PAL's default, with nobody to ask.
class WsconsCapabilityPolicy final : public Ubiquitty::CapabilityPolicy {
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

} // namespace Ubiquitty::Wscons
