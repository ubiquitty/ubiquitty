// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittyCore

/// The system's searchable monospaced font and face picker, pushed inside
/// the settings sheet's own navigation stack.
///
/// Pushed, not presented: a sheet asked for from inside the settings sheet
/// collapsed the settings sheet instead of standing over it, and the person
/// was left on the terminal with no picker. A pushed picker needs no second
/// presentation, and a pick pops it to the settings it came from.
struct TerminalFontPicker: UIViewControllerRepresentable {
    let selectedFont: String
    let onSelect: (String) -> Void
    /// Whether the picker is on the stack; a pick or a cancel clears it,
    /// which pops. The stack's own flag rather than an environment `dismiss`,
    /// which read from inside a representable resolves to whatever encloses
    /// it rather than to the picker.
    @Binding
    var isPresented: Bool
    var isMonospacedOnly = true

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = true
        if isMonospacedOnly { configuration.filteredTraits = .traitMonoSpace }
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        picker.selectedFontDescriptor = UIFont(name: selectedFont, size: 13)?.fontDescriptor
        return picker
    }

    func updateUIViewController(_ controller: UIFontPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        private let picker: TerminalFontPicker

        init(_ picker: TerminalFontPicker) { self.picker = picker }

        func fontPickerViewControllerDidPickFont(_ controller: UIFontPickerViewController) {
            if let descriptor = controller.selectedFontDescriptor {
                picker.onSelect(descriptor.postscriptName)
            }
            picker.isPresented = false
        }

        func fontPickerViewControllerDidCancel(_ controller: UIFontPickerViewController) {
            picker.isPresented = false
        }
    }
}

/// The settings rows for the font. The picker it opens is a navigation
/// destination the settings form declares, since a destination declared
/// inside a form's lazy rows is not one the stack can reach.
struct TerminalFontSection: View {
    let settings: AppSettingsModel
    @Binding
    var isChoosingFont: Bool

    /// The sizes the stepper offers: Core's zoom range, so a stepped size is
    /// one the renderer draws.
    static var sizeRange: ClosedRange<Double> {
        let range = Ubiquitty.Preferences.Zoom.fontZoomRange().pointee
        return range.minimum...range.maximum
    }

    var body: some View {
        Section {
            Button {
                isChoosingFont = true
            } label: {
                LabeledContent("Font", value: settings.fontFamily)
            }
            .accessibilityIdentifier("terminal-font-picker")
            Stepper(
                value: Binding(get: { settings.fontPointSize }, set: { settings.selectFont(pointSize: $0) }),
                in: Self.sizeRange
            ) {
                LabeledContent("Default Size", value: "\(settings.fontPointSize.formatted()) pt")
            }
            .accessibilityIdentifier("terminal-font-size")
            Stepper(value: settings.number(.FontLineSpacing), in: 0...16, step: 0.25) {
                LabeledContent("Line Spacing", value: "\(settings.value(.FontLineSpacing).number.formatted()) pt")
            }
            .accessibilityHint("Extra space added to each line’s natural height.")
            .accessibilityIdentifier("terminal-line-spacing")
            Text("Aa Bb 0123456789\nIl1 O0 {} [] () -> !=")
                .font(.custom(settings.fontFamily, fixedSize: settings.fontPointSize))
                .lineSpacing(settings.value(.FontLineSpacing).number)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .accessibilityLabel("Font preview")
            if settings.hasCustomFont {
                Button("Reset Font") { settings.resetFont() }
                    .accessibilityIdentifier("terminal-font-reset")
            }
        } header: {
            Text("Font")
        } footer: {
            Text("Applies to all connections on this device. Pinch to zoom an individual pane.")
        }
        Section {
            Toggle(
                "Match Fallback Font Size",
                isOn: Binding(get: { settings.shouldMatchFallbackSize }, set: { settings.setFallbackSizeMatching($0) })
            )
            .accessibilityIdentifier("terminal-match-fallback-size")
            NavigationLink("Fallback Ranges") { FallbackFontsView(settings: settings) }
        } header: {
            Text("Fallback Fonts")
        } footer: {
            Text("Match fallback text to the primary font’s visible size. Each configured range can use its own choice.")
        }
    }
}
