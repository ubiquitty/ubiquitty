// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Named overrides share the configuration reader’s range parser and writer.
struct FallbackFontsView: View {
    let settings: AppSettingsModel
    @State
    private var editor: Editor?

    private struct Editor: Identifiable {
        let id = UUID()
        var range: AppSettingsModel.FallbackRange?
    }

    var body: some View {
        Group {
            if settings.fallbackRanges.isEmpty {
                ContentUnavailableView(
                    "No Font Ranges",
                    systemImage: "textformat",
                    description: Text("Add a range to choose its fallback font.")
                )
            } else {
                List {
                    Section {
                        ForEach(settings.fallbackRanges) { range in
                            Button {
                                editor = Editor(range: range)
                            } label: {
                                LabeledContent {
                                    Text(range.family).foregroundStyle(.secondary)
                                } label: {
                                    Text(range.range).font(.body.monospaced()).foregroundStyle(.primary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ranges = settings.fallbackRanges
                            for offset in offsets { settings.remove(ranges[offset]) }
                        }
                    } footer: {
                        Text("Choose a font and size policy for specific Unicode characters. Other characters keep their existing fonts.")
                    }
                }
            }
        }
        .navigationTitle("Fallback Ranges")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Range", systemImage: "plus") { editor = Editor() }
            }
        }
        .sheet(item: $editor) { entry in
            FallbackRangeEditor(settings: settings, original: entry.range)
        }
    }
}

private struct FallbackRangeEditor: View {
    let settings: AppSettingsModel
    let original: AppSettingsModel.FallbackRange?
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var range: String
    @State
    private var family: String
    @State
    private var shouldMatchSize: Bool?
    @State
    private var isChoosingFont = false
    @State
    private var error = ""
    @State
    private var isConfirmingDiscard = false

    init(settings: AppSettingsModel, original: AppSettingsModel.FallbackRange?) {
        self.settings = settings
        self.original = original
        _range = State(initialValue: original?.range ?? "")
        _family = State(initialValue: original?.family ?? "")
        _shouldMatchSize = State(initialValue: original?.shouldMatchSize)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("U+2400-U+243F", text: $range)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .accessibilityLabel("Unicode Range")
                        .accessibilityIdentifier("fallback-range")
                } header: {
                    Text("Characters")
                } footer: {
                    Text("Enter one code point, such as U+2426, or a range.")
                }
                Section {
                    Button {
                        isChoosingFont = true
                    } label: {
                        LabeledContent("Font", value: family.isEmpty ? "Choose Font" : family)
                    }
                    Picker("Size", selection: $shouldMatchSize) {
                        Text("Use Default").tag(Bool?.none)
                        Text("Match Primary Font").tag(Bool?.some(true))
                        Text("Original Size").tag(Bool?.some(false))
                    }
                } footer: {
                    Text(
                        "Saving replaces overlapping overrides only for these characters."
                    )
                }
                if !error.isEmpty { Section { ErrorMessage(error) } }
            }
            .navigationTitle(original == nil ? "New Font Range" : "Font Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetToolbar(
                    confirm: save,
                    cancel: {
                        if hasUnsavedEdits { isConfirmingDiscard = true } else { dismiss() }
                    }
                )
            }
            .navigationDestination(isPresented: $isChoosingFont) {
                TerminalFontPicker(selectedFont: family, onSelect: { family = $0 }, isPresented: $isChoosingFont, isMonospacedOnly: false)
                    .navigationTitle("Font")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheetChrome()
        .presentationDetents([.large])
        .guardingUnsavedEdits(hasUnsavedEdits, discard: { dismiss() })
        .confirmationDialog("Discard Changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
        }
    }

    private var hasUnsavedEdits: Bool {
        range != (original?.range ?? "") || family != (original?.family ?? "") || shouldMatchSize != original?.shouldMatchSize
    }

    private func save() {
        guard settings.saveRange(range, family: family, shouldMatchSize: shouldMatchSize, replacing: original) else {
            error = family.isEmpty ? "Choose a font." : "Enter a Unicode code point or an ascending range from U+0000 to U+10FFFF."
            return
        }
        dismiss()
    }
}
