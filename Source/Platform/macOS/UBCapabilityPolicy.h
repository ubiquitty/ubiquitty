// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// ⚠️  No new code in this file. Write Swift, in the Swift arm.
//
// Objective-C++ on the macOS frontend is being retired: the Swift arm under
// Source/Platform/macOS/App is where logic lives, and it reaches Core
// directly through cxx-interop. Add nothing here. Do not grow an @objc seam to
// reach Swift from here either — existing seams shrink toward thin accessors
// and never grow. Migrate the surrounding code instead, by the recipes in
// Docs/swift-cxx-interop.md.

#include "PAL/TerminalClients.h"

#include <string_view>

// The macOS GUI's CapabilityPolicy, installed on every pane and every adopted
// tmux pane. The kitty file-transport seam (UBFileReadClient) is fail-closed and
// reads only through a policy, and a tmux pane dialled over SSH runs as Remote,
// so this frontend states its answer for every origin.
//
// The answer is `defaultDecisionWithoutConsent`. A Local principal is the user's
// own program, already running with the user's OS privileges, and may do
// everything. A Remote or Agent principal keeps its benign, informational and
// rendering effects: DA, DSR, cursor reports and colour queries are what vim, tmux
// and shells block on for capability detection, and refusing them would stall a
// pane's programs while protecting nothing past the screen the pane already
// shows. Its host-escaping and exfiltrating effects are refused, the clipboard
// write and the notification PAL would ask a remote owner about included: this
// policy holds no consent question, so a Prompt from it would be a question
// nobody asks. The daemon's HostCapabilityPolicy is where a principal is asked
// and granted. Kept in Platform/macOS (not shared from Platform/Host) so the
// backends stay independent.
class UBCapabilityPolicy : public Ubiquitty::CapabilityPolicy {
public:
    [[nodiscard]] Ubiquitty::CapabilityDecision check(Ubiquitty::Capability capability, Ubiquitty::CapabilityOrigin origin, std::string_view) override
    {
        return Ubiquitty::defaultDecisionWithoutConsent(capability, origin);
    }
};
