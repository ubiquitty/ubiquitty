// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittyCore
import UbiquittyKit

// Find in scrollback. The search is Core's: the worker publishes results to
// the focused pane's session, the matches reach the renderer through
// the model and are drawn in the grid by the same capture that draws every
// cell, and the active match is revealed by the placement every frontend's
// find jumps with. This is the bar that asks, and the counter in Core's words.

/// What one search of the scrollback answered.
struct TerminalFindStatus: Equatable {
    let totalMatches: Int
    let activeIndex: Int
    let isPatternInvalid: Bool
    let isComplete: Bool

    /// The counter beside the field, in Core's words: "3 of 12", "No matches".
    var counter: String {
        String(Ubiquitty.Runtime.searchCounterText(totalMatches, activeIndex, isPatternInvalid, isComplete))
    }

    init(_ status: TerminalSurface.SearchStatus) {
        totalMatches = status.totalMatches
        activeIndex = status.activeIndex
        isPatternInvalid = status.isPatternInvalid
        isComplete = status.isComplete
    }
}

extension TerminalSessionModel {
    /// Puts the find bar up over the focused pane.
    func beginFind() {
        isFindingInScrollback = true
    }

    /// Searches the focused pane's scrollback afresh, live as the query is
    /// typed; an empty query clears the matches.
    ///
    /// - Parameter query: The text to find, verbatim and case-insensitive.
    func find(_ query: String) {
        guard let pane = focusedSurface else { return }
        if let previous = findSurface, previous !== pane { previous.clearSearch() }
        findSurface = pane
        guard !query.isEmpty else {
            pane.clearSearch()
            findStatus = nil
            return
        }
        findStatus = TerminalFindStatus(pane.setSearchQuery(query))
    }

    /// Steps to the next match, wrapping past the last.
    func findNext() {
        guard let pane = findSurface, findStatus != nil else { return }
        findStatus = TerminalFindStatus(pane.findNextMatch())
    }

    /// Steps to the previous match, wrapping past the first.
    func findPrevious() {
        guard let pane = findSurface, findStatus != nil else { return }
        findStatus = TerminalFindStatus(pane.findPreviousMatch())
    }

    /// Takes the find bar down. The active match stays selected, so the place
    /// the search reached can be copied.
    func endFind() {
        findSurface?.clearSearch()
        findSurface = nil
        findStatus = nil
        isFindingInScrollback = false
    }
}

/// The find bar, above the keyboard and the bottom bar: a field, the counter,
/// the previous and next matches, and the close button.
struct TerminalFindBar: View {
    let session: TerminalSessionModel
    @State
    private var query = ""
    @FocusState
    private var isFieldFocused: Bool
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    private var hasMatches: Bool { (session.findStatus?.totalMatches ?? 0) > 0 }

    var body: some View {
        // At the accessibility sizes the field takes a row of its own, so the
        // query is not squeezed to a few letters beside the buttons.
        let layout =
            dynamicTypeSize >= .accessibility1
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            field
            HStack(spacing: 4) {
                Button {
                    session.findNext()
                } label: {
                    Label("Next Match", systemImage: "chevron.up")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!hasMatches)
                .accessibilityIdentifier("find-next")
                Button {
                    session.findPrevious()
                } label: {
                    Label("Previous Match", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!hasMatches)
                .accessibilityIdentifier("find-previous")
                // Closes the bar and commits nothing: the active match stays
                // selected. Outside a bar the close role draws its title, so
                // the glyph is given and the glass drawn as a bar draws it.
                Button(role: .close) {
                    session.endFind()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("find-done")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: query) { _, text in session.find(text) }
        .onChange(of: session.activePaneID) { _, _ in session.find(query) }
        .onAppear { isFieldFocused = true }
        .sensoryFeedback(.selection, trigger: session.findStatus?.activeIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in Scrollback")
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in Scrollback", text: $query)
                .focused($isFieldFocused)
                .submitLabel(.search)
                .onSubmit { session.findNext() }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("find-field")
            if let status = session.findStatus {
                Text(status.counter)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(status.isPatternInvalid ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("find-counter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: Capsule())
    }
}

/// The hardware keyboard's find commands: Command-F puts the bar up,
/// Command-G and Command-Shift-G step through the matches.
@MainActor
enum TerminalFindCommands {
    static var commands: [UIKeyCommand] {
        let action = #selector(TerminalKeyInputView.performFindCommand(_:))
        return [
            UIKeyCommand(title: "Find in Scrollback", action: action, input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Find Next", action: action, input: "g", modifierFlags: .command),
            UIKeyCommand(title: "Find Previous", action: action, input: "g", modifierFlags: [.command, .shift]),
        ]
        .map { command in
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    /// Does what one of the commands asks.
    ///
    /// - Parameters:
    ///   - command: The command pressed.
    ///   - session: The workspace it acts on.
    static func perform(_ command: UIKeyCommand, on session: TerminalSessionModel) {
        switch (command.input, command.modifierFlags.contains(.shift)) {
        case ("f", _): session.beginFind()
        case ("g", false): session.isFindingInScrollback ? session.findNext() : session.beginFind()
        case ("g", true): session.isFindingInScrollback ? session.findPrevious() : session.beginFind()
        default: break
        }
    }
}
