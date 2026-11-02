// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ShowcaseHostDoor.h — stands the showcase host up in a directory client, for
// the UI scenarios.
//
// The host is a C++ fixture under Tests/ (`UbiquittyTest::ShowcaseHost`), which
// no Swift module names: a second module reaching Core's headers would define
// their types twice. So the fixture crosses as one C function over the client
// a scenario already holds, and the scenario reads everything else off the
// client, as the window does.
//
// Compiled only into the UI-test build.
//

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// How a directory client holds the showcase host's tree.
typedef enum __attribute__((enum_extensibility(closed))) UBShowcaseHostState {
    /// As a listing answered it; nothing follows it.
    UBShowcaseHostStateListed = 0,
    /// Followed by a connected watch.
    UBShowcaseHostStateLive = 1,
    /// Left behind by a watch that lost its host.
    UBShowcaseHostStateStale = 2,
    /// A host that answered and holds nothing.
    UBShowcaseHostStateHoldingNothing = 3,
} UBShowcaseHostState;

/// Hands a directory client the showcase host's tree through its test doors.
///
/// - Parameters:
///   - directoryClient: A `Ubiquitty::Runtime::HostDirectoryClient`, borrowed
///     for the call.
///   - state: How the tree is to be held.
void UBUITestHoldShowcaseHost(void* directoryClient, UBShowcaseHostState state);

#ifdef __cplusplus
}
#endif
