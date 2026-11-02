// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// PlatformPane.swift — the [mac]/[linux] override editor
// (Docs/platform-config-and-sync.md). For a chosen platform, each overridable
// presentation field shows the base (live global config) value and an
// Override toggle gating the platform's value. Setting writes the key into the
// [<plat>] section; clearing strips it, so the resolver inherits the base.
//
// Reads + writes funnel through the application delegate: base values, the
// per-platform override dictionary, and a single set/unset call per field.
// On this build's own platform the override applies live. Settings stays the
// single source of truth.
//

import AppKit
import SwiftUI

// One overridable field's metadata: the bridge token, label, and whether
// it edits a number (with range/unit) or free text.
private struct PlatformField: Identifiable {
    let id: String // the bridge token (PlatformField* value)
    let label: String
    let numeric: Bool
    let unit: String
    let lo: Double
    let hi: Double
    let placeholder: String

    static func text(_ id: String, _ label: String, _ ph: String) -> PlatformField {
        PlatformField(
            id: id,
            label: label,
            numeric: false,
            unit: "",
            lo: 0,
            hi: 0,
            placeholder: ph
        )
    }
    // `schema` names the (section, key) whose shared bounds + unit drive this
    // numeric field — resolved through SettingsCatalog.bounds (the Settings schema
    // bridge), the same source the global control and the parse clamp read, so
    // no range/unit literals are re-spelled here.
    static func number(
        _ id: String,
        _ label: String,
        schema: (section: String, key: String)
    ) -> PlatformField {
        let bounds = SettingsCatalog.bounds(schema.section, schema.key)
        return PlatformField(
            id: id,
            label: label,
            numeric: true,
            unit: bounds.unit,
            lo: bounds.minimum,
            hi: bounds.maximum,
            placeholder: ""
        )
    }
}

// Tokens must match the PlatformField* ObjC constants' string values.
//
// The numeric range + unit per field are not spelled here: each
// .number row names its (section, key) and draws its bounds from the shared
// Settings schema (via SettingsCatalog.bounds), the same source the global
// Settings control and the TOML parse clamp read.
//
// NOTE: the canonical token→key→kind list still lives once in C++ —
// Source/Core/Preferences/Profile.h's `platformOverrideFields` — which the application
// bridge (App/ApplicationBridge.cpp) already walks. This Swift array is the THIRD copy of the
// token + label list; it should consume the generated tokens from that single
// source once a token bridge exists. Until then, keep these rows in step with
// the C++ list.
private let platformFields: [PlatformField] = [
    .text("theme", "Theme", "Theme name"),
    .text("fontFamily", "Font Family", "JetBrains Mono"),
    .text("fallbackFont", "Symbol Fallback", "Symbols Nerd Font"),
    .number("fontSize", "Font Size", schema: ("font", "size")),
    .number("lineSpacing", "Line Spacing", schema: ("font", "line_spacing")),
    .number("paddingLeft", "Padding Left", schema: ("appearance", "padding_left")),
    .number("paddingRight", "Padding Right", schema: ("appearance", "padding_right")),
    .number("paddingTop", "Padding Top", schema: ("appearance", "padding_top")),
    .number("titlelessPaddingTop", "Titleless Top Padding", schema: ("appearance", "titleless_padding_top")),
    .number("paddingBottom", "Padding Bottom", schema: ("appearance", "padding_bottom")),
    .text("startupHost", "Startup Command", "Leave blank for a local shell"),
]

private let platformLabels = ["macOS", "Linux"]

struct PlatformPane: View {
    @State
    private var platform = 0
    @State
    private var base: [String: Any] = [:]
    @State
    private var overrides: [String: Any] = [:]

    var body: some View {
        SettingsPaneStack {
            SettingsCardView(
                title: "Platform",
                footer:
                    "An override applies on its own platform and is ignored elsewhere. Cleared fields use the global settings. The highlighted platform is the one this Mac runs."
            ) {
                SettingsListRow(isFirst: true) {
                    HStack {
                        Text("Platform")
                        Spacer()
                        Picker("", selection: $platform) {
                            ForEach(0..<platformLabels.count, id: \.self) { i in
                                Text(platformLabels[i]).tag(i)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            }
            SettingsCardView(title: "Overrides") {
                ForEach(Array(platformFields.enumerated()), id: \.element.id) { index, field in
                    SettingsListRow(isFirst: index == 0) {
                        FieldRow(
                            field: field,
                            baseValue: baseDisplay(field),
                            override: bindingFor(field)
                        )
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChangeCompatibility(of: platform) { reload() }
    }

    // MARK: data

    private func reload() {
        base = SettingsBridge.app?.settingsPlatformBaseValues() ?? [:]
        overrides = SettingsBridge.app?.settingsPlatformOverrides(forPlatform: platform) ?? [:]
    }

    private func baseDisplay(_ field: PlatformField) -> String {
        guard let v = base[field.id] else { return "—" }
        if field.numeric, let n = v as? NSNumber {
            return "\(Int(n.doubleValue.rounded())) \(field.unit)"
        }
        return (v as? String) ?? "—"
    }

    // A binding over the platform override value for `field`. nil means the
    // field is not overridden; setting/clearing it round-trips to the bridge.
    private func bindingFor(_ field: PlatformField) -> Binding<Any?> {
        Binding(
            get: { overrides[field.id] },
            set: { newValue in
                if let v = newValue {
                    overrides[field.id] = v
                    SettingsBridge.app?
                        .settingsSetPlatformOverride(
                            platform,
                            field: field.id,
                            value: v
                        )
                } else {
                    overrides.removeValue(forKey: field.id)
                    SettingsBridge.app?
                        .settingsSetPlatformOverride(
                            platform,
                            field: field.id,
                            value: nil
                        )
                }
            }
        )
    }
}

// The view targets the macOS 13 deployment floor, where only the deprecated
// one-parameter onChange exists; macOS 14 deprecates it in favor of the
// two-parameter overload. Branch on availability so neither build warns.

// One field row: label, base value, Override toggle, value editor.
private struct FieldRow: View {
    let field: PlatformField
    let baseValue: String
    let override: Binding<Any?>

    private var isOn: Bool { override.wrappedValue != nil }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                Text("base: \(baseValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isOn {
                editor
            } else {
                Text("inherits").foregroundStyle(.secondary).font(.callout)
            }
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { on in
                        if on { override.wrappedValue = defaultValue() } else { override.wrappedValue = nil }
                    }
                )
            )
            .labelsHidden().toggleStyle(SettingsSwitchStyle())
            .accessibilityLabel("Override \(field.label)")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if field.numeric {
            let current = (override.wrappedValue as? NSNumber)?.doubleValue ?? field.lo
            Stepper(
                value: Binding(
                    get: { (override.wrappedValue as? NSNumber)?.doubleValue ?? field.lo },
                    set: { override.wrappedValue = NSNumber(value: min(max($0, field.lo), field.hi)) }
                ),
                in: field.lo...field.hi,
                step: 1
            ) {
                Text("\(Int(current)) \(field.unit)").monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
            .fixedSize()
        } else {
            // Commit on Return / focus loss so we don't round-trip the file
            // on every keystroke.
            CommitTextField(
                placeholder: field.placeholder,
                initial: (override.wrappedValue as? String) ?? "",
                onCommit: { override.wrappedValue = $0 }
            )
            .frame(width: 180)
        }
    }

    // Seed value when the override is first switched on.
    private func defaultValue() -> Any {
        field.numeric ? NSNumber(value: field.lo) : ""
    }
}

// A text field that commits its value only on Return / focus loss.
private struct CommitTextField: View {
    @FocusState
    private var isFocused: Bool
    let placeholder: String
    let onCommit: (String) -> Void
    @State
    private var text: String
    @State
    private var lastCommitted: String

    init(placeholder: String, initial: String, onCommit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.onCommit = onCommit
        _text = State(initialValue: initial)
        _lastCommitted = State(initialValue: initial)
    }

    // Commit only when the value changed since the last commit, so a
    // Return-then-close doesn't round-trip the file twice.
    private func commit() {
        guard text != lastCommitted else { return }
        lastCommitted = text
        onCommit(text)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onChangeCompatibility(of: isFocused) { if !isFocused { commit() } }
            .onSubmit { commit() }
            .onDisappear { commit() }
    }
}
