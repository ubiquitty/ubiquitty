// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <gtk/gtk.h>

namespace Ubiquitty::Linux::GTK {

/// The icon name the desktop entry, the GtkApplication id and every window share.
inline constexpr const char* applicationIconName = "org.ubiquitty.linux";

/// Makes the bundled app icon the default for every window on a display.
///
/// The icon theme is taught both places the build puts the hicolor icons: the
/// `icons/` beside a build tree's binary and an install prefix's `share/icons`,
/// so a run that was never installed — or was installed under a prefix the
/// desktop does not search — still shows its own icon in the About dialog and
/// on an X11 window. Idempotent per display.
///
/// - Parameter display: The display the windows open on.
void registerApplicationIcon(GdkDisplay* display);

} // namespace Ubiquitty::Linux::GTK
