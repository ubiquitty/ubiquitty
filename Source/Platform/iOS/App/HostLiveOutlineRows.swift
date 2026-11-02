// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

import struct UbiquittyRenderKit.HostOutlineRow

// What a connected host holds, under its row on the Hosts screen: its
// workspaces, and within each its tabs and panes. Core supplies the outline
// and its words; each row gives the title a line above the program status.

/// A connected host's rows, as lines under its row in the host list.
///
/// Keeps the last received tree while the screen restarts its watch. The
/// next answer updates these rows in place, preserving their disclosure state.
struct HostLiveOutlineRows: View {
    /// The host, as the person named it, for what an assistive reader is told.
    let hostName: String
    /// The Hosts screen's reading of the host's tree.
    @Bindable
    var store: HostOutlineStore
    /// Whether the width has room to indent panes under their tabs.
    let isNestingPanes: Bool
    /// Opens a row: attaches to its workspace and shows its tab and pane.
    let open: (HostOutlineRow) -> Void

    var body: some View {
        ForEach(placedRows, id: \.row.key) { placed in
            HStack(alignment: .top, spacing: 4) {
                if placed.row.isExpandable {
                    Button {
                        store.toggle(placed.row)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(placed.row.isExpanded ? 90 : 0))
                            .frame(width: 20, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSearching)
                    .accessibilityLabel(placed.row.isExpanded ? "Collapse" : "Expand")
                    .accessibilityIdentifier("\(HostSessionsView.identifier(of: placed.row))-fold")
                }
                WorkspaceChildRow(row: placed.row, indent: 0)
            }
            .padding(.leading, CGFloat(min(placed.row.depth, isNestingPanes ? 2 : 1)) * 6)
            .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 12))
            .contentShape(Rectangle())
            .onTapGesture { open(placed.row) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: spokenWords(for: placed)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(placed.row) }
            .accessibilityAction(named: Text("Open")) { open(placed.row) }
            .accessibilityIdentifier("hosts-\(HostSessionsView.identifier(of: placed.row))")
        }
    }

    /// A row and the workspace it is under.
    private struct PlacedRow {
        let row: HostOutlineRow
        /// The title of the workspace row above it; empty on a workspace's
        /// own row.
        let workspaceTitle: String
    }

    /// Core's rows, each with the workspace it is under.
    private var placedRows: [PlacedRow] {
        var workspaceTitle = ""
        return store.rows.map { row in
            if row.level == .workspace {
                workspaceTitle = row.title
                return PlacedRow(row: row, workspaceTitle: "")
            }
            return PlacedRow(row: row, workspaceTitle: workspaceTitle)
        }
    }

    /// What VoiceOver reads for a row: what it is, Core's words for it, the
    /// workspace it is in and the host it is on.
    private func spokenWords(for placed: PlacedRow) -> String {
        let row = placed.row
        var words = [Self.kind(of: row), HostOutlineRowView<EmptyView>.spokenWords(for: row)]
        if !placed.workspaceTitle.isEmpty { words.append("in \(placed.workspaceTitle)") }
        words.append("on \(hostName)")
        return words.joined(separator: ", ")
    }

    /// What a row stands for, by the most a person can open from it: a row
    /// that folds a single pane is that pane.
    private static func kind(of row: HostOutlineRow) -> String {
        if row.level == .workspace { return "Workspace" }
        if row.isPaneRow { return "Pane" }
        if row.isTabRow { return "Tab" }
        return "Window"
    }
}
