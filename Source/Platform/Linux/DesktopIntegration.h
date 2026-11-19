// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// DesktopIntegration — listing an AppImage among the desktop's applications.
//
// A desktop shows an application's name and icon from a desktop entry it finds
// in its data directories; an AppImage carries both inside its image, where
// the desktop never looks. Integrating copies them out: the entry, with Exec
// naming the AppImage file, into the user's data directory, and the hicolor
// icons beside it. It is done without asking, as a package would install them:
// files in the user's own data directory, nothing started and nothing run.
// Once only — an entry the user removes stays removed. The policy is here,
// toolkit-free, so a Qt frontend would decide the same.

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace Ubiquitty::Linux::DesktopIntegration {

/// Where an AppImage runs from, and where the desktop looks for entries.
struct Locations {
    /// The AppImage file, as the kernel's mount table names it.
    std::filesystem::path appImage;
    /// The AppDir the image is mounted at, as `/proc/self/exe` places it.
    std::filesystem::path appDirectory;
    /// `$XDG_DATA_HOME`, or `~/.local/share`: where the entry is written.
    std::filesystem::path dataHome;
    /// `$XDG_DATA_DIRS`: where a package would have installed an entry.
    std::vector<std::filesystem::path> systemDataDirectories;
    /// `$XDG_STATE_HOME`, or `~/.local/state`: where a past integration is noted.
    std::filesystem::path stateHome;
};

/// What to do about integration when an AppImage window opens.
enum class Decision : std::uint8_t {
    /// Nothing: not an AppImage, a package or the user owns the entry, it
    /// already names this AppImage, or the user removed an entry this
    /// integration wrote.
    Leave,
    /// List the application: nothing lists it, and it never has been.
    Integrate,
    /// Rewrite an entry this integration wrote before: the AppImage moved or
    /// an update renamed it, and the entry would launch a file that is gone.
    Refresh,
};

/// The locations of this process's AppImage run.
///
/// - Returns: The locations, or nothing unless this process runs from a
///   packaged AppImage whose file and AppDir the kernel vouches for.
[[nodiscard]] std::optional<Locations> locate();

/// Decides what to do for one run.
///
/// - Parameter locations: The run's locations.
/// - Returns: The decision.
[[nodiscard]] Decision decide(const Locations& locations);

/// The path the user's desktop entry for the application has.
///
/// - Parameter dataHome: The user's data directory.
/// - Returns: The entry's path.
[[nodiscard]] std::filesystem::path entryPath(const std::filesystem::path& dataHome);

/// Quotes a path as one argument of a desktop entry's Exec key.
///
/// Quoted per the Desktop Entry Specification: the reserved characters an
/// unquoted argument cannot hold stop mattering inside double quotes, which
/// leave `"`, `` ` ``, `$` and `\` to escape; the key's string escaping then
/// doubles each backslash, and `%` becomes `%%` so no field code is read in
/// a file name.
///
/// - Parameter path: The path.
/// - Returns: The argument, or nothing for a path holding a control
///   character, which no desktop entry can carry.
[[nodiscard]] std::optional<std::string> quotedExecArgument(std::string_view path);

/// The desktop entry for an AppImage, made from the entry the image carries.
///
/// The carried entry's Exec program is replaced by the AppImage, its TryExec
/// set to the AppImage, and the entry marked with the AppImage it was written
/// for, which is how a later run recognises an entry of its own.
///
/// - Parameters:
///   - bundledEntry: The entry the image carries.
///   - appImage: The AppImage file.
/// - Returns: The entry, or nothing for a path no entry can carry.
[[nodiscard]] std::optional<std::string> desktopEntry(std::string_view bundledEntry, const std::filesystem::path& appImage);

/// Writes the entry and copies the icons, and notes that this user has had
/// the application listed, so an entry they remove stays removed.
///
/// - Parameter locations: The run's locations.
/// - Returns: Whether the entry was written. Icons that fail to copy leave the
///   entry in place; the desktop shows its generic icon for them.
bool integrate(const Locations& locations);

} // namespace Ubiquitty::Linux::DesktopIntegration
