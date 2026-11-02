// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// HostOutlineRowView.swift — one row of a host's outline, drawn.
//
// Every fact on the row is Core's (`App::OutlineRow`): the indentation, the
// title and the dimmed text of what runs there, the label and tag chips, the
// status and the ink of each mark, the words for a status, a progress, who is
// attached and what a closed row hides. This file lays them out and picks a
// shape for each; Core supplies the words, including ages.
//
// The row is the title with its chips over the facts, with the marks and one
// age on the trailing side. The title has the room first: its line, the
// facts and the chips are flows that wrap whole items rather than cut a word,
// and where the row is narrow the trailing side keeps only the progress and
// the one mark Core's accessory rule picks, the rest going under the facts.
// Everything beside the title sits on the title's line, however many lines
// the row grows to.
//

import Foundation
import SwiftUI
import UbiquittyRenderKit

/// The measures every row shares.
enum HostOutlineMetrics {
    /// How far a level is indented under the one above it.
    static let indent: CGFloat = 16
    /// The slot a fold control takes, kept on a row with none so titles align.
    static let foldSlot: CGFloat = 14
    /// The slot a status mark takes, kept on a row with none.
    static let statusSlot: CGFloat = 16
    /// The slot a tab colour takes, kept on a row with none.
    static let tabColorSlot: CGFloat = 3
    /// How wide a progress mark is.
    static let progressWidth: CGFloat = 36
    /// The width under which a row keeps only its progress and one mark on
    /// the trailing side.
    static let compactWidth: CGFloat = 520
    /// The height of the title's line, which the fold, the tab colour, the
    /// status mark and the trailing marks are centred on.
    #if os(macOS)
    static let titleLine: CGFloat = 16
    #else
    static let titleLine: CGFloat = 22
    #endif
}

extension HostOutlineColor {
    /// The colour as SwiftUI draws it.
    var color: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }

    /// Whether dark text reads on the colour better than light text does, by
    /// its relative luminance.
    var isLight: Bool {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) > 0.4
    }
}

extension HostOutlineInk {
    /// The colour the ink is drawn in.
    ///
    /// - Parameter platform: The platform's own colour for the mark, drawn
    ///   where Core says the platform's is the one.
    /// - Returns: The colour.
    func color(platform: Color) -> Color {
        switch self {
        case .theme(let color): color.color
        case .platform: platform
        }
    }
}

extension HostOutlineProgressMark {
    /// The platform's own colour for the mark.
    var platformColor: Color {
        switch self {
        case .accent: .accentColor
        case .inactive: .gray
        case .error: .red
        }
    }
}

/// How much of a row is drawn.
enum HostOutlineRowStyle: Equatable {
    /// The title with its chips over the facts, and every mark.
    case full
    /// One line: the status, the title cut in its middle so the end of a
    /// path stays, and on the trailing side the progress, the one mark
    /// Core's accessory rule picks and the age. For a list that holds a
    /// host's rows among other things, a line each.
    ///
    /// - Parameter nests: Whether each level is indented under the one
    ///   above it; without, every row under a workspace shares one indent,
    ///   so a narrow column gives its titles the room.
    case singleLine(nests: Bool)
}

/// One row.
struct HostOutlineRowView<Accessory: View>: View {
    let row: HostOutlineRow
    /// Whether the rows are a search's, in which a fold has nothing to act on.
    let isSearching: Bool
    /// Opens or closes the row.
    let toggle: () -> Void
    /// Whether the row is narrow, so only its progress and one mark stay on
    /// the trailing side.
    let isCompact: Bool
    /// How much of the row is drawn.
    var style = HostOutlineRowStyle.full
    /// What the window showing the outline adds to the row beside Core's
    /// marks: its own facts about the row, never the host's.
    @ViewBuilder
    let accessory: () -> Accessory

    @Environment(\.backgroundProminence)
    private var backgroundProminence

    /// Whether the row is drawn on a selection's emphasised fill, where a
    /// mark in a theme's colour needs a plate under it to stay readable.
    private var isOnEmphasis: Bool { backgroundProminence == .increased }

    /// Whether nothing runs in the row's workspace.
    private var isRestorable: Bool { row.workspaceState == .restorable }

    var body: some View {
        switch style {
        case .full:
            fullRow
        case .singleLine(let nests):
            singleLineRow(nests: nests)
        }
    }

    /// The level the row is indented to: its depth, or with a style that
    /// does not nest, one level under its workspace at most.
    private func indentLevel(nests: Bool) -> Int {
        nests ? row.depth : min(row.depth, 1)
    }

    private var fullRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                fold
                tabColor
                statusMark
            }
            .frame(height: HostOutlineMetrics.titleLine)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                factsLine
                if isCompact {
                    detailMarks
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                trailingMarks
                    .frame(minHeight: HostOutlineMetrics.titleLine)
                age
            }
            .layoutPriority(1)
        }
        .padding(.leading, CGFloat(row.depth) * HostOutlineMetrics.indent)
        .padding(.vertical, 2)
        // A search keeps the way to a match on screen; those rows step back
        // so the matches are the ones read.
        .opacity(isSearching && !row.isMatch ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// The row on one line, read as one element: Core's words for it, with
    /// opening or closing it as an action where it folds.
    private func singleLineRow(nests: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Group {
                fold
                tabColor
                statusMark
            }
            .frame(height: HostOutlineMetrics.titleLine)
            Text(row.title)
                .font(row.level == .workspace ? .body.weight(.semibold) : .body)
                .foregroundStyle(isRestorable ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, row.isMatch ? 3 : 0)
                .background(
                    row.isMatch ? AnyShapeStyle(Color.yellow.opacity(isOnEmphasis ? 0 : 0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 3)
                )
                // The title has the line's room before the spacer beside it.
                .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                progress
                accessoryMark
                age
            }
            .fixedSize()
        }
        .padding(.leading, CGFloat(indentLevel(nests: nests)) * HostOutlineMetrics.indent)
        .opacity(isSearching && !row.isMatch ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenWords(for: row))
        .modifier(FoldAction(row: row, isSearching: isSearching, toggle: toggle))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// What an assistive reader is told of a row read as one element:
    /// Core's title, then Core's words for its status, its progress, who is
    /// attached and what a closed row hides, and the newest age.
    ///
    /// - Parameter row: The row.
    /// - Returns: The words, joined as a list is read.
    static func spokenWords(for row: HostOutlineRow) -> String {
        var words = [row.title, row.statusWords, row.progressWords, row.attendanceWords, row.collapsedWords, row.stateWords]
        if let newest = row.sinceActivity {
            words.append(HostWords.lastActive(secondsAgo: newest.seconds))
        }
        return words.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The identifier a scenario finds the row by.
    private var accessibilityIdentifier: String {
        if let id = row.id {
            return "host-outline-row-\(id.kind)-\(id.number)"
        }
        return "host-outline-row-\(row.level)-\(row.pathWorkspace)-\(row.pathWindow)-\(row.pathTab)-\(row.pathPane)"
    }

    // MARK: - Leading marks

    @ViewBuilder
    private var fold: some View {
        if row.isExpandable {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: HostOutlineMetrics.foldSlot, height: HostOutlineMetrics.foldSlot)
                    // A line of a touch list is a finger tall, and the fold
                    // takes its touches from the slot's surround.
                    .contentShape(Rectangle().inset(by: style == .full ? 0 : -10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isSearching)
            // A row read as one element folds through its own action.
            .accessibilityHidden(style != .full)
            .accessibilityLabel(HostWords.foldControl(for: row))
            .accessibilityIdentifier("\(accessibilityIdentifier)-fold")
        } else {
            Color.clear.frame(width: HostOutlineMetrics.foldSlot, height: HostOutlineMetrics.foldSlot)
        }
    }

    @ViewBuilder
    private var tabColor: some View {
        if let color = row.tabColor {
            Capsule()
                .fill(color.color)
                .frame(width: HostOutlineMetrics.tabColorSlot)
                .accessibilityLabel(HostWords.text(.tabColour))
        } else {
            Color.clear.frame(width: HostOutlineMetrics.tabColorSlot, height: 1)
        }
    }

    /// The shape a status is drawn as. The colour is Core's ink; the shape
    /// tells the kinds apart for a reader who cannot tell the colours apart.
    private var statusSymbol: String? {
        switch row.status {
        case .none: nil
        case .idle: "circle"
        case .running: "circle.fill"
        case .working: "ellipsis.circle.fill"
        case .done: "checkmark.circle.fill"
        case .attention: "bell.badge.circle.fill"
        case .blocked:
            switch row.blockKind {
            case .permission: "hand.raised.circle.fill"
            case .auth: "key.circle.fill"
            case .question, .none: "questionmark.circle.fill"
            }
        case .failed: "xmark.octagon.fill"
        }
    }

    /// The colour of the figure inside a status mark. A mark of one shape has
    /// no figure and is drawn in the ink whole; a figure on a light ink is
    /// dark so it can be told from the ink.
    private var statusGlyph: Color {
        let ink = row.statusInk.color(platform: .secondary)
        switch row.status {
        case .none, .idle, .running:
            return ink
        case .working, .done, .attention, .blocked, .failed:
            if case .theme(let color) = row.statusInk, color.isLight {
                return .black
            }
            return .white
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        if isRestorable {
            // Nothing runs in the workspace, so there is no status to mark;
            // the slot says instead that the row is a record.
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: HostOutlineMetrics.statusSlot)
                .accessibilityHidden(true)
        } else if let symbol = statusSymbol {
            Image(systemName: symbol)
                .font(.system(size: row.status == .running ? 8 : 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(statusGlyph, row.statusInk.color(platform: .secondary))
                .modifier(MarkPlate(isShown: isOnEmphasis, shape: Circle()))
                .frame(width: HostOutlineMetrics.statusSlot)
                .accessibilityLabel(row.statusWords)
                .accessibilityIdentifier("\(accessibilityIdentifier)-status")
        } else {
            Color.clear.frame(width: HostOutlineMetrics.statusSlot, height: 1)
        }
    }

    // MARK: - Title and facts

    private var title: some View {
        Text(row.title)
            .font(row.level == .workspace ? .body.weight(.semibold) : .body)
            .foregroundStyle(isRestorable ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, row.isMatch ? 3 : 0)
            .background(
                row.isMatch ? AnyShapeStyle(Color.yellow.opacity(isOnEmphasis ? 0 : 0.35)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .accessibilityIdentifier("\(accessibilityIdentifier)-title")
    }

    @ViewBuilder
    private var currentMark: some View {
        if row.isHostCurrent {
            // A quiet mark: it says where the host's own focus is, which is
            // not a status and must not read as one.
            Image(systemName: "eye")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(row.hostCurrentWords)
                .accessibilityLabel(row.hostCurrentWords)
        }
    }

    @ViewBuilder
    private var secondary: some View {
        if !row.secondaryTitle.isEmpty {
            Text(row.secondaryTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if !row.stateWords.isEmpty {
            HostOutlineStateChip(words: row.stateWords)
        }
        ForEach(Array(row.labelChips.enumerated()), id: \.offset) { _, label in
            HostOutlineLabelChip(label: label)
        }
        ForEach(Array(row.tags.enumerated()), id: \.offset) { _, tag in
            HostOutlineTagChip(tag: tag, isOnEmphasis: isOnEmphasis)
        }
    }

    /// The title, what runs there and the chips as one flow: on one line
    /// while they fit, the text of what runs there shortened into the room
    /// left before anything wraps.
    private var titleLine: some View {
        HostOutlineFlow(spacing: 6, lineSpacing: 3) {
            title
            currentMark
            secondary.layoutValue(key: HostOutlineFlow.IsCompressible.self, value: true)
            chips
            // A narrow row has no room for a badge beside its marks, and one
            // badge is not worth a line of its own, so it sits with the chips.
            if isCompact {
                badge
            }
        }
    }

    /// The row's facts in Core's words and in the pane's own values, in the
    /// order they matter to someone choosing a row.
    private var facts: [String] {
        var facts = [row.statusWords, row.progressWords, row.attendanceWords, row.collapsedWords, row.lifetimeWords, row.program]
        if row.columns > 0, row.rows > 0 {
            facts.append(HostWords.grid(columns: row.columns, rows: row.rows))
        }
        return facts.filter { !$0.isEmpty }
    }

    /// The facts and the directory as one flow of whole items: a fact that
    /// does not fit starts the next line rather than losing its end, and the
    /// directory, which is a path and not a word, is shortened in its middle
    /// into the room left.
    @ViewBuilder
    private var factsLine: some View {
        let facts = facts
        if !facts.isEmpty || !row.directory.isEmpty {
            HostOutlineFlow(spacing: 5, lineSpacing: 1) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    Text(index + 1 < facts.count || !row.directory.isEmpty ? fact + "  ·" : fact)
                        .lineLimit(1)
                }
                if !row.directory.isEmpty {
                    Text(row.directory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutValue(key: HostOutlineFlow.IsCompressible.self, value: true)
                        .accessibilityIdentifier("\(accessibilityIdentifier)-directory")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(accessibilityIdentifier)-facts")
        }
    }

    // MARK: - Marks

    /// The marks on the title's line at the trailing side. A narrow row
    /// keeps the progress and the one mark Core's accessory rule picks; a
    /// wide one has room for all of them.
    private var trailingMarks: some View {
        HStack(spacing: 6) {
            if !isCompact {
                accessory()
            }
            progress
            if !isCompact {
                badge
            }
            accessoryMark
            if !isCompact {
                otherMarks
                attentionTitle
            }
        }
    }

    /// What a narrow row moves under its facts: everything the trailing side
    /// had no room for, as a flow of whole items.
    @ViewBuilder
    private var detailMarks: some View {
        if hasDetailMarks {
            HostOutlineFlow(spacing: 6, lineSpacing: 2) {
                accessory()
                otherMarks
                attentionTitle.layoutValue(key: HostOutlineFlow.IsCompressible.self, value: true)
            }
        }
    }

    /// Whether a narrow row has anything Core states to put under its facts.
    private var hasDetailMarks: Bool {
        showsBellApart || showsNotificationApart || !row.attentionTitle.isEmpty
    }

    @ViewBuilder
    private var progress: some View {
        if row.progressState != 0 {
            HostOutlineProgressMarkView(
                state: row.progressState,
                value: row.progressValue,
                color: row.progressInk.color(platform: row.progressMark.platformColor)
            )
            .modifier(MarkPlate(isShown: isOnEmphasis, shape: Capsule()))
            .accessibilityLabel(row.progressWords)
            .accessibilityIdentifier("\(accessibilityIdentifier)-progress")
        }
    }

    /// The badge the row's pane wears, or on a row over several panes how
    /// many of them wear one, as a count in a filled badge.
    @ViewBuilder
    private var badge: some View {
        if !row.badge.isEmpty {
            Text(row.badge)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 96)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                .accessibilityIdentifier("\(accessibilityIdentifier)-badge")
        } else if row.badgeCount > 0 {
            Text(row.badgeCount, format: .number)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isOnEmphasis ? Color.black : Color.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .frame(minWidth: 16)
                .background(isOnEmphasis ? Color.white.opacity(0.92) : Color.secondary, in: Capsule())
                .accessibilityLabel(HostWords.text(.badges))
                .accessibilityValue(Text(row.badgeCount, format: .number))
                .accessibilityIdentifier("\(accessibilityIdentifier)-badge-count")
        }
    }

    /// Whether the bell is drawn apart from the one mark Core's rule picks:
    /// it rang, and the rule gave the slot to something else.
    private var showsBellApart: Bool {
        row.hasUnseenBell && row.accessory != .bell && row.accessory != .colouredBell
    }

    /// Whether the notification's mark is drawn apart from the one mark
    /// Core's rule picks.
    private var showsNotificationApart: Bool {
        row.hasUnseenNotification && row.accessory != .notificationDot
    }

    private var bellMark: some View {
        Image(systemName: "bell.fill")
            .font(.caption)
            .foregroundStyle(bellColor)
            .modifier(MarkPlate(isShown: isOnEmphasis, shape: Circle()))
            .accessibilityLabel(HostWords.text(.bell))
            .accessibilityIdentifier("\(accessibilityIdentifier)-bell")
    }

    private var notificationMark: some View {
        Image(systemName: "bubble.left.fill")
            .font(.caption)
            .foregroundStyle(row.notificationInk.color(platform: .blue))
            .modifier(MarkPlate(isShown: isOnEmphasis, shape: Circle()))
            .help(row.attentionBody)
            .accessibilityLabel(HostWords.text(.notification))
            .accessibilityIdentifier("\(accessibilityIdentifier)-notification")
    }

    /// The marks the row has beyond the one Core's accessory rule picks.
    @ViewBuilder
    private var otherMarks: some View {
        if showsBellApart {
            bellMark
        }
        if showsNotificationApart {
            notificationMark
        }
    }

    /// The one mark Core's accessory rule picks for the row. A progress ring
    /// is the progress mark already drawn; the colour a program chose is
    /// drawn only here, as a dot of its own or as the bell's ink.
    @ViewBuilder
    private var accessoryMark: some View {
        switch row.accessory {
        case .bell, .colouredBell:
            bellMark
        case .notificationDot:
            notificationMark
        case .statusDot:
            if let ink = row.accessoryInk {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(ink.color)
                    .modifier(MarkPlate(isShown: isOnEmphasis, shape: Circle()))
                    .accessibilityLabel(HostWords.text(.indicator))
                    .accessibilityIdentifier("\(accessibilityIdentifier)-indicator")
            }
        case .none, .progressRing, .activityDots, .shortcutHint:
            EmptyView()
        }
    }

    /// The newest unseen notification's title, in Core's words.
    @ViewBuilder
    private var attentionTitle: some View {
        if !row.attentionTitle.isEmpty {
            Text(row.attentionTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: isCompact ? .infinity : 160, alignment: .leading)
                .fixedSize(horizontal: !isCompact, vertical: false)
                .help(row.attentionBody)
                .accessibilityIdentifier("\(accessibilityIdentifier)-attention")
        }
    }

    /// What the bell is drawn in: the colour the program chose where Core's
    /// one-mark rule says the bell wears it, else the bell's own ink.
    private var bellColor: Color {
        if row.accessory == .colouredBell, let ink = row.accessoryInk {
            return ink.color
        }
        return row.bellInk.color(platform: .secondary)
    }

    /// The one age the row shows: the newer of its two, as Core picked it.
    /// Both are in the help tag and in what an assistive reader is told.
    @ViewBuilder
    private var age: some View {
        if let newest = row.sinceActivity {
            Text(HostWords.compactAge(secondsAgo: newest.seconds))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(bothAges)
                .accessibilityLabel(HostWords.text(.lastActive))
                .accessibilityValue(bothAges)
                .accessibilityIdentifier("\(accessibilityIdentifier)-age")
        }
    }

    /// When the row last wrote and was last typed into, one a line.
    private var bothAges: String {
        var lines: [String] = []
        if let output = row.sinceOutput {
            lines.append(HostWords.lastOutput(secondsAgo: output.seconds))
        }
        if let input = row.sinceInput {
            lines.append(HostWords.lastInput(secondsAgo: input.seconds))
        }
        return lines.joined(separator: "\n")
    }
}

/// Opening or closing a row read as one element, as an action an assistive
/// reader offers on it; nothing for a row with nothing under it, or while a
/// search holds every match open.
private struct FoldAction: ViewModifier {
    let row: HostOutlineRow
    let isSearching: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if row.isExpandable, !isSearching {
            content.accessibilityAction(named: Text(HostWords.foldControl(for: row)), toggle)
        } else {
            content
        }
    }
}

/// A light plate under a mark drawn on a selection's emphasised fill, so a
/// mark in a theme's colour is not lost on the accent.
private struct MarkPlate<Plate: Shape>: ViewModifier {
    let isShown: Bool
    let shape: Plate

    func body(content: Content) -> some View {
        if isShown {
            content
                .padding(2)
                .background(Color.white.opacity(0.92), in: shape)
        } else {
            content
        }
    }
}

/// A progress mark: a short bar filled to the reported value.
private struct HostOutlineProgressMarkView: View {
    /// The state as OSC 9;4 numbers it: 1 a value, 2 an error, 3 of unknown
    /// length, 4 held.
    let state: UInt8
    let value: UInt8
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(color.opacity(0.25))
            switch state {
            case 2:
                Capsule().fill(color)
            case 3:
                // Of unknown length: a block in the middle, drawn still. A
                // list of many rows does not animate each one.
                Capsule()
                    .fill(color)
                    .frame(width: HostOutlineMetrics.progressWidth * 0.4)
                    .offset(x: HostOutlineMetrics.progressWidth * 0.3)
            default:
                Capsule()
                    .fill(color.opacity(state == 4 ? 0.55 : 1))
                    .frame(width: HostOutlineMetrics.progressWidth * CGFloat(min(value, 100)) / 100)
            }
        }
        .frame(width: HostOutlineMetrics.progressWidth, height: 5)
    }
}

/// A label, as a person typed it.
private struct HostOutlineLabelChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .accessibilityLabel(HostWords.labelChip(label))
    }
}

/// What a workspace's row says of its state, in Core's word.
private struct HostOutlineStateChip: View {
    let words: String

    var body: some View {
        Text(words)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// A tag, in the colour the reader's rules give its name.
///
/// An untitled tag, which only a rule with a colour supplies, is a dot of that
/// colour rather than an empty capsule, spoken by its colour's name. A tag
/// whose rule hides its name is that dot too, spoken by its name.
private struct HostOutlineTagChip: View {
    let tag: HostOutlineTag
    let isOnEmphasis: Bool

    var body: some View {
        if !tag.isNameShown {
            Circle()
                .fill(tag.color?.color ?? .secondary)
                .overlay(Circle().strokeBorder(isOnEmphasis ? Color.white.opacity(0.92) : .clear, lineWidth: 1))
                .frame(width: 9, height: 9)
                .accessibilityElement()
                .accessibilityLabel(HostWords.tagChip(tag.spokenName))
        } else {
            capsule
        }
    }

    private var capsule: some View {
        Text(tag.name)
            .font(.caption.weight(tag.isLoud ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(HostWords.tagChip(tag.name))
    }

    /// A loud tag is filled with its colour; a quiet one is tinted with it.
    private var isFilled: Bool { tag.isLoud && tag.color != nil }

    private var foreground: Color {
        guard let color = tag.color else { return isOnEmphasis ? .black : .primary }
        if isFilled {
            return color.isLight ? .black : .white
        }
        return isOnEmphasis ? .black : .primary
    }

    private var background: Color {
        guard let color = tag.color else {
            return isOnEmphasis ? .white.opacity(0.92) : .clear
        }
        if isFilled {
            return color.color
        }
        return isOnEmphasis ? .white.opacity(0.92) : color.color.opacity(0.18)
    }

    private var stroke: Color {
        guard let color = tag.color else { return .secondary.opacity(0.6) }
        return color.color.opacity(isFilled ? 1 : 0.75)
    }
}

/// Lays views out in lines, starting a new line when one is full.
///
/// A view marked ``IsCompressible`` is text that may be shortened: it is
/// given the room left on its line when that is enough to say something, and
/// starts a line of its own, shortened to the width, when it is not. Every
/// other view keeps its size, so a chip is drawn whole or on the next line.
struct HostOutlineFlow: Layout {
    /// Whether a view may be drawn narrower than it asks to be.
    struct IsCompressible: LayoutValueKey {
        static let defaultValue = false
    }

    /// The least room worth shortening a compressible view into.
    private static let leastCompressedWidth: CGFloat = 72

    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index]
                    .place(
                        at: CGPoint(x: x, y: y + line.height / 2),
                        anchor: .leading,
                        proposal: ProposedViewSize(width: item.width, height: item.height)
                    )
                x += item.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Item {
        let index: Int
        let width: CGFloat
        let height: CGFloat
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: Item, spacing: CGFloat) {
            width += (items.isEmpty ? 0 : spacing) + item.width
            height = max(height, item.height)
            items.append(item)
        }
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let used = current.items.isEmpty ? 0 : current.width + spacing
            if used + ideal.width <= width {
                current.append(Item(index: index, width: ideal.width, height: ideal.height), spacing: spacing)
                continue
            }
            let isCompressible = subviews[index][IsCompressible.self]
            let room = width - used
            if isCompressible, !current.items.isEmpty, room >= Self.leastCompressedWidth {
                current.append(Item(index: index, width: room, height: ideal.height), spacing: spacing)
                continue
            }
            if !current.items.isEmpty {
                lines.append(current)
                current = Line()
            }
            // Alone on its line, a view wider than the line is drawn at the
            // line's width; text shortens itself and a chip is clipped by
            // nothing narrower than the row.
            current.append(Item(index: index, width: min(ideal.width, width), height: ideal.height), spacing: spacing)
        }
        if !current.items.isEmpty {
            lines.append(current)
        }
        return lines
    }
}
