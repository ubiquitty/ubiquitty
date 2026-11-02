// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittyCore
import UbiquittyKit

/// The same app preferences from Hosts, a terminal, or a keyboard command.
struct AppSettingsView: View {
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var settings = AppSettingsModel()
    @State
    private var isChoosingFont = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Match System", isOn: settings.toggle(.AppearanceFollowSystem))
                        .accessibilityLabel("Match System Appearance")
                    if settings.value(.AppearanceFollowSystem).boolean {
                        themeLink("Light Theme", key: .AppearanceSystemLightTheme, isDark: false)
                        themeLink("Dark Theme", key: .AppearanceSystemDarkTheme, isDark: true)
                    } else {
                        themeLink("Theme", key: .AppearanceTheme)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Saved host themes can override these defaults in Connection Details.")
                }
                TerminalFontSection(settings: settings, isChoosingFont: $isChoosingFont)
                Section {
                    NavigationLink("Text and Cursor") { textSettings }
                    NavigationLink("Padding") { paddingSettings }
                        .accessibilityIdentifier("padding-settings")
                    NavigationLink("Session Titles") { sessionTitleSettings }
                        .accessibilityIdentifier("session-title-settings")
                    NavigationLink("Keyboard") { keyboardSettings }
                    NavigationLink("Terminal") { terminalSettings }
                    NavigationLink("Privacy and Notifications") { privacySettings }
                }
                Section("About") {
                    LabeledContent(
                        "Version",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                    )
                    NavigationLink("Licenses") { LicensesView() }
                        .accessibilityIdentifier("licenses")
                    Link("Help", destination: URL(string: "https://ubiquitty.org/platforms/ios/")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetToolbar.close { dismiss() } }
            .navigationDestination(isPresented: $isChoosingFont) {
                TerminalFontPicker(
                    selectedFont: settings.fontFamily,
                    onSelect: { settings.selectFont(family: $0) },
                    isPresented: $isChoosingFont
                )
                .navigationTitle("Font")
                .navigationBarTitleDisplayMode(.inline)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .sheetChrome()
        .presentationDetents([.large])
    }

    private func themeLink(_ title: String, key: Ubiquitty.Preferences.Key, isDark: Bool? = nil) -> some View {
        NavigationLink {
            AppThemeGallery(settings: settings, key: key, title: title, isDark: isDark)
        } label: {
            LabeledContent(title, value: String(settings.value(key).text).isEmpty ? "Default" : String(settings.value(key).text))
        }
        .accessibilityIdentifier("terminal-theme-picker-\(title)")
    }

    private var textSettings: some View {
        Form {
            Section("Text") {
                Toggle("Ligatures", isOn: settings.toggle(.FontLigatures))
            }
            Section("Cursor") {
                Picker("Shape", selection: settings.text(.CursorShape)) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                Toggle("Blink", isOn: settings.toggle(.CursorBlink))
            }
        }
        .navigationTitle("Text and Cursor")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The content insets: one control for every edge, then each edge alone.
    ///
    /// Each step is one edit of the configuration document, which every open
    /// pane hears and re-lays out its grid for.
    private var paddingSettings: some View {
        let range = AppSettingsModel.paddingRange
        return Form {
            Section {
                Stepper(value: settings.paddingOnEveryEdge, in: range.bounds, step: range.step) {
                    LabeledContent("All Edges", value: settings.uniformPadding.map(Self.points) ?? "Mixed")
                }
                .accessibilityIdentifier("padding-all-edges")
            } footer: {
                Text("The space between the terminal’s text and the edges of its pane. It is added inside the screen’s safe area.")
            }
            Section("Edges") {
                ForEach(AppSettingsModel.paddingEdges, id: \.title) { edge in
                    Stepper(value: settings.padding(edge.key), in: range.bounds, step: range.step) {
                        LabeledContent(edge.title, value: Self.points(settings.value(edge.key).number))
                    }
                    .accessibilityIdentifier("padding-\(edge.title.lowercased())")
                }
            }
            if settings.hasCustomPadding {
                Section {
                    Button("Reset to Default") { settings.resetPadding() }
                        .accessibilityIdentifier("padding-reset")
                }
            }
        }
        .navigationTitle("Padding")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func points(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) pt"
    }

    private var keyboardSettings: some View {
        Form {
            Section {
                Toggle("Option Sends Meta", isOn: settings.optionSendsMeta)
            } footer: {
                Text(
                    "Use Option for terminal shortcuts on a hardware keyboard. Turn this off to type accents and other characters with Option."
                )
            }
            Section {
                NavigationLink("Accessory Keys") { AccessoryKeysView(settings: settings) }
            } footer: {
                Text("Choose and reorder the symbols above the keyboard on iPhone and in the shortcuts bar on iPad.")
            }
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sessionTitleSettings: some View {
        Form {
            Section {
                Toggle("Folder", isOn: settings.titleToggle(.TitleTabDirectory))
                    .accessibilityIdentifier("session-title-folder")
                if settings.titleToggle(.TitleTabDirectory).wrappedValue {
                    Picker("Folder Format", selection: settings.titleToggle(.TitleTabDirectoryPath)) {
                        Text("Name").tag(false)
                        Text("Path").tag(true)
                    }
                    .accessibilityIdentifier("session-title-folder-format")
                }
            } footer: {
                Text("Turn off Folder to remove the working directory from the start of automatic session titles.")
            }
            Section("Program") {
                Toggle("Program Title", isOn: settings.titleToggle(.TitleTabAppTitle))
                    .accessibilityIdentifier("session-title-program")
                Toggle("Active Process", isOn: settings.titleToggle(.TitleTabProcess))
                    .accessibilityIdentifier("session-title-process")
                Toggle("Arguments", isOn: settings.titleToggle(.TitleTabProcessArguments))
                    .disabled(!settings.titleToggle(.TitleTabProcess).wrappedValue)
                Toggle("Shell Command", isOn: settings.titleToggle(.TitleTabShellCommand))
                Toggle("Program Status", isOn: settings.titleToggle(.TitleTabProgramStatus))
            }
            Section {
                Toggle("Dimensions", isOn: settings.titleToggle(.TitleTabDimensions))
            } footer: {
                Text("Applies to automatic titles in workspace lists and tabs. Names you give to workspaces and tabs stay the same.")
            }
        }
        .navigationTitle("Session Titles")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var terminalSettings: some View {
        Form {
            Section {
                Stepper(value: settings.integer(.TerminalScrollbackLines), in: 1000...100000, step: 1000) {
                    LabeledContent("Scrollback Lines", value: Int(settings.value(.TerminalScrollbackLines).integer).formatted())
                }
            } footer: {
                Text("Remote workspaces also follow the host’s history limit.")
            }
            Section("Bell") {
                Toggle("Flash", isOn: settings.toggle(.BellVisual))
            }
            Section("Paste") {
                Toggle("Confirm Multiline Paste", isOn: settings.toggle(.PasteConfirmMultiline))
            }
            Section {
                Toggle("Open Links with a Tap", isOn: settings.toggle(.SelectionOSC8ClickOpens))
            } header: {
                Text("Links")
            } footer: {
                Text(
                    "Open a link a program marks as clickable with a tap. SSH, SFTP, FTP and FTPS links connect to a host, so a tap leaves them alone: touch and hold one and choose Open Link."
                )
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var privacySettings: some View {
        Form {
            Section {
                Toggle(
                    "Save Remote History",
                    isOn: Binding(
                        get: { settings.shouldPersistRemoteHistory },
                        set: { settings.setHistoryPersistence($0) }
                    )
                )
                .accessibilityIdentifier("terminal-save-remote-history")
                if !settings.historyPersistenceError.isEmpty { ErrorMessage(settings.historyPersistenceError) }
            } footer: {
                Text("Keeps saved workspaces’ history encrypted after you quit. Changing this clears it and disconnects.")
            }
            Section("Notifications") {
                Toggle("Notifications", isOn: settings.toggle(.NotificationsEnabled))
                Toggle("Sound", isOn: settings.toggle(.NotificationsSound))
                Button("Notification Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
        .navigationTitle("Privacy and Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Palette samples use Core’s registered colors, including custom themes.
private struct AppThemeGallery: View {
    let settings: AppSettingsModel
    let key: Ubiquitty.Preferences.Key
    let title: String
    var isDark: Bool?
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var query = ""

    private var choices: [Int] {
        (0..<Int(Ubiquitty.Themes.themeCount()))
            .filter { index in
                (isDark == nil || Ubiquitty.Themes.isThemeDark(Int32(index)) == isDark)
                    && (query.isEmpty || name(index).localizedCaseInsensitiveContains(query))
            }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 16) {
                ForEach(choices, id: \.self) { index in
                    Button {
                        settings.write(key, .ofText(.String, std.string(name(index))))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            sample(index)
                            HStack {
                                Text(name(index)).foregroundStyle(.primary)
                                Spacer()
                                if name(index) == String(settings.value(key).text) {
                                    Image(systemName: "checkmark").accessibilityLabel("Selected")
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme-choice-\(name(index))")
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search Themes")
    }

    private func name(_ index: Int) -> String {
        Ubiquitty.Themes.themeName(Int32(index)).map { String(cString: $0) } ?? ""
    }

    private func sample(_ index: Int) -> some View {
        var colors = [UInt8](repeating: 0, count: 768)
        var defaults = [UInt8](repeating: 0, count: 9)
        _ = Ubiquitty.Themes.themeColorBytes(Int32(index), &colors, &defaults, nil)
        func color(_ bytes: [UInt8], _ offset: Int) -> Color {
            Color(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255, blue: Double(bytes[offset + 2]) / 255)
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text("~/project $ ls").foregroundStyle(color(defaults, 0))
            Text("Sources  README.md").foregroundStyle(color(colors, 12))
            HStack(spacing: 0) {
                ForEach(0..<8) { slot in color(colors, slot * 3).frame(height: 8) }
            }
            .padding(.top, 6)
        }
        .font(.custom(settings.fontFamily, size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(color(defaults, 3), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

/// The license texts the bundle carries under `Licenses/`, where the build
/// copies every notice the third-party inventory names, each at its path in the
/// source tree. The project's own license, notice and third-party summary come
/// first; the rest follow by path.
private struct LicensesView: View {
    private let documents = LicenseDocument.bundled()

    var body: some View {
        List(documents) { document in
            NavigationLink(document.title) { LicenseTextView(document: document) }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One bundled license text, read from the bundle when it is shown.
private struct LicenseTextView: View {
    let document: LicenseDocument

    var body: some View {
        ScrollView {
            Text((try? String(contentsOf: document.url, encoding: .utf8)) ?? "")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A file under the bundle's `Licenses/`, titled by its path below it.
private struct LicenseDocument: Identifiable {
    let title: String
    let url: URL
    var id: String { title }

    private static let leading = ["LICENSE", "NOTICE", "third-party-notices.md"]

    /// Every regular file under `Licenses/`, the leading three first.
    ///
    /// The titles are the relative paths `subpaths(atPath:)` returns: an
    /// enumerator's URLs resolve the container's symbolic links, so trimming
    /// the root's components off them miscounts.
    static func bundled() -> [LicenseDocument] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true),
            let paths = FileManager.default.subpaths(atPath: root.path)
        else {
            return []
        }
        var documents: [LicenseDocument] = []
        for path in paths {
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                documents.append(LicenseDocument(title: path, url: url))
            }
        }
        func rank(_ document: LicenseDocument) -> Int { leading.firstIndex(of: document.title) ?? leading.count }
        return documents.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.title < $1.title }
    }
}
