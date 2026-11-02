// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/ConfigurationWatcher.h"

#include "Core/Preferences/Configuration.h"
#include "Core/Preferences/PreferencesPaths.h"
#include "Core/Preferences/SelfWriteGuard.h"

#include <optional>
#include <string>

namespace Ubiquitty::Linux {

ConfigurationWatcher::~ConfigurationWatcher()
{
    stop();
}

bool ConfigurationWatcher::start()
{
    if (m_monitor) {
        return true;
    }
    const auto path = Preferences::filePath();
    const auto directory = Preferences::directoryPath();
    if (!path || !directory || g_mkdir_with_parents(directory->c_str(), 0700) != 0) {
        return false;
    }
    m_file.reset(g_file_new_for_path(path->c_str()));
    const std::unique_ptr<GFile, ObjectRelease> parent(g_file_get_parent(m_file.get()));
    // Watching the name in its directory survives the inode replacement an
    // editor's atomic save performs, and sees deletion followed by recreation.
    m_monitor.reset(g_file_monitor_directory(parent.get(), G_FILE_MONITOR_WATCH_MOVES, nullptr, nullptr));
    if (!m_monitor) {
        m_file.reset();
        return false;
    }
    g_signal_connect(m_monitor.get(), "changed", G_CALLBACK(fileChanged), this);
    return true;
}

void ConfigurationWatcher::stop()
{
    if (m_reloadSource) {
        g_source_remove(m_reloadSource);
        m_reloadSource = 0;
    }
    if (m_monitor) {
        g_signal_handlers_disconnect_by_data(m_monitor.get(), this);
        g_file_monitor_cancel(m_monitor.get());
        m_monitor.reset();
    }
    m_file.reset();
}

void ConfigurationWatcher::fileChanged(GFileMonitor*, GFile* file, GFile* otherFile, GFileMonitorEvent, gpointer data)
{
    auto& watcher = *static_cast<ConfigurationWatcher*>(data);
    if ((!file || !g_file_equal(file, watcher.m_file.get()))
        && (!otherFile || !g_file_equal(otherFile, watcher.m_file.get()))) {
        return;
    }
    if (watcher.m_reloadSource) {
        g_source_remove(watcher.m_reloadSource);
    }
    // Coalesce truncate/write/close and rename bursts before parsing their
    // final document; the source is one-shot and leaves idle windows asleep.
    constexpr guint saveCoalescingMilliseconds = 100;
    watcher.m_reloadSource = g_timeout_add(saveCoalescingMilliseconds, reload, &watcher);
}

gboolean ConfigurationWatcher::reload(gpointer data)
{
    auto& watcher = *static_cast<ConfigurationWatcher*>(data);
    watcher.m_reloadSource = 0;
    char* bytes = nullptr;
    gsize length = 0;
    GError* error = nullptr;
    std::optional<std::string> document;
    if (g_file_load_contents(watcher.m_file.get(), nullptr, &bytes, &length, nullptr, &error)) {
        document.emplace(bytes, length);
    }
    g_free(bytes);
    // A file that is there and cannot be read says nothing about what the
    // person wants; reading it as the empty document would put every setting
    // back to its default. The live configuration stays, and the next save
    // that can be read is applied. Only a missing file is the empty document.
    if (error && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND)) {
        g_printerr("ubiquitty-linux: config.toml: %s; keeping the configuration in force\n", error->message);
        g_error_free(error);
        return G_SOURCE_REMOVE;
    }
    if (error) {
        g_error_free(error);
    }
    if (Preferences::selfWriteGuard().originOf(document) == Preferences::ChangeOrigin::OwnWrite) {
        return G_SOURCE_REMOVE;
    }
    // The live document is the authoritative duplicate-event check. A missing
    // file is the empty/default document, as in configureFromStoredDocument.
    const std::string body = document.value_or(std::string());
    if (body == Preferences::liveDocument()) {
        return G_SOURCE_REMOVE;
    }
    const auto result = Preferences::configure(body, Preferences::ParseMode::Permissive);
    for (const auto& diagnostic : result.diagnostics) {
        g_printerr("ubiquitty-linux: config.toml: %s\n", Preferences::diagnosticSentence(diagnostic).c_str());
    }
    return G_SOURCE_REMOVE;
}

} // namespace Ubiquitty::Linux
