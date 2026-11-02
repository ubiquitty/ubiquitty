// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

import struct UbiquittyRenderKit.HostOutlineIdentity
import struct UbiquittyRenderKit.HostOutlineRow
import enum UbiquittyRenderKit.HostOutlineStatus
import enum UbiquittyRenderKit.HostOutlineWorkspaceState
import enum UbiquittyRenderKit.HostWords

// The rows of a host's workspace list on a phone and a tablet: a workspace on
// two lines, its tabs on one line each, and the panes that need the person.
// Core supplies each row’s identity, program content, status and attendance.
// This view chooses their native presentation and human-readable status labels.

/// One workspace and the rows Core lists under it.
struct WorkspaceGroup: Identifiable {
    /// The workspace's own row: closed, it carries what it hides.
    let row: HostOutlineRow
    /// The rows under it, in Core's order; none while it is closed.
    let children: [HostOutlineRow]

    var id: HostOutlineRowKey { row.key }

    /// Whether nothing runs in it and opening it restores it.
    var isSaved: Bool { row.workspaceState == .restorable }

    /// How many tabs it holds: what its closed row hides, or the tab rows
    /// listed under it while it is open.
    var tabCount: Int {
        if let summary = row.collapsedSummary { return max(summary.tabs, 1) }
        let tabs = children.filter(\.isTabRow).count
        return max(tabs, 1)
    }

    /// The rows a disclosure lists: on a phone the tabs alone, one line
    /// each; with room for more, every row under the workspace, nested.
    ///
    /// A workspace whose row is already its one tab lists that tab's panes,
    /// which are then all there is under it.
    ///
    /// - Parameter nestsPanes: Whether the width nests panes under tabs.
    /// - Returns: The rows.
    func disclosedRows(nestsPanes: Bool) -> [HostOutlineRow] {
        if nestsPanes || row.foldedTab != nil { return children }
        return children.filter(\.isTabRow)
    }

    /// Splits Core's flat rows into workspaces.
    ///
    /// - Parameter rows: Core's rows, workspaces first in each run.
    /// - Returns: One group per workspace row.
    static func groups(of rows: [HostOutlineRow]) -> [WorkspaceGroup] {
        var groups: [WorkspaceGroup] = []
        var current: HostOutlineRow?
        var children: [HostOutlineRow] = []
        for row in rows {
            if row.level == .workspace {
                if let current { groups.append(WorkspaceGroup(row: current, children: children)) }
                current = row
                children = []
            } else {
                children.append(row)
            }
        }
        if let current { groups.append(WorkspaceGroup(row: current, children: children)) }
        return groups
    }
}

extension HostOutlineRow {
    /// Whether the row is a tab's: a tab's own, or a window's of one tab.
    var isTabRow: Bool {
        level == .tab || (level == .window && foldedTab != nil)
    }

    /// Whether the row is a pane's, or stands for one pane.
    var isPaneRow: Bool {
        level == .pane || foldedPane != nil
    }

    /// Whether the row is one the person is needed on, by Core's rule for a
    /// row's second line: a question, a request or a failure.
    var needsThePerson: Bool {
        isPaneRow && workspaceState != .restorable && !secondLine.isEmpty
    }

    /// A program's question stays verbatim; a bare status gets a readable headline.
    var needsYouTitle: String {
        guard !hasUnseenNotification, secondLine == statusWords else { return secondLine }
        switch status {
        case .attention: return String(localized: "Needs attention")
        case .failed: return String(localized: "Process failed")
        case .blocked:
            switch blockKind {
            case .permission: return String(localized: "Waiting for permission")
            case .question: return String(localized: "Waiting for an answer")
            case .auth: return String(localized: "Sign-in required")
            case .none: return String(localized: "Waiting")
            }
        default: return secondLine
        }
    }

    /// The age a row shows, in Core's words: "just now", "4m ago".
    var ageWords: String? {
        sinceActivity.map { HostWords.compactAge(secondsAgo: $0.seconds) }
    }
}

/// How a workspace list is ordered.
enum WorkspaceOrder: String, CaseIterable, Identifiable {
    /// The most recently active first.
    case recent
    /// By name, as the Finder orders names.
    case name
    /// The ones that need the person first, then the most recently active.
    case needsAttention

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .recent: "Recent"
        case .name: "Name"
        case .needsAttention: "Needs Attention"
        }
    }

    /// Orders groups, keeping Core's order between equals.
    ///
    /// - Parameter groups: The groups, in Core's order.
    /// - Returns: The groups in this order.
    func sorted(_ groups: [WorkspaceGroup]) -> [WorkspaceGroup] {
        let indexed = Array(groups.enumerated())
        let recent: (WorkspaceGroup, WorkspaceGroup) -> Bool? = { left, right in
            let leftAge = left.row.sinceActivity?.seconds ?? .max
            let rightAge = right.row.sinceActivity?.seconds ?? .max
            return leftAge == rightAge ? nil : leftAge < rightAge
        }
        return
            indexed.sorted { left, right in
                let isEarlier: Bool?
                switch self {
                case .recent:
                    isEarlier = recent(left.element, right.element)
                case .name:
                    let comparison = left.element.row.title.localizedStandardCompare(right.element.row.title)
                    isEarlier = comparison == .orderedSame ? nil : comparison == .orderedAscending
                case .needsAttention:
                    let leftRank = left.element.row.status.rawValue
                    let rightRank = right.element.row.status.rawValue
                    isEarlier = leftRank == rightRank ? recent(left.element, right.element) : leftRank > rightRank
                }
                return isEarlier ?? (left.offset < right.offset)
            }
            .map(\.element)
    }
}

/// A workspace on two lines: its status and name, then how many tabs it
/// has, who is on it and how long ago anything happened.
struct WorkspaceRowLabel: View {
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize
    let group: WorkspaceGroup
    /// What the device is called, for the row of the workspace it is on.
    var deviceName = UIDevice.current.model

    var body: some View {
        let row = group.row
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgramStatusMark(status: row.status, isSaved: group.isSaved, blockKind: row.blockKind)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.title)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.middle)
                        .foregroundStyle(group.isSaved ? .secondary : .primary)
                    Spacer(minLength: 4)
                    trailing
                }
                Text(verbatim: facts)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityWords))
    }

    /// The tag a rule made prominent, a progress bar while a program reports
    /// one, or the mark of the workspace this device is on.
    @ViewBuilder
    private var trailing: some View {
        let row = group.row
        if row.status == .working, row.progressState != 0, row.progressValue > 0 {
            ProgressView(value: Double(min(row.progressValue, 100)), total: 100)
                .frame(width: 48)
                .tint(ProgramStatusMark.tone(for: .working))
                .accessibilityHidden(true)
        } else if row.here != .elsewhere {
            Image(systemName: deviceName == "iPad" ? "ipad" : "iphone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else if let loud = row.tags.first(where: \.isLoud) {
            Text(verbatim: loud.name)
                .font(.caption.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    /// The second line: "3 tabs · 2 people · 4m ago".
    private var facts: String {
        var parts = [Self.tabCountWords(group.tabCount)]
        if !group.row.attendanceWords.isEmpty { parts.append(group.row.attendanceWords) }
        if let age = group.row.ageWords { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    /// "1 tab", "3 tabs".
    static func tabCountWords(_ count: Int) -> String {
        count == 1 ? "1 tab" : "\(count) tabs"
    }

    private var accessibilityWords: String {
        let row = group.row
        var parts = [row.title]
        if !row.statusWords.isEmpty { parts.append(row.statusWords) }
        if !row.progressWords.isEmpty { parts.append(row.progressWords) }
        parts.append(facts)
        for words in [row.stateWords, row.lifetimeWords] where !words.isEmpty {
            parts.append(words)
        }
        if row.here != .elsewhere { parts.append("Open on this \(deviceName)") }
        return parts.joined(separator: ", ")
    }
}

/// A title above its program status, with a shallow indent for nested panes.
struct WorkspaceChildRow: View {
    let row: HostOutlineRow
    /// How many levels the row sits below its workspace's first.
    let indent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.title)
                .font(row.level == .workspace ? .body.weight(.semibold) : .body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !row.programStatus.isEmpty {
                HStack(spacing: 5) {
                    ProgramStatusMark(status: row.status, isSaved: row.workspaceState == .restorable, blockKind: row.blockKind)
                    Text(verbatim: row.programStatus)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(min(indent, 2)) * 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: [row.title, row.programStatus].filter { !$0.isEmpty }
                    .joined(separator: ", ")
            )
        )
    }
}

/// A pane that needs the person: what it asks, where it is, and the one
/// action that answers it.
struct NeedsYouRow: View {
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize
    /// What it asks or reports, in Core's words.
    let question: String
    /// Where it is: the workspace, then the pane.
    let place: String
    let status: HostOutlineStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let layout =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                ProgramStatusMark(status: status)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: question)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text(verbatim: place)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// What a workspace's context menu previews: its rows as a detail card —
/// the facts Core states for it, and every tab with what runs where.
struct WorkspacePreview: View {
    let group: WorkspaceGroup
    /// The rows under the workspace with every row open.
    let everyRow: [HostOutlineRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgramStatusMark(status: group.row.status, isSaved: group.isSaved, blockKind: group.row.blockKind)
                    .font(.title3)
                Text(verbatim: group.row.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !group.row.details.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(group.row.details.prefix(6).enumerated()), id: \.offset) { _, detail in
                        GridRow {
                            Text(verbatim: detail.label)
                                .foregroundStyle(.secondary)
                            Text(verbatim: detail.value)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .font(.footnote)
            }
            let tabs = everyRow.filter(\.isTabRow)
            if !tabs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(tabs.prefix(8).enumerated()), id: \.offset) { _, tab in
                        HStack(spacing: 8) {
                            ProgramStatusMark(status: tab.status, isSaved: group.isSaved, blockKind: tab.blockKind)
                                .font(.footnote)
                            Text(verbatim: tab.title)
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if tab.columns > 0, tab.rows > 0 {
                                Text(verbatim: HostWords.grid(columns: tab.columns, rows: tab.rows))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}
