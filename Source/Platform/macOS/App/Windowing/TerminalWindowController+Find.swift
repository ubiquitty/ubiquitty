// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Find.swift — ⌘F on a Kit-hosted window.
//
// The connection between two pieces that each stand alone. `UBFindBar` lays
// itself out and reports intent through a delegate; `TerminalSurface+Search`
// runs the search, steps matches and hands the last one over as a selection.
// The controller is the bar's delegate and drives the surface's search.
//
// The one rule worth stating, because it is a design decision and not a
// layout detail: the bar INSETS the grid rather than painting over it
// (design.md 2.3). Overlaying would hide the top rows of the very output the
// user is searching, and the rows a search is about are usually the ones a
// bar would cover.

import AppKit
internal import UbiquittyCore

extension TerminalWindowController: UBFindBarDelegate {
    /// The bar's height, and so the grid's inset while it is up.
    static let findBarHeight: CGFloat = 28.0

    /// Edit > Find… — raise the bar, focus its field, re-run any query it kept.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func performFindAction(_ sender: Any?) {
        showFindBar()
    }

    /// Edit > Find Next — ⌘G.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func findNext(_ sender: Any?) {
        findBarFindNext()
    }

    /// Edit > Find Previous — ⇧⌘G.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func findPrevious(_ sender: Any?) {
        findBarFindPrevious()
    }

    /// Edit > Use Selection for Find — ⌘E.
    ///
    /// Loads the selection as the term without raising the bar, which is what
    /// makes ⌘E then ⌘G a search without ever seeing a text field.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func useSelectionForFind(_ sender: Any?) {
        guard let text = focusedPaneSurface?.selectedText, !text.isEmpty else { return }
        findBar.query = text
        runSearch(text)
    }

    /// Raises the bar and insets the grid under it.
    func showFindBar() {
        if findBar.superview == nil {
            findBar.findDelegate = self
            // Opened the way it was last left: a reader who turned case
            // matching on meant searching, not searching in that window.
            isFindCaseSensitive = FindBarMemory.isCaseSensitive()
            findBar.setCaseSensitive(isFindCaseSensitive)
            paneHost.addSubview(findBar)
        }
        applyThemeToFindBar()
        findBarInset = Self.findBarHeight
        layoutContentAndFindBar()
        findBar.focusField(inWindow: window)
        let query = findBar.query
        if !query.isEmpty {
            runSearch(query)
        }
    }

    /// Drops the bar and gives the grid its rows back.
    func hideFindBar() {
        guard findBarInset != 0 else { return }
        findBarInset = 0
        // The surface hands the focused match over as a selection before it
        // drops the highlights, so the match stays where the user left it.
        focusedPaneSurface?.clearSearch()
        findBar.removeFromSuperview()
        layoutContentAndFindBar()
        if let surface = focusedPaneSurface {
            window?.makeFirstResponder(surface)
        }
    }

    /// Lays the bar across the top and the panes below it.
    ///
    /// The bar and the panes are SIBLINGS inside the host, and the panes are
    /// what shrinks. The host is the window's own content view — AppKit owns
    /// its frame — so insetting the host is a resize the window undoes,
    /// silently: the bar appears, the grid loses rows, and closing never gives
    /// them back because the host never really moved.
    func layoutContentAndFindBar() {
        let bounds = paneHost.bounds
        findBar.frame = NSRect(
            x: 0,
            y: bounds.height - findBarInset,
            width: bounds.width,
            height: findBarInset
        )
        findBar.autoresizingMask = [.width, .minYMargin]
        relayoutPanesForInsetChange()
    }

    /// Re-lays the model's pane tree, or else what the focused pane stands
    /// in under the host — the single surface, or a hosted layout's mirror of
    /// its host's tree — into the space the bar left it.
    ///
    /// Explicitly rather than by autoresizing: a proportional mask does not
    /// return the height it gave up when the region shrinks and grows again,
    /// and a find bar that costs a row every time it opens eats the screen.
    private func relayoutPanesForInsetChange() {
        let available = NSRect(
            x: 0,
            y: 0,
            width: paneHost.bounds.width,
            height: paneHost.bounds.height - findBarInset
        )
        if surfaces.count > 1 {
            rebuildPaneLayout()
            return
        }
        guard let surface = focusedPaneSurface else { return }
        var paneRoot: NSView = surface
        while let parent = paneRoot.superview, parent !== paneHost {
            paneRoot = parent
        }
        guard paneRoot.superview === paneHost else { return }
        paneRoot.frame = available
        paneRoot.layoutSubtreeIfNeeded()
    }

    /// Runs a query against the focused surface and shows the count.
    ///
    /// - Parameter query: The term, as typed.
    private func runSearch(_ query: String) {
        guard let surface = focusedPaneSurface else { return }
        guard !query.isEmpty else {
            surface.clearSearch()
            findBar.setStatus("")
            return
        }
        let status = surface.setSearchQuery(query, isRegex: isFindRegex, isCaseSensitive: isFindCaseSensitive)
        findBar.setStatus(Self.statusText(status))
    }

    /// Refreshes the bar from a publication belonging to its focused pane.
    ///
    /// - Parameter surface: The pane whose search changed.
    func surfaceDidChangeSearch(_ surface: TerminalSurface) {
        TerminalSurface.beamPresenter?.searchDidChange?(surface)
        guard surface === focusedPaneSurface, findBar.superview != nil, !findBar.query.isEmpty else { return }
        findBar.setStatus(Self.statusText(surface.searchStatus))
    }

    /// The count the bar shows, in the shape a person reads.
    ///
    /// - Parameter status: What the search answered.
    /// - Returns: The label text.
    private static func statusText(_ status: TerminalSurface.SearchStatus) -> String {
        String(Ubiquitty.Runtime.searchCounterText(status.totalMatches, status.activeIndex, status.isPatternInvalid, status.isComplete))
    }

    // MARK: - UBFindBarDelegate

    /// The query changed as the user typed: search again, live.
    ///
    /// - Parameter query: The new term.
    public func findBarQueryDidChange(_ query: String) {
        runSearch(query)
    }

    /// Step to the next match.
    public func findBarFindNext() {
        guard let surface = focusedPaneSurface else { return }
        findBar.setStatus(Self.statusText(surface.findNextMatch()))
    }

    /// Step to the previous match.
    public func findBarFindPrevious() {
        guard let surface = focusedPaneSurface else { return }
        findBar.setStatus(Self.statusText(surface.findPreviousMatch()))
    }

    /// Done, or Esc.
    public func findBarClose() {
        hideFindBar()
    }

    /// The regex toggle flipped; re-run so the answer matches the switch.
    ///
    /// - Parameter on: Whether the term is a regular expression.
    public func findBarSetRegex(_ on: Bool) {
        isFindRegex = on
        runSearch(findBar.query)
    }

    /// The case toggle flipped.
    ///
    /// - Parameter on: Whether the search is case-sensitive.
    public func findBarSetCaseSensitive(_ on: Bool) {
        isFindCaseSensitive = on
        FindBarMemory.setCaseSensitive(on)
        runSearch(findBar.query)
    }

    /// Fills the bar with the theme's chrome band, the tint the tab strip
    /// and the inactive pane bars wear.
    ///
    /// Re-applied on every theme change: the bar is a band of chrome across
    /// the top of the grid, and one left in the previous theme's colour reads
    /// as a piece of another window.
    package func applyThemeToFindBar() {
        guard findBar.superview != nil, let band = chromeBandColor() else { return }
        findBar.applyTint(band)
    }
}
