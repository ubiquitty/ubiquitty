// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PAL "Core calls down" surface for the OpenBSD/NetBSD wscons console frontend.
// Monotonic clock + stderr diag mirror the POSIX host/Linux backends. No desktop
// session here (no X11, no compositor), so clipboard and preferences are no-ops.
//
// Run by hand on OpenBSD 7.9 x64 under QEMU and nowhere else: NetBSD and real
// hardware are untried. Its ioctl and struct names come from
// <dev/wscons/wsconsio.h>, so a BSD release not yet tried needs them compared
// with that release's own copy of the header.

#include "PAL/PAL.h"

#include <cstdio>
#include <ctime>

namespace Ubiquitty {
namespace PAL {

Ticks monotonicTicks()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return Ticks::fromTimespec(static_cast<uint64_t>(ts.tv_sec), static_cast<uint64_t>(ts.tv_nsec));
}

uint32_t monotonicMicros()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint32_t>(static_cast<uint64_t>(ts.tv_sec) * 1000000u + static_cast<uint64_t>(ts.tv_nsec) / 1000u);
}

void diagWrite(std::string_view message)
{
    if (message.empty())
        return;
    (void)::fwrite(message.data(), 1, message.size(), stderr);
    (void)::fputc('\n', stderr);
}

// No desktop session to hold a selection — OSC 52 is parsed but has nowhere to
// land; no-op.
void clipboardSetText(std::string_view /*utf8*/) { }
int clipboardGetText(char* /*outputBuffer*/, int /*outputCapacity*/) { return -1; }

// preferencesLoad / preferencesSaveAtomic are bundled, in
// Platform/POSIX/Preferences.cpp — this arm reads the same configuration file as
// the others rather than reporting that it has none.

// Unwired in this spike: the console bell ioctl (WSKBDIO_BELL) needs the keyboard
// fd, which this PAL-only TU does not own. BEL parses + coalesces but rings nothing.
void bellRing(BellMode /*mode*/) { }

} // namespace PAL
} // namespace Ubiquitty
