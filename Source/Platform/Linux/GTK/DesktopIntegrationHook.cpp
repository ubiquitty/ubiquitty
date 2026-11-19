// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/GTK/DesktopIntegrationHook.h"

#include "Platform/Linux/DesktopIntegration.h"

namespace Ubiquitty::Linux::GTK {

namespace {
constexpr const char* integratedKey = "desktop-integration-checked";
}

void integrateWithDesktop(GtkWidget* window)
{
    // Once per process: every window of the run shares the one decision. The
    // display carries the mark, as the run's other once-per-display state does.
    GdkDisplay* display = window ? gtk_widget_get_display(window) : nullptr;
    if (!display || g_object_get_data(G_OBJECT(display), integratedKey))
        return;
    g_object_set_data(G_OBJECT(display), integratedKey, GINT_TO_POINTER(1));
    const auto locations = DesktopIntegration::locate();
    if (locations && DesktopIntegration::decide(*locations) != DesktopIntegration::Decision::Leave)
        (void)DesktopIntegration::integrate(*locations);
}

} // namespace Ubiquitty::Linux::GTK
