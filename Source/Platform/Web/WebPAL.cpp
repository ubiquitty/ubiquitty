// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Source/Platform/Web/WebPAL.cpp — the browser's half of the PAL contract.
//
// `Platform/Wasm` supplies the system half — storage, spawn, login shell — as
// unavailable stubs. This file supplies the half every embedder must implement:
// clock, diag, bell, clipboard and preferences.
//
// Every browser facility behind these is asynchronous and every function here is
// not, so nothing is fetched on demand: a clipboard read is served from a buffer
// the embedder pushes in. The asynchrony stays outside, and Core keeps its
// synchronous contract.
//

#include "PAL/PAL.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

namespace {

// The clipboard text last pushed in. OSC 52 writes land here for the shim to
// pull out, and reads are served from it. One thread, one caller: wasm has no
// other here.
std::string clipboardText;

// Nanoseconds since an arbitrary origin. Integer, because the counters below
// are 32-bit and wrap: a large double loses the low bits that make a delta
// across the wrap exact.
std::uint64_t nowNanoseconds()
{
#ifdef __EMSCRIPTEN__
    return static_cast<std::uint64_t>(emscripten_get_now() * 1e6); // performance.now(), monotonic
#else
    // A clock that advances is required off-target too: a constant freezes every
    // age-bounded policy in Core, so no watchdog ever fires.
    const auto since = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(since).count());
#endif
}

} // namespace

namespace Ubiquitty::PAL {

Ticks monotonicTicks() { return Ticks::fromNanoseconds(nowNanoseconds()); }
uint32_t monotonicMicros() { return static_cast<uint32_t>((nowNanoseconds() / 1000ull) & 0xFFFFFFFFull); }

// The browser console is the only sink a page always has.
void diagWrite(std::string_view message)
{
    if (!message.empty())
        std::fwrite(message.data(), 1, message.size(), stderr);
}

// A terminal bell has no browser equivalent that is not hostile: audio needs a
// user gesture and a visual flash belongs to the page's own styling. The page
// decides, so Core's bell is a no-op here rather than a guess.
void bellRing(BellMode) { }

void clipboardSetText(std::string_view utf8)
{
    clipboardText.assign(utf8);
}

int clipboardGetText(char* outputBuffer, int outputCapacity)
{
    if (!outputBuffer || outputCapacity <= 0)
        return -1;
    // Bounded in the unsigned domain before it is narrowed, because the
    // narrowing is what can make it negative. `size()` is unsigned, and text
    // large enough to truncate to a negative `int` clears the capacity test
    // rather than failing it — a negative is not `>=` a positive capacity —
    // and then widens back into a count near the size of the address space for
    // a copy into the caller's buffer. The page sets this text, so its length
    // is not this function's to trust.
    const std::size_t available = clipboardText.size();
    if (available >= static_cast<std::size_t>(outputCapacity))
        return -1;
    std::memcpy(outputBuffer, clipboardText.data(), available);
    outputBuffer[available] = '\0';
    return static_cast<int>(available);
}

// preferencesLoad / preferencesSaveAtomic are bundled: Platform/Wasm/Preferences.cpp
// carries them for this build, holding bytes the page supplies. Defining them
// here as well would be two definitions of one seam.

} // namespace Ubiquitty::PAL
