// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// This half of the surface is AppKit's. The events it answers — mouse
// buttons, a scroll wheel with momentum, NSEvent modifier flags, the
// AppKit text-input client — have no counterpart on a touch screen, so the
// UIKit shell answers its own and neither carries the other's model.
//
// Guarded rather than moved: it extends the shared surface, and keeping it
// beside what it extends is what stops the two halves drifting apart.

#if canImport(AppKit)

// TerminalSurface+Input.swift — an AppKit event becomes wire bytes without an
// Objective-C++ hop.
//
// Every table and every rule below the translation is Core's: the native key
// code maps to a portable identity through the frontend's one table
// (`UBKeyCodeMap.h`), the identity maps to a code point through
// `Core/Keys/KeyTranslation.h`, and the code point plus the terminal's live
// modes encode through `Core/Keys/Keymap.h` — the same encoder the Linux and
// Web frontends call. What this file decides is only what AppKit alone knows:
// which modifier flags were held, which characters the key produced, and
// whether the press was a repeat.
//
// The mode read is one lock-free snapshot per event. Reading the model directly
// would take the lock a flood holds hot, on the main thread, once per keystroke.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalSurface {
    /// Encodes one key event and writes it to the host.
    ///
    /// - Parameters:
    ///   - event: The AppKit event.
    ///   - eventType: Press, repeat or release. A repeat arrives as `.press`
    ///     and is reclassified here, because whether the host wants repeats
    ///     reported is a terminal mode rather than an AppKit fact.
    /// - Returns: Whether bytes were written. False is a legitimate outcome —
    ///   a dead key, a release under a terminal that reports none, or a repeat
    ///   suppressed by DECARM.
    @discardableResult
    package func sendKey(_ event: NSEvent, eventType: Ubiquitty.Keys.KeyEventType) -> Bool {
        guard let press = Self.keyPress(event, eventType: eventType) else {
            return false
        }
        let sent = sendKey(press)
        // A press acts on the live screen, so the view leaves history to show
        // it; a release only reports. The Metal arm draws the same line.
        if sent, eventType != .Release {
            snapToTailOnKeypress()
            // The caret holds solid over what is being typed, and the pointer
            // leaves until the next move. A release is not typing: it reports.
            noteUserActivity()
            hidePointerForTyping()
        }
        return sent
    }

    /// What AppKit reported, as the terminal's contract for a key press.
    ///
    /// The whole of this frontend's share: the key from the platform table,
    /// the modifier bits, the two layout code points and the text produced,
    /// read as the reader's `[keys] option_as_alt` says. Nothing here consults
    /// a terminal mode.
    ///
    /// - Returns: The press, or nil for an event carrying no key at all.
    private static func keyPress(
        _ event: NSEvent,
        eventType: Ubiquitty.Keys.KeyEventType
    ) -> Ubiquitty.Runtime.KeyPress? {
        var press = Ubiquitty.Runtime.KeyPress()
        press.eventType = eventType
        press.virtualKey = Ubiquitty.macOS.portableKeyForCode(event.keyCode)
        if press.virtualKey == .None, Int(event.keyCode) < physicalKeyUsages.count {
            press.virtualKey = Ubiquitty.Keys.printableKeyForHID(physicalKeyUsages[Int(event.keyCode)])
        }
        press.modifiers = modifierBits(event.modifierFlags) | (positionModifierBits(event.modifierFlags) << 8)
        press.wasModified = !event.modifierFlags
            .intersection([.shift, .control, .option, .command]).isEmpty

        // The repeat and character properties are defined for key events
        // alone; AppKit raises on the rest, and an Objective-C exception
        // crossing a Swift frame aborts rather than unwinding. A modifier
        // arrives as flags-changed, never repeats, and types nothing.
        let isKeyEvent = event.type == .keyDown || event.type == .keyUp
        press.isRepeat = isKeyEvent && event.isARepeat

        // charactersIgnoringModifiers keeps Shift applied — Apple documents it
        // as "as if no modifier except Shift" — so Shift+; yields ':' rather
        // than the base ';'. Applying an empty modifier set strips it to the
        // true layout base. Which of them reports is the terminal's ladder.
        press.unshiftedCodePoint =
            isKeyEvent
            ? UInt32(event.characters(byApplyingModifiers: [])?.utf16.first ?? 0) : 0
        press.shiftedCodePoint =
            isKeyEvent
            ? UInt32(event.charactersIgnoringModifiers?.utf16.first ?? 0) : 0

        // The Latin letter on this physical key, from the ASCII-capable layout
        // — the one the menu bar consults for ⌘ equivalents, and the one a
        // person on a Cyrillic, Greek or Hebrew layout types Latin on. Asked
        // only when the layout's own letter is not ASCII, as the chord path
        // asks it: under a Latin layout the ASCII-capable layout is the layout
        // in use, so the answer repeats the key, which Core discards. What
        // the letter folds to under Ctrl, and whether Kitty reports the
        // position beside it, is Core's.
        if press.unshiftedCodePoint >= 0x80 || press.shiftedCodePoint >= 0x80 {
            press.baseLayoutCodePoint = KeyboardLayout.asciiCapableCharacter(forKeyCode: event.keyCode)
        }

        if isKeyEvent, let typed = event.characters, !typed.isEmpty {
            let units = Array(typed.utf16.prefix(Int(Ubiquitty.Keys.maxKeyEventTextLength)))
            withUnsafeMutablePointer(to: &press.text) { storage in
                let slots = UnsafeMutableRawPointer(storage).assumingMemoryBound(to: UInt32.self)
                for (index, unit) in units.enumerated() {
                    slots[index] = UInt32(unit)
                }
            }
            press.textLength = Int32(units.count)
        }

        // An Option key `[keys] option_as_alt` leaves out is the layout's
        // third level. The input method hands a one-character ASCII commit
        // such as German Option-L's @ back to the key path, and Core drops the
        // Option bit from a key it shifted so the character goes out rather
        // than ESC l.
        let flags = event.modifierFlags
        return Ubiquitty.Runtime.pressUnderOptionAsAlternate(
            press,
            Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee),
            heldOptionKeys(flags),
            flags.contains(.command) ? .Held : .Up
        )
    }

    private static let physicalKeyUsages: [UInt16] = [
        4, 22, 7, 9, 11, 10, 29, 27, 6, 25, 100, 5, 20, 26, 8, 21,
        28, 23, 30, 31, 32, 33, 35, 34, 46, 38, 36, 45, 37, 39, 48, 18,
        24, 47, 12, 19, 0, 15, 13, 52, 14, 51, 49, 54, 56, 17, 16, 55,
        0, 44, 53, 0, 0, 0, 0, 0, 0, 57, 0, 0, 0, 0, 0, 0,
    ]

    /// Sided flags for DEC extended keyboard reports.
    private static func positionModifierBits(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = flags.contains(.capsLock) ? 4 : 0
        let keys: [(Ubiquitty.Keys.VirtualKey, UInt32)] = [
            (.LeftShift, 1), (.RightShift, 2), (.LeftControl, 8), (.RightControl, 8),
            (.LeftAlternate, 16), (.RightAlternate, 32), (.LeftSuper, 64), (.RightSuper, 128),
        ]
        for (key, bit) in keys where flags.rawValue & UInt(Ubiquitty.macOS.modifierDeviceMask(key)) != 0 {
            result |= bit
        }
        return result
    }

    /// Reads which Option keys a key event holds.
    ///
    /// The general `.option` flag cannot tell the left key from the right, so
    /// the side comes from the per-side bits AppKit reports in the flags' low
    /// byte, through the same device masks the modifier-key reports use.
    ///
    /// - Parameter flags: The event's modifier flags.
    /// - Returns: The held state Core's Option rules take.
    static func heldOptionKeys(_ flags: NSEvent.ModifierFlags) -> Ubiquitty.Input.AlternateModifier {
        let raw = flags.rawValue
        let leftMask = UInt(Ubiquitty.macOS.modifierDeviceMask(.LeftAlternate))
        let rightMask = UInt(Ubiquitty.macOS.modifierDeviceMask(.RightAlternate))
        return Ubiquitty.Input.alternateModifierForSides(
            flags.contains(.option),
            (raw & leftMask) != 0,
            (raw & rightMask) != 0
        )
    }

    /// Writes encoded bytes to the host, and echoes them when the terminal said
    /// the host will not.
    ///
    /// - Parameters:
    ///   - bytes: The encoded sequence, whose first `count` entries are live.
    ///   - count: How many bytes the terminal wrote.
    ///   - encoding: What it decided, including whether to echo.
    private func write(_ bytes: [CChar], count: Int, encoding: Ubiquitty.Runtime.KeyEncoding) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            drive.sendInput(base, count: count)
            if encoding.shouldEchoLocally {
                drive.feed(Span(_unsafeStart: base, count: count))
            }
        }
        observer?.terminalSurface(self, didTransmit: bytes, count: count)
    }

    /// Narrows AppKit's modifier flags to the encoder's bitmask.
    ///
    /// - Parameter flags: What AppKit reported.
    /// - Returns: The bits `Keymap` reads.
    public static func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.shift) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierShift) }
        if flags.contains(.option) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierAlternate) }
        if flags.contains(.control) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierCtrl) }
        if flags.contains(.command) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierSuper) }
        if flags.contains(.capsLock) { bits |= UInt32(Ubiquitty.Keys.Keymap.keymapModifierCapsLock) }
        return bits
    }
}

#endif
