// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Terminal context stays attached to its originating pane. Search publications
// carry durable destinations, resolved when a palette action runs.

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// Swift-native replacements for the retired UBBeamBlock / UBBeamMatch @objc DTOs.

struct BeamBlock {
    let command: String
    let absoluteRow: Int
    let statusGlyph: String // "✗" when the command failed, else empty
}

struct BeamMatch {
    let line: String
    let absoluteRow: Int
    let column: Int
    let position: Ubiquitty.Screen.LogicalPosition
}

struct BeamTabDestination {
    let title: String
    let index: Int
    let isCurrent: Bool
}

/// Where an intent from a window's focused pane lands, Core's classification.
///
/// An alias because `Protocol` after a type parses as the metatype suffix in
/// expression position, and the alias is the spelling that crosses both.
typealias BeamPaneContext = Ubiquitty.`Protocol`.Tmux.PaneContext

/// An intent a reader asks of the focused pane by meaning, Core's vocabulary.
typealias BeamPaneIntent = Ubiquitty.`Protocol`.Tmux.ActionIntent

/// What the palette asks of the window it was summoned over.
///
/// Both shells answer it, so no palette path names a controller class: a
/// dismissal hands the keyboard back, restyles the chrome it covered and runs
/// a keyboard-only action, and a pane-intent command asks where the focused
/// pane's input lands and performs the intent there.
@MainActor
protocol BeamTerminalHost: AnyObject {
    /// Hands the keyboard back to the terminal when the responder the
    /// palette saved is gone.
    func restoreFocusAfterBeam()

    /// Repaints the title bar and tab strip the palette covered.
    func restoreChromeAfterBeam()

    /// Runs a keyboard-only action on the focused pane.
    ///
    /// - Parameter token: The action's name in Core's key catalog.
    func performBeamKeyAction(named token: String)

    /// Where an intent from the focused pane lands, Core's classification.
    var beamPaneContext: BeamPaneContext { get }

    /// What the session hosting this tab calls its window, for a rename's
    /// prefill; empty for a window no session names.
    var beamHostedWindowName: String { get }

    /// Performs an intent on the focused pane over whatever transport its
    /// input takes.
    ///
    /// - Parameters:
    ///   - intent: What the reader picked.
    ///   - value: The new name for a rename; ignored otherwise.
    /// - Returns: Whether anything was sent.
    func performBeamPaneIntent(_ intent: BeamPaneIntent, value: String) -> Bool
}

extension TerminalWindowController: BeamTerminalHost {
    var beamPaneContext: BeamPaneContext { tmuxPaneContext() }

    var beamHostedWindowName: String { tmuxWindowName }

    func performBeamPaneIntent(_ intent: BeamPaneIntent, value: String) -> Bool {
        performTmuxIntent(intent, value: value)
    }
}

/// Keeps palette operations attached to the terminal that opened it.
@MainActor
final class BeamTerminalContext {
    private weak var controller: NSWindowController?
    private weak var surface: TerminalSurface?

    init?(_ controller: NSWindowController?) {
        guard let controller,
            controller is TerminalWindowController
        else { return nil }
        self.controller = controller
        surface = (controller as? TerminalWindowController)?.beamSurface
    }

    func withTerminal(_ body: (Ubiquitty.Terminal?, UInt64) -> Void) {
        if let surface, surface.window === controller?.window {
            surface.drive.withTerminal { body($0, $0.modelEpoch) }
        }
    }

    func markDirty() {
        if let surface {
            surface.needsDisplay = true
        }
    }

    func beamScroll(toAbsoluteRow row: Int) {
        if let shell = controller as? TerminalWindowController, let surface {
            shell.revealBeamRow(row, in: surface)
        }
    }

    /// Tests whether a publication belongs to this palette's attached pane.
    ///
    /// - Parameter candidate: The publishing surface.
    /// - Returns: Whether it is the originating pane, still in its window.
    func ownsSearchPublication(from candidate: TerminalSurface) -> Bool {
        surface === candidate && candidate.window === controller?.window
    }

    /// Queues the palette query on its originating pane.
    ///
    /// - Parameters:
    ///   - query: The text to find.
    ///   - isRegex: Whether the text is a search expression.
    ///   - limit: The maximum number of labels requested.
    ///   - range: The inclusive row range, or nil for the whole buffer.
    func beginFind(_ query: String, isRegex: Bool, limit: Int, range: ClosedRange<Int>?) {
        guard let surface, surface.window === controller?.window else { return }
        _ = surface.drive.setPaletteSearchQuery(
            query,
            isRegex: isRegex,
            firstRow: range?.lowerBound ?? -1,
            lastRow: range?.upperBound ?? -1,
            labelLimit: limit
        )
    }

    /// The current query's available labels and action destinations.
    var findMatches: [BeamMatch] {
        guard let surface, surface.window === controller?.window else { return [] }
        return surface.drive.searchLabels.map {
            BeamMatch(line: String($0.text), absoluteRow: Int($0.absoluteRow), column: Int($0.column), position: $0.position)
        }
    }

    /// The shared counter wording, or nil after the pane leaves its window.
    var findStatusText: String? {
        guard let surface, surface.window === controller?.window else { return nil }
        let status = surface.searchStatus
        return String(Ubiquitty.Runtime.searchCounterText(status.totalMatches, -1, status.isPatternInvalid, status.isComplete))
    }

    /// Reveals a result's text if it still exists.
    ///
    /// - Parameter position: The destination captured with the result.
    func beamScroll(to position: Ubiquitty.Screen.LogicalPosition) {
        guard let shell = controller as? TerminalWindowController, let surface else { return }
        shell.revealBeamPosition(position, in: surface)
    }

    /// Cancels the palette query and drops its transient highlights.
    func clearFind() {
        guard let surface, surface.window === controller?.window else { return }
        surface.drive.clearScrollbackSearch()
        surface.needsDisplay = true
    }

    private var tabs: [NSWindow] {
        guard let window = controller?.window else { return [] }
        let siblings = window.tabGroup?.windows ?? []
        return siblings.isEmpty ? [window] : siblings
    }

    func beamTabs() -> [BeamTabDestination] {
        tabs.enumerated()
            .map { index, window in
                BeamTabDestination(
                    title: window.tab.title ?? window.title,
                    index: index,
                    isCurrent: window === controller?.window
                )
            }
    }

    func beamSelectTab(at index: Int) {
        let siblings = tabs
        guard siblings.indices.contains(index) else { return }
        let window = siblings[index]
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func beamPanes() -> [BeamPaneDestination] {
        if let shell = controller as? TerminalWindowController {
            return shell.beamPaneDestinations()
        }
        return []
    }

    func beamFocusPane(_ identifier: Int) {
        if let shell = controller as? TerminalWindowController {
            shell.focusPane(withIdentifier: identifier)
        }
    }
}

@MainActor
enum BeamTerminalProviders {
    // Bound the captured-output copy so a runaway block can't stall the
    // palette. The BLOCK bound is Ubiquitty.Screen.maxCommandBlocks: two
    // frontends offering "the command blocks" have to offer the same ones.

    // OSC-133 command blocks, newest first. Core walks the marks; the glyph is
    // the frontend's choice, so Core reports the failure and this picks how it
    // reads.
    static func commandBlocks(_ controller: BeamTerminalContext) -> [BeamBlock] {
        var out: [BeamBlock] = []
        controller.withTerminal { term, _ in
            guard let term else { return }
            for block in Ubiquitty.Screen.commandBlocks(term, Ubiquitty.Screen.maxCommandBlocks) {
                out.append(
                    BeamBlock(
                        command: String(block.command),
                        absoluteRow: Int(block.promptRow),
                        statusGlyph: block.didFail ? "✗" : ""
                    )
                )
            }
        }
        return out
    }

    // The newest command block's output row span (from, to), or nil when there is
    // no OSC-133 command block (no shell integration). Beam's "Last output" scope.
    static func lastBlockRange(_ controller: BeamTerminalContext) -> (from: Int, to: Int)? {
        var result: (Int, Int)?
        controller.withTerminal { term, _ in
            guard let term else { return }
            let span = Ubiquitty.Screen.lastCommandOutputRows(term)
            if span.isFound {
                result = (Int(span.from), Int(span.to))
            }
        }
        return result
    }

    // The captured OUTPUT text of the command block whose executed prompt sits at
    // `absoluteRow`: the rows after the typed command line down to the row before
    // the next executed prompt (or buffer end), trailing blank lines dropped. Empty
    // when the row isn't a command or produced no output.
    static func blockOutput(_ controller: BeamTerminalContext, absoluteRow: Int) -> String {
        var result = ""
        controller.withTerminal { term, _ in
            guard let term else { return }
            result = String(
                Ubiquitty.Screen.commandBlockOutput(
                    term,
                    Int32(absoluteRow),
                    Int32(Ubiquitty.Screen.maxCommandOutputRows)
                )
            )
        }
        return result
    }

    // Queues the scoped query and reads its available labels. SearchChanged
    // refreshes the list as more arrive; a replacement has no old labels.
    static func findMatches(
        _ controller: BeamTerminalContext,
        query: String,
        isRegex: Bool,
        limit: Int,
        range: ClosedRange<Int>? = nil
    ) -> [BeamMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            controller.beginFind("", isRegex: false, limit: 0, range: nil)
            return []
        }
        controller.beginFind(query, isRegex: isRegex, limit: limit, range: range)
        return controller.findMatches
    }

    // Drop any find highlight left by findMatches (Beam's find scope is transient).
    static func clearFind(_ controller: BeamTerminalContext) {
        controller.clearFind()
    }
}
