// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "PAL/TerminalClients.h"

#include <string_view>

// The web frontend's CapabilityPolicy.
//
// This frontend installs a clipboard client, a window client and a shell
// client, and states its own answer for them here rather than inheriting
// Core's fallback for a terminal nobody configured. The answer is
// `defaultDecisionWithoutConsent`, the macOS and GTK frontends' too: Local is
// allowed everything; an Agent or Remote principal keeps the replies its
// programs block on and the effects that stay on the grid, and is refused every
// host-escaping and exfiltrating effect. This frontend has no consent surface
// to prompt through, so what PAL would ask a remote owner about is refused as
// well.
//
// Nothing here stamps a non-Local origin today — the field keeps its default
// for every byte this frontend parses — so this grants what the frontend
// already did and changes no behaviour. What it decides is the shape of the
// answer if that stops being true: the day someone teleports a session into a
// browser tab is not the day the question gets asked for the first time.
/// The web frontend's capability policy: PAL's default, with nobody to ask.
class WebCapabilityPolicy final : public Ubiquitty::CapabilityPolicy {
public:
    /// Decides one capability request for this frontend.
    ///
    /// The argument is unread: the effect's tier and the principal decide.
    /// The daemon's policy is where a principal is asked and granted.
    ///
    /// - Parameters:
    ///   - capability: The effect.
    ///   - origin: The principal driving the request.
    /// - Returns: ``defaultDecisionWithoutConsent`` for the pair: Allow or Deny,
    ///   never Prompt.
    [[nodiscard]] Ubiquitty::CapabilityDecision check(Ubiquitty::Capability capability, Ubiquitty::CapabilityOrigin origin, std::string_view) override
    {
        return Ubiquitty::defaultDecisionWithoutConsent(capability, origin);
    }
};
