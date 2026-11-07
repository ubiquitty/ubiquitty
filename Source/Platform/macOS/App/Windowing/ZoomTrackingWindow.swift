// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// A terminal window that knows when its own zoom owns a resize.
///
/// Zoom is AppKit's standard zoom: the window toggles between the frame a
/// person gave it and the screen's standard frame, a drag-resize leaves the
/// zoomed state, and a move never changes the size. The window manager's Fill
/// is not used, because its state lives in the window manager, which keeps a
/// tile's untiled frame through a drag-resize and offers no way to leave the
/// tile in place.
@objc(UBZoomTrackingWindow)
open class ZoomTrackingWindow: TerminalWindow {
    fileprivate var zoomResize: ZoomResizeTracker?

    /// The frame the window held when it last zoomed in. AppKit keeps its own
    /// copy only from that zoom, and a drag-resize or a move after it leaves
    /// that copy stale, so this window restores the frame it recorded.
    private var frameBeforeZoom: NSRect?

    /// Whether zoom owns the current resize, including its final view callbacks.
    package var isZoomResizeInProgress: Bool { zoomResize?.isZoomResizeInProgress ?? false }

    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        zoomResize = ZoomResizeTracker(window: self)
    }

    open override func zoom(_ sender: Any?) {
        zoomResize?.beginZoomResize()
        let wasZoomed = isZoomed
        let leavingFrame = frame
        super.zoom(sender)
        if !wasZoomed {
            frameBeforeZoom = leavingFrame
        } else if let restored = frameBeforeZoom {
            frameBeforeZoom = nil
            if frame != restored { setFrame(restored, display: true, animate: true) }
        }
        zoomResize?.finishZoomDispatch()
    }

    open override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || (event.type == .keyDown && event.keyCode == 53) {
            zoomResize?.cancelZoomResize()
        }
        super.sendEvent(event)
    }
}

/// Tells a zoom's resize from a person's, from the window's live-resize edges.
@MainActor
private final class ZoomResizeTracker: NSObject {
    private enum ZoomResizePhase {
        case idle
        case dispatching
        case pending
        case resizing
    }

    private weak var window: NSWindow?
    private var zoomResizePhase = ZoomResizePhase.idle
    private var zoomResizeGeneration: UInt64 = 0

    var isZoomResizeInProgress: Bool {
        switch zoomResizePhase {
        case .idle: false
        case .pending: window?.inLiveResize == true
        case .dispatching, .resizing: true
        }
    }

    init(window: NSWindow) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(resizeWillStart(_:)), name: NSWindow.willStartLiveResizeNotification, object: window)
        center.addObserver(self, selector: #selector(resizeDidEnd(_:)), name: NSWindow.didEndLiveResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
    }

    func beginZoomResize() {
        zoomResizeGeneration &+= 1
        zoomResizePhase = .dispatching
    }

    func finishZoomDispatch() {
        // An animated zoom can open its live resize after the dispatch
        // returns. A pending request affects no geometry until live resize
        // begins; the next user gesture cancels it before an unrelated drag.
        if zoomResizePhase == .dispatching { zoomResizePhase = .pending }
    }

    func cancelZoomResize() {
        zoomResizeGeneration &+= 1
        zoomResizePhase = .idle
    }

    @objc
    private func resizeWillStart(_ notification: Notification) {
        if zoomResizePhase == .pending || zoomResizePhase == .dispatching {
            zoomResizePhase = .resizing
        } else {
            // A zoom's own live resize opens from a dispatched or pending
            // request. Any other live resize is a person's drag, even when the
            // last zoom's settle never saw inLiveResize clear: the zoom is over.
            cancelZoomResize()
        }
    }

    @objc
    private func resizeDidEnd(_ notification: Notification) {
        let generation = zoomResizeGeneration
        // The window's notification precedes its views' end callbacks. Their
        // final resize and history settle still belong to this zoom.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.zoomResizeGeneration == generation, self.window?.inLiveResize != true else { return }
            self.zoomResizePhase = .idle
        }
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        cancelZoomResize()
    }
}
