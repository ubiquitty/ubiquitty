// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// KeysPane.swift — the in-window [keys] binding editor. Lists the global
// key bindings (spec -> action), and adds / edits / removes them. A new
// binding's chord is captured by a small NSView key-capture control that
// renders an NSEvent into the same spec string the Input parser consumes
// ("cmd+shift+k"); the action is chosen from the built-in vocabulary or a
// raw "send:<bytes>" / "command:<id>" string.
//
// Reads + writes funnel through the application delegate: the whole [keys]
// table is rewritten on every change, Preferences::values().keyBindings is
// refreshed, and TerminalSurface.keyBindingsDidChangeNotification is posted so every
// live view rebuilds its binding table. Settings stays the single source of
// truth.
//

import AppKit
import SwiftUI

// One editable binding row.
private struct KeyBinding: Identifiable {
    let id = UUID()
    var spec: String
    var action: String
}

// The built-in named actions, in a sensible menu order. The raw string is
// what lands in config.toml; the label is the human-facing name. "send:"
// and "command:" are entered free-form via the action text field.
private struct ActionChoice: Identifiable, Hashable {
    let id: String // the raw action token, or "" for custom
    let label: String
}

// The built-in choices, projected from Core's catalog rather than written out
// again. A second list drifts one way: this one carried 18 of the catalog's 21
// and the three it lacked — clear, select_all, toggle_beam — were bindable all
// along, so a user with `action = "clear"` in config.toml saw it classified as a
// custom send-string by the editor below and its label rendered as the raw
// token. Core parsed the binding correctly the whole time; only the pane
// disagreed about what it was.
//
// The trailing custom entry is this pane's own, not Core's: "" is the sentinel
// the editor uses for a free-form send:/command: string, which is not an action
// and has no catalog token.
private let namedActions: [ActionChoice] =
    KeysCatalog.actionVocabulary()
    .map { ActionChoice(id: $0.token, label: $0.label) }
    + [ActionChoice(id: "", label: "Send Bytes / Command…")]

struct KeysPane: View {
    @State
    private var bindings: [KeyBinding] = []
    @State
    private var session = EditSession<KeyBinding>()

    @State
    private var optionPolicy = "none"

    var body: some View {
        SettingsPaneStack {
            SettingsCardView(
                title: "Option Key",
                footer:
                    "Option normally types your keyboard layout’s characters and accents. Use Meta for shell shortcuts and Emacs; leave one Option key unchanged if your layout needs it for @ or brackets."
            ) {
                SettingsListRow(isFirst: true) {
                    HStack {
                        Text("Use Option as Meta")
                        Spacer()
                        SettingsPopUpButton(
                            options: ["Neither Key", "Left Option", "Right Option", "Both Keys"],
                            selectedIndex: ["none", "left", "right", "both"].firstIndex(of: optionPolicy) ?? 0,
                            select: { index in
                                let tokens = ["none", "left", "right", "both"]
                                guard tokens.indices.contains(index) else { return }
                                let value = tokens[index]
                                if setOptionAsAlternate(value) {
                                    optionPolicy = value
                                } else {
                                    presentError(
                                        "Couldn’t Save Keyboard Setting",
                                        informativeText: "Check that your configuration file is writable, then try again."
                                    )
                                }
                            }
                        )
                        .accessibilityLabel("Use Option as Meta")
                        .accessibilityIdentifier("keys.option_as_alt")
                        .settingsSearchTarget("keys.option_as_alt")
                    }
                }
            }
            SettingsCardView(
                title: "Key Bindings",
                footer:
                    "Bindings override terminal shortcuts. Shortcuts already assigned in the macOS menu bar take precedence. Use “+” between modifiers and a key, and spaces between chords in a sequence."
            ) {
                if bindings.isEmpty {
                    SettingsListRow(isFirst: true) {
                        Text("No custom bindings.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(bindings) { binding in
                        SettingsListRow(isFirst: binding.id == bindings.first?.id) {
                            row(binding)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Add Binding", systemImage: "plus") {
                    session.new(KeyBinding(spec: "", action: "copy"))
                }
                .settingsSearchTarget("keys.add-binding")
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $session.editing) { binding in
            KeyBindingSheet(
                binding: binding,
                isNew: session.isNew,
                onCommit: { commit($0) },
                onCancel: {}
            )
        }
    }

    @ViewBuilder
    private func row(_ binding: KeyBinding) -> some View {
        HStack(spacing: 12) {
            Text(binding.spec)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 140, alignment: .leading)
            Text(actionLabel(binding.action))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Edit") { session.edit(binding) }
            Button(role: .destructive) {
                remove(binding)
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    private func actionLabel(_ raw: String) -> String {
        if let m = namedActions.first(where: { $0.id == raw && !$0.id.isEmpty }) {
            return m.label
        }
        return raw
    }

    // MARK: data

    private func reload() {
        switch Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) {
        case .None: optionPolicy = "none"
        case .Left: optionPolicy = "left"
        case .Right: optionPolicy = "right"
        case .Both: optionPolicy = "both"
        }
        let specs = SettingsBridge.app?.settingsKeyBindingSpecs() ?? []
        let actions = SettingsBridge.app?.settingsKeyBindingActions() ?? []
        bindings = zip(specs, actions).map { KeyBinding(spec: $0, action: $1) }
    }

    private func remove(_ binding: KeyBinding) {
        bindings.removeAll { $0.id == binding.id }
        persist()
    }

    private func commit(_ binding: KeyBinding) {
        if let index = bindings.firstIndex(where: { $0.id == binding.id }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
        persist()
    }

    private func persist() {
        let specs = bindings.map { $0.spec }
        let actions = bindings.map { $0.action }
        SettingsBridge.app?.settingsSetKeyBindingSpecs(specs, actions: actions)
        reload()
    }
}

// The add/edit sheet: capture a chord, pick an action.
private struct KeyBindingSheet: View {
    @State
    var binding: KeyBinding
    let isNew: Bool
    let onCommit: (KeyBinding) -> Void
    let onCancel: () -> Void

    @State
    private var choice: String
    @State
    private var sendText: String

    init(
        binding: KeyBinding,
        isNew: Bool,
        onCommit: @escaping (KeyBinding) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _binding = State(initialValue: binding)
        self.isNew = isNew
        self.onCommit = onCommit
        self.onCancel = onCancel
        // Seed the picker: a named action selects itself; anything else
        // (send:/command:/unknown) falls into the custom slot.
        let named = namedActions.contains { $0.id == binding.action && !$0.id.isEmpty }
        _choice = State(initialValue: named ? binding.action : "")
        _sendText = State(initialValue: named ? "" : binding.action)
    }

    private var resolvedAction: String {
        choice.isEmpty ? sendText : choice
    }

    private var isValid: Bool {
        guard !binding.spec.isEmpty, !resolvedAction.isEmpty else { return false }
        return SettingsBridge.app?
            .settingsValidateKeySpec(
                binding.spec,
                action: resolvedAction
            ) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Binding" : "Edit Binding").font(.headline)

            HStack {
                Text("Shortcut").frame(width: 80, alignment: .leading)
                KeyCaptureField(spec: $binding.spec)
                    .frame(width: 240, height: 24)
            }

            HStack {
                Text("Action").frame(width: 80, alignment: .leading)
                Picker("", selection: $choice) {
                    ForEach(namedActions) { a in
                        Text(a.label).tag(a.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            if choice.isEmpty {
                HStack {
                    Text("").frame(width: 80)
                    TextField("send:\\x18  or  command:my_cmd", text: $sendText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }

            ModalButtons(
                saveDisabled: !isValid,
                onCancel: onCancel,
                onSave: {
                    binding.action = resolvedAction
                    onCommit(binding)
                }
            )
        }
        .padding(24)
        .frame(width: 400)
    }
}

// NSView that records the next key chord and renders it into the Input
// spec string. Click to focus, then press the shortcut.
private struct KeyCaptureField: NSViewRepresentable {
    @Binding
    var spec: String

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onCapture = { spec = $0 }
        v.spec = spec
        return v
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.spec = spec
        view.needsDisplay = true
    }

    final class CaptureView: NSView {
        var onCapture: ((String) -> Void)?
        var spec: String = "" { didSet { needsDisplay = true } }
        private var capturing = false

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let background =
                capturing
                ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                : NSColor.textBackgroundColor
            background.setFill()
            let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()

            let text =
                capturing
                ? "Press a shortcut…"
                : (spec.isEmpty ? "Click to record" : spec)
            let color =
                (capturing || spec.isEmpty)
                ? NSColor.secondaryLabelColor
                : NSColor.labelColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ]
            let s = NSAttributedString(string: text, attributes: attributes)
            let size = s.size()
            s.draw(at: NSPoint(x: 8, y: (bounds.height - size.height) / 2))
        }

        override func mouseDown(with event: NSEvent) {
            capturing = true
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            capturing = false
            needsDisplay = true
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard capturing else {
                super.keyDown(with: event)
                return
            }
            if let captured = KeySpec.from(event) {
                spec = captured
                onCapture?(captured)
            }
            capturing = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // While recording, swallow shortcuts so e.g. cmd+W records
            // instead of closing the sheet.
            if capturing {
                keyDown(with: event)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

// Render an NSEvent key press into the Input key-spec grammar
// ("cmd+shift+k"). Mirrors the modifier tokens parseKeySpec accepts and
// the named-key vocabulary.
enum KeySpec {
    static func from(_ event: NSEvent) -> String? {
        guard let key = keyToken(event) else { return nil }
        var parts: [String] = []
        let f = event.modifierFlags
        if f.contains(.command) { parts.append("cmd") }
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("alt") }
        if f.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static func keyToken(_ event: NSEvent) -> String? {
        // Named keys by virtual keycode (layout-independent).
        switch event.keyCode {
        case 36, 76: return "enter"
        case 48: return "tab"
        case 53: return "escape"
        case 49: return "space"
        case 51: return "backspace"
        case 117: return "delete"
        case 114: return "insert"
        case 126: return "up"
        case 125: return "down"
        case 123: return "left"
        case 124: return "right"
        case 116: return "pageup"
        case 121: return "pagedown"
        case 115: return "home"
        case 119: return "end"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        default: break
        }
        // Printable: use the characters ignoring modifiers (so shift+'2'
        // records as shift+2, not '@'), lower-cased to match the parser's
        // base-layout codepoint.
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
            let c = chars.lowercased().first,
            c.isLetter || c.isNumber
                || "`-=[]\\;',./".contains(c)
        else {
            return nil
        }
        return String(c)
    }
}
