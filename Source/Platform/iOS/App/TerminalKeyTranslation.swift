// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import GameController
import UIKit
import UbiquittyCore

// UIKit's keys, as the terminal's contract for a key press.
//
// This shell's whole share of the keyboard: which key UIKit reported, which
// modifiers were held, and what it typed. Which bytes that becomes is the
// terminal's, behind `TerminalSurface.sendKey`.
//
// This file replaced two private encoders — one here and one in the terminal
// screen's control row — that spelled the sequences themselves. Both wrote the
// cursor keys as CSI forms, so they stayed CSI under DECCKM, where vim, less
// and readline in application mode expect SS3; and neither could reach the
// Kitty protocol, modifyOtherKeys or DECUDK at all.
enum TerminalKeyTranslation {
    /// The portable key UIKit's code stands for, or nil when the press carries
    /// no key identity of its own and should arrive as text instead.
    ///
    /// - Parameter keyCode: UIKit's HID usage.
    /// - Returns: The key Core names.
    static func virtualKey(for keyCode: UIKeyboardHIDUsage) -> Ubiquitty.Keys.VirtualKey? {
        switch keyCode {
        case .keyboardUpArrow: return .UpArrow
        case .keyboardDownArrow: return .DownArrow
        case .keyboardLeftArrow: return .LeftArrow
        case .keyboardRightArrow: return .RightArrow
        case .keyboardReturnOrEnter: return .Return
        case .keypadEnter: return .KeypadEnter
        case .keyboardTab: return .Tab
        case .keyboardEscape: return .Escape
        case .keyboardDeleteOrBackspace: return .Backspace
        case .keyboardDeleteForward: return .ForwardDelete
        case .keyboardInsert: return .Insert
        case .keyboardHome: return .Home
        case .keyboardEnd: return .End
        case .keyboardPageUp: return .PageUp
        case .keyboardPageDown: return .PageDown
        case .keyboardF1: return .F1
        case .keyboardF2: return .F2
        case .keyboardF3: return .F3
        case .keyboardF4: return .F4
        case .keyboardF5: return .F5
        case .keyboardF6: return .F6
        case .keyboardF7: return .F7
        case .keyboardF8: return .F8
        case .keyboardF9: return .F9
        case .keyboardF10: return .F10
        case .keyboardF11: return .F11
        case .keyboardF12: return .F12
        case .keyboardLeftShift: return .LeftShift
        case .keyboardRightShift: return .RightShift
        case .keyboardLeftControl: return .LeftControl
        case .keyboardRightControl: return .RightControl
        case .keyboardLeftAlt: return .LeftAlternate
        case .keyboardRightAlt: return .RightAlternate
        case .keyboardLeftGUI: return .LeftSuper
        case .keyboardRightGUI: return .RightSuper
        default:
            let physical = Ubiquitty.Keys.printableKeyForHID(UInt16(keyCode.rawValue))
            return physical == .None ? nil : physical
        }
    }

    /// UIKit's modifier flags as the bits Core reads.
    ///
    /// - Parameter flags: What UIKit reported.
    /// - Returns: The `KEYMAP_MOD_*` bitmask.
    static func modifierBits(_ flags: UIKeyModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.shift) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierShift) }
        if flags.contains(.alternate) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierAlternate) }
        if flags.contains(.control) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierCtrl) }
        if flags.contains(.command) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierSuper) }
        if flags.contains(.alphaShift) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierCapsLock) }
        return bits
    }

    /// Sided modifier state from the attached hardware keyboard.
    @MainActor
    private static func positionModifiers(_ flags: UIKeyModifierFlags) -> UInt32 {
        let input = GCKeyboard.coalesced?.keyboardInput
        var bits: UInt32 = flags.contains(.alphaShift) ? 4 : 0
        let keys: [(GCKeyCode, UInt32)] = [
            (.leftShift, 1), (.rightShift, 2), (.leftControl, 8), (.rightControl, 8),
            (.leftAlt, 16), (.rightAlt, 32), (.leftGUI, 64), (.rightGUI, 128),
        ]
        for (key, bit) in keys where input?.button(forKeyCode: key)?.isPressed == true {
            bits |= bit
        }
        if flags.contains(.shift), bits & 3 == 0 { bits |= 1 }
        if flags.contains(.control) { bits |= 8 }
        if flags.contains(.alternate), bits & 0x30 == 0 { bits |= 16 }
        return bits
    }

    /// The press a hardware key stands for, or nil to let UIKit deliver it as
    /// text through `insertText`.
    ///
    /// - Parameters:
    ///   - key: UIKit's key.
    ///   - eventType: The hardware press or release.
    /// - Returns: What the terminal needs to know.
    @MainActor
    static func keyPress(for key: UIKey, eventType: Ubiquitty.Keys.KeyEventType = .Press) -> Ubiquitty.Runtime.KeyPress? {
        var press = Ubiquitty.Runtime.KeyPress()
        press.eventType = eventType
        press.modifiers = modifierBits(key.modifierFlags) | (positionModifiers(key.modifierFlags) << 8)
        press.wasModified = !key.modifierFlags
            .intersection([.shift, .control, .alternate, .command]).isEmpty

        // The layout's own code points: what the key means with nothing held,
        // and what it reports with Shift still applied. Which of them the
        // terminal reports, and where the shifted glyph rides, is Core's.
        press.unshiftedCodePoint = key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
        press.shiftedCodePoint = press.unshiftedCodePoint

        if let named = virtualKey(for: key.keyCode) {
            press.virtualKey = named
        } else if press.unshiftedCodePoint == 0 {
            return nil // no key identity and no character: nothing to send
        }

        let modifier = UInt32(Ubiquitty.Keys.isoModifierKey(press.virtualKey))
        if modifier != 0 && press.virtualKey != .CapsLock {
            if eventType == .Release {
                press.modifiers &= ~(modifier << 8)
                let held = press.modifiers >> 8
                if held & 3 == 0 { press.modifiers &= ~UInt32(Ubiquitty.Keys.Keymap.keymapModifierShift) }
                if held & 8 == 0 { press.modifiers &= ~UInt32(Ubiquitty.Keys.Keymap.keymapModifierCtrl) }
                if held & 0x30 == 0 { press.modifiers &= ~UInt32(Ubiquitty.Keys.Keymap.keymapModifierAlternate) }
            } else {
                press.modifiers |= modifier << 8
            }
        }

        if !key.characters.isEmpty {
            let scalars = Array(
                key.characters.unicodeScalars.prefix(
                    Int(Ubiquitty.Keys.maxKeyEventTextLength)
                )
            )
            withUnsafeMutablePointer(to: &press.text) { storage in
                let slots = UnsafeMutableRawPointer(storage).assumingMemoryBound(to: UInt32.self)
                for (index, scalar) in scalars.enumerated() {
                    slots[index] = scalar.value
                }
            }
            press.textLength = Int32(scalars.count)
        }
        return press
    }

    /// The press a named key stands for, for the on-screen control row.
    ///
    /// - Parameter key: The key the row offers.
    /// - Returns: What the terminal needs to know.
    static func keyPress(for key: Ubiquitty.Keys.VirtualKey) -> Ubiquitty.Runtime.KeyPress {
        var press = Ubiquitty.Runtime.KeyPress()
        press.virtualKey = key
        return press
    }
}
