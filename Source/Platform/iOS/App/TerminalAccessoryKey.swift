// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import UbiquittyCore

/// The software keyboard's modifiers, independent of hardware key events.
///
/// A tap latches a modifier for the next key, a second tap locks it, and a
/// third releases it. A modifier held while another key is pressed applies to
/// that key and releases with the finger, without latching.
struct TerminalKeyboardModifiers {
    enum Modifier: CaseIterable, Hashable {
        case control, alternate, command, shift

        /// The word printed on the key cap, lowercase as on Apple's keyboards.
        var capTitle: String {
            switch self {
            case .control: "ctrl"
            case .alternate: "alt"
            case .command: "cmd"
            case .shift: "shift"
            }
        }

        /// What VoiceOver calls the key.
        var spokenName: String {
            switch self {
            case .control: "Control"
            case .alternate: "Alt"
            case .command: "Command"
            case .shift: "Shift"
            }
        }

        /// The SF Symbol a cap may show instead of its word.
        var symbol: String? {
            switch self {
            case .shift: "shift"
            case .control, .alternate, .command: nil
            }
        }

        /// The stable name UI tests and the iPad shortcuts bar find the key by.
        var accessibilityIdentifier: String {
            switch self {
            case .control: "terminal-modifier-Ctrl"
            case .alternate: "terminal-modifier-Alt"
            case .command: "terminal-modifier-Cmd"
            case .shift: "terminal-modifier-Shift"
            }
        }

        var bits: UInt32 {
            switch self {
            case .control: UInt32(Ubiquitty.Keys.Keymap.keymapModifierCtrl)
            case .alternate: UInt32(Ubiquitty.Keys.Keymap.keymapModifierAlternate)
            case .command: UInt32(Ubiquitty.Keys.Keymap.keymapModifierSuper)
            case .shift: UInt32(Ubiquitty.Keys.Keymap.keymapModifierShift)
            }
        }
    }

    enum State {
        case off, once, locked
    }

    enum PressEnd {
        case activate, cancel
    }

    private var states: [Modifier: State] = [:]
    private var held: Set<Modifier> = []
    private var usedWhileHeld: Set<Modifier> = []

    func state(of modifier: Modifier) -> State { states[modifier] ?? .off }
    func isHeld(_ modifier: Modifier) -> Bool { held.contains(modifier) }
    /// Whether a key has taken this modifier since its finger came down.
    func wasUsedWhileHeld(_ modifier: Modifier) -> Bool { usedWhileHeld.contains(modifier) }

    /// What VoiceOver says after the key's name.
    func spokenState(of modifier: Modifier) -> String {
        if isHeld(modifier) { return "Held" }
        switch state(of: modifier) {
        case .off: return "Off"
        case .once: return "Next key"
        case .locked: return "Locked"
        }
    }

    mutating func beginPress(_ modifier: Modifier) {
        held.insert(modifier)
        usedWhileHeld.remove(modifier)
    }

    mutating func endPress(_ modifier: Modifier, _ ending: PressEnd) {
        held.remove(modifier)
        let didChord = usedWhileHeld.remove(modifier) != nil
        if ending == .activate && !didChord { toggle(modifier) }
    }

    mutating func toggle(_ modifier: Modifier) {
        switch state(of: modifier) {
        case .off: states[modifier] = .once
        case .once: states[modifier] = .locked
        case .locked: states[modifier] = .off
        }
    }

    mutating func clear(_ modifier: Modifier) {
        states[modifier] = .off
        held.remove(modifier)
        usedWhileHeld.remove(modifier)
    }

    var bits: UInt32 {
        Modifier.allCases.reduce(0) { result, modifier in
            result | (state(of: modifier) == .off && !held.contains(modifier) ? 0 : modifier.bits)
        }
    }

    mutating func consume() -> UInt32 {
        let result = bits
        usedWhileHeld.formUnion(held)
        for modifier in Modifier.allCases where state(of: modifier) == .once { states[modifier] = .off }
        return result
    }
}

/// One key the terminal offers above or beside the software keyboard.
///
/// This is the one table of those keys. The iPhone row and the iPad shortcuts
/// bar are two presentations of it, and neither spells a byte: a press names
/// either a key with an identity of its own or a character, and Core encodes
/// it with the pending modifiers and the terminal's modes, the same encoder
/// the macOS and web frontends hand their keys to. So Control-C here is the
/// Control-C a Mac keyboard sends, Kitty keyboard mode included.
struct TerminalAccessoryKey: Identifiable {
    /// What pressing the key asks the terminal for.
    enum Press {
        /// A key with an identity of its own, which Core names on the wire.
        case key(Ubiquitty.Keys.VirtualKey)
        /// A character, encoded as if typed with the pending modifiers.
        case character(Unicode.Scalar)
    }

    /// What VoiceOver calls the key, and the suffix of its accessibility
    /// identifier.
    let spokenName: String
    /// The word or glyph printed on the cap.
    let capTitle: String
    /// The SF Symbol the cap shows in place of its title, where one names the key.
    let symbol: String?
    let press: Press

    var id: String { spokenName }
    var accessibilityIdentifier: String { "terminal-key-\(spokenName)" }

    /// Whether the cap shows one character, which pops up above the finger
    /// as the system keyboard's letters do.
    var showsPopUp: Bool {
        if case .character = press { return true }
        return false
    }

    private init(_ spokenName: String, cap capTitle: String, symbol: String? = nil, _ press: Press) {
        self.spokenName = spokenName
        self.capTitle = capTitle
        self.symbol = symbol
        self.press = press
    }

    private init(_ spokenName: String, character: Unicode.Scalar) {
        self.init(spokenName, cap: String(character), .character(character))
    }

    static let escape = TerminalAccessoryKey("Escape", cap: "esc", .key(.Escape))
    static let tab = TerminalAccessoryKey("Tab", cap: "tab", .key(.Tab))

    static let leftArrow = TerminalAccessoryKey("Left Arrow", cap: "←", symbol: "arrowtriangle.left.fill", .key(.LeftArrow))
    static let upArrow = TerminalAccessoryKey("Up Arrow", cap: "↑", symbol: "arrowtriangle.up.fill", .key(.UpArrow))
    static let downArrow = TerminalAccessoryKey("Down Arrow", cap: "↓", symbol: "arrowtriangle.down.fill", .key(.DownArrow))
    static let rightArrow = TerminalAccessoryKey("Right Arrow", cap: "→", symbol: "arrowtriangle.right.fill", .key(.RightArrow))

    /// The arrows, in the order the iPad shortcuts bar lays them out.
    static let arrows: [TerminalAccessoryKey] = [leftArrow, upArrow, downArrow, rightArrow]

    /// The characters a shell uses that the iOS keyboard keeps behind its
    /// 123 and #+= pages, most used first.
    static let symbols: [TerminalAccessoryKey] = [
        TerminalAccessoryKey("Tilde", character: "~"),
        TerminalAccessoryKey("Slash", character: "/"),
        TerminalAccessoryKey("Vertical Bar", character: "|"),
        TerminalAccessoryKey("Hyphen", character: "-"),
        TerminalAccessoryKey("Underscore", character: "_"),
        TerminalAccessoryKey("Backslash", character: "\\"),
        TerminalAccessoryKey("Grave Accent", character: "`"),
        TerminalAccessoryKey("Greater-Than Sign", character: ">"),
        TerminalAccessoryKey("Less-Than Sign", character: "<"),
        TerminalAccessoryKey("Asterisk", character: "*"),
        TerminalAccessoryKey("Dollar Sign", character: "$"),
        TerminalAccessoryKey("Ampersand", character: "&"),
        TerminalAccessoryKey("Semicolon", character: ";"),
        TerminalAccessoryKey("Equals Sign", character: "="),
        // copy-ok: the key types a straight apostrophe, which is what a shell quotes with
        TerminalAccessoryKey("Apostrophe", character: "'"),
        // copy-ok: the key types a straight quotation mark, which is what a shell quotes with
        TerminalAccessoryKey("Quotation Mark", character: "\""),
        TerminalAccessoryKey("Left Bracket", character: "["),
        TerminalAccessoryKey("Right Bracket", character: "]"),
        TerminalAccessoryKey("Left Brace", character: "{"),
        TerminalAccessoryKey("Right Brace", character: "}"),
    ]

    /// Core validates the bounded ordered subset; both keyboard presentations read it.
    static var configuredSymbols: [TerminalAccessoryKey] {
        let value = Ubiquitty.Preferences.effectiveValue(.KeysAccessorySymbols, Ubiquitty.Preferences.values().pointee).value
        return String(value?.text ?? std.string()).unicodeScalars
            .compactMap { scalar in
                symbols.first { key in
                    if case .character(let character) = key.press { return character == scalar }
                    return false
                }
            }
    }

    /// The function keys.
    static let functionKeys: [TerminalAccessoryKey] = {
        let keys: [Ubiquitty.Keys.VirtualKey] = [.F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12]
        return keys.enumerated()
            .map { index, key in
                TerminalAccessoryKey("F\(index + 1)", cap: "F\(index + 1)", .key(key))
            }
    }()

    /// The navigation and editing keys a full keyboard has and the iOS one
    /// lacks, in the words Apple's extended keyboards print on them.
    static let navigationKeys: [TerminalAccessoryKey] = [
        TerminalAccessoryKey("Home", cap: "home", .key(.Home)),
        TerminalAccessoryKey("End", cap: "end", .key(.End)),
        TerminalAccessoryKey("Page Up", cap: "page up", .key(.PageUp)),
        TerminalAccessoryKey("Page Down", cap: "page down", .key(.PageDown)),
        TerminalAccessoryKey("Insert", cap: "insert", .key(.Insert)),
        TerminalAccessoryKey("Forward Delete", cap: "delete", symbol: "delete.forward", .key(.ForwardDelete)),
    ]

    /// The second page of the row: function keys, then navigation keys.
    static let functionPage: [TerminalAccessoryKey] = functionKeys + navigationKeys
}

/// A Control chord offered by holding the Control key, the way holding a
/// letter offers its accents.
struct TerminalControlChord: Identifiable {
    /// The letter the chord is typed with.
    let letter: Unicode.Scalar

    var id: UInt32 { letter.value }
    /// The chord as Apple writes a key combination in text.
    var spokenName: String { "Control-\(String(letter).uppercased())" }
    /// The chord as a terminal prints it.
    var capTitle: String { "^\(String(letter).uppercased())" }
    var accessibilityIdentifier: String { "terminal-chord-\(String(letter).uppercased())" }

    /// Interrupt, end of input, suspend, history search, clear, line start,
    /// line end and erase word: the chords a shell session leans on.
    static let common: [TerminalControlChord] = {
        let letters: [Unicode.Scalar] = ["c", "d", "z", "r", "l", "a", "e", "w"]
        return letters.map { TerminalControlChord(letter: $0) }
    }()
}
