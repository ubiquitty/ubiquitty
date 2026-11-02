// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UbiquittyKit

/// Keeps the native search field outside the sidebar's scrolling viewport.
struct SettingsSearchField: NSViewRepresentable {
    @Binding
    var text: String
    var placeholder = "Search"
    var identifier = "settings-search"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.controlSize = .large
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityLabel(identifier == "settings-search" ? "Search settings" : placeholder)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// The native pop-up menu behind every settings selector.
///
/// An explicit `NSPopUpButton`, so the control is the same class on every
/// release: a SwiftUI menu picker is bridged to one on some releases and drawn
/// by SwiftUI on others, and the settings window is an AppKit window whose
/// selectors are read, driven and styled as AppKit controls.
struct SettingsPopUpButton: NSViewRepresentable {
    let options: [String]
    let selectedIndex: Int
    let select: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelect(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        // Items are added one by one rather than by title list: the title
        // list API drops a repeated title, which would shift every index
        // after it away from the option it names.
        if button.itemArray.map(\.title) != options {
            button.removeAllItems()
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option, action: nil, keyEquivalent: "")
                item.tag = index
                button.menu?.addItem(item)
            }
        }
        if selectedIndex >= 0, selectedIndex < button.numberOfItems, button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
    }

    // The button hugs its widest title, as the bridged picker did; a proposal
    // narrower than that wins, so a long option list cannot widen a row.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsic = button.intrinsicContentSize
        let width = proposal.width.map { min($0, intrinsic.width) } ?? intrinsic.width
        return CGSize(width: width, height: intrinsic.height)
    }

    // The button's target: AppKit sends the action on the main actor, where
    // the button's selection lives, so the coordinator is isolated there too.
    @MainActor
    final class Coordinator: NSObject {
        var select: (Int) -> Void

        init(select: @escaping (Int) -> Void) { self.select = select }

        @objc
        func didSelect(_ button: NSPopUpButton) {
            select(button.indexOfSelectedItem)
        }
    }
}

/// Supplies the shared content surfaces and spacing for every settings page.
enum SettingsStyle {
    static let pageInset: CGFloat = 20
    static let rowInset: CGFloat = 10
    static let sectionSpacing: CGFloat = 24
    static let cornerRadius: CGFloat = 12
    static let contentWidth: CGFloat = 660
    static let groupBackground = Color(
        nsColor: NSColor(name: "settingsGroupBackground") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.16, alpha: 1)
                : NSColor(srgbRed: 247.0 / 255, green: 247.0 / 255, blue: 247.0 / 255, alpha: 1)
        }
    )
}

/// Uses the compact switch size of macOS settings rows without shrinking their labels.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 13))
    }
}

/// Groups related settings on an opaque content surface, below the navigation glass.
struct SettingsCardView<Content: View>: View {
    let title: String?
    let footer: String?
    let headerAccessory: AnyView?
    @ViewBuilder
    let content: () -> Content
    @Environment(\.colorSchemeContrast)
    private var contrast

    init(
        title: String? = nil,
        footer: String? = nil,
        headerAccessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.headerAccessory = headerAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || headerAccessory != nil {
                HStack {
                    if let title { Text(title).font(.headline).foregroundStyle(.primary) }
                    Spacer()
                    headerAccessory
                }
                .padding(.horizontal, SettingsStyle.rowInset)
            }
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity)
                .background(SettingsStyle.groupBackground)
                .clipShape(.rect(cornerRadius: SettingsStyle.cornerRadius))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: SettingsStyle.cornerRadius)
                            .strokeBorder(.primary.opacity(0.4), lineWidth: 1)
                    }
                }
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsStyle.rowInset)
            }
        }
    }
}

// Vertical stack of cards with the standard pane padding + max width, so a
// custom pane lays out identically to a data-driven one.
struct SettingsPaneStack<Content: View>: View {
    @ViewBuilder
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) { content() }
            .padding(SettingsStyle.pageInset)
            .frame(maxWidth: SettingsStyle.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .controlSize(.small)
            .font(.system(size: 13))
            .toggleStyle(SettingsSwitchStyle())
    }
}

// A hairline-divided row inside a SettingsCard.
struct SettingsListRow<Content: View>: View {
    let isFirst: Bool
    @ViewBuilder
    let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5)
                    .padding(.horizontal, SettingsStyle.rowInset)
            }
            content()
                .frame(minHeight: 20)
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 9)
        }
    }
}

/// Identifies a settings category with a colored system symbol tile.
struct SettingsCategoryIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.regular)
            .foregroundStyle(.white)
            .frame(width: size * 0.7, height: size * 0.7)
            .frame(width: size, height: size)
            .background(color.gradient, in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            .accessibilityHidden(true)
    }
}

/// Describes the selected category using the same grouped surface as its settings.
struct SettingsCategoryHeader: View {
    let category: SettingsCategory

    var body: some View {
        SettingsCardView {
            HStack(alignment: .top, spacing: 12) {
                SettingsCategoryIcon(symbol: category.symbol, color: category.color, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.headline)
                    Text(category.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .padding(.horizontal, SettingsStyle.pageInset)
        .padding(.bottom, 8)
        .frame(maxWidth: SettingsStyle.contentWidth)
        .frame(maxWidth: .infinity)
    }
}

// The application delegate's write-through surface. The custom panes funnel
// every write through `app`, exactly like the catalog.
@MainActor
enum SettingsBridge {
    static var app: UBAppDelegate? { NSApp.delegate as? UBAppDelegate }
    static let valuesChanged = Notification.Name("UBSettingsValuesChanged")
}

private struct SettingsRevealTargetKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsRevealTarget: String? {
        get { self[SettingsRevealTargetKey.self] }
        set { self[SettingsRevealTargetKey.self] = newValue }
    }
}

private struct SettingsSearchTarget: ViewModifier {
    let address: String
    @Environment(\.settingsRevealTarget)
    private var target

    func body(content: Content) -> some View {
        content
            .id(address)
            .accessibilityIdentifier("settings-row-" + address)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(target == address ? 0.22 : 0)))
            .animation(.easeInOut(duration: 0.4), value: target == address)
    }
}

extension View {
    @ViewBuilder
    func settingsSearchTarget(_ address: String?) -> some View {
        if let address { modifier(SettingsSearchTarget(address: address)) } else { self }
    }
}
