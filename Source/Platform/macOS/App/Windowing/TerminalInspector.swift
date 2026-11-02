// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Presents a process from the session's shared process sample.
package struct InspectorProcess: Identifiable, Equatable {
    package let id: UInt32
    let group: UInt32
    package let name: String
    let arguments: String
    let rawName: String
    let smartName: String
    let smartArguments: String
    let marker: String
    let isSecondary: Bool
    let isZombie: Bool
    let isStopped: Bool
    let user: String
    let isForeground: Bool
}

/// A live palette color displayed independently of the selected theme's preview.
struct InspectorColor: Identifiable, Equatable {
    let id: Int
    let red: UInt16
    let green: UInt16
    let blue: UInt16
    var color: Color { Color(red: Double(red) / 65535, green: Double(green) / 65535, blue: Double(blue) / 65535) }
    var name: String {
        switch id {
        case 16: "Text"
        case 17: "Background"
        case 18: "Cursor"
        default: "ANSI \(id)"
        }
    }
    var description: String {
        "\(name): " + String(format: "#%02X%02X%02X", red >> 8, green >> 8, blue >> 8)
    }
}

/// Holds the native inspector's presentation state, refreshed by session events.
@MainActor
@Observable
package final class TerminalInspectorModel {
    weak var controller: TerminalWindowController?
    weak var surface: TerminalSurface?
    package var target: (any InspectorTarget)? {
        didSet {
            oldValue?.setObservation(ObjectIdentifier(self), isActive: false)
            target?.setObservation(ObjectIdentifier(self), isActive: isObservationActive)
        }
    }
    package var isObservationActive = false {
        didSet { target?.setObservation(ObjectIdentifier(self), isActive: isObservationActive) }
    }
    package init() {}
    var canClearDirectory: Bool { target?.canClearDirectory ?? false }
    package var title = ""
    package var tabTitle = ""
    package var columns = 0
    package var rows = 0
    package var directory = ""
    package var tty = ""
    package var answerbackDisplay = ""
    var canConfigureAnswerback = false
    var command = ""
    var shell = ""
    var font = ""
    package var fontFamily = ""
    package var fontSize = 12.0
    let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
    var background = Color.black
    var canResetBackground = false
    var palette: [InspectorColor] = []
    var themes: [ThemeSnapshot] = []
    private var themeCatalogGeneration: UInt64?
    package var processes: [InspectorProcess] = []
    var selectedProcess: UInt32?
    var showsArguments = UserDefaults.standard.bool(forKey: "UBInspectorShowArguments") {
        didSet { UserDefaults.standard.set(showsArguments, forKey: "UBInspectorShowArguments") }
    }
    var showsSmartNames = false
    var section = 0
    var themeQuery = ""
    var selectedTheme: Int?
    var isEditing = false
    var error = ""
    private var identity: InspectorIdentity?
    private var paletteGeneration: UInt64?

    /// Refreshes data for the pane without overwriting an in-progress edit.
    ///
    /// - Parameter surface: The pane selected for inspection.
    func refresh(from surface: TerminalSurface) {
        self.surface = surface
        if let current = target as? SurfaceInspectorTarget, current.surface === surface, current.controller === controller {
            refresh()
            return
        }
        target = SurfaceInspectorTarget(controller: controller, surface: surface)
        refresh()
    }

    /// Refreshes the selected session using the existing metadata event.
    package func refresh() {
        guard let target else { return }
        let changedPane = identity != target.identity
        identity = target.identity
        let info = target.information()
        let nextAnswerback = String(info.answerbackDisplay)
        if answerbackDisplay != nextAnswerback { answerbackDisplay = nextAnswerback }
        if canConfigureAnswerback != info.canConfigureAnswerback { canConfigureAnswerback = info.canConfigureAnswerback }
        if changedPane || paletteGeneration != info.paletteGeneration {
            refreshTheme()
            palette = (0..<19)
                .map { index in
                    let color = info.colorAt(UInt32(index))
                    return InspectorColor(id: index, red: color.red, green: color.green, blue: color.blue)
                }
            paletteGeneration = info.paletteGeneration
        }
        // Written only where the value moved, as `processes` already is:
        // every field here is observed, and an assignment of the same value
        // still invalidates whatever reads it.
        if changedPane || !isEditing {
            let nextTitle = target.windowTitle
            if title != nextTitle { title = nextTitle }
            let nextTabTitle = target.tabTitle
            if tabTitle != nextTabTitle { tabTitle = nextTabTitle }
            if columns != Int(info.columns) { columns = Int(info.columns) }
            if rows != Int(info.rows) { rows = Int(info.rows) }
            let nextBackground = Color(
                red: Double(info.backgroundRed) / 255,
                green: Double(info.backgroundGreen) / 255,
                blue: Double(info.backgroundBlue) / 255
            )
            if background != nextBackground { background = nextBackground }
        }
        if canResetBackground != target.canResetBackground { canResetBackground = target.canResetBackground }
        if directory != String(info.directory) { directory = String(info.directory) }
        if tty != String(info.tty) { tty = String(info.tty) }
        if command != String(info.command) { command = String(info.command) }
        if shell != String(info.shell) { shell = String(info.shell) }
        let nextFont = "\(target.fontFamily) · \(target.fontSize.formatted()) pt"
        if font != nextFont { font = nextFont }
        if changedPane || !isEditing {
            if fontFamily != target.fontFamily { fontFamily = target.fontFamily }
            if fontSize != target.fontSize { fontSize = target.fontSize }
        }
        let next = info.processes.map { record in
            let presentation = Ubiquitty.Session.processPresentation(record)
            return InspectorProcess(
                id: presentation.processID,
                group: presentation.processGroupID,
                name: String(presentation.name),
                arguments: String(presentation.arguments),
                rawName: String(presentation.rawName),
                smartName: String(presentation.smartName),
                smartArguments: String(presentation.smartArguments),
                marker: String(presentation.marker),
                isSecondary: presentation.isSecondary,
                isZombie: presentation.isZombie,
                isStopped: record.state == .Stopped,
                user: String(presentation.user),
                isForeground: presentation.isForeground
            )
        }
        if processes != next { processes = next }
        if changedPane || !processes.contains(where: { $0.id == selectedProcess }) { selectedProcess = nil }
    }

    /// Replaces the answerback without exposing the concealed message to the editor.
    /// - Parameter value: The replacement typed by the user.
    package func applyAnswerback(_ value: String) {
        guard target?.setAnswerback(value) == true else { return }
        refresh()
    }

    /// Copies one representation of the selected process to the system pasteboard.
    ///
    /// - Parameters:
    ///   - process: The selected process row.
    ///   - field: The representation requested by the menu.
    func copyProcess(_ process: InspectorProcess, field: String) {
        let text: String
        switch field {
        case "id": text = String(process.id)
        case "name": text = process.rawName
        case "command": text = process.arguments
        default: text = "\(process.marker)\t\(displayName(process))\t\(process.user)\t\(process.id)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Resolves the selected process-name display mode.
    ///
    /// - Parameter process: The row to display.
    /// - Returns: The name or command supplied by Core.
    func displayName(_ process: InspectorProcess) -> String {
        if showsSmartNames { return showsArguments ? process.smartArguments : process.smartName }
        return showsArguments ? process.arguments : process.name
    }

    /// Clears the session's reported directory without changing the shell's working directory.
    func clearDirectory() {
        guard target?.clearDirectory() == true else { return }
        refresh()
    }

    /// Writes the fields' titles to the window's one custom-title state.
    package func applyTitles() {
        isEditing = false
        target?.applyTitles(window: title, tab: tabTitle)
    }

    /// Resizes the terminal using the existing grid-to-window geometry path.
    func applyDimensions() {
        isEditing = false
        target?.resize(columns: columns, rows: rows)
    }

    /// Applies the selected native color to the terminal's default background.
    func applyBackground() {
        guard let color = NSColor(background).usingColorSpace(.sRGB), let target else { return }
        let accepted = target.applyBackground(
            red: UInt8((color.redComponent * 255).rounded()),
            green: UInt8((color.greenComponent * 255).rounded()),
            blue: UInt8((color.blueComponent * 255).rounded())
        )
        if !accepted { error = "The session couldn’t apply the background color. Try again." }
        refresh()
    }

    /// Restores the session's baseline background color.
    func resetBackground() {
        guard target?.resetBackground() == true else {
            error = "The session couldn’t reset the background color. Try again."
            return
        }
        refresh()
    }

    /// Reads the theme identified by the session's authoritative reset palette.
    func refreshTheme() {
        let generation = Ubiquitty.Themes.generation()
        if themeCatalogGeneration != generation {
            let builtInCount = Int(Ubiquitty.Themes.builtInCount())
            themes = TerminalSurface.themeNames.enumerated()
                .map {
                    ThemeSnapshot.load($0.offset, name: $0.element, builtInCount: builtInCount)
                }
            themeCatalogGeneration = generation
        }
        guard let target else {
            selectedTheme = nil
            return
        }
        let index = target.themeIndex()
        selectedTheme = index >= 0 ? Int(index) : nil
    }

    /// Applies the selected font while retaining the renderer's features and fallback configuration.
    package func applyFont() {
        isEditing = false
        if target?.applyFont(family: fontFamily, size: fontSize) != true {
            error = "This font couldn’t be applied. Choose an installed family and a size from 6 to 144 points."
        }
        refresh()
    }

    /// Applies a theme to the inspected pane.
    ///
    /// - Parameter index: The index in Core's theme catalog.
    func applyTheme(_ index: Int) {
        guard target?.applyTheme(index) == true else {
            error = "The session couldn’t apply this theme. Try again."
            return
        }
        refresh()
    }

    /// Sends a signal to the selected live process group.
    ///
    /// - Parameter signal: The POSIX signal number.
    func sendSignal(_ signal: Int32) {
        guard let selectedProcess else { return }
        if target?.sendSignal(process: selectedProcess, signal: signal) != true {
            error = "The session couldn’t signal this process. It may have already exited."
        }
    }
}

/// Keeps inspector controls inside the native content region while its background fills the window.
@MainActor
final class TerminalInspectorViewController: NSViewController {
    private let hosting: NSHostingController<TerminalInspectorView>
    private var safeTop: NSLayoutConstraint?
    private var fullTop: NSLayoutConstraint?

    /// Controls whether a titleless window uses the complete inspector height.
    var hidesTitleBar: Bool {
        didSet { updateContentTop() }
    }

    /// Creates the inspector content with the window's title-bar visibility.
    ///
    /// - Parameters:
    ///   - model: The event-driven session presentation model.
    ///   - hidesTitleBar: Whether the window has no title-bar content to avoid.
    init(model: TerminalInspectorModel, hidesTitleBar: Bool) {
        hosting = NSHostingController(rootView: TerminalInspectorView(model: model))
        self.hidesTitleBar = hidesTitleBar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalInspectorViewController is built in code")
    }

    override func loadView() {
        view = NSView()
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        safeTop = hosting.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        fullTop = hosting.view.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateContentTop()
    }

    private func updateContentTop() {
        safeTop?.isActive = false
        fullTop?.isActive = false
        safeTop?.isActive = !hidesTitleBar
        fullTop?.isActive = hidesTitleBar
    }
}

/// Displays session details and appearance controls using native macOS forms.
package struct TerminalInspectorView: View {
    @Bindable
    var model: TerminalInspectorModel
    @FocusState
    private var isEditing: Bool
    @State
    private var showsAnswerbackEditor = false
    @State
    private var replacementAnswerback = ""

    package init(model: TerminalInspectorModel) { self.model = model }

    package var body: some View {
        VStack(spacing: 0) {
            InspectorSectionControl(selection: $model.section)
                .frame(height: 32).frame(maxWidth: .infinity).padding(16)
            switch model.section {
            case 0: info
            case 1: profile
            default: processes
            }
        }
        .font(.system(size: NSFont.smallSystemFontSize))
        .controlSize(.small)
        .onReceive(NotificationCenter.default.publisher(for: .terminalAppearanceChanged)) { _ in
            model.refresh()
            model.refreshTheme()
        }
        .onChange(of: isEditing) { _, value in model.isEditing = value }
        .alert("Replace Answerback", isPresented: $showsAnswerbackEditor) {
            TextField("New message", text: $replacementAnswerback)
            Button("Cancel", role: .cancel) { replacementAnswerback = "" }
            Button("Replace") {
                model.applyAnswerback(replacementAnswerback)
                replacementAnswerback = ""
            }
        } message: {
            Text("The terminal sends this message when an application requests its answerback.")
        }
        .alert("Couldn’t Complete the Action", isPresented: Binding(get: { !model.error.isEmpty }, set: { if !$0 { model.error = "" } })) {
            Button("OK") { model.error = "" }
        } message: {
            Text(model.error)
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var info: some View {
        Form {
            Section("Titles") {
                TextField("Window", text: $model.title, prompt: Text("Automatic"))
                    .focused($isEditing).onSubmit { model.applyTitles() }
                TextField("Tab", text: $model.tabTitle, prompt: Text("Automatic"))
                    .focused($isEditing).onSubmit { model.applyTitles() }
            }
            Section("Terminal") {
                if model.canConfigureAnswerback {
                    LabeledContent("Answerback") {
                        Text(model.answerbackDisplay.isEmpty ? "None" : model.answerbackDisplay)
                            .foregroundStyle(.secondary).lineLimit(2)
                        Button("Replace…") {
                            replacementAnswerback = ""
                            showsAnswerbackEditor = true
                        }
                    }
                }
                TextField("Columns", value: $model.columns, format: .number.grouping(.never))
                    .focused($isEditing).onSubmit { model.applyDimensions() }
                TextField("Rows", value: $model.rows, format: .number.grouping(.never))
                    .focused($isEditing).onSubmit { model.applyDimensions() }
                HStack {
                    ColorPicker(
                        "Background",
                        selection: Binding(
                            get: { model.background },
                            set: {
                                model.background = $0
                                model.applyBackground()
                            }
                        ),
                        supportsOpacity: false
                    )
                    if model.canResetBackground {
                        Button {
                            model.resetBackground()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Reset Background Color").accessibilityLabel("Reset Background Color")
                    }
                }
            }
            Section("Session") {
                LabeledContent("Directory") {
                    HStack(spacing: 6) {
                        Text(model.directory.isEmpty ? "—" : model.directory)
                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            .textSelection(.enabled).lineLimit(3).help(model.directory)
                        if model.canClearDirectory {
                            Button {
                                model.clearDirectory()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Clear Reported Directory").accessibilityLabel("Clear Reported Directory")
                        }
                    }
                }
                detail("TTY", model.tty.isEmpty || model.tty.hasPrefix("/") ? model.tty : "/dev/\(model.tty)")
                detail("Command", model.command)
                detail("Shell", model.shell)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Running Processes").font(.headline)
                Spacer()
                Menu {
                    processMenu(model.processes.first { $0.id == model.selectedProcess })
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 16)
            Table(model.processes, selection: $model.selectedProcess) {
                TableColumn("•") { process in
                    Text(process.marker).foregroundStyle(processColor(process))
                }
                .width(18)
                TableColumn("Process") { process in
                    HStack(spacing: 8) {
                        Text(model.displayName(process))
                            .fontWeight(process.isForeground && !process.isSecondary ? .semibold : .regular)
                            .lineLimit(1).truncationMode(.tail).help(process.arguments)
                        Spacer(minLength: 0)
                        if !process.user.isEmpty && process.user != NSUserName() {
                            Text(process.user).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(processColor(process))
                }
                TableColumn("ID") { process in
                    Text(String(process.id)).monospacedDigit().foregroundStyle(processColor(process))
                        .fontWeight(process.isForeground && !process.isSecondary ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(65)
            }
            .font(.system(size: 11))
            .contextMenu(forSelectionType: UInt32.self) { identifiers in
                processMenu(model.processes.first { identifiers.contains($0.id) })
            }
            .onCopyCommand {
                guard let process = model.processes.first(where: { $0.id == model.selectedProcess }) else { return [] }
                return [
                    NSItemProvider(object: "\(process.marker)\t\(model.displayName(process))\t\(process.user)\t\(process.id)" as NSString)
                ]
            }
            .frame(minHeight: 160, idealHeight: 220).padding(.horizontal, 12)
            if model.processes.isEmpty {
                Text("No local process information for this session.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func processMenu(_ process: InspectorProcess?) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { if let process { model.copyProcess(process, field: "row") } }
            .disabled(process == nil)
        Button("Copy ID") { if let process { model.copyProcess(process, field: "id") } }.disabled(process == nil)
        Button("Copy Name") { if let process { model.copyProcess(process, field: "name") } }.disabled(process == nil)
        Button("Copy Command") { if let process { model.copyProcess(process, field: "command") } }.disabled(process == nil)
        Divider()
        Toggle("Show Arguments", isOn: $model.showsArguments)
        Toggle("Show Smart Names and Arguments", isOn: $model.showsSmartNames)
        Divider()
        Menu("Signal Process Group") {
            ForEach(signalOptions, id: \.number) { signal in
                Button(signal.label) {
                    guard let process else { return }
                    model.selectedProcess = process.id
                    model.sendSignal(signal.number)
                }
            }
        }
        .disabled(process == nil || process?.isZombie == true || (process?.group ?? 0) <= 1)
    }

    private var signalOptions: [(number: Int32, label: String)] {
        Ubiquitty.PAL.Process.Signal.table()
            .map { entry in
                (entry.number, "\(String(entry.label)) (\(String(entry.mnemonic)))")
            }
    }

    private func processColor(_ process: InspectorProcess) -> Color {
        if process.isZombie { return .orange }
        if process.isStopped { return .red }
        return process.isSecondary ? .secondary : .primary
    }

    /// Displays a selectable session fact with an explicit unavailable value.
    ///
    /// - Parameters:
    ///   - label: The fact's name.
    ///   - value: Its current value.
    /// - Returns: A native labeled row.
    private func detail(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled).lineLimit(3).help(value)
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker(
                    "Font",
                    selection: Binding(
                        get: { model.fontFamily },
                        set: {
                            model.fontFamily = $0
                            model.applyFont()
                        }
                    )
                ) {
                    if !model.fontFamilies.contains(model.fontFamily) {
                        Text(model.fontFamily).tag(model.fontFamily)
                    }
                    ForEach(model.fontFamilies, id: \.self) { family in Text(family).tag(family) }
                }
                TextField("Size", value: $model.fontSize, format: .number)
                    .focused($isEditing).onSubmit { model.applyFont() }
                Section("Live Colors") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 8), spacing: 5) {
                        ForEach(model.palette.prefix(16)) { color in
                            RoundedRectangle(cornerRadius: 4).fill(color.color).frame(height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)))
                                .help(color.description).accessibilityLabel(color.description)
                        }
                    }
                    HStack {
                        ForEach(model.palette.suffix(3)) { color in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4).fill(color.color).frame(height: 20)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)))
                                Text(color.name).font(.caption2).foregroundStyle(.secondary)
                            }
                            .help(color.description).accessibilityLabel(color.description)
                        }
                    }
                }
            }
            .formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
            .scrollContentBackground(.hidden)
            TextField("Search themes", text: $model.themeQuery).textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 12)], spacing: 16) {
                    ForEach(model.themes.filter { model.themeQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(model.themeQuery) })
                    { theme in
                        ThemeChoice(theme: theme, isSelected: model.selectedTheme == theme.id) {
                            model.applyTheme(theme.id)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }
}

/// Uses equally sized native segments across the inspector's width.
private struct InspectorSectionControl: NSViewRepresentable {
    @Binding
    var selection: Int

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 3
        control.segmentDistribution = .fillEqually
        control.trackingMode = .selectOne
        control.controlSize = .large
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sections = [("info.circle", "Session Info"), ("paintpalette", "Appearance"), ("list.bullet.rectangle", "Running Processes")]
        for (index, section) in sections.enumerated() {
            control.setImage(NSImage(systemSymbolName: section.0, accessibilityDescription: section.1), forSegment: index)
            control.setToolTip(section.1, forSegment: index)
        }
        control.setAccessibilityLabel("Inspector section")
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSection(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }

        @objc
        func selectSection(_ sender: NSSegmentedControl) {
            selection.wrappedValue = sender.selectedSegment
        }
    }
}
