// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/DesktopIntegration.h"

#include "Platform/Linux/Updater.h"

#include <cstdlib>
#include <fstream>
#include <sstream>
#include <system_error>

namespace Ubiquitty::Linux::DesktopIntegration {

namespace {

namespace fs = std::filesystem;

// The name the desktop entry, the icons and the GtkApplication id share.
constexpr std::string_view applicationID = "org.ubiquitty.linux";
// The key that marks an entry as this integration's, naming the AppImage it
// was written for.
constexpr std::string_view appImageKey = "X-Ubiquitty-AppImage";
// Present once an entry has been written for this user: an entry missing while
// it is present was removed on purpose, and is not written back.
constexpr std::string_view integratedFile = "desktop-integration";

// An XDG base directory: the variable when it holds an absolute path, which
// the specification requires, else the fallback under home.
fs::path baseDirectory(const char* variable, std::string_view fallbackUnderHome)
{
    if (const char* value = std::getenv(variable); value && value[0] == '/')
        return value;
    const char* home = std::getenv("HOME");
    return home && home[0] == '/' ? fs::path(home) / fallbackUnderHome : fs::path();
}

std::optional<std::string> readFile(const fs::path& path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
        return std::nullopt;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

bool hasControlCharacter(std::string_view text)
{
    for (const char character : text) {
        if (static_cast<unsigned char>(character) < 0x20 || character == 0x7F)
            return true;
    }
    return false;
}

// A value of type string: the specification's escapes for the backslash and
// the whitespace controls, of which only the backslash can reach here.
std::string escapedString(std::string_view text)
{
    std::string escaped;
    for (const char character : text) {
        if (character == '\\')
            escaped += '\\';
        escaped += character;
    }
    return escaped;
}

// The value a key holds in the entry's main group, or nothing.
std::optional<std::string> mainGroupValue(std::string_view entry, std::string_view key)
{
    bool isInMainGroup = false;
    std::istringstream lines { std::string(entry) };
    for (std::string line; std::getline(lines, line);) {
        if (line.starts_with('['))
            isInMainGroup = line == "[Desktop Entry]";
        else if (isInMainGroup && line.size() > key.size() && line.starts_with(key) && line[key.size()] == '=')
            return line.substr(key.size() + 1);
    }
    return std::nullopt;
}

// The string escape undone, for comparing a stored path with a real one.
std::string unescapedString(std::string_view text)
{
    std::string plain;
    for (std::size_t index = 0; index < text.size(); ++index) {
        if (text[index] == '\\' && index + 1 < text.size() && text[index + 1] == '\\')
            ++index;
        plain += text[index];
    }
    return plain;
}

// The AppImage an entry in the user's directory launches, when the entry is
// one an AppImage integration wrote: marked by this one, or — written by hand
// or by another integrator — trying an `.AppImage` file.
std::optional<std::string> integratedAppImage(std::string_view entry)
{
    if (const auto marked = mainGroupValue(entry, appImageKey))
        return unescapedString(*marked);
    if (const auto tried = mainGroupValue(entry, "TryExec"); tried && tried->ends_with(".AppImage"))
        return unescapedString(*tried);
    return std::nullopt;
}

bool writeAtomically(const fs::path& path, std::string_view contents)
{
    std::error_code error;
    fs::create_directories(path.parent_path(), error);
    if (error)
        return false;
    fs::path temporary = path;
    temporary += ".new";
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output)
            return false;
        output << contents;
        if (!output.flush())
            return false;
    }
    fs::rename(temporary, path, error);
    if (error) {
        fs::remove(temporary, error);
        return false;
    }
    return true;
}

// Copies the image's hicolor icons for the application beside the user's other
// icons, size by size, as the desktop's icon theme looks them up.
void copyIcons(const fs::path& appDirectory, const fs::path& dataHome)
{
    const fs::path source = appDirectory / "usr/share/icons/hicolor";
    const fs::path destination = dataHome / "icons/hicolor";
    std::error_code error;
    // The application's icons from an earlier image go first: a size this
    // image no longer ships would otherwise be preferred over its scalable one.
    for (fs::directory_iterator size(destination, error), end; !error && size != end; size.increment(error)) {
        for (fs::directory_iterator icon(size->path() / "apps", error), last; !error && icon != last; icon.increment(error)) {
            if (icon->path().stem() == applicationID || icon->path().stem() == std::string(applicationID) + "-symbolic") {
                std::error_code removeError;
                fs::remove(icon->path(), removeError);
            }
        }
        error.clear();
    }
    for (fs::directory_iterator size(source, error), end; !error && size != end; size.increment(error)) {
        const fs::path apps = size->path() / "apps";
        for (fs::directory_iterator icon(apps, error), last; !error && icon != last; icon.increment(error)) {
            if (icon->path().stem() != applicationID && icon->path().stem() != std::string(applicationID) + "-symbolic")
                continue;
            const fs::path target = destination / size->path().filename() / "apps" / icon->path().filename();
            std::error_code copyError;
            fs::create_directories(target.parent_path(), copyError);
            fs::copy_file(icon->path(), target, fs::copy_options::overwrite_existing, copyError);
        }
        error.clear();
    }
}

} // namespace

std::optional<Locations> locate()
{
    const std::string appImage = Updater::appImagePath();
    const std::string appDirectory = Updater::appDirectory();
    if (appImage.empty() || appDirectory.empty())
        return std::nullopt;
    Locations locations;
    locations.appImage = appImage;
    locations.appDirectory = appDirectory;
    locations.dataHome = baseDirectory("XDG_DATA_HOME", ".local/share");
    locations.stateHome = baseDirectory("XDG_STATE_HOME", ".local/state");
    if (locations.dataHome.empty() || locations.stateHome.empty())
        return std::nullopt;
    const char* systemDirectories = std::getenv("XDG_DATA_DIRS");
    std::istringstream directories(systemDirectories && systemDirectories[0] ? systemDirectories : "/usr/local/share:/usr/share");
    for (std::string directory; std::getline(directories, directory, ':');) {
        if (directory.starts_with('/'))
            locations.systemDataDirectories.emplace_back(directory);
    }
    return locations;
}

fs::path entryPath(const fs::path& dataHome)
{
    return dataHome / "applications" / (std::string(applicationID) + ".desktop");
}

Decision decide(const Locations& locations)
{
    std::error_code error;
    // A package's entry is the desktop's to show; an AppImage does not shadow it.
    for (const fs::path& directory : locations.systemDataDirectories) {
        if (fs::exists(entryPath(directory), error))
            return Decision::Leave;
    }
    if (const auto entry = readFile(entryPath(locations.dataHome))) {
        const auto launched = integratedAppImage(*entry);
        // An entry the user wrote is theirs, whatever it launches.
        if (!launched)
            return Decision::Leave;
        return fs::path(*launched).lexically_normal() == locations.appImage.lexically_normal() ? Decision::Leave : Decision::Refresh;
    }
    if (fs::exists(locations.stateHome / "ubiquitty" / integratedFile, error))
        return Decision::Leave;
    return Decision::Integrate;
}

std::optional<std::string> quotedExecArgument(std::string_view path)
{
    if (hasControlCharacter(path))
        return std::nullopt;
    std::string quoted = "\"";
    for (const char character : path) {
        if (character == '"' || character == '`' || character == '$' || character == '\\')
            quoted += '\\';
        quoted += character;
    }
    quoted += '"';
    // The string escape applies before the quoting rule, so each backslash
    // the quoting wrote is doubled; then no `%` may read as a field code.
    std::string argument;
    for (const char character : quoted) {
        if (character == '\\')
            argument += "\\\\";
        else if (character == '%')
            argument += "%%";
        else
            argument += character;
    }
    return argument;
}

std::optional<std::string> desktopEntry(std::string_view bundledEntry, const fs::path& appImage)
{
    const std::string path = appImage.string();
    const auto program = quotedExecArgument(path);
    if (!program)
        return std::nullopt;
    std::string entry;
    bool isInMainGroup = false;
    std::istringstream lines { std::string(bundledEntry) };
    for (std::string line; std::getline(lines, line);) {
        if (line.starts_with('['))
            isInMainGroup = line == "[Desktop Entry]";
        if (isInMainGroup && (line.starts_with("TryExec=") || line.starts_with(std::string(appImageKey) + "=")))
            continue;
        if (isInMainGroup && line.starts_with("Exec=")) {
            // The image's own program is replaced; its arguments stay.
            const std::string command = line.substr(5);
            const std::size_t space = command.find(' ');
            entry += "Exec=" + *program + (space == std::string::npos ? std::string() : command.substr(space)) + "\n";
            entry += "TryExec=" + escapedString(path) + "\n";
            entry += std::string(appImageKey) + "=" + escapedString(path) + "\n";
            continue;
        }
        entry += line + "\n";
    }
    return entry;
}

bool integrate(const Locations& locations)
{
    const auto bundled = readFile(locations.appDirectory / "usr/share/applications" / (std::string(applicationID) + ".desktop"));
    if (!bundled)
        return false;
    const auto entry = desktopEntry(*bundled, locations.appImage);
    if (!entry || !writeAtomically(entryPath(locations.dataHome), *entry))
        return false;
    copyIcons(locations.appDirectory, locations.dataHome);
    (void)writeAtomically(locations.stateHome / "ubiquitty" / integratedFile, "");
    return true;
}

} // namespace Ubiquitty::Linux::DesktopIntegration
