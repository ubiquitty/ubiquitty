// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UbiquittyAppBridge
import UbiquittyKit

/// Identifies whether a theme is being chosen now or for an automatic appearance.
enum ThemeDestination: String, Identifiable {
    case current, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: "Choose a theme"
        case .light: "Choose a light theme"
        case .dark: "Choose a dark theme"
        }
    }
}

/// Reads theme choices from configuration and writes only in response to an explicit selection.
@MainActor
final class ThemePickerModel: ObservableObject {
    @Published
    private(set) var themes: [ThemeSnapshot] = []

    var appearanceMode: Int { SettingsBridge.app?.settingsAppearanceMode() ?? 0 }
    /// The pinned theme's registry index, or -1 while the theme follows the
    /// system appearance or no theme is pinned.
    var activeIndex: Int {
        let name = settingText(.AppearanceTheme)
        guard !settingBool(.AppearanceFollowSystem), !name.isEmpty else { return -1 }
        return Int(Ubiquitty.Themes.indexForName(name))
    }

    func reload() {
        let names = SettingsBridge.app?.settingsThemeNames() ?? []
        let builtInCount = Int(Ubiquitty.Themes.builtInCount())
        themes = names.enumerated().map { ThemeSnapshot.load($0.offset, name: $0.element, builtInCount: builtInCount) }
    }

    func selectedIndex(for destination: ThemeDestination) -> Int {
        switch destination {
        case .current: activeIndex
        case .light:
            appearanceMode == 1 ? activeIndex : Int(Ubiquitty.SwiftBridge.systemLightTheme())
        case .dark:
            appearanceMode == 2 ? activeIndex : Int(Ubiquitty.SwiftBridge.systemDarkTheme())
        }
    }

    func theme(for destination: ThemeDestination) -> ThemeSnapshot? {
        themes.first { $0.id == selectedIndex(for: destination) }
    }

    func setAppearanceMode(_ mode: Int) {
        guard mode != appearanceMode else { return }
        if mode == 0 {
            SettingsBridge.app?.settingsSetAppearanceMode(0)
        } else {
            let destination: ThemeDestination = mode == 1 ? .light : .dark
            if let theme = theme(for: destination), !theme.usesSystemAppearance {
                SettingsBridge.app?.settingsSelectTheme(theme.id)
            } else if let theme = choices(for: destination).first(where: { !$0.usesSystemAppearance }) {
                SettingsBridge.app?.settingsSelectTheme(theme.id)
            }
        }
        reload()
    }

    func select(_ theme: ThemeSnapshot, for destination: ThemeDestination) {
        let mode = appearanceMode
        if theme.usesSystemAppearance {
            SettingsBridge.app?.settingsSetSystemLightTheme(theme.id)
            SettingsBridge.app?.settingsSetSystemDarkTheme(theme.id)
            SettingsBridge.app?.settingsSetAppearanceMode(0)
            reload()
            return
        }
        switch destination {
        case .current:
            if theme.isDark {
                SettingsBridge.app?.settingsSetSystemDarkTheme(theme.id)
            } else {
                SettingsBridge.app?.settingsSetSystemLightTheme(theme.id)
            }
            SettingsBridge.app?.settingsSelectTheme(theme.id)
        case .light:
            SettingsBridge.app?.settingsSetSystemLightTheme(theme.id)
            if mode == 1 { SettingsBridge.app?.settingsSelectTheme(theme.id) }
        case .dark:
            SettingsBridge.app?.settingsSetSystemDarkTheme(theme.id)
            if mode == 2 { SettingsBridge.app?.settingsSelectTheme(theme.id) }
        }
        reload()
    }

    func choices(for destination: ThemeDestination, query: String = "") -> [ThemeSnapshot] {
        themes.filter {
            (destination == .current || $0.usesSystemAppearance || $0.isDark == (destination == .dark))
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
}

/// Offers visual appearance choices and the palettes used for light and dark terminals.
struct AppearanceThemePicker: View {
    @StateObject
    private var model = ThemePickerModel()
    @State
    private var destination: ThemeDestination?

    var body: some View {
        SettingsCardView {
            SettingsListRow(isFirst: true) {
                HStack(alignment: .top) {
                    Text("Appearance")
                    Spacer()
                    HStack(spacing: 10) {
                        appearanceChoice("Auto", mode: 0)
                        appearanceChoice("Light", mode: 1)
                        appearanceChoice("Dark", mode: 2)
                    }
                }
            }
            if model.appearanceMode != 2 { themeRow(.light, title: "Light theme") }
            if model.appearanceMode != 1 { themeRow(.dark, title: "Dark theme") }
        }
        .font(.system(size: 13))
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in model.reload() }
        .sheet(item: $destination) {
            ThemePickerSheet(model: model, destination: $0)
        }
    }

    private func appearanceChoice(_ title: String, mode: Int) -> some View {
        Button {
            model.setAppearanceMode(mode)
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    if mode != 2, let light = model.theme(for: .light) {
                        ThemeMiniPreview(theme: light)
                    }
                    if mode != 1, let dark = model.theme(for: .dark) {
                        ThemeMiniPreview(theme: dark)
                    }
                }
                .frame(width: 72, height: 46)
                .modifier(SettingsChoiceFrame(isSelected: model.appearanceMode == mode))
                Text(title).font(.system(size: 11, weight: model.appearanceMode == mode ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + " appearance")
        .accessibilityValue(model.appearanceMode == mode ? "Selected" : "")
        .accessibilityIdentifier("settings-appearance-\(mode)")
    }

    private func themeRow(_ slot: ThemeDestination, title: String) -> some View {
        SettingsListRow(isFirst: false) {
            Button {
                model.reload()
                destination = slot
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                    Spacer()
                    if let theme = model.theme(for: slot) {
                        ThemeMiniPreview(theme: theme)
                            .frame(width: 52, height: 32)
                            .clipShape(.rect(cornerRadius: 5))
                        Text(theme.name).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-theme-\(slot.rawValue)")
        }
    }
}

/// Shows a small terminal-shaped palette sample for an appearance option.
private struct ThemeMiniPreview: View {
    let theme: ThemeSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(ColorPack.color(theme.foreground).opacity(0.3)).frame(width: 3, height: 3) }
            }
            RoundedRectangle(cornerRadius: 1).fill(ColorPack.color(theme.ansi[2])).frame(height: 3)
            RoundedRectangle(cornerRadius: 1).fill(ColorPack.color(theme.ansi[4])).frame(height: 3).padding(.trailing, 10)
            RoundedRectangle(cornerRadius: 1).fill(ColorPack.color(theme.foreground)).frame(height: 3).padding(.trailing, 5)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorPack.color(theme.background))
        .accessibilityHidden(true)
    }
}

/// Chooses a theme for a specific appearance without changing the automatic-follow preference.
struct ThemePickerSheet: View {
    @ObservedObject
    var model: ThemePickerModel
    let destination: ThemeDestination
    var selectedIndex: Int? = nil
    var onSelect: ((ThemeSnapshot) -> Void)? = nil
    @State
    private var query = ""
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(destination.title).font(.title2.bold())
            SettingsSearchField(text: $query, placeholder: "Search themes", identifier: "theme-picker-search").frame(height: 28)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 20) {
                    ForEach(model.choices(for: destination, query: query)) { theme in
                        ThemeChoice(theme: theme, isSelected: theme.id == (selectedIndex ?? model.selectedIndex(for: destination))) {
                            if let onSelect { onSelect(theme) } else { model.select(theme, for: destination) }
                            dismiss()
                        }
                    }
                }
                .padding(3)
                if model.choices(for: destination, query: query).isEmpty {
                    Text("No themes match your search.").foregroundStyle(.secondary).padding()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onAppear { model.reload() }
    }
}
