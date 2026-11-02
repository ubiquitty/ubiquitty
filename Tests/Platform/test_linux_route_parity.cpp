// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Core/Preferences/Preferences.h"
#include "Platform/Linux/FontRouting.h"

#include <cstdio>
#include <string>

TEST(linuxRouteParity)
{

    Ubiquitty::Preferences::Values config;
    Ubiquitty::Linux::configureFontRouting(16, config);
    const std::string sample = "東京가나다سلام😀";
    const std::string cpu = Ubiquitty::Linux::diagnoseFontRoutes(sample, "cpu");
    Ubiquitty::Linux::configureFontRouting(16, config);
    const std::string vulkan = Ubiquitty::Linux::diagnoseFontRoutes(sample, "vulkan");
    CHECK(cpu.find("renderer=cpu") != std::string::npos);
    CHECK(vulkan.find("renderer=vulkan") != std::string::npos);
    CHECK(cpu.find("script=Han") != std::string::npos);
    CHECK(cpu.find("script=Hangul") != std::string::npos);
    CHECK(cpu.find("script=Arabic") != std::string::npos);
    CHECK(cpu.find("script=Emoji") != std::string::npos);
    CHECK(cpu.find("script=Symbols") != std::string::npos);
    CHECK(vulkan.find("script=Han") != std::string::npos);
    CHECK(vulkan.find("script=Hangul") != std::string::npos);
    CHECK(vulkan.find("script=Arabic") != std::string::npos);
    CHECK(vulkan.find("script=Emoji") != std::string::npos);
    CHECK(vulkan.find("script=Symbols") != std::string::npos);
    CHECK(cpu.find("atlas=wide") != std::string::npos && vulkan.find("atlas=wide") != std::string::npos);
    CHECK(cpu.find("atlas=shaped") != std::string::npos && vulkan.find("atlas=shaped") != std::string::npos);
    CHECK(cpu.find("atlas=color") != std::string::npos && vulkan.find("atlas=color") != std::string::npos);
}

UBIQUITTY_TEST_MAIN()
