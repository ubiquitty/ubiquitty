// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <gio/gio.h>
#include <memory>

namespace Ubiquitty::Linux {

/// Delivers external configuration saves to Core on the GTK main context.
class ConfigurationWatcher {
public:
    ConfigurationWatcher() = default;
    /// Cancels callbacks before releasing the watched file and monitor.
    ~ConfigurationWatcher();
    ConfigurationWatcher(const ConfigurationWatcher&) = delete;
    ConfigurationWatcher& operator=(const ConfigurationWatcher&) = delete;

    /// Watches the configured file's directory, including an absent file.
    ///
    /// - Returns: Whether the directory monitor is active.
    [[nodiscard]] bool start();
    /// Cancels monitoring and any queued reload before returning.
    void stop();

private:
    /// Releases the owned GObject reference when its holder resets.
    struct ObjectRelease {
        void operator()(gpointer object) const { g_object_unref(object); }
    };

    /// Coalesces path changes while the monitor borrows this watcher as callback data.
    static void fileChanged(GFileMonitor*, GFile*, GFile*, GFileMonitorEvent, gpointer);
    /// Applies the queued document and removes the source borrowing this watcher.
    ///
    /// - Returns: `G_SOURCE_REMOVE` to release the one-shot source.
    static gboolean reload(gpointer);

    std::unique_ptr<GFile, ObjectRelease> m_file;
    std::unique_ptr<GFileMonitor, ObjectRelease> m_monitor;
    guint m_reloadSource = 0;
};

} // namespace Ubiquitty::Linux
