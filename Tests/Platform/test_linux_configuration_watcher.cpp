// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Core/Preferences/Configuration.h"
#include "Core/Preferences/PreferencesPaths.h"
#include "Core/Preferences/SelfWriteGuard.h"
#include "Helpers/TempDir.h"
#include "Platform/Linux/ConfigurationWatcher.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <string>

namespace {

using namespace std::chrono_literals;

class ConfigurationHome {
public:
    ConfigurationHome()
    {
        CHECK(m_directory.valid());
        if (const char* previous = std::getenv("XDG_CONFIG_HOME")) {
            m_previousHome = previous;
        }
        CHECK_EQ(::setenv("XDG_CONFIG_HOME", m_directory.path().c_str(), 1), 0);
        (void)Ubiquitty::Preferences::configure("", Ubiquitty::Preferences::ParseMode::Strict);
        (void)Ubiquitty::Preferences::selfWriteGuard().originOf(std::nullopt);
    }

    ~ConfigurationHome()
    {
        if (m_previousHome) {
            (void)::setenv("XDG_CONFIG_HOME", m_previousHome->c_str(), 1);
        } else {
            (void)::unsetenv("XDG_CONFIG_HOME");
        }
    }

    [[nodiscard]] std::string path() const { return m_directory.path() + "/ubiquitty/config.toml"; }
    [[nodiscard]] std::string siblingPath() const { return m_directory.path() + "/ubiquitty/editor-save.toml"; }

private:
    Ubiquitty::Test::TempDir m_directory;
    std::optional<std::string> m_previousHome;
};

void writeFile(const std::string& path, const std::string& body)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    CHECK(output.is_open());
    output << body;
    output.close();
    CHECK(!output.fail());
}

void pumpFor(std::chrono::milliseconds duration)
{
    const auto deadline = std::chrono::steady_clock::now() + duration;
    do {
        while (g_main_context_iteration(nullptr, false)) {
        }
        g_usleep(1000);
    } while (std::chrono::steady_clock::now() < deadline);
}

template<typename Predicate>
bool waitUntil(Predicate predicate)
{
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    do {
        while (g_main_context_iteration(nullptr, false)) {
        }
        if (predicate()) {
            return true;
        }
        g_usleep(1000);
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
}

std::string fontDocument(int size)
{
    return "[font]\nsize = " + std::to_string(size) + "\n";
}

} // namespace

TEST(externalConfigurationCreationAndInPlaceSaveReachEverySubscriber)
{
    ConfigurationHome home;
    Ubiquitty::Linux::ConfigurationWatcher watcher;
    CHECK(watcher.start());
    CHECK(watcher.start());
    int firstDeliveries = 0;
    int secondDeliveries = 0;
    double firstSize = 0;
    double secondSize = 0;
    Ubiquitty::Preferences::ConfigurationSubscription first([&](const auto& values) {
        ++firstDeliveries;
        firstSize = values.fontSize.value_or(0);
    });
    Ubiquitty::Preferences::ConfigurationSubscription second([&](const auto& values) {
        ++secondDeliveries;
        secondSize = values.fontSize.value_or(0);
    });

    writeFile(home.path(), fontDocument(19) + "[cursor]\nblink = false\n");
    CHECK(waitUntil([&] { return firstSize == 19 && secondSize == 19; }));
    CHECK(Ubiquitty::Preferences::values().cursorBlink == false);
    pumpFor(350ms);
    CHECK_EQ(firstDeliveries, 1);
    CHECK_EQ(secondDeliveries, 1);

    writeFile(home.path(), fontDocument(23));
    CHECK(waitUntil([&] { return firstSize == 23 && secondSize == 23; }));
    CHECK(!Ubiquitty::Preferences::values().cursorBlink.has_value());
    pumpFor(350ms);
    CHECK_EQ(firstDeliveries, 2);
    CHECK_EQ(secondDeliveries, 2);
}

TEST(atomicConfigurationReplacementsAndRenameAwayKeepMonitoringTheName)
{
    ConfigurationHome home;
    Ubiquitty::Linux::ConfigurationWatcher watcher;
    CHECK(watcher.start());
    for (int size : { 19, 23, 27 }) {
        writeFile(home.siblingPath(), fontDocument(size));
        CHECK_EQ(std::rename(home.siblingPath().c_str(), home.path().c_str()), 0);
        CHECK(waitUntil([&] { return Ubiquitty::Preferences::values().fontSize == size; }));
    }

    CHECK_EQ(std::rename(home.path().c_str(), home.siblingPath().c_str()), 0);
    CHECK(waitUntil([] { return Ubiquitty::Preferences::liveDocument().empty(); }));
    CHECK(!Ubiquitty::Preferences::values().fontSize.has_value());
    CHECK_EQ(std::rename(home.siblingPath().c_str(), home.path().c_str()), 0);
    CHECK(waitUntil([] { return Ubiquitty::Preferences::values().fontSize == 27; }));

    CHECK_EQ(std::remove(home.path().c_str()), 0);
    CHECK(waitUntil([] { return Ubiquitty::Preferences::liveDocument().empty(); }));
    writeFile(home.path(), fontDocument(31));
    CHECK(waitUntil([] { return Ubiquitty::Preferences::values().fontSize == 31; }));
}

TEST(ownWritesAndUnrelatedFilesDoNotReloadConfiguration)
{
    ConfigurationHome home;
    Ubiquitty::Linux::ConfigurationWatcher watcher;
    CHECK(watcher.start());
    const auto configured = Ubiquitty::Preferences::configureOwnDocument(fontDocument(21));
    CHECK(configured.isApplied);
    pumpFor(500ms);
    CHECK_EQ(Ubiquitty::Preferences::configurationEpoch(), configured.epoch);
    CHECK(Ubiquitty::Preferences::selfWriteGuard().hasOwnWrite());

    writeFile(home.siblingPath(), fontDocument(35));
    pumpFor(350ms);
    CHECK_EQ(Ubiquitty::Preferences::configurationEpoch(), configured.epoch);

    writeFile(home.path(), fontDocument(25));
    CHECK(waitUntil([] { return Ubiquitty::Preferences::values().fontSize == 25; }));
    CHECK(!Ubiquitty::Preferences::selfWriteGuard().hasOwnWrite());
}

TEST(stoppingAndDestroyingConfigurationWatcherCancelQueuedReloads)
{
    ConfigurationHome home;
    const auto openingEpoch = Ubiquitty::Preferences::configurationEpoch();
    {
        Ubiquitty::Linux::ConfigurationWatcher watcher;
        CHECK(watcher.start());
        writeFile(home.path(), fontDocument(29));
        pumpFor(25ms);
        watcher.stop();
        watcher.stop();
        pumpFor(250ms);
        CHECK_EQ(Ubiquitty::Preferences::configurationEpoch(), openingEpoch);

        CHECK(watcher.start());
        writeFile(home.path(), fontDocument(33));
        pumpFor(25ms);
    }
    pumpFor(250ms);
    CHECK_EQ(Ubiquitty::Preferences::configurationEpoch(), openingEpoch);

    Ubiquitty::Linux::ConfigurationWatcher restarted;
    CHECK(restarted.start());
    writeFile(home.path(), fontDocument(37));
    CHECK(waitUntil([] { return Ubiquitty::Preferences::values().fontSize == 37; }));
}

UBIQUITTY_TEST_MAIN()
