// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// HostOutlineList.swift — a host's outline as a list, and the two things a
// list of it shows besides rows: that the tree is no longer being followed,
// and the question Core asks when a connect does not say where to land.
//
// The list is flat because the rows are: Core has already put them in order,
// folded what folds and decided which are open, so a nested disclosure tree
// here would be a second owner of what is expanded. A fold asks the store to
// close or open the row, and the rows that come back are drawn.
//

import SwiftUI
import UbiquittyRenderKit

/// A host's rows, selectable, with a menu and an open action per row, and
/// the actions a swipe across a row reveals where the platform swipes.
struct HostOutlineList<RowMenu: View, RowAccessory: View, RowSwipe: View>: View {
    @Bindable
    var store: HostOutlineStore

    /// The selected row.
    @Binding
    var selection: HostOutlineRowKey?

    /// What a double click, Return or a tap on a row does.
    let open: (HostOutlineRow) -> Void

    /// The menu for a row.
    @ViewBuilder
    let rowMenu: (HostOutlineRow) -> RowMenu

    /// What the window adds to a row beside Core's marks.
    @ViewBuilder
    let rowAccessory: (HostOutlineRow) -> RowAccessory
    /// The actions a trailing swipe across a row reveals. Never a full
    /// swipe: one stroke across the list must not act on a row.
    @ViewBuilder
    let rowSwipe: (HostOutlineRow) -> RowSwipe

    /// Whether the list is narrow, so each row puts its ages under its
    /// facts.
    @State
    private var isCompact = false

    var body: some View {
        List(selection: $selection) {
            ForEach(store.rows, id: \.key) { row in
                HostOutlineRowView(row: row, isSearching: store.isSearching, toggle: { store.toggle(row) }, isCompact: isCompact) {
                    rowAccessory(row)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    rowSwipe(row)
                }
            }
        }
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width < HostOutlineMetrics.compactWidth
        } action: { isNarrow in
            isCompact = isNarrow
        }
        .contextMenu(forSelectionType: HostOutlineRowKey.self) { keys in
            if let row = store.row(for: keys.first) {
                rowMenu(row)
            }
        } primaryAction: { keys in
            if let row = store.row(for: keys.first) {
                open(row)
            }
        }
        .onKeyPress(.rightArrow) { fold(open: true) }
        .onKeyPress(.leftArrow) { fold(open: false) }
        .modifier(HostOutlineFreshnessStyle(freshness: store.freshness))
        .onAppear { store.startRefreshingAges() }
        .onDisappear { store.stopRefreshingAges() }
        .accessibilityIdentifier("host-outline")
    }

    /// Opens or closes the selected row from the keyboard.
    ///
    /// - Parameter open: Whether the arrow opens.
    /// - Returns: Whether the key did anything, so an arrow on a row with
    ///   nothing to fold still reaches the list.
    private func fold(open: Bool) -> KeyPress.Result {
        guard let row = store.row(for: selection), row.isExpandable, row.isExpanded != open, !store.isSearching else {
            return .ignored
        }
        store.setExpanded(open, row)
        return .handled
    }
}

extension HostOutlineList where RowSwipe == EmptyView {
    /// A list whose rows reveal nothing on a swipe.
    init(
        store: HostOutlineStore,
        selection: Binding<HostOutlineRowKey?>,
        open: @escaping (HostOutlineRow) -> Void,
        @ViewBuilder rowMenu: @escaping (HostOutlineRow) -> RowMenu,
        @ViewBuilder rowAccessory: @escaping (HostOutlineRow) -> RowAccessory
    ) {
        self.init(
            store: store,
            selection: selection,
            open: open,
            rowMenu: rowMenu,
            rowAccessory: rowAccessory,
            rowSwipe: { _ in EmptyView() }
        )
    }
}

/// How rows are drawn for how current their tree is. A tree nothing follows
/// is what the host held when it was last heard, and is drawn as that, never
/// as live.
struct HostOutlineFreshnessStyle: ViewModifier {
    let freshness: HostOutlineFreshness

    func body(content: Content) -> some View {
        content
            .saturation(freshness == .stale ? 0.25 : 1)
            .opacity(freshness == .stale ? 0.6 : 1)
    }
}

/// The line over an outline whose tree is no longer followed: Core's sentence
/// for why, and a way to ask again.
struct HostOutlineStaleBanner: View {
    /// Core's sentence (`Snapshot::watchError`).
    let message: String
    /// Asks the host again; nil where the list retries by itself.
    let retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let retry {
                Button(HostWords.text(.tryAgain), action: retry)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host-outline-stale")
    }
}

/// What Core asks a person when a connect does not say where to land
/// (`Runtime::AttachQuestion`), as values a view reads.
struct HostAttachQuestion: Equatable, Identifiable {
    /// One workspace the person may pick.
    struct Candidate: Equatable, Identifiable {
        /// The workspace, as the host's tree numbers it.
        let workspaceID: UInt32
        /// What picking it attaches to, as its row in the outline carries
        /// it.
        let open: HostOutlineOpen
        /// What the workspace's row in the outline is called.
        let title: String
        /// Whether anything runs in it.
        let state: HostOutlineWorkspaceState

        var id: UInt32 { workspaceID }
    }

    /// Core's sentence.
    let text: String
    /// Core's shorter sentence for the action bar.
    let shortText: String
    /// What may be picked, in the tree's order.
    let candidates: [Candidate]
    /// Whether starting a new workspace is offered beside the candidates.
    let isNewSessionOffered: Bool

    var id: String { text }
}

/// Core's question, its candidates, and the buttons that answer it.
struct HostAttachQuestionView: View {
    let question: HostAttachQuestion
    /// Attaches to a candidate.
    let choose: (HostAttachQuestion.Candidate) -> Void
    /// Starts a new workspace; called only where the question offers one.
    let startNew: () -> Void
    /// Leaves the question unanswered.
    let cancel: () -> Void

    @State
    private var selection: UInt32?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("host-attach-question-text")
            // A few rows a person picks one of: plain buttons in a column,
            // not a table, so nothing here is laid out twice to be measured.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(question.candidates) { candidate in
                        Button {
                            if selection == candidate.workspaceID {
                                choose(candidate)
                            } else {
                                selection = candidate.workspaceID
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: candidate.state == .restorable ? "clock.arrow.circlepath" : "rectangle.stack")
                                    .foregroundStyle(selection == candidate.workspaceID ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(candidate.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .foregroundStyle(
                                selection == candidate.workspaceID
                                    ? AnyShapeStyle(.white)
                                    : candidate.state == .restorable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                            )
                            .background(
                                selection == candidate.workspaceID ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == candidate.workspaceID ? .isSelected : [])
                        .accessibilityIdentifier("host-attach-candidate-\(candidate.workspaceID)")
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: question.candidates.count <= 8)
            HStack(spacing: 12) {
                if question.isNewSessionOffered {
                    Button(HostWords.text(.newSession), action: startNew)
                        .accessibilityIdentifier("host-attach-question-new")
                }
                Spacer()
                Button(HostWords.text(.cancel), role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(HostWords.text(.attach)) {
                    if let candidate = question.candidates.first(where: { $0.workspaceID == selection }) {
                        choose(candidate)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
                .accessibilityIdentifier("host-attach-question-attach")
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460)
        .onAppear {
            // One candidate is a yes-or-no question, so it starts selected and
            // Return answers yes.
            if question.candidates.count == 1 {
                selection = question.candidates.first?.workspaceID
            }
        }
        .accessibilityIdentifier("host-attach-question")
    }
}
