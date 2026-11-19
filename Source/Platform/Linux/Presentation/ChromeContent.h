// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Platform/Linux/Presentation/StatusSymbol.h"

#include <cstdint>
#include <optional>
#include <string>

// What a Linux window's chrome shows, independent of the toolkit drawing it.
// The window gathers these from Core; a toolkit's chrome (GTK and libadwaita
// today, Qt for KDE later) draws them, so the policy has one home.

namespace Ubiquitty::Linux::Presentation {

/// What one pane shows beside its title: the program it runs and the state
/// that program reported. Drawn by the header and the tab bar alike, so the
/// two never disagree.
struct PaneMarks {
    /// The program's catalog key (`Title::processIconCatalog`); empty for none
    /// or when the preference turns process icons off.
    std::string processIconKey;
    /// The program's name as its owner writes it, for the icon's tooltip.
    std::string processIconTitle;
    /// The status the program reported, if any.
    std::optional<StatusSymbol> status;
    /// Whether a bell rang in the pane that nobody has seen.
    bool hasUnheardBell = false; // bool-ok: names the one state it reports

    /// The symbol the pane's mark shows: its program's status, else the bell.
    [[nodiscard]] std::optional<StatusSymbol> shownSymbol() const;

    bool operator==(const PaneMarks&) const = default;
};

/// One tab as a tab bar shows it.
struct TabItem {
    /// The model's tab identifier.
    std::uint32_t identifier = 0;
    /// Core's composed tab label; the bar elides it to fit.
    std::string label;
    bool isActive = false; // bool-ok: names the one state it reports
    PaneMarks marks;

    bool operator==(const TabItem&) const = default;
};

/// The window actions a chrome's controls drive, by name. The window installs
/// them; a chrome only names them, so every click runs in the window's own
/// action dispatch and no chrome holds a callback into the window.
namespace ChromeActions {
inline constexpr const char* newTab = "win.new-tab";
inline constexpr const char* find = "win.find";
/// Stateful, of type `u`: the active tab's identifier. Selecting a tab
/// changes the state.
inline constexpr const char* activeTab = "win.active-tab";
/// Takes a `u`: the identifier of the tab to close.
inline constexpr const char* closeTab = "win.close-tab";
} // namespace ChromeActions

} // namespace Ubiquitty::Linux::Presentation
