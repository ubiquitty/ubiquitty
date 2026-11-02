// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// SessionClipboardSeam.h — the C seam a session's clipboard client calls,
// implemented in Swift by Source/Platform/macOS/App/SessionClipboard.swift.
//
// The client is C++ (SessionClipboardClient.cpp) because it subclasses Core's
// virtual ClipboardClient, which a Swift type cannot. The pasteboard text, the
// app's clipboard store and the read prompt are AppKit's and stay in Swift; the
// typed items go through TypedPasteboard.h like every other C++ caller's.
// Every call but `create` and `release` runs on the main thread. Bytes and text
// cross as CoreFoundation objects, borrowed for the length of a call, so neither
// side spells a pointer and a length.
//

#include <CoreFoundation/CoreFoundation.h>

#include <cstddef>
#include <cstdint>

extern "C" {

/// Whether a read waits for a person's answer, as the seam carries it.
enum class UbiquittyClipboardReadConfirmation : int {
    NotRequired = 0,
    Required = 1,
};

/// How a read was answered, as the seam carries it.
enum class UbiquittyClipboardReadDecision : int {
    Refused = 0,
    Approved = 1,
};

/// Makes a session's clipboard: the identity a read prompt's "always" answer is
/// granted to. Retained; the caller ends it with ``ubiquittySessionClipboardRelease``.
///
/// - Returns: The clipboard, opaque.
void* ubiquittySessionClipboardCreate(void);

/// Releases a clipboard made by ``ubiquittySessionClipboardCreate``, from any thread.
///
/// - Parameter clipboard: The clipboard.
void ubiquittySessionClipboardRelease(void* clipboard);

/// Writes bytes to a buffer: 0 is the general pasteboard's text, which takes
/// UTF-8 only; any other is the app's own clipboard store.
///
/// - Parameters:
///   - clipboard: The clipboard.
///   - bytes: The bytes.
///   - buffer: The buffer.
void ubiquittySessionClipboardWrite(void* clipboard, CFDataRef bytes, int buffer);

/// Asks for a buffer's contents, through the read prompt when confirmation is
/// required. `answer` is called at most once with the decision and the buffer's
/// bytes; when it will not be called, `discard` is, so the context is released
/// either way. The general clipboard's typed items are not read here: the
/// caller reads them once, beside the answer.
///
/// - Parameters:
///   - clipboard: The clipboard.
///   - identity: The session's identity, which the prompt names.
///   - buffer: The buffer.
///   - setSpec: The OSC 52 selection the program named.
///   - confirmation: Whether a person must approve the read.
///   - bound: The byte bound the prompt applies; the typed items that ride
///     with the general clipboard are the caller's to read.
///   - context: Passed to `answer` or `discard`.
///   - answer: Receives the decision and the bytes.
///   - discard: Releases the context unanswered.
void ubiquittySessionClipboardRequestRead(void* clipboard, std::uintptr_t identity, int buffer, CFStringRef setSpec,
    UbiquittyClipboardReadConfirmation confirmation, std::size_t bound, void* context,
    void (*answer)(void* context, UbiquittyClipboardReadDecision decision, CFDataRef bytes),
    void (*discard)(void* context));

} // extern "C"
