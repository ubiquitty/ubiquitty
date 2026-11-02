// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import SwiftUI
import UbiquittyKit

/// Presents the selected font's own features and axes with a shared terminal preview.
struct FontFeaturesPane: View {
    @Environment(\.settingsRevealTarget)
    private var revealTarget
    @State
    private var familyName = TerminalSettingsPreview.configuredFontFamily
    @State
    private var groups: [FontFeatureGroup] = []
    @State
    private var settings: [String: Int] = [:]
    @State
    private var axes: [FontVariationAxis] = []
    @State
    private var effectiveAxisValues: [String: Double] = [:]
    @State
    private var variationValues: [String: Double] = [:]
    @State
    private var examples: [String: String] = [:]
    @State
    private var query = ""
    @State
    private var showsSpecification = false

    var body: some View {
        SettingsPaneStack {
            SettingsSearchField(text: $query, placeholder: "Search font features", identifier: "settings-feature-search")
                .frame(height: 28)
            Text("Change a feature to see its effect in the terminal preview above.")
                .font(.caption).foregroundStyle(.secondary)
            if !axes.isEmpty && query.isEmpty { variationsCard }
            if groups.isEmpty {
                SettingsCardView {
                    SettingsListRow(isFirst: true) {
                        Text("\(familyName) has no optional OpenType features.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if filteredGroups.isEmpty {
                Text("No matching features").foregroundStyle(.secondary)
            } else {
                ForEach(sections) { section in
                    SettingsCardView(title: section.title) {
                        if section.kind == .characterVariants {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], alignment: .leading, spacing: 20) {
                                ForEach(section.groups) { group in
                                    ForEach(group.options.filter { $0.value != 0 }) { option in
                                        variantChoice(option, in: group)
                                    }
                                }
                            }
                            .padding(16)
                        } else {
                            ForEach(Array(section.groups.enumerated()), id: \.element.id) { index, group in
                                featureRows(group, isFirst: index == 0)
                            }
                        }
                    }
                }
            }
            SettingsCardView {
                SettingsListRow(isFirst: true) {
                    DisclosureGroup("Advanced Specification", isExpanded: $showsSpecification) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Use OpenType tags for features or axes the font doesn’t list.")
                                .foregroundStyle(.secondary)
                            Text("Features").font(.headline)
                            TextFieldControl(
                                placeholder: "calt liga -dlig ss01",
                                get: { SettingsBridge.app?.settingsFontFeatures() ?? "" },
                                set: {
                                    SettingsBridge.app?.settingsSetFontFeatures($0)
                                    reloadValues()
                                }
                            )
                            .accessibilityIdentifier("settings-feature-specification")
                            .settingsSearchTarget("font.features.specification")
                            Text("Variations").font(.headline)
                            TextFieldControl(
                                placeholder: "wght=450, slnt=-5",
                                get: { SettingsBridge.app?.settingsFontVariations() ?? "" },
                                set: {
                                    SettingsBridge.app?.settingsSetFontVariations($0)
                                    reloadValues()
                                }
                            )
                            .accessibilityIdentifier("settings-variation-specification")
                            .settingsSearchTarget("font.variations.specification")
                        }
                        .padding(.top, 12)
                    }
                }
            }
        }
        .onAppear {
            reload()
            revealIfNeeded()
        }
        .onChangeCompatibility(of: revealTarget) { revealIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsView.fontFamilyChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in reloadValues() }
    }

    private func revealIfNeeded() {
        if revealTarget == "font.features.specification" || revealTarget == "font.variations.specification" {
            query = ""
            showsSpecification = true
        }
    }

    private var filteredGroups: [FontFeatureGroup] {
        groups.filter { group in
            query.isEmpty || group.name.localizedStandardContains(query)
                || group.options.contains { $0.name.localizedStandardContains(query) || $0.tag.localizedStandardContains(query) }
        }
    }

    private struct FeatureSection: Identifiable {
        enum Kind: Hashable {
            case characterVariants
            case stylisticSets
            case fontGroup(FontFeatureGroup.ID)

            var title: String {
                switch self {
                case .characterVariants: return "Character Variants"
                case .stylisticSets: return "Stylistic Sets"
                case .fontGroup: return ""
                }
            }
        }

        let kind: Kind
        let groups: [FontFeatureGroup]
        var id: Kind { kind }
        var title: String {
            if case .fontGroup = kind { return groups.first?.name ?? "" }
            return kind.title
        }
    }

    private var sections: [FeatureSection] {
        var order: [FeatureSection.Kind] = []
        var grouped: [FeatureSection.Kind: [FontFeatureGroup]] = [:]
        for group in filteredGroups {
            let kind: FeatureSection.Kind
            if group.options.contains(where: { $0.tag.hasPrefix("cv") }) {
                kind = .characterVariants
            } else if group.options.contains(where: { $0.tag.hasPrefix("ss") }) {
                kind = .stylisticSets
            } else {
                kind = .fontGroup(group.id)
            }
            if grouped[kind] == nil { order.append(kind) }
            grouped[kind, default: []].append(group)
        }
        return order.map { FeatureSection(kind: $0, groups: grouped[$0] ?? []) }
    }

    @ViewBuilder
    private func featureRows(_ group: FontFeatureGroup, isFirst: Bool) -> some View {
        if group.isExclusive {
            SettingsListRow(isFirst: isFirst) {
                Picker(
                    group.name,
                    selection: Binding(
                        get: { chosenOption(in: group) },
                        set: { choose($0, in: group) }
                    )
                ) {
                    ForEach(group.options) { option in
                        HStack(spacing: 12) {
                            featureExample(option, in: group)
                            Text(option.name)
                        }
                        .tag(option.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ForEach(Array(group.options.enumerated()), id: \.element.id) { index, option in
                SettingsListRow(isFirst: isFirst && index == 0) {
                    HStack(spacing: 12) {
                        featureComparison(option, in: group)
                        Text(option.name).frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 8)
                        Toggle(
                            option.name,
                            isOn: Binding(
                                get: { settings[option.tag].map { $0 != 0 } ?? option.isDefault },
                                set: { isOn in
                                    settings[option.tag] = isOn ? option.value : 0
                                    commitFeatures()
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings-feature-" + option.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func featureExample(_ option: FontFeatureOption, in group: FontFeatureGroup) -> some View {
        if let example = example(for: option, in: group) {
            Text(example)
                .font(.custom(familyName, size: 14))
                .frame(width: 76, height: 38)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityLabel("Characters affected: " + example)
        }
    }

    private func example(for option: FontFeatureOption, in group: FontFeatureGroup) -> String? {
        examples[option.id] ?? group.options.compactMap { examples[$0.id] }.first
    }

    @ViewBuilder
    private func featureComparison(_ option: FontFeatureOption, in group: FontFeatureGroup) -> some View {
        if let example = example(for: option, in: group) {
            Text(example)
                .font(.custom(familyName, size: 14))
                .frame(width: 164, height: 38)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Characters affected: " + example)
                .help(example)
        } else {
            Text("No specimen available")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 164, alignment: .leading)
        }
    }

    private func chosenOption(in group: FontFeatureGroup) -> String {
        group.options.first(where: { settings[$0.tag] == $0.value })?.id
            ?? group.options.first(where: \.isDefault)?.id
            ?? group.options.first?.id ?? ""
    }

    private func variantChoice(_ option: FontFeatureOption, in group: FontFeatureGroup) -> some View {
        let selected =
            group.isExclusive
            ? chosenOption(in: group) == option.id
            : settings[option.tag].map { $0 != 0 } ?? option.isDefault
        let affected = example(for: option, in: group)
        return Button {
            if selected {
                settings[option.tag] = 0
                commitFeatures()
            } else if group.isExclusive {
                choose(option.id, in: group)
            } else {
                settings[option.tag] = option.value
                commitFeatures()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                featureComparison(option, in: group)
                HStack(spacing: 6) {
                    Text(affected ?? group.name).fontWeight(selected ? .semibold : .regular)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                Text(option.tag).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.06) : Color.clear, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.name + (affected.map { ", affects " + $0 } ?? ""))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("settings-feature-" + option.id)
    }

    private func choose(_ id: String, in group: FontFeatureGroup) {
        guard let option = group.options.first(where: { $0.id == id }) else { return }
        for other in group.options { settings.removeValue(forKey: other.tag) }
        if !option.isDefault { settings[option.tag] = option.value }
        commitFeatures()
    }

    private func commitFeatures() {
        SettingsBridge.app?.settingsSetFontFeatures(FontFeatureCatalog.specification(from: settings))
    }

    private var variationsCard: some View {
        SettingsCardView(
            title: "Variable Font",
            footer: "Axis overrides take priority over the weight and width in Fonts. Reset returns control to those settings."
        ) {
            ForEach(Array(axes.enumerated()), id: \.element.id) { index, axis in
                SettingsListRow(isFirst: index == 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(axis.name)
                            Spacer()
                            Text(
                                (variationValues[axis.tag] ?? effectiveAxisValues[axis.tag] ?? axis.defaultValue)
                                    .formatted(.number.precision(.fractionLength(0...2)))
                            )
                            .monospacedDigit()
                            Button("Reset") {
                                variationValues.removeValue(forKey: axis.tag)
                                commitVariations()
                            }
                            .disabled(variationValues[axis.tag] == nil)
                            .accessibilityLabel("Reset \(axis.name)")
                        }
                        Slider(
                            value: Binding(
                                get: {
                                    min(
                                        axis.maxValue,
                                        max(axis.minValue, variationValues[axis.tag] ?? effectiveAxisValues[axis.tag] ?? axis.defaultValue)
                                    )
                                },
                                set: { variationValues[axis.tag] = $0 }
                            ),
                            in: axis.minValue...axis.maxValue,
                            onEditingChanged: { editing in
                                if !editing { commitVariations() }
                            }
                        )
                        .accessibilityLabel(axis.name)
                    }
                }
            }
        }
    }

    private func commitVariations() {
        SettingsBridge.app?
            .settingsSetFontVariations(
                FontFeatureCatalog.variationSpecification(from: variationValues, order: axes.map(\.tag))
            )
    }

    private func reloadValues() {
        settings = FontFeatureCatalog.settings(inSpecification: SettingsBridge.app?.settingsFontFeatures() ?? "")
        variationValues = FontFeatureCatalog.variationValues(inSpecification: SettingsBridge.app?.settingsFontVariations() ?? "")
        let font = FontFeatureCatalog.font(familyName: familyName, size: 13, settings: settings)
        let resolved = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber] ?? [:]
        effectiveAxisValues = Dictionary(
            uniqueKeysWithValues: axes.map { axis in
                let identifier = axis.tag.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return (axis.tag, resolved[NSNumber(value: identifier)]?.doubleValue ?? axis.defaultValue)
            }
        )
    }

    private func reload() {
        familyName = TerminalSettingsPreview.configuredFontFamily
        groups = FontFeatureCatalog.groups(forFamilyNamed: familyName)
        axes = FontFeatureCatalog.variationAxes(forFamilyNamed: familyName)
        var measured: [String: String] = [:]
        for group in groups {
            for option in group.options {
                if let example = FontFeatureCatalog.example(for: option, familyName: familyName) {
                    measured[option.id] = example
                }
            }
        }
        examples = measured
        reloadValues()
    }
}
