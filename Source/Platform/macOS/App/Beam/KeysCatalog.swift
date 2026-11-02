// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// KeysCatalog.swift — the [keys] built-in action vocabulary + the user's live
// bindings, read DIRECTLY from the portable Core (Input catalog + Settings) via
// Swift/C++ interop. Feeds Beam's keyboard-only-actions provider and the
// shortcut cheat sheet — no ObjC.
//

import CxxStdlib
import UbiquittyCore

enum KeysCatalog {
    // The built-in action vocabulary: (token, label) pairs, single-sourced from
    // the Core catalog so nothing can drift from what parseAction recognizes.
    static func actionVocabulary() -> [(token: String, label: String)] {
        var count: Int32 = 0
        guard let entries = Ubiquitty.Input.namedActionCatalog(&count) else { return [] }
        return (0..<Int(count))
            .map { index in
                (String(cString: entries[index].token), String(cString: entries[index].label))
            }
    }

    // The user's live [keys] bindings for the cheat sheet: (spec, label) where
    // spec is the raw key-spec and label is the action's human name — a catalog
    // label for a built-in token, else the raw send:/macro:/command: string.
    static func userBindings() -> [(spec: String, label: String)] {
        let vocabulary = actionVocabulary()
        var out: [(spec: String, label: String)] = []
        for binding in Ubiquitty.Preferences.values().pointee.keyBindings {
            let spec: std.string = binding.spec
            let action: std.string = binding.action
            let actionString = String(action)
            let label = vocabulary.first { $0.token == actionString }?.label ?? actionString
            out.append((String(spec), label))
        }
        return out
    }
}
