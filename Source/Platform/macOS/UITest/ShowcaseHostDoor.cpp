// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "ShowcaseHostDoor.h"

#include "Core/Runtime/HostDirectoryClient.h"
#include "Core/Session/SessionDirectoryCore.h"
#include "Core/Session/SessionTree.h"
#include "Core/Session/ShowcaseSessionTree.h"

#include <chrono>
#include <cstdint>

void UBUITestHoldShowcaseHost(void* directoryClient, UBShowcaseHostState state)
{
    using namespace Ubiquitty;
    auto* client = static_cast<Runtime::HostDirectoryClient*>(directoryClient);
    if (!client)
        return;
    // The host states its tree at this machine's own clock, so the ages a
    // scenario reads are the fixture's own.
    const std::uint64_t now = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
    if (state == UBShowcaseHostStateHoldingNothing) {
        Session::SessionTree nothing;
        nothing.revision = 1;
        nothing.hostNowUnixMilliseconds = now;
        client->noteListedSessionTreeForTest(nothing);
        return;
    }
    const UbiquittyTest::ShowcaseHost host;
    const Session::SessionTree tree = host.tree(now);
    client->noteListedSessionTreeForTest(tree);
    if (state == UBShowcaseHostStateListed)
        return;
    client->noteWatchedSessionTreeForTest(tree);
    if (state == UBShowcaseHostStateStale) {
        Session::DirectoryFailureReport dropped;
        dropped.detail = "ssh: connect to host build.example port 22: Network is unreachable";
        client->noteWatchInterruptedForTest(dropped);
    }
}
