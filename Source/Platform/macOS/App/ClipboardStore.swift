// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CxxStdlib
import UbiquittyCore

/// Connects the portable selection buffers and copy history to the paste picker.
@MainActor
@objc(UBClipboardStore)
final class ClipboardStore: NSObject {
    private static let instance = ClipboardStore()
    private var store = Ubiquitty.OSC.ClipboardStore()

    @objc
    static func shared() -> ClipboardStore { instance }

    @objc(setBytes:forBuffer:)
    func setBytes(_ bytes: Data, forBuffer buffer: Int) {
        guard let raw = UInt8(exactly: buffer), let selector = Ubiquitty.ClipboardBuffer(rawValue: raw), selector != .Count else { return }
        bytes.withUnsafeBytes { raw in
            let view = std.string_view(raw.bindMemory(to: CChar.self).baseAddress, raw.count)
            store.setBuffer(selector, view)
        }
    }

    @objc(bytesForBuffer:)
    func bytes(forBuffer buffer: Int) -> Data? {
        guard let raw = UInt8(exactly: buffer), let selector = Ubiquitty.ClipboardBuffer(rawValue: raw), selector != .Count else {
            return nil
        }
        let bytes = store.bufferBytes(selector)
        guard !bytes.empty() else { return nil }
        return withExtendedLifetime(bytes) {
            Data(bytes: bytes.__dataUnsafe(), count: Int(bytes.size()))
        }
    }

    @objc
    func recordRecentCopy(_ text: String) {
        text.withCString { store.recordRecentCopy(std.string_view($0)) }
    }

    @objc
    func pasteBufferEntries() -> [[String: Any]] {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return text.withCString { pointer in
            store.pasteEntries(std.string_view(pointer))
                .map { entry in
                    [
                        "kind": Int(entry.kind.rawValue), "index": Int(entry.index),
                        "label": String(entry.label), "preview": String(entry.preview),
                    ]
                }
        }
    }

    func text(for kind: Ubiquitty.OSC.PasteEntryKind, index: Int) -> String? {
        guard let position = Int32(exactly: index) else { return nil }
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let result = clipboard.withCString { store.textForEntry(kind, position, std.string_view($0)) }
        return result.empty() ? nil : String(result)
    }

    @objc(textForEntryKind:index:)
    func textForEntryKind(_ kind: Int, index: Int) -> String? {
        switch kind {
        case Int(Ubiquitty.OSC.PasteEntryKind.Buffer.rawValue): return text(for: .Buffer, index: index)
        case Int(Ubiquitty.OSC.PasteEntryKind.Recent.rawValue): return text(for: .Recent, index: index)
        default: return nil
        }
    }
}
