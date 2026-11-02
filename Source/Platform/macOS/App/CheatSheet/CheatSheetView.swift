// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// CheatSheetView.swift — the hold-⌘ overlay: a dimmed scrim with a centered
// two-column card (Menu shortcuts · Custom keys). App-level chrome, so it uses
// the system material + colors, not a terminal theme.
//

import SwiftUI

struct CheatSheetView: View {
    let menu: [CheatSheetEntry]
    let keys: [CheatSheetEntry]
    let onDismiss: () -> Void

    // Menu rows grouped by their top-level menu, in menu-bar order.
    private var menuGroups: [(group: String, entries: [CheatSheetEntry])] {
        var order: [String] = []
        var byGroup: [String: [CheatSheetEntry]] = [:]
        for entry in menu {
            if byGroup[entry.group] == nil { order.append(entry.group) }
            byGroup[entry.group, default: []].append(entry)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() } // click the scrim to close
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts")
                .font(.headline)
            HStack(alignment: .top, spacing: 32) {
                column(title: "Menu", groups: menuGroups)
                if !keys.isEmpty {
                    column(title: "Custom Keys", groups: [("", keys)])
                }
            }
            Text("Hold ⌘ · release to dismiss")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: 720, maxHeight: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(radius: 24, y: 8)
        .padding(40)
    }

    private func column(
        title: String,
        groups: [(group: String, entries: [CheatSheetEntry])]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if !group.group.isEmpty {
                            Text(group.group)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        ForEach(group.entries) { entry in
                            HStack(spacing: 10) {
                                Text(entry.shortcut)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minWidth: 64, alignment: .leading)
                                Text(entry.label)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
    }
}
