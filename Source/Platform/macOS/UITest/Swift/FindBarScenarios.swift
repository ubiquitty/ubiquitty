// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// FindBarScenarios.swift — ⌘F on a Kit-hosted window.
//
// The window connects UBFindBar to TerminalSurface+Search; each works alone,
// so this checks that ⌘F reaches both through the window.
//
// The assertion that matters is the inset. design.md 2.3 says the bar pushes
// the grid down rather than painting over its top rows, and the difference is
// not cosmetic: an overlay leaves the application writing to rows nobody can
// see, in exactly the region a search is usually about. A scenario that only
// checked the bar appeared would pass on the wrong implementation.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    terminalSurfaces(under: view).first
}

/// Every terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surfaces in hierarchy order.
@MainActor
private func terminalSurfaces(under view: NSView) -> [TerminalSurface] {
    var surfaces: [TerminalSurface] = []
    if let surface = view as? TerminalSurface {
        surfaces.append(surface)
    }
    for subview in view.subviews {
        surfaces.append(contentsOf: terminalSurfaces(under: subview))
    }
    return surfaces
}

/// Registers the find-bar scenarios with the UI-test runner.
enum FindBarScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_find_bar_insets_the_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                let rowsBefore = surface.publishedGrid.rows
                t.expect(rowsBefore > 0, desc: "the grid has rows before the bar opens (\(rowsBefore))")

                // Waited for rather than slept past. A pane re-grids when the
                // layout reaches it, which is a turn of the run loop and not a
                // fixed duration — a bar mounted into a split reaches the two
                // panes across separate passes, and under a full suite the
                // second one can land after any interval chosen here. Waiting
                // on the condition costs nothing when it already holds and
                // still fails when it never does — the distinction a sleep
                // cannot draw, since a pane that was slow and a pane that
                // never gives its rows up read the same to it.
                shell.performFindAction(nil)
                let insetTheGrid = t.wait(until: { surface.publishedGrid.rows < rowsBefore }, timeout: 10)

                // The bar is up, and the grid gave up rows for it — the second
                // clause is what separates an inset from an overlay.
                t.expect(
                    shell.findBar.superview != nil,
                    desc: "the find bar is mounted"
                )
                let rowsWithBar = surface.publishedGrid.rows
                t.expect(
                    insetTheGrid,
                    desc:
                        "the grid lost rows to the bar rather than being painted over (\(rowsBefore) -> \(rowsWithBar); "
                        + "surface \(surface.frame.height), host \(shell.paneHost.bounds.height), bar \(shell.findBar.frame.height))"
                )

                // And closing gives them back.
                shell.findBarClose()
                let gaveTheRowsBack = t.wait(until: { surface.publishedGrid.rows == rowsBefore }, timeout: 10)
                t.expect(
                    shell.findBar.superview == nil,
                    desc: "the bar is gone after Done"
                )
                t.expect(
                    gaveTheRowsBack,
                    desc: "and the grid has its rows back (\(surface.publishedGrid.rows))"
                )

                shell.splitRight(nil)
                t.expect(
                    t.wait(until: { terminalSurfaces(under: content).count == 2 }, timeout: 10),
                    desc: "a second pane opens for the split-layout control"
                )
                let splitPanes = terminalSurfaces(under: content)
                let splitRowsBefore = splitPanes.map { $0.publishedGrid.rows }
                shell.performFindAction(nil)
                // All the panes, not the first to answer: the assertion is that
                // the bar insets the whole layout, so the wait has to hold for
                // them at once, or a split that inset one pane of two passes.
                let everyPaneGaveRows = t.wait(
                    until: {
                        splitPanes.count == 2
                            && zip(splitPanes.map { $0.publishedGrid.rows }, splitRowsBefore)
                                .allSatisfy { $0 < $1 }
                    },
                    timeout: 10
                )
                let splitRowsWithBar = splitPanes.map { $0.publishedGrid.rows }
                t.expect(
                    everyPaneGaveRows,
                    desc: "every split pane gives rows to the bar (\(splitRowsBefore) -> \(splitRowsWithBar))"
                )
                shell.findBarClose()
                let everyPaneGotThemBack = t.wait(
                    until: { splitPanes.map { $0.publishedGrid.rows } == splitRowsBefore },
                    timeout: 10
                )
                t.expect(
                    everyPaneGotThemBack,
                    desc: "every split pane gets its rows back "
                        + "(\(splitRowsBefore) -> \(splitPanes.map { $0.publishedGrid.rows }))"
                )
            }
        }

        // The bar wears the theme and opens the way it was left.
        UBUITestRegister("swift_shell_find_bar_is_tinted_and_remembers_case") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let wasCaseSensitive = FindBarMemory.isCaseSensitive()
                defer { FindBarMemory.setCaseSensitive(wasCaseSensitive) }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                shell.performFindAction(nil)
                t.pump(0.4)

                // The band the tab strip and the pane bars wear: a bar in some
                // other colour reads as a piece of another window.
                let band = shell.chromeBandColor()
                t.expect(band != nil, desc: "the window can name its chrome band")
                let filled = shell.findBar.layer?.backgroundColor
                t.expect(filled != nil, desc: "the bar is filled at all")
                if let band, let filled {
                    t.expect(
                        filled == band.cgColor,
                        desc: "and filled with the band rather than something of its own"
                    )
                }

                // Case matching is remembered, so the next bar opens matching.
                t.expect(!shell.isFindCaseSensitive, desc: "the bar opens insensitive by default")
                shell.findBarSetCaseSensitive(true)
                t.expect(FindBarMemory.isCaseSensitive(), desc: "turning it on is remembered")

                guard let second = TerminalWindowController.spawn(), let secondWindow = second.window else {
                    t.expect(false, desc: "a second window opens")
                    return
                }
                defer { secondWindow.close() }
                second.performFindAction(nil)
                t.pump(0.4)
                t.expect(
                    second.isFindCaseSensitive,
                    desc: "and the next window's bar opens matching case"
                )
            }
        }

        UBUITestRegister("swift_shell_find_bar_searches_and_steps") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // Three occurrences of a term nothing else on screen carries.
                surface.feed(Data("alpha findme beta\r\nfindme again\r\nand findme once more\r\n".utf8))
                t.pump(0.3)

                shell.performFindAction(nil)
                t.pump(0.3)
                shell.findBar.query = "findme"
                shell.findBarQueryDidChange("findme")
                t.expect(
                    t.wait(
                        until: {
                            surface.searchStatus.isComplete
                                && shell.findBar.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "1 of 3" }
                        },
                        timeout: 10
                    ),
                    desc: "the async search updates the bar without more terminal output"
                )
                let status = surface.searchStatus
                t.expect(
                    status.totalMatches == 3,
                    desc: "the search found all three occurrences (\(status.totalMatches))"
                )

                // A program repainting the focused match's line in place, inside
                // a synchronized update, as a full-screen program redraws on
                // every keystroke. The rescan finds the match where it stood, so
                // the focus clock the pill's bounce and the reveal read stays
                // put, and the frames after it keep drawing the search tiers.
                let beforeRepaint = surface.drive.searchStatus
                surface.feed(Data("\u{1B}[?2026h\u{1B}[1A\r\u{1B}[2Kand findme once more\r\n\u{1B}[?2026l".utf8))
                let didRescan = t.wait(
                    until: {
                        let current = surface.drive.searchStatus
                        return current.isComplete && current.screenGeneration > beforeRepaint.screenGeneration
                    },
                    timeout: 10
                )
                t.expect(didRescan, desc: "the repaint was rescanned")
                let afterRepaint = surface.drive.searchStatus
                t.expect(
                    afterRepaint.foundCount == 3 && afterRepaint.activeIndex == beforeRepaint.activeIndex,
                    desc: "the repaint kept the count and the focus (\(afterRepaint.foundCount), \(afterRepaint.activeIndex))"
                )
                t.expect(
                    afterRepaint.activeEpoch == beforeRepaint.activeEpoch,
                    desc: "the repaint did not restart the pill's bounce (\(beforeRepaint.activeEpoch) -> \(afterRepaint.activeEpoch))"
                )
                t.expect(
                    afterRepaint.revealEpoch == beforeRepaint.revealEpoch,
                    desc: "nor owe a reveal (\(beforeRepaint.revealEpoch) -> \(afterRepaint.revealEpoch))"
                )
                t.expect(
                    t.wait(
                        until: {
                            surface.updateLayer()
                            return surface.didLastFrameDrawSearch
                        },
                        timeout: 5
                    ),
                    desc: "the frames after the synchronized repaint draw the search tiers"
                )

                // Stepping moves the active match, which is what Cmd-G does.
                let first = surface.findNextMatch().activeIndex
                let second = surface.findNextMatch().activeIndex
                t.expect(
                    first != second,
                    desc: "stepping moves the active match (\(first) -> \(second))"
                )

                shell.findBarClose()
                t.pump(0.3)
                // The handoff: the match the user was looking at survives the
                // bar closing, as a real selection they can copy.
                t.expect(
                    surface.hasSelection,
                    desc: "closing the bar left the focused match selected"
                )

                // ⌘E takes that selection as the next find term without the
                // bar being up, which is what makes ⌘E ⌘G a search you never
                // see a text field for.
                shell.findBar.query = ""
                shell.useSelectionForFind(nil)
                t.pump(0.3)
                t.expect(
                    !shell.findBar.query.isEmpty,
                    desc: "Cmd-E loaded the selection as the find term (\(shell.findBar.query))"
                )
            }
        }
    }
}
