// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Apple/ShowcaseHostSeed.h"

#include "Core/Session/ShowcaseSessionTree.h"

Ubiquitty::Session::SessionTree ubiquittyShowcaseHostTree(std::uint64_t nowUnixMilliseconds)
{
    const UbiquittyTest::ShowcaseHost host;
    return host.tree(nowUnixMilliseconds);
}
