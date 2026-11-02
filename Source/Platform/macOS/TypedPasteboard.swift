// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UniformTypeIdentifiers

/// Translates between MIME payloads and native pasteboard representations.
///
/// The one implementation both macOS shells reach: the Swift shell calls the
/// methods, and the C++ shell calls the C entry points below, which are the
/// same operations over pointer-and-length arguments. AppKit owns the
/// pasteboard, so every operation here runs on the main thread.
@MainActor
public enum TypedPasteboard {
    private static let fixedTypes: [(String, NSPasteboard.PasteboardType)] = [
        ("text/plain", .string), ("text/html", .html), ("text/rtf", .rtf),
        ("image/png", .png), ("image/tiff", .tiff), ("application/pdf", .pdf),
    ]

    private static func bareMIME(_ mime: String) -> String {
        String(mime.prefix { $0 != ";" }).lowercased()
    }

    /// Replaces the named pasteboard's contents with a typed set.
    ///
    /// - Parameters:
    ///   - names: One MIME name per payload.
    ///   - payloads: The payloads, paired with `names` in order.
    ///   - pasteboardName: The pasteboard, empty for the general one.
    public static func apply(_ names: [String], payloads: [Data], pasteboardName: String) {
        let pasteboard = Self.pasteboard(pasteboardName)
        pasteboard.clearContents()
        for (name, bytes) in zip(names, payloads) {
            Self.write(name, bytes: bytes, to: pasteboard)
        }
    }

    /// Empties the named pasteboard, opening the generation writes land in.
    ///
    /// - Parameter pasteboardName: The pasteboard, empty for the general one.
    public static func clear(_ pasteboardName: String) {
        Self.pasteboard(pasteboardName).clearContents()
    }

    /// Writes one MIME payload into the named pasteboard's open generation.
    ///
    /// - Parameters:
    ///   - mime: The payload's MIME name; a name the mapping cannot answer is
    ///     dropped, because the pasteboard has no type to file it under.
    ///   - bytes: The payload.
    ///   - pasteboardName: The pasteboard, empty for the general one.
    public static func setItem(_ mime: String, bytes: Data, pasteboardName: String) {
        Self.write(mime, bytes: bytes, to: Self.pasteboard(pasteboardName))
    }

    /// Files one payload under the pasteboard type its MIME maps to.
    ///
    /// Text lands through the string API so plain interop (⌘V elsewhere) sees
    /// it; everything else lands as data under its mapped type.
    private static func write(_ mime: String, bytes: Data, to pasteboard: NSPasteboard) {
        let bare = Self.bareMIME(mime)
        if bare == "text/plain" {
            if let text = String(data: bytes, encoding: .utf8) {
                pasteboard.setString(text, forType: .string)
            }
        } else if let type = Self.fixedTypes.first(where: { $0.0 == bare })?.1
            ?? UTType(mimeType: bare).map({ NSPasteboard.PasteboardType($0.identifier) })
        {
            pasteboard.setData(bytes, forType: type)
        }
    }

    @MainActor
    private static func pasteboard(_ name: String) -> NSPasteboard {
        name.isEmpty ? .general : NSPasteboard(name: .init(name))
    }

    /// Lists the named pasteboard's MIME formats without reading payload data.
    /// - Parameter pasteboardName: Empty selects the general pasteboard.
    /// - Returns: Ordered, deduplicated MIME names.
    public static func typeNames(_ pasteboardName: String) -> [String] {
        var names: [String] = []
        for type in Self.pasteboard(pasteboardName).types ?? [] {
            guard
                let mime = Self.fixedTypes.first(where: { $0.1 == type })?.0
                    ?? UTType(type.rawValue)?.preferredMIMEType,
                !names.contains(where: { Self.bareMIME($0) == Self.bareMIME(mime) })
            else { continue }
            names.append(mime)
        }
        return names
    }

    /// Captures ordered, deduplicated MIME payloads with a bound per item.
    ///
    /// - Parameters:
    ///   - pasteboardName: The pasteboard, empty for the general one.
    ///   - bound: The most bytes any one payload may carry.
    ///   - completion: Receives the names and payloads, paired in order.
    public static func capture(_ pasteboardName: String, bound: Int, completion: ([String], [Data]) -> Void) {
        let pasteboard = Self.pasteboard(pasteboardName)
        var names: [String] = []
        var payloads: [Data] = []
        for type in pasteboard.types ?? [] {
            guard
                let mime = Self.fixedTypes.first(where: { $0.1 == type })?.0
                    ?? UTType(type.rawValue)?.preferredMIMEType,
                !names.contains(where: { Self.bareMIME($0) == Self.bareMIME(mime) })
            else { continue }
            let bytes: Data
            if Self.bareMIME(mime) == "text/plain" {
                guard let text = pasteboard.string(forType: type) else { continue }
                bytes = Data(text.utf8)
            } else {
                bytes = pasteboard.data(forType: type) ?? Data()
            }
            names.append(mime)
            payloads.append(Data(bytes.prefix(max(0, bound))))
        }
        completion(names, payloads)
    }

    /// Writes one payload under one concrete pasteboard type, no clearing.
    ///
    /// The raw half of ``apply(_:payloads:pasteboardName:)``, for a writer that
    /// names the platform type itself — a legacy spelling beside the modern
    /// one, or a test building the multi-spelling pasteboards real
    /// applications leave behind. The MIME mapping is not consulted.
    ///
    /// - Parameters:
    ///   - bytes: The payload; empty sets an empty datum.
    ///   - typeIdentifier: The pasteboard type, verbatim.
    ///   - pasteboardName: The pasteboard, empty for the general one.
    public static func applyData(_ bytes: Data, typeIdentifier: String, pasteboardName: String) {
        pasteboard(pasteboardName).setData(bytes, forType: .init(typeIdentifier))
    }

    /// Releases a uniquely named pasteboard its owner is finished with.
    ///
    /// - Parameter name: The name its owner minted; the empty name addresses
    ///   the general pasteboard, which is nobody's to release.
    public static func releaseNamed(_ name: String) {
        guard !name.isEmpty else { return }
        pasteboard(name).releaseGlobally()
    }
}

// MARK: - The C entry points the C++ shell calls

// Pointer and length rather than a C string, because a pasteboard name and a
// MIME name are both byte ranges on the C++ side and either may hold bytes that
// are not UTF-8. A range that does not decode addresses nothing: the operation
// returns having done nothing, which is what AppKit does with a name it cannot
// make an NSString from.
//
// Every entry point asserts main-thread isolation rather than hopping, because
// the contract is the same one the Swift callers keep — Core calls the seam on
// the frontend's own loop, and a hop would answer a synchronous capture after
// the caller had already read the empty snapshot.

/// Decodes a UTF-8 byte range a C caller passed.
private func decodedText(_ bytes: UnsafePointer<CChar>, _ length: UInt) -> String? {
    String(bytes: UnsafeRawBufferPointer(start: bytes, count: Int(length)), encoding: .utf8)
}

/// Empties the named pasteboard. See ``TypedPasteboard/clear(_:)``.
@_cdecl("ubiquittyTypedPasteboardClear")
public func ubiquittyTypedPasteboardClear(_ pasteboardName: UnsafePointer<CChar>, _ pasteboardNameLength: UInt) {
    guard let name = decodedText(pasteboardName, pasteboardNameLength) else { return }
    MainActor.assumeIsolated { TypedPasteboard.clear(name) }
}

/// Writes one MIME payload. See ``TypedPasteboard/setItem(_:bytes:pasteboardName:)``.
@_cdecl("ubiquittyTypedPasteboardSetItem")
public func ubiquittyTypedPasteboardSetItem(
    _ pasteboardName: UnsafePointer<CChar>,
    _ pasteboardNameLength: UInt,
    _ mime: UnsafePointer<CChar>,
    _ mimeLength: UInt,
    _ bytes: UnsafeRawPointer?,
    _ byteCount: UInt
) {
    guard let name = decodedText(pasteboardName, pasteboardNameLength),
        let spelling = decodedText(mime, mimeLength)
    else { return }
    let payload = Data(UnsafeRawBufferPointer(start: bytes, count: Int(byteCount)))
    MainActor.assumeIsolated { TypedPasteboard.setItem(spelling, bytes: payload, pasteboardName: name) }
}

/// Writes one payload under a verbatim type. See ``TypedPasteboard/applyData(_:typeIdentifier:pasteboardName:)``.
@_cdecl("ubiquittyTypedPasteboardSetTypeData")
public func ubiquittyTypedPasteboardSetTypeData(
    _ pasteboardName: UnsafePointer<CChar>,
    _ pasteboardNameLength: UInt,
    _ typeIdentifier: UnsafePointer<CChar>,
    _ typeIdentifierLength: UInt,
    _ bytes: UnsafeRawPointer?,
    _ byteCount: UInt
) {
    guard let name = decodedText(pasteboardName, pasteboardNameLength),
        let type = decodedText(typeIdentifier, typeIdentifierLength)
    else { return }
    let payload = Data(UnsafeRawBufferPointer(start: bytes, count: Int(byteCount)))
    MainActor.assumeIsolated { TypedPasteboard.applyData(payload, typeIdentifier: type, pasteboardName: name) }
}

/// Captures the named pasteboard, one `receive` call per payload.
///
/// The names and bytes handed to `receive` live for that call only; the caller
/// copies what it keeps. See ``TypedPasteboard/capture(_:bound:completion:)``.
@_cdecl("ubiquittyTypedPasteboardCapture")
public func ubiquittyTypedPasteboardCapture(
    _ pasteboardName: UnsafePointer<CChar>,
    _ pasteboardNameLength: UInt,
    _ perItemBound: UInt,
    _ context: UnsafeMutableRawPointer?,
    _ receive: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UInt, UnsafeRawPointer?, UInt) -> Void
) {
    guard let name = decodedText(pasteboardName, pasteboardNameLength) else { return }
    let bound = Int(min(perItemBound, UInt(Int.max)))
    // The capture is taken under main-actor isolation and handed back after it,
    // because the C function pointer and its context belong to the caller's
    // isolation and cannot be sent into the main actor's.
    let captured: ([String], [Data]) = MainActor.assumeIsolated {
        var names: [String] = []
        var payloads: [Data] = []
        TypedPasteboard.capture(name, bound: bound) { capturedNames, capturedPayloads in
            names = capturedNames
            payloads = capturedPayloads
        }
        return (names, payloads)
    }
    for (mime, payload) in zip(captured.0, captured.1) {
        mime.withCString { spelling in
            payload.withUnsafeBytes { raw in
                receive(context, spelling, UInt(mime.utf8.count), raw.baseAddress, UInt(raw.count))
            }
        }
    }
}

/// Releases a uniquely named pasteboard. See ``TypedPasteboard/releaseNamed(_:)``.
@_cdecl("ubiquittyTypedPasteboardRelease")
public func ubiquittyTypedPasteboardRelease(_ pasteboardName: UnsafePointer<CChar>, _ pasteboardNameLength: UInt) {
    guard let name = decodedText(pasteboardName, pasteboardNameLength) else { return }
    MainActor.assumeIsolated { TypedPasteboard.releaseNamed(name) }
}
