// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+TmuxHosting.swift — the shell hosts a tmux window: every
// pane is an adopting surface over the Core session's Terminal (the same
// model the deliver path writes, under the same lock), input wraps through
// the -CC primary via the session's routing, and the layout mirrors tmux's
// own tree. The tmux controller resolves each pane's adoption facts from the
// Core session it owns and binds them here; this side holds views, no tmux
// state.
//
// The window-level verbs ride the same route. Every pane's session reaches the
// -CC control channel, so a verb about the whole tmux session (close it,
// report the window's size, perform a Beam intent) is asked of one pane's
// session, and the command it sends is Core's.

import AppKit
internal import UbiquittyCore
package import UbiquittyRenderKit

// The namespace through a type alias: `Protocol` after a type parses as the
// metatype suffix in expression position, and the alias is the spelling that
// crosses both positions.
private typealias TmuxProtocol = Ubiquitty.`Protocol`.Tmux

/// The model a tmux pane's surface adopted, and the lock it reads that model
/// under.
struct TmuxAdoption: Equatable {
    /// The session pane's terminal.
    let terminal: UnsafeMutableRawPointer
    /// The address of that pane's content lock.
    let lockAddress: UInt
}

/// One pane of one attached session.
///
/// Two concurrently attached -CC sessions each number their panes from %0, so a
/// pane id names a pane in both; the session it is numbered in is the rest of
/// the name, and what keeps one session's bind from taking the other's routing.
private struct TmuxPaneKey: Hashable {
    let sessionAddress: UInt
    let paneID: Int32
}

/// The grid a window reports to tmux as its control client's size.
struct TmuxClientGrid: Equatable {
    var columns: Int
    var rows: Int
}

extension TerminalWindowController {
    /// Shows the control terminal and focuses its authentication prompt.
    package func showTmuxAuthentication() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(focusedSurface)
    }

    /// The directories Core searches a tool in, for this process's `PATH`.
    package static var toolSearchDirectories: [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .withCString { Ubiquitty.Network.toolSearchDirectories(std.string_view($0)).map { String($0) } }
    }

    /// Resolves a tool by name across Core's search directories without
    /// running a shell.
    ///
    /// - Parameter name: The executable's name.
    /// - Returns: The first executable match, or nil when there is none.
    package static func resolveTool(named name: String) -> String? {
        toolSearchDirectories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Resolves the local tmux executable without running a shell.
    package static var tmuxExecutable: String? { resolveTool(named: "tmux") }

    /// Spawns a window that hosts one tmux window's panes.
    ///
    /// The window opens empty; the controller binds panes and applies the
    /// layout the same way it replays a cached `%layout-change`.
    ///
    /// - Returns: The controller, or nil when the renderer cannot be built.
    @objc
    public static func spawnTmuxHostingWindow() -> TerminalWindowController? {
        spawnTmuxHostingWindow(tabbingIdentity: "")
    }

    /// Spawns a tmux window into its session's own tab group.
    ///
    /// Two concurrently attached sessions each pass their own identity, so
    /// AppKit's automatic tabbing groups a session's windows together and
    /// never merges one session's tabs into another's.
    ///
    /// - Parameter tabbingIdentity: The session's tab-group key; empty joins
    ///   the default group.
    @objc
    public static func spawnTmuxHostingWindow(tabbingIdentity: String) -> TerminalWindowController? {
        guard let controller = spawnEmptyForTmux() else {
            return nil
        }
        if !tabbingIdentity.isEmpty {
            controller.window?.tabbingIdentifier = tabbingIdentity
        }
        spawnedControllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    /// Binds an adopting, primary-routed surface to one tmux pane.
    ///
    /// The terminal and lock are the Core session pane's — the same model
    /// the deliver path writes, under the same lock — and input wraps for
    /// the pane through the -CC primary. Binding a pane already bound to the
    /// same model is a no-op, which is what lets every layout pass re-list its
    /// panes.
    ///
    /// Binding it to another model is a retarget, and a retarget builds a new
    /// surface rather than pointing the old one elsewhere. What a surface knows
    /// about its model — the frame it last drew, the scrollback count its next
    /// drain compares against, the link under the pointer, the lock it reads
    /// under — was learned from that model, and a surface carried across would
    /// show rows of the pane that left and read the new growth against the old
    /// count. Nothing of it can outlive the surface, so the old surface ends
    /// its adoption and goes, and the next layout mirror mounts the new one.
    ///
    /// A closed window binds nothing: its panes were released as it closed.
    ///
    /// - Parameters:
    ///   - paneID: The tmux pane id.
    ///   - terminal: The session pane's terminal.
    ///   - lockAddress: The pane's content lock's address.
    ///   - rows: The pane's grid rows, the server's authority.
    ///   - columns: The pane's grid columns, likewise.
    ///   - clientAddress: The primary's tmux client's address.
    ///   - streamAddress: The control channel stream's address.
    ///   - sessionAddress: The attached session this pane is numbered in, as an
    ///     address that is one value for all of a session's panes and another
    ///     for every concurrently attached session.
    /// - Returns: Whether the pane is bound after the call.
    @objc
    @discardableResult
    public func bindTmuxPane(
        _ paneID: Int32,
        terminal: UnsafeMutableRawPointer,
        lockAddress: UInt,
        rows: Int,
        columns: Int,
        clientAddress: UInt,
        streamAddress: UInt,
        sessionAddress: UInt
    ) -> Bool {
        guard !isWindowClosed else {
            return false
        }
        let adoption = TmuxAdoption(terminal: terminal, lockAddress: lockAddress)
        let key = TmuxPaneKey(sessionAddress: sessionAddress, paneID: paneID)
        if let previous = Self.hostsByPane[key], previous !== self,
            previous.tmuxAdoptions[paneID] == adoption,
            let moved = previous.tmuxSurfaces.removeValue(forKey: paneID)
        {
            previous.tmuxAdoptions.removeValue(forKey: paneID)
            previous.tmuxSessionAddresses.removeValue(forKey: paneID)
            tmuxSurfaces[paneID] = moved
            tmuxAdoptions[paneID] = adoption
            tmuxSessionAddresses[paneID] = sessionAddress
            Self.hostsByPane[key] = self
            adoptTransferredSurface(moved)
            return true
        }
        if tmuxSurfaces[paneID] != nil {
            if tmuxAdoptions[paneID] == adoption {
                return true
            }
            unbindTmuxPane(paneID)
        }
        guard
            let surface = TerminalSurface.makeAdopting(
                terminal: terminal,
                lockAddress: lockAddress,
                rows: rows,
                columns: columns
            )
        else {
            return false
        }
        surface.renderer = windowRenderer
        surface.observer = windowBridge
        surface.drive.routeInputViaTmux(clientAddress: clientAddress, streamAddress: streamAddress, paneID: paneID)
        tmuxSurfaces[paneID] = surface
        tmuxAdoptions[paneID] = adoption
        tmuxSessionAddresses[paneID] = sessionAddress
        Self.hostsByPane[TmuxPaneKey(sessionAddress: sessionAddress, paneID: paneID)] = self
        // The tmux mirror lays panes out itself, so the bar takes the window's
        // shape here rather than from a pane layout.
        applyScrollerBottomInset(to: surface)
        return true
    }

    /// Unbinds a vanished pane's surface — before the Core session frees
    /// the terminal it adopted.
    ///
    /// - Parameter paneID: The tmux pane id.
    @objc
    public func unbindTmuxPane(_ paneID: Int32) {
        // This pane's own slot: the key carries the session it was bound for,
        // so the window another attached session holds under the same pane id
        // keeps its registration.
        if let sessionAddress = tmuxSessionAddresses.removeValue(forKey: paneID) {
            let key = TmuxPaneKey(sessionAddress: sessionAddress, paneID: paneID)
            if Self.hostsByPane[key] === self { Self.hostsByPane.removeValue(forKey: key) }
        }
        tmuxAdoptions.removeValue(forKey: paneID)
        guard let surface = tmuxSurfaces.removeValue(forKey: paneID) else {
            return
        }
        // End the adoption here, not in deinit: the surface's deallocation can
        // be deferred (an autorelease, an in-flight drain hop), and the owner
        // retires the terminal as soon as this returns. A session still reading
        // the adopted pointers past that is a use of freed memory from its own
        // teardown.
        surface.drive.endAdoption()
        surface.removeFromSuperview()
        // A session of this process hosts the pane: it frees a pane the
        // program retired only once no view reads it.
        hostingSurface?.drive.releaseHostedPane(paneID)
    }

    /// Unbinds every pane this window hosts.
    ///
    /// For a window the reader closed: tmux still has the window, so no
    /// `%window-close` arrives to unbind them, and each surface would go on
    /// reading a model the session frees whenever tmux next retires it.
    func releaseTmuxPanes() {
        for paneID in boundTmuxPaneIDs() {
            unbindTmuxPane(paneID)
        }
    }

    /// Every window hosting tmux panes, keyed by the panes they hold and the
    /// sessions those panes are numbered in.
    ///
    /// A render-only pane's output arrives on the control channel's thread and
    /// is repainted from the main hop that follows, which knows the pane and
    /// the session it was delivered for. The registry is what turns that pair
    /// back into the window showing the pane.
    private static var hostsByPane: [TmuxPaneKey: TerminalWindowController] = [:]

    /// How many times a pane here has been repainted by the deliver flush.
    ///
    /// The wiring is what this counts: a render-only pane has no other way to
    /// be told its output landed, so a zero here means the hop is not reaching
    /// this shell at all.
    package private(set) static var tmuxRepaintsForTesting = 0

    /// Repaints the pane this id names in this session, if a window here is
    /// showing it.
    ///
    /// Called from the deliver flush's main hop: a render-only pane runs no
    /// ingest loop, so nothing else asks it to draw, and its published modes
    /// go stale — which the input and pointer paths read. Without this the
    /// pane repaints only when something else happens to ask, which is the
    /// lag a reader sees as typing arriving late.
    ///
    /// - Parameters:
    ///   - paneID: The tmux pane id whose output just landed.
    ///   - sessionAddress: The session that delivered it, the address its panes
    ///     were bound under.
    /// - Returns: Whether a window here took it.
    @objc
    @discardableResult
    public static func repaintTmuxPane(_ paneID: Int32, sessionAddress: UInt) -> Bool {
        guard
            let host = hostsByPane[TmuxPaneKey(sessionAddress: sessionAddress, paneID: paneID)],
            let surface = host.tmuxSurfaces[paneID]
        else {
            return false
        }
        // The modes first, then the frame: the input and pointer paths read
        // the published snapshot, and a frame drawn against the previous one
        // would show the pane a keystroke ago.
        surface.drive.republishSnapshot()
        surface.needsDisplay = true
        surface.refreshScrollbackChrome()
        // What the pane's program asked of the window — a verb, a banner, a
        // trigger — was queued on the pane's own session by the output that
        // just landed, and no drain of its own reports it.
        surface.serviceIngestEvents()
        // Nor does a screen update: the chrome follows the palette the output
        // may have moved from here.
        host.restyleChromeIfColorsMoved(on: surface)
        Self.tmuxRepaintsForTesting += 1
        return true
    }

    /// The surface a bound pane draws into, for a scenario that watches it
    /// paint.
    ///
    /// - Parameter paneID: A bound pane id.
    /// - Returns: Its surface, or nil when nothing is bound to that id.
    package func tmuxSurfaceForTesting(_ paneID: Int32) -> TerminalSurface? {
        tmuxSurfaces[paneID]
    }

    /// The bound pane ids, for the controller's reconcile pass.
    ///
    /// - Returns: Every pane id a surface is bound to.
    @objc
    public func boundTmuxPaneIDs() -> [Int32] {
        Array(tmuxSurfaces.keys)
    }

    /// Mirrors one tmux layout string into the window: Core's grammar
    /// parses it, and the split structure lands as split views with ratios
    /// from the reported cell rects — tmux owns the geometry, this side
    /// only reflects it. Panes must be bound first.
    ///
    /// - Parameters:
    ///   - layout: The `%layout-change` payload.
    ///   - activePaneID: The pane to focus, or a negative value to keep.
    /// - Returns: Whether the layout parsed.
    @objc
    @discardableResult
    public func applyTmuxLayoutMirror(_ layout: String, activePaneID: Int32) -> Bool {
        var root = TmuxProtocol.LayoutNode()
        guard TmuxProtocol.parseLayoutTree(layout, layout.utf8.count, &root) else {
            return false
        }
        guard let host = window?.contentView else {
            return false
        }
        transferTree = Ubiquitty.Panes.Tree(TmuxProtocol.leftmostPaneID(root))
        TmuxProtocol.buildPaneTreeInto(&transferTree, root)
        if activePaneID >= 0 { _ = transferTree.focusPane(activePaneID) }
        host.subviews.forEach { $0.removeFromSuperview() }
        let mirrored = mirrorTmuxNode(root)
        mirrored.frame = host.bounds
        mirrored.autoresizingMask = [.width, .height]
        host.addSubview(mirrored)
        // Every pane's chrome is new and shows no report, and the pane count
        // the slots are partitioned by may have moved.
        syncProgressChrome()
        if activePaneID >= 0, let focused = tmuxSurfaces[activePaneID] {
            window?.makeFirstResponder(focused)
        }
        // The window opened empty, so its first chrome paint had no pane to
        // take the theme from; it takes it from the pane it now shows.
        if let active = activeSurface {
            restyleChromeIfColorsMoved(on: active)
        }
        // This window's own grid: the attach reported the hidden control
        // window's, and tmux laid the session out to that until told otherwise.
        reportTmuxClientGrid()
        PaneTransferCoordinator.shared.hostedLayoutDidChange(self)
        return true
    }

    /// Whether this window shows a tmux window's panes.
    var isHostingTmux: Bool {
        !tmuxSurfaces.isEmpty
    }

    /// The pane a tmux verb from this window is about.
    ///
    /// The pane with the keyboard, else the hosted pane the reader was last
    /// in: a palette summoned over the window holds the keyboard while its
    /// command runs, and the intent it carries is still about the pane under
    /// it. A hosted window with neither answers its lowest pane, and a window
    /// of local sessions its model's focused pane.
    var tmuxIntentSurface: TerminalSurface? {
        if let responder = window?.firstResponder as? TerminalSurface {
            return responder
        }
        if let last = lastFocusedTmuxSurface, tmuxSurfaces.values.contains(where: { $0 === last }) {
            return last
        }
        if let lowest = tmuxSurfaces.keys.min() {
            return tmuxSurfaces[lowest]
        }
        return focusedSurface
    }

    /// Where a tmux intent from this window lands, read by the pane's session
    /// from its route and its live process table.
    ///
    /// - Returns: The focused pane's tmux context, Core's classification.
    package func tmuxPaneContext() -> Ubiquitty.`Protocol`.Tmux.PaneContext {
        tmuxIntentSurface?.drive.tmuxPaneContext() ?? .nativePane
    }

    /// Performs a tmux intent on the focused pane, over whichever transport
    /// its input takes. The target is that pane, not the window's first: in a
    /// split window the two differ, and a split or a kill lands where the
    /// reader is.
    ///
    /// A full-screen `tmux attach` takes its chord as the reader's own
    /// typing, through the surface's user-input route: the selection drops,
    /// a pane with SRM reset echoes the bytes, and "Broadcast Input" fans
    /// them to the panes listening. Writing them straight to the host does
    /// none of the three. The -CC channel's commands are not typing and stay
    /// the session's to send.
    ///
    /// - Parameters:
    ///   - intent: What the reader asked for.
    ///   - value: The new name for a rename; ignored otherwise.
    /// - Returns: Whether anything was sent. False for a native pane, whose
    ///   own menu action applies instead.
    @discardableResult
    package func performTmuxIntent(_ intent: Ubiquitty.`Protocol`.Tmux.ActionIntent, value: String = "") -> Bool {
        guard let surface = tmuxIntentSurface else {
            return false
        }
        // Non-empty only for a raw attach, which is the one context whose
        // bytes are keystrokes.
        let chord = surface.drive.tmuxIntentKeystrokes(intent, value: value)
        guard chord.isEmpty else {
            surface.transmitAsUserInput(chord)
            return true
        }
        return surface.drive.performTmuxIntent(intent, value: value)
    }

    /// Confirms a close of this tmux window, with separate session-wide choices.
    /// The server's reply removes the affected views after it accepts the command.
    ///
    /// - Parameter window: The window being closed.
    func confirmTmuxWindowClose(_ window: NSWindow) {
        guard let surface = tmuxIntentSurface, hostedWindowID >= 0 else { return }
        let windowID = hostedWindowID
        let isTab = (window.tabGroup?.windows.count ?? 1) > 1
        let closeTitle = isTab ? "Close Tab" : "Close Window"
        let alert = NSAlert()
        alert.messageText = isTab ? "Close tmux Tab?" : "Close tmux Window?"
        alert.informativeText =
            "\(closeTitle) ends the processes in this tmux window. Other windows stay connected. Detach keeps the whole session running; Kill Session ends all its windows."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let close = alert.addButton(withTitle: closeTitle)
        close.hasDestructiveAction = true
        close.keyEquivalent = ""
        alert.addButton(withTitle: "Detach").keyEquivalent = ""
        let kill = alert.addButton(withTitle: "Kill Session")
        kill.hasDestructiveAction = true
        kill.keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self, weak surface] response in
            guard let self, !self.isWindowClosed, self.hostedWindowID == windowID, let surface,
                self.tmuxSurfaces.values.contains(where: { $0 === surface })
            else { return }
            switch response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
            case 1:
                surface.drive.requestTmuxWindowClose(windowID)
            case 2:
                surface.drive.requestTmuxSessionClose(.detach)
            case 3:
                surface.drive.requestTmuxSessionClose(.kill)
            default:
                break
            }
        }
    }

    /// Reports this window's grid to tmux as its control client's size, when
    /// it has moved since the last report.
    ///
    /// The whole content, not the focused pane: tmux tiles the client's size
    /// across the window's panes itself, and the session sizes to its latest
    /// client, so a tile's grid would shrink every window of the session to
    /// one tile. The other tabs of the session follow through tmux: the new
    /// size re-lays every window of the session, and each window's
    /// `%layout-change` re-sizes its panes in the session model before this
    /// shell mirrors it.
    func reportTmuxClientGrid() {
        guard let grid = tmuxClientGrid(), grid != reportedTmuxClientGrid, let surface = tmuxIntentSurface else {
            return
        }
        if surface.drive.reportTmuxClientSize(columns: grid.columns, rows: grid.rows) {
            reportedTmuxClientGrid = grid
        }
    }

    /// The grid this window's content holds at a hosted pane's cell size.
    ///
    /// Core's fit, with that pane's cell and insets over the whole content:
    /// the division a single pane makes over its own bounds, made over the
    /// window's.
    ///
    /// - Returns: The grid, or nil for a window with no hosted pane or no
    ///   measured cell yet.
    func tmuxClientGrid() -> TmuxClientGrid? {
        guard let host = window?.contentView,
            let surface = tmuxSurfaces.keys.min().flatMap({ tmuxSurfaces[$0] }),
            let renderer = surface.renderer
        else {
            return nil
        }
        let cell = renderer.cellSize(for: surface)
        guard cell.width > 0, cell.height > 0, host.bounds.width > 0, host.bounds.height > 0 else {
            return nil
        }
        let insets = renderer.gridFitInsets(for: surface)
        var request = Ubiquitty.Rendering.GridFitRequest()
        request.insets.left = Float(insets.left)
        request.insets.right = Float(insets.right)
        request.insets.top = Float(insets.top)
        request.insets.bottom = Float(insets.bottom)
        request.viewport.width = Float(host.bounds.width)
        request.viewport.height = Float(host.bounds.height)
        request.cell.width = Float(cell.width)
        request.cell.height = Float(cell.height)
        let grid = Ubiquitty.Rendering.fitGridToViewport(request)
        guard grid.columns > 0, grid.rows > 0 else {
            return nil
        }
        return TmuxClientGrid(columns: Int(grid.columns), rows: Int(grid.rows))
    }

    /// The client size this window last reported, for a scenario comparing it
    /// with what the server applied.
    package var reportedTmuxClientGridForTesting: (columns: Int, rows: Int)? {
        reportedTmuxClientGrid.map { ($0.columns, $0.rows) }
    }

    /// Shows the session's pill in the title row, or renames the one standing.
    func applyTmuxSessionBadge() {
        guard let bar = windowAccessoryBar else {
            return
        }
        TmuxSessionBadge.setSession(tmuxSessionName, in: bar)
    }

    /// The session pill in this window's title row, for a scenario that reads
    /// what it names and how it is painted.
    package var tmuxSessionBadgeForTesting: TmuxSessionBadge? {
        windowAccessoryBar.flatMap { TmuxSessionBadge.badge(in: $0) }
    }

    private func mirrorTmuxNode(_ node: TmuxProtocol.LayoutNode) -> NSView {
        if node.isLeaf() {
            guard let surface = tmuxSurfaces[node.paneID] else { return NSView(frame: .zero) }
            let chrome = PaneChrome(
                paneID: node.paneID,
                target: self,
                closeAction: #selector(closeHostedPaneFromChrome(_:)),
                expandAction: #selector(zoomHostedPaneFromChrome(_:))
            )
            chrome.showsTitleBar = showsPaneTitleBars
            chrome.contentView = surface
            chrome.apply(
                title: NSAttributedString(string: "Pane \(node.paneID)"),
                background: .windowBackgroundColor,
                tint: .labelColor,
                isExpanded: false
            )
            return chrome
        }
        let split = NSSplitView(frame: .zero)
        split.dividerStyle = .thin
        split.isVertical = node.split == .Columns
        for child in node.children {
            split.addArrangedSubview(mirrorTmuxNode(child))
        }
        split.layoutSubtreeIfNeeded()
        // Divider positions from the children's cell extents: tmux's
        // authority, restated as fractions of this node's span.
        let total = node.split == .Columns ? Double(node.width) : Double(node.height)
        let extent = split.isVertical ? Double(split.bounds.width) : Double(split.bounds.height)
        if total > 0, extent > 0 {
            var running = 0.0
            for (index, child) in node.children.enumerated() where index < node.children.count - 1 {
                running += node.split == .Columns ? Double(child.width) : Double(child.height)
                split.setPosition(extent * (running / total), ofDividerAt: index)
            }
        }
        return split
    }

    @objc
    private func closeHostedPaneFromChrome(_ sender: NSButton) {
        _ = tmuxSurfaces[Int32(sender.tag)]?.drive.requestPaneVerb(.close)
    }

    @objc
    private func zoomHostedPaneFromChrome(_ sender: NSButton) {
        _ = tmuxSurfaces[Int32(sender.tag)]?.drive.requestPaneVerb(.zoom)
    }
}
