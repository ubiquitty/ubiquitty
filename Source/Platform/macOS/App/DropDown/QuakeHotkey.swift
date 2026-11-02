// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// QuakeHotkey.swift — the drop-down terminal's `[quake] hotkey` spec, read into
// the Carbon modifier mask and virtual key code a global hotkey registers.
//
// Foundation and Carbon alone, so Tests/Platform/test_macos_quake_hotkey.swift
// runs the parser without the app module.
//

import Carbon
import Foundation

/// A global hotkey chord: a Carbon modifier mask and a virtual key code.
struct QuakeHotkey: Equatable {
    let modifiers: UInt32
    let keyCode: UInt32

    /// Reads a "+"-joined spec ("control+grave", "cmd+shift+t").
    ///
    /// The modifier vocabulary is Input::Keybindings' (cmd/command/super/win,
    /// ctrl/control, alt/opt/option/meta, shift), ASCII case-insensitive, so a reader
    /// learns one spelling for both. The key is a named key (grave or backtick,
    /// space, return or enter, tab, escape or esc), a digit, a letter or F1 to
    /// F20, mapped through a fixed ANSI table rather than the current layout so
    /// the common chords do not move with it. Spaces and tabs are ignored. When
    /// several key tokens are given the last that resolves wins; an unknown one
    /// is skipped.
    ///
    /// - Parameter spec: The spec.
    /// - Returns: The chord, or nil when no key token resolves.
    init?(spec: String) {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        let scalars = spec.unicodeScalars.filter { $0 != " " && $0 != "\t" }
        let tokens = scalars.split(separator: "+").map(Self.asciiLowercased)
        for token in tokens {
            switch token {
            case "cmd", "command", "super", "win":
                modifiers |= UInt32(cmdKey)
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            case "alt", "opt", "option", "meta":
                modifiers |= UInt32(optionKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            default:
                if let code = Self.keyCode(for: token) {
                    keyCode = code
                }
            }
        }
        guard let keyCode else { return nil }
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    private static let digits = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
    private static let letters = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K,
        kVK_ANSI_L, kVK_ANSI_M,
        kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z,
    ]
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// The token with A to Z lowered and every other character kept, so a
    /// letter outside ASCII that lowers to one (the Kelvin sign to k) is not
    /// read as that key.
    private static func asciiLowercased(_ token: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(token.map { (65...90).contains($0.value) ? Unicode.Scalar(UInt8($0.value + 32)) : $0 }))
    }

    /// The virtual key code of a lowercased key token, or nil for none.
    private static func keyCode(for token: String) -> UInt32? {
        switch token {
        case "grave", "backtick", "`":
            return UInt32(kVK_ANSI_Grave)
        case "space":
            return UInt32(kVK_Space)
        case "return", "enter":
            return UInt32(kVK_Return)
        case "tab":
            return UInt32(kVK_Tab)
        case "escape", "esc":
            return UInt32(kVK_Escape)
        default:
            break
        }
        let scalars = Array(token.unicodeScalars)
        if scalars.count == 1, let value = scalars.first?.value {
            if (48...57).contains(value) { return UInt32(digits[Int(value - 48)]) }
            if (97...122).contains(value) { return UInt32(letters[Int(value - 97)]) }
        }
        if scalars.count >= 2, scalars[0] == "f", scalars.dropFirst().allSatisfy({ (48...57).contains($0.value) }),
            let number = Int(String(String.UnicodeScalarView(scalars.dropFirst()))), (1...20).contains(number)
        {
            return UInt32(functionKeys[number - 1])
        }
        return nil
    }
}
