// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// UBClipboardReadInterop.h — the OSC 52 clipboard-read confirmation seam.
//
// The frontend hands the Swift presenter an opaque `token` identifying the
// pending read, then waits for the user's choice. Swift calls
// resolveClipboardRead with that same token to deliver the decision back
// across the interop boundary; it forwards to the native resolver the frontend
// registered, which marshals onto the ingest path and frames (or suppresses)
// the OSC 52 reply in Core. Swift never touches Core or the
// Ubiquitty::Terminal directly — only this scalar crossing.
//

namespace Ubiquitty::SwiftBridge {

/// The frontend's completion for one pending OSC 52 read.
///
/// - Parameters:
///   - token: The opaque handle the presenter was given for the read.
///   - approve: Whether the user allowed the clipboard to be returned.
using ClipboardReadResolver = void (*)(const void* token, bool approve);

/// Installs the frontend's ingest-path completion; the frontend calls this once
/// at startup.
///
/// - Parameter resolver: The completion, or null to unregister.
void setClipboardReadResolver(ClipboardReadResolver resolver);

/// Delivers the user's answer for a pending read to the registered resolver.
///
/// Called from the prompt's button handler. With no resolver registered the
/// reply is dropped and the drop is logged, so a headless run does not hang
/// silently.
///
/// - Parameters:
///   - token: The handle the presenter received for this read.
///   - approve: True returns the clipboard to the requesting program.
void resolveClipboardRead(const void* token, bool approve);

} // namespace Ubiquitty::SwiftBridge
