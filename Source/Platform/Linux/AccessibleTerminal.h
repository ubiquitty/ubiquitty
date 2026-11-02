// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Base/Geometry.h"
#include "Platform/Linux/Accessibility.h"

#include <gtk/gtk.h>

namespace Ubiquitty::Linux::Accessibility {

/// Creates an AT-SPI terminal element with no visual text layout.
/// - Returns: A floating widget reference, adopted by its GTK parent.
[[nodiscard]] GtkWidget* createTerminal();

/// Publishes the visible text and its cell-to-widget transform.
/// - Parameters:
///   - widget: The terminal element created by ``createTerminal``.
///   - snapshot: Owned text and character coordinates from the displayed grid.
///   - origin: Grid origin in widget coordinates.
///   - cell: Cell extent in widget coordinates, including presentation scale.
void updateTerminal(GtkWidget* widget, Snapshot snapshot, FloatPoint origin, FloatSize cell);

} // namespace Ubiquitty::Linux::Accessibility
