// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TagsPane.swift — the in-window [[tags]] manager. A tag is a named, coloured
// marker a window wears so what it is connected to is legible before the title
// is read: a red "production" against a host whose name says so.
//
// A rule matches on the host, the profile, or both. An entry that constrains
// neither marks nothing by rule — it declares a colour for a tag applied by
// hand or by the session — and this pane says so rather than letting the rule
// look broken.
//
// Reads + writes funnel through the application delegate: a tag crosses as a
// dictionary keyed by the tag's field names, and settings stays the single
// source of truth.
//
// The list is in file order, which is the order every window draws the tags
// its rules give it. A rule is dragged onto another to take its place, or moved
// one place with Move Up and Move Down from its context menu or its
// accessibility actions; each move writes the new order back to the file.
//

import AppKit
import CoreTransferable
import SwiftUI
import UbiquittyCore
import UbiquittyKit
import UniformTypeIdentifiers

private struct Tag: Identifiable {
    var id = UUID()
    /// The rule's position among the `[[tags]]` blocks, which is how a save
    /// or a delete addresses it; -1 for a rule not yet saved. A position
    /// rather than a name, because the title is optional.
    var index: Int
    var name: String
    var color: String
    var matchHost: String
    var matchProfile: String
    var isLoud: Bool
    /// The Phosphor icon drawn in the dot's place, empty for none.
    var icon: String
    /// The icon's weight as the config spells it; empty is the default fill.
    var iconWeight: String
    /// Whether the marker draws the title beside its icon, or as its capsule.
    var showsName: Bool
    /// Whether the window's title bar draws the tag.
    var showsInTitleBar: Bool
    /// Whether the window's tab draws the tag.
    var showsInTabs: Bool
    /// Whether a pane's header draws the tag.
    var showsInPaneHeaders: Bool

    init(dict: [String: Any]) {
        index = dict["index"] as? Int ?? -1
        name = dict["name"] as? String ?? ""
        color = dict["color"] as? String ?? ""
        matchHost = dict["matchHost"] as? String ?? ""
        matchProfile = dict["matchProfile"] as? String ?? ""
        isLoud = (dict["prominence"] as? String ?? "").lowercased() == "loud"
        icon = dict["icon"] as? String ?? ""
        iconWeight = dict["iconWeight"] as? String ?? ""
        showsName = dict["showName"] as? Bool ?? true
        showsInTitleBar = dict["showInTitleBar"] as? Bool ?? true
        showsInTabs = dict["showInTabs"] as? Bool ?? true
        showsInPaneHeaders = dict["showInPaneHeaders"] as? Bool ?? true
    }

    init() {
        index = -1
        name = ""
        color = "red"
        matchHost = ""
        matchProfile = ""
        isLoud = false
        icon = ""
        iconWeight = ""
        showsName = true
        showsInTitleBar = true
        showsInTabs = true
        showsInPaneHeaders = true
    }

    /// Whether the rule has no title and is drawn as a dot.
    var isUntitled: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Whether the icon is drawn in its regular weight rather than the default
    /// fill, by Core's reading of the spelling.
    var isIconRegular: Bool {
        get { PhosphorIcons.weight(spelled: iconWeight) == .Regular }
        set { iconWeight = newValue ? PhosphorIcons.spelling(of: .Regular) : "" }
    }

    /// The colour the rule's marker is drawn in, nil when the value names none.
    var markerColor: NSColor? { TagColorValue.color(of: color) }

    func dictionary() -> [String: Any] {
        [
            "name": name, "color": color, "matchHost": matchHost,
            "matchProfile": matchProfile, "prominence": isLoud ? "loud" : "",
            "icon": icon, "iconWeight": iconWeight, "showName": showsName,
            "showInTitleBar": showsInTitleBar, "showInTabs": showsInTabs,
            "showInPaneHeaders": showsInPaneHeaders,
        ]
    }
}

/// A rule being dragged to another place in the list: the rule's position,
/// and the list it was picked up from, so a drop from another pane, or from
/// the same pane before the list was read again, is refused.
private struct TagRuleReorderItem: Codable, Transferable {
    let scope: UUID
    let index: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "org.ubiquitty.tag-rule-reorder"))
            .visibility(.ownProcess)
    }
}

// The palette and swatch resolution live in TagPalette, read from Core's one
// table; a config may also carry a #rrggbb literal, which the editor keeps as
// typed.
@MainActor
private func swatch(for name: String) -> Color? {
    TagPalette.swatch(for: name)
}

// What a rule matches, said in words. An entry constraining neither host nor
// profile marks nothing; the row says that outright, so it is not read as a
// pattern that failed to fire.
private func matchSummary(_ tag: Tag) -> String {
    let host = tag.matchHost.trimmingCharacters(in: .whitespaces)
    let profile = tag.matchProfile.trimmingCharacters(in: .whitespaces)
    switch (host.isEmpty, profile.isEmpty) {
    case (false, false):
        return "hosts matching \(host), on profile \(profile)"
    case (false, true):
        return "hosts matching \(host)"
    case (true, false):
        return "profile \(profile)"
    case (true, true):
        return "no rule — applied by hand or by the session"
    }
}

struct TagsPane: View {
    @State
    private var tags: [Tag] = []
    @State
    private var session = EditSession<Tag>()
    /// The list a drag was picked up from, renewed each time the rules are
    /// read, so a drop carries a position in the list on screen.
    @State
    private var reorderScope = UUID()
    /// The rule a dragged one would take the place of, while it hovers there.
    @State
    private var dropTargetIndex: Int?

    #if UBIQUITTY_UI_TESTS
    /// Saves the rule editor on screen as its Save button does; nil while no
    /// editor is up.
    ///
    /// SwiftUI draws the sheet's buttons rather than installing controls, so a
    /// scenario has no view to press. This is that press, through the same
    /// commit and dismissal.
    @MainActor
    static var saveEditorForTesting: (() -> Void)?
    #endif

    var body: some View {
        SettingsListPane(
            title: "Tags",
            footer:
                "A tag marks a window with a colored dot or icon before its title, so you can tell what it’s connected to before you read the title. A rule marks every matching window on its own, which makes it dependable for something like production. Windows show their tags in the order listed here; drag a tag to move it.",
            emptyText: "No tags.",
            addLabel: "New Tag",
            items: tags,
            onAdd: { session.new(Tag()) },
            reload: reload,
            addSearchID: "tags.new",
            // How strongly every tag below is drawn, before the tags themselves.
            leadingCards: [SettingsCatalog.tagStrengthCard()]
        ) { tag in
            row(tag)
        }
        .sheet(item: $session.editing) { tag in
            TagEditorSheet(
                tag: tag,
                isNew: session.isNew,
                onCommit: { commit($0) },
                onCancel: {}
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: TagRulePrefill.pendingChanged)) { _ in
            // A rule jump can arrive after the config changed while this pane
            // stayed alive. Resolve its position against the current rules.
            reload()
        }
    }

    @ViewBuilder
    private func row(_ tag: Tag) -> some View {
        let canMoveUp = tag.index > 0
        let canMoveDown = tag.index >= 0 && tag.index < tags.count - 1
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            marker(tag)
            VStack(alignment: .leading, spacing: 2) {
                // An untitled rule is a dot in the title bar; the list says so
                // rather than showing an empty line.
                if tag.isUntitled {
                    Text("Untitled").foregroundStyle(.secondary)
                } else {
                    Text(tag.name)
                }
                Text(matchSummary(tag)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Edit") { session.edit(tag) }
            Button(role: .destructive) {
                remove(tag)
            } label: {
                Image(systemName: "trash")
            }
        }
        .contentShape(Rectangle())
        .overlay {
            if dropTargetIndex == tag.index {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
            }
        }
        // A rule dropped on another takes its place, the rules between
        // shifting one place toward where it came from.
        .draggable(TagRuleReorderItem(scope: reorderScope, index: tag.index))
        .dropDestination(for: TagRuleReorderItem.self, isEnabled: tags.count > 1) { items, _ in
            dropTargetIndex = nil
            guard items.count == 1, let item = items.first, item.scope == reorderScope else { return }
            move(from: item.index, to: tag.index)
        }
        .onDropSessionUpdated { drop in
            switch drop.phase {
            case .entering, .active:
                dropTargetIndex = tag.index
            case .exiting, .ended, .dataTransferCompleted:
                if dropTargetIndex == tag.index {
                    dropTargetIndex = nil
                }
            @unknown default:
                dropTargetIndex = nil
            }
        }
        .contextMenu {
            Button("Move Up") { move(from: tag.index, to: tag.index - 1) }
                .disabled(!canMoveUp)
            Button("Move Down") { move(from: tag.index, to: tag.index + 1) }
                .disabled(!canMoveDown)
        }
        .accessibilityAction(named: "Move Up") {
            if canMoveUp { move(from: tag.index, to: tag.index - 1) }
        }
        .accessibilityAction(named: "Move Down") {
            if canMoveDown { move(from: tag.index, to: tag.index + 1) }
        }
    }

    /// The rule's marker as the list shows it: its icon in its colour, or the
    /// colour's dot when it has no icon the catalog carries, which is what the
    /// title row draws in that case too.
    @ViewBuilder
    private func marker(_ tag: Tag) -> some View {
        if let icon = PhosphorIcons.cachedImage(
            named: tag.icon,
            weight: PhosphorIcons.weight(spelled: tag.iconWeight),
            side: 14,
            color: tag.markerColor ?? .secondaryLabelColor
        ) {
            Image(nsImage: icon)
                .frame(width: 14, height: 14)
                .accessibilityLabel(PhosphorIcons.spokenName(of: tag.icon))
        } else {
            Circle()
                .fill(swatch(for: tag.color) ?? Color.clear)
                .overlay(Circle().stroke(Color.secondary.opacity(swatch(for: tag.color) == nil ? 1 : 0)))
                .frame(width: 10, height: 10)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: data

    private func reload() {
        let raw = SettingsBridge.app?.settingsTags() ?? []
        tags = raw.map { Tag(dict: $0) }
        reorderScope = UUID()
        dropTargetIndex = nil
        consumeRulePrefill()
    }

    /// Moves the rule at one position to another and reads the list again,
    /// in the order the file now holds.
    private func move(from: Int, to: Int) {
        guard from != to, tags.indices.contains(from), tags.indices.contains(to) else { return }
        SettingsBridge.app?.settingsMoveTag(from: from, to: to)
        reload()
    }

    // A "Rules…" jump from a window's title popover arrives with the rule the
    // window matched, which opens that rule's editor, or with the window's
    // host, which opens the new-rule editor with the host pattern prefilled,
    // so the rule the user came to write is already aimed.
    private func consumeRulePrefill() {
        // A window that a rule matched jumps to that rule.
        if let index = TagRulePrefill.takePendingRuleIndex() {
            if let tag = tags.first(where: { $0.index == index }) {
                session.edit(tag)
            }
            return
        }
        guard let host = TagRulePrefill.takePendingHost() else { return }
        var tag = Tag()
        tag.matchHost = host
        session.new(tag)
    }

    private func remove(_ tag: Tag) {
        SettingsBridge.app?.settingsDeleteTag(at: tag.index)
        reload()
    }

    private func commit(_ tag: Tag) {
        SettingsBridge.app?.settingsSaveTag(tag.dictionary(), at: tag.index)
        reload()
    }
}

private struct TagEditorSheet: View {
    @State
    var tag: Tag
    let isNew: Bool
    let onCommit: (Tag) -> Void
    let onCancel: () -> Void

    #if UBIQUITTY_UI_TESTS
    @Environment(\.dismiss)
    private var dismissForTesting
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Tag" : "Edit Tag").font(.headline)

            HStack {
                Text("Title").frame(width: 90, alignment: .leading)
                TextField("Optional", text: $tag.name)
                    .textFieldStyle(.roundedBorder).frame(width: 280)
                    .accessibilityIdentifier("tagEditor.title")
            }

            HStack(alignment: .top) {
                Text("Color").frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(TagPalette.entries, id: \.name) { named in
                            Button {
                                tag.color = named.name
                            } label: {
                                Circle()
                                    .fill(named.color)
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                Color.accentColor,
                                                lineWidth: tag.color.lowercased() == named.name ? 2 : 0
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(named.name)
                        }
                        TagCustomColorField(color: $tag.color)
                            .frame(width: 18, height: 18)
                    }
                    TextField("red, or #rrggbb", text: $tag.color)
                        .textFieldStyle(.roundedBorder).frame(width: 280)
                }
            }

            HStack {
                Text("Icon").frame(width: 90, alignment: .leading)
                TagIconControls(icon: $tag.icon, isRegular: $tag.isIconRegular, tint: tag.markerColor)
                    .frame(width: 280, alignment: .leading)
            }

            // How the marker is drawn and where. Without the name, a titled
            // rule draws its icon alone, or its colour's dot without one; an
            // untitled rule has no name to show either way. The host outline
            // shows every tag whatever the places say.
            HStack(alignment: .top) {
                Text("Display").frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    TagEditorCheckbox(
                        title: "Show name",
                        identifier: "tagEditor.showName",
                        isOn: $tag.showsName,
                        isEnabled: !tag.isUntitled
                    )
                    TagEditorCheckbox(title: "Show in title bar", identifier: "tagEditor.showInTitleBar", isOn: $tag.showsInTitleBar)
                    TagEditorCheckbox(title: "Show in tabs", identifier: "tagEditor.showInTabs", isOn: $tag.showsInTabs)
                    TagEditorCheckbox(
                        title: "Show in pane headers",
                        identifier: "tagEditor.showInPaneHeaders",
                        isOn: $tag.showsInPaneHeaders
                    )
                    Text("VoiceOver and tooltips still use a hidden name.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Text("Hosts").frame(width: 90, alignment: .leading)
                TextField("prod-*, staging-*", text: $tag.matchHost)
                    .textFieldStyle(.roundedBorder).frame(width: 280)
            }

            // A rule matching a host is only as good as the terminal's knowledge
            // of which host it is on, and that knowledge has a floor a reader
            // cannot see from here: a nested ssh leaves one ssh process on this
            // machine, so the second hop is invisible until the far shell says
            // its own name. Saying so beside the field is what stops a rule that
            // never fires from reading as a broken rule.
            HStack(alignment: .top) {
                Spacer().frame(width: 90)
                Text(
                    "Matches the machine a session is on: one Ubiquitty connected to, "
                        + "or one reached by typing ssh, mosh, docker exec, and the like. "
                        + "For a host behind a second SSH hop, install the shell integration "
                        + "there: copy zsh.sh or bash.sh from the integration folder and "
                        + "source it from the remote shell’s startup file. It reports the "
                        + "host itself, which is the only way a hop past the first can be "
                        + "seen."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
            }

            HStack {
                Text("Profile").frame(width: 90, alignment: .leading)
                TextField("any", text: $tag.matchProfile)
                    .textFieldStyle(.roundedBorder).frame(width: 280)
            }

            HStack(alignment: .top) {
                Text("Prominence").frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $tag.isLoud) {
                        Text("Quiet").tag(false)
                        Text("Loud").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    Text("Loud also tints the whole title bar — the signal worth reserving for something like production.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(explanation)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            ModalButtons(
                saveDisabled: !(SettingsBridge.app?.settingsIsValidTag(tag.dictionary()) ?? false),
                onCancel: onCancel,
                onSave: { onCommit(tag) }
            )
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            #if UBIQUITTY_UI_TESTS
            TagsPane.saveEditorForTesting = {
                onCommit(tag)
                dismissForTesting()
            }
            #endif
        }
        .onDisappear {
            #if UBIQUITTY_UI_TESTS
            TagsPane.saveEditorForTesting = nil
            #endif
        }
    }

    private var explanation: String {
        let host = tag.matchHost.trimmingCharacters(in: .whitespaces)
        let profile = tag.matchProfile.trimmingCharacters(in: .whitespaces)
        if host.isEmpty, profile.isEmpty {
            if tag.isUntitled {
                return
                    "A tag without a title needs a host or profile pattern. Set one to have it mark matching windows with a colored dot, or add a title to apply it by hand."
            }
            return
                "With neither field set, this tag marks no window on its own; it only gives the name a color, to be applied by hand or by the session. Set a host or profile pattern to have it mark matching windows automatically."
        }
        if tag.isUntitled {
            return "Without a title, matching windows show a colored dot. "
                + markingSentence(host: host, profile: profile)
        }
        if !tag.showsName {
            let mark = tag.icon.isEmpty ? "a colored dot" : "the icon"
            return "With the name hidden, matching windows show \(mark) without the title. "
                + markingSentence(host: host, profile: profile)
        }
        return markingSentence(host: host, profile: profile)
    }

    private func markingSentence(host: String, profile: String) -> String {
        var parts: [String] = []
        if !host.isEmpty {
            parts.append("the host matches \(host)")
        }
        if !profile.isEmpty {
            parts.append("the profile is \(profile)")
        }
        let joined = parts.joined(separator: " and ")
        return "Marks a window when \(joined). Patterns use * for any run of characters and ignore case."
    }
}

/// The rule editor's icon row: the icon picker, and the weight it is drawn in.
///
/// AppKit rather than SwiftUI, because the picker's grid is a collection view
/// that builds only the cells on screen. The weight is offered only once there
/// is an icon to draw in it.
private struct TagIconControls: NSViewRepresentable {
    @Binding
    var icon: String
    @Binding
    var isRegular: Bool
    let tint: NSColor?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSStackView {
        let picker = TagIconPicker()
        picker.setAccessibilityIdentifier("tagEditor.icon")
        let weight = NSSegmentedControl(
            labels: ["Fill", "Regular"],
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.weightChanged(_:))
        )
        weight.setAccessibilityLabel("Icon weight")
        weight.setAccessibilityIdentifier("tagEditor.iconWeight")
        context.coordinator.picker = picker
        context.coordinator.weight = weight
        // The picker takes the row's slack, so a long icon name widens the
        // button rather than pushing the weight out of the row.
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        weight.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [picker, weight])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        return row
    }

    func updateNSView(_ row: NSStackView, context: Context) {
        let coordinator = context.coordinator
        let icon = $icon
        let isRegular = $isRegular
        coordinator.picker?.onPick = { icon.wrappedValue = $0 }
        coordinator.onWeightChange = { isRegular.wrappedValue = $0 }
        coordinator.picker?.iconName = self.icon
        coordinator.picker?.iconWeight = self.isRegular ? .Regular : .Fill
        coordinator.picker?.tint = tint
        coordinator.weight?.selectedSegment = self.isRegular ? 1 : 0
        coordinator.weight?.isEnabled = !self.icon.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView row: NSStackView, context: Context) -> CGSize? {
        let fitting = row.fittingSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    /// The segmented control's target, and the controls the update reaches.
    @MainActor
    final class Coordinator: NSObject {
        weak var picker: TagIconPicker?
        weak var weight: NSSegmentedControl?
        var onWeightChange: ((Bool) -> Void)?

        @objc
        func weightChanged(_ sender: NSSegmentedControl) {
            onWeightChange?(sender.selectedSegment == 1)
        }
    }
}

/// One of the rule editor's check boxes, as an AppKit button.
///
/// AppKit rather than SwiftUI for the reason the icon row is: SwiftUI draws a
/// sheet's controls rather than installing them, and a check box that is a
/// button in the window is the one VoiceOver and a scenario both press.
private struct TagEditorCheckbox: NSViewRepresentable {
    let title: String
    let identifier: String
    @Binding
    var isOn: Bool
    var isEnabled = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.toggled(_:)))
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let isOn = $isOn
        context.coordinator.onToggle = { isOn.wrappedValue = $0 }
        button.title = title
        button.state = self.isOn ? .on : .off
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton, context: Context) -> CGSize? {
        button.intrinsicContentSize
    }

    /// The button's target, and the binding a press writes.
    @MainActor
    final class Coordinator: NSObject {
        var onToggle: ((Bool) -> Void)?

        @objc
        func toggled(_ sender: NSButton) {
            onToggle?(sender.state == .on)
        }
    }
}

/// The custom swatch after the palette's seven, writing what the colour panel
/// chooses as a `#rrggbb` value. A rule whose colour is already such a literal
/// shows it here, selected.
private struct TagCustomColorField: NSViewRepresentable {
    @Binding
    var color: String

    func makeNSView(context: Context) -> TagCustomColorSwatch {
        let swatch = TagCustomColorSwatch(look: .disc)
        swatch.setAccessibilityIdentifier("tagEditor.customColor")
        return swatch
    }

    func updateNSView(_ swatch: TagCustomColorSwatch, context: Context) {
        let color = $color
        swatch.onPick = { color.wrappedValue = $0 }
        let isCustom = TagColorValue.isCustom(self.color)
        swatch.isChosen = isCustom
        // A palette colour leaves the last custom colour on the swatch, so
        // a press brings it back.
        if isCustom {
            swatch.color = TagColorValue.color(of: self.color)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView swatch: TagCustomColorSwatch, context: Context) -> CGSize? {
        swatch.intrinsicContentSize
    }
}
