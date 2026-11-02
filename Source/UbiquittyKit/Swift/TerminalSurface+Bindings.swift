// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Bindings.swift — the user's [keys] section, on this arm.
//
// The machinery is shared: `Input::BindingTable` parses the specs,
// `Input::ChordResolver` runs the leader state machine, and the Web and Linux
// frontends drive both. This file is where this arm asks them.
//
// Order matters and is not this file's to choose: a binding gets the key
// before the input method and before the default keymap, because a user who
// bound a chord means that chord and not whatever their layout would have
// produced. `routeKeyPress` is where that order lives; this supplies the
// translation into a chord and the execution of what comes back.

internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit

extension TerminalSurface {
    /// What consulting the bindings concluded about a key.
    internal enum BindingOutcome {
        /// Unbound: the key belongs to whatever would have had it.
        case notBound
        /// Spent — a binding fired, or a leader is capturing.
        case consumed
    }

    /// Offers a key to the user's bindings and performs what matches.
    ///
    /// - Parameter event: The key press.
    /// - Returns: Whether the key was spent.
    internal func consultKeyBindings(_ event: NSEvent) -> BindingOutcome {
        guard let chord = Self.keyChord(for: event) else {
            return .notBound
        }
        guard let action = drive.feedKeyChord(key: chord.key, modifiers: chord.modifiers) else {
            // A leader in progress spends the key without firing anything; an
            // unbound key spends nothing. Both answer nil, and they ask
            // opposite things of the caller.
            return drive.isChordPending ? .consumed : .notBound
        }
        perform(action)
        return .consumed
    }

    /// The name posted when the `[keys]` configuration changes.
    ///
    /// Every view watches it and rebuilds: an edited table that reached only the
    /// window that was open when the reader saved would be found half-applied
    /// by the others.
    public static let keyBindingsDidChangeNotification = Notification.Name("UBTerminalViewKeyBindingsDidChange")

    /// Offers a key to the compose path.
    ///
    /// After the bindings, so a binding on the same key wins, and before the
    /// input method and the keymap — the order the other two arms take.
    ///
    /// The character fed is the one the key actually produced, not the
    /// unshifted one a chord is matched on: a sequence keys on `"` and `~`,
    /// which are what shift made of those keys.
    ///
    /// - Parameter event: The key press.
    /// - Returns: Whether the key was spent.
    internal func consultComposeKey(_ event: NSEvent) -> BindingOutcome {
        guard drive.isComposeArmed, let chord = Self.keyChord(for: event) else {
            return .notBound
        }
        let typed = event.characters?.unicodeScalars.first?.value ?? 0
        switch drive.offerKeyToCompose(key: chord.key, modifiers: chord.modifiers, typedCodePoint: typed) {
        case .write:
            guard let scalar = Unicode.Scalar(drive.composedCharacter) else {
                return .consumed
            }
            transmitAsUserInput(String(Character(scalar)))
            return .consumed
        case .swallow:
            return .consumed
        case .pass:
            return .notBound
        @unknown default:
            // A value this build does not know is not a key to swallow: the
            // press takes the path it would have taken with compose off.
            return .notBound
        }
    }

    /// Offers a key to the built-in default bindings.
    ///
    /// Asked on the key-equivalent pass rather than on key-down: a default that
    /// summons an overlay has to toggle it back off while the overlay holds
    /// first responder, which is exactly when key-down no longer reaches the
    /// surface. Whether a default still stands, since a user who rebinds its
    /// action replaces it, is Core's decision, so a shell asks rather than
    /// checks.
    ///
    /// - Parameter event: The key press.
    /// - Returns: Whether the key was spent.
    internal func consultDefaultKeyBindings(_ event: NSEvent) -> BindingOutcome {
        guard let chord = Self.keyChord(for: event),
            let action = drive.feedDefaultKeyChord(key: chord.key, modifiers: chord.modifiers)
        else {
            return .notBound
        }
        if window.map({ TerminalWindowController.beamPresenter?.isActive($0) ?? false }) == true,
            action.kind != UInt8(Ubiquitty.Input.ActionKind.ToggleBeam.rawValue)
        {
            return .notBound
        }
        perform(action)
        return .consumed
    }

    /// Performs a palette command through the terminal's key-action dispatcher.
    ///
    /// - Parameter token: The action token from Core's catalog.
    public func performKeyAction(named token: String) {
        guard let action = RuntimeDrive.ResolvedBinding.named(token) else { return }
        perform(action)
    }

    /// Selects a tab when this is a Cmd+digit accelerator.
    ///
    /// The digit-1..9 and accelerator-only parse is `Input::commandNumberTabPosition`,
    /// shared with the Metal arm: no menu item backs this gesture, so without
    /// a shared parse each arm decides for itself what counts as the chord.
    ///
    /// - Parameter event: The key press.
    /// - Returns: Whether a tab was selected.
    /// The tab-selection action, by name.
    ///
    /// A string rather than `#selector`: this one is implemented on the app
    /// delegate, which the Kit cannot name. Everything else here reaches a
    /// Swift method and is checked by the compiler.
    private static let selectTabAction = NSSelectorFromString("selectTab:")

    internal func selectTabForCommandNumber(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        let held = event.modifierFlags.intersection(relevant)
        guard let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first
        else {
            return false
        }
        let position = Ubiquitty.Input.commandNumberTabPosition(
            held == [.command] ? .AcceleratorOnly : .OtherModifiers,
            scalar.value
        )
        guard position != 0 else { return false }
        let item = NSMenuItem(title: "", action: NSSelectorFromString("selectTab:"), keyEquivalent: "")
        item.tag = Int(position)
        return NSApp.sendAction(NSSelectorFromString("selectTab:"), to: nil, from: item)
    }

    /// The chord a key event names, in the spelling bindings are written in.
    ///
    /// - Parameter event: The key press.
    /// - Returns: The chord, or nil for a dead key with no character.
    private static func keyChord(for event: NSEvent) -> (key: UInt32, modifiers: UInt32)? {
        // The same bits the encoder reads, narrowed to the four a binding may
        // name: caps lock is a state, not a chord.
        let modifiers = TerminalSurface.modifierBits(event.modifierFlags) & UInt32(Ubiquitty.Input.bindModMask)
        // A functional key names itself, whatever the layout produces for it.
        let functional = Ubiquitty.Keys.functionalKeyCodePoint(Ubiquitty.macOS.portableKeyForCode(event.keyCode))
        if functional != 0 {
            return (functional, modifiers)
        }
        guard let base = event.charactersIgnoringModifiers, let first = base.unicodeScalars.first else {
            return nil
        }
        // The layout's unshifted character for this physical key, which Core
        // uses for two cases: a non-Latin layout, where the reported character
        // is Cyrillic or Greek while bindings are written in ASCII; and any
        // shifted chord, where the reported character is what shift produced
        // (`{`) rather than the key a binding names (`[`). Asked only in those
        // cases, because it is a layout query per keystroke.
        let needsLayout = first.value >= 0x80 || (modifiers & UInt32(Ubiquitty.Input.bindModShift)) != 0
        let unshifted: UInt32 = needsLayout ? KeyboardLayout.asciiCapableCharacter(forKeyCode: event.keyCode) : 0
        return (Ubiquitty.Input.resolveChordKey(first.value, unshifted, modifiers), modifiers)
    }

    /// Performs a matched binding.
    ///
    /// - Parameter action: What the resolver returned.
    private func sendWindowAction(_ selector: Selector) {
        // Window-shaped commands have no meaning on a surface: they belong to
        // whatever owns the window, and the responder chain is how a menu item
        // would have reached it too.
        NSApp.sendAction(selector, to: nil, from: self)
    }

    private func perform(_ action: RuntimeDrive.ResolvedBinding) {
        switch Ubiquitty.Input.ActionKind(rawValue: Int32(action.kind)) {
        case .SendBytes:
            // Core has decoded the escapes; preserve arbitrary bytes while
            // retaining the input path's selection, activity, and broadcast effects.
            transmitAsUserInput(action.bytes.map { CChar(bitPattern: $0) })
        case .Macro:
            invokeMacro(named: action.name)
        case .Copy:
            _ = copySelection()
        case .Paste:
            // Paste is the shell's: it owns the pasteboard read and the
            // bracketed-paste confirmation Core decides on. The selector is
            // the one the Edit menu targets — NSResponder has no `paste:` to
            // fall back on, so a near-miss here is a binding that does nothing.
            sendWindowAction(#selector(TerminalWindowController.pasteFromPasteboard(_:)))
        case .ScrollLineUp:
            offsetView(byLines: 1)
        case .ScrollLineDown:
            offsetView(byLines: -1)
        case .ScrollPageUp:
            // Core's one page rule, the amount the Cmd-PgUp chord and the
            // scroller's track click also take, so a bound page and a built-in
            // page move the viewport the same distance.
            offsetView(byLines: Int(Ubiquitty.Keys.pageLinesForRows(publishedGrid.rows)))
        case .ScrollPageDown:
            offsetView(byLines: -Int(Ubiquitty.Keys.pageLinesForRows(publishedGrid.rows)))
        case .ScrollToTop:
            setViewOffset(absolute: Int(Int32.max))
        case .ScrollToBottom:
            setViewOffset(absolute: 0)
        case .ClearScrollback:
            runClearCommand(.Scrollback)
        case .ClearScreen:
            runClearCommand(.Screen)
        case .ClearBuffer:
            runClearCommand(.Buffer)
        case .SelectAll:
            selectAll(nil)
        case .IncreaseFontSize:
            sendWindowAction(#selector(TerminalWindowController.growFontSize(_:)))
        case .DecreaseFontSize:
            sendWindowAction(#selector(TerminalWindowController.shrinkFontSize(_:)))
        case .ResetFontSize:
            sendWindowAction(#selector(TerminalWindowController.resetFontSize(_:)))
        case .ToggleFullscreen:
            sendWindowAction(#selector(NSWindow.toggleFullScreen(_:)))
        case .NewTab:
            // These two reach the app delegate, which the Kit cannot name, so
            // they are built from a string rather than #selector. Everything
            // else in this switch names a Swift method and is checked by the
            // compiler, which a string selector cannot be: a near-miss in one
            // of them builds clean and binds a dead key.
            sendWindowAction(NSSelectorFromString("newTab:"))
        case .NewWindow:
            sendWindowAction(NSSelectorFromString("newWindow:"))
        case .CloseTab:
            sendWindowAction(#selector(NSWindow.performClose(_:)))
        case .NextTab:
            // AppKit's own tab selection, which wraps at each end of the group:
            // a terminal that stopped at the last tab would be the one
            // application on the desktop that does. Called on this surface's
            // own window rather than sent down the responder chain, because the
            // group to cycle is this window's — a chain walk answers from
            // whatever holds the responder, which is a find field or a palette
            // as readily as the terminal.
            lastTabSelectionDirectionForTesting = 1
            window?.selectNextTab(nil)
        case .PrevTab:
            lastTabSelectionDirectionForTesting = -1
            window?.selectPreviousTab(nil)
        case .ToggleBeam:
            // The palette is window furniture, one overlay per window, and only
            // a shell has one, so it goes to the window's controller. Called
            // rather than sent: while the palette itself holds first responder
            // the chain would end in its field, and the toggle that dismisses
            // it would never arrive.
            (window?.windowController as? TerminalWindowController)?.toggleBeam(nil)
        default:
            // An unrecognised action consumes its binding without typing the key.
            break
        }
    }

    /// Sends a configured macro through the user-input path.
    ///
    /// - Parameter name: The macro name in the live configuration.
    public func invokeMacro(named name: String) {
        guard
            let body = Ubiquitty.Preferences.findMacroBody(
                Ubiquitty.Preferences.values().pointee,
                std.string(name)
            )
        else { return }
        var decoded = std.string()
        guard Ubiquitty.Input.decodeSendPayload(body.pointee, &decoded), !decoded.empty() else { return }
        transmitAsUserInput((0..<decoded.size()).map { decoded[$0] })
    }
}
#endif
