// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct PasteEntry: Identifiable {
    let id: String
    let kind: Int
    let index: Int
    let label: String
    let preview: String
}

/// Holds the panel's transient query and selection over Core-provided entries.
@MainActor
final class PasteBuffersModel: ObservableObject {
    @Published
    var entries: [PasteEntry] = []
    @Published
    var selection: String?
    @Published
    var query = ""

    var matches: [PasteEntry] {
        entries.filter { query.isEmpty || $0.preview.localizedStandardContains(query) || $0.label.localizedStandardContains(query) }
    }
}

/// Selects stored text for a user-initiated paste into the captured terminal.
struct PasteBuffersView: View {
    private var app: UBAppDelegate? { NSApp.delegate as? UBAppDelegate }
    @ObservedObject
    var model: PasteBuffersModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                rows(kind: 0, title: "Buffers")
                rows(kind: 1, title: "Recent copies")
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.matches.isEmpty {
                    ContentUnavailableView {
                        Label(model.entries.isEmpty ? "No copied text" : "No matching buffers", systemImage: "doc.on.clipboard")
                    } description: {
                        Text(model.entries.isEmpty ? "Copy text in a terminal to keep it here." : "Try another word or buffer name.")
                    }
                }
            }
            HStack(spacing: 12) {
                Text("\(model.matches.count) \(model.matches.count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button("Paste") {
                    if let entry = model.matches.first(where: { $0.id == model.selection }) { paste(entry) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!model.matches.contains(where: { $0.id == model.selection }))
            }
            .controlSize(.large)
            .padding(16)
            .background(.bar)
        }
        .frame(minWidth: 360, minHeight: 300)
        .onAppear(perform: reload)
        .onChange(of: model.query) { _, _ in reconcileSelection() }
    }

    @ViewBuilder
    private func rows(kind: Int, title: String) -> some View {
        let group = model.matches.filter { $0.kind == kind }
        if !group.isEmpty {
            Section(title) {
                ForEach(group) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: kind == 1 ? "clock.arrow.circlepath" : "doc.on.clipboard")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.preview.isEmpty ? "Empty text" : entry.preview)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 7)
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { paste(entry) }
                }
            }
        }
    }

    private func reconcileSelection() {
        if !model.matches.contains(where: { $0.id == model.selection }) { model.selection = model.matches.first?.id }
    }

    private func reload() {
        model.entries = (app?.pasteBufferEntries() ?? [])
            .map {
                let kind = ($0["kind"] as? NSNumber)?.intValue ?? 0
                let index = ($0["index"] as? NSNumber)?.intValue ?? 0
                return PasteEntry(
                    id: "\(kind):\(index)",
                    kind: kind,
                    index: index,
                    label: $0["label"] as? String ?? "",
                    preview: $0["preview"] as? String ?? ""
                )
            }
        reconcileSelection()
    }

    private func paste(_ entry: PasteEntry) {
        app?.pasteBufferEntry(ofKind: entry.kind, index: entry.index)
        close()
    }

    private func close() { app?.closePasteBuffersPanel() }
}
