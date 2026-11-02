// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// Source/Platform/macOS/Bell.h — the test seam over the macOS bell backend.
//
// Ubiquitty::PAL::bellRing is declared on the seam itself (Source/PAL/PAL.h);
// nothing here widens it. What this header carries is the one thing a suite
// running on a desk with speakers cannot observe by listening: which modes ask
// the system for the user's alert sound, and a switch that keeps the asking
// inaudible.
//

namespace Ubiquitty::macOS {

#if UBIQUITTY_ENABLE_TEST_HOOKS
namespace ForTest {

/// How many times this backend has asked for the user's alert sound.
///
/// Compiled into the backend only under the test-hook define, which counts
/// every request: the mode gate is the invariant worth pinning, and a count is
/// the only way a test observes it.
///
/// - Returns: The running count, since the process started.
[[nodiscard]] int alertSoundRequestCount();

/// Keeps every later request from reaching the speakers.
///
/// The backend still runs the same AudioToolbox call it runs in the app; this
/// returns before it, so a suite pinning the mode gate stays silent on a desk
/// with speakers. One way: nothing turns playback back on.
void silenceAlertPlayback();

} // namespace ForTest
#endif

} // namespace Ubiquitty::macOS
