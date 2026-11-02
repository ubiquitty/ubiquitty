// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// TypedPasteboard.h — the C++ half of the MIME-typed pasteboard both macOS
// shells share. The clipboard seam speaks MIME names; AppKit speaks pasteboard
// types, and the translation lives in TypedPasteboard.swift. This header is how
// C++ reaches it: each function here marshals its arguments into the Swift
// module's C entry points, so there is one mapping, one type ordering and one
// set of bounds whichever shell the user opened.
//
// Every operation runs on the main thread — NSPasteboard is AppKit's — which is
// why capture exists at all: Core asks for types and bytes on the ingest
// thread, so a client answers from the snapshot its approval captured, never
// from the pasteboard itself. The Swift side asserts that isolation, so a call
// from another thread fails where it is made rather than corrupting AppKit.
//
// Pasteboards are addressed by name, so a test drives the same code against a
// uniquely named pasteboard and the user's clipboard is never part of a test
// run. The empty name means the general pasteboard. A name that is not UTF-8
// addresses nothing.

#include "Core/Clipboard/ReadStage.h"
#include "PAL/TerminalClients.h"

#include <cstddef>
#include <functional>
#include <span>
#include <string_view>

namespace Ubiquitty::TypedPasteboard {

using Ubiquitty::Clipboard::Snapshot;

/// Applies a typed set to the named pasteboard, replacing its contents.
///
/// Text lands through the string API so plain interop (⌘V elsewhere) sees
/// it; every other item lands as data under the pasteboard type its MIME
/// maps to. An item whose MIME maps to no type is dropped — the pasteboard
/// cannot name it. Main thread only.
///
/// - Parameters:
///   - pasteboardName: The pasteboard, empty for the general one.
///   - items: The payloads, one per MIME. Empty clears the pasteboard.
void apply(std::string_view pasteboardName, std::span<const ClipboardItem> items);

/// Captures the named pasteboard's typed contents. Main thread only.
///
/// Types the mapping does not name are skipped; a type whose MIME another
/// type already captured is skipped too, first reading wins — a pasteboard
/// lists plain text under several spellings and the seam wants one.
///
/// - Parameters:
///   - pasteboardName: The pasteboard, empty for the general one.
///   - perItemBound: The most bytes any one payload may carry.
/// - Returns: The snapshot, empty when the pasteboard holds nothing mapped.
[[nodiscard]] Snapshot capture(std::string_view pasteboardName, std::size_t perItemBound);

/// Writes one payload under one concrete pasteboard type, no clearing.
///
/// The raw half of ``apply``, for a writer that must name the platform type
/// itself — a legacy spelling beside the modern one, or a test building the
/// multi-spelling pasteboards real applications leave behind. The MIME
/// mapping is not consulted.
///
/// - Parameters:
///   - pasteboardName: The pasteboard, empty for the general one.
///   - typeIdentifier: The pasteboard type, verbatim.
///   - bytes: The payload; empty sets an empty datum.
void applyDataForType(std::string_view pasteboardName, std::string_view typeIdentifier, std::span<const char> bytes);

/// Captures the general pasteboard and hands it to Core's remote-serve seam.
///
/// The body of ``ClipboardClient/captureClipboardForRemote`` for the C++
/// shell. One function because it is the same capture either way, and a second
/// copy is a second set of bounds and a second type ordering — a remote program
/// would be answered differently depending on which shell the user opened.
///
/// Main thread only, like everything else here. Core calls the seam on the
/// frontend's own loop for exactly this reason.
///
/// - Parameter sink: Receives views onto a capture that lives for the call.
/// - Returns: True always — a capture of an empty pasteboard is still a
///   capture, and it is Core that decides an empty one reports Empty.
bool captureForRemote(const std::function<void(std::span<const ClipboardItem>)>& sink);

/// Releases a uniquely named pasteboard a test created by addressing it.
///
/// - Parameter pasteboardName: The name the test minted; never empty.
void releaseNamed(std::string_view pasteboardName);

} // namespace Ubiquitty::TypedPasteboard
