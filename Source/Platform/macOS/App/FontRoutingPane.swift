// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// FontRoutingPane.swift — the Settings pane for per-range font routing.
//
// `[[font.range_map]]` is the most specific font control the configuration
// has: it routes a range of code points to a family, and the route consults it
// before every fallback slot, so it wins over the symbol, Han and emoji
// choices. It was also the only one with no control at all, which put the
// blunt instruments in the UI and the precise one in a file — backwards.
//
// The list is the pane. A reader who has never heard the term sees the
// overrides in force with the characters they cover drawn beside them, which
// says what the feature is better than a sentence would; a reader who wants one
// adds it by naming characters and a family.
//
// A range is entered as characters, not as hex. "⌘" and "─━│" are what a person
// has in hand when they want this; U+2318 is what the file stores, and the two
// are the same statement in different alphabets, so the field takes either.
//

import AppKit
import SwiftUI

struct FontRoutingPane: View {
    /// The entries in force, newest read from the configuration.
    @State
    private var entries: [FontRangeOverride] = []
    /// The characters or range the add row is holding.
    @State
    private var draftRange: String = ""
    /// The family the add row will route them to; empty until one is picked.
    @State
    private var draftFamily: String = ""
    @State
    private var shouldMatchDraftSize: Bool?
    /// Why the add row refused, when it did. Nil when there is nothing to say.
    @State
    private var draftProblem: String?
    /// The per-script choices in force.
    @State
    private var scripts: [FontScriptFallback] = []
    /// The script the add-a-script row is holding, empty until one is picked.
    @State
    private var draftScript: String = ""
    /// The family that script will route to, empty until one is picked.
    @State
    private var draftScriptFamily: String = ""

    var body: some View {
        SettingsPaneStack {
            overridesCard.settingsSearchTarget("font.ranges")
            addCard.settingsSearchTarget("font.add-range")
            scriptsCard.settingsSearchTarget("font.script-fallbacks")
            orderCard.settingsSearchTarget("font.fallback-order")
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in reload() }
    }

    // MARK: - The overrides in force

    private var overridesCard: some View {
        SettingsCardView(
            title: "Range Overrides",
            footer:
                "Choose a font for a range of characters. For characters missing from the terminal font, explicit routes take priority over general fallbacks."
        ) {
            if entries.isEmpty {
                SettingsListRow(isFirst: true) {
                    Text("No range overrides. Add one below to send particular characters to a particular font.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    SettingsListRow(isFirst: index == 0) {
                        overrideRow(entry)
                    }
                }
            }
        }
    }

    private func overrideRow(_ entry: FontRangeOverride) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.family)
                    .font(.system(size: 12))
                Text(entry.range)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(
                "Size",
                selection: Binding(
                    get: { entry.shouldMatchSize },
                    set: { value in
                        SettingsBridge.app?
                            .settingsSetRangeMap(from: entry.first, to: entry.last, family: entry.family, shouldMatchSize: value)
                        reload()
                    }
                )
            ) {
                Text("Use Default").tag(Bool?.none)
                Text("Match Primary Font").tag(Bool?.some(true))
                Text("Original Size").tag(Bool?.some(false))
            }
            .frame(width: 185)
            .accessibilityIdentifier("fallback-size-\(entry.first)-\(entry.last)")
            Button("Remove") {
                SettingsBridge.app?.settingsRemoveRangeMap(from: entry.first, to: entry.last)
                reload()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Adding one

    private var addCard: some View {
        SettingsCardView(
            title: "Add an Override",
            footer:
                "Type the characters to route — paste them straight in — or a code point like U+2318, or a range like U+2500-U+257F."
        ) {
            SettingsListRow(isFirst: true) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Characters, or U+2500-U+257F", text: $draftRange)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Picker("Font", selection: $draftFamily) {
                            Text("Choose a font").tag("")
                            ForEach(installedFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        Picker("Size", selection: $shouldMatchDraftSize) {
                            Text("Use Default").tag(Bool?.none)
                            Text("Match Primary Font").tag(Bool?.some(true))
                            Text("Original Size").tag(Bool?.some(false))
                        }
                        Button("Add", action: addDraft)
                            .controlSize(.small)
                            .disabled(draftRange.isEmpty || draftFamily.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let draftProblem {
                SettingsListRow(isFirst: false) {
                    Text(draftProblem)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func addDraft() {
        guard let range = FontRoutingPane.range(from: draftRange) else {
            draftProblem = "Not characters or a code-point range: \(draftRange)"
            return
        }
        guard !draftFamily.isEmpty else {
            draftProblem = "Choose a font to route them to."
            return
        }
        draftProblem = nil
        SettingsBridge.app?
            .settingsSetRangeMap(from: range.first, to: range.last, family: draftFamily, shouldMatchSize: shouldMatchDraftSize)
        draftRange = ""
        draftFamily = ""
        shouldMatchDraftSize = nil
        reload()
    }

    /// The range a person typed, whether they typed characters or code points.
    ///
    /// Characters first, because that is what someone has in hand when they
    /// want this. Two or more characters make the range they span rather than
    /// one entry each: the reader wrote them together because they belong
    /// together, and a range is what the file stores.
    ///
    /// - Parameter text: What the field holds.
    /// - Returns: The range, or nil when the text is neither.
    static func range(from text: String) -> (first: UInt32, last: UInt32)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return nil
        }
        // A code-point spelling: U+2318, 2318, or either side of a dash. Text
        // SHAPED like one is read as one and refused when it does not parse,
        // rather than falling through to the characters branch — "U+257F-U+2500"
        // is a backwards range a person mistyped, and reading it as the
        // characters U, +, 2 … would write an override spanning most of ASCII
        // and report success.
        if looksLikeCodePoints(trimmed) {
            return codePointRange(from: trimmed)
        }
        let scalars = trimmed.unicodeScalars.map(\.value)
        guard let low = scalars.min(), let high = scalars.max() else {
            return nil
        }
        return (low, high)
    }

    /// Whether `text` is written as code points rather than as characters.
    ///
    /// Every dash-separated token, once an optional `U+` is off, has to be hex
    /// digits. Bare hex counts because that is a spelling config.toml uses, and
    /// the characters this feature exists to route — box drawing, powerline
    /// marks, technical symbols — are never hex-digit ASCII, so the ambiguity
    /// is theoretical where the feature is real.
    ///
    /// - Parameter text: The trimmed field contents.
    /// - Returns: True when the text should be read as code points.
    private static func looksLikeCodePoints(_ text: String) -> Bool {
        let tokens = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(tokens.count) else {
            return false
        }
        return tokens.allSatisfy { token in
            var body = token.trimmingCharacters(in: .whitespaces)
            if body.lowercased().hasPrefix("u+") {
                body = String(body.dropFirst(2))
            }
            return !body.isEmpty && body.allSatisfy(\.isHexDigit)
        }
    }

    /// `U+2318`, `2318`, or a dashed pair of either, as the config file spells
    /// one. Nil when the text is not that shape, which is how a caller tells
    /// "code points" from "characters".
    private static func codePointRange(from text: String) -> (first: UInt32, last: UInt32)? {
        func point(_ token: Substring) -> UInt32? {
            var body = token.trimmingCharacters(in: .whitespaces)
            if body.lowercased().hasPrefix("u+") {
                body = String(body.dropFirst(2))
            }
            guard (1...6).contains(body.count),
                body.allSatisfy(\.isHexDigit),
                let value = UInt32(body, radix: 16),
                value <= 0x10FFFF
            else {
                return nil
            }
            return value
        }
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if halves.count == 2 {
            guard let first = point(halves[0]), let last = point(halves[1]), first <= last else {
                return nil
            }
            return (first, last)
        }
        guard let only = point(text[...]) else {
            return nil
        }
        return (only, only)
    }

    // MARK: - Per-script choices

    /// `[[font.language_fallbacks]]`: one family per script, for a reader whose
    /// primary face covers Latin well and something else badly.
    ///
    /// Coarser than a range override and easier to mean: "draw all Arabic in
    /// this" is a sentence a person says, where the code points it covers is
    /// not. The route consults these after the range map, so an override still
    /// wins for the characters it names.
    private var scriptsCard: some View {
        SettingsCardView(
            title: "Script Fallbacks",
            footer:
                "Choose a font for a writing system. Use CJK Fallback above to select regional Han forms."
        ) {
            if scripts.isEmpty {
                SettingsListRow(isFirst: true) {
                    Text("No script fallbacks. Add one to draw a whole script in a chosen font.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(scripts.enumerated()), id: \.element.id) { index, entry in
                    SettingsListRow(isFirst: index == 0) {
                        HStack(spacing: 10) {
                            Text(entry.script.capitalized)
                                .font(.system(size: 12))
                                .frame(minWidth: 90, alignment: .leading)
                            Text(entry.family)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") {
                                SettingsBridge.app?.settingsRemoveLanguageFallback(forScript: entry.script)
                                reload()
                            }
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            SettingsListRow(isFirst: false) {
                HStack(spacing: 8) {
                    Picker("", selection: $draftScript) {
                        Text("Choose a script").tag("")
                        ForEach(scriptNames, id: \.self) { script in
                            Text(script.capitalized).tag(script)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Picker("", selection: $draftScriptFamily) {
                        Text("Choose a font").tag("")
                        ForEach(installedFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Button("Add") {
                        SettingsBridge.app?
                            .settingsSetLanguageFallback(
                                forScript: draftScript,
                                family: draftScriptFamily
                            )
                        draftScript = ""
                        draftScriptFamily = ""
                        reload()
                    }
                    .controlSize(.small)
                    .disabled(draftScript.isEmpty || draftScriptFamily.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var scriptNames: [String] {
        SettingsBridge.app?.settingsFontScriptNames() ?? []
    }

    // MARK: - What the order is

    /// The route, in the order it is consulted.
    ///
    /// Shown because every other control on the Fonts pane is one of these
    /// stages, and which one wins is the question a reader arrives with when
    /// two of them name different fonts for the same character.
    private var orderCard: some View {
        SettingsCardView(
            title: "Route Order",
            footer: "The first stage carrying a glyph for the character draws it."
        ) {
            let stages = [
                ("Terminal Font", "the primary face, when it contains the character"),
                ("Range Overrides", "explicit routes for missing characters"),
                ("Fallback Fonts", "CJK, symbols, and emoji, by character type"),
                ("Script Fallbacks", "choices for other writing systems"),
                ("System Fonts", "remaining missing characters"),
            ]
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                SettingsListRow(isFirst: index == 0) {
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        Text(stage.0).font(.system(size: 12))
                        Text(stage.1)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Reading back

    private var installedFamilies: [String] {
        SettingsBridge.app?.settingsAllFontFamilyNames() ?? []
    }

    private func reload() {
        entries = FontRoutingPane.currentEntries()
        scripts = FontRoutingPane.currentScriptFallbacks()
    }

    /// The overrides the configuration holds, in file order.
    static func currentEntries() -> [FontRangeOverride] {
        let raw = SettingsBridge.app?.settingsRangeMapEntries() ?? []
        return raw.compactMap { entry in
            guard let range = entry["range"] as? String,
                let family = entry["family"] as? String,
                let first = (entry["first"] as? NSNumber)?.uint32Value,
                let last = (entry["last"] as? NSNumber)?.uint32Value
            else {
                return nil
            }
            return FontRangeOverride(range: range, family: family, first: first, last: last, shouldMatchSize: entry["matchSize"] as? Bool)
        }
    }
}

extension FontRoutingPane {
    /// The script fallbacks the configuration holds, in file order.
    static func currentScriptFallbacks() -> [FontScriptFallback] {
        let raw = SettingsBridge.app?.settingsLanguageFallbackEntries() ?? []
        return raw.compactMap { entry in
            guard let script = entry["script"] as? String, let family = entry["family"] as? String else {
                return nil
            }
            return FontScriptFallback(script: script, family: family)
        }
    }
}

/// One `[[font.language_fallbacks]]` entry, as the pane shows it.
struct FontScriptFallback: Identifiable {
    let script: String
    let family: String

    var id: String { script }
}

/// One `[[font.range_map]]` entry, as the pane shows it.
struct FontRangeOverride: Identifiable {
    /// The range as the file spells it, so the row quotes what a person wrote
    /// rather than the two numbers it parsed to.
    let range: String
    let family: String
    let first: UInt32
    let last: UInt32
    let shouldMatchSize: Bool?

    var id: String { "\(first)-\(last)-\(family)" }

    /// A few of the characters the entry covers, for drawing beside it.
    ///
    /// Capped because a range can span a plane, and the row is showing what the
    /// override is about rather than enumerating it.
    var sample: String {
        var text = ""
        var codePoint = first
        while codePoint <= last && text.count < 4 {
            if let scalar = UnicodeScalar(codePoint) {
                text.unicodeScalars.append(scalar)
            }
            codePoint += 1
        }
        return text
    }
}
