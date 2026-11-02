// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

/// Which of a workspace's panes a wide window shows together, and where.
///
/// A regular-width window — the inner display of iPhone Duo, an iPad, a large
/// iPhone turned sideways — has room for two terminals, and the Human
/// Interface Guidelines ask a larger display to show one more level of what the
/// smaller one shows one at a time. The layout itself is the system's
/// `ArrangementView`, which places the two side by side or one above the other
/// and moves them clear of the fold. What is decided here is which two panes
/// they are, and that decision is kept stable on purpose: focusing a pane
/// already on screen moves nothing, because a terminal that jumps to the other
/// side of the display on a tap is one a person loses track of.
///
/// Pane identifiers are the host's, as `TerminalSessionModel` lists them.
enum TerminalPaneArrangement {
    /// The most panes shown together.
    static let capacity = 2

    /// Chooses the nearest surviving neighbor when the focused pane closes.
    ///
    /// - Parameters:
    ///   - focused: The pane that lost its place.
    ///   - previous: The pane order before the layout change.
    ///   - available: The host's current pane order.
    /// - Returns: A surviving neighbor, or the first available pane.
    static func replacementFocus(for focused: UInt32, previous: [UInt32], available: [UInt32]) -> UInt32? {
        if let index = previous.firstIndex(of: focused) {
            let neighbors = previous.dropFirst(index + 1) + previous.prefix(index).reversed()
            if let neighbor = neighbors.first(where: { available.contains($0) }) { return neighbor }
        }
        return available.first
    }

    /// Returns the panes to show after focusing one.
    ///
    /// A pane already shown keeps its place. A pane that is not shown takes the
    /// place of the one that was not focused, so the pane a person was working
    /// in stays beside the one they asked for. Panes the host no longer lists
    /// are dropped, and an empty place is filled with the first listed pane not
    /// already shown.
    ///
    /// - Parameters:
    ///   - shown: The panes shown now, in their places.
    ///   - focusing: The pane being focused.
    ///   - previouslyFocused: The pane that had focus before, if any.
    ///   - available: The panes the host lists, in its order.
    /// - Returns: At most ``capacity`` panes, in their places, including
    ///   `focusing` whenever the host lists it.
    static func arrangement(
        after shown: [UInt32],
        focusing: UInt32,
        previouslyFocused: UInt32?,
        available: [UInt32]
    ) -> [UInt32] {
        var result = shown.filter { available.contains($0) }
        if available.contains(focusing), !result.contains(focusing) {
            if result.count < capacity {
                result.append(focusing)
            } else {
                var replaced = result.count - 1
                if let kept = previouslyFocused, let keptIndex = result.firstIndex(of: kept) {
                    replaced = keptIndex == 0 ? 1 : 0
                }
                result[replaced] = focusing
            }
        }
        for candidate in available where result.count < capacity && !result.contains(candidate) {
            result.append(candidate)
        }
        return Array(result.prefix(capacity))
    }
}
