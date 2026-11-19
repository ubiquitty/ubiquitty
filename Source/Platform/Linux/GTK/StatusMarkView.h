// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Platform/Linux/GTK/GObjectPointer.h"
#include "Platform/Linux/Presentation/StatusSymbol.h"

#include <gtk/gtk.h>

#include <optional>
#include <string_view>

namespace Ubiquitty::Linux::GTK {

/// The libadwaita style class a status tone wears, so the system theme colours
/// it; empty for the surrounding ink.
[[nodiscard]] std::string_view styleClass(Presentation::StatusTone tone);

/// A pane's status mark: a themed symbolic icon coloured by libadwaita's
/// status style classes, or libadwaita's spinner for work in flight.
class StatusMarkView final {
public:
    /// - Parameter pixelSize: The mark's logical size.
    explicit StatusMarkView(int pixelSize);
    StatusMarkView(const StatusMarkView&) = delete;
    StatusMarkView& operator=(const StatusMarkView&) = delete;

    /// The view's widget, borrowed.
    [[nodiscard]] GtkWidget* widget() const { return m_root.get(); }

    /// Shows a symbol, or hides the mark.
    ///
    /// - Parameter symbol: The status to show; nothing hides the mark.
    void show(const std::optional<Presentation::StatusSymbol>& symbol);

private:
    GObjectPointer<GtkWidget> m_root;
    GtkWidget* m_image = nullptr; // owned by m_root
    GtkWidget* m_spinner = nullptr; // owned by m_root
    std::optional<Presentation::StatusSymbol> m_shown;
};

} // namespace Ubiquitty::Linux::GTK
