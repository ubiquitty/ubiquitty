// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/App/TitleCompose.h"

#include <string>

namespace Ubiquitty::Linux::Presentation {

/// What a GNOME header bar's two-line title shows for the focused pane.
///
/// The bold line names what runs; the smaller line under it says where, and
/// what the program says it is doing. The system title (the one string a
/// window switcher or a taskbar shows) is composed apart by Core, as before.
struct WindowTitleContent {
    /// The bold top line.
    std::string title;
    /// The working directory, as a full path abbreviated against home; empty
    /// when unknown or when the composition leaves the directory out.
    std::string directory;
    /// The program's status text; empty when it reported none or the
    /// composition leaves status out.
    std::string status;

    /// What the subtitle shows: the program's status when it said something,
    /// else the directory. One line under the title has room for one of them,
    /// and the program's words are the newer news.
    [[nodiscard]] const std::string& subtitle() const { return status.empty() ? directory : status; }

    /// Whether the subtitle shows the directory, which elides from its start.
    [[nodiscard]] bool isSubtitleDirectory() const { return status.empty(); }

    bool operator==(const WindowTitleContent&) const = default;
};

/// Composes the header's two lines from one pane's title facts.
///
/// The top line is Core's window title with the directory and the status taken
/// out, since the bottom line carries both. A title that would then say
/// nothing names the directory's folder instead of the fallback, so a shell at
/// its prompt reads as GNOME's terminals read: the folder above, its path below.
///
/// - Parameters:
///   - pane: The focused pane's facts.
///   - viewer: The window's viewer facts; its fallback names an empty title.
///   - composition: The reader's window `[title]` composition.
/// - Returns: The two lines.
[[nodiscard]] WindowTitleContent windowTitleContent(const App::PaneTitleFacts& pane, App::TitleViewerFacts viewer,
    const Preferences::Effective::TitleComposition& composition);

} // namespace Ubiquitty::Linux::Presentation
