// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <glib-unix.h>

namespace Ubiquitty::Linux {

/// Watches PTY input without starving GTK's pending layout and redraw sources.
///
/// - Parameters:
///   - fileDescriptor: Borrowed PTY master descriptor.
///   - callback: Drains one bounded pass and decides whether to retain the watch.
///   - context: Borrowed callback state, valid until the source is removed.
/// - Returns: The source ID the caller removes before releasing the descriptor or state.
[[nodiscard]] inline guint addPTYReadWatch(int fileDescriptor, GUnixFDSourceFunc callback, gpointer context)
{
    // A flooding PTY stays ready across main-context iterations. Sharing GTK's
    // documented redraw priority lets both sources advance in the same turn.
    return g_unix_fd_add_full(G_PRIORITY_HIGH_IDLE + 20, fileDescriptor,
        static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR), callback, context, nullptr);
}

} // namespace Ubiquitty::Linux
