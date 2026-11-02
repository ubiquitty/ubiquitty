// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Source/Platform/macOS/Bell.cpp
//
// macOS backend for the PAL bell contract (see Source/PAL/PAL.h, "Bell"). The
// audible cue is AudioServicesPlayAlertSound(kUserPreferredAlert) — the alert
// the person chose in Sound settings, at the volume they chose, which is the
// same cue Finder and Mail sound. Plain C AudioToolbox, so this is a C++
// translation unit, and it is the framework DECPSSound.cpp already links.
//
// The visible half of a bell does not route through PAL: the flash needs the
// Metal renderer's overlay pass and the per-frame tick clock, both owned by the
// terminal view. The view resolves the bell through Ubiquitty::resolveBellEvent
// and hands the renderer a flash start tick directly, so this backend answers
// the audible half alone — the same division Source/Platform/Linux/PAL.cpp
// draws.
//
// DECPS play-sound (PAL::playTones) is a separate device with its own mix and
// lives in Source/Platform/macOS/DECPSSound.cpp.
//

#include "Platform/macOS/Bell.h"

#include "PAL/PAL.h"

#include <AudioToolbox/AudioToolbox.h>

namespace {

#if UBIQUITTY_ENABLE_TEST_HOOKS
int s_alertSoundRequests = 0;
bool s_isAlertPlaybackSilenced = false;
#endif

// The alert. The test-hook define counts the request and, once a suite has
// silenced playback, returns ahead of it: the AudioToolbox call below is the
// same line every build compiles, so a test build links what the app runs. See
// Ubiquitty::macOS::ForTest::alertSoundRequestCount.
void requestUserAlertSound()
{
#if UBIQUITTY_ENABLE_TEST_HOOKS
    ++s_alertSoundRequests;
    if (s_isAlertPlaybackSilenced)
        return;
#endif
    AudioServicesPlayAlertSound(kUserPreferredAlert);
}

} // namespace

namespace Ubiquitty::macOS {

#if UBIQUITTY_ENABLE_TEST_HOOKS
namespace ForTest {

int alertSoundRequestCount() { return s_alertSoundRequests; }

void silenceAlertPlayback() { s_isAlertPlaybackSilenced = true; }

} // namespace ForTest
#endif

} // namespace Ubiquitty::macOS

namespace Ubiquitty::PAL {

void bellRing(BellMode mode)
{
    if (mode == BellMode::Audio || mode == BellMode::Both)
        requestUserAlertSound();
}

} // namespace Ubiquitty::PAL
