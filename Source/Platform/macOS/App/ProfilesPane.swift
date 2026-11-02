// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ProfilesPane.swift — the in-window [[profiles]] manager. Lists named
// presentation profiles and lets the user create / duplicate / edit /
// delete them, with explicit overrides and parent inheritance. Unset fields fall back
// through the parent chain to the live global configuration.
//
// Reads + writes funnel through the application delegate: a profile crosses
// as a dictionary keyed by the profile's field names; saving serializes
// a [[profiles]] block to config.toml and rebuilds the "New Window with
// Profile" menu. Settings stays the single source of truth.
//

import AppKit
import SwiftUI
import UbiquittyCore
import UbiquittyKit
import UniformTypeIdentifiers

struct ProfilesPane: View {
    @State
    private var profiles: [Profile] = []
    @State
    private var session = EditSession<Profile>()
    @State
    private var received: ReceivedProfile?
    @State
    private var query = ""

    private struct ReceivedProfile: Identifiable {
        let id = UUID()
        let core: Ubiquitty.Preferences.Profile
        let window: TerminalWindowController?
    }

    var body: some View {
        SettingsListPane(
            title: "Profiles",
            footer:
                "Profiles are saved on this Mac. Sharing is opt-in and sends presentation settings only, using an exported file. Received settings are reviewed before use. Temporary changes last only for the chosen window.",
            emptyText: query.isEmpty ? "No profiles." : "No matching profiles.",
            addLabel: "New Profile",
            items: visibleProfiles,
            onAdd: { session.new(Profile(name: uniqueName("New Profile", existing: profiles.map(\.name)))) },
            reload: reload,
            addSearchID: "profiles.new"
        ) { profile in
            row(profile)
        }
        .safeAreaInset(edge: .top) {
            TextField("Filter Profiles", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter Profiles")
                .padding(.horizontal).padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Import Shared Profile…", action: importProfile)
                    .settingsSearchTarget("profiles.import")
                Spacer()
                Button("Reset Window Overrides") {
                    selectedTerminal?.resetTemporaryProfile()
                }
                .disabled(selectedTerminal == nil)
                .settingsSearchTarget("profiles.reset-window")
            }
            .padding()
        }
        .sheet(item: $received) { proposal in
            review(proposal)
        }
        .sheet(item: $session.editing) { profile in
            ProfileEditorSheet(
                profile: profile,
                isNew: session.isNew,
                profiles: profiles,
                onCommit: { commit($0) },
                onCancel: {}
            )
        }
    }

    private var visibleProfiles: [Profile] {
        profiles.filter { query.isEmpty || $0.name.localizedStandardContains(query) || summary($0).localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func row(_ profile: Profile) -> some View {
        HStack(spacing: 12) {
            Button {
                session.edit(profile)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).fontWeight(.medium)
                    Text(summary(profile)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(profile.name)")
            Menu {
                Button("Edit…") { session.edit(profile) }
                Button("Duplicate…") { duplicate(profile) }
                if profile.scope == 1 { Button("Export…") { exportProfile(profile) } }
                Divider()
                Button("Delete…", role: .destructive) { remove(profile) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Actions for \(profile.name)")
            .accessibilityLabel("Actions for \(profile.name)")
        }
    }

    private func summary(_ profile: Profile) -> String {
        var parts: [String] = []
        if let parent = profile.parentProfile { parts.append("Based on " + parent) }
        if let theme = profile.theme, !theme.isEmpty { parts.append(theme) }
        if let family = profile.fontFamily, !family.isEmpty { parts.append(family) }
        if let fallback = profile.fallbackFont, !fallback.isEmpty { parts.append("⊕ \(fallback)") }
        // Core's spelling, the one the Settings field and the palette show, so
        // a profile set to a size between two points reads as that size.
        if let size = profile.fontSize {
            parts.append(PaletteSettings.formatNumber(size, step: SettingsCatalog.bounds("font", "size").step) + "pt")
        }
        if let chromeless = profile.hideTitleBar { parts.append(chromeless ? "No title bar" : "Title bar") }
        if let host = profile.startupHost, !host.isEmpty { parts.append("→ \(host)") }
        return parts.isEmpty ? "Inherits all defaults" : parts.joined(separator: " · ")
    }

    private var selectedTerminal: TerminalWindowController? {
        NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindowController }.first { !$0.isWindowClosed }
    }

    private func exportProfile(_ profile: Profile) {
        let eligible = Ubiquitty.Preferences.profilesForSharing(Ubiquitty.Preferences.values().pointee)
        guard let shared = eligible.first(where: { String($0.name) == profile.name }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Shared Profile"
        panel.allowedContentTypes = [UTType(filenameExtension: "ubqprofile") ?? .plainText]
        panel.nameFieldStringValue = profile.name.replacingOccurrences(of: "/", with: "-") + ".ubqprofile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try String(Ubiquitty.Preferences.serializeProfile(shared)).write(to: url, atomically: true, encoding: .utf8) } catch {
            NSApp.presentError(error)
        }
    }

    private func importProfile() {
        let window = selectedTerminal
        let panel = NSOpenPanel()
        panel.title = "Review Shared Profile"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard let data = try file.read(upToCount: 65537), data.count <= 65536,
                let text = String(data: data, encoding: .utf8),
                let profile = Ubiquitty.Preferences.profileFromTransferText(std.string(text)).value
            else {
                presentError("Can’t Import the Profile", informativeText: "Choose a shared Ubiquitty profile smaller than 64 KB.")
                return
            }
            received = ReceivedProfile(core: profile, window: window)
        } catch { NSApp.presentError(error) }
    }

    private func review(_ proposal: ReceivedProfile) -> some View {
        let incoming = Profile(core: proposal.core)
        let current = Profile(core: proposal.window?.effectiveProfile ?? Ubiquitty.Preferences.Profile())
        return VStack(alignment: .leading, spacing: 16) {
            Text("Review \(incoming.name)").font(.headline)
            Text("Only presentation changes are included. Commands, paths, credentials, and permissions stay on their original device.")
                .foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        Text("Setting")
                        Text("Current Window")
                        Text("Received Override")
                    }
                    .bold()
                    ForEach(Profile.presentationFields, id: \.key) { label, key in
                        if let value = incoming.dictionary()[key] {
                            GridRow {
                                Text(label)
                                Text(current.dictionary()[key].map { String(describing: $0) } ?? "Inherited")
                                Text(String(describing: value))
                            }
                        }
                    }
                }
            }
            Text(
                "Apply affects only this window until it closes. Save creates a local copy with a unique name; existing profiles are preserved."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { received = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save on This Mac") {
                    var local = incoming
                    local.scope = 0
                    local.name = uniqueName(local.name, existing: profiles.map(\.name))
                    commit(local)
                    received = nil
                }
                Button("Apply to Window") {
                    proposal.window?.applyTemporaryProfile(proposal.core)
                    received = nil
                }
                .disabled(proposal.window == nil || proposal.window?.isWindowClosed == true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 660, height: 460)
    }

    // MARK: data

    private func reload() {
        let raw = SettingsBridge.app?.settingsProfiles() ?? []
        profiles = raw.map { Profile(dict: $0) }
    }

    private func duplicate(_ profile: Profile) {
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueName(profile.name + " Copy", existing: profiles.map(\.name))
        session.duplicate(copy)
    }

    private func remove(_ profile: Profile) {
        guard let app = SettingsBridge.app else { return }
        let references = app.settingsProfileDeletionReferences(profile.name)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if references.isEmpty {
            alert.messageText = "Delete “\(profile.name)”?"
            alert.informativeText = "This removes the saved profile from this Mac."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            app.settingsDeleteProfileNamed(profile.name)
            reload()
        } else {
            alert.messageText = "“\(profile.name)” Is in Use"
            alert.informativeText = "Change these references before deleting the profile:\n\n\(references.joined(separator: "\n"))"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func commit(_ profile: Profile) {
        SettingsBridge.app?.settingsSaveProfile(profile.dictionary())
        reload()
    }
}

// The add/edit sheet. Each optional field has an "Override" toggle; off
// means inherit (the field is omitted from the block).
private struct ProfileEditorSheet: View {
    @State
    var profile: Profile
    let isNew: Bool
    let profiles: [Profile]
    @StateObject
    private var themeModel = ThemePickerModel()
    @State
    private var choosingTheme = false
    let onCommit: (Profile) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Profile" : "Edit Profile").font(.headline)
            ScrollView {
                SettingsPaneStack {
                    SettingsCardView {
                        SettingsListRow(isFirst: true) {
                            HStack {
                                Text("Name")
                                Spacer()
                                TextField("Profile name", text: $profile.name)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                                    .disabled(!isNew)
                            }
                        }
                        SettingsListRow(isFirst: false) {
                            HStack {
                                Text("Based on")
                                Spacer()
                                Picker(
                                    "Based on",
                                    selection: Binding(
                                        get: { profile.parentProfile ?? "" },
                                        set: { profile.parentProfile = $0.isEmpty ? nil : $0 }
                                    )
                                ) {
                                    Text("App defaults").tag("")
                                    ForEach(parentChoices, id: \.self) { Text($0).tag($0) }
                                    if let parent = profile.parentProfile, !parentChoices.contains(parent) {
                                        Text(parent + " (unavailable)").tag(parent)
                                    }
                                }
                                .labelsHidden().frame(width: 220)
                            }
                        }
                    }
                    SettingsCardView(
                        title: "Effective Values",
                        footer:
                            "Turn off an Override to inherit. Values resolve from app defaults, platform settings, parent profiles, then this profile. Temporary window changes apply last."
                    ) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(Profile.presentationFields, id: \.key) { field in
                                let effective = effectiveValue(for: field.key)
                                GridRow {
                                    Text(field.label)
                                    Text(effective.value)
                                    Text(effective.source).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.caption).padding(12)
                    }
                    SettingsCardView(
                        title: "Sharing",
                        footer:
                            "Allow export makes this profile available for explicit transfer to another device. Turning it off prevents future exports; it does not remove copies already sent."
                    ) {
                        SettingsListRow(isFirst: true) {
                            Toggle(
                                "Allow Export to Other Devices",
                                isOn: Binding(get: { profile.scope == 1 }, set: { profile.scope = $0 ? 1 : 0 })
                            )
                        }
                    }
                    SettingsCardView(title: "Appearance") {
                        SettingsListRow(isFirst: true) {
                            OptionalFieldRow(
                                label: "Theme",
                                value: $profile.theme,
                                defaultValue: themeModel.theme(for: .current)?.name ?? ""
                            ) {
                                Button {
                                    choosingTheme = true
                                } label: {
                                    HStack {
                                        Text(profile.theme ?? "Use inherited theme")
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(profile.theme == nil)
                                .frame(width: 220)
                            }
                        }
                        SettingsListRow(isFirst: false) {
                            optionalText("Font family", value: $profile.fontFamily, placeholder: "JetBrains Mono")
                        }
                        SettingsListRow(isFirst: false) {
                            optionalText("Symbol fallback", value: $profile.fallbackFont, placeholder: "Symbols Nerd Font")
                        }
                        SettingsListRow(isFirst: false) {
                            optionalNumber("Font size", value: $profile.fontSize, schema: ("font", "size"))
                        }
                        SettingsListRow(isFirst: false) {
                            optionalNumber("Line spacing", value: $profile.lineSpacing, schema: ("font", "line_spacing"))
                        }
                    }
                    SettingsCardView(title: "Window") {
                        SettingsListRow(isFirst: true) {
                            optionalNumber("Left padding", value: $profile.paddingLeft, schema: ("appearance", "padding_left"))
                        }
                        SettingsListRow(isFirst: false) {
                            optionalNumber("Right padding", value: $profile.paddingRight, schema: ("appearance", "padding_right"))
                        }
                        SettingsListRow(isFirst: false) {
                            optionalNumber("Top padding", value: $profile.paddingTop, schema: ("appearance", "padding_top"))
                        }
                        SettingsListRow(isFirst: false) {
                            optionalNumber(
                                "Titleless top padding",
                                value: $profile.titlelessPaddingTop,
                                schema: ("appearance", "titleless_padding_top")
                            )
                        }
                        SettingsListRow(isFirst: false) {
                            optionalNumber("Bottom padding", value: $profile.paddingBottom, schema: ("appearance", "padding_bottom"))
                        }
                        SettingsListRow(isFirst: false) {
                            optionalToggle("Hide title bar", value: $profile.hideTitleBar)
                        }
                    }
                    SettingsCardView(
                        title: "Process Exit",
                        footer:
                            "Applies to local shells. Restart creates a new process after one second and stops after three rapid restarts. Running steadily for a minute resets the limit."
                    ) {
                        SettingsListRow(isFirst: true) {
                            Picker("When the process exits", selection: $profile.processExit) {
                                Text("Inherit").tag(String?.none)
                                Text("Keep Output").tag(Optional("keep_output"))
                                Text("Close on Clean Exit").tag(Optional("close_on_success"))
                                Text("Close Always").tag(Optional("close_always"))
                                Text("Restart Process").tag(Optional("restart"))
                            }
                        }
                    }
                    SettingsCardView(
                        title: "Connection",
                        footer: "An empty host override opens a local shell. Turn off the override to inherit the connection."
                    ) {
                        SettingsListRow(isFirst: true) {
                            optionalText("Startup host", value: $profile.startupHost, placeholder: "Local shell")
                        }
                    }
                }
            }
            Text("Turn on an override to customize a setting for this profile.")
                .font(.callout).foregroundStyle(.secondary)
            ModalButtons(
                saveDisabled: !isValidName(profile.name) || (isNew && profiles.contains { $0.name == profile.name }),
                onCancel: onCancel,
                onSave: { onCommit(profile) }
            )
        }
        .padding(20)
        .frame(width: 480, height: 560)
        .onAppear { themeModel.reload() }
        .sheet(isPresented: $choosingTheme) {
            ThemePickerSheet(
                model: themeModel,
                destination: .current,
                selectedIndex: themeModel.themes.first { $0.name == profile.theme }?.id,
                onSelect: { profile.theme = $0.name }
            )
        }
    }

    private var parentChoices: [String] {
        profiles.filter { candidate in
            var current: Profile? = candidate
            var visited = Set<String>()
            while let next = current {
                guard next.name != profile.name, visited.insert(next.name).inserted else { return false }
                current = profiles.first { $0.name == next.parentProfile }
            }
            return true
        }
        .map(\.name)
    }

    private func optionalText(
        _ label: String,
        value: Binding<String?>,
        placeholder: String
    ) -> some View {
        OptionalFieldRow(label: label, value: value, defaultValue: "") {
            TextField(
                placeholder,
                text: Binding(
                    get: { value.wrappedValue ?? "" },
                    set: { value.wrappedValue = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .disabled(value.wrappedValue == nil)
        }
    }

    private func effectiveValue(for key: String) -> (value: String, source: String) {
        if let value = profile.dictionary()[key] { return (String(describing: value), "This profile") }
        var parentName = profile.parentProfile
        var visited: Set<String> = [profile.name]
        for _ in 0..<32 {
            guard let name = parentName, visited.insert(name).inserted,
                let parent = profiles.first(where: { $0.name == name })
            else { break }
            if let value = parent.dictionary()[key] { return (String(describing: value), name) }
            parentName = parent.parentProfile
        }
        let configuration = Ubiquitty.Preferences.values().pointee
        let platform = Profile(core: Ubiquitty.Preferences.applyCurrentPlatformOverride(Ubiquitty.Preferences.Profile(), configuration))
        if let value = platform.dictionary()[key] { return (String(describing: value), "Platform settings") }
        let defaults = Profile(core: Ubiquitty.Preferences.profileFromValues(configuration, "Default"))
        if let value = defaults.dictionary()[key] { return (String(describing: value), "App settings") }
        let rendered = Ubiquitty.Preferences.Effective.renderConfiguration(configuration)
        let builtin: String
        switch key {
        case "fontSize": builtin = String(rendered.fontSizePoints)
        case "fontFamily": builtin = rendered.fontFamily.isEmpty() ? "System monospace" : String(rendered.fontFamily.string())
        case "fallbackFont": builtin = "Bundled symbols"
        case "lineSpacing": builtin = String(rendered.lineSpacingPoints)
        case "paddingLeft": builtin = String(rendered.paddingLeftPoints)
        case "paddingRight": builtin = String(rendered.paddingRightPoints)
        case "paddingTop": builtin = String(rendered.paddingTopPoints)
        case "titlelessPaddingTop": builtin = String(rendered.titlelessPaddingTopPoints)
        case "paddingBottom": builtin = String(rendered.paddingBottomPoints)
        case "hideTitleBar": builtin = "Off"
        default: builtin = "Automatic"
        }
        return (builtin, "App default")
    }

    // `schema` names the (section, key) whose shared bounds drive the stepper —
    // resolved once through SettingsCatalog.bounds (the Settings schema bridge) so
    // the range / step / unit can't drift from the global control or the parser.
    private func optionalNumber(
        _ label: String,
        value: Binding<Double?>,
        schema: (section: String, key: String)
    ) -> some View {
        let bounds = SettingsCatalog.bounds(schema.section, schema.key)
        let range = bounds.minimum...bounds.maximum
        let unit = bounds.unit
        let step = bounds.step
        return OptionalFieldRow(label: label, value: value, defaultValue: range.lowerBound) {
            if let current = value.wrappedValue {
                Stepper(
                    value: Binding(
                        get: { value.wrappedValue ?? range.lowerBound },
                        set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
                    ),
                    in: range,
                    step: step
                ) {
                    Text("\(current.formatted(.number.precision(.fractionLength(0...2)))) \(unit)").monospacedDigit()
                        .frame(width: 70, alignment: .leading)
                }
                .frame(width: 220, alignment: .leading)
            } else {
                Text("Inherited").foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
            }
        }
    }

    // An Override toggle gating a bool field: off = inherit (nil); on reveals an
    // On/Off switch for the value itself. Seeds `true` when first enabled, the
    // chromeless case the override is most useful for.
    private func optionalToggle(_ label: String, value: Binding<Bool?>) -> some View {
        OptionalFieldRow(label: label, value: value, defaultValue: true) {
            if let current = value.wrappedValue {
                Toggle(
                    isOn: Binding(
                        get: { value.wrappedValue ?? false },
                        set: { value.wrappedValue = $0 }
                    )
                ) { Text(current ? "On" : "Off") }
                .toggleStyle(SettingsSwitchStyle())
                .frame(width: 220, alignment: .leading)
            } else {
                Text("Inherited").foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
            }
        }
    }
}

// A row with an Override toggle gating a field. Off = inherit (nil), and the
// toggle seeds `defaultValue` when switched on.
private struct OptionalFieldRow<Value, Field: View>: View {
    let label: String
    @Binding
    var value: Value?
    let defaultValue: Value
    @ViewBuilder
    let field: () -> Field

    var body: some View {
        HStack {
            Toggle(
                isOn: Binding(
                    get: { value != nil },
                    set: { value = $0 ? (value ?? defaultValue) : nil }
                )
            ) { Text(label) }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Override " + label)
            .frame(width: 150, alignment: .leading)
            Spacer()
            field()
        }
    }
}
