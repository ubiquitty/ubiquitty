// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PAL "Core calls down" surface for the Linux frontend: monotonic clock + stderr
// diag; clipboard / preferences / bell answer without an OS call. The "up" hooks (image
// decoder, play-tones, selection colors) live in the portable PAL.cpp, not here.

#include "PAL/PAL.h"

#include "Platform/Linux/Clipboard.h"

#include <cstdio>
#include <ctime>
#include <string>

#include <gdk/gdk.h>

namespace Ubiquitty::PAL {

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

void clipboardSetText(std::string_view utf8)
{
    if (utf8.empty())
        return;
    // NUL-terminate: gdk_clipboard_set_text takes a C string, but the
    // selected-text byte run isn't guaranteed terminated.
    const std::string text(utf8);
    Ubiquitty::Linux::Clipboard::recordLastSetText(text); // headless test capture
    GdkDisplay* display = gdk_display_get_default();
    if (!display)
        return; // no display (headless self-test); the capture above still ran
    gdk_clipboard_set_text(gdk_display_get_clipboard(display), text.c_str());
}
int clipboardGetText(char* /*outputBuffer*/, int /*outputCapacity*/) { return -1; }
// preferencesLoad / preferencesSaveAtomic: bundled, in Platform/POSIX/Preferences.cpp.
void bellRing(BellMode mode)
{
    // Audible cue only — the visual flash is the frontend's job.
    if (mode != BellMode::Audio && mode != BellMode::Both)
        return;
    if (GdkDisplay* display = gdk_display_get_default())
        gdk_display_beep(display);
}

} // namespace Ubiquitty::PAL
