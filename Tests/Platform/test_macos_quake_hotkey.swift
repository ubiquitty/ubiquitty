// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_macos_quake_hotkey.swift — the drop-down terminal's
// `[quake] hotkey` spec reads into the Carbon chord the global hotkey registers:
// the modifier spellings Input::Keybindings uses, named keys, digits, letters
// and F1 to F20 through a fixed ANSI table, ASCII case and blanks ignored, and
// no chord for a spec that names no key.
//
// Compiled by plain `xcrun swiftc` with QuakeHotkey.swift alone. A failure
// prints FAIL file:line, and any failure exits nonzero.
//

import Carbon
import Foundation

var failures = 0

func check(_ condition: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition {
        print("FAIL \(file):\(line): \(what)")
        failures += 1
    }
}

func chord(_ spec: String) -> (UInt32, UInt32)? {
    QuakeHotkey(spec: spec).map { ($0.modifiers, $0.keyCode) }
}

@main
struct QuakeHotkeyTest {
    static func main() {
        let control = UInt32(controlKey)
        let command = UInt32(cmdKey)
        let option = UInt32(optionKey)
        let shift = UInt32(shiftKey)

        check(chord("control+grave")! == (control, UInt32(kVK_ANSI_Grave)), "the default spec is control and the grave key")
        check(
            chord("Ctrl + `")! == (control, UInt32(kVK_ANSI_Grave)),
            "blanks and ASCII case do not matter, and a backtick is the grave key"
        )
        check(chord("cmd+shift+t")! == (command | shift, UInt32(kVK_ANSI_T)), "modifiers combine")
        check(chord("super+win+command+cmd+a")! == (command, UInt32(kVK_ANSI_A)), "every command spelling is command")
        check(chord("alt+opt+option+meta+1")! == (option, UInt32(kVK_ANSI_1)), "every option spelling is option, and digits are keys")
        check(chord("space")! == (0, UInt32(kVK_Space)), "a named key alone is a chord")
        check(chord("enter")! == chord("return")!, "enter and return are one key")
        check(chord("esc")! == (0, UInt32(kVK_Escape)) && chord("tab")! == (0, UInt32(kVK_Tab)), "escape and tab are named keys")
        check(chord("F1")! == (0, UInt32(kVK_F1)) && chord("f20")! == (0, UInt32(kVK_F20)), "F1 to F20 are keys")
        check(chord("f21") == nil && chord("f0") == nil && chord("f1x") == nil, "a function key outside F1 to F20 is no key")
        check(chord("x+y")! == (0, UInt32(kVK_ANSI_Y)), "of several keys the last wins")
        check(chord("ctrl+unknown+k")! == (control, UInt32(kVK_ANSI_K)), "an unknown token is skipped")
        check(chord("ctrl+shift") == nil && chord("") == nil, "a spec that names no key is no chord")
        check(chord("\u{212A}") == nil, "a letter outside ASCII that lowers to k is not the k key")

        if failures == 0 {
            print("test_macos_quake_hotkey: the drop-down hotkey spec reads into the chord the global hotkey registers")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
