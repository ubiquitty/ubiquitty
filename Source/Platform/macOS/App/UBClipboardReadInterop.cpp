// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// UBClipboardReadInterop.cpp — the OSC 52 read-confirmation resolver registry.
// The frontend registers its ingest-path completion; the Swift prompt calls
// resolveClipboardRead.
//

#include "UBClipboardReadInterop.h"
#include "PAL/Log.h"

#include <atomic>
#include <cassert>
#include <cstdio>

namespace Ubiquitty::SwiftBridge {

namespace {

// Atomic to avoid a data race between the one-time registration on main and
// the ingest-thread read.
std::atomic<ClipboardReadResolver>& registeredResolver()
{
    static std::atomic<ClipboardReadResolver> resolver { nullptr };
    return resolver;
}

} // namespace

void setClipboardReadResolver(ClipboardReadResolver resolver) { registeredResolver().store(resolver, std::memory_order_release); }

void resolveClipboardRead(const void* token, bool approve)
{
    // A null resolver means Core's deferred OSC 52 reply never completes and
    // the requesting app hangs forever waiting on the clipboard. Surface it
    // (trap in debug, warn in release) instead of dropping silently.
    ClipboardReadResolver resolver = registeredResolver().load(std::memory_order_acquire);
    if (!resolver) {
        Ubiquitty::PAL::logLine(stderr,
            "Ubiquitty: resolveClipboardRead with no resolver registered; OSC 52 reply dropped (token={})",
            token);
        assert(resolver != nullptr && "resolveClipboardRead called before resolver registration");
        return;
    }
    resolver(token, approve);
}

} // namespace Ubiquitty::SwiftBridge
