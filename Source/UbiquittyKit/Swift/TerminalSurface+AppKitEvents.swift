// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)

import AppKit
internal import UbiquittyCore

// The surface's AppKit event handling.
//
// Split from the surface itself because this is the one part of it that is
// genuinely per-platform. A mouse with a scroll wheel, a trackpad with
// momentum and modifier keys reported as flag changes have no counterpart on
// a touch screen — the UIKit shell answers touches and UIKeyInput instead,
// and neither shell should carry the other's event model.
//
// Everything above this line in TerminalSurface is shared: the grid, the
// geometry, the drive, the chrome and the drawing. What differs is how a
// gesture arrives, which is why only the arrival moved.

extension TerminalSurface {
    // MARK: - AppKit view lifecycle
    //
    // Each of these is AppKit's name for an edge the surface already knows
    // how to answer; the body lives once, in the surface.

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        surfaceDidMoveToWindow()
    }

    override public func viewDidHide() {
        super.viewDidHide()
        surfaceDidChangeVisibility()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        surfaceDidChangeVisibility()
    }

    override public func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        // The drag is activity in its own right: a full-screen program's
        // reflow lands milliseconds after each step, off the main thread,
        // and the redraw it would ask for does not fire in AppKit's
        // resize-tracking run-loop mode. Keeping the clock running for the
        // drag is what draws that fill within a frame of its arriving
        // rather than at the next mouse move.
        drive.notePresentationActivity()
        if !drive.isPresentationContinuous {
            frameClock.resume()
        }
        // The drag presents transactionally so each step's bounds change and
        // the frame drawn for it reach the compositor together.
        metalLayer.presentsWithTransaction = true
        frameLink?.synchronizePresentationMode()
        liveResizeStartWindowFrame = window?.frame ?? .zero
        // The drain's half of the resize's hold: no frame it publishes may
        // show a redraw the capture keeps back.
        drive.setLiveResize(liveResizeStartWindowFrame.isEmpty ? .Idle : .Active)
        if !liveResizeStartWindowFrame.isEmpty {
            let pointer = NSEvent.mouseLocation
            let frame = liveResizeStartWindowFrame
            isLiveResizeBottomFixed = abs(pointer.y - frame.maxY) < abs(pointer.y - frame.minY)
        }
        // An image application's per-frame delete-and-replace must not blank
        // its picture on a frame captured between the two; see the latch.
        isHoldingImageGapsForResize = true
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // A delete after the drag is a delete again.
        isHoldingImageGapsForResize = false
        // The drag's anchoring ends with the drag: the settled grid is fitted
        // top-anchored to the bounds the reader stopped at.
        liveResizeStartWindowFrame = .zero
        drive.setLiveResize(.Idle)
        isLiveResizeBottomFixed = false
        refitGridToBounds()
        // The one full-history rewrap the drag's steps deferred. After the
        // last step, so it rewraps to the width the reader stopped at. The
        // refit carried the view across its own resize, so the settle's carry
        // starts from the history the refit left.
        noteViewportBeforeResize()
        drive.settleResize()
        carryViewOffsetAcrossResize()
        needsDisplay = true
        if window?.occlusionState.contains(.visible) == true {
            isDrawingResizeStep = true
            drawSurfaceFrame()
            isDrawingResizeStep = false
        }
        scheduleTransactionalPresentRelease()
    }

    /// Whether a resize step holds the window's bottom edge still.
    ///
    /// The fact the grid resize anchors on: a top-edge drag ages the primary
    /// screen's top rows into history, so the rows above the stationary
    /// bottom edge stay where the reader is looking. The layer's gravity does
    /// not follow it. A stale drawable stays pinned top-left whichever edge
    /// moves, because the grid is laid out from the top inset on every step:
    /// a frame shown in a bounds it was not drawn for loses its bottom edge,
    /// never part of its first row.
    ///
    /// A stationary edge is only meaningful when the window frame changed
    /// size: a fixed frame (a divider dragged between two panes) would read
    /// as bottom fixed, and reads as not.
    ///
    /// - Parameters:
    ///   - startFrame: The window's frame when the drag began.
    ///   - currentFrame: Its frame now.
    /// - Returns: Whether the bottom edge is the one standing still.
    package static func isBottomEdgeFixed(resizingFrom startFrame: CGRect, to currentFrame: CGRect) -> Bool {
        let epsilon = 1.0
        guard currentFrame.size != startFrame.size else { return false }
        return abs(currentFrame.minY - startFrame.minY) < epsilon
    }

    override public func setFrameSize(_ newSize: CGSize) {
        // AppKit cascades this across a whole tab group's view tree on every
        // tab switch and window relayout, almost always with the size it
        // already has. There is nothing to reflow then, and the synchronous
        // present below must not be paid: it blocks the main thread until the
        // GPU schedules the drawable, so one per tab on a busy GPU is a hang.
        guard newSize != frame.size else {
            super.setFrameSize(newSize)
            return
        }
        // The surface's own latch rather than `inLiveResize`: the two say the
        // same thing during a drag, and this one is set by the entry point
        // above rather than by AppKit, so the whole path can be exercised.
        if let window, !liveResizeStartWindowFrame.isEmpty, window.frame.size != liveResizeStartWindowFrame.size {
            // Kept for the grid resize below. A window frame that has not
            // moved at all is a pane divider being dragged, which says nothing
            // about the window's edges and must not anchor the grid off its
            // own origin.
            isLiveResizeBottomFixed =
                window.frame != liveResizeStartWindowFrame
                && TerminalSurface.isBottomEdgeFixed(resizingFrom: liveResizeStartWindowFrame, to: window.frame)
        }
        super.setFrameSize(newSize)
        // A drag's step is timed in two halves under UBIQUITTY_PERFLOG:
        // the reflow here, and the encode and present of the frame that
        // follows, which reads and clears this. Off the log, a clock read
        // per step is what it costs.
        if !liveResizeStartWindowFrame.isEmpty {
            let reflowStartedAt = ProcessInfo.processInfo.systemUptime
            surfaceDidResize(to: newSize)
            lastLiveResizeReflowSeconds = ProcessInfo.processInfo.systemUptime - reflowStartedAt
        } else {
            surfaceDidResize(to: newSize)
        }

        // Draw at the new size in the same transaction as the bounds change,
        // so the compositor never has to make a frame out of the previous
        // drawable. A live drag or native Fill already presents transactionally;
        // a direct setFrame can resize outside those callbacks, so it turns
        // the transactional present on for its own frame.
        //
        // Only for a window that is on screen: the present blocks the main
        // thread on the GPU, and a background or occluded tab has nobody to
        // show a stale frame to, so it redraws asynchronously instead. A tab
        // appearing or disappearing relays out every pane at a CHANGED size
        // and takes that same asynchronous path — a sibling pane saturating
        // the GPU would otherwise stall the switch for about a second. The
        // asynchronous mark is held while the pane's frames are withheld, and
        // the reveal spends it.
        let isTabBarPresent = (window?.tabGroup?.windows.count ?? 0) >= 2
        let isTabStripRelayout = isTabBarPresent != wasTabBarPresent
        wasTabBarPresent = isTabBarPresent
        let isVisible = window?.occlusionState.contains(.visible) ?? false
        isDrawingResizeStep = true
        defer { isDrawingResizeStep = false }
        if inLiveResize {
            drawSurfaceFrame()
        } else if isVisible, !isTabStripRelayout {
            // Kept on past the step: the frames a program's redraw brings
            // between two steps then present in order with them. Presented
            // asynchronously, one of those can land behind a following
            // step's transaction and show a smaller frame in the larger
            // bounds — a step back mid-animation. The mode drops once the
            // frame has held still.
            metalLayer.presentsWithTransaction = true
            frameLink?.synchronizePresentationMode()
            drawSurfaceFrame()
            scheduleTransactionalPresentRelease()
        } else {
            needsDisplay = true
        }
    }

    /// Drops the transactional present once the frame has held still for
    /// longer than an animation step. Cancelled and rebooked by every step,
    /// so the mode outlives the animation by one interval and no more; a
    /// live drag owns the mode itself and is left alone.
    private func scheduleTransactionalPresentRelease() {
        transactionalPresentRelease?.cancel()
        let release = DispatchWorkItem { [weak self] in
            guard let self, self.liveResizeStartWindowFrame.isEmpty else { return }
            self.metalLayer.presentsWithTransaction = false
            self.frameLink?.synchronizePresentationMode()
        }
        transactionalPresentRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: release)
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        surfaceDidChangeBackingProperties()
        publishNativeWindowGeometry()
    }

    /// Publishes native window facts used by terminal geometry reports.
    internal func publishNativeWindowGeometry() {
        guard let window else { return }
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main
        let positionX = Int32(clamping: Int(max(0, frame.minX.rounded())))
        let positionY = Int32(clamping: Int(max(0, ((screen?.frame.height ?? frame.height) - frame.maxY).rounded())))
        let maxContent = window.contentRect(forFrameRect: screen?.visibleFrame ?? frame)
        let insets = renderer?.gridFitInsets(for: self) ?? .init()
        let scale = window.backingScaleFactor
        let screenWidth = UInt16(clamping: Int((max(1, maxContent.width - insets.left - insets.right) * scale).rounded()))
        let screenHeight = UInt16(clamping: Int((max(1, maxContent.height - insets.top - insets.bottom) * scale).rounded()))
        let isMiniaturized = window.isMiniaturized
        drive.withTerminal { terminal in
            terminal.winPosX = positionX
            terminal.winPosY = positionY
            terminal.screenPixelWidth = screenWidth
            terminal.screenPixelHeight = screenHeight
            terminal.windowIconified = isMiniaturized
        }
    }

    /// Watches the window edges that change how this surface presents.
    ///
    /// Miniaturize and occlusion are AppKit facts with no counterpart on a
    /// phone, which is why the watching is per-shell while what it triggers
    /// is not.
    internal func installPlatformWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
        // The workspace posts on a centre of its own, and an observer taken
        // off the default centre is left registered: the teardown has to name
        // the centre each observer came from.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        // Before the window check, and posted by nobody in particular
        // (`object: nil`): an edited `[keys]` table has to reach every live
        // surface, not the one whose window happened to be frontmost. The
        // table and the compose trigger are rebuilt together, because one
        // block holds both.
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: TerminalSurface.keyBindingsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.drive.rebuildKeyBindings()
                }
            }
        )
        // The machine's own budget, posted by nobody in particular
        // (`object: nil`) and read by every live surface: Low Power Mode and
        // thermal pressure are process-wide, and a pane that missed the edge
        // would keep spending on a machine that asked every other pane to
        // stop. `ProcessInfo` posts these from a BACKGROUND queue, unlike
        // every AppKit notification beside them, and the refresh reads
        // `NSWindow.tabGroup` — which lazily builds an `NSTabBar` and runs
        // AutoLayout, and AppKit off the main thread aborts the process. The
        // `.main` queue named here is that hop.
        let onMachineEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMachineThrottle()
            }
        }
        for name in [ProcessInfo.thermalStateDidChangeNotification, NSNotification.Name.NSProcessInfoPowerStateDidChange] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: onMachineEdge))
        }
        guard let window else { return }
        publishNativeWindowGeometry()
        let onGeometryEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishNativeWindowGeometry()
            }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: onGeometryEdge))
        }
        windowObservers.append(
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.drive.isPresentationContinuous else { return }
                    // Displays can share a backing scale while having different refresh rates.
                    self.frameClock.resume()
                }
            }
        )
        // NotificationCenter runs a block observer on the queue named at
        // registration; every registration below names `.main`, so each body
        // runs on the main thread and takes the surface's isolation back.
        let onEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishNativeWindowGeometry()
                self?.recomputePresentation()
            }
        }
        windowObservers.append(
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main, using: onEdge)
        )
        // An edge that brings the window back, with the occlusion report for
        // where it lands still to come: the pane draws now and the report
        // settles it. Core ignores the edge for a pane it already draws.
        let onRevealEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishNativeWindowGeometry()
                self?.noteRevealEdge()
            }
        }
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: onRevealEdge))
        }
        // Focus is Core's conjunction of the window's key status, the
        // responder and the application's activation, so every edge that can
        // move one of the three re-derives it, across AppKit's settling; the
        // recompute reconciles the pointer lock, which reads the same facts.
        // Main is watched as well as key: a plain tab switch fires main
        // reliably and key not always. A tab reaching or leaving the front of
        // its group changes what its cursor paints as, and that fact needs
        // the frame asked for because it dirties no cell.
        let onWindowActivationEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSurfaceFocusAcrossSettling()
                self?.refreshWindowTabBackgrounding()
            }
        }
        // A window or application coming forward is a reveal as well as a
        // focus edge, and the reveal is noted first: the frame the edge asks
        // for is the one the reader sees, and the occlusion report that would
        // permit it arrives a frame or more later. A pane that is behind its
        // group's front tab, miniaturized or hidden takes none of these —
        // Core reads the same struct and answers for it.
        let onBecomeEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteRevealEdge()
                self.refreshSurfaceFocusAcrossSettling()
                self.refreshWindowTabBackgrounding()
            }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: onBecomeEdge))
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: onWindowActivationEdge))
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: onBecomeEdge))
        }
        windowObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main,
                using: onWindowActivationEdge
            )
        )
        // The workspace's own centre, which is where the edges that move a
        // whole desktop are posted. Each one can put this window in front of a
        // reader with no notification of its own from the window: a space
        // swipe, a display waking, and the login session coming back from a
        // fast user switch. The space edge is taken only by a window on the
        // space that became active — the others are on windows that did not
        // move.
        let onSpaceEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isOnActiveSpace == true else { return }
                self.noteRevealEdge()
            }
        }
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main,
                using: onSpaceEdge
            )
        )
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main, using: onRevealEdge)
            )
        }
        windowObservers.append(
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) {
                [weak self] notification in
                let reportedWindow = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                        let changedWindow = reportedWindow,
                        changedWindow === window || window.tabGroup?.windows.contains(where: { $0 === changedWindow }) == true
                    else { return }
                    // A tab switch flips occlusion a frame after it moves the
                    // group's selection, so this edge re-reads the tab fact too;
                    // it is also the one edge a switch produces in a window that
                    // is never key.
                    self.refreshWindowTabBackgrounding()
                    // The report is the window system's answer to whatever
                    // edge preceded it, in either direction: it describes the
                    // window as it stands, so the reveal that was drawing on
                    // trust ends here.
                    self.settleRevealFromReport()
                    // Occlusion is the full-rate fact the tab check does not
                    // carry: a window covered whole by another app parks its
                    // link here even though its tab is still the front one, so
                    // it stops driving frames into a drawable nothing shows.
                    // recomputePresentation early-returns cheaply when nothing
                    // moved.
                    self.recomputePresentation()
                    if self.frameDelivery == .Draw {
                        self.needsDisplay = true
                        self.frameClock.noteAnimationActivity()
                    }
                }
            }
        )
    }
    /// Forwards one pointer event to Core's pipeline as facts, and applies
    /// what remains: repaint, observer notification, gesture bookkeeping.
    /// The pointer lock short-circuits first — the OS grab is platform state
    /// the pipeline never sees.
    ///
    /// - Parameters:
    ///   - event: The AppKit event.
    ///   - kind: Press, release or motion.
    ///   - button: The button, in xterm's identity space.
    ///   - isDragging: Whether a held button extends a gesture.
    /// - Returns: Whether the pipeline consumed the event.
    @discardableResult
    private func forwardPointerFact(
        _ event: NSEvent,
        kind: Ubiquitty.Runtime.TerminalSession.PointerFact.Kind,
        button: Ubiquitty.Input.PointerButton,
        isDragging: Bool = false
    ) -> Bool {
        guard
            let fact = makePointerFact(
                atViewPoint: convert(event.locationInWindow, from: nil),
                kind: kind,
                button: button,
                clickCount: event.clickCount,
                isDragging: isDragging,
                modifiers: SurfaceModifiers(
                    hasShift: event.modifierFlags.contains(.shift),
                    hasAlternate: event.modifierFlags.contains(.option),
                    hasControl: event.modifierFlags.contains(.control),
                    hasCommand: event.modifierFlags.contains(.command)
                )
            )
        else {
            return false
        }
        // The motion since the last event, which relative pointer lock
        // (DECSET 7403) reports in place of a position.
        var moved = fact
        moved.deltaX = Int(event.deltaX.rounded())
        moved.deltaY = Int(event.deltaY.rounded())
        return forward(moved)
    }

    override public func mouseDown(with event: NSEvent) {
        dragDrop.pressed(event)
        // Focus follows the click before the report goes out: a host that made
        // this surface first responder on the same event would otherwise send
        // the press to whichever surface held focus a moment ago.
        window?.makeFirstResponder(self)
        // A click makes the pointer visible again, like a move.
        pointerIsHiddenForTyping = false
        // A click that opens a link is spent on that: it must not also start a
        // selection, or the gesture both navigates and highlights.
        let reporting = pointerReportingState(modifiers: event.modifierFlags)
        let isSelectionOverride = reporting.isMouseReporting && reporting.isSelectionOverrideModifierArmed
        if !isSelectionOverride, event.clickCount == 1,
            openLink(
                atViewPoint: convert(event.locationInWindow, from: nil),
                isCommandHeld: event.modifierFlags.contains(.command)
            )
        {
            // The press went to the link and was never reported, so the
            // release and any motion before it must not be either: an
            // application that saw a release with no press reads it as a click
            // whose beginning it missed, and acts on half a gesture.
            didPressOpenALink = true
            return
        }
        // Before the selection and after the link: a Command press on a link
        // in a chromeless window still opens it, and everything else with the
        // drag modifiers held moves the window instead of selecting.
        if !isSelectionOverride, beginWindowDrag(with: event) {
            return
        }
        // Which chord makes a drag rectangular is the reader's and Core matches
        // it exactly, so this asks rather than testing Option itself. Hard-coded
        // here, a chord moved off Option left this true for a bare Option press
        // and the crosshair promised a block the press would not make.
        isRectangularDragInFlight = Ubiquitty.Input.localDragIsRectangular(
            pointerReportingState(modifiers: event.modifierFlags)
        )
        // Sets `isSelectionDragInFlight` from Core's answer about the press.
        forwardPointerFact(event, kind: .press, button: .left)
        applyPointerCursor()
    }

    override public func mouseUp(with event: NSEvent) {
        dragDrop.released()
        if didPressOpenALink {
            didPressOpenALink = false
            isSelectionDragInFlight = false
            return
        }
        if endWindowDrag() {
            return
        }
        isSelectionDragInFlight = false
        isRectangularDragInFlight = false
        // The gesture is over, so the walk past the edge is too — whether or
        // not one was running.
        stopDragAutoScroll()
        forwardPointerFact(event, kind: .release, button: .left)
    }

    override public func mouseDragged(with event: NSEvent) {
        // Motion after a press that opened a link belongs to the gesture the
        // link took, and reporting it would hand an application the middle of
        // a drag whose start it never saw.
        if didPressOpenALink {
            return
        }
        if continueWindowDrag(with: event) {
            return
        }
        if dragDrop.dragged(event) { return }
        forwardPointerFact(event, kind: .motion, button: .left, isDragging: true)
        // Every drag event, not only the ones outside: a drag returning over
        // the grid is what stops the walk, and this is the event that says so.
        noteDragAutoScroll(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    override public func rightMouseDown(with event: NSEvent) {
        // Core's ladder decides first: a locator press or a mouse report
        // belongs to the program, and the menu must not pop over an
        // application that took the click. Unconsumed, AppKit's own handler
        // asks `menu(for:)` — swallowing it leaves the right button dead in
        // a plain shell.
        if !forwardPointerFact(event, kind: .press, button: .right) {
            super.rightMouseDown(with: event)
        }
    }

    override public func rightMouseUp(with event: NSEvent) {
        forwardPointerFact(event, kind: .release, button: .right)
    }

    override public func rightMouseDragged(with event: NSEvent) {
        forwardPointerFact(event, kind: .motion, button: .right, isDragging: true)
    }

    override public func otherMouseDown(with event: NSEvent) {
        forwardPointerFact(event, kind: .press, button: Self.otherButton(event.buttonNumber))
    }

    override public func otherMouseUp(with event: NSEvent) {
        forwardPointerFact(event, kind: .release, button: Self.otherButton(event.buttonNumber))
    }

    override public func otherMouseDragged(with event: NSEvent) {
        forwardPointerFact(event, kind: .motion, button: Self.otherButton(event.buttonNumber), isDragging: true)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        // `inVisibleRect` keeps the area glued to the view's visible rect, so it
        // follows every geometry change without a rebuild. A pane grown by a
        // sibling closing reaches the surface through `setFrameSize` — which
        // does not run the layout pass that re-invokes this — so an area built
        // from the bounds would freeze at the old, smaller ones and moves over
        // the grown band would never arrive. The rect is ignored under that
        // option; the bounds are passed because the initialiser demands one.
        //
        // `activeInKeyWindow` rather than always: a hover affordance lighting
        // up in a window the reader is not in is a hand for a link they cannot
        // click from where they are.
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override public func mouseEntered(with event: NSEvent) {
        // The area asks for entry and exit, so AppKit sends this — and a
        // pointer can arrive over a cell without crossing another one inside
        // the view: moved in from outside and stopped, or the window brought
        // under a pointer that never moved. No motion event follows either, so
        // an affordance resolved only on movement waits for a move the reader
        // has no reason to make, and a link under the pointer offers no hand.
        updateLinkAffordance(
            atViewPoint: convert(event.locationInWindow, from: nil),
            isCommandHeld: event.modifierFlags.contains(.command)
        )
        applyPointerCursor()
    }

    override public func mouseExited(with event: NSEvent) {
        // The pointer left: whatever it was over, it is not over it now. The
        // affordance goes with it rather than being left lit on the cell the
        // pointer was last seen on.
        clearLinkAffordance()
    }

    override public func mouseMoved(with event: NSEvent) {
        // A real move means the pointer is visible again, whatever typing did
        // to it — AppKit has already unhidden it by the time this arrives.
        pointerIsHiddenForTyping = false
        updateLinkAffordance(
            atViewPoint: convert(event.locationInWindow, from: nil),
            isCommandHeld: event.modifierFlags.contains(.command)
        )
        // Only 1003 reports a button-less move, and the encoder is what knows
        // that. Forwarding unconditionally costs one refused call per move.
        // The button is none: `.other` encodes as xterm's button 0, which
        // would report every hover as a held left button.
        forwardPointerFact(event, kind: .motion, button: .none)
    }

    /// Offers a keypress to the Tektronix graphic-input crosshair.
    ///
    /// Whether the press is the trigger is Core's — it holds the mode and the
    /// crosshair — and so is the projection, which has to be the one the Tek
    /// vectors were drawn through. What is here is the platform's share: the
    /// byte the key produced, and where the pointer sits in this view with y
    /// measured from the top, which is the axis the projection expects and the
    /// opposite of AppKit's own.
    ///
    /// - Parameter event: The key press.
    /// - Returns: Whether the press was spent on the report.
    private func reportTekGraphicInputIfArmed(_ event: NSEvent) -> Bool {
        let snapshot = drive.readSnapshot()
        guard snapshot.isTekModeActive, snapshot.isTekGraphicInputActive,
            let typed = event.characters?.utf8.first
        else {
            return false
        }
        let local = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let reported = drive.reportTekGraphicInput(
            key: CChar(bitPattern: typed & 0x7F),
            pointX: local.x,
            pointY: bounds.height - local.y,
            viewWidth: bounds.width,
            viewHeight: bounds.height
        )
        if reported {
            // The crosshair auto-disables with the report, so the frame that
            // follows is the one that takes it off screen.
            needsDisplay = true
        }
        return reported
    }

    override public func scrollWheel(with event: NSEvent) {
        routeWheel(event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The built-in defaults, and nothing else this view claims: they are
        // taken here rather than on key-down because a default that summons an
        // overlay must dismiss it while the overlay holds first responder, and
        // key-down then never arrives. Claimed only from the surface that
        // answers keys, or while its palette is up: this pass runs down the
        // whole view hierarchy, and a find field holding the responder keeps
        // its own chords. A default the user has rebound is not claimed, so
        // the chord falls through to the terminal like any other key.
        let isPaletteUp = window.map { TerminalWindowController.beamPresenter?.isActive($0) ?? false } ?? false
        if window?.firstResponder === self || isPaletteUp {
            if consultDefaultKeyBindings(event) == .consumed {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override public func keyDown(with event: NSEvent) {
        if window.map({ TerminalWindowController.beamPresenter?.isActive($0) ?? false }) == true { return }
        // A non-modifier key joining the break-out chord disarms it — the
        // hold must be the chord alone.
        disarmPointerLockChord()
        // Scrollback navigation is app-level chrome and takes the key before
        // the input method sees the event, matching the Metal arm's set.
        if handleScrollbackNavigationKey(event) {
            return
        }
        // While the Tektronix crosshair is up a keypress is the graphic-input
        // trigger rather than input: it reports the typed byte and the
        // crosshair's Tek coordinates, and the crosshair disables itself after.
        // Taken before the bindings and the input method, because a program
        // waiting on GIN is blocked and everything below assumes a terminal
        // that is reading.
        if reportTekGraphicInputIfArmed(event) {
            return
        }
        // A keystroke drops the selection before it reaches the process — a
        // highlight standing over content being edited is stale.
        clearSelectionForUserInput()
        routeKeyPress(event)
    }

    override public func keyUp(with event: NSEvent) {
        // Handed over unconditionally: whether a release is reported is the
        // encoder's decision from the host's Kitty flags, and answering it here
        // would be a second reading of the same mode.
        sendKey(event, eventType: .Release)
    }

    override public func flagsChanged(with event: NSEvent) {
        // The break-out chord is native, above the key resolver and the
        // host, so no rebind, mode, or escape stream can shadow the release.
        updatePointerLockChord(event)
        // Whether a link opens on a click depends on the modifier, so the
        // hand appears and goes with it under a pointer that never moved.
        updateLinkAffordanceAtLivePointer()
        // The same for the block-select crosshair, which is armed by a
        // modifier and by nothing else.
        applyPointerCursor()
        // A modifier is a key like any other under Kitty, and nothing under the
        // legacy encoder — which is exactly what the encoder returns for it, so
        // no gate here has to know which regime is live.
        sendKey(event, eventType: modifierIsDown(event) ? .Press : .Release)
    }

    /// Whether the modifier that changed is the one now held.
    ///
    /// AppKit reports a press and a release as the same event kind, so the
    /// direction is read from the flags: the bit for the key that changed is set
    /// on the way down and clear on the way up.
    ///
    /// The bit is the PER-SIDE one, not the general `.shift` / `.control` /
    /// `.option` / `.command`. Those cannot tell the two sides apart: releasing
    /// the left Shift while the right one is held leaves the general bit set,
    /// and a reader of it reports a press for a key going up — which under the
    /// Kitty protocol is a modifier a program then believes is still down.
    ///
    /// - Parameter event: The flags-changed event.
    /// - Returns: Whether this was a press.
    private func modifierIsDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 57 { return event.modifierFlags.contains(.capsLock) }
        let key = Ubiquitty.macOS.portableKeyForCode(event.keyCode)
        let mask = Ubiquitty.macOS.modifierDeviceMask(key)
        guard mask != 0 else { return false }
        return (event.modifierFlags.rawValue & UInt(mask)) != 0
    }
}

#endif
