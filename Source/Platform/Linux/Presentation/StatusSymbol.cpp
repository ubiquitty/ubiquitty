// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Presentation/StatusSymbol.h"
#include "Platform/Linux/Presentation/ChromeContent.h"

namespace Ubiquitty::Linux::Presentation {

std::optional<StatusSymbol> statusSymbol(App::StatusKind kind, OSC::ProgramBlockKind blockKind)
{
    // Names from the freedesktop and Adwaita symbolic sets, so every icon theme
    // that follows the naming specification draws its own version of each.
    switch (kind) {
    case App::StatusKind::None:
        return std::nullopt;
    case App::StatusKind::Idle:
        return StatusSymbol { .iconName = "weather-clear-night-symbolic", .tone = StatusTone::Dim, .spokenName = "Idle" };
    case App::StatusKind::Running:
        return StatusSymbol { .iconName = "media-playback-start-symbolic", .tone = StatusTone::Plain, .spokenName = "Running" };
    case App::StatusKind::Working:
        // Work in flight is the toolkit's spinner, as GNOME shows it everywhere.
        return StatusSymbol { .iconName = {}, .tone = StatusTone::Plain, .isSpinner = true, .spokenName = "Working" };
    case App::StatusKind::Done:
        return StatusSymbol { .iconName = "object-select-symbolic", .tone = StatusTone::Success, .spokenName = "Done" };
    case App::StatusKind::Attention:
        return StatusSymbol { .iconName = "preferences-system-notifications-symbolic", .tone = StatusTone::Accent, .spokenName = "Needs attention" };
    case App::StatusKind::Blocked:
        switch (blockKind) {
        case OSC::ProgramBlockKind::Permission:
            return StatusSymbol { .iconName = "changes-prevent-symbolic", .tone = StatusTone::Warning, .spokenName = "Waiting for permission" };
        case OSC::ProgramBlockKind::Auth:
            return StatusSymbol { .iconName = "dialog-password-symbolic", .tone = StatusTone::Warning, .spokenName = "Waiting for sign-in" };
        case OSC::ProgramBlockKind::Question:
        case OSC::ProgramBlockKind::None:
            break;
        }
        return StatusSymbol { .iconName = "dialog-question-symbolic", .tone = StatusTone::Warning, .spokenName = "Waiting for an answer" };
    case App::StatusKind::Failed:
        return StatusSymbol { .iconName = "dialog-error-symbolic", .tone = StatusTone::Error, .spokenName = "Failed" };
    }
    return std::nullopt;
}

StatusSymbol bellSymbol()
{
    return StatusSymbol { .iconName = "preferences-system-notifications-symbolic", .tone = StatusTone::Accent, .spokenName = "Bell" };
}

std::optional<StatusSymbol> PaneMarks::shownSymbol() const
{
    if (status)
        return status;
    if (hasUnheardBell)
        return bellSymbol();
    return std::nullopt;
}

} // namespace Ubiquitty::Linux::Presentation
