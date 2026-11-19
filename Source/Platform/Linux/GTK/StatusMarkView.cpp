// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/StatusMarkView.h"

#include <adwaita.h>

#include <array>
#include <string>

namespace Ubiquitty::Linux::GTK {

using Presentation::StatusSymbol;
using Presentation::StatusTone;

std::string_view styleClass(StatusTone tone)
{
    switch (tone) {
    case StatusTone::Dim:
        return "dim-label";
    case StatusTone::Plain:
        return "";
    case StatusTone::Accent:
        return "accent";
    case StatusTone::Success:
        return "success";
    case StatusTone::Warning:
        return "warning";
    case StatusTone::Error:
        return "error";
    }
    return "";
}

StatusMarkView::StatusMarkView(int pixelSize)
    : m_root(adoptSunk(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)))
    , m_image(gtk_image_new())
    , m_spinner(adw_spinner_new())
{
    gtk_widget_add_css_class(m_root.get(), "ubiquitty-status-mark");
    gtk_widget_set_valign(m_root.get(), GTK_ALIGN_CENTER);
    gtk_image_set_pixel_size(GTK_IMAGE(m_image), pixelSize);
    gtk_widget_set_size_request(m_spinner, pixelSize, pixelSize);
    gtk_box_append(GTK_BOX(m_root.get()), m_image);
    gtk_box_append(GTK_BOX(m_root.get()), m_spinner);
    gtk_widget_set_visible(m_root.get(), FALSE);
}

void StatusMarkView::show(const std::optional<StatusSymbol>& symbol)
{
    if (symbol == m_shown)
        return;
    m_shown = symbol;
    GtkWidget* root = m_root.get();
    for (const StatusTone tone : std::array { StatusTone::Dim, StatusTone::Accent, StatusTone::Success, StatusTone::Warning, StatusTone::Error })
        gtk_widget_remove_css_class(root, std::string(styleClass(tone)).c_str());
    if (!symbol) {
        // An unmapped AdwSpinner stops animating, so a hidden mark costs nothing.
        gtk_widget_set_visible(root, FALSE);
        return;
    }
    if (const std::string_view style = styleClass(symbol->tone); !style.empty())
        gtk_widget_add_css_class(root, std::string(style).c_str());
    gtk_widget_set_visible(m_image, !symbol->isSpinner);
    gtk_widget_set_visible(m_spinner, symbol->isSpinner);
    if (!symbol->isSpinner)
        gtk_image_set_from_icon_name(GTK_IMAGE(m_image), std::string(symbol->iconName).c_str());
    const std::string spoken(symbol->spokenName);
    gtk_widget_set_tooltip_text(root, spoken.c_str());
    gtk_accessible_update_property(GTK_ACCESSIBLE(root), GTK_ACCESSIBLE_PROPERTY_LABEL, spoken.c_str(), -1);
    gtk_widget_set_visible(root, TRUE);
}

} // namespace Ubiquitty::Linux::GTK
