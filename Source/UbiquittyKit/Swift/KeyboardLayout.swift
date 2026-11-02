// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// KeyboardLayout.swift — the Latin letter a physical key carries.
//
// Bindings are written in ASCII. Under a Russian or Greek layout the character
// a key produces is not, so a chord written `cmd+k` would never match the key
// the user thinks of as K. Asking the current ASCII-CAPABLE layout what that
// physical key would produce recovers it — which is the same recovery the menu
// bar performs for its own key equivalents, and the reason ⌘C keeps working
// when the layout changes.
//
// The Metal arm has this in Objective-C, and that file says in its own header
// not to grow: it is being retired. So this is the Swift arm's, not a bridge
// into it.

import Carbon.HIToolbox
import Foundation

/// The current ASCII-capable keyboard layout.
enum KeyboardLayout {
    /// The unshifted character a physical key produces under the current
    /// ASCII-capable layout.
    ///
    /// - Parameter keyCode: The hardware key code.
    /// - Returns: The character, or 0 when the layout cannot say.
    static func asciiCapableCharacter(forKeyCode keyCode: UInt16) -> UInt32 {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return 0
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers: the unshifted character is what a chord names
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return 0 }
        return UInt32(characters[0])
    }
}
