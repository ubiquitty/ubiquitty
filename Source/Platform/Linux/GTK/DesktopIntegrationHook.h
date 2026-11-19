// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <gtk/gtk.h>

namespace Ubiquitty::Linux::GTK {

/// Lists an AppImage among the desktop's applications, once per process, as
/// `DesktopIntegration` decides: writes the entry and icons when nothing
/// lists it and nothing ever has, and points an entry it wrote before at the
/// AppImage once the file has moved. Does nothing outside an AppImage.
///
/// - Parameter window: A window of the run, whose display carries the
///   once-per-process mark.
void integrateWithDesktop(GtkWidget* window);

} // namespace Ubiquitty::Linux::GTK
