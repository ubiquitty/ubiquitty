// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/WindowTitleView.h"

#include "Core/App/ProcessIconPlate.h"

#include <string>

namespace Ubiquitty::Linux::GTK {

using Presentation::ChromeGround;
using Presentation::PaneMarks;
using Presentation::WindowTitleContent;

namespace {

constexpr int iconPixelSize = 16;
constexpr int statusPixelSize = 12;

GtkWidget* makeLabel(const char* styleClass, PangoEllipsizeMode ellipsize)
{
    GtkWidget* label = gtk_label_new(nullptr);
    gtk_widget_add_css_class(label, styleClass);
    gtk_label_set_single_line_mode(GTK_LABEL(label), TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(label), ellipsize);
    // Narrow enough that the header's side buttons are never pushed away.
    gtk_label_set_width_chars(GTK_LABEL(label), 4);
    return label;
}

void setText(GtkWidget* label, const std::string& text)
{
    gtk_label_set_text(GTK_LABEL(label), text.c_str());
    gtk_widget_set_visible(label, !text.empty());
}

} // namespace

WindowTitleView::WindowTitleView(ProcessIconLoader& icons)
    : m_icons(icons)
    , m_root(adoptSunk(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)))
    , m_status(statusPixelSize)
    , m_icon(gtk_image_new())
    , m_title(makeLabel("title", PANGO_ELLIPSIZE_END))
    , m_subtitleRow(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4))
    , m_directory(makeLabel("subtitle", PANGO_ELLIPSIZE_START))
    , m_separator(makeLabel("subtitle", PANGO_ELLIPSIZE_NONE))
    , m_statusText(makeLabel("subtitle", PANGO_ELLIPSIZE_END))
{
    GtkWidget* root = m_root.get();
    gtk_widget_add_css_class(root, "ubiquitty-window-title");
    gtk_widget_set_halign(root, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(root, GTK_ALIGN_CENTER);

    gtk_image_set_pixel_size(GTK_IMAGE(m_icon), iconPixelSize);
    gtk_widget_add_css_class(m_icon, "ubiquitty-process-icon");
    gtk_widget_set_valign(m_icon, GTK_ALIGN_CENTER);
    gtk_widget_set_visible(m_icon, FALSE);

    GtkWidget* lines = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_valign(lines, GTK_ALIGN_CENTER);
    gtk_widget_set_hexpand(lines, TRUE);
    gtk_box_append(GTK_BOX(lines), m_title);
    gtk_widget_set_halign(m_subtitleRow, GTK_ALIGN_CENTER);
    gtk_label_set_text(GTK_LABEL(m_separator), "·");
    gtk_accessible_update_state(GTK_ACCESSIBLE(m_separator), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);
    gtk_box_append(GTK_BOX(m_subtitleRow), m_directory);
    gtk_box_append(GTK_BOX(m_subtitleRow), m_separator);
    gtk_box_append(GTK_BOX(m_subtitleRow), m_status.widget());
    gtk_box_append(GTK_BOX(m_subtitleRow), m_statusText);
    gtk_box_append(GTK_BOX(lines), m_subtitleRow);

    gtk_box_append(GTK_BOX(root), m_icon);
    gtk_box_append(GTK_BOX(root), lines);
}

void WindowTitleView::showIcon(const PaneMarks& marks, const ChromeGround& ground)
{
    GIcon* icon = m_icons.icon(marks.processIconKey, ground);
    if (!icon) {
        gtk_image_clear(GTK_IMAGE(m_icon));
        gtk_widget_set_visible(m_icon, FALSE);
        return;
    }
    gtk_image_set_from_gicon(GTK_IMAGE(m_icon), icon);
    // Core decides when a logo in its own colours needs a plate to be made out.
    if (App::processIconNeedsPlate(marks.processIconKey, ground.groundRGB))
        gtk_widget_add_css_class(m_icon, "plate");
    else
        gtk_widget_remove_css_class(m_icon, "plate");
    gtk_widget_set_tooltip_text(m_icon, marks.processIconTitle.c_str());
    gtk_accessible_update_property(GTK_ACCESSIBLE(m_icon), GTK_ACCESSIBLE_PROPERTY_LABEL, marks.processIconTitle.c_str(), -1);
    gtk_widget_set_visible(m_icon, TRUE);
}

void WindowTitleView::show(const WindowTitleContent& content, const PaneMarks& marks, const ChromeGround& ground)
{
    showIcon(marks, ground);
    gtk_label_set_text(GTK_LABEL(m_title), content.title.c_str());
    setText(m_directory, content.directory);
    setText(m_statusText, content.status);
    const std::optional<Presentation::StatusSymbol> symbol = marks.shownSymbol();
    m_status.show(symbol);
    const bool hasStatus = symbol || !content.status.empty();
    gtk_widget_set_visible(m_separator, !content.directory.empty() && hasStatus);
    gtk_widget_set_visible(m_subtitleRow, !content.directory.empty() || hasStatus);

    // Full text on hover: either line may be ellipsized.
    std::string tooltip = content.title;
    for (const std::string* part : { &content.directory, &content.status }) {
        if (!part->empty())
            tooltip += "\n" + *part;
    }
    gtk_widget_set_tooltip_text(m_root.get(), tooltip.c_str());
}

} // namespace Ubiquitty::Linux::GTK
