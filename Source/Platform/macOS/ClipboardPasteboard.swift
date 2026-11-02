// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

//
// The pasteboard half of the macOS PAL clipboard backend, declared for C++ in
// Source/Platform/macOS/ClipboardPasteboard.h and called from
// Source/Platform/macOS/Clipboard.cpp.
//
// AppKit's accessor and no other board: the UI-test harness exchanges
// NSPasteboard.general for a privately owned board, so a scenario that copies
// leaves the operator's clipboard alone, and reaching the system board by
// another route would walk around that exchange.
//
// Nonisolated, because the seam is a C symbol and the callers are Core's OSC 52
// dispatch and the window controllers, all on the main thread. NSPasteboard
// carries no actor of its own.
//

/// Replaces the general pasteboard's text with `byteCount` UTF-8 bytes.
///
/// Bytes that are not UTF-8 leave the pasteboard untouched: a malformed OSC 52
/// payload is a no-op rather than a cleared clipboard.
///
/// - Parameters:
///   - utf8: The text, which need not be NUL-terminated; null only when
///     `byteCount` is zero.
///   - byteCount: The byte count; zero stores empty text.
@_cdecl("ubiquittyClipboardSetText")
func ubiquittyClipboardSetText(_ utf8: UnsafePointer<CChar>?, _ byteCount: Int) {
    var text = ""
    if let utf8, byteCount > 0 {
        let bytes = UnsafeRawBufferPointer(start: utf8, count: byteCount)
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return }
        text = decoded
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// Reads the general pasteboard's text into `outputBuffer` as UTF-8.
///
/// - Parameters:
///   - outputBuffer: Where the bytes go.
///   - outputCapacity: The buffer's size in bytes.
/// - Returns: The byte count written, clamped to `outputCapacity`; -1 when the
///   pasteboard holds no string.
@_cdecl("ubiquittyClipboardGetText")
func ubiquittyClipboardGetText(_ outputBuffer: UnsafeMutablePointer<CChar>?, _ outputCapacity: Int32) -> Int32 {
    guard let outputBuffer, outputCapacity > 0 else { return -1 }
    guard let text = NSPasteboard.general.string(forType: .string) else { return -1 }
    let utf8 = Array(text.utf8)
    let count = min(utf8.count, Int(outputCapacity))
    if count > 0 {
        utf8.withUnsafeBytes { source in
            outputBuffer.withMemoryRebound(to: UInt8.self, capacity: count) { destination in
                destination.update(from: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
            }
        }
    }
    return Int32(count)
}
