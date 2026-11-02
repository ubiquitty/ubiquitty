// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ThemesPane.swift — the in-window Themes editor. Lists every
// registered theme with a live swatch strip, lets the user pin the active
// one, and create / duplicate / edit / delete custom themes. Built-in
// themes are read-only (Duplicate only).
//
// Reads: theme colors from the Core theme registry (Ubiquitty.Themes),
// names via the application delegate. Writes: every mutation funnels
// through the application delegate — select / save (overwrite-by-name) /
// delete — which persists a [[themes]] block to config.toml and refreshes
// the runtime registry. Settings stays the single source of truth.
//

import AppKit
import SwiftUI
import UbiquittyAppBridge
import UbiquittyCore
import UbiquittyKit
import UniformTypeIdentifiers

struct ThemesPane: View {
    @StateObject
    private var model = ThemePickerModel()
    @State
    private var query = ""
    @State
    private var filter = ThemeDestination.current
    @State
    private var session = EditSession<ThemeSnapshot>()

    private var themes: [ThemeSnapshot] { model.themes }
    private var activeIndex: Int { model.activeIndex }

    var body: some View {
        SettingsPaneStack {
            HStack(spacing: 12) {
                SettingsSearchField(text: $query, placeholder: "Search themes", identifier: "theme-search")
                    .frame(height: 28)
                Picker("Appearance", selection: $filter) {
                    Text("All").tag(ThemeDestination.current)
                    Text("Light").tag(ThemeDestination.light)
                    Text("Dark").tag(ThemeDestination.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 20) {
                ForEach(model.choices(for: filter, query: query)) { theme in
                    VStack(spacing: 6) {
                        ThemeChoice(theme: theme, isSelected: theme.id == activeIndex) {
                            model.select(theme, for: .current)
                        }
                        HStack {
                            Text(theme.isBuiltIn ? "Built-in" : "Custom")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Duplicate…") { duplicate(theme) }
                                Button("Export Theme…") { export(theme) }
                                if !theme.isBuiltIn {
                                    Button("Edit…") { session.edit(theme) }
                                    Button("Delete", role: .destructive) { deleteTheme(theme) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Actions for " + theme.name)
                        }
                    }
                }
            }
            if model.choices(for: filter, query: query).isEmpty {
                Text("No themes match your search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            Text("Choose a theme to use it in all windows. To switch automatically with macOS, choose Auto in Appearance.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Import…") {
                    NSApp.sendAction(NSSelectorFromString("importTheme:"), to: SettingsBridge.app, from: nil)
                    reload()
                }
                .settingsSearchTarget("themes.import")
                Spacer()
                Button {
                    beginNew()
                } label: {
                    Label("New Theme…", systemImage: "plus")
                }
                .settingsSearchTarget("themes.new")
            }
        }
        .onAppear {
            reload()
            editCurrentThemeIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.editCurrentThemeNotification)) { _ in
            editCurrentThemeIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in reload() }
        .sheet(item: $session.editing) { snapshot in
            ThemeEditorSheet(
                snapshot: snapshot,
                isNew: session.isNew,
                originalName: session.isNew ? nil : snapshot.name,
                existingNames: themes.map(\.name),
                onCommit: { committed in commit(committed, replacing: session.isNew ? nil : snapshot.name) },
                onCancel: {}
            )
        }
    }

    private func editCurrentThemeIfRequested() {
        guard let index = SettingsWindowController.takePendingThemeEdit(), let theme = themes.first(where: { $0.id == index }) else {
            return
        }
        if theme.isBuiltIn { duplicate(theme) } else { session.edit(theme) }
    }

    private func export(_ theme: ThemeSnapshot) {
        guard let palette = Ubiquitty.Themes.get(Int32(theme.id)) else { return }
        let contents = String(palette.pointee.serializeTOML())
        let panel = NSSavePanel()
        panel.title = "Export Theme"
        panel.message = "Save a Ubiquitty theme. Other theme formats are available for import only."
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        panel.nameFieldStringValue = theme.name.replacingOccurrences(of: "/", with: "-") + ".toml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSApp.presentError(error)
        }
    }

    private func reload() { model.reload() }

    private func deleteTheme(_ theme: ThemeSnapshot) {
        SettingsBridge.app?.settingsDeleteThemeNamed(theme.name)
        reload()
    }

    private func beginNew() {
        // Seed from the active (or first) theme so the editor opens on a
        // sensible palette rather than all-black.
        let seed = themes.first { $0.id == activeIndex } ?? themes.first
        var snapshot =
            seed
            ?? ThemeSnapshot(
                id: -1,
                name: "",
                isDark: true,
                isBuiltIn: false,
                ansi: [UInt32](repeating: 0, count: 16),
                foreground: 0xFFFF_FFFF,
                background: 0x0000_00FF,
                cursor: 0xFFFF_FFFF
            )
        snapshot.name = uniqueName("New Theme", existing: themes.map(\.name))
        snapshot.isBuiltIn = false
        session.new(snapshot)
    }

    private func duplicate(_ theme: ThemeSnapshot) {
        var snapshot = theme
        snapshot.name = uniqueName(theme.name + " Copy", existing: themes.map(\.name))
        snapshot.isBuiltIn = false
        session.duplicate(snapshot)
    }

    private func commit(_ snapshot: ThemeSnapshot, replacing originalName: String?) {
        SettingsBridge.app?
            .settingsSaveThemeNamed(
                snapshot.name,
                replacingName: originalName,
                isDark: snapshot.isDark,
                ansi: snapshot.ansi,
                foreground: snapshot.foreground,
                background: snapshot.background,
                cursor: snapshot.cursor,
                select: session.isNew
            )
        reload()
    }
}

/// Edits a local palette draft; only Save changes the live terminal or configuration.
private struct ThemeEditorSheet: View {
    @State
    var snapshot: ThemeSnapshot
    let isNew: Bool
    let originalName: String?
    let existingNames: [String]
    let onCommit: (ThemeSnapshot) -> Void
    let onCancel: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(46), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Theme" : "Edit Theme").font(.headline)

            ThemeTerminalPreview(theme: snapshot)

            HStack {
                Text("Name")
                TextField("Theme name", text: $snapshot.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Toggle("Dark", isOn: $snapshot.isDark)
            }

            Text("ANSI Palette").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<16, id: \.self) { slot in
                    paletteWell(
                        slot: slot,
                        value: Binding(
                            get: { snapshot.ansi[slot] },
                            set: { snapshot.ansi[slot] = $0 }
                        ),
                        label: "\(slot)"
                    )
                }
            }

            Text("Defaults").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                namedWell(slot: 16, label: "Foreground", value: $snapshot.foreground)
                namedWell(slot: 17, label: "Background", value: $snapshot.background)
                namedWell(slot: 18, label: "Cursor", value: $snapshot.cursor)
            }

            ModalButtons(
                saveDisabled: !isValidName(snapshot.name)
                    || (snapshot.name != originalName && existingNames.contains(snapshot.name)),
                onCancel: onCancel,
                onSave: { onCommit(snapshot) }
            )
        }
        .padding(24)
        .frame(width: 460)
    }

    private func colorBinding(value: Binding<UInt32>) -> Binding<Color> {
        Binding(
            get: { ColorPack.color(value.wrappedValue) },
            set: { value.wrappedValue = ColorPack.pack($0) }
        )
    }

    // A compact color well over a packed-RGBA binding.
    private func paletteWell(slot: Int, value: Binding<UInt32>, label: String) -> some View {
        VStack(spacing: 2) {
            ColorPicker(label, selection: colorBinding(value: value), supportsOpacity: true)
                .labelsHidden()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func namedWell(slot: Int, label: String, value: Binding<UInt32>) -> some View {
        VStack(spacing: 4) {
            ColorPicker(label, selection: colorBinding(value: value), supportsOpacity: true)
                .labelsHidden()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
