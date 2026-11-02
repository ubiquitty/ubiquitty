// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

internal import UbiquittyCore

// The selection over a surface's terminal.
//
// Shared, and it names no view type at all: what a selection is — its anchor,
// its mode, the rules that extend it — is Core's, and both shells hold the same
// one. Only the gesture that begins it differs, and that lives with each
// shell's events.

final class SurfaceSelectionModel {
    let session: UnsafeMutablePointer<Ubiquitty.Selection.Session>

    /// Runs `body` against the Core selection state this model owns.
    ///
    /// The single place the state is handed to a Core call. This signature
    /// names `Ubiquitty.SelectionState` so the type stays imported: a member
    /// whose signature carries a C++ type is dropped from the module in any
    /// file that has not named that type, so callers reach the state through
    /// this rather than each spelling the C++ type out.
    @discardableResult
    func withState<Result>(_ body: (inout Ubiquitty.SelectionState) -> Result) -> Result {
        body(&session.pointee.state)
    }

    /// Runs `body` against the complete Core selection session this model owns.
    @discardableResult
    func withSession<Result>(_ body: (inout Ubiquitty.Selection.Session) -> Result) -> Result {
        body(&session.pointee)
    }

    /// The highlight spans of the last frame, reused so a steady selection
    /// allocates nothing per frame.
    var spanScratch: [Ubiquitty.Rendering.SelectionRowSpan] = []
    /// Where the last frame's selection begins and ends on screen, in
    /// viewport cells, for the touch shell's handles; nil when the frame drew
    /// none. The end's column is the last selected cell, inclusive.
    var visibleEnds: (start: (row: Int, column: Int), end: (row: Int, column: Int))?
    /// Where the selection falls inside rich text blocks, one entry a block,
    /// reused from frame to frame like the spans.
    var blockScratch: [Ubiquitty.RichText.BlockSelection] = []

    /// The overlay tiers Core collects from the live terminal, each reused for
    /// the same reason as ``spanScratch``: they are read on the frame path, and
    /// a per-frame array would allocate four times a frame for tiers that are
    /// empty most of the time.
    private var focusedSearchScratch: [Ubiquitty.Rendering.SelectionRowSpan] = []
    private var otherSearchScratch: [Ubiquitty.Rendering.SelectionRowSpan] = []
    private var triggerHighlightScratch: [Ubiquitty.Rendering.SelectionRowSpan] = []
    private var hiliteRegionScratch: [Ubiquitty.Rendering.SelectionRowSpan] = []

    /// Borrows the frame's overlay tiers while `body` captures and encodes them.
    ///
    /// The caller holds the terminal's model lock throughout this call. The
    /// options' overlay pointers are valid only during `body`, and must not
    /// escape it. Empty tiers always have a null pointer and a zero count.
    ///
    /// - Parameters:
    ///   - terminal: The live terminal the tiers are read from.
    ///   - viewOffset: Scrollback rows above the viewport.
    ///   - rows: The visible row count; zero suppresses all overlays.
    ///   - options: The capture options augmented for `body`.
    ///   - body: The synchronous consumer of the borrowed overlay spans.
    /// - Returns: The consumer's result.
    func withOverlayTiers<Result>(
        _ terminal: borrowing Ubiquitty.Terminal,
        viewOffset: Int32,
        rows: Int,
        options: borrowing Ubiquitty.Rendering.TerminalSnapshotOptions,
        _ body: (Ubiquitty.Rendering.TerminalSnapshotOptions) -> Result
    ) -> Result {
        let terminal = copy terminal
        var options = copy options
        options.searchMatchSpans = nil
        options.searchMatchSpanCount = 0
        options.otherSearchMatchSpans = nil
        options.otherSearchMatchSpanCount = 0
        options.triggerHighlightSpans = nil
        options.triggerHighlightSpanCount = 0
        options.hiliteRegionSpans = nil
        options.hiliteRegionSpanCount = 0
        guard rows > 0 else {
            return body(options)
        }

        // Search and trigger tiers may contain many disjoint spans on one row.
        // Their published entry counts bound the collectors without truncating
        // dense rows; only the DEC band is bounded by the terminal's row count.
        let searchCapacity = max(0, Int(Ubiquitty.Screen.ScrollSearch.segmentCount(terminal)))
        let triggerCapacity = max(0, Int(Ubiquitty.Triggers.highlightCount(terminal)))
        Self.growScratch(&focusedSearchScratch, capacity: searchCapacity)
        Self.growScratch(&otherSearchScratch, capacity: searchCapacity)
        Self.growScratch(&triggerHighlightScratch, capacity: triggerCapacity)
        Self.growScratch(&hiliteRegionScratch, capacity: max(0, Int(terminal.rows)))

        return focusedSearchScratch.withUnsafeMutableBufferPointer { focused in
            otherSearchScratch.withUnsafeMutableBufferPointer { other in
                triggerHighlightScratch.withUnsafeMutableBufferPointer { trigger in
                    hiliteRegionScratch.withUnsafeMutableBufferPointer { hilite in
                        let focusedCount = Ubiquitty.Rendering.collectSearchMatchRowSpans(
                            terminal,
                            viewOffset,
                            Ubiquitty.Rendering.OverlayRowSpans(focused)
                        )
                        options.searchMatchSpans = focusedCount > 0 ? UnsafePointer(focused.baseAddress) : nil
                        options.searchMatchSpanCount = focusedCount
                        if focusedCount > 0 {
                            let highlight = Ubiquitty.Rendering.focusedSearchMatchColor()
                            options.searchMatchHighlight = Ubiquitty.Rendering.Vec4(
                                x: highlight.red,
                                y: highlight.green,
                                z: highlight.blue,
                                w: highlight.alpha
                            )
                        }

                        let otherCount = Ubiquitty.Rendering.collectOtherSearchMatchRowSpans(
                            terminal,
                            viewOffset,
                            Ubiquitty.Rendering.OverlayRowSpans(other)
                        )
                        options.otherSearchMatchSpans = otherCount > 0 ? UnsafePointer(other.baseAddress) : nil
                        options.otherSearchMatchSpanCount = otherCount

                        let triggerCount = Ubiquitty.Rendering.collectTriggerHighlightRowSpans(
                            terminal,
                            viewOffset,
                            Ubiquitty.Rendering.OverlayRowSpans(trigger)
                        )
                        options.triggerHighlightSpans = triggerCount > 0 ? UnsafePointer(trigger.baseAddress) : nil
                        options.triggerHighlightSpanCount = triggerCount

                        let hiliteCount = Ubiquitty.Rendering.collectHiliteRegionRowSpans(
                            terminal,
                            viewOffset,
                            Ubiquitty.Rendering.OverlayRowSpans(hilite)
                        )
                        options.hiliteRegionSpans = hiliteCount > 0 ? UnsafePointer(hilite.baseAddress) : nil
                        options.hiliteRegionSpanCount = hiliteCount
                        return body(options)
                    }
                }
            }
        }
    }

    private static func growScratch(_ scratch: inout [Ubiquitty.Rendering.SelectionRowSpan], capacity: Int) {
        if scratch.count < capacity {
            scratch.append(contentsOf: repeatElement(Ubiquitty.Rendering.SelectionRowSpan(), count: capacity - scratch.count))
        }
    }

    init() {
        session = .allocate(capacity: 1)
        session.initialize(to: Ubiquitty.Selection.Session())
        Ubiquitty.Selection.`init`(&session.pointee)
    }

    deinit {
        session.deinitialize(count: 1)
        session.deallocate()
    }
}
