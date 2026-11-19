// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/ApplicationIcon.h"

#include "Platform/Linux/BundledFontDirectory.h"

#include <string>

namespace Ubiquitty::Linux::GTK {

namespace {
constexpr const char* registeredKey = "ubiquitty-application-icon";
}

void registerApplicationIcon(GdkDisplay* display)
{
    if (!display || g_object_get_data(G_OBJECT(display), registeredKey))
        return;
    g_object_set_data(G_OBJECT(display), registeredKey, GINT_TO_POINTER(1));
    // The executable's directory: the build tree, or an install prefix's bin.
    const std::string binary = bundledFontDirectory();
    if (!binary.empty()) {
        GtkIconTheme* theme = gtk_icon_theme_get_for_display(display);
        gtk_icon_theme_add_search_path(theme, (binary + "/icons").c_str());
        gtk_icon_theme_add_search_path(theme, (binary + "/../share/icons").c_str());
    }
    gtk_window_set_default_icon_name(applicationIconName);
}

} // namespace Ubiquitty::Linux::GTK
