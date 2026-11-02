// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_clipboard_read_resolver.cpp — pin the OSC 52 clipboard-read resolver
// registry seam in UBClipboardReadInterop.cpp.
//
// The Swift prompt's Allow/Deny choice crosses back into Core through
// Ubiquitty::SwiftBridge::resolveClipboardRead(token, approve), which forwards
// to the native completion the frontend registered via setClipboardReadResolver.
// This test registers a stub resolver, drives both the approve and deny edges,
// and asserts the stub observed the same opaque token pointer + bool — i.e. the
// decision marshals across the interop boundary unchanged.
//
// The null-resolver path (no frontend registered) traps via assert() in debug
// and warns + drops in release; it is not exercised here so the
// suite doesn't abort on the debug build. The guard is verified by inspection.

#include "Platform/macOS/App/UBClipboardReadInterop.h"

// Stub resolver state — records what resolveClipboardRead forwarded.
namespace {
const void* g_seenToken = nullptr;
bool g_seenApprove = false;
int g_calls = 0;

void stubResolver(const void* token, bool approve)
{
    g_calls++;
    g_seenToken = token;
    g_seenApprove = approve;
}
} // namespace

TEST(testResolverForwardsTokenAndBool)
{
    using namespace Ubiquitty::SwiftBridge;

    setClipboardReadResolver(&stubResolver);

    // Two distinct opaque tokens stand in for two pending OSC 52 reads.
    int tokenA = 0;
    int tokenB = 0;
    const void* a = &tokenA;
    const void* b = &tokenB;

    resolveClipboardRead(a, true);
    CHECK(g_calls == 1);
    CHECK(g_seenToken == a);
    CHECK(g_seenApprove == true);

    resolveClipboardRead(b, false);
    CHECK(g_calls == 2);
    CHECK(g_seenToken == b);
    CHECK(g_seenApprove == false);

    // Unregister so we leave no process-wide state for any sibling test.
    setClipboardReadResolver(nullptr);
}

UBIQUITTY_TEST_MAIN()
