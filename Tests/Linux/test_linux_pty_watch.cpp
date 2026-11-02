// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "PAL/UnixFileDescriptor.h"
#include "Platform/Linux/PTYWatch.h"

#include <array>

TEST(aContinuouslyReadablePTYAllowsPendingRedrawsAndContinuesDraining)
{
    std::array<int, 2> descriptors { -1, -1 };
    REQUIRE(::pipe(descriptors.data()) == 0);
    Ubiquitty::PAL::UnixFileDescriptor reader(descriptors[0]);
    Ubiquitty::PAL::UnixFileDescriptor writer(descriptors[1]);
    REQUIRE(::write(writer.get(), "x", 1) == 1);

    int drains = 0;
    int redraws = 0;
    const guint readSource = Ubiquitty::Linux::addPTYReadWatch(reader.get(), [](int, GIOCondition, gpointer context) -> gboolean {
            ++*static_cast<int*>(context);
            // Leave the byte queued: the descriptor stays ready like a PTY flood.
            return G_SOURCE_CONTINUE; }, &drains);
    const guint redrawSource = g_idle_add_full(G_PRIORITY_HIGH_IDLE + 20, [](gpointer context) -> gboolean {
            ++*static_cast<int*>(context);
            return G_SOURCE_REMOVE; }, &redraws, nullptr);
    for (int iteration = 0; iteration < 8; ++iteration)
        g_main_context_iteration(nullptr, false);
    g_source_remove(readSource);
    if (redraws == 0)
        g_source_remove(redrawSource);

    CHECK_EQ(redraws, 1);
    CHECK(drains > 0);
}

UBIQUITTY_TEST_MAIN()
