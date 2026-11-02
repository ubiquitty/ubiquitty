// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
internal import UbiquittyCore

// Sending a key, for either shell.
//
// A frontend reports what it alone knows — which key, which modifiers, the
// layout's code points, the text produced — and this hands it to the terminal.
// Which bytes that becomes is the terminal's: DECCKM, the Kitty flag set, the
// application-keypad form, the xterm modifier ladder, DECUDK, repeat
// suppression under DECARM, and whether SRM leaves the echo here.
//
// One entry point rather than one per shell, because the alternative is what
// this replaced: two shells, two spellings of the same escape sequences, and
// one of them wrong the moment a program set a mode.

/// How many bytes an encoded key sequence can need.
///
/// The encoder refuses to write past the span it is given and reports zero, so
/// this bounds the sequence rather than truncating it. 64 covers the longest
/// form the encoder emits — a Kitty CSI u event carrying associated text.
private let keyEncodeBufferSize = 64

extension TerminalSurface {
    /// Sends one key press to the host.
    ///
    /// - Parameter press: What the platform reported; see `Runtime::KeyPress`.
    /// - Returns: Whether the pane's endpoint accepted the input. A remote
    ///   event may be accepted without local echo bytes; its host owns the
    ///   modes that determine what the program receives.
    /// Package-scoped: a public signature naming `Runtime::KeyPress` would leak
    /// an internally imported Core type into the framework interface.
    @discardableResult
    package func sendKey(_ press: Ubiquitty.Runtime.KeyPress) -> Bool {
        var output = [CChar](repeating: 0, count: keyEncodeBufferSize)
        // The terminal sends it: bytes to a local program, the press itself
        // to a remote host, which encodes it under the modes live there.
        let encoding = output.withUnsafeMutableBufferPointer { buffer in
            drive.sendKey(press, into: buffer)
        }
        guard encoding.wasAccepted else {
            return false
        }
        guard encoding.length > 0 else { return true }
        let count = Int(encoding.length)
        output.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            // The host will not echo, so the typed bytes go back through the
            // model to appear at all. The terminal decided that, including the
            // password-prompt case, which is why nothing here re-reads a mode.
            if encoding.shouldEchoLocally {
                drive.feed(Span(_unsafeStart: base, count: count))
            }
        }
        observer?.terminalSurface(self, didTransmit: output, count: count)
        return true
    }
}
