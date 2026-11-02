// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Search.swift — the find bar's seam. The whole search is
// Core's: the worker publishes matches and progress through the session,
// the match spans reach the renderer through the model, and the reveal
// placement is the shared rule every frontend's find jumps with. This side
// applies each reveal once and repaints on SearchChanged. Both shells' find
// bars come through here: the macOS bar above the grid and the iOS bar above
// the keyboard.

internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalSurface {
    /// The find bar's last publication: counts, progress, and pattern validity.
    public struct SearchStatus: Equatable {
        /// Logical matches found; zero for a cleared or failed search.
        public let totalMatches: Int
        /// The active match, zero-based; -1 when none is.
        public let activeIndex: Int
        /// Whether the pattern failed to compile — the bar's warning state.
        public let isPatternInvalid: Bool
        /// Whether the count is final for this scan.
        public let isComplete: Bool
    }

    /// The search's current counts and progress, without taking the model lock.
    public var searchStatus: SearchStatus {
        let status = drive.searchStatus
        return SearchStatus(
            totalMatches: Int(status.foundCount),
            activeIndex: Int(status.activeIndex),
            isPatternInvalid: status.isPatternInvalid,
            isComplete: status.isComplete
        )
    }

    /// Starts a search and returns the pending state; publications notify the observer.
    ///
    /// - Parameters:
    ///   - pattern: The query; empty clears the search.
    ///   - isRegex: Whether the pattern is the search's own regex grammar
    ///     rather than verbatim text.
    ///   - isCaseSensitive: Whether case distinguishes.
    /// - Returns: What the find bar shows.
    @discardableResult
    public func setSearchQuery(_ pattern: String, isRegex: Bool = false, isCaseSensitive: Bool = false) -> SearchStatus {
        guard drive.setSearchQuery(pattern, form: isRegex ? .regex : .literal, sensitivity: isCaseSensitive ? .Sensitive : .Insensitive)
        else {
            return searchStatus
        }
        return SearchStatus(totalMatches: 0, activeIndex: -1, isPatternInvalid: false, isComplete: pattern.isEmpty)
    }

    /// Searches in slices and waits for a result, for automation and snapshots.
    ///
    /// - Parameters:
    ///   - pattern: The query; empty clears.
    ///   - isRegex: Whether the query is an RE2 expression.
    ///   - isCaseSensitive: Whether case distinguishes.
    ///   - timeoutMilliseconds: The wait bound.
    /// - Returns: The current status; incomplete if the wait expired.
    @discardableResult
    public func searchScrollbackAndWait(
        _ pattern: String,
        isRegex: Bool = false,
        isCaseSensitive: Bool = false,
        timeoutMilliseconds: UInt32 = 30_000
    ) -> SearchStatus {
        applySearchOutcome(
            drive.searchScrollbackAndWait(
                pattern,
                form: isRegex ? .regex : .literal,
                sensitivity: isCaseSensitive ? .Sensitive : .Insensitive,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    }

    /// Steps to the next match, wrapping past the last.
    ///
    /// - Returns: What the find bar shows.
    @discardableResult
    public func findNextMatch() -> SearchStatus {
        applySearchOutcome(drive.stepSearchMatch(.forward))
    }

    /// Steps to the previous match, wrapping past the first.
    ///
    /// - Returns: What the find bar shows.
    @discardableResult
    public func findPreviousMatch() -> SearchStatus {
        applySearchOutcome(drive.stepSearchMatch(.backward))
    }

    /// Drops the search — the bar closed.
    ///
    /// The focused match is handed over as a real selection first, so it stays
    /// highlighted and copyable once the transient find highlights go. Closing
    /// a find bar should not lose the user's place.
    public func clearSearch() {
        selectionModel.withState { drive.handOffActiveSearchMatch(into: &$0) }
        drive.clearScrollbackSearch()
        needsDisplay = true
    }

    /// Moves the viewport where the outcome says and repaints; the spans are
    /// already on the model.
    @discardableResult
    func applySearchOutcome(_ outcome: Ubiquitty.Search.Status) -> SearchStatus {
        if outcome.generation != lastSearchRevealGeneration || outcome.revealEpoch != lastSearchRevealEpoch {
            lastSearchRevealGeneration = outcome.generation
            lastSearchRevealEpoch = outcome.revealEpoch
            if outcome.revealViewOffset >= 0 {
                setViewOffset(absolute: Int(outcome.revealViewOffset))
            }
        }
        needsDisplay = true
        frameClock.noteAnimationActivity()
        return SearchStatus(
            totalMatches: Int(outcome.foundCount),
            activeIndex: Int(outcome.activeIndex),
            isPatternInvalid: outcome.isPatternInvalid,
            isComplete: outcome.isComplete
        )
    }
}
