// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// Source/Platform/macOS/ClipboardPasteboard.h — the C seam the macOS clipboard
// backend calls, implemented in Swift by
// Source/Platform/macOS/ClipboardPasteboard.swift.
//
// The pasteboard half is Swift because it must be AppKit's NSPasteboard.general
// and nothing else. The UI-test harness exchanges that accessor for a privately
// owned board (Source/Platform/macOS/UITest/Swift/PasteboardIsolation.swift), so
// a scenario that copies never writes the operator's clipboard; a Carbon-era
// pasteboard handle reaches the system board directly and would walk around
// that exchange.
//
// Bytes rather than a string type, so the seam carries what the PAL contract
// carries: UTF-8 that need not be NUL-terminated.
//

#include <cstddef>

extern "C" {

/// Replaces the general pasteboard's text with `byteCount` UTF-8 bytes.
///
/// Bytes that are not UTF-8 leave the pasteboard untouched, which is what makes
/// a malformed OSC 52 payload a no-op rather than a cleared clipboard.
///
/// - Parameters:
///   - utf8: The text; may be null when `byteCount` is zero.
///   - byteCount: The byte count, which may be zero to store empty text.
void ubiquittyClipboardSetText(const char* utf8, std::size_t byteCount);

/// Reads the general pasteboard's text as UTF-8.
///
/// - Parameters:
///   - outputBuffer: Where the bytes go; never null here.
///   - outputCapacity: The buffer's size in bytes; always positive here.
/// - Returns: The byte count written, clamped to `outputCapacity`; -1 when the
///   pasteboard holds no string. The clamp cuts on a raw byte boundary, so a
///   multi-byte sequence straddling the end is cut mid-character — callers size
///   the buffer to the expected payload rather than relying on a code-point
///   aligned cut.
int ubiquittyClipboardGetText(char* outputBuffer, int outputCapacity);

} // extern "C"
