// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyAppBridge
import UbiquittyPasteboard

/// Owns a session's pasteboard operations and consent identity.
///
/// Reached from C++ through SessionClipboardSeam.h, whose functions are at the
/// end of this file: the session's clipboard client subclasses Core's virtual
/// ClipboardClient, which a Swift type cannot.
final class SessionClipboard: NSObject {
    @MainActor
    func write(_ bytes: Data, buffer: Int) {
        if buffer == 0 {
            guard let text = String(data: bytes, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else {
            ClipboardStore.shared().setBytes(bytes, forBuffer: buffer)
        }
    }

    @MainActor
    func apply(_ names: [String], payloads: [Data], pasteboardName: String) {
        TypedPasteboard.apply(names, payloads: payloads, pasteboardName: pasteboardName)
    }

    @MainActor
    func capture(_ pasteboardName: String, bound: Int, completion: ([String], [Data]) -> Void) {
        TypedPasteboard.capture(pasteboardName, bound: bound, completion: completion)
    }

    /// Who reads the general clipboard's typed items once a read is approved.
    enum TypedItemReading {
        /// This clipboard captures them and hands them to the completion.
        case capturedHere
        /// The caller reads them itself; the completion gets none, so the
        /// pasteboard is read once.
        case leftToCaller
    }

    /// Asks for a buffer's contents, through the read prompt when
    /// confirmation is required.
    ///
    /// - Parameters:
    ///   - identity: The session's identity, which the prompt names.
    ///   - buffer: The buffer; 0 is the general clipboard.
    ///   - setSpec: The OSC 52 selection the program named.
    ///   - requiresConfirmation: Whether a person must approve the read.
    ///   - bound: The byte bound for each typed item.
    ///   - typedItems: Who reads the general clipboard's typed items.
    ///   - completion: The decision, the buffer's bytes, and the typed items'
    ///     names and payloads.
    @MainActor
    func requestRead(
        _ identity: UInt,
        buffer: Int,
        setSpec: String,
        requiresConfirmation: Bool,
        bound: Int,
        typedItems: TypedItemReading = .capturedHere,
        completion: @escaping (Bool, Data, [String], [Data]) -> Void
    ) {
        let answer: (Bool) -> Void = { [weak self] approved in
            guard let self else { return }
            guard approved else {
                completion(false, Data(), [], [])
                return
            }
            if buffer == 0 {
                let bytes = Data((NSPasteboard.general.string(forType: .string) ?? "").utf8)
                guard typedItems == .capturedHere else {
                    completion(true, bytes, [], [])
                    return
                }
                self.capture("", bound: bound) { names, payloads in
                    completion(true, bytes, names, payloads)
                }
            } else {
                completion(true, ClipboardStore.shared().bytes(forBuffer: buffer) ?? Data(), [], [])
            }
        }
        if requiresConfirmation {
            ClipboardReadPrompt.present(forSession: identity, grantIdentity: self, setSpec: setSpec, completion: answer)
        } else {
            answer(true)
        }
    }
}

// MARK: - The C seam (SessionClipboardSeam.h)

/// The seam's opaque handles: a retained clipboard, and a read's C context.
/// Spelled once here, so every signature below names the role, not the pointer.
typealias SessionClipboardSeamHandle = UnsafeMutableRawPointer

/// Receives a read's answer; its second argument is UbiquittyClipboardReadDecision,
/// 1 approved and 0 refused.
typealias SessionClipboardReadAnswer = @convention(c) (SessionClipboardSeamHandle?, Int32, CFData) -> Void

/// Releases a read's context unanswered.
typealias SessionClipboardReadDiscard = @convention(c) (SessionClipboardSeamHandle?) -> Void

private func sessionClipboard(from handle: SessionClipboardSeamHandle?) -> SessionClipboard? {
    handle.map { Unmanaged<SessionClipboard>.fromOpaque($0).takeUnretainedValue() }
}

/// Makes a session's clipboard. See SessionClipboardSeam.h.
@_cdecl("ubiquittySessionClipboardCreate")
func ubiquittySessionClipboardCreate() -> SessionClipboardSeamHandle {
    Unmanaged.passRetained(SessionClipboard()).toOpaque()
}

/// Releases a session's clipboard. See SessionClipboardSeam.h.
@_cdecl("ubiquittySessionClipboardRelease")
func ubiquittySessionClipboardRelease(_ handle: SessionClipboardSeamHandle?) {
    guard let handle else { return }
    Unmanaged<SessionClipboard>.fromOpaque(handle).release()
}

/// Writes a buffer. See SessionClipboardSeam.h.
@_cdecl("ubiquittySessionClipboardWrite")
func ubiquittySessionClipboardWrite(_ handle: SessionClipboardSeamHandle?, _ bytes: CFData, _ buffer: Int32) {
    let data = bytes as Data
    // The seam calls on the main thread, which is where the clipboard lives.
    nonisolated(unsafe) let handle = handle
    MainActor.assumeIsolated { sessionClipboard(from: handle)?.write(data, buffer: Int(buffer)) }
}

/// A read's C context, released unanswered if the answer never comes.
///
/// Unchecked because it carries the C context: it is made, settled and
/// released on the main thread, where the seam calls and the prompt answers.
private final class PendingRead: @unchecked Sendable {
    private let context: SessionClipboardSeamHandle?
    private let answer: SessionClipboardReadAnswer
    private let discard: SessionClipboardReadDiscard
    private var isSettled = false

    init(context: SessionClipboardSeamHandle?, answer: SessionClipboardReadAnswer, discard: SessionClipboardReadDiscard) {
        self.context = context
        self.answer = answer
        self.discard = discard
    }

    func settle(_ approved: Bool, _ bytes: Data) {
        guard !isSettled else { return }
        isSettled = true
        answer(context, approved ? 1 : 0, bytes as CFData)
    }

    deinit {
        if !isSettled {
            discard(context)
        }
    }
}

/// Asks for a buffer's contents. See SessionClipboardSeam.h.
@_cdecl("ubiquittySessionClipboardRequestRead")
func ubiquittySessionClipboardRequestRead(
    _ handle: SessionClipboardSeamHandle?,
    _ identity: UInt,
    _ buffer: Int32,
    _ setSpec: CFString,
    _ confirmation: Int32,
    _ bound: UInt,
    _ context: SessionClipboardSeamHandle?,
    _ answer: SessionClipboardReadAnswer,
    _ discard: SessionClipboardReadDiscard
) {
    let pending = PendingRead(context: context, answer: answer, discard: discard)
    let spec = setSpec as String
    // The seam calls on the main thread, which is where the clipboard lives.
    nonisolated(unsafe) let handle = handle
    MainActor.assumeIsolated {
        guard let clipboard = sessionClipboard(from: handle) else { return }
        clipboard.requestRead(
            identity,
            buffer: Int(buffer),
            setSpec: spec,
            requiresConfirmation: confirmation != 0,
            bound: Int(bound),
            typedItems: .leftToCaller
        ) {
            approved,
            bytes,
            _,
            _ in
            pending.settle(approved, bytes)
        }
    }
}
