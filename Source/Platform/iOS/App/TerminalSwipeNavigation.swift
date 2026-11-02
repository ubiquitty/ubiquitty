// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import UbiquittyCore

/// Which way a sideways swipe moves through an ordered list.
///
/// Leftward is next: the content moves the way the finger does, so what comes
/// into view is what was to the right of it.
enum SwipeStep: Equatable {
    case next
    case previous
}

/// Where a sideways swipe lands: which workspace pane, which connection.
///
/// Decided on plain lists rather than inside the model or the view, so the
/// wrap and the single-entry answer can be checked without a host to switch
/// between.
enum TerminalSwipeNavigation {
    /// What a workspace swipe says when there is no other pane.
    static let onlyOnePaneNotice = "Only one pane"

    /// What a workspace swipe says before any panes have been listed.
    static let noPanesNotice = "No panes available"

    /// What a connection swipe says when there is no other connection.
    static let onlyOneConnectionNotice = "Only one connection"

    /// The entry beside `current` in `ordered`, wrapping at both ends.
    ///
    /// - Parameters:
    ///   - current: Where the reader is, or nil when nowhere in the list.
    ///   - ordered: The entries, in the order a swipe walks them; no repeats.
    ///   - step: Which way to walk.
    /// - Returns: The neighbour, or nil when there is no other entry to move to.
    ///   A current entry missing from the list walks in from the end the step
    ///   faces: the first entry for next, the last for previous.
    static func neighbor<Entry: Equatable>(of current: Entry?, in ordered: [Entry], step: SwipeStep) -> Entry? {
        guard let index = current.flatMap({ ordered.firstIndex(of: $0) }) else {
            return step == .next ? ordered.first : ordered.last
        }
        guard ordered.count > 1 else { return nil }
        let offset = step == .next ? 1 : ordered.count - 1
        return ordered[(index + offset) % ordered.count]
    }

    /// The neighbouring pane, including siblings within the same tab.
    ///
    /// - Parameters:
    ///   - activePaneID: The focused pane.
    ///   - panes: The workspace's panes in window, tab and visual tree order.
    ///   - step: Which neighbour.
    /// - Returns: The pane to focus, or nil when there is no other pane.
    static func paneDestination(from activePaneID: UInt32, among panes: [TerminalPane], step: SwipeStep) -> TerminalPane? {
        guard let destination = neighbor(of: activePaneID, in: panes.map(\.id), step: step) else { return nil }
        return panes.first { $0.id == destination }
    }

    /// Reads a tab's leaves in first-child-before-second-child display order.
    ///
    /// Pool indices are allocation order, which changes when a pane is split
    /// or removed; they do not describe the order shown to the person.
    ///
    /// - Parameter tree: The authoritative tab tree.
    /// - Returns: Pane identities from left/top to right/bottom.
    static func paneIDs(in tree: Ubiquitty.Panes.Tree) -> [UInt32] {
        var pending = [tree.root()]
        var result: [UInt32] = []
        while let index = pending.popLast() {
            guard index >= 0, index < Ubiquitty.Panes.maxNodes else { continue }
            let node = tree.node(index)
            if tree.isLeaf(index) {
                result.append(UInt32(node.paneID))
            } else {
                pending.append(node.second)
                pending.append(node.first)
            }
        }
        return result
    }

    /// Where a connection swipe goes, and whose model names it.
    ///
    /// - Parameters:
    ///   - current: The connection that was swiped.
    ///   - hosts: Every saved host, in host-list order.
    ///   - isOpen: Whether a host has a connection under way; only those are walked.
    ///   - step: Which neighbour.
    /// - Returns: The destination, or none when no other connection is open.
    static func connectionSwitch<ID: Equatable>(
        from current: ID,
        hosts: [ID],
        isOpen: (ID) -> Bool,
        step: SwipeStep
    ) -> ConnectionSwitch<ID> {
        let destination = neighbor(of: current, in: hosts.filter(isOpen), step: step)
        return ConnectionSwitch(destination: destination, announcedOn: destination ?? current)
    }

    /// The line a connection swipe shows on arrival: the host's name, and which
    /// of its sessions this is when the model can say.
    ///
    /// - Parameters:
    ///   - hostName: The saved host's display name.
    ///   - sessionSummary: The model's sentence for its session, empty when it has none.
    /// - Returns: The notice.
    static func connectionNotice(hostName: String, sessionSummary: String) -> String {
        sessionSummary.isEmpty ? hostName : "\(hostName) · \(sessionSummary)"
    }
}

/// The answer to a connection swipe.
struct ConnectionSwitch<ID: Equatable>: Equatable {
    /// The connection to open, or nil to stay where the reader is.
    let destination: ID?
    /// The connection whose model carries the notice. The destination's, because the screen
    /// that opens draws that model and the swiped screen is gone by the time it would show; the
    /// swiped one's when there is nowhere to go.
    let announcedOn: ID
}
