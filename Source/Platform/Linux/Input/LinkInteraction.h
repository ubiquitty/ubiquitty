// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Input/PointerLadder.h"

#include <string_view>

namespace Ubiquitty::Preferences {
struct Values;
}

namespace Ubiquitty::Linux {

/// Describes a link resolved by Core at the pointer's visible cell.
struct LinkTargetFacts {
    /// The program declared the target with OSC 8.
    bool isHyperlink = false;
    /// The resolver inferred a filesystem path rather than a URL.
    bool isFilePath = false;
    /// The target URI or literal path borrowed for this interaction.
    std::string_view uri;
};

/// Adapts Linux's native Control gesture to Core's link interaction policy.
class LinkInteraction final {
public:
    /// Resolves the native gesture and current pointer ownership.
    ///
    /// - Parameters:
    ///   - moment: The held modifiers and application's mouse-reporting state.
    ///   - configuration: The current link and selection preferences.
    LinkInteraction(const Input::PointerMoment& moment, const Preferences::Values& configuration);

    /// Returns the shared policy's scope for the link scan.
    ///
    /// - Returns: No scan, declared links only, or all detected candidates.
    [[nodiscard]] Input::LinkProbe probe() const;

    /// Decides whether the resolved target accepts the current gesture.
    ///
    /// - Parameter target: The resolver's target and source classification.
    /// - Returns: Whether the click may reach the platform's target opener.
    [[nodiscard]] bool canOpen(const LinkTargetFacts& target) const;

    /// Returns the resolved ownership and selection gestures.
    ///
    /// - Returns: The shared pointer-reporting decision for this moment.
    [[nodiscard]] const Input::PointerReportingState& reportingState() const;

private:
    Input::PointerReportingState m_reporting;
    bool m_isPlainClickEnabled;
};

} // namespace Ubiquitty::Linux
