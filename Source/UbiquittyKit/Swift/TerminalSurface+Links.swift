// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Links.swift — a link under the pointer: whether it is one,
// whether this click opens it, and what the pointer says about that.
//
// Every judgement here is Core's, so every arm answers alike. What counts as a link,
// and where a soft-wrapped one begins and ends, is `Screen::linkAtVisibleCell`.
// Whether the terminal may act locally while an application is reporting the
// mouse is `Input::allowsLocalLinkInteraction`. Whether a plain click may open
// this particular link is `Input::plainClickOpenableUnderReporting`. Which
// schemes may reach a handler at all is `LinkRun::isLaunchableURLScheme`, and
// which targets are the Welcome screen's own buttons, dispatched without one,
// is `App::Welcome::isActionURI`.
//
// That list is the point. Terminal output is attacker-controllable, so the
// question "does this text open something when clicked" has exactly one
// correct answer per build and it cannot be allowed to differ between two
// shells of the same application. None of it is re-decided here.
//
// The opening itself is the shell's, because only a shell knows what a URL
// means on its platform, and it arrives as ``linkOpener`` rather than being
// called directly — which is also what lets a scenario watch without launching
// anything.

import Foundation
internal import UbiquittyCore
package import UbiquittyRenderKit

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit

extension TerminalSurface {
    /// The modifiers held, as the facts Core's chord rules are asked of.
    ///
    /// A mask this surface matched itself would be a second answer to which
    /// modifier means which gesture; Core holds the one.
    internal static func heldModifiers(_ flags: NSEvent.ModifierFlags) -> Ubiquitty.Input.HeldModifiers {
        var held = Ubiquitty.Input.HeldModifiers()
        held.hasCommand = flags.contains(.command)
        held.hasControl = flags.contains(.control)
        held.hasAlternate = flags.contains(.option)
        held.hasShift = flags.contains(.shift)
        return held
    }

    /// The report-vs-local inputs for one pointer moment, answered by Core.
    ///
    /// One spelling, because two would answer differently: the link hover, the
    /// press routing and the crosshair all turn on the same question of whether
    /// this gesture stays local. A tmux `-CC` pane is not reported here — this
    /// surface does not yet know it is one — so on such a pane the answer is
    /// the ordinary terminal's.
    ///
    /// - Parameters:
    ///   - modifiers: What is down for the event asking.
    ///   - isBlockSelectionInFlight: Whether a rectangular drag is running.
    /// - Returns: The state, for `Input::allowsLocalLinkInteraction`,
    ///   `Input::allowsLocalDragSelect` and `Input::localDragIsRectangular`.
    internal func pointerReportingState(
        modifiers: NSEvent.ModifierFlags,
        isBlockSelectionInFlight: Bool = false
    ) -> Ubiquitty.Input.PointerReportingState {
        var moment = Ubiquitty.Input.PointerMoment()
        moment.held = Self.heldModifiers(modifiers)
        moment.isMouseReporting = drive.readSnapshot().mouseReportsActive
        moment.isBlockSelectionInFlight = isBlockSelectionInFlight
        return Ubiquitty.Input.pointerReportingState(
            moment,
            Ubiquitty.Input.pointerPolicyFromPreferences(Ubiquitty.Preferences.values().pointee)
        )
    }

    /// The same facts, for a question with no event behind it.
    ///
    /// The pointer image is asked for on edges a modifier press causes, and
    /// those carry no reliable modifier of their own, so the live ones are
    /// read.
    internal var pointerReportingState: Ubiquitty.Input.PointerReportingState {
        pointerReportingState(modifiers: NSEvent.modifierFlags)
    }
}
#endif

extension TerminalSurface {
    /// The link under a view point, if the terminal may act on one there.
    ///
    /// - Parameters:
    ///   - point: The point, in view coordinates.
    ///   - isCommandHeld: Whether Command is down for this event.
    /// - Returns: The link, or nil when there is none or the application owns
    ///   the pointer.
    internal func link(atViewPoint point: CGPoint, isCommandHeld: Bool) -> RuntimeDrive.ResolvedLink? {
        // The link gesture's one chord is Command, so the caller's claim about
        // it is the whole moment — and it is a claim rather than a reading of
        // the keyboard: the context menu asks as though Command were held,
        // because the reader chose the item by name.
        var moment = Ubiquitty.Input.PointerMoment()
        moment.held.hasCommand = isCommandHeld
        moment.isMouseReporting = drive.readSnapshot().mouseReportsActive
        let reporting = Ubiquitty.Input.pointerReportingState(
            moment,
            Ubiquitty.Input.pointerPolicyFromPreferences(Ubiquitty.Preferences.values().pointee)
        )
        // How much of the scan this event is worth is Core's: a bare hover
        // runs on every pointer move over any text, and the sweep it would
        // otherwise pay for exists to find what the program never declared.
        let probe = Ubiquitty.Input.linkProbe(
            reporting,
            Ubiquitty.Preferences.Effective.osc8ClickOpens(Ubiquitty.Preferences.values().pointee)
        )
        let scope: Ubiquitty.Screen.LinkScanScope
        switch probe {
        case .none:
            return nil
        case .declared:
            scope = .declared
        case .any:
            scope = .any
        @unknown default:
            return nil
        }
        // Strictly: the report path clamps, which is right for telling an
        // application which cell was pressed and wrong here. A pointer in the
        // padding is over no cell at all, and a hand offered for the cell it
        // clamps to is an affordance for something the pointer is not on.
        guard let cell = strictCell(atViewPoint: point) else { return nil }
        return drive.resolveLink(viewOffset: viewOffset, row: cell.row, column: cell.column, scope: scope)
    }

    /// Whether a click carrying these modifiers opens `link`.
    ///
    /// Command always does: the user asked for this one by name. Without it a
    /// connection scheme never does (`LinkRun::requiresLinkModifier`).
    ///
    /// Without it, what opens depends on who owns the pointer. On an ordinary
    /// screen a program's own OSC 8 declaration opens and a guess does not —
    /// the terminal read that text as a link, the program never said it was
    /// one, and acting on a reading unasked is how a click on someone's output
    /// launches something they did not write. Under mouse reporting with
    /// links_override_reporting, the terminal is keeping a click the
    /// application would otherwise have received, so the set it may spend that
    /// click on is narrower and Core names it:
    /// `Input::plainClickOpenableUnderReporting` admits a declared link of any
    /// kind and, among guesses, a strict http(s) URL only.
    ///
    /// - Parameters:
    ///   - link: The resolved link.
    ///   - isCommandHeld: Whether Command is down.
    /// - Returns: Whether to open it.
    internal func clickOpens(_ link: RuntimeDrive.ResolvedLink, isCommandHeld: Bool) -> Bool {
        if isCommandHeld {
            return true
        }
        // A connection to a host the program named (ssh, sftp, ftp, ftps)
        // opens only when the reader holds Command for it: Core's rule.
        if link.uri.withCString({ Ubiquitty.Attributes.LinkRun.requiresLinkModifier(std.string_view($0)) }) {
            return false
        }
        let configuration = Ubiquitty.Preferences.values().pointee
        guard Ubiquitty.Preferences.Effective.osc8ClickOpens(configuration) else {
            return false
        }
        let isReporting = drive.readSnapshot().mouseReportsActive
        let isOverrideEnabled = Ubiquitty.Preferences.Effective.linksOverrideReporting(configuration)
        guard isReporting, isOverrideEnabled else {
            // The ordinary case: only what the program itself declared.
            return link.isHyperlink
        }
        var candidate = Ubiquitty.Input.PlainOpenableLink()
        candidate.isOSC8 = link.isHyperlink
        candidate.isFile = link.isFilePath
        candidate.hasOpenableScheme = link.uri.withCString { Ubiquitty.Input.isOpenableURLScheme(std.string_view($0)) }
        return Ubiquitty.Input.plainClickOpenableUnderReporting(candidate)
    }
}

#if canImport(AppKit)
extension TerminalSurface {
    /// Opens a link if this click asks for it and the scheme is one a handler
    /// may be launched for.
    ///
    /// - Parameters:
    ///   - point: Where the click landed, in view coordinates.
    ///   - isCommandHeld: Whether Command is down.
    /// - Returns: Whether a link was opened, so the caller can swallow the
    ///   click rather than also selecting with it.
    @discardableResult
    package func openLink(atViewPoint point: CGPoint, isCommandHeld: Bool) -> Bool {
        guard let found = link(atViewPoint: point, isCommandHeld: isCommandHeld),
            clickOpens(found, isCommandHeld: isCommandHeld)
        else {
            return false
        }
        // A path candidate on a thin client names a file on the HOST, and this
        // machine's filesystem has nothing to say about it: stat'ing it here
        // either finds nothing or finds an unrelated local file of the same
        // name. It is asked of the host instead, and the answer lands later.
        if handleFileLink(found.uri, isPath: found.isFilePath) {
            return true
        }
        guard let opener = linkOpener else { return false }
        // A path candidate is not a URL: it becomes one only once a file is
        // found where it points, and until then there is nothing to open.
        let target = found.isFilePath ? fileURLString(forCandidate: found.uri) : found.uri
        guard let target else { return false }
        // The last gate, and the one that matters most: a scheme the build has
        // not sanctioned never reaches a handler, whatever the click said. A
        // Welcome screen button passes it because it reaches no handler at
        // all: the opener dispatches that namespace in-process and stops.
        let isOpenable = target.withCString {
            Ubiquitty.App.Welcome.isActionURI(std.string_view($0))
                || Ubiquitty.Attributes.LinkRun.isLaunchableURLScheme(std.string_view($0))
        }
        guard isOpenable else {
            return false
        }
        opener(target)
        openedLinksForTesting.append(target)
        return true
    }

    /// The `file://` URL a bare path candidate names, or nil when no file is
    /// there.
    ///
    /// Which path the candidate names is Core's
    /// (`LinkRun::resolveFilePathCandidate`), over the pane's own directory —
    /// which is already the reported-over-sampled answer Core arbitrates — and
    /// the host's home. What is left here is the filesystem, and it is touched
    /// on this path alone: a hover or a click that named the candidate, never
    /// the drain every printed line takes.
    ///
    /// - Parameter candidate: The text the link run matched.
    /// - Returns: The URL, or nil when the candidate names no existing file.
    private func fileURLString(forCandidate candidate: String) -> String? {
        let base = drive.currentDirectory() ?? ""
        let home = NSHomeDirectory()
        let resolved = candidate.withCString { rawCandidate in
            base.withCString { rawBase in
                home.withCString { rawHome in
                    String(
                        Ubiquitty.Attributes.LinkRun.resolveFilePathCandidate(
                            std.string_view(rawCandidate),
                            std.string_view(rawBase),
                            std.string_view(rawHome)
                        )
                    )
                }
            }
        }
        guard !resolved.isEmpty, FileManager.default.fileExists(atPath: resolved) else {
            return nil
        }
        return URL(fileURLWithPath: resolved).absoluteString
    }

    /// Whether the pointer at this point should show the link affordance.
    ///
    /// - Parameters:
    ///   - point: The point, in view coordinates.
    ///   - isCommandHeld: Whether Command is down.
    /// - Returns: Whether a click here would open something.
    package func pointerIsOverOpenableLink(atViewPoint point: CGPoint, isCommandHeld: Bool) -> Bool {
        guard !pointerIsHiddenForTyping,
            let found = link(atViewPoint: point, isCommandHeld: isCommandHeld)
        else {
            return false
        }
        guard clickOpens(found, isCommandHeld: isCommandHeld) else { return false }
        // A path candidate offers the hand only where a file actually is: the
        // affordance promises what the click would do, and a click on a path
        // that resolves to nothing does nothing.
        if found.isFilePath, drive.isRemoteAttached { return true }
        return found.isFilePath ? fileURLString(forCandidate: found.uri) != nil : true
    }

    /// Applies the affordance for a pointer at this point.
    ///
    /// The hand is set only when the answer CHANGES, because setting a cursor
    /// per motion event fights AppKit's own cursor-rect machinery and flickers.
    ///
    /// - Parameters:
    ///   - point: The point, in view coordinates.
    ///   - isCommandHeld: Whether Command is down.
    /// Re-resolves the affordance where the pointer actually is.
    ///
    /// For the two occasions with no reliable point of their own. A
    /// flags-changed event carries a `locationInWindow` that is not where the
    /// pointer is, and a drain has no location at all — but in both cases what
    /// is under the pointer has changed: the modifier decides whether a link
    /// opens, and output scrolls the grid beneath a pointer that never moved.
    ///
    /// Whether to ask at all is Core's `Input::shouldReResolveLinkHover`, over
    /// four facts only a view knows.
    internal func updateLinkAffordanceAtLivePointer() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        var facts = Ubiquitty.Input.HoverReResolveFacts()
        facts.isSelecting = isSelectionDragInFlight
        facts.isPointerHiddenForTyping = pointerIsHiddenForTyping
        facts.isWindowKey = window.isKeyWindow
        facts.isPointerInsideView = bounds.contains(point)
        guard Ubiquitty.Input.shouldReResolveLinkHover(facts) else { return }
        updateLinkAffordance(
            atViewPoint: point,
            isCommandHeld: NSEvent.modifierFlags.contains(.command)
        )
    }

    package func updateLinkAffordance(atViewPoint point: CGPoint, isCommandHeld: Bool) {
        let found = pointerIsHiddenForTyping ? nil : link(atViewPoint: point, isCommandHeld: isCommandHeld)
        // What the preview says is what a click would open, so a path
        // candidate is carried as the file URL it resolves to and dropped when
        // it resolves to none. The filesystem is only reached for a candidate a
        // click would act on, which for a bare path means Command is held.
        let openable = found.flatMap { clickOpens($0, isCommandHeld: isCommandHeld) ? $0 : nil }
        let target = openable.flatMap { $0.isFilePath ? fileURLString(forCandidate: $0.uri) : $0.uri }
        let hovered = target == nil ? nil : openable
        // The run is compared by where it sits rather than by identity: the
        // pointer moving one cell along the same link resolves a fresh value
        // describing the same run, and repainting for that would repaint on
        // every motion event over a link.
        if !isSameRun(hovered, hoveredLinkRun) {
            hoveredLinkRun = hovered
            publishHoverRunToBoundaryCapture()
            needsDisplay = true
            // The preview follows the run rather than the pointer: moving one
            // cell along the same link resolves the same target, and telling
            // the host again per motion event is what the comparison above is
            // for.
            hoveredLinkTarget = target
            observer?.terminalSurface(self, didChangeLinkPreview: target)
        }
        let isOverLink = hovered != nil
        // The document-style pointer's fact, refreshed on the same move: a link
        // outranks it, so it is only asked where none is hovered.
        let wasOverVoid = isPointerOverTextVoid
        isPointerOverTextVoid = !isOverLink && isPointerInTextVoid(atViewPoint: point)
        guard isOverLink != isShowingLinkAffordance || isPointerOverTextVoid != wasOverVoid else {
            return
        }
        isShowingLinkAffordance = isOverLink
        // Through the rect, not around it: a cursor set directly is replaced by
        // the rect's on the next move, which would put the I-beam back over an
        // application's own shape a moment after the hover ended.
        applyPointerCursor()
    }

    /// Whether the pointer sits past the end of its row's text.
    ///
    /// The read is a tried lock on the model, so a contended one keeps the
    /// answer already held rather than flickering the pointer under a flood.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: Whether there is nothing to select there.
    private func isPointerInTextVoid(atViewPoint point: CGPoint) -> Bool {
        guard let cell = reportCell(atViewPoint: point) else {
            return isPointerOverTextVoid
        }
        switch drive.pointerTextVoid(visibleRow: Int(cell.row), column: Int(cell.column), viewOffset: viewOffset) {
        case .empty:
            return true
        case .text:
            return false
        case .unknown:
            return isPointerOverTextVoid
        @unknown default:
            return isPointerOverTextVoid
        }
    }

    /// Drops the affordance and its accent.
    ///
    /// Called wherever the pointer stops meaning anything: typing hides it,
    /// focus leaves, the view goes away. A hover that survives any of those is
    /// an underline the user cannot explain.
    package func clearLinkAffordance() {
        if hoveredLinkRun != nil {
            hoveredLinkRun = nil
            publishHoverRunToBoundaryCapture()
            hoveredLinkTarget = nil
            needsDisplay = true
            observer?.terminalSurface(self, didChangeLinkPreview: nil)
        }
        guard isShowingLinkAffordance else { return }
        isShowingLinkAffordance = false
        applyPointerCursor()
    }

    /// Hands the resolved run to the session's boundary capture.
    ///
    /// The live route reads ``hoveredLinkRun`` off this surface as it assembles
    /// each frame, but the boundary route runs on the ingest thread inside the
    /// model lock and can read nothing of this view's, so the run has to be
    /// left where that capture can find it. Without it a boundary frame draws
    /// the link resting, and a program redrawing under synchronized output —
    /// which alternates the two routes — flickers the emphasis under a pointer
    /// that never moved.
    ///
    /// Called on both edges, the end of a hover included: an inactive run is
    /// what stops a boundary frame emphasising a link the pointer has left.
    private func publishHoverRunToBoundaryCapture() {
        var hover = Ubiquitty.Rendering.FrameHoverLink()
        if let run = hoveredLinkRun {
            hover.isActive = true
            hover.rowAbsoluteFirst = run.rowFirst
            hover.rowAbsoluteLast = run.rowLast
            hover.columnFirst = run.columnFirst
            hover.columnLast = run.columnLast
            hover.spanColumnFirst = run.spanColumnFirst
            hover.spanColumnLast = run.spanColumnLast
            hover.textDigest = run.textDigest
        }
        drive.setSyncFrameHoverLink(hover)
    }

    /// Whether two resolutions describe the same run on screen.
    ///
    /// - Parameters:
    ///   - lhs: One resolution, or nil.
    ///   - rhs: The other, or nil.
    /// - Returns: Whether they cover the same cells with the same target.
    private func isSameRun(_ lhs: RuntimeDrive.ResolvedLink?, _ rhs: RuntimeDrive.ResolvedLink?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let one?, let other?):
            return one.uri == other.uri && one.rowFirst == other.rowFirst && one.rowLast == other.rowLast
                && one.columnFirst == other.columnFirst && one.columnLast == other.columnLast
        default:
            return false
        }
    }
}
#endif

extension TerminalSurface {
    /// Handles file targets before any configured URL handler can run.
    /// Returns false only for ordinary URLs and existing local-file handling.
    @discardableResult
    package func handleFileLink(_ target: String, isPath: Bool) -> Bool {
        let isURI = target.withCString { Ubiquitty.Session.isFileLinkURI(std.string_view($0)) }
        guard isPath || isURI else { return false }
        guard drive.isRemoteAttached else {
            guard isURI else { return false }
            // Preserve the platform's local file URL spellings. A hostname
            // on an unconnected URI cannot authorize a remote connection.
            // This machine's name is the kernel's, read at the click, which is
            // what ls --hyperlink writes and what the opener checks the
            // authority against; ProcessInfo.hostName asks the resolver and
            // can answer another spelling, a .local or DNS name for the same machine.
            guard let url = URL(string: target), url.isFileURL else { return true }
            let authority = url.host ?? ""
            let localHost = String(Ubiquitty.PAL.systemHostName())
            let isLocal =
                authority.isEmpty || authority.caseInsensitiveCompare("localhost") == .orderedSame
                || (!localHost.isEmpty && authority.caseInsensitiveCompare(localHost) == .orderedSame)
            return !isLocal
        }
        guard drive.pendingFileDownloadToken == 0,
            let prompt = drive.prepareFileDownload(target, isURI: isURI, host: remoteFileHost, hostLabel: remoteFileHostLabel)
        else { return true }
        if let fileDownloadPromptHandler {
            fileDownloadPromptHandler(prompt)
        } else {
            #if canImport(AppKit)
            presentFileDownload(prompt)
            #else
            drive.answerFileDownload(prompt.token, download: false)
            #endif
        }
        return true
    }

    /// Answers the original pane's question rather than the currently focused pane.
    @discardableResult
    package func answerFileDownload(_ prompt: RuntimeDrive.FileDownloadPrompt, download: Bool) -> UInt32 {
        let requestID = drive.answerFileDownload(prompt.token, download: download)
        #if canImport(AppKit)
        if requestID != 0 { requestedHostFilesForTesting.append(prompt.path) }
        #endif
        return requestID
    }
}

#if canImport(AppKit)
extension TerminalSurface {
    /// Presents one native question without stacking over another sheet.
    private func presentFileDownload(_ prompt: RuntimeDrive.FileDownloadPrompt) {
        guard let window, window.attachedSheet == nil else {
            drive.answerFileDownload(prompt.token, download: false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Download this file?"
        alert.informativeText = "From \(prompt.host)"
        let pathView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 88))
        pathView.string = prompt.path
        pathView.isEditable = false
        pathView.isSelectable = true
        pathView.isRichText = false
        pathView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pathView.drawsBackground = false
        pathView.isVerticallyResizable = true
        pathView.isHorizontallyResizable = false
        pathView.maxSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        pathView.autoresizingMask = [.width]
        pathView.textContainer?.widthTracksTextView = true
        pathView.setAccessibilityLabel("File path")
        let scrollView = NSScrollView(frame: pathView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = pathView
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Download")
        fileDownloadAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self else { return }
            if self.fileDownloadAlert === alert { self.fileDownloadAlert = nil }
            self.answerFileDownload(prompt, download: response == .alertSecondButtonReturn)
        }
    }

    /// Retires presentation as soon as its connection invalidates the question.
    internal func dismissStaleFileDownloadPrompt() {
        guard drive.pendingFileDownloadToken == 0, let alert = fileDownloadAlert else { return }
        fileDownloadAlert = nil
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
    }
}
#endif

#if canImport(UIKit)
extension TerminalSurface {
    /// Applies Core's link-versus-mouse-report policy to a touch or hardware click.
    ///
    /// A touch carries no modifier, so a tap never opens an ssh, sftp, ftp or
    /// ftps link (`LinkRun::requiresLinkModifier`): it hands a connection to a
    /// host the program named, and a tap is also how a reader focuses the
    /// pane. The edit menu's Open Link asks as though Command were held,
    /// because the reader chose it by name, and a Command-click from a
    /// hardware keyboard holds it.
    ///
    /// - Parameters:
    ///   - point: Where the touch or click landed, in view coordinates.
    ///   - modifiers: The modifiers held, none for a touch.
    /// - Returns: Whether a link was opened, so the caller spends the tap on it.
    internal func openLink(atViewPoint point: CGPoint, modifiers: SurfaceModifiers) -> Bool {
        guard let found = link(atViewPoint: point, isCommandHeld: modifiers.hasCommand),
            clickOpens(found, isCommandHeld: modifiers.hasCommand)
        else { return false }
        if handleFileLink(found.uri, isPath: found.isFilePath) { return true }
        guard !found.isFilePath,
            found.uri.withCString({ Ubiquitty.Attributes.LinkRun.isLaunchableURLScheme(std.string_view($0)) }),
            let url = URL(string: found.uri), !url.isFileURL
        else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
#endif
