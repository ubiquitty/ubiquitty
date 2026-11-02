// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Source/Platform/macOS/Clipboard.cpp
//
// macOS backend for the PAL clipboard contract (see Source/PAL/PAL.h,
// "Clipboard"). UTF-8 in, UTF-8 out, routed through the general pasteboard.
// Core's OSC 52 dispatcher is the producer; these two functions are the
// consumer.
//
// The pasteboard itself lives one file over, in Swift
// (Source/Platform/macOS/ClipboardPasteboard.h says why). This translation unit
// is the PAL half: it holds the two guards the contract states, so the Swift
// side answers a buffer it may always write to.
//

#include "Platform/macOS/ClipboardPasteboard.h"

#include "PAL/PAL.h"

namespace Ubiquitty::PAL {

void clipboardSetText(std::string_view utf8)
{
    ubiquittyClipboardSetText(utf8.data(), utf8.size());
}

int clipboardGetText(char* outputBuffer, int outputCapacity)
{
    if (!outputBuffer || outputCapacity <= 0)
        return -1;
    return ubiquittyClipboardGetText(outputBuffer, outputCapacity);
}

} // namespace Ubiquitty::PAL
