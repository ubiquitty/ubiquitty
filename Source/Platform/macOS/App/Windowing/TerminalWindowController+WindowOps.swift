// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TerminalWindowController+WindowOps.swift — what a program asks of the window.
//
// The CSI t family, DECCOLM's column change, OSC 1337 StealFocus, an attention
// request and an OSC 1337 colour preset. Core reaches a frontend for these
// through `WindowClient`, which this arm cannot install: cxx-interop does not
// let a Swift type subclass a C++ class with virtual methods. So the session
// queues the calls, reports that the queue is not empty, and this drains it.
//
// Off the drain rather than inline is not only what the seam forces — the
// parser makes those calls with the model lock held, on the ingest thread, and
// no window can be resized from there.
//
// Three things here are not translations of an AppKit call, and each answers
// the same question: what a program reads back immediately after asking.
//
//   - Iconify latches Core's own flag on the REQUEST. Miniaturisation is
//     animated, so a CSI 11 t arriving behind it would otherwise report the
//     state the window is leaving.
//   - Maximize drives the frame instead of calling `zoom`, which also animates:
//     a CSI 18 t behind it would measure a frame still in flight.
//   - A native full-screen request arriving mid-transition is judged against
//     the state it is transitioning into. The style mask lags the animation
//     by its whole duration, so comparing against it makes the opposite request
//     cancel itself as a no-op and strand the window wherever the transition
//     lands, with nothing able to move it afterwards.
//
// Geometry is untrusted input. Every frame change resizes the drawable, which
// discards the layer's pool and allocates afresh, and draws its step
// synchronously; a program writing CSI 8 t and CSI 9 t as fast as it can makes
// that one allocation per request. So the geometry a drain carries folds into
// one target frame, applied once at the drain's end and at most once per
// display frame, and CSI 4 t and CSI 8 t are limited to the screen as xterm
// limits them. What a program can drive is then one drawable size per display
// frame, no larger than the screen.
//

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalWindowController {
    /// Performs everything a program has asked of this window.
    ///
    /// Drains rather than taking one, because the queue is what Core fills and
    /// a program that iconifies and then moves put two in it. In the program's
    /// order: the pair means different things each way round.
    ///
    /// - Parameter surface: The surface whose session carries the requests.
    func performPendingWindowRequests(from surface: TerminalSurface) {
        while let request = surface.drive.takeWindowRequest() {
            performWindowRequest(request, on: surface)
        }
        flushProgramFrame()
    }

    /// The frame a program's geometry requests start from: where the ones
    /// already taken arrived, or the window's own.
    private var programFrame: NSRect? { programFrameTarget ?? window?.frame }

    /// The longest a program's frame waits behind the previous one.
    private static let programFrameInterval: TimeInterval = 1.0 / 60.0

    /// The most geometry requests held across a native full-screen transition.
    ///
    /// The overrun is dropped, as Core drops it from its own queue: the
    /// transition lasts a fraction of a second, and a program writing faster
    /// than that is not asking for every step.
    private static let deferredGeometryLimit = 16

    /// Applies the frame a program's requests arrived at, at most once per
    /// display frame: a held frame is booked for when the interval ends, and
    /// later drains fold into it.
    func flushProgramFrame() {
        guard programFrameTarget != nil, !isProgramFrameFlushBooked else { return }
        let wait = programFrameAppliedAt + Self.programFrameInterval - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else {
            applyProgramFrameNow()
            return
        }
        isProgramFrameFlushBooked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.isProgramFrameFlushBooked = false
            self.applyProgramFrameNow()
        }
    }

    /// Applies a held program frame at once, for a request whose meaning
    /// depends on the frame having landed.
    private func applyProgramFrameNow() {
        guard let target = programFrameTarget else { return }
        programFrameTarget = nil
        guard let window, !isInFullScreenTransition, target != window.frame else { return }
        programFrameAppliedAt = ProcessInfo.processInfo.systemUptime
        window.setFrame(target, display: true)
    }

    /// Performs one request.
    ///
    /// - Parameters:
    ///   - request: What the program asked for.
    ///   - surface: The surface whose session asked.
    private func performWindowRequest(_ request: RuntimeDrive.WindowRequest, on surface: TerminalSurface) {
        switch request.kind {
        case .windowOp:
            performWindowOperation(request.first, request.second, request.third, on: surface)
        case .columnMode:
            applyColumnMode(isColumns132: request.first != 0, on: surface)
        case .stealFocus:
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        case .attention:
            requestAttention(styleValue: request.first)
        case .colorPreset:
            applyColorPreset(named: request.text)
        }
    }

    /// One CSI t window operation.
    ///
    /// - Parameters:
    ///   - operation: The `Ps` the program wrote.
    ///   - first: Its first argument.
    ///   - second: Its second argument.
    ///   - surface: The surface whose session asked.
    private func performWindowOperation(_ operation: Int, _ first: Int, _ second: Int, on surface: TerminalSurface) {
        guard let window else { return }
        // A geometry request while a native full-screen transition runs would
        // leave the window full-screen-sized around a grid it just shrank, so
        // it waits for the animation and runs against the frame it lands on.
        if [3, 4, 8, 9].contains(operation), isInFullScreenTransition {
            if deferredGeometryRequests.count < Self.deferredGeometryLimit {
                deferredGeometryRequests.append((operation, first, second))
            }
            return
        }
        // These read or change the window's state behind its frame, so the
        // geometry taken before them lands first and they meet the frame the
        // program asked for.
        if [1, 2, 10].contains(operation) {
            applyProgramFrameNow()
        }
        switch operation {
        case 1, 2:
            // Latched on the request, ahead of the animation, so a CSI 11 t
            // behind this reads where the window is going rather than where it
            // still is. The window notifications correct it if the window
            // manager refuses, and carry a person's own miniaturise too.
            let isIconifying = operation == 2
            surface.drive.withTerminal { terminal in
                terminal.windowIconified = isIconifying
            }
            if isIconifying {
                window.miniaturize(nil)
            } else {
                window.deminiaturize(nil)
            }
        case 3:
            // The program's origin is top-left and y-down; Cocoa's is
            // bottom-left.
            guard var frame = programFrame else { return }
            let screenHeight = (window.screen ?? NSScreen.main)?.frame.height ?? 0
            frame.origin = NSPoint(x: CGFloat(first), y: screenHeight - CGFloat(second) - frame.height)
            programFrameTarget = frame
        case 4:
            if let frame = programFrame {
                programFrameTarget = textAreaFrame(heightInPixels: first, widthInPixels: second, from: frame, on: surface)
            }
        case 5:
            // A program raising its window is a reveal: the window system
            // reports the occlusion that follows a frame or more later, and
            // what the reader sees first is the frame this asks for.
            window.orderFront(nil)
            for projected in projectedSurfaces {
                projected.noteRevealEdge()
            }
        case 6:
            window.orderBack(nil)
        case 7:
            surface.needsDisplay = true
        case 8:
            // CSI 8 t names the grid, so it goes through the one place that
            // turns a grid into a frame: -1 keeps an axis, 0 fits the screen,
            // and no axis grows past the screen, which is xterm's limit too.
            let snapshot = surface.drive.readSnapshot()
            let screenRowCount = screenRows(on: surface)
            let screenColumnCount = screenColumns(on: surface)
            let rows = min(cellCount(first, current: Int(snapshot.rows), screenExtent: screenRowCount), screenRowCount)
            let columns = min(
                cellCount(second, current: Int(snapshot.columns), screenExtent: screenColumnCount),
                screenColumnCount
            )
            if let frame = programFrame, let sized = self.frame(forColumns: columns, rows: rows, from: frame) {
                programFrameTarget = sized
            }
        case 9:
            if let frame = programFrame, let maximized = maximizedFrame(mode: first, from: frame) {
                programFrameTarget = maximized
            }
        case 10:
            setProgramFullScreen(mode: first)
        default:
            break
        }
    }

    /// The frame whose TEXT AREA is the size asked for.
    ///
    /// CSI 14 t reports the text area, so a program that resizes and then
    /// measures must read back what it asked for. Sizing the frame instead
    /// leaves it short by the decorations and the renderer's padding. Neither
    /// axis grows past the screen's visible frame, as in xterm.
    ///
    /// - Parameters:
    ///   - heightInPixels: The height asked for; -1 keeps it, 0 fits the screen.
    ///   - widthInPixels: The width, on the same terms.
    ///   - frame: The frame the request starts from.
    ///   - surface: The surface whose padding the frame carries.
    /// - Returns: The frame, or nil before the surface has a renderer.
    private func textAreaFrame(
        heightInPixels: Int,
        widthInPixels: Int,
        from frame: NSRect,
        on surface: TerminalSurface
    )
        -> NSRect?
    {
        guard let window, let renderer = surface.renderer else { return nil }
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1
        let insets = renderer.gridFitInsets(for: surface)
        let reservedWidth = insets.left + insets.right
        let reservedHeight = insets.top + insets.bottom
        let content = window.contentRect(forFrameRect: frame)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let visibleContent = window.contentRect(forFrameRect: visible)

        let textHeight =
            switch heightInPixels {
            case ..<0: content.height - reservedHeight
            case 0: visibleContent.height - reservedHeight
            default: min(CGFloat(heightInPixels) / scale, visibleContent.height - reservedHeight)
            }
        let textWidth =
            switch widthInPixels {
            case ..<0: content.width - reservedWidth
            case 0: visibleContent.width - reservedWidth
            default: min(CGFloat(widthInPixels) / scale, visibleContent.width - reservedWidth)
            }

        let sized = window.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: max(textWidth, 1) + reservedWidth,
                height: max(textHeight, 1) + reservedHeight
            )
        )
        // Cocoa anchors a size change at the bottom-left; the origin shifts so
        // the window appears to grow from its top-left, which is the corner the
        // reader is least likely to be looking at.
        return NSRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height - sized.height,
            width: sized.width,
            height: sized.height
        )
    }

    /// The frame for maximize, restore, or fill one axis.
    ///
    /// Driven rather than animated through `zoom`, so every axis has landed by
    /// the time the frame is applied and a CSI 18 t behind it measures a
    /// window that has stopped moving.
    ///
    /// - Parameters:
    ///   - mode: 0 restores, 1 fills, 2 fills vertically, 3 horizontally.
    ///   - current: The frame the request starts from.
    /// - Returns: The frame, or nil when there is nothing to restore.
    private func maximizedFrame(mode: Int, from current: NSRect) -> NSRect? {
        guard let window, let screen = window.screen ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        var frame = current
        if mode == 0 {
            guard let restored = preMaximizeFrame else { return nil }
            preMaximizeFrame = nil
            return restored
        }
        if preMaximizeFrame == nil {
            preMaximizeFrame = frame
        }
        switch mode {
        case 1: frame = visible
        case 2:
            frame.origin.y = visible.origin.y
            frame.size.height = visible.height
        case 3:
            frame.origin.x = visible.origin.x
            frame.size.width = visible.width
        default: break
        }
        return frame
    }

    /// CSI 10 t, program full screen.
    ///
    /// Unless `[window] program_fullscreen = native`, this fills the screen's
    /// visible frame in place: synchronous, no Space change, and the window
    /// stays resizable, so a geometry request behind it lands instead of racing
    /// an animation that would refuse it.
    ///
    /// - Parameter mode: 0 leaves, 1 enters, 2 toggles.
    private func setProgramFullScreen(mode: Int) {
        guard let window else { return }
        guard usesNativeProgramFullScreen else {
            let wants = mode == 2 ? !isProgramFillingScreen : mode == 1
            guard wants != isProgramFillingScreen else { return }
            if wants {
                preProgramFillScreenFrame = window.frame
                isProgramFillingScreen = true
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true)
                }
            } else {
                isProgramFillingScreen = false
                if let restored = preProgramFillScreenFrame {
                    window.setFrame(restored, display: true)
                }
                preProgramFillScreenFrame = nil
            }
            return
        }
        // Judged against the state the window is entering. The style
        // mask lags the animation by its whole duration, so the opposite
        // request compared against it reads as a no-op and the window is
        // stranded wherever the transition lands.
        let isFull = window.styleMask.contains(.fullScreen)
        let settling = isInFullScreenTransition ? fullScreenTransitionTarget : isFull
        let wants = mode == 2 ? !settling : mode == 1
        if isInFullScreenTransition {
            pendingFullScreenRequest = wants != fullScreenTransitionTarget ? wants : nil
        } else if wants != isFull {
            window.toggleFullScreen(nil)
        }
    }

    /// DECCOLM asked for 80 or 132 columns.
    ///
    /// The window follows at the natural cell width — xterm's `c132` — unless
    /// the reader turned that off or the window is full screen, where there is
    /// no width to take.
    ///
    /// - Parameters:
    ///   - isColumns132: Whether the new width is 132.
    ///   - surface: The surface whose grid changed.
    private func applyColumnMode(isColumns132: Bool, on surface: TerminalSurface) {
        guard let window, !window.styleMask.contains(.fullScreen), !isProgramFillingScreen else { return }
        guard Ubiquitty.Preferences.Effective.columnModeResizesWindow(Ubiquitty.Preferences.values().pointee) else {
            return
        }
        let snapshot = surface.drive.readSnapshot()
        let columns = isColumns132 ? 132 : 80
        if let frame = programFrame, let sized = self.frame(forColumns: columns, rows: Int(snapshot.rows), from: frame) {
            programFrameTarget = sized
        }
    }

    /// Asks for the human's attention as insistently as Core resolved.
    ///
    /// Three answers, not two: Cancel is a request to STOP, and folding it in
    /// with the rest would bounce the Dock for a program asking for quiet. The
    /// id is kept because that is the only handle a cancel has — AppKit
    /// auto-cancels a critical request when the app is activated, but a program
    /// that changes its mind before the reader looks has nothing else to name.
    ///
    /// - Parameter styleValue: The `PAL::AttentionRequest` Core sent.
    private func requestAttention(styleValue: Int) {
        switch styleValue {
        case Int(Ubiquitty.AttentionRequest.Cancel.rawValue):
            if let identifier = attentionRequestIdentifier {
                NSApp.cancelUserAttentionRequest(identifier)
                attentionRequestIdentifier = nil
            }
        case Int(Ubiquitty.AttentionRequest.Continuous.rawValue):
            // Bounces until the window is activated; AppKit cancels it there.
            attentionRequestIdentifier = NSApp.requestUserAttention(.criticalRequest)
        default:
            attentionRequestIdentifier = NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// OSC 1337 SetColors=preset applied live to every pane.
    ///
    /// Not written to preferences: a program that recolours the terminal for
    /// the duration of its run has not changed what the reader chose.
    ///
    /// - Parameter name: The theme the program named; unknown names do nothing.
    package func applyColorPreset(named name: String) {
        guard !name.isEmpty else { return }
        // Core owns which names exist; an unknown one is a no-op rather than a
        // guess, because a program naming a theme this build does not carry has
        // said nothing about what it wanted instead.
        let index = name.withCString { Int(Ubiquitty.Themes.indexForName($0)) }
        guard index >= 0 else { return }
        // Every pane, not the focused one: a split window reskins as a whole,
        // and a hosted pane carries the theme to its host.
        for surface in projectedSurfaces {
            _ = surface.applyTheme(at: index)
            // The chrome reads the published snapshot, and a theme written
            // under the model lock reaches it on the next drain: republished
            // here so the paint below sees the colours just applied rather
            // than the ones they replaced.
            surface.republishAfterPreferenceWrite()
        }
        applyChromeTheme()
        applyThemeToFindBar()
        refreshPaneChrome()
    }

    /// An axis of CSI 8 t: a negative count keeps the current size, 0 fills the screen.
    ///
    /// - Parameters:
    ///   - asked: What the program wrote.
    ///   - current: What the grid has now, for -1.
    ///   - screenExtent: What fits the screen, for 0.
    /// - Returns: The count to resize to.
    private func cellCount(_ asked: Int, current: Int, screenExtent: Int) -> Int {
        switch asked {
        case ..<0: current
        case 0: screenExtent
        default: asked
        }
    }

    /// How many rows the screen's visible frame would hold, the window's
    /// chrome included, so a frame sized to them stays on the screen.
    ///
    /// - Parameter surface: The surface whose cell decides.
    /// - Returns: The row count, at least one.
    private func screenRows(on surface: TerminalSurface) -> Int {
        guard let renderer = surface.renderer, let window else { return 24 }
        let cell = renderer.cellSize(for: surface)
        guard cell.height > 0 else { return 24 }
        let insets = renderer.gridFitInsets(for: surface)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 0
        let chrome = terminalFrameOverhead.height
        return max(Int((visible - chrome - insets.top - insets.bottom) / cell.height), 1)
    }

    /// How many columns the screen's visible frame would hold, on the same terms.
    ///
    /// - Parameter surface: The surface whose cell decides.
    /// - Returns: The column count, at least one.
    private func screenColumns(on surface: TerminalSurface) -> Int {
        guard let renderer = surface.renderer, let window else { return 80 }
        let cell = renderer.cellSize(for: surface)
        guard cell.width > 0 else { return 80 }
        let insets = renderer.gridFitInsets(for: surface)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 0
        let chrome = terminalFrameOverhead.width
        return max(Int((visible - chrome - insets.left - insets.right) / cell.width), 1)
    }

    /// Whether `[window] program_fullscreen` asks for the native transition.
    private var usesNativeProgramFullScreen: Bool {
        Ubiquitty.Preferences.Effective.programFullscreenUsesNative(Ubiquitty.Preferences.values().pointee)
    }

    /// A native full-screen transition started.
    ///
    /// The target is recorded here because the style mask does not carry it
    /// until the animation ends, and a CSI 10 t arriving in between has to be
    /// judged against where the window is going.
    ///
    /// - Parameter notification: AppKit's, unread.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        isInFullScreenTransition = true
        fullScreenTransitionTarget = true
        frameBeforeFullScreen = window?.frame
    }

    /// It finished; anything that waited for it runs now.
    ///
    /// The chrome and the geometry settle a turn later. AppKit wires the
    /// full-screen titlebar window up after this notification returns, so a
    /// re-theme on this turn finds no container to paint; and the layer's
    /// scale can still be the animation's here rather than the display's.
    ///
    /// - Parameter notification: AppKit's, unread.
    public func windowDidEnterFullScreen(_ notification: Notification) {
        isInFullScreenTransition = false
        runDeferredWindowRequests()
        DispatchQueue.main.async { [weak self] in
            self?.settleChromeAfterFullScreenTransition()
            self?.settleGeometryAfterFullScreenTransition()
        }
    }

    /// A native full-screen exit started.
    ///
    /// - Parameter notification: AppKit's, unread.
    public func windowWillExitFullScreen(_ notification: Notification) {
        isInFullScreenTransition = true
        fullScreenTransitionTarget = false
    }

    /// It finished; anything that waited for it runs now.
    ///
    /// The chrome settles at once, the window being back in its own frame
    /// with its own titlebar, and the geometry a turn later, for the reason
    /// entry has: synchronously in the notification the scale and the
    /// drawable can still be the animation's.
    ///
    /// - Parameter notification: AppKit's, unread.
    public func windowDidExitFullScreen(_ notification: Notification) {
        isInFullScreenTransition = false
        frameBeforeFullScreen = nil
        runDeferredWindowRequests()
        settleChromeAfterFullScreenTransition()
        DispatchQueue.main.async { [weak self] in
            self?.settleGeometryAfterFullScreenTransition()
        }
    }

    /// The window manager refused the transition.
    ///
    /// The bracket closes on the frame the window kept, and what waited for
    /// the transition runs against that frame.
    ///
    /// - Parameter window: The window, unread.
    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isInFullScreenTransition = false
        frameBeforeFullScreen = nil
        runDeferredWindowRequests()
    }

    /// The window manager refused the exit; the bracket closes as above.
    ///
    /// - Parameter window: The window, unread.
    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isInFullScreenTransition = false
        runDeferredWindowRequests()
    }

    /// Paints the chrome again after a full-screen transition.
    ///
    /// Full screen re-hosts the window: the title row it had is gone and a
    /// new one stands in its place, and the blur the window server drew
    /// behind the old one can go with the move. Both are put back off the
    /// same settings a config reload applies, so the two paths cannot
    /// disagree about what a window looks like.
    private func settleChromeAfterFullScreenTransition() {
        applyTranslucency()
        // Full screen re-hosts the title row into a window of AppKit's own and
        // hands it back on the way out, so the container the paint reached is
        // not the one standing now.
        window.map { TabStripStyling.forgetTitlebar(of: $0) }
        invalidateChromePaintMemo()
        applyChromeTheme()
        // The window's band leaves a title row only the menu bar reveals, or
        // goes back to the window's own.
        syncPaneProgressBands()
        chromeSettlesAfterFullScreenForTesting += 1
    }

    /// Republishes the geometry of every surface the window projects, hosted
    /// panes included, off the scale the window settled on.
    private func settleGeometryAfterFullScreenTransition() {
        for surface in projectedSurfaces {
            surface.settleAfterFullScreenTransition()
        }
    }

    /// Runs the geometry requests that arrived while the transition ran.
    ///
    /// Called by the full-screen delegate hooks once the mask is true, because
    /// a request judged against a frame the animation was still moving would
    /// size the window to somewhere it no longer is.
    func runDeferredWindowRequests() {
        let deferred = deferredGeometryRequests
        deferredGeometryRequests.removeAll()
        guard let surface = focusedPaneSurface else { return }
        for request in deferred {
            performWindowOperation(request.operation, request.first, request.second, on: surface)
        }
        flushProgramFrame()
        if let wants = pendingFullScreenRequest {
            pendingFullScreenRequest = nil
            setProgramFullScreen(mode: wants ? 1 : 0)
        }
    }
}
