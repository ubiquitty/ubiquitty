// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/App/StatusRollup.h"
#include "Core/OSC/Activity.h"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace Ubiquitty::Linux::Presentation {

/// The role a status mark's colour plays; each toolkit maps it to its own
/// theme colours (GTK style classes, KDE colour roles).
enum class StatusTone : std::uint8_t {
    /// The surrounding ink, dimmed as the theme dims secondary content.
    Dim,
    /// The surrounding ink.
    Plain,
    /// The theme's accent colour.
    Accent,
    /// The theme's success colour.
    Success,
    /// The theme's warning colour.
    Warning,
    /// The theme's error colour.
    Error,
};

/// How a desktop chrome draws one pane status: a freedesktop symbolic icon
/// (which GNOME's and KDE's icon themes both name), or the toolkit's own
/// spinner for work in flight.
struct StatusSymbol {
    /// The freedesktop symbolic icon name; empty when `isSpinner`.
    std::string_view iconName;
    StatusTone tone = StatusTone::Plain;
    /// Whether the status is drawn as a running GtkSpinner instead of an icon.
    bool isSpinner = false; // bool-ok: names the one presentation it selects
    /// What an assistive reader is told the mark means.
    std::string_view spokenName;

    bool operator==(const StatusSymbol&) const = default;
};

/// The symbol a program-status kind is drawn with, the freedesktop counterpart
/// of the SF Symbols the Apple chrome uses for the same kinds.
///
/// - Parameters:
///   - kind: The pane's program status kind.
///   - blockKind: What a blocked program waits for.
/// - Returns: The symbol; nothing for `None`, which draws no mark.
[[nodiscard]] std::optional<StatusSymbol> statusSymbol(App::StatusKind kind, OSC::ProgramBlockKind blockKind);

/// The symbol an unheard bell is drawn with.
[[nodiscard]] StatusSymbol bellSymbol();

} // namespace Ubiquitty::Linux::Presentation
