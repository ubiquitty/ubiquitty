// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
final class SettingsCatalogModel: ObservableObject {
    @Published
    private(set) var categories: [SettingsCategory]
    // A pending external request to select a category (e.g. Beam opening a custom
    // pane). SettingsView observes it, navigates, then consumes it back to nil.
    @Published
    var selectCategory: String?
    /// The stable setting address to reveal after selecting its category.
    @Published
    var revealRowID: String?
    /// The title of the page on show, which the hosting window carries as its
    /// own. Set here rather than left to the navigation title, whose route to
    /// the window's title is a release's choice rather than a contract.
    @Published
    var shownTitle = "Settings"

    func contains(rowID: String, in categoryID: String) -> Bool {
        guard let category = categories.first(where: { $0.id == categoryID }) else { return false }
        if category.searchEntries.contains(where: { $0.id == rowID }) { return true }
        if case .pane(let pane) = category.content { return pane.cards.contains { $0.rows.contains { $0.id == rowID } } }
        return false
    }

    init() {
        categories = SettingsCatalog.categories()
    }

    func refresh() {
        categories = SettingsCatalog.categories()
    }
}

struct SettingsView: View {
    @StateObject
    private var previewState: FontSettingsPreviewState
    @StateObject
    private var catalogModel: SettingsCatalogModel
    @State
    private var navigation: SettingsNavigation
    @State
    private var searchText = ""
    @FocusState
    private var isSidebarFocused: Bool
    // The control a search match navigated to; the destination pane scrolls it
    // into view and pulses it once, then clears.
    @State
    private var pulseTarget: String?
    // Motion law: the scroll-to is positional motion, so it snaps (no animation)
    // under Reduce Motion. The pulse tint is opacity, not motion — it stays.
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    // The model is minted inside the body rather than as a default argument:
    // a default argument evaluates at the caller, outside this initializer's
    // isolation, and the model's own initializer is main-actor.
    @MainActor
    init(catalogModel: SettingsCatalogModel? = nil, previewState: FontSettingsPreviewState? = nil) {
        let model = catalogModel ?? SettingsCatalogModel()
        _previewState = StateObject(wrappedValue: previewState ?? FontSettingsPreviewState())
        _catalogModel = StateObject(wrappedValue: model)
        _navigation = State(initialValue: SettingsNavigation(selection: model.categories.first?.id ?? "appearance"))
    }

    private var selection: String { navigation.selection }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 460)
        .navigationSplitViewStyle(.balanced)
        .environmentObject(previewState)
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            refreshFontsIfNeeded(selection)
            applySelectCategory() // a request set before the view appeared (first open)
            isSidebarFocused = true
        }
        .onChangeCompatibility(of: catalogModel.selectCategory) {
            applySelectCategory()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsView.fontFamilyChanged)) { _ in
            // The family's members are the weight pickers' rows; a new
            // family means new rows.
            catalogModel.refresh()
        }
    }

    // Consume both parts together so an invalid destination cannot leave a
    // pending highlight attached to a later navigation request.
    private func applySelectCategory() {
        guard let category = catalogModel.selectCategory else { return }
        let rowID = catalogModel.revealRowID
        catalogModel.revealRowID = nil
        catalogModel.selectCategory = nil
        guard categories.contains(where: { $0.id == category }) else { return }
        navigate(to: category)
        searchText = ""
        guard let rowID, catalogModel.contains(rowID: rowID, in: category) else { return }
        DispatchQueue.main.async { pulseTarget = rowID }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 8) {
            SettingsSearchField(text: $searchText)
                .frame(height: 28)
                .padding(.horizontal, 10)
                .padding(.top, 12)
            if searchText.isEmpty {
                List(
                    selection: Binding(
                        get: { categories.sidebarCategoryID(for: selection) },
                        set: { navigate(to: $0) }
                    )
                ) {
                    ForEach(SettingsCategory.Group.allCases, id: \.self) { group in
                        Section {
                            ForEach(categories.filter { $0.parentID == nil && $0.group == group }) { category in
                                HStack(spacing: 8) {
                                    SettingsCategoryIcon(symbol: category.symbol, color: category.color)
                                    Text(category.title)
                                }
                                .padding(.vertical, 2)
                                .tag(category.id)
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded { navigate(to: category.id) })
                                .accessibilityIdentifier("settings-category-\(category.id)")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .focused($isSidebarFocused)
                .clipped()
                .accessibilityIdentifier("settings-categories")
            } else {
                searchResultsList
                    .clipped()
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 260)
        .scrollContentBackground(.hidden)
    }

    // Flattened cross-pane matches replace the category list while searching.
    // Selecting one navigates to its pane and pulses the matched control.
    @ViewBuilder
    private var searchResultsList: some View {
        let hits = categories.settingsSearchHits().filter { $0.matches(searchText) }
        if hits.isEmpty {
            VStack {
                Spacer()
                Text("No settings match “\(searchText)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(hits) { hit in
                Button {
                    navigate(to: hit)
                } label: {
                    HStack(spacing: 8) {
                        SettingsCategoryIcon(
                            symbol: hit.categorySymbol,
                            color: categories.first(where: { $0.id == hit.categoryID })?.color ?? .gray
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.label)
                            Text(hit.categoryTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    private func navigate(to hit: SettingsSearchHit) {
        navigate(to: hit.categoryID)
        searchText = ""
        // Defer the pulse one runloop turn so the destination pane has rendered
        // for the new selection — the ScrollViewReader needs the row's id present.
        guard let rowID = hit.rowID,
            catalogModel.contains(rowID: rowID, in: hit.categoryID)
        else { return }
        DispatchQueue.main.async { pulseTarget = rowID }
    }

    private func navigate(to categoryID: String) {
        pulseTarget = nil
        refreshFontsIfNeeded(categoryID)
        navigation.select(categoryID)
    }

    private var categories: [SettingsCategory] {
        catalogModel.categories
    }

    private func refreshFontsIfNeeded(_ categoryID: String) {
        if categoryID == "fonts" {
            catalogModel.refresh()
        }
    }

    /// The notification the family setter posts; the weight pickers are
    /// built from the family's members and must rebuild with it.
    static let fontFamilyChanged = NSNotification.Name("UBFontFamilyChanged")

    @ViewBuilder
    private var detail: some View {
        let category = categories.first { $0.id == selection }
        ZStack {
            Color(nsColor: .controlBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                if selection == "fonts" || category?.parentID == "fonts" {
                    FontSettingsPreview(kind: .font)
                    Divider()
                } else if let pinnedHeader = category?.pinnedHeader {
                    pinnedHeader()
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if let category, ["sessions", "security"].contains(category.id) {
                                SettingsCategoryHeader(category: category)
                            }
                            if selection == "appearance" {
                                AppearanceThemePicker()
                                    .padding(.horizontal, SettingsStyle.pageInset)
                                    .frame(maxWidth: SettingsStyle.contentWidth)
                                    .frame(maxWidth: .infinity)
                            }
                            switch category?.content {
                            case .pane(let pane):
                                PaneView(pane: pane, pulseTarget: pulseTarget)
                            case .custom(let builder):
                                builder()
                            case .none:
                                EmptyView()
                            }
                            if selection == "font-routing" { FontRoutingPane() }
                            categoryLinks
                                .padding(.bottom, SettingsStyle.pageInset)
                        }
                    }
                    .id(selection)
                    .environment(\.settingsRevealTarget, pulseTarget)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("settings-detail")
                    .onChangeCompatibility(of: pulseTarget) {
                        pulseToTarget(using: proxy)
                    }
                }
            }
        }
        .navigationTitle(category?.title ?? "Settings")
        .onAppear {
            catalogModel.shownTitle = category?.title ?? "Settings"
        }
        .onChangeCompatibility(of: category?.title) {
            catalogModel.shownTitle = category?.title ?? "Settings"
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    searchText = ""
                    navigation.goBack()
                    pulseTarget = nil
                    refreshFontsIfNeeded(selection)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!navigation.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Go back")
                Button {
                    searchText = ""
                    navigation.goForward()
                    pulseTarget = nil
                    refreshFontsIfNeeded(selection)
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!navigation.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Go forward")
            }
        }
    }

    @ViewBuilder
    private var categoryLinks: some View {
        let children = categories.filter { $0.parentID == selection }
        if !children.isEmpty {
            SettingsCardView {
                ForEach(children) { category in
                    SettingsListRow(isFirst: category.id == children.first?.id) {
                        Button {
                            navigate(to: category.id)
                        } label: {
                            HStack(spacing: 10) {
                                SettingsCategoryIcon(symbol: category.symbol, color: category.color)
                                Text(category.title)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-open-\(category.id)")
                    }
                }
            }
            .padding(.horizontal, SettingsStyle.pageInset)
            .frame(maxWidth: SettingsStyle.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    // Scroll the just-navigated-to control into view and let it pulse, then
    // retire the highlight after it plays so it reads as a one-shot "here".
    private func pulseToTarget(using proxy: ScrollViewProxy) {
        guard let target = pulseTarget else { return }
        // A custom target may first expand a disclosure group on this same update.
        DispatchQueue.main.async {
            guard pulseTarget == target else { return }
            if reduceMotion {
                proxy.scrollTo(target, anchor: .center)
            } else {
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if pulseTarget == target { pulseTarget = nil }
        }
    }
}

// One pane = a vertical stack of cards.
struct PaneView: View {
    let pane: SettingsPane
    let pulseTarget: String?

    var body: some View {
        SettingsPaneStack {
            ForEach(pane.cards) { CardView(card: $0, pulseTarget: pulseTarget) }
        }
    }
}

/// One catalog card inside a custom pane, so its rows read, reset and answer a
/// search exactly as a data-driven pane's rows do.
struct SettingsCatalogCardView: View {
    /// The card to draw.
    let card: SettingsCard
    @Environment(\.settingsRevealTarget)
    private var revealTarget

    var body: some View {
        CardView(card: card, pulseTarget: revealTarget)
    }
}

// One card = an optional title, then a rounded group of rows divided by
// hairlines.
private struct CardView: View {
    let card: SettingsCard
    let pulseTarget: String?
    @State
    private var resetProposal: SettingsResetProposal?
    @State
    private var revision = 0

    var body: some View {
        let _ = revision
        let customized = SettingsResetProposal.customized(card.rows)
        SettingsCardView(title: card.title, footer: card.footer, headerAccessory: customized.isEmpty ? nil : AnyView(resetMenu(customized)))
        {
            ForEach(Array(card.rows.enumerated()), id: \.element.id) { index, row in
                SettingsListRow(isFirst: index == 0) {
                    RowView(row: row, pulseTarget: pulseTarget)
                        .contextMenu {
                            if customized.contains(where: { $0.id == row.id }) {
                                Button("Reset \(row.label)…") { resetProposal = .init(title: row.label, rows: [row]) }
                            }
                        }
                }
            }
        }
        .sheet(item: $resetProposal) { SettingsResetSheet(proposal: $0) }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in revision &+= 1 }
    }

    private func resetMenu(_ customized: [SettingsRow]) -> some View {
        Menu {
            ForEach(customized) { row in
                Button("Reset \(row.label)…") { resetProposal = .init(title: row.label, rows: [row]) }
            }
            if customized.count > 1 {
                Divider()
                Button("Reset Section…") { resetProposal = .init(title: card.title ?? "These Settings", rows: customized) }
            }
        } label: {
            Label("Reset Settings", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reset settings in this section")
        .accessibilityIdentifier("settings-reset-" + card.rows.map(\.id).joined(separator: "-"))
    }
}

// One row = label (+ optional detail) on the left, the bound control on
// the right; or, for a control that needs the width, the control alone.
private struct RowView: View {
    let row: SettingsRow
    let pulseTarget: String?
    private let control: SettingsRow.Control
    @State
    private var isEnabled: Bool
    @State
    private var shownDetail: String?

    init(row: SettingsRow, pulseTarget: String?) {
        self.row = row
        self.pulseTarget = pulseTarget
        self.control = row.control.resolved()
        _isEnabled = State(initialValue: row.isEnabled?() ?? true)
        _shownDetail = State(initialValue: row.currentDetail?() ?? row.detail)
    }

    private var isPulsing: Bool { pulseTarget == row.id }

    var body: some View {
        Group {
            if case .backgroundImage(let get, let set) = control {
                // The card's title already names the setting, so the full-width
                // control carries the row's label only for VoiceOver.
                BackgroundImageField(label: row.label, get: get, set: set)
            } else {
                labelledRow
            }
        }
        // A search match scrolls here and flashes this tint once (see pulseTarget).
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isPulsing ? 0.22 : 0))
                .padding(.horizontal, 6)
        )
        .animation(.easeInOut(duration: 0.4), value: isPulsing)
        .id(row.id)
        .accessibilityIdentifier("settings-row-" + row.id)
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in
            isEnabled = row.isEnabled?() ?? true
            shownDetail = row.currentDetail?() ?? row.detail
        }
    }

    private var labelledRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                if let detail = shownDetail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(isEnabled ? .secondary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            Group {
                if case .fontFamily = row.presentation,
                    case .menu(let options, _, let get, let set) = control
                {
                    SettingsFontPicker(options: options, get: get, set: set)
                } else if case .fontWidth = row.presentation,
                    case .stepper(let minimum, let maximum, let step, _, let get, let set) = control
                {
                    FontWidthControl(range: minimum...maximum, step: step, get: get, set: set)
                } else {
                    ControlView(control: control)
                }
            }
            .disabled(!isEnabled)
            .accessibilityLabel(row.label)
            .help(row.detail ?? "")
        }
    }
}

private struct FontWidthControl: View {
    let range: ClosedRange<Double>
    let step: Double
    let get: () -> Double
    let set: (Double) -> Void
    @State
    private var value: Double

    init(range: ClosedRange<Double>, step: Double, get: @escaping () -> Double, set: @escaping (Double) -> Void) {
        self.range = range
        self.step = step
        self.get = get
        self.set = set
        _value = State(initialValue: get())
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            MenuControl(
                options: ["Font Default", "Custom"],
                get: { value > 0 ? 1 : 0 },
                set: { selection in
                    value = selection == 1 ? 100 : 0
                    set(value)
                }
            )
            if value > 0 {
                Stepper(
                    value: Binding(
                        get: { value },
                        set: {
                            value = $0
                            set($0)
                        }
                    ),
                    in: range,
                    step: step
                ) {
                    Text(value.formatted(.number.precision(.fractionLength(0...1))) + " %").monospacedDigit()
                }
                .fixedSize()
            }
        }
        .onChangeCompatibility(of: get()) { value = get() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in value = get() }
    }
}

// Renders one control kind, seeding its state from the live getter and
// writing through on change.
private struct ControlView: View {
    let control: SettingsRow.Control

    var body: some View {
        switch control {
        case .deferred(let build):
            ControlView(control: build())
        case .textList(let get, let set):
            TextListControl(get: get, set: set)
        case .toggle(let get, let set):
            ToggleControl(get: get, set: set)
        case .segmented(let options, let caution, let get, let set):
            SegmentedControl(options: options, caution: caution, get: get, set: set)
        case .menu(let options, let caution, let get, let set):
            MenuControl(options: options, caution: caution, get: get, set: set)
        case .slider(let lo, let hi, let unit, let get, let set):
            SliderControl(min: lo, max: hi, unit: unit, get: get, set: set)
        case .stepper(let lo, let hi, let step, let unit, let get, let set):
            StepperControl(
                min: lo,
                max: hi,
                step: step,
                unit: unit,
                get: get,
                set: set
            )
        case .textField(let placeholder, let get, let set):
            TextFieldControl(placeholder: placeholder, get: get, set: set)
        case .backgroundImage(let get, let set):
            BackgroundImageField(label: "Background Image", get: get, set: set)
        }
    }
}

private struct ToggleControl: View {
    let get: () -> Bool
    let set: (Bool) -> Void
    @State
    private var value: Bool

    // Seed from the live Settings getter at construction so the control
    // shows the current value on the first frame, with no onAppear race.
    init(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        self.get = get
        self.set = set
        _value = State(initialValue: get())
    }

    var body: some View {
        Toggle(
            "",
            isOn: Binding(
                get: { value },
                set: {
                    value = $0
                    set($0)
                }
            )
        )
        .labelsHidden()
        .toggleStyle(SettingsSwitchStyle())
        .onChangeCompatibility(of: get()) { value = get() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in value = get() }
    }
}

private struct SegmentedControl: View {
    let options: [String]
    // Asked about the chosen index, not about the row: what a term costs can
    // depend on which term it is, and only the control knows which one that is
    // right now. Optional so the rows that need no caution show none.
    let caution: ((Int) -> String?)?
    let get: () -> Int
    let set: (Int) -> Void
    @State
    private var value: Int

    init(
        options: [String],
        caution: ((Int) -> String?)? = nil,
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) {
        self.options = options
        self.caution = caution
        self.get = get
        self.set = set
        _value = State(initialValue: get())
    }

    var body: some View {
        // Trailing, so the picker keeps the right edge every other control in
        // the column is aligned to and the caution hangs under it.
        VStack(alignment: .trailing, spacing: 4) {
            Picker(
                "",
                selection: Binding(
                    get: { value },
                    set: {
                        value = $0
                        set($0)
                    }
                )
            ) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // Read off `value` rather than `get()`: the state is what the
            // picker is showing, so the caution appears on the same update as
            // the selection instead of after whatever the write settles into.
            if let caution, let text = caution(value) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .onChangeCompatibility(of: get()) { value = get() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in value = get() }
    }
}

// Popup (pull-down) menu — for index choices with too many options for a
// segmented control, e.g. the theme list.
struct MenuControl: View {
    let options: [String]
    let caution: ((Int) -> String?)?
    let get: () -> Int
    let set: (Int) -> Void
    @State
    private var value: Int

    init(options: [String], caution: ((Int) -> String?)? = nil, get: @escaping () -> Int, set: @escaping (Int) -> Void) {
        self.caution = caution
        self.options = options
        self.get = get
        self.set = set
        _value = State(initialValue: Self.clamp(get(), count: options.count))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            SettingsPopUpButton(
                options: options,
                selectedIndex: value,
                select: {
                    value = $0
                    set($0)
                }
            )
            .frame(maxWidth: 220, alignment: .trailing)
            .onAppear {
                value = liveValue
            }
            .onChangeCompatibility(of: options) { value = liveValue }
            .onChangeCompatibility(of: get()) { value = liveValue }
            .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in value = liveValue }
            if let message = caution?(value) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
    }

    private var liveValue: Int {
        Self.clamp(get(), count: options.count)
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        if index < 0 {
            return 0
        }
        if index >= count {
            return max(count - 1, 0)
        }
        return index
    }
}

private struct SliderControl: View {
    let range: ClosedRange<Double>
    let unit: String?
    let get: () -> Double
    let set: (Double) -> Void
    @State
    private var value: Double
    // A disabled row dims its whole control, as the pop-up does: SwiftUI's
    // slider keeps its knob at full strength when disabled, and a readout in
    // .secondary does not change at all, so the row would read as live.
    @Environment(\.isEnabled)
    private var isEnabled

    init(
        min: Double,
        max: Double,
        unit: String? = nil,
        get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) {
        self.range = min...max
        self.unit = unit
        self.get = get
        self.set = set
        _value = State(initialValue: Swift.min(Swift.max(get(), min), max))
    }

    private var label: String {
        if let unit {
            return "\(Int(value.rounded())) \(unit)"
        }
        return "\(Int((value * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { value },
                    set: {
                        value = $0
                        set($0)
                    }
                ),
                in: range
            )
            .frame(width: 160)
            .opacity(isEnabled ? 1 : 0.5)
            Text(label)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(width: 42, alignment: .trailing)
        }
        .onChangeCompatibility(of: get()) { value = min(range.upperBound, max(range.lowerBound, get())) }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in
            value = min(range.upperBound, max(range.lowerBound, get()))
        }
    }
}

// Numeric stepper whose readout is an editable field, with the unit beside it.
//
// The arrows move by the schema's step, which is as fine as the setting can be
// set — a quarter point for a font size. A value far from where the control
// stands is typed instead, in the spelling the configuration file uses: a
// decimal point, no unit. The readout is Core's, the one the palette's number
// editor shows, so one value reads the same in both.
private struct StepperControl: View {
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let get: () -> Double
    let set: (Double) -> Void
    @State
    private var value: Double
    @State
    private var text: String
    @FocusState
    private var isEditing: Bool

    init(
        min: Double,
        max: Double,
        step: Double,
        unit: String,
        get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) {
        self.range = min...max
        self.step = step
        self.unit = unit
        self.get = get
        self.set = set
        let initial = Swift.min(Swift.max(get(), min), max)
        _value = State(initialValue: initial)
        _text = State(initialValue: PaletteSettings.formatNumber(initial, step: step))
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($isEditing)
                .onSubmit { commit() }
                .onChangeCompatibility(of: isEditing) { if !isEditing { commit() } }
            if !unit.isEmpty {
                Text(unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Stepper(
                "",
                value: Binding(
                    get: { value },
                    set: { adopt($0) }
                ),
                in: range,
                step: step
            )
            .labelsHidden()
        }
        .onChangeCompatibility(of: get()) { synchronize() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in synchronize() }
    }

    /// Takes `next` as the control's value, writes it through, and restates the
    /// field in the canonical spelling.
    ///
    /// - Parameter next: The wanted value, clamped to the schema's bounds.
    private func adopt(_ next: Double) {
        let bounded = min(range.upperBound, max(range.lowerBound, next))
        value = bounded
        text = PaletteSettings.formatNumber(bounded, step: step)
        set(bounded)
    }

    /// Reads what the field holds. Text the grammar does not accept leaves the
    /// setting alone and the field falls back to the standing value, so a
    /// half-typed number cannot be committed by clicking away.
    private func commit() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(typed) else {
            text = PaletteSettings.formatNumber(value, step: step)
            return
        }
        let bounded = min(range.upperBound, max(range.lowerBound, parsed))
        guard bounded != value else {
            text = PaletteSettings.formatNumber(value, step: step)
            return
        }
        adopt(bounded)
    }

    /// Re-reads the live value. A field being typed into keeps its characters:
    /// a write from elsewhere must not replace what is under the caret.
    private func synchronize() {
        guard !isEditing else { return }
        value = min(range.upperBound, max(range.lowerBound, get()))
        text = PaletteSettings.formatNumber(value, step: step)
    }
}

// Free-text field committing on Return / focus loss.
struct TextFieldControl: View {
    @FocusState
    private var isFocused: Bool
    let placeholder: String
    let get: () -> String
    let set: (String) -> Void
    @State
    private var value: String
    @State
    private var lastCommitted: String

    init(
        placeholder: String,
        get: @escaping () -> String,
        set: @escaping (String) -> Void
    ) {
        self.placeholder = placeholder
        self.get = get
        self.set = set
        let initial = get()
        _value = State(initialValue: initial)
        _lastCommitted = State(initialValue: initial)
    }

    // Commit only when the value changed since the last commit, so a
    // Return-then-close doesn't round-trip the file twice.
    private func commit() {
        guard value != lastCommitted else { return }
        lastCommitted = value
        set(value)
        value = get()
        lastCommitted = value
    }

    private func synchronize() {
        guard value == lastCommitted else { return }
        value = get()
        lastCommitted = value
    }

    var body: some View {
        TextField(
            placeholder,
            text: Binding(
                get: { value },
                set: { value = $0 }
            )
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
        .focused($isFocused)
        .onChangeCompatibility(of: isFocused) { if !isFocused { commit() } }
        .onSubmit { commit() }
        .onDisappear { commit() }
        .onChangeCompatibility(of: get()) { synchronize() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in synchronize() }
    }
}

// Supplies the command palette's material, optionally pinned to the terminal theme.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    // nil → follow the system appearance; set to pin the material light/dark (Beam
    // pins it to the TERMINAL theme, which is independent of the system appearance).
    var appearanceName: NSAppearance.Name? = nil

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.appearance = appearanceName.flatMap(NSAppearance.init(named:))
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}

private struct TextListControl: View {
    let get: () -> String
    let set: (String) -> Void
    @State
    private var newName = ""
    @State
    private var names: [String]

    init(get: @escaping () -> String, set: @escaping (String) -> Void) {
        self.get = get
        self.set = set
        _names = State(initialValue: Self.split(get()))
    }

    private static func split(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func addName() {
        let additions = Self.split(newName)
        for name in additions where !names.contains(name) {
            names.append(name)
        }
        newName = ""
        set(names.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button {
                                names.remove(at: index)
                                set(names.joined(separator: ", "))
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove " + name)
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 160)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                TextField("Process name", text: $newName)
                    .onSubmit(addName)
                Button("Add", action: addName)
                    .disabled(Self.split(newName).isEmpty)
            }
        }
        .frame(width: 240, alignment: .trailing)
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in
            names = Self.split(get())
        }
    }
}
