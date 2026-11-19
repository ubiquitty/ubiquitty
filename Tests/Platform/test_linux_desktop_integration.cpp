// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_linux_desktop_integration.cpp — listing an AppImage among the desktop's
// applications: when a run asks, refreshes or leaves things alone, how the
// AppImage's path is quoted into Exec, and what integrating writes.

#include "Platform/Linux/DesktopIntegration.h"

#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

using namespace Ubiquitty::Linux::DesktopIntegration;
namespace fs = std::filesystem;

namespace {

constexpr const char* bundledEntry = "[Desktop Entry]\nType=Application\nName=Ubiquitty\nExec=ubiquitty\nIcon=org.ubiquitty.linux\nX-TerminalArgExec=-e\n";

// A fresh directory standing for one machine: an AppDir carrying the entry and
// two icons, a home, and a system data directory.
struct Machine {
    fs::path root;
    Locations locations;

    Machine()
    {
        std::string pattern = (fs::temp_directory_path() / "ubiquitty-integration-XXXXXX").string();
        root = ::mkdtemp(pattern.data());
        locations.appImage = root / "Downloads/Ubiquitty-0.5.0-x86_64.AppImage";
        locations.appDirectory = root / "mount";
        locations.dataHome = root / "home/.local/share";
        locations.stateHome = root / "home/.local/state";
        locations.systemDataDirectories = { root / "usr/share" };
        write(locations.appDirectory / "usr/share/applications/org.ubiquitty.linux.desktop", bundledEntry);
        write(locations.appDirectory / "usr/share/icons/hicolor/48x48/apps/org.ubiquitty.linux.png", "png");
        write(locations.appDirectory / "usr/share/icons/hicolor/scalable/apps/org.ubiquitty.linux.svg", "svg");
        write(locations.appDirectory / "usr/share/icons/hicolor/48x48/apps/someone-else.png", "other");
    }
    ~Machine()
    {
        std::error_code error;
        fs::remove_all(root, error);
    }
    Machine(const Machine&) = delete;
    Machine& operator=(const Machine&) = delete;

    static void write(const fs::path& path, const std::string& contents)
    {
        std::error_code error;
        fs::create_directories(path.parent_path(), error);
        std::ofstream(path) << contents;
    }
    static std::string read(const fs::path& path)
    {
        std::ifstream input(path);
        std::ostringstream contents;
        contents << input.rdbuf();
        return contents.str();
    }
};

} // namespace

TEST(aPlainPathIsQuotedWhole)
{
    CHECK(quotedExecArgument("/home/x/Ubiquitty.AppImage") == "\"/home/x/Ubiquitty.AppImage\"");
}

TEST(reservedCharactersAreEscapedInsideTheQuotes)
{
    // `"`, `$` and the backtick take a backslash, which the string escape then
    // doubles; a backslash itself becomes four; `%` becomes `%%`.
    CHECK_MSG(quotedExecArgument("/a b/$x\"`%") == "\"/a b/\\\\$x\\\\\"\\\\`%%\"", quotedExecArgument("/a b/$x\"`%")->c_str());
    CHECK(quotedExecArgument("/a\\b") == "\"/a\\\\\\\\b\"");
}

TEST(aPathWithAControlCharacterCannotBeListed)
{
    CHECK(!quotedExecArgument("/a\nb"));
    CHECK(!desktopEntry(bundledEntry, "/a\nb"));
}

TEST(theEntryLaunchesTheAppImageAndKeepsTheRest)
{
    const auto entry = desktopEntry(bundledEntry, "/home/x/Ubiquitty.AppImage");
    CHECK(entry.has_value());
    CHECK(entry->find("Exec=\"/home/x/Ubiquitty.AppImage\"\n") != std::string::npos);
    CHECK(entry->find("TryExec=/home/x/Ubiquitty.AppImage\n") != std::string::npos);
    CHECK(entry->find("X-Ubiquitty-AppImage=/home/x/Ubiquitty.AppImage\n") != std::string::npos);
    CHECK(entry->find("Icon=org.ubiquitty.linux\n") != std::string::npos);
    CHECK(entry->find("X-TerminalArgExec=-e\n") != std::string::npos);
    CHECK(entry->find("Exec=ubiquitty") == std::string::npos);
}

TEST(aFirstRunIntegrates)
{
    Machine machine;
    CHECK(decide(machine.locations) == Decision::Integrate);
}

TEST(anEntryTheUserRemovedStaysRemoved)
{
    Machine machine;
    CHECK(integrate(machine.locations));
    std::error_code error;
    fs::remove(entryPath(machine.locations.dataHome), error);
    CHECK(decide(machine.locations) == Decision::Leave);
}

TEST(aPackagesEntryIsLeftToTheDesktop)
{
    Machine machine;
    Machine::write(entryPath(machine.root / "usr/share"), bundledEntry);
    CHECK(decide(machine.locations) == Decision::Leave);
}

TEST(theUsersOwnEntryIsLeftAlone)
{
    Machine machine;
    Machine::write(entryPath(machine.locations.dataHome), "[Desktop Entry]\nExec=/opt/ubiquitty/bin/ubiquitty\n");
    CHECK(decide(machine.locations) == Decision::Leave);
}

TEST(integratingWritesTheEntryAndThisAppsIcons)
{
    Machine machine;
    CHECK(integrate(machine.locations));
    const std::string entry = Machine::read(entryPath(machine.locations.dataHome));
    CHECK(entry.find("X-Ubiquitty-AppImage=" + machine.locations.appImage.string()) != std::string::npos);
    const fs::path icons = machine.locations.dataHome / "icons/hicolor";
    CHECK(fs::exists(icons / "48x48/apps/org.ubiquitty.linux.png"));
    CHECK(fs::exists(icons / "scalable/apps/org.ubiquitty.linux.svg"));
    CHECK(!fs::exists(icons / "48x48/apps/someone-else.png"));
    CHECK(decide(machine.locations) == Decision::Leave);
}

TEST(anEntryForAMovedAppImageIsRefreshed)
{
    Machine machine;
    CHECK(integrate(machine.locations));
    machine.locations.appImage = machine.root / "Applications/Ubiquitty-0.5.1-x86_64.AppImage";
    CHECK(decide(machine.locations) == Decision::Refresh);
    CHECK(integrate(machine.locations));
    CHECK(decide(machine.locations) == Decision::Leave);
}

TEST(anEntryAnotherIntegratorWroteIsRefreshedToo)
{
    Machine machine;
    Machine::write(entryPath(machine.locations.dataHome), "[Desktop Entry]\nExec=\"/old/Ubiquitty.AppImage\"\nTryExec=/old/Ubiquitty.AppImage\n");
    CHECK(decide(machine.locations) == Decision::Refresh);
}

UBIQUITTY_TEST_MAIN()
