// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SelectionPasteboard.swift — the pasteboard a copied selection is written to.
//
// One writer, because a pasteboard write is a declaration as much as a write:
// the types declared, their order, and whether a declared type has bytes
// behind it are what a paste target reads. The two shells declared them apart,
// and one of them declared rich types it could not always redeem.
//

import AppKit

/// Writes a copied selection's flavours to a pasteboard.
@objc(UBSelectionPasteboard)
@MainActor
public final class SelectionPasteboard: NSObject {
    /// Receives successful user copies to the general pasteboard.
    public static var didCopyText: ((String) -> Void)?

    /// Writes the flavours a copy produced.
    ///
    /// A rich flavour is declared only when there are bytes behind it: a
    /// declared type the pasteboard cannot redeem hands a paste target nothing
    /// rather than letting it fall through to the plain string beside it.
    ///
    /// - Parameters:
    ///   - plain: The plain text; an empty string writes nothing at all.
    ///   - rtf: The RTF document, or empty for a plain copy.
    ///   - html: The HTML fragment, or empty for a plain copy.
    ///   - pasteboard: The destination.
    /// - Returns: Whether anything was written.
    @discardableResult
    @objc
    public static func write(plain: String, rtf: String, html: String, to pasteboard: NSPasteboard) -> Bool {
        guard !plain.isEmpty else { return false }
        var types: [NSPasteboard.PasteboardType] = []
        if !rtf.isEmpty { types.append(.rtf) }
        if !html.isEmpty { types.append(.html) }
        types.append(.string)
        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)
        if !rtf.isEmpty { pasteboard.setData(Data(rtf.utf8), forType: .rtf) }
        if !html.isEmpty { pasteboard.setData(Data(html.utf8), forType: .html) }
        guard pasteboard.setString(plain, forType: .string) else { return false }
        if pasteboard.name == NSPasteboard.general.name {
            didCopyText?(plain)
        }
        return true
    }
}
